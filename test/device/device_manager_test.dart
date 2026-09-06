import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/device/ble_session_capture.dart';
import 'package:libreomi/device/device_manager.dart';
import 'package:libreomi/device/fake_omi_device.dart';
import 'package:libreomi/device/omi_device.dart';
import 'package:libreomi/device/omi_gatt.dart';

/// An in-memory [SavedDeviceStore], standing in for `SettingsService`.
class MapSavedDeviceStore implements SavedDeviceStore {
  @override
  String savedDeviceId = '';

  @override
  String savedDeviceName = '';
}

/// A scriptable [OmiDeviceHost]: the "fake scanner" the DeviceManager tests
/// drive instead of a BLE stack.
class FakeOmiDeviceHost implements OmiDeviceHost {
  FakeOmiDeviceHost({
    this.scanResults = const <List<DiscoveredDevice>>[],
    this.connectSucceeds = true,
    this.armSucceeds = true,
  });

  final List<List<DiscoveredDevice>> scanResults;
  bool connectSucceeds;
  bool armSucceeds;

  final List<DiscoveredDevice> connectCalls = [];
  final List<String> armCalls = [];
  int stopScanCalls = 0;
  int disconnectCalls = 0;

  final _stateController =
      StreamController<DeviceConnectionState>.broadcast(sync: true);

  FakeOmiDevice? _device;
  DeviceConnectionState _state = DeviceConnectionState.disconnected;

  /// The device handed out on a successful connect. Assigned so a test can
  /// drive its streams.
  FakeOmiDevice? get device => _device;

  @override
  Stream<List<DiscoveredDevice>> scanForDevices({
    Duration timeout = const Duration(seconds: 15),
  }) =>
      Stream.fromIterable(scanResults);

  @override
  Future<void> stopScan() async => stopScanCalls++;

  @override
  Future<OmiDevice?> connect(DiscoveredDevice device) async {
    connectCalls.add(device);
    if (!connectSucceeds) return null;
    // A real device reports its own platform name even when the scan entry
    // carried none, which is the fallback `DeviceManager.connect` relies on.
    _device = FakeOmiDevice(
      const [],
      id: device.id,
      name: device.name.isEmpty ? 'Name from device' : device.name,
    );
    await _device!.startAudioStream();
    setState(DeviceConnectionState.connected);
    return _device;
  }

  @override
  Future<bool> armSavedDevice(String deviceId) async {
    armCalls.add(deviceId);
    return armSucceeds;
  }

  @override
  OmiDevice? get currentDevice =>
      _state == DeviceConnectionState.connected ? _device : null;

  @override
  Stream<DeviceConnectionState> get connectionState => _stateController.stream;

  @override
  DeviceConnectionState get state => _state;

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    setState(DeviceConnectionState.disconnected);
  }

  int disposeCalls = 0;

  @override
  Future<void> dispose() async => disposeCalls++;

  /// Drives a state change, as the real stack would.
  void setState(DeviceConnectionState state) {
    _state = state;
    _stateController.add(state);
  }

  /// Connects without going through [connect], for tests that only care
  /// about the connected-device wiring.
  void bringUp(FakeOmiDevice device) {
    _device = device;
    setState(DeviceConnectionState.connected);
  }

  Future<void> close() => _stateController.close();
}

/// Records what it was asked to capture.
class RecordingCapture implements BleSessionCapture {
  final List<String> started = [];
  int stopped = 0;

  @override
  Future<void> start(OmiDevice device) async => started.add(device.id);

  @override
  Future<void> stop() async => stopped++;
}

