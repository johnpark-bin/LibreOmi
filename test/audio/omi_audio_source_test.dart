import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/audio/audio_source.dart';
import 'package:libreomi/audio/omi_audio_source.dart';

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
  });
}
