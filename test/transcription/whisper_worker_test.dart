import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/transcription/vad.dart';
import 'package:libreomi/transcription/whisper_worker.dart';

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

/// A scriptable [WhisperRecognizerApi]. Returns [nextText] (or throws
/// [nextError] if set) for the next call, and records the sample counts it
/// saw.
class _FakeRecognizer implements WhisperRecognizerApi {
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

WhisperFeedCommand _feedCommand(int sampleCount, DateTime at) =>
    WhisperFeedCommand(
      TransferableTypedData.fromList(<Uint8List>[Uint8List(sampleCount * 2)]),
      at,
    );

void main() {
  group('WhisperWorkerCore', () {
    late List<Object?> events;
    late _FakeVad fakeVad;
    late _FakeRecognizer fakeRecognizer;
    late WhisperWorkerCore core;

    void init({int sampleRate = 16000}) {
      core = WhisperWorkerCore(
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
      core.handle(WhisperInitCommand(WhisperWorkerConfig(
        modelDir: '/nonexistent',
        modelSize: 'tiny',
        vad: const VadConfig(modelPath: '/nonexistent'),
        sampleRate: sampleRate,
      )));
    }

    setUp(() {
      events = <Object?>[];
    });

    test('feeding audio before init throws StateError', () {
      core = WhisperWorkerCore(emit: events.add);
      expect(
        () => core.handle(_feedCommand(100, DateTime(2024))),
        throwsA(isA<StateError>()),
      );
    });

    test('one VAD segment produces one WhisperSegmentEvent with the '
        'scripted text', () {
      init();
      fakeVad.onNextAccept.add(_segment(startSample: 0, sampleCount: 8000));
      fakeRecognizer.nextText = 'hello world';

      core.handle(_feedCommand(8000, DateTime(2024)));

      expect(events, hasLength(1));
      expect((events.single as WhisperSegmentEvent).text, 'hello world');
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
      final event = events.single as WhisperSegmentEvent;
      expect(event.startTime, 1.0);
      expect(event.endTime, 1.5);
      expect(event.startAt, t0.add(const Duration(seconds: 1)));
      expect(event.endAt, t0.add(const Duration(milliseconds: 1500)));
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
        events.map((e) => (e as WhisperSegmentEvent).text),
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

    test('WhisperFlushCommand calls vad.flush() and emits the trailing '
        'segment, and the core still works afterwards', () {
      init();
      // Anchor the timeline: a chunk with no completed segment yet.
      core.handle(_feedCommand(1600, DateTime(2024)));

      fakeVad.onNextFlush.add(_segment(startSample: 0, sampleCount: 1600));
      fakeRecognizer.nextText = 'trailing';

      core.handle(const WhisperFlushCommand());

      expect(fakeVad.flushCalls, 1);
      expect(events, hasLength(1));
      expect((events.single as WhisperSegmentEvent).text, 'trailing');

      // Core still works after the flush.
      fakeRecognizer.nextText = 'after flush';
      fakeVad.onNextAccept
          .add(_segment(startSample: 1600, sampleCount: 1600));
      core.handle(_feedCommand(1600, DateTime(2024)));
      expect(events, hasLength(2));
    });

    test('WhisperStopCommand emits the trailing segment, disposes both, '
        'and a second stop is a no-op', () {
      init();
      // Anchor the timeline: a chunk with no completed segment yet.
      core.handle(_feedCommand(1600, DateTime(2024)));

      fakeVad.onNextFlush.add(_segment(startSample: 0, sampleCount: 1600));
      fakeRecognizer.nextText = 'final';

      core.handle(const WhisperStopCommand());

      expect(events, hasLength(1));
      expect((events.single as WhisperSegmentEvent).text, 'final');
      expect(fakeVad.disposeCalls, 1);
      expect(fakeRecognizer.disposeCalls, 1);

      // Second stop is a no-op: no more dispose calls, no more events.
      core.handle(const WhisperStopCommand());
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
      core.handle(const WhisperFlushCommand());
      expect(events, hasLength(1));
      expect((events.single as WhisperSegmentEvent).text, 'second');
    });

    test('an unknown command throws ArgumentError', () {
      init();
      expect(() => core.handle(Object()), throwsA(isA<ArgumentError>()));
    });

    test('odd-length PCM16 and empty chunks are tolerated', () {
      init();
      final oddBytes = Uint8List(5);
      core.handle(WhisperFeedCommand(
        TransferableTypedData.fromList(<Uint8List>[oddBytes]),
        DateTime(2024),
      ));
      core.handle(WhisperFeedCommand(
        TransferableTypedData.fromList(<Uint8List>[Uint8List(0)]),
        DateTime(2024),
      ));
      expect(events, isEmpty);
    });
  });
}
