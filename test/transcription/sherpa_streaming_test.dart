import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/audio/audio_source.dart';
import 'package:libreomi/models/conversation.dart';
import 'package:libreomi/services/sherpa_service.dart';
import 'package:libreomi/transcription/sherpa_streaming.dart';

/// Subclasses [SherpaService] and overrides its ONNX-touching methods so
/// tests never load a real model.
class _FakeSherpa extends SherpaService {
  _FakeSherpa({super.onTranscript, super.onError});

  final added = <Uint8List>[];
  bool initialized = false;
  bool processing = false;
  bool disposed = false;

  @override
  Future<void> initialize() async {
    initialized = true;
  }

  @override
  void startProcessing() {
    processing = true;
  }

  @override
  void addAudio(Uint8List data) => added.add(data);

  @override
  void stopProcessing() {
    processing = false;
  }

  @override
  void dispose() {
    disposed = true;
  }
}

void main() {
  group('SherpaStreamingTranscriber', () {
    late _FakeSherpa fake;
    late SherpaStreamingTranscriber transcriber;

    SherpaStreamingTranscriber build() {
      return SherpaStreamingTranscriber(
        serviceFactory: ({required onTranscript, required onError}) {
          fake = _FakeSherpa(onTranscript: onTranscript, onError: onError);
          return fake;
        },
      );
    }

    setUp(() {
      transcriber = build();
    });

    test('acceptedEncoding is pcm16', () {
      expect(transcriber.acceptedEncoding, AudioEncoding.pcm16);
    });

    test('one segment callback produces one event', () async {
      await transcriber.start();
      final events = <TranscriptSegment>[];
      transcriber.segments.listen(events.add);

      fake.onTranscript!([
        TranscriptSegment(text: 'hi', speakerId: 0, startTime: 0, endTime: 1),
      ]);

      expect(events, hasLength(1));
      expect(events.single.text, 'hi');
    });

    test('two segment callback produces two events in order', () async {
      await transcriber.start();
      final events = <TranscriptSegment>[];
      transcriber.segments.listen(events.add);

      fake.onTranscript!([
        TranscriptSegment(text: 'a', speakerId: 0, startTime: 0, endTime: 1),
        TranscriptSegment(text: 'b', speakerId: 0, startTime: 1, endTime: 2),
      ]);

      expect(events.map((e) => e.text).toList(), ['a', 'b']);
    });

    test('error callback produces one event on errors', () async {
      await transcriber.start();
      final errors = <String>[];
      transcriber.errors.listen(errors.add);

      fake.onError!('boom');

      expect(errors, ['boom']);
    });

    test('feed reaches the wrapped service with the chunk bytes', () async {
      await transcriber.start();
      final bytes = Uint8List.fromList([1, 2, 3]);
      transcriber.feed(AudioChunk(
        bytes: bytes,
        encoding: AudioEncoding.pcm16,
        at: DateTime.now(),
      ));

      expect(fake.added, [bytes]);
    });

    test('start initializes and starts processing', () async {
      await transcriber.start();
      expect(fake.initialized, isTrue);
      expect(fake.processing, isTrue);
    });

    test('stop stops processing and disposes', () async {
      await transcriber.start();
      await transcriber.stop();
      expect(fake.processing, isFalse);
      expect(fake.disposed, isTrue);
    });

    test('late callback after stop produces no event and does not throw',
        () async {
      await transcriber.start();
      final events = <TranscriptSegment>[];
      transcriber.segments.listen(events.add);

      final serviceRef = fake;
      await transcriber.stop();

      expect(
        () => serviceRef.onTranscript!([
          TranscriptSegment(text: 'late', speakerId: 0, startTime: 0, endTime: 1),
        ]),
        returnsNormally,
      );
      expect(events, isEmpty);
    });

    test('feed before start is a no-op', () {
      final t = build();
      expect(
        () => t.feed(AudioChunk(
          bytes: Uint8List.fromList([1]),
          encoding: AudioEncoding.pcm16,
          at: DateTime.now(),
        )),
        returnsNormally,
      );
    });

    test('stop when never started is safe', () async {
      final t = build();
      await t.stop();
    });
  });
}
