/// Silero voice activity detection, and the only file allowed to import
/// `package:sherpa_onnx`'s VAD API (LO-42).
///
/// The Whisper batch path (`offline_worker.dart`, a separate unit) replaces
/// its old fixed 3-second timer with speech segments cut by this detector:
/// instead of decoding whatever audio happened to land in a timer tick, it
/// decodes whole utterances bounded by silence. The layering mirrors
/// `sherpa_worker.dart` (LO-41, see `docs/03-architecture.md` §1):
///
/// * [VadApi] — the handful of native calls a drain loop needs, behind an
///   interface so callers are testable without a model.
/// * [VadTimeline] — sample index to wall-clock/seconds conversion. Pure
///   Dart, no isolate, no plugin; this is what `vad_test.dart` exercises.
/// * [SileroVad] — the real implementation. Constructed only inside a worker
///   isolate, same as `SherpaOnnxRecognizer`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// How to build the detector. Sent to the worker as-is, so every field must
/// be sendable across an isolate boundary.
class VadConfig {
  const VadConfig({
    required this.modelPath,
    this.sampleRate = 16000,
    this.threshold = 0.5,
    this.minSilenceDuration = 0.5,
    this.minSpeechDuration = 0.25,
    this.windowSize = 512,
    this.maxSpeechDuration = 20.0,
    this.numThreads = 1,
    this.bufferSizeInSeconds = 30.0,
    this.nativeLibraryDir,
  });

  /// Path to the installed `silero_vad.onnx` (see
  /// `ModelCatalog.sileroVad`/`ModelCatalog.sileroVadFileName`). Model
  /// download and layout belong to `model_store.dart` (LO-40), not here.
  final String modelPath;

  /// Sample rate of the PCM this detector is fed. The Omi path and the phone
  /// mic both deliver 16 kHz.
  final int sampleRate;

  final double threshold;
  final double minSilenceDuration;
  final double minSpeechDuration;
  final int windowSize;

  /// Deliberately raised from sherpa's own 5 s default. A normal sentence
  /// should never be split mid-word just because it ran long, but the
  /// Whisper decode on the other end still needs a bound on how much audio
  /// one segment can hand it. 20 s covers a normal sentence with headroom;
  /// a long monologue that exceeds it is force-split at 20 s by sherpa
  /// itself, not by anything in this file.
  final double maxSpeechDuration;

  final int numThreads;

  /// Capacity, in seconds, of the detector's own circular buffer. Must
  /// comfortably exceed [maxSpeechDuration]: the buffer has to hold a whole
  /// utterance plus the silence that closes it before [VadApi.front] can
  /// hand that utterance back, so a value at or below [maxSpeechDuration]
  /// would drop the tail of the longest speech segments the config itself
  /// allows.
  final double bufferSizeInSeconds;

  /// Where to load `libsherpa-onnx-c-api` from. Null on device, where the
  /// bundled library is already on the loader's search path; set only by the
  /// desktop integration test, which runs outside a Flutter app bundle.
  final String? nativeLibraryDir;
}

/// One speech utterance the detector cut out of the stream.
class VadSpeechSegment {
  const VadSpeechSegment({required this.samples, required this.startSample});

  final Float32List samples;

  /// Sample index, counted from the first sample ever fed to the detector,
  /// at which this utterance starts.
  final int startSample;

  int get sampleCount => samples.length;
}

/// The slice of the Silero VAD a drain loop needs. Implemented for real by
/// [SileroVad] and faked in tests.
abstract class VadApi {
  /// Feeds one chunk of audio. May complete zero or more segments, made
  /// available through [isEmpty]/[front]/[pop].
  void acceptWaveform(Float32List samples);

  /// True when no completed segment is queued.
  bool get isEmpty;

  /// The oldest completed segment still queued. Only valid when [isEmpty]
  /// is false.
  VadSpeechSegment front();

  /// Drops the segment [front] returned.
  void pop();

  /// Tells the detector no more audio is coming, so a trailing utterance
  /// still in progress is emitted rather than silently dropped.
  void flush();

  /// Clears in-progress state without emitting anything.
  void reset();

  void dispose();
}

/// Builds a detector for [config]. Swapped out in tests.
typedef VadFactory = VadApi Function(VadConfig config);

