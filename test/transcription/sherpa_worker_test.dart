import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/transcription/sherpa_worker.dart';

/// A scriptable [SherpaRecognizerApi]. The test sets [isEndpoint] and
/// [nextResult] before each feed to control what the core sees.
class _FakeRecognizer implements SherpaRecognizerApi {
  _FakeRecognizer(this.config);

  final SherpaWorkerConfig config;

  final List<Float32List> accepted = <Float32List>[];
  int resetCalls = 0;
  int inputFinishedCalls = 0;
  int disposeCalls = 0;
  int decodeCalls = 0;

  int _readyRemaining = 0;

  /// Test-only: `fake.isReady = true` scripts exactly one more `true` read;
  /// use [scriptReady] to script several in a row (to exercise the drain
  /// loops in `_feed`/`_stop`).
  set isReady(bool value) => _readyRemaining = value ? 1 : 0;

  @override
  bool get isReady {
    if (_readyRemaining > 0) {
      _readyRemaining--;
      return true;
    }
    return false;
  }

  /// Makes [isReady] return true for the next [count] reads, then false.
  void scriptReady(int count) => _readyRemaining = count;

  @override
  bool isEndpoint = false;
  SherpaRecognition nextResult =
      const SherpaRecognition(text: '', timestamps: <double>[]);

  @override
  void acceptWaveform(Float32List samples, int sampleRate) {
    accepted.add(samples);
  }

  @override
  void decode() => decodeCalls++;

  @override
  SherpaRecognition getResult() => nextResult;

  @override
  void reset() => resetCalls++;

  @override
  void inputFinished() => inputFinishedCalls++;

  @override
  void dispose() => disposeCalls++;
}

/// Builds a [Uint8List] of PCM16 silence containing [sampleCount] samples.
Uint8List _silence(int sampleCount) => Uint8List(sampleCount * 2);

SherpaFeedCommand _feedCommand(Uint8List bytes, DateTime at) =>
    SherpaFeedCommand(TransferableTypedData.fromList(<Uint8List>[bytes]), at);

