/// The sherpa-onnx offline (Whisper) recognizer, and the only file allowed to
/// import it for batch decoding (LO-42).
///
/// This is the only Whisper decode path. Everything that touches the native
/// recognizer runs in a worker isolate, same as the streaming path. The
/// layering is:
///
/// * [WhisperRecognizerApi] — the one native call an utterance decode needs,
///   behind an interface so [WhisperWorkerCore] is testable without a model.
/// * [WhisperWorkerCore] — feeds PCM16 to a [VadApi], and decodes whatever
///   utterance the detector cuts out. Pure Dart, no isolate, no plugin.
/// * [whisperWorkerMain] — the isolate entry point wiring the core to an
///   [IsolateWorker].
/// * [WhisperWorkerClient] — the main-isolate handle the transcriber talks
///   to.
///
/// What decided when to decode used to be a fixed 3-second timer (see the
/// old `services/whisper_service.dart`), which cuts audio mid-word whenever
/// an utterance straddles a tick. Cutting on the VAD's silence boundaries
/// instead means every decode gets a whole utterance, never half of one.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'isolate_channel.dart';
import 'sherpa_worker.dart' show pcm16ToFloat32;
import 'vad.dart';

/// How to build the recognizer. Sent to the worker as-is, so every field must
/// be sendable across an isolate boundary.
class WhisperWorkerConfig {
  const WhisperWorkerConfig({
    required this.modelDir,
    required this.modelSize,
    required this.vad,
    this.numThreads = 2,
    this.sampleRate = 16000,
    this.nativeLibraryDir,
  });

  /// Directory holding the model files. Supplied by the caller — model
  /// download and layout belong to `model_store.dart` (LO-40), not here.
  final String modelDir;

  /// `'tiny'` or `'base'`. Callers must reduce a raw settings string through
  /// [ModelCatalog.whisperSize] first: the size is a file name prefix, so a
  /// value the catalog would not recognize resolves to files that are not on
  /// disk.
  final String modelSize;

  /// Detector this worker segments speech with, before any Whisper decode.
  final VadConfig vad;

  final int numThreads;

  /// Sample rate of the PCM16 the worker is fed. The Omi path and the phone
  /// mic both deliver 16 kHz.
  final int sampleRate;

  /// Where to load `libsherpa-onnx-c-api` from. Null on device, where the
  /// bundled library is already on the loader's search path; set only by the
  /// desktop integration test, which runs outside a Flutter app bundle.
  final String? nativeLibraryDir;

  String get encoderPath => '$modelDir/$modelSize-encoder.onnx';
  String get decoderPath => '$modelDir/$modelSize-decoder.onnx';
  String get tokensPath => '$modelDir/$modelSize-tokens.txt';
}

/// The slice of sherpa-onnx's offline recognizer an utterance decode needs.
/// Implemented for real by [WhisperOnnxRecognizer] and faked in tests.
abstract class WhisperRecognizerApi {
  /// Decodes one whole utterance and returns its text.
  String recognize(Float32List samples, int sampleRate);

  void dispose();
}

/// Builds a recognizer for [config]. Swapped out in tests.
typedef WhisperRecognizerFactory = WhisperRecognizerApi Function(
    WhisperWorkerConfig config);

// ---------------------------------------------------------------------------
// Worker protocol
// ---------------------------------------------------------------------------

/// Builds the VAD and the recognizer. Answered once both are loaded, or with
/// an error if either could not be.
class WhisperInitCommand {
  const WhisperInitCommand(this.config);
  final WhisperWorkerConfig config;
}

/// One chunk of PCM16 audio. Sent as a notification — the main isolate never
/// waits for a decode. The bytes travel as [TransferableTypedData] so they
/// are moved rather than copied.
class WhisperFeedCommand {
  const WhisperFeedCommand(this.pcm16, this.at);

  final TransferableTypedData pcm16;

  /// Wall clock at which this chunk's first sample was captured.
  final DateTime at;
}

/// Flushes the detector's tail, emits whatever utterance was still in
/// progress, and keeps the worker running.
class WhisperFlushCommand {
  const WhisperFlushCommand();
}

/// Flushes the tail, emits it, and frees the VAD and the recognizer.
class WhisperStopCommand {
  const WhisperStopCommand();
}

/// One decoded utterance, on its way back to the main isolate.
class WhisperSegmentEvent {
  const WhisperSegmentEvent({
    required this.text,
    required this.startTime,
    required this.endTime,
    required this.startAt,
    required this.endAt,
  });

  final String text;

  /// Seconds from the start of the session, from the VAD segment's sample
  /// indices via [VadTimeline].
  final double startTime;
  final double endTime;

  /// Wall clock, derived the same way as [startTime]/[endTime].
  final DateTime startAt;
  final DateTime endAt;
}

// ---------------------------------------------------------------------------
// Core
// ---------------------------------------------------------------------------

