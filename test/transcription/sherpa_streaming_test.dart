import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/audio/audio_source.dart';
import 'package:libreomi/models/conversation.dart';
import 'package:libreomi/transcription/isolate_channel.dart';
import 'package:libreomi/transcription/sherpa_streaming.dart';
import 'package:libreomi/transcription/sherpa_worker.dart';

/// A [SherpaWorkerClient] the test fully controls: no isolate, no model.
class _FakeWorkerClient implements SherpaWorkerClient {
  final _events = StreamController<Object?>.broadcast(sync: true);

  SherpaWorkerConfig? startedWith;
  Object? startError;
  bool stopped = false;
  int stopCalls = 0;

  final fedChunks = <Uint8List>[];
  final fedAts = <DateTime>[];

  @override
  Stream<Object?> get events => _events.stream;

  @override
  Future<void> start(SherpaWorkerConfig config) async {
    startedWith = config;
    if (startError != null) {
      throw startError!;
    }
  }

  @override
  void feed(Uint8List pcm16, DateTime at) {
    fedChunks.add(pcm16);
    fedAts.add(at);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    stopped = true;
  }

  void emit(Object? event) => _events.add(event);
  void emitError(Object error) => _events.addError(error);
}

AudioChunk _chunk(List<int> bytes, DateTime at) => AudioChunk(
      bytes: Uint8List.fromList(bytes),
      encoding: AudioEncoding.pcm16,
      at: at,
    );