void main() {
  group('pcm16ToFloat32', () {
    test('little-endian conversion of representative values', () {
      final bytes = ByteData(8);
      bytes.setInt16(0, 0x0000, Endian.little);
      bytes.setInt16(2, 0x7FFF, Endian.little);
      bytes.setInt16(4, -32768, Endian.little); // 0x8000
      bytes.setInt16(6, -1, Endian.little); // 0xFFFF -> -1/32768
      final samples = pcm16ToFloat32(bytes.buffer.asUint8List());

      expect(samples[0], 0.0);
      expect(samples[1], closeTo(0.99997, 1e-5));
      expect(samples[2], -1.0);
      expect(samples[3], closeTo(-1 / 32768, 1e-9));
    });

    test('odd trailing byte is dropped', () {
      final bytes = Uint8List.fromList(<int>[0, 0, 1, 0, 0xFF]);
      final samples = pcm16ToFloat32(bytes);
      expect(samples.length, 2);
    });

    test('empty input yields empty output', () {
      expect(pcm16ToFloat32(Uint8List(0)), isEmpty);
    });
  });

  group('SherpaWorkerCore', () {
    late List<Object?> events;
    late _FakeRecognizer fake;
    late SherpaWorkerCore core;

    void init({int sampleRate = 16000}) {
      core = SherpaWorkerCore(
        emit: events.add,
        recognizerFactory: (config) {
          fake = _FakeRecognizer(config);
          return fake;
        },
      );
      core.handle(SherpaInitCommand(SherpaWorkerConfig(
        modelDir: '/nonexistent',
        sampleRate: sampleRate,
      )));
    }

    setUp(() {
      events = <Object?>[];
    });

    test('feed before init throws StateError', () {
      core = SherpaWorkerCore(emit: events.add);
      expect(
        () => core.handle(_feedCommand(_silence(100), DateTime(2024))),
        throwsA(isA<StateError>()),
      );
    });

    test('one endpoint produces exactly one SherpaSegmentEvent', () {
      init();
      fake.isEndpoint = true;
      fake.nextResult =
          const SherpaRecognition(text: 'hello', timestamps: <double>[0, 1]);
      core.handle(_feedCommand(_silence(100), DateTime(2024)));

      expect(events, hasLength(1));
      expect((events.single as SherpaSegmentEvent).text, 'hello');
    });

    test('two endpoints produce two SherpaSegmentEvents', () {
      init();
      fake.isEndpoint = true;
      fake.nextResult =
          const SherpaRecognition(text: 'first', timestamps: <double>[0, 1]);
      core.handle(_feedCommand(_silence(100), DateTime(2024)));

      fake.nextResult =
          const SherpaRecognition(text: 'second', timestamps: <double>[0, 1]);
      core.handle(_feedCommand(_silence(100), DateTime(2024)));

      expect(events, hasLength(2));
      expect(
        events.map((e) => (e as SherpaSegmentEvent).text),
        <String>['first', 'second'],
      );
    });

    test('an endpoint with empty/whitespace text produces no event but '
        'still resets', () {
      init();
      fake.isEndpoint = true;
      fake.nextResult =
          const SherpaRecognition(text: '   ', timestamps: <double>[]);
      core.handle(_feedCommand(_silence(100), DateTime(2024)));

      expect(events, isEmpty);
      expect(fake.resetCalls, 1);
    });

    test('timestamps: startAt from the first chunk, endAt from the chunk '
        'that tripped the endpoint, over a multi-chunk utterance', () {
      init(sampleRate: 16000);
      final t0 = DateTime(2024, 1, 1, 0, 0, 0);

      // Chunk 1: 1600 samples (100ms), no endpoint.
      final chunk1Bytes = _silence(1600);
      core.handle(_feedCommand(chunk1Bytes, t0));
      expect(events, isEmpty);

      // Chunk 2: 800 samples (50ms), endpoint trips here.
      final t1 = t0.add(const Duration(milliseconds: 250));
      fake.isEndpoint = true;
      fake.nextResult = const SherpaRecognition(
        text: 'utterance',
        timestamps: <double>[0.1, 0.2, 0.3],
      );
      final chunk2Bytes = _silence(800);
      core.handle(_feedCommand(chunk2Bytes, t1));

      expect(events, hasLength(1));
      final event = events.single as SherpaSegmentEvent;
      expect(event.startAt, t0);
      final expectedEndAt = t1.add(const Duration(microseconds: 50000));
      expect(event.endAt, expectedEndAt);
      expect(event.startTime, 0.1);
      expect(event.endTime, 0.3);
    });

    test('timestamps are 0 when the returned timestamp list is empty', () {
      init();
      fake.isEndpoint = true;
      fake.nextResult =
          const SherpaRecognition(text: 'x', timestamps: <double>[]);
      core.handle(_feedCommand(_silence(100), DateTime(2024)));

      final event = events.single as SherpaSegmentEvent;
      expect(event.startTime, 0);
      expect(event.endTime, 0);
    });

    test('after an endpoint, the next utterance startAt comes from the '
        'next chunk, not the old one', () {
      init();
      fake.isEndpoint = true;
      fake.nextResult =
          const SherpaRecognition(text: 'first', timestamps: <double>[0]);
      final t0 = DateTime(2024, 1, 1);
      core.handle(_feedCommand(_silence(100), t0));
      expect(events, hasLength(1));

      final t1 = DateTime(2024, 1, 2);
      fake.nextResult =
          const SherpaRecognition(text: 'second', timestamps: <double>[0]);
      core.handle(_feedCommand(_silence(100), t1));

      final second = events[1] as SherpaSegmentEvent;
      expect(second.startAt, t1);
    });

    test('SherpaStopCommand flushes the tail, disposes, and a second stop '
        'is a no-op', () {
      init(sampleRate: 16000);
      final t0 = DateTime(2024, 1, 1);
      // Feed without endpoint so there is a pending tail.
      final bytes = _silence(1600); // 100ms
      core.handle(_feedCommand(bytes, t0));
      expect(events, isEmpty);

      fake.isReady = false;
      fake.nextResult = const SherpaRecognition(
        text: 'tail text',
        timestamps: <double>[0.05],
      );
      core.handle(const SherpaStopCommand());

      expect(fake.inputFinishedCalls, 1);
      expect(fake.disposeCalls, 1);
      expect(events, hasLength(1));
      final event = events.single as SherpaSegmentEvent;
      expect(event.text, 'tail text');
      final expectedEndAt = t0.add(const Duration(microseconds: 100000));
      expect(event.endAt, expectedEndAt);

      // Second stop is a no-op: no more dispose calls, no more events.
      core.handle(const SherpaStopCommand());
      expect(fake.disposeCalls, 1);
      expect(events, hasLength(1));
    });

    test('SherpaResetCommand drops the pending utterance', () {
      init();
      final t0 = DateTime(2024, 1, 1);
      core.handle(_feedCommand(_silence(100), t0)); // no endpoint yet
      core.handle(const SherpaResetCommand());
      expect(fake.resetCalls, 1);

      final t1 = DateTime(2024, 1, 2);
      fake.isEndpoint = true;
      fake.nextResult =
          const SherpaRecognition(text: 'after reset', timestamps: <double>[0]);
      core.handle(_feedCommand(_silence(100), t1));

      final event = events.single as SherpaSegmentEvent;
      expect(event.startAt, t1);
    });

    test('_feed drains isReady, calling decode() exactly as many times as '
        'scripted, and the loop terminates', () {
      init();
      fake.scriptReady(3);
      core.handle(_feedCommand(_silence(100), DateTime(2024)));

      expect(fake.decodeCalls, 3);
      // The loop must have stopped because isReady ran out, not because the
      // fake never had it become true.
      expect(fake.isReady, isFalse);
    });

    test('_stop drains isReady, calling decode() exactly as many times as '
        'scripted, and the loop terminates', () {
      init();
      fake.scriptReady(4);
      core.handle(const SherpaStopCommand());

      expect(fake.decodeCalls, 4);
      expect(fake.isReady, isFalse);
    });

    test('an unknown command throws ArgumentError', () {
      init();
      expect(() => core.handle(Object()), throwsA(isA<ArgumentError>()));
    });
  });
}
