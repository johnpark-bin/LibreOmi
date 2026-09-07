import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/audio/wav.dart';
import 'package:libreomi/transcription/isolate_channel.dart';
import 'package:libreomi/transcription/model_store.dart';
import 'package:libreomi/transcription/offline_file_transcriber.dart';
import 'package:libreomi/transcription/whisper_worker.dart';

/// A scriptable [WhisperWorkerClient]. Records every [feed]d chunk and
/// whether [flush]/[stop] were called, and lets a test push events onto
/// [events] to simulate the worker.
class _FakeWorkerClient implements WhisperWorkerClient {
  final StreamController<Object?> _events =
      StreamController<Object?>.broadcast(sync: true);

  final List<Uint8List> fedChunks = <Uint8List>[];
  final List<DateTime> fedAt = <DateTime>[];
  WhisperWorkerConfig? startedWith;

  final List<String> callOrder = <String>[];

  /// Lets a test suspend [start] right after it records the call (and after
  /// the transcriber has already subscribed to [events]), so events can be
  /// emitted deterministically before the feed/flush/stop sequence runs.
  /// Pre-completed by default so tests that don't care about ordering never
  /// block on it.
  Completer<void> startGate = Completer<void>()..complete();

  @override
  Stream<Object?> get events => _events.stream;

  @override
  Future<void> start(WhisperWorkerConfig config) async {
    startedWith = config;
    callOrder.add('start');
    await startGate.future;
  }

  @override
  void feed(Uint8List pcm16, DateTime at) {
    fedChunks.add(Uint8List.fromList(pcm16));
    fedAt.add(at);
    callOrder.add('feed');
  }

  @override
  Future<void> flush() async {
    callOrder.add('flush');
  }

  @override
  Future<void> stop() async {
    callOrder.add('stop');
    if (!_events.isClosed) await _events.close();
  }

  void emit(Object? event) => _events.add(event);
}

