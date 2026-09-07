import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/transcription/vad.dart';
import 'package:libreomi/transcription/model_catalog.dart';
import 'package:libreomi/transcription/offline_worker.dart';

/// A scriptable [VadApi]. Tests enqueue segments with [enqueue] and assert
/// [flushCalls]/[resetCalls]/[disposeCalls] afterwards.
class _FakeVad implements VadApi {
  final List<Float32List> accepted = <Float32List>[];
  final List<VadSpeechSegment> _queue = <VadSpeechSegment>[];

  int flushCalls = 0;
  int resetCalls = 0;
  int disposeCalls = 0;

  /// Segments that show up in the queue the next time [acceptWaveform] or
  /// [flush] runs, mimicking the detector completing them in response to
  /// that call.
  final List<VadSpeechSegment> onNextAccept = <VadSpeechSegment>[];
  final List<VadSpeechSegment> onNextFlush = <VadSpeechSegment>[];

  void enqueue(VadSpeechSegment segment) => _queue.add(segment);

  @override
  void acceptWaveform(Float32List samples) {
    accepted.add(samples);
    _queue.addAll(onNextAccept);
    onNextAccept.clear();
  }

  @override
  bool get isEmpty => _queue.isEmpty;

  @override
  VadSpeechSegment front() => _queue.first;

  @override
  void pop() => _queue.removeAt(0);

  @override
  void flush() {
    flushCalls++;
    _queue.addAll(onNextFlush);
    onNextFlush.clear();
  }

  @override
  void reset() => resetCalls++;

  @override
  void dispose() => disposeCalls++;
}

/// A scriptable [OfflineRecognizerApi]. Returns [nextText] (or throws
/// [nextError] if set) for the next call, and records the sample counts it
/// saw.
class _FakeRecognizer implements OfflineRecognizerApi {
  final List<int> sampleCounts = <int>[];
  int disposeCalls = 0;

  String nextText = '';
  Object? nextError;

  @override
  String recognize(Float32List samples, int sampleRate) {
    sampleCounts.add(samples.length);
    final error = nextError;
    if (error != null) {
      nextError = null;
      throw error;
    }
    final text = nextText;
    nextText = '';
    return text;
  }

  @override
  void dispose() => disposeCalls++;
}

VadSpeechSegment _segment({required int startSample, required int sampleCount}) =>
    VadSpeechSegment(
      samples: Float32List(sampleCount),
      startSample: startSample,
    );

OfflineFeedCommand _feedCommand(int sampleCount, DateTime at) =>
    OfflineFeedCommand(
      TransferableTypedData.fromList(<Uint8List>[Uint8List(sampleCount * 2)]),
      at,
    );

