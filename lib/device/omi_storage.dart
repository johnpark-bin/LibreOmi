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
/// - [rawPackets] is the untouched byte stream, kept for the debug BLE
///   session capture (`ble_session_capture.dart`) and for hand-inspecting a
///   transfer. Since LO-50 no transfer code uses it: the sync service reads
///   [packets] and drives `services/sdcard_transfer.dart`.
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

  /// Asks the device to stop the transfer that is currently in flight
  /// (command 3, sent as a bare `0x03` byte rather than the 6-byte read/clear
  /// payload). Returns false when the write could not be made.
  ///
  /// Sending this is what lets a cancelled sync leave the device idle instead
  /// of streaming into a listener that is gone.
  Future<bool> stopRead();

  /// Acknowledges the transferred data and clears it from the device
  /// (command 1).
  Future<bool> clear({int fileNumber = 1});

  /// Raw storage notification payloads, exactly as received.
  Stream<List<int>> get rawPackets;

  /// [rawPackets] decoded with [parseStoragePacket].
  Stream<StoragePacket> get packets;
}
