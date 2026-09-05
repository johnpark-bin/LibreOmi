/// BLE service for Omi device connection
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble/ble_protocol.dart';

export 'ble/ble_protocol.dart';

enum DeviceConnectionState {
  disconnected,
  connecting,
  connected,
}

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

  /// Try to connect to a previously saved device by its remote ID
  Future<bool> connectToSavedDevice(String deviceId) async {
    if (deviceId.isEmpty) return false;

    try {
      debugPrint('Attempting to reconnect to saved device: $deviceId');

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

      // Create device from ID and try to connect
      final device = BluetoothDevice.fromId(deviceId);
      return await connect(device);
    } catch (e) {
      debugPrint('Failed to reconnect to saved device: $e');
      return false;
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

  /// Connect to Omi device
  Future<bool> connect(BluetoothDevice device) async {
    _lastError = null;
    // Drop anything left over from a previous connection before we start, so
    // a failure part-way through this method can never leave stale handles
    // behind, and so a stale connection-state subscription is cancelled
    // rather than silently overwritten below.
    await _cleanupSubscriptions();
    _lastMtu = 0;
    try {
      _state = DeviceConnectionState.connecting;
      _stateController.add(_state);

      // `mtu: null` disables the plugin's own post-connect MTU request
      // (flutter_blue_plus defaults it to 512). We negotiate explicitly below
      // so we can observe and gate on the result; leaving the default on
      // would exchange MTU twice per connect.
      await device.connect(timeout: const Duration(seconds: 10), mtu: null);
      _connectedDevice = device;

      // Listen for disconnection
      _connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _onDisconnected();
        }
      });

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
          await disconnect();
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
        await disconnect();
        return false;
      }

      // Subscribe to button characteristic, if present.
      final buttonCharacteristic = _characteristic(buttonTriggerCharacteristicUuid);
      if (buttonCharacteristic != null) {
        await buttonCharacteristic.setNotifyValue(true);
        _buttonSubscription = buttonCharacteristic.onValueReceived.listen((value) {
          if (value.isNotEmpty) _buttonController.add(value);
        });
        debugPrint('Subscribed to button events');
      }

      _state = DeviceConnectionState.connected;
      _stateController.add(_state);

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
      await _cleanupSubscriptions();
      try {
        await _connectedDevice?.disconnect();
      } catch (e) {
        debugPrint('Error disconnecting after a failed connect: $e');
      }
      _connectedDevice = null;
      _state = DeviceConnectionState.disconnected;
      _stateController.add(_state);
      return false;
    }
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

  /// Disconnect from device
  Future<void> disconnect() async {
    await _cleanupSubscriptions();

    try {
      await _connectedDevice?.disconnect();
    } catch (e) {
      debugPrint('Error disconnecting: $e');
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