void main() {
  group('OfflineWorkerCore', () {
    late List<Object?> events;
    late _FakeVad fakeVad;
    late _FakeRecognizer fakeRecognizer;
    late OfflineWorkerCore core;

    void init({int sampleRate = 16000, ModelSpec? model}) {
      core = OfflineWorkerCore(
        emit: events.add,
        vadFactory: (config) {
          fakeVad = _FakeVad();
          return fakeVad;
        },
        recognizerFactory: (config) {
          fakeRecognizer = _FakeRecognizer();
          return fakeRecognizer;
        },
      );
      core.handle(OfflineInitCommand(OfflineWorkerConfig(
        model: model ?? ModelCatalog.whisperTiny,
        modelDir: '/nonexistent',
        vad: const VadConfig(modelPath: '/nonexistent'),
        sampleRate: sampleRate,
      )));
    }

    setUp(() {
      events = <Object?>[];
    });

    test('feeding audio before init throws StateError', () {
      core = OfflineWorkerCore(emit: events.add);
      expect(
        () => core.handle(_feedCommand(100, DateTime(2024))),
        throwsA(isA<StateError>()),
      );
    });

    test('one VAD segment produces one OfflineSegmentEvent with the '
        'scripted text', () {
      init();
      fakeVad.onNextAccept.add(_segment(startSample: 0, sampleCount: 8000));
      fakeRecognizer.nextText = 'hello world';

      core.handle(_feedCommand(8000, DateTime(2024)));

      expect(events, hasLength(1));
      expect((events.single as OfflineSegmentEvent).text, 'hello world');
    });

    test('times are derived from the segment sample indices and the first '
        'chunk\'s at; a later chunk\'s at does not move the anchor', () {
      init(sampleRate: 16000);
      final t0 = DateTime(2024, 1, 1, 0, 0, 0);

      // First chunk: no segment completed yet, but this anchors the
      // timeline.
      core.handle(_feedCommand(1600, t0));
      expect(events, isEmpty);

      // A much later chunk arrives; the segment it completes starts at
      // sample 16000 with 8000 samples.
      final tLater = t0.add(const Duration(hours: 5));
      fakeVad.onNextAccept
          .add(_segment(startSample: 16000, sampleCount: 8000));
      fakeRecognizer.nextText = 'anchored';
      core.handle(_feedCommand(1600, tLater));

      expect(events, hasLength(1));
      final event = events.single as OfflineSegmentEvent;
      expect(event.startTime, 1.0);
      expect(event.endTime, 1.5);
      expect(event.startAt, t0.add(const Duration(seconds: 1)));
      expect(event.endAt, t0.add(const Duration(milliseconds: 1500)));
    });

    test('a SenseVoice model produces exactly the same segment events as a '
        'Whisper one (LO-71)', () {
      // The point of generalizing the worker rather than writing a second
      // one: everything above buildOfflineRecognizerConfig — segmentation,
      // the timeline anchor, the event shape — must not notice which model
      // is loaded. Decoded twice with the same script and compared.
      OfflineSegmentEvent runWith(ModelSpec model) {
        events = <Object?>[];
        init(model: model);
        final t0 = DateTime(2024, 1, 1);
        core.handle(_feedCommand(1600, t0));
        fakeVad.onNextAccept
            .add(_segment(startSample: 16000, sampleCount: 8000));
        fakeRecognizer.nextText = '안녕하세요 hello';
        core.handle(_feedCommand(1600, t0.add(const Duration(hours: 5))));
        return events.single as OfflineSegmentEvent;
      }

      final whisper = runWith(ModelCatalog.whisperTiny);
      final senseVoice = runWith(ModelCatalog.senseVoice);

      expect(senseVoice.text, whisper.text);
      expect(senseVoice.startTime, whisper.startTime);
      expect(senseVoice.endTime, whisper.endTime);
      expect(senseVoice.startAt, whisper.startAt);
      expect(senseVoice.endAt, whisper.endAt);
    });

    test('several queued segments drain in order', () {
      init();
      fakeRecognizer.nextText = 'first';
      fakeVad.onNextAccept.add(_segment(startSample: 0, sampleCount: 1600));
      core.handle(_feedCommand(1600, DateTime(2024)));
      expect(events, hasLength(1));

      fakeRecognizer.nextText = 'second';
      fakeVad.onNextAccept
          .add(_segment(startSample: 1600, sampleCount: 1600));
      core.handle(_feedCommand(1600, DateTime(2024)));

      expect(events, hasLength(2));
      expect(
        events.map((e) => (e as OfflineSegmentEvent).text),
        <String>['first', 'second'],
      );
    });

    test('a segment whose recognition is empty or whitespace emits nothing',
        () {
      init();
      fakeRecognizer.nextText = '   ';
      fakeVad.onNextAccept.add(_segment(startSample: 0, sampleCount: 1600));
      core.handle(_feedCommand(1600, DateTime(2024)));

      expect(events, isEmpty);
    });

    test('OfflineFlushCommand calls vad.flush() and emits the trailing '
        'segment, and the core still works afterwards', () {
      init();
      // Anchor the timeline: a chunk with no completed segment yet.
      core.handle(_feedCommand(1600, DateTime(2024)));

      fakeVad.onNextFlush.add(_segment(startSample: 0, sampleCount: 1600));
      fakeRecognizer.nextText = 'trailing';

      core.handle(const OfflineFlushCommand());

      expect(fakeVad.flushCalls, 1);
      expect(events, hasLength(1));
      expect((events.single as OfflineSegmentEvent).text, 'trailing');

      // Core still works after the flush.
      fakeRecognizer.nextText = 'after flush';
      fakeVad.onNextAccept
          .add(_segment(startSample: 1600, sampleCount: 1600));
      core.handle(_feedCommand(1600, DateTime(2024)));
      expect(events, hasLength(2));
    });

    test('OfflineStopCommand emits the trailing segment, disposes both, '
        'and a second stop is a no-op', () {
      init();
      // Anchor the timeline: a chunk with no completed segment yet.
      core.handle(_feedCommand(1600, DateTime(2024)));

      fakeVad.onNextFlush.add(_segment(startSample: 0, sampleCount: 1600));
      fakeRecognizer.nextText = 'final';

      core.handle(const OfflineStopCommand());

      expect(events, hasLength(1));
      expect((events.single as OfflineSegmentEvent).text, 'final');
      expect(fakeVad.disposeCalls, 1);
      expect(fakeRecognizer.disposeCalls, 1);

      // Second stop is a no-op: no more dispose calls, no more events.
      core.handle(const OfflineStopCommand());
      expect(fakeVad.disposeCalls, 1);
      expect(fakeRecognizer.disposeCalls, 1);
      expect(events, hasLength(1));
    });

    test('a recognizer that throws on one segment does not wedge the drain '
        'loop: the following segment still comes through', () {
      init();
      fakeVad.enqueue(_segment(startSample: 0, sampleCount: 1600));
      fakeVad.enqueue(_segment(startSample: 1600, sampleCount: 1600));
      fakeRecognizer.nextError = Exception('boom');

      // The first recognize() call throws, which propagates out of
      // handle(). Because _drain pops before decoding, the failed segment
      // is already gone from the queue rather than being retried forever.
      expect(
        () => core.handle(_feedCommand(1600, DateTime(2024))),
        throwsA(isA<Exception>()),
      );
      expect(fakeVad.isEmpty, isFalse);
      expect(fakeVad.front().startSample, 1600);

      // Draining resumes on the next command and the second segment still
      // comes through, proving the queue was not wedged on the first one.
      fakeRecognizer.nextText = 'second';
      core.handle(const OfflineFlushCommand());
      expect(events, hasLength(1));
      expect((events.single as OfflineSegmentEvent).text, 'second');
    });

    test('an unknown command throws ArgumentError', () {
      init();
      expect(() => core.handle(Object()), throwsA(isA<ArgumentError>()));
    });

    test('odd-length PCM16 and empty chunks are tolerated', () {
      init();
      final oddBytes = Uint8List(5);
      core.handle(OfflineFeedCommand(
        TransferableTypedData.fromList(<Uint8List>[oddBytes]),
        DateTime(2024),
      ));
      core.handle(OfflineFeedCommand(
        TransferableTypedData.fromList(<Uint8List>[Uint8List(0)]),
        DateTime(2024),
      ));
      expect(events, isEmpty);
    });
  });

  group('buildOfflineRecognizerConfig', () {
    // Pure config mapping: no model on disk, no native library, no isolate.
    // This is the one place that knows a Whisper from a SenseVoice, so it is
    // also the one place where getting it wrong is silent — a recognizer
    // built with every model field empty loads and then decodes nothing.
    OfflineWorkerConfig configFor(
      ModelSpec model, {
      String language = 'en',
      String task = 'transcribe',
      int numThreads = 3,
    }) =>
        OfflineWorkerConfig(
          model: model,
          modelDir: '/models/dir',
          vad: const VadConfig(modelPath: '/models/vad/silero_vad.onnx'),
          language: language,
          task: task,
          numThreads: numThreads,
        );

    test('a Whisper spec fills the whisper config and leaves SenseVoice empty',
        () {
      final config = buildOfflineRecognizerConfig(
          configFor(ModelCatalog.whisperTiny, language: 'ko'));

      expect(config.model.whisper.encoder, '/models/dir/tiny-encoder.onnx');
      expect(config.model.whisper.decoder, '/models/dir/tiny-decoder.onnx');
      expect(config.model.whisper.language, 'ko');
      expect(config.model.whisper.task, 'transcribe');
      expect(config.model.tokens, '/models/dir/tiny-tokens.txt');
      expect(config.model.numThreads, 3);
      expect(config.model.senseVoice.model, isEmpty);
    });

    test('the Whisper base spec resolves its own file names', () {
      // The file names come from ModelSpec.requiredFiles, so a second
      // Whisper entry needs no code change to load.
      final config =
          buildOfflineRecognizerConfig(configFor(ModelCatalog.whisperBase));
      expect(config.model.whisper.encoder, '/models/dir/base-encoder.onnx');
      expect(config.model.tokens, '/models/dir/base-tokens.txt');
    });

    test('a SenseVoice spec fills the SenseVoice config and leaves Whisper '
        'empty', () {
      final config = buildOfflineRecognizerConfig(
          configFor(ModelCatalog.senseVoice, language: 'ko'));

      expect(config.model.senseVoice.model, '/models/dir/model.int8.onnx');
      expect(config.model.senseVoice.language, 'ko');
      expect(config.model.senseVoice.useInverseTextNormalization, isTrue);
      expect(config.model.tokens, '/models/dir/tokens.txt');
      expect(config.model.numThreads, 3);
      expect(config.model.whisper.encoder, isEmpty);
      expect(config.model.whisper.decoder, isEmpty);
    });

    test('a language SenseVoice was not trained on becomes auto-detection',
        () {
      final config = buildOfflineRecognizerConfig(
          configFor(ModelCatalog.senseVoice, language: 'de'));
      expect(config.model.senseVoice.language, 'auto');
    });

    test('a model the offline path cannot decode is rejected', () {
      // A streaming transducer has no offline recognizer at all, so this has
      // to fail loudly rather than build a config with nothing in it.
      expect(
        () => buildOfflineRecognizerConfig(
            configFor(ModelCatalog.streamingZipformerKo)),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => buildOfflineRecognizerConfig(configFor(ModelCatalog.sileroVad)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('OfflineWorkerConfig', () {
    test('modelPaths joins every required file onto the model directory', () {
      const config = OfflineWorkerConfig(
        model: ModelCatalog.senseVoice,
        modelDir: '/models/sense',
        vad: VadConfig(modelPath: '/vad'),
      );
      expect(config.modelPaths, [
        '/models/sense/model.int8.onnx',
        '/models/sense/tokens.txt',
      ]);
    });

    test('an ambiguous or missing suffix is a StateError naming the model',
        () {
      const config = OfflineWorkerConfig(
        model: ModelCatalog.senseVoice,
        modelDir: '/models/sense',
        vad: VadConfig(modelPath: '/vad'),
      );
      expect(() => config.modelPathEndingWith('encoder.onnx'),
          throwsA(isA<StateError>()));
    });
  });
}
