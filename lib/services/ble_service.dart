/// BLE service for Omi device connection
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../device/omi_device.dart';
import '../device/omi_gatt.dart';
import 'ble/connection_ownership.dart';
import 'ble/gatt_retry.dart';

export '../device/omi_gatt.dart';
// `DeviceConnectionState` moved to `device/omi_device.dart` in LO-31 (it is
// part of the `device/` contract, not of this service). Re-exported so the
// existing importers of this file keep compiling.
export '../device/omi_device.dart' show DeviceConnectionState;

class BleDevice {
  final BluetoothDevice device;
  final String name;
  final int rssi;

  BleDevice({
    required this.device,
    required this.name,
    required this.rssi,
  });
}

class BleService {
  static final BleService _instance = BleService._internal();
  factory BleService() => _instance;
  BleService._internal();

  BluetoothDevice? _connectedDevice;

  // Auto-connect state for the saved device (LO-22). `_autoConnectSubscription`
  // deliberately lives outside `_cleanupSubscriptions()`: once armed, the
  // Android stack keeps retrying the link on its own (the plugin skips
  // `gatt.close()` for auto-connected devices), so the listener has to survive
  // a disconnect to see the reconnection that follows it.
  BluetoothDevice? _autoConnectDevice;
  StreamSubscription? _autoConnectSubscription;
  bool _isSettingUpConnection = false;

  BluetoothCharacteristic? _audioCharacteristic;
  StreamSubscription? _audioSubscription;
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _buttonSubscription;

  // Characteristics discovered once per connection, keyed by normalized
  // UUID. See `connect()` for the one-time service discovery call; every
  // other method looks the characteristic up here instead of re-discovering.
  final Map<String, BluetoothCharacteristic> _characteristics = {};

  BluetoothCharacteristic? _characteristic(String uuid) =>
      _characteristics[normalizeUuid(uuid)];

  int _lastMtu = 0;
  int get lastMtu => _lastMtu;

  String? _lastError;
  String? get lastError => _lastError;

  DeviceConnectionState _state = DeviceConnectionState.disconnected;
  DeviceConnectionState get state => _state;

  final _stateController = StreamController<DeviceConnectionState>.broadcast();
  Stream<DeviceConnectionState> get stateStream => _stateController.stream;

  final _audioController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get audioStream => _audioController.stream;

  final _batteryController = StreamController<int>.broadcast();
  Stream<int> get batteryStream => _batteryController.stream;

  final _buttonController = StreamController<List<int>>.broadcast();
  Stream<List<int>> get buttonStream => _buttonController.stream;

  bool get isConnected => _state == DeviceConnectionState.connected;
  String? get connectedDeviceId => _connectedDevice?.remoteId.str;
  String? get connectedDeviceName => _connectedDevice?.platformName;

  // Audio packet-length logging state (see startAudioStream / the audio
  // notification listener). Cheap diagnostics only — see docs/04 §5.
  // Length changes are logged at most `_maxAudioLengthLogs` times per stream
  // so a variable-length stream can never degenerate into one log line per
  // notification at 50-100 Hz.
  static const int _maxAudioLengthLogs = 5;
  static const int _audioPacketLogInterval = 1000;
  int _audioPacketCount = 0;
  int _audioLengthLogCount = 0;
  int _lastLoggedAudioPacketLength = -1;

