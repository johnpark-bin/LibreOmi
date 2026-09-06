import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/audio/audio_source.dart';
import 'package:libreomi/audio/omi_audio_source.dart';
import 'package:libreomi/core/log.dart';

void main() {
  group('OmiAudioSource', () {
    late StreamController<Uint8List> rawPackets;

    setUp(() {
      rawPackets = StreamController<Uint8List>.broadcast();
    });

    tearDown(() async {
      await rawPackets.close();
    });

    test('strips the 3-byte Omi header from a packet', () async {
      final source = OmiAudioSource(rawPackets.stream);
      final chunks = <AudioChunk>[];
      final sub = source.start().listen(chunks.add);

      rawPackets.add(Uint8List.fromList([0, 0, 0, 10, 20, 30]));
      await Future<void>.delayed(Duration.zero);

      expect(chunks, hasLength(1));
      expect(chunks.single.bytes, Uint8List.fromList([10, 20, 30]));

      await sub.cancel();
      await source.stop();
    });

    test('drops packets of length 3 or shorter', () async {
      final source = OmiAudioSource(rawPackets.stream);
      final chunks = <AudioChunk>[];
      final sub = source.start().listen(chunks.add);

      rawPackets.add(Uint8List.fromList([1, 2, 3]));
      rawPackets.add(Uint8List.fromList([1, 2]));
      await Future<void>.delayed(Duration.zero);

      expect(chunks, isEmpty);

      await sub.cancel();
      await source.stop();
    });

    test('emits the configured encoding and the injected clock', () async {
      final fixedTime = DateTime(2026, 1, 1, 12);
      final source = OmiAudioSource(
        rawPackets.stream,
        encoding: AudioEncoding.pcm16,
        now: () => fixedTime,
      );
      final chunks = <AudioChunk>[];
      final sub = source.start().listen(chunks.add);

      rawPackets.add(Uint8List.fromList([0, 0, 0, 10]));
      await Future<void>.delayed(Duration.zero);

      expect(chunks.single.encoding, AudioEncoding.pcm16);
      expect(chunks.single.at, fixedTime);

      await sub.cancel();
      await source.stop();
    });

    test('emits no event after stop()', () async {
      final source = OmiAudioSource(rawPackets.stream);
      final chunks = <AudioChunk>[];
      source.start().listen(chunks.add);

      await source.stop();
      rawPackets.add(Uint8List.fromList([0, 0, 0, 10]));
      await Future<void>.delayed(Duration.zero);

      expect(chunks, isEmpty);
    });

    test('start() after stop() re-subscribes and works again', () async {
      final source = OmiAudioSource(rawPackets.stream);
      final firstChunks = <AudioChunk>[];
      source.start().listen(firstChunks.add);
      await source.stop();

      final secondChunks = <AudioChunk>[];
      final sub = source.start().listen(secondChunks.add);

      rawPackets.add(Uint8List.fromList([0, 0, 0, 42]));
      await Future<void>.delayed(Duration.zero);

      expect(firstChunks, isEmpty);
      expect(secondChunks, hasLength(1));
      expect(secondChunks.single.bytes, Uint8List.fromList([42]));

      await sub.cancel();
      await source.stop();
    });
    group('packet gap detection', () {
      late List<String> lines;
      late void Function(String?) previousSink;

      Uint8List packet(int index, [int payload = 7]) => Uint8List.fromList([
            index & 0xFF,
            (index >> 8) & 0xFF,
            0,
            payload,
          ]);

      setUp(() {
        lines = [];
        previousSink = logSink;
        logSink = (message) => lines.add(message ?? '');
      });

      tearDown(() {
        logSink = previousSink;
      });

      test('counts nothing for a contiguous run', () async {
        final source = OmiAudioSource(rawPackets.stream);
        final sub = source.start().listen((_) {});

        for (var i = 0; i < 5; i++) {
          rawPackets.add(packet(i));
        }
        await Future<void>.delayed(Duration.zero);

        expect(source.gapCount, 0);
        expect(lines, isEmpty);

        await sub.cancel();
        await source.stop();
      });

      test('counts and logs a skipped packet index', () async {
        final source = OmiAudioSource(rawPackets.stream);
        final sub = source.start().listen((_) {});

        rawPackets.add(packet(98));
        rawPackets.add(packet(99));
        rawPackets.add(packet(101));
        await Future<void>.delayed(Duration.zero);

        expect(source.gapCount, 1);
        expect(lines.single, contains('expected 100, got 101'));

        await sub.cancel();
        await source.stop();
      });

      test('treats the uint16 wrap as contiguous', () async {
        final source = OmiAudioSource(rawPackets.stream);
        final sub = source.start().listen((_) {});

        rawPackets.add(packet(65535));
        rawPackets.add(packet(0));
        await Future<void>.delayed(Duration.zero);

        expect(source.gapCount, 0);
        expect(lines, isEmpty);

        await sub.cancel();
        await source.stop();
      });

      test('stops logging after maxGapLogs but keeps counting', () async {
        final source = OmiAudioSource(rawPackets.stream);
        final sub = source.start().listen((_) {});

        // Every other index is skipped, so each packet after the first is a gap.
        for (var i = 0; i < 2 * (OmiAudioSource.maxGapLogs + 3); i += 2) {
          rawPackets.add(packet(i));
        }
        await Future<void>.delayed(Duration.zero);

        expect(source.gapCount, OmiAudioSource.maxGapLogs + 2);
        expect(lines, hasLength(OmiAudioSource.maxGapLogs));

        await sub.cancel();
        await source.stop();
      });

      test('start() resets the gap counter', () async {
        final source = OmiAudioSource(rawPackets.stream);
        var sub = source.start().listen((_) {});
        rawPackets.add(packet(0));
        rawPackets.add(packet(5));
        await Future<void>.delayed(Duration.zero);
        expect(source.gapCount, 1);
        await sub.cancel();
        await source.stop();

        sub = source.start().listen((_) {});
        expect(source.gapCount, 0);
        await sub.cancel();
        await source.stop();
      });
    });
  });
}