void main() {
  late FakeOmiDeviceHost host;
  late MapSavedDeviceStore saved;

  DeviceManager build({BleSessionCapture? capture}) => DeviceManager(
        host: host,
        savedDevices: saved,
        capture: capture,
      );

  setUp(() {
    host = FakeOmiDeviceHost();
    saved = MapSavedDeviceStore();
  });

  tearDown(() async {
    await host.close();
  });

  group('scanning', () {
    test('forwards the host scan results', () async {
      const found = DiscoveredDevice(id: 'aa:bb', name: 'Omi', rssi: -50);
      host = FakeOmiDeviceHost(scanResults: const [
        <DiscoveredDevice>[],
        [found],
      ]);
      final manager = build();

      final batches = await manager.scanForDevices().toList();

      expect(batches, [
        <DiscoveredDevice>[],
        [found],
      ]);
      await manager.dispose();
    });

    test('stopScan reaches the host', () async {
      final manager = build();
      await manager.stopScan();
      expect(host.stopScanCalls, 1);
      await manager.dispose();
    });
  });

  group('saved device', () {
    const discovered = DiscoveredDevice(id: 'aa:bb:cc', name: 'Omi DevKit', rssi: -42);

    test('a successful connect records the device as the saved one', () async {
      final manager = build();

      expect(await manager.connect(discovered), isTrue);

      expect(saved.savedDeviceId, 'aa:bb:cc');
      expect(saved.savedDeviceName, 'Omi DevKit');
      expect(host.connectCalls.single, discovered);
      await manager.dispose();
    });

    test('a failed connect leaves the saved device untouched', () async {
      saved.savedDeviceId = 'previous';
      saved.savedDeviceName = 'Previous Omi';
      host.connectSucceeds = false;
      final manager = build();

      expect(await manager.connect(discovered), isFalse);

      expect(saved.savedDeviceId, 'previous');
      expect(saved.savedDeviceName, 'Previous Omi');
      await manager.dispose();
    });

    test('an unnamed scan result falls back to the device name', () async {
      final manager = build();

      await manager.connect(
        const DiscoveredDevice(id: 'aa:bb:cc', name: '', rssi: -42),
      );

      expect(saved.savedDeviceName, 'Name from device');
      await manager.dispose();
    });

    test('connectToSavedDevice arms the stored id', () async {
      saved.savedDeviceId = 'stored-id';
      final manager = build();

      expect(await manager.connectToSavedDevice(), isTrue);
      expect(host.armCalls, ['stored-id']);
      await manager.dispose();
    });

    test('connectToSavedDevice does nothing without a saved device', () async {
      final manager = build();

      expect(await manager.connectToSavedDevice(), isFalse);
      expect(host.armCalls, isEmpty);
      await manager.dispose();
    });

    test('connectToSavedDevice reports a refused arm', () async {
      saved.savedDeviceId = 'stored-id';
      host.armSucceeds = false;
      final manager = build();

      expect(await manager.connectToSavedDevice(), isFalse);
      await manager.dispose();
    });
  });

  group('connection-independent streams', () {
    test('forward the connected device and survive a reconnect', () async {
      final manager = build();
      final audio = <Uint8List>[];
      final buttons = <ButtonEvent>[];
      final battery = <int>[];
      manager.audioPackets.listen(audio.add);
      manager.buttonEvents.listen(buttons.add);
      manager.batteryLevel.listen(battery.add);

      final first = FakeOmiDevice(const []);
      await first.startAudioStream();
      host.bringUp(first);
      first.emit(CaptureChannel.audio, Uint8List.fromList([0, 0, 0, 9]));
      first.emit(CaptureChannel.button, Uint8List.fromList([1, 0, 0, 0]));
      first.emit(CaptureChannel.battery, Uint8List.fromList([77]));

      host.setState(DeviceConnectionState.disconnected);
      // Nothing from a device that is gone.
      first.emit(CaptureChannel.audio, Uint8List.fromList([0, 0, 0, 99]));

      final second = FakeOmiDevice(const [], id: 'second');
      await second.startAudioStream();
      host.bringUp(second);
      second.emit(CaptureChannel.audio, Uint8List.fromList([1, 0, 0, 5]));
      second.emit(CaptureChannel.button, Uint8List.fromList([2, 0, 0, 0]));

      expect(audio.map((p) => p.last), [9, 5]);
      expect(buttons, [ButtonEvent.singleTap, ButtonEvent.doubleTap]);
      expect(battery, [77]);
      await manager.dispose();
    });

    test('attach to a host that is already connected at construction', () async {
      final device = FakeOmiDevice(const []);
      await device.startAudioStream();
      host.bringUp(device);

      final manager = build();
      final audio = <Uint8List>[];
      manager.audioPackets.listen(audio.add);

      device.emit(CaptureChannel.audio, Uint8List.fromList([0, 0, 0, 3]));

      expect(audio, hasLength(1));
      await manager.dispose();
    });
  });

  group('session capture', () {
    test('starts on connect and stops on disconnect', () async {
      final capture = RecordingCapture();
      final manager = build(capture: capture);

      host.bringUp(FakeOmiDevice(const [], id: 'captured'));
      await Future<void>.delayed(Duration.zero);
      expect(capture.started, ['captured']);

      host.setState(DeviceConnectionState.disconnected);
      await Future<void>.delayed(Duration.zero);
      expect(capture.stopped, 1);

      await manager.dispose();
    });
  });

  test('state and isConnected mirror the host', () async {
    final manager = build();
    expect(manager.isConnected, isFalse);
    expect(manager.state, DeviceConnectionState.disconnected);

    host.bringUp(FakeOmiDevice(const []));
    expect(manager.isConnected, isTrue);
    expect(manager.current, isNotNull);

    await manager.disconnect();
    expect(manager.isConnected, isFalse);
    expect(host.disconnectCalls, 1);
    await manager.dispose();
    expect(host.disposeCalls, 1);
  });
}