void main() {
  group('OfflineFileTranscriber', () {
    late Directory tempDir;
    late _FakeWorkerClient client;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('offline_file_transcriber_test');
      client = _FakeWorkerClient();
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    OfflineFileTranscriber buildTranscriber({int chunkBytes = 32000}) {
      return OfflineFileTranscriber(
        modelDir: '${tempDir.path}/whisper',
        vadModelPath: '${tempDir.path}/vad/silero_vad.onnx',
        chunkBytes: chunkBytes,
        workerClientFactory: () => client,
        recordingStartedAt: DateTime(2024, 1, 1),
      );
    }

    File writeWav(List<int> pcm,
        {int sampleRate = wavSampleRate,
        int channels = wavChannels,
        int bitsPerSample = wavBitsPerSample}) {
      final file = File('${tempDir.path}/input.wav');
      file.writeAsBytesSync(
        buildWav(pcm,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample),
      );
      return file;
    }

    test('PCM is chunked to chunkBytes and total fed bytes equal the data payload',
        () async {
      final pcm = List<int>.generate(70001, (i) => i % 256);
      final file = writeWav(pcm);
      final transcriber = buildTranscriber(chunkBytes: 32000);

      final future = transcriber.transcribe(file);
      await Future<void>.delayed(Duration.zero);
      await future;

      expect(client.fedChunks.map((c) => c.length).toList(),
          <int>[32000, 32000, 6001]);
      final totalFed =
          client.fedChunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
      expect(totalFed, pcm.length);
    });

    test('flush() is called before stop()', () async {
      final file = writeWav(List<int>.filled(3200, 0));
      final transcriber = buildTranscriber();

      await transcriber.transcribe(file);

      final flushIndex = client.callOrder.indexOf('flush');
      final stopIndex = client.callOrder.indexOf('stop');
      expect(flushIndex, greaterThanOrEqualTo(0));
      expect(stopIndex, greaterThanOrEqualTo(0));
      expect(flushIndex, lessThan(stopIndex));
    });

    test('WhisperSegmentEvents map to TranscriptSegments in order with fields '
        'preserved and speakerId 0', () async {
      final file = writeWav(List<int>.filled(3200, 0));
      final transcriber = buildTranscriber();

      client.startGate = Completer<void>();
      final segmentsFuture = transcriber.transcribe(file);
      // Wait until the transcriber has subscribed and started the (fake)
      // worker, so these events are not emitted before anyone is listening
      // — start() is now blocked on startGate, so feed/flush/stop have not
      // run yet either.
      await _waitForStart(client);

      client.emit(WhisperSegmentEvent(
        text: 'first',
        startTime: 0.0,
        endTime: 1.0,
        startAt: DateTime(2024, 1, 1, 0, 0, 0),
        endAt: DateTime(2024, 1, 1, 0, 0, 1),
      ));
      client.emit(WhisperSegmentEvent(
        text: 'second',
        startTime: 1.0,
        endTime: 2.0,
        startAt: DateTime(2024, 1, 1, 0, 0, 1),
        endAt: DateTime(2024, 1, 1, 0, 0, 2),
      ));
      client.startGate.complete();

      final segments = await segmentsFuture;

      expect(segments, hasLength(2));
      expect(segments[0].text, 'first');
      expect(segments[0].speakerId, 0);
      expect(segments[0].startTime, 0.0);
      expect(segments[0].endTime, 1.0);
      expect(segments[0].startAt, DateTime(2024, 1, 1, 0, 0, 0));
      expect(segments[0].endAt, DateTime(2024, 1, 1, 0, 0, 1));
      expect(segments[1].text, 'second');
      expect(segments[1].speakerId, 0);
    });

    test('a non-16kHz WAV is rejected with a clear error', () async {
      final file = writeWav(List<int>.filled(3200, 0), sampleRate: 8000);
      final transcriber = buildTranscriber();

      await expectLater(
        transcriber.transcribe(file),
        throwsA(isA<ArgumentError>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('8000'), contains('16000')),
        )),
      );
    });

    test('a stereo WAV is rejected with a clear error', () async {
      final file =
          writeWav(List<int>.filled(3200, 0), channels: 2);
      final transcriber = buildTranscriber();

      await expectLater(
        transcriber.transcribe(file),
        throwsA(isA<ArgumentError>().having(
          (e) => e.toString(),
          'message',
          contains('2-channel'),
        )),
      );
    });

    test('an 8-bit PCM WAV is rejected with a clear error', () async {
      // `parseWav` accepts any integer PCM, and 8-bit samples read as PCM16
      // would decode into a confident-looking transcript of noise.
      final file = writeWav(List<int>.filled(3200, 0), bitsPerSample: 8);
      final transcriber = buildTranscriber();

      await expectLater(
        transcriber.transcribe(file),
        throwsA(isA<ArgumentError>().having(
          (e) => e.toString(),
          'message',
          contains('8-bit'),
        )),
      );
    });

    test('a missing model surfaces the ModelStore exception verbatim',
        () async {
      final file = writeWav(List<int>.filled(3200, 0));
      final transcriber = OfflineFileTranscriber(
        // No modelDir/vadModelPath, so the store is consulted -- and a real
        // store over an empty directory is exactly what a fresh install
        // looks like, so this needs no fake.
        modelStore: ModelStore(
          supportDirectory: () async => tempDir,
          legacyDocumentsDirectory: () async => tempDir,
        ),
        workerClientFactory: () =>
            fail('the worker must not start without a model'),
      );

      await expectLater(
        transcriber.transcribe(file),
        throwsA(isA<ModelNotInstalledException>()),
      );
    });

    test('a worker error with no segments surfaces as a thrown exception',
        () async {
      final file = writeWav(List<int>.filled(3200, 0));
      final transcriber = buildTranscriber();

      client.startGate = Completer<void>();
      final future = transcriber.transcribe(file);
      await _waitForStart(client);
      client.emit(const IsolateWorkerError('model failed to load', ''));
      client.startGate.complete();

      await expectLater(
        future,
        throwsA(predicate(
            (e) => e.toString().contains('model failed to load'))),
      );
    });
  });
}

/// Polls until [client] has recorded a [WhisperWorkerClient.start] call, so
/// a test can safely emit events without racing the transcriber's own
/// subscribe-then-start sequence.
Future<void> _waitForStart(_FakeWorkerClient client) async {
  for (var i = 0; i < 50 && client.startedWith == null; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(client.startedWith, isNotNull,
      reason: 'worker client was never started');
}
