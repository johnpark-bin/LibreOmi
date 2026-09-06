/// Owns scanning, connecting, the saved device and the currently connected
/// [OmiDevice] (`docs/03-architecture.md` §1).
///
/// The auto-reconnect backoff itself lives in `controllers/device_controller.dart`
/// (LO-34).
library;

import 'dart:async';
import 'dart:typed_data';

import '../core/log.dart';
import 'omi_gatt.dart';
import 'ble_session_capture.dart';
import 'omi_device.dart';

const _log = Log('Device');

/// An Omi device seen by a scan. Deliberately free of `flutter_blue_plus`
/// types so the UI and the tests can build one.
class DiscoveredDevice {
  const DiscoveredDevice({
    required this.id,
    required this.name,
    required this.rssi,
  });

  /// Platform device identifier (the BLE remote id).
  final String id;
  final String name;
  final int rssi;

  @override
  bool operator ==(Object other) =>
      other is DiscoveredDevice &&
      other.id == id &&
      other.name == name &&
      other.rssi == rssi;

  @override
  int get hashCode => Object.hash(id, name, rssi);

  @override
  String toString() => 'DiscoveredDevice($id, $name, $rssi)';
}

/// Where [DeviceManager] remembers the device to reconnect to. Backed by
/// `SettingsService` in production; a map in tests.
abstract class SavedDeviceStore {
  String get savedDeviceId;
  set savedDeviceId(String value);

  String get savedDeviceName;
  set savedDeviceName(String value);
}

/// The transport [DeviceManager] drives: a real BLE stack
/// (`BleDeviceHost` in `omi_ble_device.dart`) or a fake one in tests.
abstract class OmiDeviceHost {
  /// Emits the current match list repeatedly while a scan runs.
  Stream<List<DiscoveredDevice>> scanForDevices({Duration timeout});

  Future<void> stopScan();

  /// User-initiated connect. Returns the connected device, or `null` when the
  /// connection could not be established.
  Future<OmiDevice?> connect(DiscoveredDevice device);

  /// Arms an OS-scheduled reconnect for a previously saved device. Returns
  /// whether the request was *armed*, not whether the device is connected —
  /// callers watch [connectionState] for that.
  Future<bool> armSavedDevice(String deviceId);

  /// The device the host currently holds, or `null` when disconnected.
  OmiDevice? get currentDevice;

  Stream<DeviceConnectionState> get connectionState;

  DeviceConnectionState get state;

  Future<void> disconnect();

  /// Releases whatever the host holds (device subscriptions, caches). Does
  /// *not* drop the radio link — [disconnect] is what releases a connection.
  Future<void> dispose();
}

/// The single entry point the rest of the app uses to reach a wearable.
class DeviceManager {
  DeviceManager({
    required OmiDeviceHost host,
    required SavedDeviceStore savedDevices,
    BleSessionCapture? capture,
  })  : _host = host,
        _savedDevices = savedDevices,
        _capture = capture {
    _stateSubscription = _host.connectionState.listen(_onStateChanged);
    // A host that is already connected emits nothing until the next change,
    // so attach to it now rather than waiting for an event that may not come.
    if (_host.state == DeviceConnectionState.connected) {
      _onStateChanged(DeviceConnectionState.connected);
    }
  }

  final OmiDeviceHost _host;
  final SavedDeviceStore _savedDevices;
  final BleSessionCapture? _capture;

  StreamSubscription<DeviceConnectionState>? _stateSubscription;

  // Notification streams that outlive a single connection.
  //
  // `current` is null while disconnected, so a caller that subscribed once at
  // startup (`DeviceController.init()`) cannot hold the device's own streams. The
  // manager forwards them instead, re-attaching on every connection.
  //
  // `sync: true` so this forwarding hop does not *add* reordering between the
  // audio and button paths (`docs/03-architecture.md` §2). It cannot create an
  // ordering guarantee that does not already exist: `BleService`'s own
  // controllers are plain broadcast controllers, so both paths already take
  // one asynchronous hop before reaching here — symmetrically, which is what
  // keeps their relative order intact.
  final _audioController = StreamController<Uint8List>.broadcast(sync: true);
  final _buttonController = StreamController<ButtonEvent>.broadcast(sync: true);
  final _batteryController = StreamController<int>.broadcast(sync: true);

