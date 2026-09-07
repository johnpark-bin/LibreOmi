import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/transcription/vad.dart';

/// A queue-backed [VadApi] fake, just enough to prove the interface is
/// drainable the way a worker's decode loop will use it. The real drain loop
/// belongs to another unit (`offline_worker.dart`).
class FakeVadApi implements VadApi {
  final List<VadSpeechSegment> _queue = [];
  bool disposed = false;
  bool flushed = false;
  int resetCount = 0;

  void enqueue(VadSpeechSegment segment) => _queue.add(segment);

  @override
  void acceptWaveform(Float32List samples) {}

  @override
  bool get isEmpty => _queue.isEmpty;

  @override
  VadSpeechSegment front() => _queue.first;

  @override
  void pop() => _queue.removeAt(0);

  @override
  void flush() => flushed = true;

  @override
  void reset() => resetCount++;

  @override
  void dispose() => disposed = true;
}

void main() {
  group('VadTimeline', () {
    test('offset/wallClock/seconds at sample 0', () {
      final start = DateTime.utc(2026, 1, 1, 12);
      final timeline = VadTimeline(start: start, sampleRate: 16000);

      expect(timeline.offsetOf(0), Duration.zero);
      expect(timeline.wallClockAt(0), start);
      expect(timeline.secondsAt(0), 0.0);
    });

    test('offset/wallClock/seconds at a whole number of seconds', () {
      final start = DateTime.utc(2026, 1, 1, 12);
      final timeline = VadTimeline(start: start, sampleRate: 16000);
      final sampleIndex = 16000 * 3; // 3 seconds in.

      expect(timeline.offsetOf(sampleIndex), const Duration(seconds: 3));
      expect(
        timeline.wallClockAt(sampleIndex),
        start.add(const Duration(seconds: 3)),
      );
      expect(timeline.secondsAt(sampleIndex), 3.0);
    });

    test('offset/wallClock/seconds at a non-round sample index', () {
      final start = DateTime.utc(2026, 1, 1, 12);
      final timeline = VadTimeline(start: start, sampleRate: 16000);
      const sampleIndex = 12345;

      final expectedMicros =
          (sampleIndex * Duration.microsecondsPerSecond / 16000).round();
      expect(
        timeline.offsetOf(sampleIndex),
        Duration(microseconds: expectedMicros),
      );
      expect(
        timeline.wallClockAt(sampleIndex),
        start.add(Duration(microseconds: expectedMicros)),
      );
      expect(timeline.secondsAt(sampleIndex), sampleIndex / 16000);
    });

    test('times() produces consistent startAt <= endAt and duration', () {
      final start = DateTime.utc(2026, 1, 1, 12);
      final timeline = VadTimeline(start: start, sampleRate: 16000);
      final segment = VadSpeechSegment(
        samples: Float32List(16000 * 2), // 2 seconds of audio.
        startSample: 16000,
      );

      final times = timeline.times(segment);

      expect(times.startAt.isBefore(times.endAt) || times.startAt == times.endAt,
          isTrue);
      expect(!times.endAt.isBefore(times.startAt), isTrue);
      expect(
        times.endTime - times.startTime,
        closeTo(segment.sampleCount / 16000, 1e-9),
      );
      expect(times.startTime, 1.0);
      expect(times.endTime, 3.0);
    });

    test('times() for a zero-length segment has startAt == endAt', () {
      final start = DateTime.utc(2026, 1, 1, 12);
      final timeline = VadTimeline(start: start, sampleRate: 16000);
      final segment = VadSpeechSegment(
        samples: Float32List(0),
        startSample: 16000,
      );

      final times = timeline.times(segment);

      expect(times.startAt, times.endAt);
      expect(times.startTime, times.endTime);
    });

    test('non-positive sample rate throws ArgumentError', () {
      final start = DateTime.utc(2026, 1, 1, 12);
      expect(
        () => VadTimeline(start: start, sampleRate: 0),
        throwsArgumentError,
      );
      expect(
        () => VadTimeline(start: start, sampleRate: -16000),
        throwsArgumentError,
      );
    });
  });

  group('VadConfig', () {
    test('defaults match the documented values', () {
      const config = VadConfig(modelPath: '/models/silero_vad.onnx');

      expect(config.sampleRate, 16000);
      expect(config.threshold, 0.5);
      expect(config.minSilenceDuration, 0.5);
      expect(config.minSpeechDuration, 0.25);
      expect(config.windowSize, 512);
      expect(config.maxSpeechDuration, 20.0);
      expect(config.numThreads, 1);
      expect(config.bufferSizeInSeconds, 30.0);
      expect(config.nativeLibraryDir, isNull);
    });

    test('bufferSizeInSeconds comfortably exceeds maxSpeechDuration', () {
      const config = VadConfig(modelPath: '/models/silero_vad.onnx');
      expect(config.bufferSizeInSeconds, greaterThan(config.maxSpeechDuration));
    });
  });

  group('VadSpeechSegment', () {
    test('sampleCount reflects the samples length', () {
      final segment = VadSpeechSegment(
        samples: Float32List(4000),
        startSample: 100,
      );
      expect(segment.sampleCount, 4000);
    });
  });

  group('FakeVadApi (drain loop shape)', () {
    test('feed then drain yields queued segments in order, then empties', () {
      final vad = FakeVadApi();
      final first = VadSpeechSegment(samples: Float32List(10), startSample: 0);
      final second =
          VadSpeechSegment(samples: Float32List(20), startSample: 10);
      vad.enqueue(first);
      vad.enqueue(second);

      final drained = <VadSpeechSegment>[];
      while (!vad.isEmpty) {
        drained.add(vad.front());
        vad.pop();
      }

      expect(drained, [first, second]);
      expect(vad.isEmpty, isTrue);
    });
  });
}
