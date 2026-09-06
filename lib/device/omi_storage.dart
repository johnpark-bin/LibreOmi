/// The SD-card (storage) sub-interface of an Omi wearable.
///
/// `docs/03-architecture.md` §2 hangs this off `OmiDevice.storage`. The
/// protocol itself is documented in `docs/05-omi-ble-protocol.md` "Storage
/// (SD card) protocol"; the parsers live in `omi_gatt.dart`.
library;

import 'omi_gatt.dart';

/// Reads and clears the wearable's on-device recordings.
///
/// Two views of the same notifications are exposed on purpose:
///
/// - [packets] is the interface `docs/03` §2 describes and what new code
///   should use.
/// - [rawPackets] is the untouched byte stream. `services/sdcard_sync_service.dart`
///   still switches on notification lengths itself; porting that transfer
///   loop onto [packets] is LO-50 (M5), and doing it here would have meant
///   rewriting the one path LO-31 cannot verify without hardware.
abstract class OmiStorage {
  /// `[totalBytes, offset]` as reported by the storage control
  /// characteristic, or `[]` when the device has no storage service.
  Future<List<int>> list();

  /// Subscribes to the storage data characteristic so [rawPackets] and
  /// [packets] start delivering.
  Future<void> startStream();

  /// Unsubscribes from the storage data characteristic.
  Future<void> stopStream();

  /// Asks the device to start sending file [fileNumber] from [offset]
  /// (command 0). Returns false when the write could not be made.
  Future<bool> startRead(int offset, {int fileNumber = 1});

  /// Acknowledges the transferred data and clears it from the device
  /// (command 1).
  Future<bool> clear({int fileNumber = 1});

  /// Raw storage notification payloads, exactly as received.
  Stream<List<int>> get rawPackets;

  /// [rawPackets] decoded with [parseStoragePacket].
  Stream<StoragePacket> get packets;
}
