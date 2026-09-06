/// The transport-independent view of an Omi wearable.
///
/// `docs/03-architecture.md` §2 defines this interface. Everything above the
/// `device/` layer (session, providers, pages) talks to an [OmiDevice] rather
/// than to `flutter_blue_plus` or to `services/ble_service.dart`, so the same
/// code path can be driven by a real device (`omi_ble_device.dart`) or by a
/// recorded session (`fake_omi_device.dart`).
library;

import 'dart:typed_data';

import 'omi_gatt.dart';
import 'omi_storage.dart';

/// Connection state of the link to the wearable.
///
/// Defined here rather than in `services/ble_service.dart` because it is part
/// of the `device/` contract; `ble_service.dart` re-exports it so its existing
/// importers keep compiling.
enum DeviceConnectionState {
  disconnected,
  connecting,
  connected,
}

/// The strings the Device Information service exposes
/// (`docs/05-omi-ble-protocol.md`). Every field is `''` when the device did
/// not answer for it.
class DeviceInfo {
  const DeviceInfo({
    this.model = '',
    this.firmware = '',
    this.hardware = '',
    this.manufacturer = '',
  });

  final String model;
  final String firmware;
  final String hardware;
  final String manufacturer;

  bool get isEmpty =>
      model.isEmpty &&
      firmware.isEmpty &&
      hardware.isEmpty &&
      manufacturer.isEmpty;

  /// The shape the upstream UI expects: only the fields the device answered
  /// for, keyed by their display labels.
  Map<String, String> toMap() => {
        if (model.isNotEmpty) 'Model': model,
        if (firmware.isNotEmpty) 'Firmware': firmware,
        if (hardware.isNotEmpty) 'Hardware': hardware,
        if (manufacturer.isNotEmpty) 'Manufacturer': manufacturer,
      };

  @override
  String toString() => 'DeviceInfo(${toMap()})';
}

/// Haptic pulse lengths the Omi speaker service accepts. The wire value is
/// [code] (see `docs/05-omi-ble-protocol.md` "Speaker"): 1 = 20 ms,
/// 2 = 50 ms, 3 = 500 ms.
enum HapticLevel {
  short(1),
  medium(2),
  long(3);

  const HapticLevel(this.code);

  final int code;
}

/// One connected Omi wearable.
///
/// Streams are broadcast streams and stay alive for the lifetime of the
/// device object. Reads return `null` (or an empty/default value) rather than
/// throwing when the characteristic is missing, matching the upstream
/// behaviour the adapters wrap.
abstract class OmiDevice {
  /// Platform device identifier (the BLE remote id for a real device).
  String get id;

  /// Advertised device name, `''` when unknown.
  String get name;

  Stream<DeviceConnectionState> get connectionState;

  /// The current state, for callers that need it without waiting for the
  /// next event.
  DeviceConnectionState get state;

  /// Raw audio notification payloads, header included. Consumers strip the
  /// header with [stripAudioHeader] (see `audio/omi_audio_source.dart`).
  Stream<Uint8List> get audioPackets;

  /// Button notifications, already decoded with [parseButtonEvent].
  /// Undecodable payloads are dropped rather than surfaced.
  Stream<ButtonEvent> get buttonEvents;

  /// Battery percentages. Emits whenever a level becomes known — including
  /// the result of a [readBatteryLevel] call — so a UI can subscribe instead
  /// of polling.
  Stream<int> get batteryLevel;

  /// Subscribes to the audio characteristic so [audioPackets] starts
  /// delivering. Not called implicitly: the session decides when audio flows.
  Future<void> startAudioStream();

  /// Unsubscribes from the audio characteristic. [audioPackets] stays open.
  Future<void> stopAudioStream();

  Future<BleAudioCodec> readCodec();

  Future<DeviceInfo> readDeviceInfo();

  /// Latest battery percentage, or `null` when unavailable. Also emitted on
  /// [batteryLevel].
  Future<int?> readBatteryLevel();

  Future<int?> readMicGain();
  Future<void> writeMicGain(int value);

  Future<int?> readLedDim();
  Future<void> writeLedDim(int value);

  Future<void> haptic(HapticLevel level);

  /// The SD-card transport, or `null` when the firmware lacks the storage
  /// service.
  OmiStorage? get storage;

  Future<void> disconnect();
}