/// The decode loop, with no isolate and no native code of its own.
///
/// Audio is fed to a [VadApi], which cuts it into whole utterances bounded by
/// silence; each completed utterance is popped off the detector's queue and
/// decoded as one Whisper call. There is deliberately no timer anywhere in
/// this class: a fixed tick would cut mid-word, a silence boundary does not.
class WhisperWorkerCore {
  WhisperWorkerCore({
    required this.emit,
    VadFactory? vadFactory,
    WhisperRecognizerFactory? recognizerFactory,
  })  : _vadFactory = vadFactory ?? SileroVad.create,
        _recognizerFactory = recognizerFactory ?? WhisperOnnxRecognizer.create;

  /// Where finalized segments go. In the worker this is `IsolateWorker.emit`.
  final void Function(Object? event) emit;

  final VadFactory _vadFactory;
  final WhisperRecognizerFactory _recognizerFactory;

  VadApi? _vad;
  WhisperRecognizerApi? _recognizer;
  WhisperWorkerConfig? _config;

  /// Anchors [VadTimeline]'s sample-zero to the wall clock of the very first
  /// chunk fed this session. Set once and never touched again: re-anchoring
  /// on a later chunk would make timestamps depend on how far behind real
  /// time the feed loop happened to be, rather than being fixed the moment
  /// the session starts. This is why timestamps are deterministic under test
  /// and independent of decode latency.
  VadTimeline? _timeline;

  /// Handles one command. Suitable as an [IsolateRequestHandler].
  Object? handle(Object? command) {
    if (command is WhisperInitCommand) {
      _init(command.config);
      return null;
    }
    if (command is WhisperFeedCommand) {
      _feed(command.pcm16.materialize().asUint8List(), command.at);
      return null;
    }
    if (command is WhisperFlushCommand) {
      _flush();
      return null;
    }
    if (command is WhisperStopCommand) {
      _stop();
      return null;
    }
    throw ArgumentError('unknown whisper worker command: $command');
  }

  void _init(WhisperWorkerConfig config) {
    if (_recognizer != null) return;
    _config = config;
    _vad = _vadFactory(config.vad);
    _recognizer = _recognizerFactory(config);
  }

  void _feed(Uint8List pcm16, DateTime at) {
    final vad = _vad;
    final config = _config;
    if (vad == null || config == null) {
      throw StateError('whisper worker fed audio before init');
    }

    final samples = pcm16ToFloat32(pcm16);
    if (samples.isEmpty) return;

    _timeline ??= VadTimeline(start: at, sampleRate: config.sampleRate);

    vad.acceptWaveform(samples);
    _drain();
  }

  void _drain() {
    final vad = _vad;
    final recognizer = _recognizer;
    final timeline = _timeline;
    final config = _config;
    if (vad == null || recognizer == null || timeline == null || config == null) {
      return;
    }

    while (!vad.isEmpty) {
      final segment = vad.front();
      // Pop before decoding: a recognizer that throws on this segment must
      // not wedge the drain loop on it forever.
      vad.pop();

      final text = recognizer.recognize(segment.samples, config.sampleRate).trim();
      if (text.isEmpty) continue;

      final times = timeline.times(segment);
      emit(WhisperSegmentEvent(
        text: text,
        startTime: times.startTime,
        endTime: times.endTime,
        startAt: times.startAt,
        endAt: times.endAt.isBefore(times.startAt) ? times.startAt : times.endAt,
      ));
    }
  }

  void _flush() {
    _vad?.flush();
    _drain();
  }

  void _stop() {
    final vad = _vad;
    final recognizer = _recognizer;
    if (vad == null && recognizer == null) return;
    try {
      vad?.flush();
      _drain();
    } finally {
      _vad = null;
      _recognizer = null;
      _config = null;
      _timeline = null;
      vad?.dispose();
      recognizer?.dispose();
    }
  }

  /// Frees the VAD and the recognizer without emitting anything. Called when
  /// the isolate is torn down without a [WhisperStopCommand].
  void disposeQuietly() {
    _vad?.dispose();
    _recognizer?.dispose();
    _vad = null;
    _recognizer = null;
  }
}

// ---------------------------------------------------------------------------
// Real recognizer
// ---------------------------------------------------------------------------

/// [WhisperRecognizerApi] on top of the real sherpa-onnx offline bindings.
/// Only ever constructed inside the worker isolate.
class WhisperOnnxRecognizer implements WhisperRecognizerApi {
  WhisperOnnxRecognizer._(this._recognizer);

  final sherpa.OfflineRecognizer _recognizer;
  bool _disposed = false;

