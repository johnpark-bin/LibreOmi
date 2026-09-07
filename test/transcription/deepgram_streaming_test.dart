import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/audio/audio_source.dart';
import 'package:libreomi/core/models.dart';
import 'package:libreomi/services/deepgram_service.dart';
import 'package:libreomi/transcription/deepgram_streaming.dart';

/// Subclasses [DeepgramService] and overrides its networking methods so
/// tests never open a real socket.
class _FakeDeepgram extends DeepgramService {
  _FakeDeepgram({super.onTranscript, super.onError, super.encoding})
      : super(apiKey: 'test-key');

  final sent = <Uint8List>[];
  bool connected = false;

  @override
  Future<void> connect() async {
    connected = true;
  }

  @override
  void sendAudio(Uint8List data) => sent.add(data);

  @override
  Future<void> disconnect() async {
    connected = false;
  }
}

void main() {
  group('DeepgramStreamingTranscriber', () {
    late _FakeDeepgram fake;
    late DeepgramStreamingTranscriber transcriber;

    DeepgramStreamingTranscriber build(AudioEncoding encoding) {
      return DeepgramStreamingTranscriber(
        encoding: encoding,
        apiKey: 'test-key',
        serviceFactory: ({required onTranscript, required onError}) {
          fake = _FakeDeepgram(
            onTranscript: onTranscript,
            onError: onError,
            encoding: encoding == AudioEncoding.opus ? 'opus' : 'linear16',
          );
          return fake;
        },
      );
    }

    setUp(() {
      transcriber = build(AudioEncoding.opus);
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
        encoding: AudioEncoding.opus,
        at: DateTime.now(),
      ));

      expect(fake.sent, [bytes]);
    });

    test('acceptedEncoding reports the encoding it was built for', () {
      expect(build(AudioEncoding.opus).acceptedEncoding, AudioEncoding.opus);
      expect(build(AudioEncoding.pcm16).acceptedEncoding, AudioEncoding.pcm16);
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
      final t = build(AudioEncoding.opus);
      expect(
        () => t.feed(AudioChunk(
          bytes: Uint8List.fromList([1]),
          encoding: AudioEncoding.opus,
          at: DateTime.now(),
        )),
        returnsNormally,
      );
    });

    test('stop when never started is safe', () async {
      final t = build(AudioEncoding.opus);
      await t.stop();
    });
  });

  group('DeepgramStreamingTranscriber.buildDeepgramService', () {
    // Exercises the real factory rather than an injected fake: this is the
    // mapping that decides what the Omi and phone-mic paths actually send to
    // Deepgram. Constructing the service opens no socket.
    // Deliberately not the DeepgramService constructor defaults ('en',
    // 16000), so an argument that stops being forwarded fails the test.
    DeepgramService build(AudioEncoding encoding) {
      return DeepgramStreamingTranscriber.buildDeepgramService(
        encoding: encoding,
        apiKey: 'test-key',
        language: 'ko',
        sampleRate: 8000,
        onTranscript: (_) {},
        onError: (_) {},
      );
    }

    test('opus maps to the Deepgram opus encoding', () {
      expect(build(AudioEncoding.opus).encoding, 'opus');
    });

    test('pcm16 maps to the Deepgram linear16 encoding', () {
      expect(build(AudioEncoding.pcm16).encoding, 'linear16');
    });

    test('the other transport settings are forwarded unchanged', () {
      final service = build(AudioEncoding.opus);
      expect(service.apiKey, 'test-key');
      expect(service.language, 'ko');
      expect(service.sampleRate, 8000);
    });
  });
}
