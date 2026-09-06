import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/audio/audio_source.dart';
import 'package:libreomi/models/conversation.dart';
import 'package:libreomi/transcription/isolate_channel.dart';
import 'package:libreomi/transcription/model_catalog.dart';
import 'package:libreomi/transcription/model_store.dart';
import 'package:libreomi/transcription/whisper_batch.dart';
import 'package:libreomi/transcription/whisper_worker.dart';

/// A [WhisperWorkerClient] the test fully controls: no isolate, no model.
class _FakeWorkerClient implements WhisperWorkerClient {
  final _events = StreamController<Object?>.broadcast(sync: true);

  WhisperWorkerConfig? startedWith;
  Object? startError;
  bool stopped = false;
  int stopCalls = 0;

  final fedChunks = <Uint8List>[];
  final fedAts = <DateTime>[];

  @override
  Stream<Object?> get events => _events.stream;

  @override
  Future<void> start(WhisperWorkerConfig config) async {
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
  Future<void> flush() async {}

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
  group('WhisperBatchTranscriber', () {
    late _FakeWorkerClient fake;
    late WhisperBatchTranscriber transcriber;

    WhisperBatchTranscriber build({
      String modelSize = 'tiny',
      String modelDir = '/models/test-whisper',
      String vadModelPath = '/models/test-vad/silero_vad.onnx',
      int numThreads = 2,
    }) {
      fake = _FakeWorkerClient();
      return WhisperBatchTranscriber(
        modelSize: modelSize,
        modelDir: modelDir,
        vadModelPath: vadModelPath,
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

    test(
        'start() passes the injected modelDir and vadModelPath through, and '
        'numThreads', () async {
      transcriber = build(
        modelDir: '/custom/dir',
        vadModelPath: '/custom/vad/silero_vad.onnx',
        numThreads: 4,
      );
      await transcriber.start();

      expect(fake.startedWith, isNotNull);
      expect(fake.startedWith!.modelDir, '/custom/dir');
      expect(fake.startedWith!.vad.modelPath, '/custom/vad/silero_vad.onnx');
      expect(fake.startedWith!.numThreads, 4);
    });

    test('modelSize is reduced through ModelCatalog.whisperSize', () async {
      transcriber = build(modelSize: 'small');
      await transcriber.start();
      expect(fake.startedWith!.modelSize, 'tiny');

      transcriber = build(modelSize: 'base');
      await transcriber.start();
      expect(fake.startedWith!.modelSize, 'base');
    });

    test('a WhisperSegmentEvent becomes one TranscriptSegment', () async {
      await transcriber.start();
      final segments = <Object?>[];
      transcriber.segments.listen(segments.add);

      final startAt = DateTime(2024, 1, 1);
      final endAt = DateTime(2024, 1, 1, 0, 0, 1);
      fake.emit(WhisperSegmentEvent(
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

    test('several segment events arrive in order', () async {
      await transcriber.start();
      final segments = <TranscriptSegment>[];
      transcriber.segments.listen((s) => segments.add(s));

      for (var i = 0; i < 3; i++) {
        fake.emit(WhisperSegmentEvent(
          text: 'seg$i',
          startTime: i.toDouble(),
          endTime: i + 1.0,
          startAt: DateTime(2024, 1, 1, 0, 0, i),
          endAt: DateTime(2024, 1, 1, 0, 0, i + 1),
        ));
      }

      expect(segments.map((s) => s.text).toList(), ['seg0', 'seg1', 'seg2']);
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

    test('feed after start reaches the fake with a copy of the bytes',
        () async {
      await transcriber.start();
      final at = DateTime(2024, 1, 1);
      final original = Uint8List.fromList([1, 2, 3, 4]);
      transcriber.feed(AudioChunk(
        bytes: original,
        encoding: AudioEncoding.pcm16,
        at: at,
      ));

      expect(fake.fedChunks, hasLength(1));
      expect(fake.fedChunks.single, <int>[1, 2, 3, 4]);
      expect(fake.fedAts.single, at);

      // Mutating the original after feed() must not change what the client
      // received: feed() must have handed over a copy.
      original[0] = 99;
      expect(fake.fedChunks.single, <int>[1, 2, 3, 4]);
    });

    test('feed after stop is a no-op', () async {
      await transcriber.start();
      await transcriber.stop();
      transcriber.feed(_chunk([1, 2], DateTime(2024)));
      expect(fake.fedChunks, isEmpty);
    });

    test('a start() that fails surfaces on errors AND rethrows', () async {
      fake = _FakeWorkerClient()..startError = StateError('load failed');
      transcriber = WhisperBatchTranscriber(
        modelDir: '/models/test-whisper',
        vadModelPath: '/models/test-vad/silero_vad.onnx',
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
      fake.emit(WhisperSegmentEvent(
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

    test(
        'with no modelDir/vadModelPath, a fully uninstalled model fails '
        'start and is reported', () async {
      final support =
          Directory.systemTemp.createTempSync('whisper-store-test');
      addTearDown(() => support.deleteSync(recursive: true));

      fake = _FakeWorkerClient();
      final t = WhisperBatchTranscriber(
        modelStore: ModelStore(supportDirectory: () async => support),
        workerClient: fake,
      );
      final errors = <String>[];
      t.errors.listen(errors.add);

      await expectLater(
        t.start(),
        throwsA(isA<ModelNotInstalledException>()),
      );
      // The worker is never spawned when there is no model to load.
      expect(fake.startedWith, isNull);
      expect(errors, hasLength(1));
      expect(errors.single, contains(ModelCatalog.whisperTiny.displayName));
    });

    test(
        'with the Whisper model installed but the VAD missing, the reported '
        'error names the VAD', () async {
      final support =
          Directory.systemTemp.createTempSync('whisper-store-test');
      addTearDown(() => support.deleteSync(recursive: true));

      final whisperDir = Directory(
          '${support.path}/models/${ModelCatalog.whisperTiny.directoryName}')
        ..createSync(recursive: true);
      for (final name in [
        'tiny-encoder.onnx',
        'tiny-decoder.onnx',
        'tiny-tokens.txt',
      ]) {
        File('${whisperDir.path}/$name').writeAsBytesSync([1, 2, 3]);
      }

      fake = _FakeWorkerClient();
      final t = WhisperBatchTranscriber(
        modelStore: ModelStore(supportDirectory: () async => support),
        workerClient: fake,
      );
      final errors = <String>[];
      t.errors.listen(errors.add);

      await expectLater(
        t.start(),
        throwsA(isA<ModelNotInstalledException>()),
      );
      expect(fake.startedWith, isNull);
      expect(errors, hasLength(1));
      expect(errors.single, contains(ModelCatalog.sileroVad.displayName));
    });
  });

  group('IsolateWhisperWorkerClient (real, no fake)', () {
    // The same regression LO-41 fixed on the sherpa client, guarded here
    // because this client is a copy of that structure: `events` must be one
    // long-lived broadcast controller, not `_channel?.events ?? const
    // Stream<Object?>.empty()`. An already-exhausted `Stream.empty()` hands
    // a pre-start listener `onDone` on its first microtask and then sends
    // every real event to a different stream the listener never joined.
    //
    // No whisper or VAD model is available in a plain `flutter test` run, so
    // this cannot drive a real segment through the isolate — that is what
    // `whisper_native_test.dart` is for. What it does assert against the
    // real (non-fake) client is that a subscription taken before `start()`
    // is still open, which is exactly what the broken shape gets wrong.
    test(
        'events is live before start() is called: a pre-start listener does '
        'not see the stream complete on its own', () async {
      final client = IsolateWhisperWorkerClient();

      final received = <Object?>[];
      var done = false;
      final subA = client.events.listen(received.add, onDone: () {
        done = true;
      });
      // A second pre-start subscription must land on the same live stream.
      var doneB = false;
      final subB = client.events.listen((_) {}, onDone: () {
        doneB = true;
      });

      // Give any microtask-scheduled `onDone` every chance to fire.
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

    test('stop() before start() closes events without spawning anything',
        () async {
      final client = IsolateWhisperWorkerClient();
      var done = false;
      client.events.listen((_) {}, onDone: () => done = true);

      // feed() before start() must not throw either: the session can push a
      // chunk between building the transcriber and awaiting start().
      client.feed(Uint8List.fromList([0, 0]), DateTime(2024));
      await client.flush();
      await client.stop();

      expect(done, isTrue);
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}
