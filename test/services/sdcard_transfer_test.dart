import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/device/omi_gatt.dart';
import 'package:libreomi/services/sdcard_transfer.dart';

/// Builds a raw 83-byte storage audio-frame packet:
/// `[hdr0][hdr1][hdr2][len][data(len)...]` padded to 83 bytes.
List<int> _buildAudioFramePacket(List<int> data) {
  final raw = List<int>.filled(83, 0);
  raw[3] = data.length;
  for (var i = 0; i < data.length; i++) {
    raw[4 + i] = data[i];
  }
  return raw;
}

/// Builds a raw 440-byte multi-frame storage packet out of the given
/// frames, each encoded as `[len][data(len)]`, left-padded with zero
/// bytes (interpreted as `len == 0` padding records) to fill 440 bytes.
List<int> _buildMultiFramePacket(List<List<int>> frames) {
  final raw = List<int>.filled(440, 0);
  var offset = 0;
  for (final frame in frames) {
    raw[offset] = frame.length;
    for (var i = 0; i < frame.length; i++) {
      raw[offset + 1 + i] = frame[i];
    }
    offset += frame.length + 1;
  }
  return raw;
}

void main() {
  group('SdCardTransfer status handling', () {
    test('ready status continues and records raw code', () {
      final transfer = SdCardTransfer(startOffset: 0, totalBytes: 1000);
      final outcome = transfer.feed(parseStoragePacket([0]));
      expect(outcome, TransferOutcome.continuing);
      expect(transfer.lastStatusCode, 0);
    });

    test('transferComplete status (100) completes', () {
      final transfer = SdCardTransfer(startOffset: 0, totalBytes: 1000);
      final outcome = transfer.feed(parseStoragePacket([100]));
      expect(outcome, TransferOutcome.complete);
      expect(transfer.lastStatusCode, 100);
    });

    test('fileEmpty status (4) is empty', () {
      final transfer = SdCardTransfer(startOffset: 0, totalBytes: 1000);
      final outcome = transfer.feed(parseStoragePacket([4]));
      expect(outcome, TransferOutcome.empty);
      expect(transfer.lastStatusCode, 4);
    });

    test('badFileSize status (3) fails', () {
      final transfer = SdCardTransfer(startOffset: 0, totalBytes: 1000);
      final outcome = transfer.feed(parseStoragePacket([3]));
      expect(outcome, TransferOutcome.failed);
      expect(transfer.lastStatusCode, 3);
    });

    test('unrecognised status code fails and is preserved', () {
      final transfer = SdCardTransfer(startOffset: 0, totalBytes: 1000);
      final outcome = transfer.feed(parseStoragePacket([77]));
      expect(outcome, TransferOutcome.failed);
      expect(transfer.lastStatusCode, 77);
    });
  });

  group('SdCardTransfer audio-frame accounting', () {
    test('83-byte packet appends one frame and advances by 80', () {
      final transfer = SdCardTransfer(startOffset: 0, totalBytes: 1000);
      final raw = _buildAudioFramePacket([1, 2, 3, 4, 5]);
      final packet = parseStoragePacket(raw);
      expect(packet.kind, StoragePacketKind.audioFrame);

      final outcome = transfer.feed(packet);

      expect(outcome, TransferOutcome.continuing);
      expect(transfer.frames, hasLength(1));
      expect(transfer.frames.single, Uint8List.fromList([1, 2, 3, 4, 5]));
      expect(transfer.bytesReceived, 80);
      expect(transfer.hasReceivedData, isTrue);
    });

    test('440-byte packet appends every frame and advances by 440', () {
      final transfer = SdCardTransfer(startOffset: 0, totalBytes: 1000);
      final raw = _buildMultiFramePacket([
        [10, 11, 12],
        [20, 21],
        [30],
      ]);
      final packet = parseStoragePacket(raw);
      expect(packet.kind, StoragePacketKind.multiFrame);

      final outcome = transfer.feed(packet);

      expect(outcome, TransferOutcome.continuing);
      expect(transfer.frames, hasLength(3));
      expect(transfer.frames[0], Uint8List.fromList([10, 11, 12]));
      expect(transfer.frames[1], Uint8List.fromList([20, 21]));
      expect(transfer.frames[2], Uint8List.fromList([30]));
      expect(transfer.bytesReceived, 440);
    });

    test('unknown-length packet changes nothing', () {
      final transfer = SdCardTransfer(startOffset: 0, totalBytes: 1000);
      final packet = parseStoragePacket(List<int>.filled(7, 0));
      expect(packet.kind, StoragePacketKind.unknown);

      final outcome = transfer.feed(packet);

      expect(outcome, TransferOutcome.continuing);
      expect(transfer.frames, isEmpty);
      expect(transfer.bytesReceived, 0);
    });
  });

  group('SdCardTransfer progress', () {
    test('is monotonically non-decreasing and clamps at 1.0', () {
      final transfer = SdCardTransfer(startOffset: 0, totalBytes: 200);
      final progressReadings = <double>[];

      // 2 audio frames (+80 each) then a multi-frame packet (+440) that
      // overshoots the declared total.
      progressReadings.add(transfer.progress);
      transfer.feed(parseStoragePacket(_buildAudioFramePacket([1])));
      progressReadings.add(transfer.progress);
      transfer.feed(parseStoragePacket(_buildAudioFramePacket([2])));
      progressReadings.add(transfer.progress);
      transfer.feed(parseStoragePacket(_buildMultiFramePacket([
        [1, 2, 3],
      ])));
      progressReadings.add(transfer.progress);

      for (var i = 1; i < progressReadings.length; i++) {
        expect(progressReadings[i], greaterThanOrEqualTo(progressReadings[i - 1]));
      }
      expect(progressReadings.last, 1.0);
      expect(transfer.bytesReceived, 80 + 80 + 440);
    });

    test('bytesToSync <= 0 does not throw and reports full progress', () {
      final zero = SdCardTransfer(startOffset: 500, totalBytes: 500);
      expect(zero.bytesToSync, 0);
      expect(() => zero.progress, returnsNormally);
      expect(zero.progress, 1.0);

      final negative = SdCardTransfer(startOffset: 900, totalBytes: 500);
      expect(negative.bytesToSync, lessThan(0));
      expect(() => negative.progress, returnsNormally);
      expect(negative.progress, 1.0);

      // Feeding packets afterwards must not throw either.
      expect(
        () => negative.feed(parseStoragePacket(_buildAudioFramePacket([1]))),
        returnsNormally,
      );
      expect(negative.progress, 1.0);
    });
  });

  group('SdCardTransfer etaSeconds', () {
    test('is null when no progress has been made', () {
      final transfer = SdCardTransfer(startOffset: 0, totalBytes: 1000);
      expect(transfer.etaSeconds(const Duration(seconds: 10)), isNull);
    });

    test('is null when elapsed is zero even with progress', () {
      final transfer = SdCardTransfer(startOffset: 0, totalBytes: 100);
      transfer.feed(parseStoragePacket(_buildAudioFramePacket([1])));
      expect(transfer.etaSeconds(Duration.zero), isNull);
    });

    test('computes a concrete value matching the existing formula', () {
      final transfer = SdCardTransfer(startOffset: 0, totalBytes: 400);
      // 80 bytes received out of 400 => progress = 0.2
      transfer.feed(parseStoragePacket(_buildAudioFramePacket([1])));
      expect(transfer.progress, closeTo(0.2, 1e-9));

      final elapsed = const Duration(seconds: 10);
      final eta = transfer.etaSeconds(elapsed);
      // ((10 / 0.2) * (1 - 0.2)).round() == (50 * 0.8).round() == 40
      expect(eta, 40);
    });
  });
}
