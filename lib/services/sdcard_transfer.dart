/// Pure, timer-free, IO-free state machine for the SD-card transfer.
///
/// This mirrors the byte-accounting and progress/ETA formulas currently
/// inlined in `SdCardSyncService._performSync` (see
/// lib/services/sdcard_sync_service.dart), so that unit U3 of LO-50 can
/// port that loop onto this class without changing observable behaviour.
///
/// See docs/05-omi-ble-protocol.md "Storage (SD card) protocol" for the
/// packet shapes this consumes via [StoragePacket]/[parseStoragePacket].
library;

import 'dart:typed_data';

import '../device/omi_gatt.dart';

/// What happened as a result of feeding one [StoragePacket] into
/// [SdCardTransfer.feed].
enum TransferOutcome {
  /// A non-terminal packet was consumed (an audio/multi-frame packet, an
  /// unknown packet, or a [StorageStatus.ready] status packet).
  continuing,

  /// The device reported [StorageStatus.transferComplete] (status code 100).
  complete,

  /// The device reported [StorageStatus.fileEmpty] (status code 4).
  empty,

  /// The device reported [StorageStatus.badFileSize] (status code 3),
  /// [StorageStatus.error], or any other terminal failure.
  failed,
}

/// Tracks the state of a single SD-card transfer: bytes consumed, the
/// Opus frames accumulated so far, and progress/ETA derived from those.
///
/// Deliberately has no timers and does no IO — callers own the BLE
/// subscription and the wall clock; this class only reacts to parsed
/// packets and reports elapsed-time-based ETAs when asked.
class SdCardTransfer {
  /// Bytes already consumed on the device before this transfer started.
  final int startOffset;

  /// Total bytes the device reports for the file being transferred.
  final int totalBytes;

  /// Bytes remaining to sync: `totalBytes - startOffset`. May be `<= 0` for
  /// a degenerate/empty transfer; callers should treat that as "nothing to
  /// do" rather than an error.
  final int bytesToSync;

  final List<Uint8List> _frames = [];

  int _bytesReceived = 0;
  int? _lastStatusCode;
  bool _hasReceivedData = false;

  SdCardTransfer({required this.startOffset, required this.totalBytes})
      : bytesToSync = totalBytes - startOffset;

  /// Opus frames accumulated so far, in arrival order. Unmodifiable view
  /// over the internal accumulator.
  List<Uint8List> get frames => List.unmodifiable(_frames);

  /// Bytes consumed since [startOffset], per the accounting below.
  int get bytesReceived => _bytesReceived;

  /// The most recent raw status byte seen via a status packet, if any.
  /// Kept around purely for logging by callers.
  int? get lastStatusCode => _lastStatusCode;

  /// True once any non-status packet has been fed. Callers use this to
  /// decide whether the "no data within N seconds" timeout should fire.
  bool get hasReceivedData => _hasReceivedData;

  /// Fraction of [bytesToSync] received so far, clamped to `0.0..1.0`.
  ///
  /// Monotonically non-decreasing across calls to [feed] even if
  /// [bytesReceived] were ever to move backwards (it doesn't in normal
  /// operation, but this keeps the invariant explicit and cheap to hold).
  ///
  /// When [bytesToSync] is `<= 0` there is nothing to sync, so this
  /// returns `1.0` (transfer is trivially "complete") rather than
  /// dividing by zero.
  ///
  /// [bytesReceived] only ever increases as packets are fed (frames are
  /// never un-counted), so this is monotonically non-decreasing by
  /// construction — no extra state is needed to enforce it.
  double get progress {
    if (bytesToSync <= 0) return 1.0;
    final raw = _bytesReceived / bytesToSync;
    return raw.clamp(0.0, 1.0);
  }

  /// Estimated seconds remaining, given how much wall-clock time has
  /// elapsed since the transfer started. Pure function of [elapsed] and
  /// the current [progress] — no timers are read internally.
  ///
  /// Returns `null` when [progress] is `0` or [elapsed] is zero, since
  /// neither case yields a meaningful rate. Otherwise matches the
  /// existing service's formula:
  /// `((elapsedSeconds / progress) * (1 - progress)).round()`.
  int? etaSeconds(Duration elapsed) {
    final elapsedSeconds = elapsed.inSeconds;
    final p = progress;
    if (elapsedSeconds <= 0 || p <= 0) return null;
    return ((elapsedSeconds / p) * (1 - p)).round();
  }

  /// Consumes one parsed [StoragePacket], updating frames/byte-accounting
  /// as appropriate, and returns the resulting [TransferOutcome].
  ///
  /// Byte accounting (matches `SdCardSyncService._performSync` exactly):
  /// - [StoragePacketKind.audioFrame]: appends the single frame, advances
  ///   [bytesReceived] by 80 (the fixed payload size of the 83-byte
  ///   packet's data region, not the declared frame length).
  /// - [StoragePacketKind.multiFrame]: appends every frame parsed out of
  ///   the packet, advances [bytesReceived] by 440 (the full packet size).
  /// - [StoragePacketKind.unknown]: ignored entirely — no frame appended,
  ///   no offset advance.
  /// - [StoragePacketKind.status]: no byte accounting; the raw code is
  ///   recorded in [lastStatusCode] and mapped to a [TransferOutcome].
  TransferOutcome feed(StoragePacket packet) {
    switch (packet.kind) {
      case StoragePacketKind.status:
        _lastStatusCode = packet.rawCode;
        switch (packet.status!) {
          case StorageStatus.ready:
            return TransferOutcome.continuing;
          case StorageStatus.transferComplete:
            return TransferOutcome.complete;
          case StorageStatus.fileEmpty:
            return TransferOutcome.empty;
          case StorageStatus.badFileSize:
          case StorageStatus.error:
            return TransferOutcome.failed;
        }
      case StoragePacketKind.audioFrame:
        _hasReceivedData = true;
        _frames.add(packet.frame!);
        _bytesReceived += 80;
        return TransferOutcome.continuing;
      case StoragePacketKind.multiFrame:
        _hasReceivedData = true;
        _frames.addAll(packet.frames!);
        _bytesReceived += 440;
        return TransferOutcome.continuing;
      case StoragePacketKind.unknown:
        _hasReceivedData = true;
        return TransferOutcome.continuing;
    }
  }
}