  /// Arms `autoConnect: true` for a previously saved device.
  ///
  /// The returned bool says whether the request was *armed*, not whether the
  /// device is connected: with `autoConnect: true` flutter_blue_plus returns
  /// from `connect()` immediately and ignores the timeout, so the link comes
  /// up whenever the OS next sees the device. Callers observe [stateStream]
  /// for the actual connection and [isConnected] for the current state.
  ///
  /// This costs no BLE scan of our own — the Android stack keeps the
  /// connection request pending in its own background scheduling — so the
  /// reconnect path can never trip the 5-scans-per-30-seconds throttle.
  /// Arming is cancelled by [disconnect] or by a manual [connect].
  Future<bool> connectToSavedDevice(String deviceId) async {
    if (deviceId.isEmpty) return false;

    try {
      debugPrint('[LibreOmi/BLE] arming autoConnect for saved device: $deviceId');

      // Wait for Bluetooth adapter to be ready (skip unknown state)
      await FlutterBluePlus.adapterState
          .where((state) => state != BluetoothAdapterState.unknown)
          .first
          .timeout(const Duration(seconds: 10), onTimeout: () => BluetoothAdapterState.off);

      final state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) {
        debugPrint('Bluetooth is not on for auto-connect: $state');
        return false;
      }

      final device = BluetoothDevice.fromId(deviceId);

      // The Android plugin returns early — without registering the request in
      // `mAutoConnected` — when the device is already connected or already
      // connecting, and Dart cannot see that refusal. Recording the arm anyway
      // would make every later attempt short-circuit below on a request that
      // does not exist, and the OS would never retry the link.
      if (_isSettingUpConnection) {
        debugPrint('[LibreOmi/BLE] a connection is being set up, not arming autoConnect');
        return false;
      }
      if (device.isConnected) {
        debugPrint('[LibreOmi/BLE] $deviceId is already connected, not arming autoConnect');
        return false;
      }

      // Already armed for this device: re-arming would be a no-op on the
      // platform side, so keep the existing listener rather than tearing a
      // pending connection request down and back up. `isAutoConnectEnabled` is
      // the plugin's own record, so a request that was dropped elsewhere is
      // re-armed rather than assumed live.
      if (_autoConnectDevice?.remoteId == device.remoteId &&
          device.isAutoConnectEnabled) {
        debugPrint('[LibreOmi/BLE] autoConnect already armed for $deviceId');
        return true;
      }

      await _disarmAutoConnect();
      _autoConnectDevice = device;
      _autoConnectSubscription =
          device.connectionState.listen((state) => _onAutoConnectStateChanged(device, state));

      // `mtu: null` is mandatory here: flutter_blue_plus asserts that mtu and
      // autoConnect are incompatible, so the MTU is negotiated in
      // `_onConnectedSetup()` once the link is actually up.
      await device.connect(autoConnect: true, mtu: null);
      debugPrint('[LibreOmi/BLE] autoConnect armed for $deviceId');
      return true;
    } catch (e) {
      debugPrint('Failed to arm auto-connect for saved device: $e');
      _lastError = 'Failed to arm auto-connect: $e';
      await _disarmAutoConnect();
      return false;
    }
  }

  /// Cancels a pending or established `autoConnect` request.
  ///
  /// `BluetoothDevice.disconnect()` is what removes the device from the
  /// plugin's auto-connect list, so it has to run even when no link is up.
  /// Returns the device that was disarmed, so callers can avoid disconnecting
  /// the same device twice.
  Future<BluetoothDevice?> _disarmAutoConnect() async {
    final subscription = _autoConnectSubscription;
    final device = _autoConnectDevice;
    _autoConnectSubscription = null;
    _autoConnectDevice = null;
    await subscription?.cancel();
    if (device == null) return null;
    try {
      await device.disconnect();
    } catch (e) {
      debugPrint('[LibreOmi/BLE] error disarming autoConnect: $e');
    }
    return device;
  }

  /// Handles connection-state events for the auto-connected saved device.
  ///
  /// While merely armed the service stays [DeviceConnectionState.disconnected]:
  /// the wait is open-ended (the device may be out of range for hours) and a
  /// permanent `connecting` state would misreport that to the UI. The state
  /// only moves once the OS actually brings the link up.
  void _onAutoConnectStateChanged(BluetoothDevice device, BluetoothConnectionState state) {
    if (_autoConnectDevice?.remoteId != device.remoteId) return;
    if (state == BluetoothConnectionState.connected) {
      unawaited(_setUpAutoConnectedDevice(device));
      return;
    }
    // `connectionState` replays its current value to a new listener, so
    // arming device B while device A is connected delivers `disconnected(B)`
    // immediately. Only a drop of the link we actually hold may tear our
    // state down. The platform keeps the auto-connect request alive, so this
    // listener stays and fires again on the reconnection that follows.
    if (state == BluetoothConnectionState.disconnected &&
        _connectedDevice?.remoteId == device.remoteId) {
      _onDisconnected();
    }
  }

  /// Runs the post-connect setup for a device the OS auto-connected for us.
  Future<void> _setUpAutoConnectedDevice(BluetoothDevice device) async {
    // A manual connect in flight owns the service state until it finishes.
    if (_isSettingUpConnection) return;
    if (_connectedDevice != null && _connectedDevice!.remoteId != device.remoteId) {
      // Another device holds the connection. Walking away silently would leave
      // this link open behind the user's back with nothing left to notify us
      // about it, so drop it; the backoff re-arms once the service is idle.
      debugPrint('[LibreOmi/BLE] dropping auto-connect for ${device.remoteId} while '
          '${_connectedDevice!.remoteId} holds the connection');
      unawaited(_disarmAutoConnect());
      return;
    }
    if (_state == DeviceConnectionState.connected &&
        _connectedDevice?.remoteId == device.remoteId) {
      return;
    }
    _isSettingUpConnection = true;
    try {
      _lastError = null;
      _lastMtu = 0;
      _state = DeviceConnectionState.connecting;
      _stateController.add(_state);
      _connectedDevice = device;

      var ready = false;
      try {
        ready = await _onConnectedSetup(device);
      } catch (e) {
        debugPrint('[LibreOmi/BLE] auto-connect setup failed: $e');
        _lastError ??= 'Auto-connect setup failed: $e';
      }
      if (ready) {
        debugPrint('[LibreOmi/BLE] auto-connected to Omi device');
        return;
      }

      // Setup failed after the link came up (too-small MTU, missing audio
      // characteristic, a throwing discovery, or a manual connect that
      // superseded us). Tear this link down including the auto-connect
      // request; the caller's backoff re-arms it, which is what keeps a
      // permanently failing device from spinning at full speed.
      await _teardownFailedConnection(device);
    } finally {
      _isSettingUpConnection = false;
    }
  }


  /// Scan for Omi devices
  Stream<List<BleDevice>> scanForDevices({Duration timeout = const Duration(seconds: 15)}) async* {
    List<BleDevice> devices = [];

    try {
      // Wait for Bluetooth adapter to be ready (skip unknown state)
      await FlutterBluePlus.adapterState
          .where((state) => state != BluetoothAdapterState.unknown)
          .first
          .timeout(const Duration(seconds: 5), onTimeout: () => BluetoothAdapterState.off);

      final state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) {
        debugPrint('Bluetooth is not on: $state');
        return;
      }

      debugPrint('Starting BLE scan...');

      await FlutterBluePlus.startScan(
        timeout: timeout,
        // Don't filter - show all devices so user can pick
        // withServices: [Guid(omiServiceUuid)],
      );

      await for (final results in FlutterBluePlus.scanResults) {
        devices = results
            .where((r) => r.device.platformName.isNotEmpty)
            .where((r) => r.device.platformName.toLowerCase().contains('omi')) // Filter for Omi devices
            .map((r) => BleDevice(
              device: r.device,
              name: r.device.platformName,
              rssi: r.rssi,
            )).toList();

        // Sort by signal strength
        devices.sort((a, b) => b.rssi.compareTo(a.rssi));

        debugPrint('Found ${devices.length} devices');
        yield devices;
      }
    } catch (e) {
      debugPrint('Scan error: $e');
      yield [];
    }
  }

  /// Stop scanning
  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
  }

  /// Connect to Omi device, user-initiated.
  ///
  /// Stays `autoConnect: false` (a direct connection is much faster than the
  /// OS-scheduled one) and disarms any auto-connect request first, so the two
  /// paths can never race for the same link.
  Future<bool> connect(BluetoothDevice device) async {
    _lastError = null;
    // Drop anything left over from a previous connection before we start, so
    // a failure part-way through this method can never leave stale handles
    // behind, and so a stale connection-state subscription is cancelled
    // rather than silently overwritten below. This runs *before* the disarm:
    // cancelling a pending auto-connect makes the platform synthesise a
    // disconnect event, which a stale listener would otherwise act on.
    await _cleanupSubscriptions();
    await _disarmAutoConnect();
    _lastMtu = 0;
    // Claims the setup slot for the whole method, so an auto-connect armed by
    // the reconnect backoff while this is still in flight cannot run a second,
    // concurrent `_onConnectedSetup()` for the same device.
    _isSettingUpConnection = true;
    try {
      _state = DeviceConnectionState.connecting;
      _stateController.add(_state);
      // Claim the ownership token now, not after the link is up: a connect
      // that fails while opening the radio link must still be recognised as
      // the service's owner by `_teardownFailedConnection`, or the state
      // would stay stuck at `connecting` with nothing left to reset it.
      _connectedDevice = device;

      await _connectWithGattRetry(device);

      if (!await _onConnectedSetup(device)) {
        await _teardownFailedConnection(device);
        return false;
      }

      debugPrint('Connected to Omi device');
      return true;
    } catch (e) {
      // Anything after `device.connect()` can throw (service discovery has a
      // 15 s timeout of its own, `setNotifyValue` can fail). Tear the link
      // down completely, otherwise the GATT connection and the
      // connection-state subscription stay alive and the next attempt
      // overwrites the subscription without cancelling it.
      debugPrint('Failed to connect: $e');
      // Keep a more specific reason (e.g. the MTU rejection) if one was
      // already recorded before the throw.
      _lastError ??= 'Failed to connect: $e';
      await _teardownFailedConnection(device);
      return false;
    } finally {
      _isSettingUpConnection = false;
    }
  }

  /// Opens the link for a user-initiated connect, retrying the transient
  /// Android GATT statuses (133 / 257, see `ble/gatt_retry.dart`) up to
  /// [maxConnectAttempts] times with [connectRetryDelays] in between. Any
  /// other failure is rethrown immediately — retrying it would only delay the
  /// error the user is waiting for.
  Future<void> _connectWithGattRetry(BluetoothDevice device) async {
    for (var attempt = 1;; attempt++) {
      try {
        // `mtu: null` disables the plugin's own post-connect MTU request
        // (flutter_blue_plus defaults it to 512). We negotiate explicitly in
        // `_onConnectedSetup()` so we can observe and gate on the result;
        // leaving the default on would exchange MTU twice per connect.
        await device.connect(timeout: const Duration(seconds: 10), mtu: null);
        return;
      } catch (e) {
        final status = _connectErrorStatus(e);
        if (attempt >= maxConnectAttempts ||
            status == null ||
            !isRetryableGattStatus(status)) {
          rethrow;
        }
        final delay = connectRetryDelays[attempt - 1];
        debugPrint('[LibreOmi/BLE] connect attempt $attempt/$maxConnectAttempts failed with '
            'retryable GATT status $status; retrying in ${delay.inSeconds}s');
        await Future.delayed(delay);
      }
    }
  }

  /// The platform status behind a failed connect, if there is one.
  ///
  /// `FlutterBluePlusException` carries it as a field, which is the reliable
  /// source; `gattStatusOf` parses `toString()` and is the fallback for the
  /// error types the plugin lets through unwrapped.
  int? _connectErrorStatus(Object error) {
    if (error is FlutterBluePlusException) return error.code;
    return gattStatusOf(error);
  }

  /// Everything that has to happen once a link is up, shared by the manual
  /// and the auto-connect paths: MTU negotiation and gate, one-time service
  /// discovery, characteristic cache, button subscription.
  ///
  /// Returns false when the link came up but is unusable (too small an MTU,
  /// no audio characteristic); the caller tears the connection down. May also
  /// throw, which callers treat the same way.
  Future<bool> _onConnectedSetup(BluetoothDevice device) async {
    // `_connectedDevice` is the ownership token: a manual connect can take the
    // service over while the platform calls below are in flight, and then none
    // of the shared state (cache, characteristics, subscriptions) is ours to
    // write any more.
    bool stillOwns() => _connectedDevice?.remoteId == device.remoteId;

    // Listen for disconnection. The auto-connect path already owns a
    // longer-lived listener for this device, so only the manual path needs
    // one of its own.
    if (_autoConnectDevice?.remoteId != device.remoteId) {
      _connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _onDisconnected();
        }
      });
    }

    // MTU negotiation must happen AFTER connect() and BEFORE service
    // discovery below: the flutter_blue_plus source documents a race
    // where an unsolicited MTU update makes a later discovery call
    // time out.
    //
    // `Platform.isAndroid` is normally banned outside `platform/` per
    // AGENTS.md, but that rule is waived in this file by the LO-12
    // direction record — this logic moves to `platform/` in M3.
    if (Platform.isAndroid) {
      try {
        _lastMtu = await device.requestMtu(512);
      } catch (e) {
        debugPrint('[LibreOmi/BLE] requestMtu failed: $e');
        _lastMtu = device.mtuNow;
      }
      debugPrint('[LibreOmi/BLE] negotiated MTU=$_lastMtu (minimum $minimumUsableMtu)');

      if (!isMtuSufficient(_lastMtu)) {
        final message =
            '[LibreOmi/BLE] MTU too small: negotiated=$_lastMtu, required minimum=$minimumUsableMtu';
        debugPrint(message);
        _lastError = message;
        return false;
      }
    } else {
      // iOS/other platforms negotiate their own MTU and requestMtu()
      // throws off Android. `mtuNow` may still read the platform default
      // right after connect, so it is informational only — do not gate.
      _lastMtu = device.mtuNow;
      debugPrint('[LibreOmi/BLE] informational MTU=$_lastMtu (non-Android, not gated)');
    }

    // Discover services exactly once per connection; cache characteristics.
    final services = await device.discoverServices();
    if (!stillOwns()) {
      debugPrint('[LibreOmi/BLE] setup for ${device.remoteId} was superseded during discovery');
      return false;
    }
    for (var service in services) {
      for (var char in service.characteristics) {
        _characteristics[normalizeUuid(char.uuid.toString())] = char;
      }
    }

    _audioCharacteristic = _characteristic(audioDataStreamCharacteristicUuid);
    if (_audioCharacteristic == null) {
      const message = 'Audio characteristic not found';
      debugPrint(message);
      _lastError = message;
      return false;
    }

    // Subscribe to button characteristic, if present.
    final buttonCharacteristic = _characteristic(buttonTriggerCharacteristicUuid);
    if (buttonCharacteristic != null) {
      await buttonCharacteristic.setNotifyValue(true);
      if (!stillOwns()) {
        debugPrint('[LibreOmi/BLE] setup for ${device.remoteId} was superseded, '
            'not subscribing to button events');
        return false;
      }
      _buttonSubscription = buttonCharacteristic.onValueReceived.listen((value) {
        if (value.isNotEmpty) _buttonController.add(value);
      });
      debugPrint('Subscribed to button events');
    }

    if (!stillOwns()) {
      debugPrint('[LibreOmi/BLE] setup for ${device.remoteId} was superseded');
      return false;
    }

    _state = DeviceConnectionState.connected;
    _stateController.add(_state);
    return true;
  }

  /// Releases a link that came up but could not be used, and disarms
  /// auto-connect for it: the caller's backoff re-arms after its next delay,
  /// which is what stops a device that fails setup every time from retrying
  /// at full speed.
  ///
  /// Scoped to [device]: a setup that was superseded while it awaited must
  /// drop its own link without touching the connection that replaced it, so
  /// the shared state is only reset when [device] still owns it.
  Future<void> _teardownFailedConnection(BluetoothDevice device) async {
    final action = teardownActionFor(
      serviceOwnerId: _connectedDevice?.remoteId.str,
      failedDeviceId: device.remoteId.str,
    );

    BluetoothDevice? disarmed;
    if (_autoConnectDevice?.remoteId == device.remoteId) {
      disarmed = await _disarmAutoConnect();
    }
    if (action == TeardownAction.resetService) {
      await _cleanupSubscriptions();
    }
    if (disarmed?.remoteId != device.remoteId) {
      try {
        await device.disconnect();
      } catch (e) {
        debugPrint('Error disconnecting after a failed connect: $e');
      }
    }
    if (action == TeardownAction.releaseLinkOnly) {
      debugPrint('[LibreOmi/BLE] released ${device.remoteId} without touching '
          'the connection that superseded it');
      return;
    }

    _connectedDevice = null;
    _state = DeviceConnectionState.disconnected;
    _stateController.add(_state);
  }

  /// Set Microphone Gain (0-100)
  Future<void> setMicGain(int gain) async {
    if (_connectedDevice == null) return;
    try {
      final char = _characteristic(settingsMicGainCharacteristicUuid);
      if (char == null) {
        debugPrint('setMicGain: mic gain characteristic not available');
        return;
      }
      await char.write([gain.clamp(0, 100)]);
      debugPrint('Set Mic Gain to $gain');
    } catch (e) {
      debugPrint('Error setting mic gain: $e');
    }
  }

  /// Get Microphone Gain
  Future<int?> getMicGain() async {
    if (_connectedDevice == null) return null;
    try {
      final char = _characteristic(settingsMicGainCharacteristicUuid);
      if (char == null) {
        debugPrint('getMicGain: mic gain characteristic not available');
        return null;
      }
      final value = await char.read();
      if (value.isNotEmpty) return value[0];
    } catch (e) {
      debugPrint('Error getting mic gain: $e');
    }
    return null;
  }

  /// Set LED Dim Ratio (0-100)
  Future<void> setLedDimRatio(int ratio) async {
    if (_connectedDevice == null) return;
    try {
      final char = _characteristic(settingsDimRatioCharacteristicUuid);
      if (char == null) {
        debugPrint('setLedDimRatio: LED dim ratio characteristic not available');
        return;
      }
      await char.write([ratio.clamp(0, 100)]);
      debugPrint('Set LED Dim Ratio to $ratio');
    } catch (e) {
      debugPrint('Error setting LED dim ratio: $e');
    }
  }

  /// Get LED Dim Ratio
  Future<int?> getLedDimRatio() async {
    if (_connectedDevice == null) return null;
    try {
      final char = _characteristic(settingsDimRatioCharacteristicUuid);
      if (char == null) {
        debugPrint('getLedDimRatio: LED dim ratio characteristic not available');
        return null;
      }
      final value = await char.read();
      if (value.isNotEmpty) return value[0];
    } catch (e) {
      debugPrint('Error getting LED dim ratio: $e');
    }
    return null;
  }

  /// Trigger haptic feedback on device (using Speaker Service)
  /// level: 1 (20ms), 2 (50ms), 3 (500ms)
  Future<void> triggerHaptic(int level) async {
    if (_connectedDevice == null) return;
    try {
      final char = _characteristic(speakerDataStreamCharacteristicUuid);
      if (char == null) {
        debugPrint('Haptic service not found');
        return;
      }
      await char.write([level & 0xFF]);
      debugPrint('Triggered Omi Haptic (Level $level)');
    } catch (e) {
      debugPrint('Error triggering haptic: $e');
    }
  }

  /// Applies a connection priority (Android only). Failures here must never
  /// abort the audio stream, so they are logged and swallowed.
  Future<void> _requestConnectionPriority(ConnectionPriority priority) async {
    if (!Platform.isAndroid) return;
    if (_connectedDevice == null) return;
    try {
      await _connectedDevice!.requestConnectionPriority(connectionPriorityRequest: priority);
      debugPrint('[LibreOmi/BLE] connection priority set to $priority');
    } catch (e) {
      debugPrint('[LibreOmi/BLE] failed to set connection priority to $priority: $e');
    }
  }

  /// Start listening for audio data
  Future<void> startAudioStream() async {
    if (_audioCharacteristic == null) return;

    _audioPacketCount = 0;
    _audioLengthLogCount = 0;
    _lastLoggedAudioPacketLength = -1;

    try {
      await _audioCharacteristic!.setNotifyValue(true);
      _audioSubscription = _audioCharacteristic!.onValueReceived.listen((value) {
        if (value.isNotEmpty) {
          _audioPacketCount++;
          if (value.length != _lastLoggedAudioPacketLength &&
              _audioLengthLogCount < _maxAudioLengthLogs) {
            debugPrint('[LibreOmi/BLE] audio packet length=${value.length}');
            _lastLoggedAudioPacketLength = value.length;
            _audioLengthLogCount++;
          }
          if (_audioPacketCount % _audioPacketLogInterval == 0) {
            debugPrint(
                '[LibreOmi/BLE] audio packets=$_audioPacketCount length=${value.length}');
          }
          _audioController.add(Uint8List.fromList(value));
        }
      });
      debugPrint('Audio stream started');
      unawaited(_requestConnectionPriority(ConnectionPriority.high));
    } catch (e) {
      debugPrint('Failed to start audio stream: $e');
    }
  }

  /// Stop audio stream
  Future<void> stopAudioStream() async {
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    try {
      await _audioCharacteristic?.setNotifyValue(false);
    } catch (e) {
      debugPrint('Error stopping audio stream: $e');
    }
    unawaited(_requestConnectionPriority(ConnectionPriority.balanced));
  }

  /// Get battery level
  Future<int?> getBatteryLevel() async {
    if (_connectedDevice == null) return null;

    try {
      final char = _characteristic(batteryLevelCharacteristicUuid);
      if (char == null) {
        debugPrint('getBatteryLevel: battery characteristic not available');
        return null;
      }
      final value = await char.read();
      if (value.isNotEmpty) {
        return value[0];
      }
    } catch (e) {
      debugPrint('Failed to read battery: $e');
    }
    return null;
  }

  /// Cancels all live subscriptions and clears cached connection state.
  /// Idempotent: safe to call from both `disconnect()` and
  /// `_onDisconnected()`, even if both run for the same disconnect event.
  ///
  /// Every field is detached synchronously before the first `await`, so a
  /// second disconnect event arriving while the cancels are still in flight
  /// finds nothing left to clean up and cannot double-cancel.
  Future<void> _cleanupSubscriptions() async {
    final audio = _audioSubscription;
    final button = _buttonSubscription;
    final storage = _storageSubscription;
    final connection = _connectionSubscription;
    _audioSubscription = null;
    _buttonSubscription = null;
    _storageSubscription = null;
    _connectionSubscription = null;
    _characteristics.clear();
    _audioCharacteristic = null;
    _storageCharacteristic = null;
    // `_lastMtu` is deliberately NOT reset here: after a connection is
    // refused for a too-small MTU the caller still wants to read the
    // negotiated value. It is reset at the start of the next `connect()`.

    await audio?.cancel();
    await button?.cancel();
    await storage?.cancel();
    await connection?.cancel();
  }

  /// Disconnect from device.
  ///
  /// This is the explicit, user-initiated teardown: it also disarms
  /// auto-connect, so the OS will not bring the link back up behind the
  /// user's back.
  Future<void> disconnect() async {
    await _cleanupSubscriptions();
    final disarmed = await _disarmAutoConnect();

    final device = _connectedDevice;
    if (device != null && device.remoteId != disarmed?.remoteId) {
      try {
        await device.disconnect();
      } catch (e) {
        debugPrint('Error disconnecting: $e');
      }
    }

    _connectedDevice = null;
    _state = DeviceConnectionState.disconnected;
    _stateController.add(_state);
  }

  void _onDisconnected() {
    // Note: does not call device.disconnect() — this handler runs in
    // response to a disconnect that already happened.
    unawaited(_cleanupSubscriptions());
    _connectedDevice = null;
    _state = DeviceConnectionState.disconnected;
    _stateController.add(_state);
    debugPrint('Device disconnected');
  }

  /// Get device information from Omi device
  Future<Map<String, String>> getDeviceInfo() async {
    if (_connectedDevice == null) return {};
    Map<String, String> deviceInfo = {};

    try {
      final entries = {
        'Model': modelNumberCharacteristicUuid,
        'Firmware': firmwareRevisionCharacteristicUuid,
        'Hardware': hardwareRevisionCharacteristicUuid,
        'Manufacturer': manufacturerNameCharacteristicUuid,
      };
      for (final entry in entries.entries) {
        final char = _characteristic(entry.value);
        if (char == null) {
          debugPrint('getDeviceInfo: ${entry.key} characteristic not available');
          continue;
        }
        final val = await char.read();
        if (val.isNotEmpty) deviceInfo[entry.key] = String.fromCharCodes(val);
      }
    } catch (e) {
      debugPrint('Error getting device info: $e');
    }
    return deviceInfo;
  }

  // =============== SD Card / Storage Methods ===============

  /// Get audio codec from the Omi device
  Future<BleAudioCodec> getAudioCodec() async {
    if (_connectedDevice == null) return BleAudioCodec.pcm8;

    try {
      final char = _characteristic(audioCodecCharacteristicUuid);
      if (char == null) {
        debugPrint('getAudioCodec: audio codec characteristic not available');
        return BleAudioCodec.pcm8;
      }
      final codecValue = await char.read();
      if (codecValue.isNotEmpty) {
        final codecId = codecValue[0];
        final codec = codecFromId(codecId);
        if (codec == null) {
          debugPrint('getAudioCodec: unknown codec id=$codecId, defaulting to pcm8');
          return BleAudioCodec.pcm8;
        }
        return codec;
      }
    } catch (e) {
      debugPrint('Error reading audio codec: $e');
    }
    return BleAudioCodec.pcm8;
  }

  /// Get storage list (returns total bytes and offset if available)
  Future<List<int>> getStorageList() async {
    if (_connectedDevice == null) {
      debugPrint('getStorageList: No connected device');
      return [];
    }

    try {
      final char = _characteristic(storageReadControlCharacteristicUuid);
      if (char == null) {
        debugPrint('getStorageList: Storage service not found on this device');
        return [];
      }
      debugPrint('getStorageList: Found storage control characteristic, reading...');
      final storageValue = await char.read();
      debugPrint('getStorageList: Read ${storageValue.length} bytes');

      final storageLengths = parseStorageList(storageValue);
      debugPrint('Storage lengths: $storageLengths');
      return storageLengths;
    } catch (e) {
      debugPrint('Error reading storage list: $e');
    }
    return [];
  }

  /// Check if SD card storage is available
  Future<bool> hasStorageSupport() async {
    final storageList = await getStorageList();
    return storageList.isNotEmpty;
  }

  /// Write command to storage (for reading or clearing)
  /// command: 0 = start reading, 1 = clear/acknowledge
  Future<bool> writeToStorage(int fileNum, int command, int offset) async {
    if (_connectedDevice == null) return false;

    try {
      final char = _characteristic(storageDataStreamCharacteristicUuid);
      if (char == null) {
        debugPrint('writeToStorage: storage data characteristic not available');
        return false;
      }
      debugPrint('Writing to storage: file=$fileNum, cmd=$command, offset=$offset');
      final payload = buildStorageCommand(
        command: command,
        fileNumber: fileNum,
        offset: offset,
      );
      await char.write(payload, withoutResponse: false);
      return true;
    } catch (e) {
      debugPrint('Error writing to storage: $e');
    }
    return false;
  }

  final _storageController = StreamController<List<int>>.broadcast();
  Stream<List<int>> get storageStream => _storageController.stream;
  StreamSubscription? _storageSubscription;
  BluetoothCharacteristic? _storageCharacteristic;

  /// Start listening for storage data stream
  Future<StreamSubscription?> startStorageStream() async {
    if (_connectedDevice == null) return null;

    try {
      final char = _characteristic(storageDataStreamCharacteristicUuid);
      if (char == null) {
        debugPrint('startStorageStream: storage data characteristic not available');
        return null;
      }
      _storageCharacteristic = char;
      await char.setNotifyValue(true);
      _storageSubscription = char.onValueReceived.listen((value) {
        if (value.isNotEmpty) {
          _storageController.add(value);
        }
      });
      debugPrint('Storage stream started');
      return _storageSubscription;
    } catch (e) {
      debugPrint('Error starting storage stream: $e');
    }
    return null;
  }

  /// Stop storage stream
  Future<void> stopStorageStream() async {
    await _storageSubscription?.cancel();
    _storageSubscription = null;
    try {
      await _storageCharacteristic?.setNotifyValue(false);
    } catch (e) {
      debugPrint('Error stopping storage stream: $e');
    }
    _storageCharacteristic = null;
  }

  /// Intentionally a no-op, kept so existing callers still compile.
  ///
  /// `BleService` is a process-lifetime singleton but `AppProvider.dispose()`
  /// calls this, so neither the broadcast controllers nor the live
  /// subscriptions may be torn down here: closing the controllers would leave
  /// a re-created provider with permanently dead streams, and cancelling the
  /// subscriptions would leave a still-connected device with no data flow and
  /// nothing to re-subscribe it. Use `disconnect()` to release a connection.
  void dispose() {}
}