// ---------------------------------------------------------------------------
// Timeline
// ---------------------------------------------------------------------------

/// The four values a transcript segment needs from one [VadSpeechSegment]:
/// wall-clock and seconds-from-session-start for both edges.
class VadSegmentTimes {
  const VadSegmentTimes({
    required this.startAt,
    required this.endAt,
    required this.startTime,
    required this.endTime,
  });

  final DateTime startAt;
  final DateTime endAt;

  /// Seconds from session start.
  final double startTime;
  final double endTime;
}

/// Converts a [VadSpeechSegment]'s sample indices into times, anchored on
/// the wall clock of the first audio sample of the session rather than on
/// `DateTime.now()`.
///
/// This mirrors [SherpaWorkerCore]'s choice in `sherpa_worker.dart`: deriving
/// timestamps from the audio timeline is both more accurate than reading the
/// clock after a decode (which includes however long the decode itself took)
/// and deterministic under test.
class VadTimeline {
  VadTimeline({required DateTime start, required int sampleRate})
      : _start = start,
        _sampleRate = sampleRate {
    if (sampleRate <= 0) {
      throw ArgumentError.value(
        sampleRate,
        'sampleRate',
        'must be positive',
      );
    }
  }

  final DateTime _start;
  final int _sampleRate;

  /// Sample index to duration from session start, rounded to microseconds.
  Duration offsetOf(int sampleIndex) {
    return Duration(
      microseconds:
          (sampleIndex * Duration.microsecondsPerSecond / _sampleRate).round(),
    );
  }

  DateTime wallClockAt(int sampleIndex) => _start.add(offsetOf(sampleIndex));

  double secondsAt(int sampleIndex) => sampleIndex / _sampleRate;

  /// The four values a transcript segment needs for [segment].
  VadSegmentTimes times(VadSpeechSegment segment) {
    final endSample = segment.startSample + segment.sampleCount;
    return VadSegmentTimes(
      startAt: wallClockAt(segment.startSample),
      endAt: wallClockAt(endSample),
      startTime: secondsAt(segment.startSample),
      endTime: secondsAt(endSample),
    );
  }
}

// ---------------------------------------------------------------------------
// Real detector
// ---------------------------------------------------------------------------

/// [VadApi] on top of the real sherpa-onnx Silero VAD bindings. Only ever
/// constructed inside a worker isolate.
class SileroVad implements VadApi {
  SileroVad._(this._vad);

  final sherpa.VoiceActivityDetector _vad;
  bool _disposed = false;

  /// Loads the model in [config]. Throws a [StateError] naming the missing
  /// file when the model is not on disk: install it from the Models screen.
  static VadApi create(VadConfig config) {
    if (!File(config.modelPath).existsSync()) {
      throw StateError(
        'Silero VAD model missing: ${config.modelPath}. Install the Silero '
        'VAD model from the Models screen before local transcription can '
        'segment speech.',
      );
    }

    // Bindings are per-isolate statics, so this runs in the worker.
    sherpa.initBindings(config.nativeLibraryDir);

    final vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: config.modelPath,
          threshold: config.threshold,
          minSilenceDuration: config.minSilenceDuration,
          minSpeechDuration: config.minSpeechDuration,
          windowSize: config.windowSize,
          maxSpeechDuration: config.maxSpeechDuration,
        ),
        sampleRate: config.sampleRate,
        numThreads: config.numThreads,
        debug: false,
      ),
      bufferSizeInSeconds: config.bufferSizeInSeconds,
    );
    return SileroVad._(vad);
  }

  @override
  void acceptWaveform(Float32List samples) => _vad.acceptWaveform(samples);

  @override
  bool get isEmpty => _vad.isEmpty();

  @override
  VadSpeechSegment front() {
    // sherpa's SpeechSegment.start is already an absolute sample index from
    // the detector's own counter, so it passes straight through.
    final segment = _vad.front();
    return VadSpeechSegment(
      samples: segment.samples,
      startSample: segment.start,
    );
  }

  @override
  void pop() => _vad.pop();

  @override
  void flush() => _vad.flush();

  @override
  void reset() => _vad.reset();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _vad.free();
  }
}