void main() {
  group('SherpaStreamingTranscriber', () {
    late _FakeWorkerClient fake;
    late SherpaStreamingTranscriber transcriber;

    SherpaStreamingTranscriber build({
      String modelDir = '/models/test-model',
      int numThreads = 2,
    }) {
      fake = _FakeWorkerClient();
      return SherpaStreamingTranscriber(
        modelDir: modelDir,
        numThreads: numThreads,
        workerClient: fake,
      );
    }

    setUp(() {
      transcriber = build();
    });

    test('acceptedEncoding is pcm16', () {
      expect(transcriber.acceptedEncoding, AudioEncoding.pcm16);
    });

    test('start() passes the injected modelDir and numThreads through', () async {
      transcriber = build(modelDir: '/custom/dir', numThreads: 4);
      await transcriber.start();

      expect(fake.startedWith, isNotNull);
      expect(fake.startedWith!.modelDir, '/custom/dir');
      expect(fake.startedWith!.numThreads, 4);
    });

    test('a SherpaSegmentEvent becomes one TranscriptSegment', () async {
      await transcriber.start();
      final segments = <Object?>[];
      transcriber.segments.listen(segments.add);

      final startAt = DateTime(2024, 1, 1);
      final endAt = DateTime(2024, 1, 1, 0, 0, 1);
      fake.emit(SherpaSegmentEvent(
        text: 'hello',
        startTime: 0.5,
        endTime: 1.5,
        startAt: startAt,
        endAt: endAt,
      ));

      expect(segments, hasLength(1));
      final segment = segments.single as TranscriptSegment;
      expect(segment.text, 'hello');
      expect(segment.speakerId, 0);
      expect(segment.startTime, 0.5);
      expect(segment.endTime, 1.5);
      expect(segment.startAt, startAt);
      expect(segment.endAt, endAt);
    });

    test('an IsolateWorkerError event surfaces on errors as a String', () async {
      await transcriber.start();
      final errors = <String>[];
      transcriber.errors.listen(errors.add);

      fake.emit(const IsolateWorkerError('worker failed', 'stack'));

      expect(errors, ['worker failed']);
    });

    test('a stream error on events surfaces on errors as a String', () async {
      await transcriber.start();
      final errors = <String>[];
      transcriber.errors.listen(errors.add);

      fake.emitError(StateError('boom'));

      expect(errors, hasLength(1));
      expect(errors.single, contains('boom'));
    });

    test('feed before start is a no-op', () async {
      transcriber.feed(_chunk([1, 2], DateTime(2024)));
      expect(fake.fedChunks, isEmpty);
    });

    test('feed after start reaches the fake with bytes and chunk.at', () async {
      await transcriber.start();
      final at = DateTime(2024, 1, 1);
      transcriber.feed(_chunk([1, 2, 3, 4], at));

      expect(fake.fedChunks, hasLength(1));
      expect(fake.fedChunks.single, <int>[1, 2, 3, 4]);
      expect(fake.fedAts.single, at);
    });

    test('a start() that fails surfaces on errors AND rethrows', () async {
      fake = _FakeWorkerClient()..startError = StateError('load failed');
      transcriber = SherpaStreamingTranscriber(
        modelDir: '/models/test-model',
        workerClient: fake,
      );

      final errors = <String>[];
      final errorsFuture = transcriber.errors.first;
      transcriber.errors.listen(errors.add);

      await expectLater(transcriber.start(), throwsA(isA<StateError>()));
      await errorsFuture;
      expect(errors, hasLength(1));
      expect(errors.single, contains('load failed'));
    });

    test('stop() stops the client and closes segments/errors; a late event '
        'after stop produces nothing and does not throw', () async {
      await transcriber.start();
      final segments = <Object?>[];
      transcriber.segments.listen(segments.add);

      await transcriber.stop();
      expect(fake.stopped, isTrue);

      // Emitting after stop must not throw, and must not deliver anything.
      fake.emit(SherpaSegmentEvent(
        text: 'late',
        startTime: 0,
        endTime: 0,
        startAt: DateTime(2024),
        endAt: DateTime(2024),
      ));

      expect(segments, isEmpty);
      await expectLater(transcriber.segments, emitsDone);
      await expectLater(transcriber.errors, emitsDone);
    });

    test('stop() without start() is safe', () async {
      await transcriber.stop();
      expect(fake.stopCalls, 0);
    });

    test('double stop() is safe', () async {
      await transcriber.start();
      await transcriber.stop();
      await transcriber.stop();
      expect(fake.stopCalls, 1);
    });
  });

  group('IsolateSherpaWorkerClient (real, no fake)', () {
    // Regression guard for the bug fixed in this file: `events` used to be
    // `_channel?.events ?? const Stream<Object?>.empty()`, so a listener
    // that subscribed before `start()` attached to a brand-new
    // `Stream<Object?>.empty()` — a stream that is already exhausted and
    // delivers `onDone` on its very first microtask. Any event the worker
    // later emitted went to a *different* stream (`_channel!.events`,
    // created once `start()` spawned the isolate) that this early listener
    // was never subscribed to, so it silently missed everything. The fixed
    // implementation always returns the same long-lived
    // `StreamController.broadcast` regardless of `_channel`'s state, so a
    // pre-start subscription stays open and later receives whatever the
    // channel forwards into it.
    //
    // No sherpa model is available in this test run, so this cannot drive a
    // real SherpaSegmentEvent through decode. What it can and does assert,
    // against the real (non-fake) client: a listener attached before
    // start() observes a stream that is still open — not the
    // already-completed `Stream.empty()` the old code handed out. Run this
    // test against the pre-fix `events` getter and it fails: `done` flips
    // to `true` almost immediately.
    test(
        'events is live before start() is called: a pre-start listener does '
        'not see the stream complete on its own', () async {
      final client = IsolateSherpaWorkerClient();

      final received = <Object?>[];
      var done = false;
      final subA = client.events.listen(received.add, onDone: () {
        done = true;
      });
      // A second pre-start subscription must land on the same live stream,
      // not a fresh empty one of its own.
      var doneB = false;
      final subB = client.events.listen((_) {}, onDone: () {
        doneB = true;
      });

      // Give any synchronous/microtask-scheduled `onDone` every chance to
      // fire — `Stream<Object?>.empty()` completes within a couple of
      // microtasks of being listened to, well inside this window.
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(done, isFalse,
          reason: 'a pre-start listener must not see events complete before '
              'start() has even been called');
      expect(doneB, isFalse);
      expect(received, isEmpty);

      await subA.cancel();
      await subB.cancel();
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}
