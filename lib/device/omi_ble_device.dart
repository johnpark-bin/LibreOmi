/// The BLE adapter over `services/ble_service.dart`.
///
/// This is the only file in `lib/device/` allowed to import
/// `package:flutter_blue_plus/...` or `../services/ble_service.dart`: it is
/// where the transport-independent `device/` contract
/// ([OmiDevice], [OmiStorage], [OmiDeviceHost]) meets the concrete BLE stack.
/// `docs/03-architecture.md` §1-2.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../services/ble_service.dart';
import 'device_manager.dart';
import 'omi_device.dart';
import 'omi_storage.dart';

/// [OmiDevice] backed by a live [BleService] connection.
///
/// `BleService` is a process-lifetime singleton, so this adapter never calls
/// `BleService.dispose()` (a no-op today, kept that way deliberately — see
/// its doc comment) or tears down the service itself. [dispose] only cleans
/// up the resources this adapter owns (its own stream subscriptions and
/// controllers).
class OmiBleDevice implements OmiDevice {
  OmiBleDevice([BleService? ble]) : _ble = ble ?? BleService() {
    _batterySubscription = _ble.batteryStream.listen(_batteryController.add);
  }

  final BleService _ble;

  final StreamController<int> _batteryController =
      StreamController<int>.broadcast();
  StreamSubscription<int>? _batterySubscription;

  Stream<ButtonEvent>? _buttonEvents;

  OmiBleStorage? _storage;

  @override
  String get id => _ble.connectedDeviceId ?? '';

  @override
  String get name => _ble.connectedDeviceName ?? '';

  @override
  Stream<DeviceConnectionState> get connectionState => _ble.stateStream;

  @override
  DeviceConnectionState get state => _ble.state;

  @override
  Stream<Uint8List> get audioPackets => _ble.audioStream;

  @override
  Stream<ButtonEvent> get buttonEvents => _buttonEvents ??= _ble.buttonStream
      .map(parseButtonEvent)
      .where((event) => event != null)
      .cast<ButtonEvent>();

  @override
  Stream<int> get batteryLevel => _batteryController.stream;

  @override
  Future<void> startAudioStream() => _ble.startAudioStream();

  @override
  Future<void> stopAudioStream() => _ble.stopAudioStream();

  @override
  Future<BleAudioCodec> readCodec() => _ble.getAudioCodec();

  /// Builds a [DeviceInfo] from `BleService.getDeviceInfo()`, re-decoding
  /// each value with [decodeDeviceInfoString].
  ///
  /// `BleService` decodes these characteristics with
  /// `String.fromCharCodes`, which maps every byte 0-255 straight onto the
  /// code unit of the same value. That mapping is lossless and reversible:
  /// `string.codeUnits` gives back exactly the bytes the device sent, so the
  /// UTF-8 decode plus trailing-NUL strip that [decodeDeviceInfoString]
  /// performs can still be applied here rather than waiting for the
  /// characteristic reads to move out of `BleService` (LO-34).
  ///
  /// This is the deliberate behaviour change [decodeDeviceInfoString]'s own
  /// doc comment calls out: multi-byte UTF-8 now decodes correctly and
  /// trailing NULs no longer leak into the UI. Nothing in `lib/` read device
  /// info before LO-31, so no existing screen changes.
  @override
  Future<DeviceInfo> readDeviceInfo() async {
    final info = await _ble.getDeviceInfo();
    String decode(String? value) =>
        value == null ? '' : decodeDeviceInfoString(value.codeUnits);
    return DeviceInfo(
      model: decode(info['Model']),
      firmware: decode(info['Firmware']),
      hardware: decode(info['Hardware']),
      manufacturer: decode(info['Manufacturer']),
    );
  }

  @override
  Future<int?> readBatteryLevel() async {
    final level = await _ble.getBatteryLevel();
    if (level != null) _batteryController.add(level);
    return level;
  }

  @override
  Future<int?> readMicGain() => _ble.getMicGain();

  @override
  Future<void> writeMicGain(int value) => _ble.setMicGain(value);

  @override
  Future<int?> readLedDim() => _ble.getLedDimRatio();