  StreamSubscription<Uint8List>? _audioForward;
  StreamSubscription<ButtonEvent>? _buttonForward;
  StreamSubscription<int>? _batteryForward;
  OmiDevice? _forwardedDevice;

  /// Raw audio notification payloads from whichever device is connected.
  Stream<Uint8List> get audioPackets => _audioController.stream;

  /// Decoded button events from whichever device is connected.
  Stream<ButtonEvent> get buttonEvents => _buttonController.stream;

  /// Battery percentages from whichever device is connected.
  Stream<int> get batteryLevel => _batteryController.stream;

  /// The connected device, or `null`.
  OmiDevice? get current => _host.currentDevice;

  Stream<DeviceConnectionState> get connectionState => _host.connectionState;

  DeviceConnectionState get state => _host.state;

  bool get isConnected => state == DeviceConnectionState.connected;

  String get savedDeviceId => _savedDevices.savedDeviceId;

  String get savedDeviceName => _savedDevices.savedDeviceName;

  Stream<List<DiscoveredDevice>> scanForDevices({
    Duration timeout = const Duration(seconds: 15),
  }) =>
      _host.scanForDevices(timeout: timeout);

  Future<void> stopScan() => _host.stopScan();

  /// Connects to a scanned device and, on success, remembers it as the device
  /// to auto-reconnect to.
  Future<bool> connect(DiscoveredDevice device) async {
    final connected = await _host.connect(device);
    if (connected == null) return false;
    _savedDevices.savedDeviceId = connected.id;
    _savedDevices.savedDeviceName =
        device.name.isNotEmpty ? device.name : connected.name;
    _log.d('connected to ${connected.id}, saved as "${_savedDevices.savedDeviceName}"');
    return true;
  }

  /// Arms an OS-scheduled reconnect for the saved device. Returns false when
  /// there is no saved device or the request could not be armed.
  Future<bool> connectToSavedDevice() async {
    final savedId = _savedDevices.savedDeviceId;
    if (savedId.isEmpty) {
      _log.d('no saved device to arm');
      return false;
    }
    return _host.armSavedDevice(savedId);
  }

  Future<void> disconnect() => _host.disconnect();

  void _onStateChanged(DeviceConnectionState state) {
    if (state == DeviceConnectionState.connected) {
      final device = _host.currentDevice;
      // `_attachTo` returns false for a repeated `connected` event on the
      // device already attached, so a duplicate event cannot stack a second
      // set of forwards or open a second capture file.
      if (device != null && _attachTo(device)) {
        unawaited(_capture?.start(device));
      }
    } else if (state == DeviceConnectionState.disconnected) {
      _detach();
      unawaited(_capture?.stop());
    }
  }

  /// Forwards [device]'s streams. Returns false when it was already the
  /// attached device and nothing changed.
  bool _attachTo(OmiDevice device) {
    if (identical(_forwardedDevice, device)) return false;
    _detach();
    _forwardedDevice = device;
    _audioForward = device.audioPackets.listen(_audioController.add);
    _buttonForward = device.buttonEvents.listen(_buttonController.add);
    _batteryForward = device.batteryLevel.listen(_batteryController.add);
    return true;
  }

  void _detach() {
    _forwardedDevice = null;
    unawaited(_audioForward?.cancel());
    unawaited(_buttonForward?.cancel());
    unawaited(_batteryForward?.cancel());
    _audioForward = null;
    _buttonForward = null;
    _batteryForward = null;
  }

  Future<void> dispose() async {
    await _stateSubscription?.cancel();
    _stateSubscription = null;
    _detach();
    await _capture?.stop();
    await _host.dispose();
    await _audioController.close();
    await _buttonController.close();
    await _batteryController.close();
  }
}