  /// Loads the model in [config]. Throws a [StateError] naming the missing
  /// file when the model is not on disk — downloading it is `model_store`'s
  /// job (LO-40), not the worker's.
  static WhisperRecognizerApi create(WhisperWorkerConfig config) {
    for (final path in <String>[
      config.encoderPath,
      config.decoderPath,
      config.tokensPath,
    ]) {
      if (!File(path).existsSync()) {
        throw StateError(
          'Whisper model file missing: $path. Install the Whisper model from '
          'the Models screen before local transcription can start.',
        );
      }
    }

    // Bindings are per-isolate statics, so this runs in the worker.
    sherpa.initBindings(config.nativeLibraryDir);

    final recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder: config.encoderPath,
            decoder: config.decoderPath,
          ),
          tokens: config.tokensPath,
          numThreads: config.numThreads,
          debug: false,
        ),
      ),
    );
    return WhisperOnnxRecognizer._(recognizer);
  }

  @override
  String recognize(Float32List samples, int sampleRate) {
    final stream = _recognizer.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
      _recognizer.decode(stream);
      return _recognizer.getResult(stream).text;
    } finally {
      stream.free();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _recognizer.free();
  }
}

// ---------------------------------------------------------------------------
// Isolate entry point and client
// ---------------------------------------------------------------------------

/// Worker isolate entry point. Top-level, as [Isolate.spawn] requires.
Future<void> whisperWorkerMain(IsolateBootstrap bootstrap) {
  WhisperWorkerCore? core;
  return IsolateWorker.serve(
    bootstrap,
    (worker) {
      core = WhisperWorkerCore(emit: worker.emit);
      return core!.handle;
    },
    onShutdown: () => core?.disposeQuietly(),
  );
}

/// The main-isolate handle to a running worker. An interface so callers can
/// be tested without spawning an isolate.
abstract class WhisperWorkerClient {
  /// Starts the worker and loads the VAD and the model. Throws if either
  /// cannot be loaded.
  Future<void> start(WhisperWorkerConfig config);

  /// [WhisperSegmentEvent]s, plus [IsolateWorkerError]s for failures that
  /// happened outside a request. Stream errors mean the worker died.
  Stream<Object?> get events;

  /// Hands one PCM16 chunk to the worker. Never waits for the decode.
  void feed(Uint8List pcm16, DateTime at);

  /// Flushes whatever utterance is in progress and emits it. The worker
  /// keeps running afterwards.
  Future<void> flush();

  /// Flushes the tail, then shuts the worker down. Any final segment reaches
  /// [events] before this future completes.
  Future<void> stop();
}

/// [WhisperWorkerClient] backed by a real isolate.
///
/// [events] is a controller of this object's own rather than the channel's,
/// so a caller can subscribe before [start] has spawned anything. Forwarding
/// is synchronous, which keeps a final segment ahead of the answer to the
/// [WhisperStopCommand] that produced it.
class IsolateWhisperWorkerClient implements WhisperWorkerClient {
  final StreamController<Object?> _events =
      StreamController<Object?>.broadcast(sync: true);

  IsolateChannel? _channel;
  StreamSubscription<Object?>? _channelEvents;

  @override
  Stream<Object?> get events => _events.stream;

  @override
  Future<void> start(WhisperWorkerConfig config) async {
    final channel = await IsolateChannel.spawn(
      whisperWorkerMain,
      debugName: 'whisper-worker',
    );
    _channel = channel;
    _channelEvents = channel.events.listen(
      (event) {
        if (!_events.isClosed) _events.add(event);
      },
      onError: (Object error) {
        if (!_events.isClosed) _events.addError(error);
      },
    );
    try {
      await channel.request(WhisperInitCommand(config));
    } catch (_) {
      await _shutdown(channel);
      rethrow;
    }
  }

  @override
  void feed(Uint8List pcm16, DateTime at) {
    // fromList takes ownership of the buffer it is given, so the caller hands
    // us a copy it no longer shares.
    //
    // Nothing bounds how many of these the worker's port can hold: a decode
    // that falls behind real time grows the queue. At 16 kHz mono that is
    // 32 kB per second of backlog, and the Omi path drops audio upstream long
    // before it matters, so a bound is deliberately left to whoever first
    // measures a need for one.
    _channel?.notify(
      WhisperFeedCommand(
          TransferableTypedData.fromList(<Uint8List>[pcm16]), at),
    );
  }

  @override
  Future<void> flush() async {
    final channel = _channel;
    if (channel == null) return;
    try {
      await channel.request(const WhisperFlushCommand());
    } catch (_) {
      // A worker that already died has nothing left to flush.
    }
  }

  @override
  Future<void> stop() async {
    final channel = _channel;
    if (channel == null) {
      // Never started, or already stopped: there is no isolate to flush, but
      // the controller is this object's own and still needs closing.
      if (!_events.isClosed) await _events.close();
      return;
    }
    try {
      await channel.request(const WhisperStopCommand());
    } catch (_) {
      // A worker that already died has nothing left to flush; the shutdown
      // below is still the right cleanup.
    }
    await _shutdown(channel);
  }

  Future<void> _shutdown(IsolateChannel channel) async {
    _channel = null;
    await channel.close();
    await _channelEvents?.cancel();
    _channelEvents = null;
    await _events.close();
  }
}