  @override
  Future<void> writeLedDim(int value) => _ble.setLedDimRatio(value);

  @override
  Future<void> haptic(HapticLevel level) => _ble.triggerHaptic(level.code);

  /// Always non-null: whether the firmware actually has the storage service
  /// is discovered by calling [OmiStorage.list], which returns `[]` when the
  /// storage control characteristic is missing — exactly how
  /// `DeviceController._checkStorageSupport()` decides today via
  /// `BleService.hasStorageSupport()`. Returning a live object unconditionally
  /// keeps that decision where the actual GATT lookup happens instead of
  /// duplicating it here.
  @override
  OmiStorage get storage => _storage ??= OmiBleStorage(_ble);

  @override
  Future<void> disconnect() => _ble.disconnect();

  /// Cancels the subscriptions and closes the controllers this adapter owns.
  /// Does NOT call `BleService.dispose()` — the service is a process-lifetime
  /// singleton and its `dispose()` is a deliberate no-op.
  Future<void> dispose() async {
    await _batterySubscription?.cancel();
    _batterySubscription = null;
    await _batteryController.close();
  }
}

/// [OmiStorage] backed by a live [BleService] connection.
class OmiBleStorage implements OmiStorage {
  OmiBleStorage(this._ble);

  final BleService _ble;

  @override
  Future<List<int>> list() => _ble.getStorageList();

  @override
  Future<void> startStream() async {
    await _ble.startStorageStream();
  }

  @override
  Future<void> stopStream() => _ble.stopStorageStream();

  @override
  Future<bool> startRead(int offset, {int fileNumber = 1}) =>
      _ble.writeToStorage(fileNumber, 0, offset);

  @override
  Future<bool> stopRead() => _ble.writeStorageStop();

  @override
  Future<bool> clear({int fileNumber = 1}) =>
      _ble.writeToStorage(fileNumber, 1, 0);

  @override
  Stream<List<int>> get rawPackets => _ble.storageStream;

  @override
  Stream<StoragePacket> get packets => rawPackets.map(parseStoragePacket);
}

/// [OmiDeviceHost] backed by a live [BleService] connection.
///
/// Owns one [OmiBleDevice], created lazily and reused for the lifetime of
/// this host so `currentDevice` identity stays stable across reconnects.
class BleDeviceHost implements OmiDeviceHost {
  BleDeviceHost([BleService? ble]) : _ble = ble ?? BleService();

  final BleService _ble;

  final Map<String, BleDevice> _seen = <String, BleDevice>{};

  OmiBleDevice? _device;

  @override
  Stream<List<DiscoveredDevice>> scanForDevices({
    Duration timeout = const Duration(seconds: 15),
  }) {
    return _ble.scanForDevices(timeout: timeout).map((devices) {
      for (final device in devices) {
        _seen[device.device.remoteId.str] = device;
      }
      return devices
          .map((device) => DiscoveredDevice(
                id: device.device.remoteId.str,
                name: device.name,
                rssi: device.rssi,
              ))
          .toList();
    });
  }

  @override
  Future<void> stopScan() => _ble.stopScan();

  @override
  Future<OmiDevice?> connect(DiscoveredDevice device) async {
    final bluetoothDevice =
        _seen[device.id]?.device ?? BluetoothDevice.fromId(device.id);
    final connected = await _ble.connect(bluetoothDevice);
    if (!connected) return null;
    return _device ??= OmiBleDevice(_ble);
  }

  @override
  Future<bool> armSavedDevice(String deviceId) =>
      _ble.connectToSavedDevice(deviceId);

  @override
  OmiDevice? get currentDevice => _ble.isConnected ? (_device ??= OmiBleDevice(_ble)) : null;

  @override
  Stream<DeviceConnectionState> get connectionState => _ble.stateStream;

  @override
  DeviceConnectionState get state => _ble.state;

  @override
  Future<void> disconnect() => _ble.disconnect();

  /// Releases the adapter this host handed out and the scan cache. The
  /// `BleService` singleton and any live radio link are left alone — the
  /// process may still be connected after the owning provider goes away.
  @override
  Future<void> dispose() async {
    final device = _device;
    _device = null;
    _seen.clear();
    await device?.dispose();
  }
}
