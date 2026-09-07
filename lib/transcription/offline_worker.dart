/// The sherpa-onnx offline recognizers — Whisper and SenseVoice — and the
/// only file allowed to import the plugin for batch decoding (LO-42, LO-71).
///
/// This is the only offline decode path. Everything that touches the native
/// recognizer runs in a worker isolate, same as the streaming path. The
/// layering is:
///
/// * [OfflineRecognizerApi] — the one native call an utterance decode needs,
///   behind an interface so [OfflineWorkerCore] is testable without a model.
/// * [OfflineWorkerCore] — feeds PCM16 to a [VadApi], and decodes whatever
///   utterance the detector cuts out. Pure Dart, no isolate, no plugin.
/// * [offlineWorkerMain] — the isolate entry point wiring the core to an
///   [IsolateWorker].
/// * [OfflineWorkerClient] — the main-isolate handle the transcriber talks
///   to.
///
/// Which recognizer gets built is a property of the [ModelSpec] the caller
/// hands in, resolved by [buildOfflineRecognizerConfig]. Everything below
/// that line — VAD segmentation, timestamps, the isolate protocol — is
/// identical for every offline model, which is why LO-71 added SenseVoice by
/// widening one factory rather than by growing a second worker.
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
import 'model_catalog.dart';
import 'sherpa_worker.dart' show pcm16ToFloat32;
import 'vad.dart';

/// How to build the recognizer. Sent to the worker as-is, so every field must
/// be sendable across an isolate boundary.
class OfflineWorkerConfig {
  const OfflineWorkerConfig({
    required this.model,
    required this.modelDir,
    required this.vad,
    this.numThreads = 2,
    this.sampleRate = 16000,
    this.nativeLibraryDir,
    this.language = '',
    this.task = '',
  });

  /// Which model to load, and — through [ModelSpec.requiredFiles] — what its
  /// files are called.
  ///
  /// The spec travels rather than a size string or an id because file names
  /// then have exactly one home, `model_catalog.dart`. Callers must reduce a
  /// raw settings value through [ModelCatalog.offlineModel] first, so a
  /// stale preference cannot name a model that is not installable.
  final ModelSpec model;

  /// Directory holding the model files. Supplied by the caller — model
  /// download and layout belong to `model_store.dart` (LO-40), not here.
  final String modelDir;

  /// Detector this worker segments speech with, before any decode.
  final VadConfig vad;

  final int numThreads;

  /// Sample rate of the PCM16 the worker is fed. The Omi path and the phone
  /// mic both deliver 16 kHz.
  final int sampleRate;

  /// Where to load `libsherpa-onnx-c-api` from. Null on device, where the
  /// bundled library is already on the loader's search path; set only by the
  /// desktop integration test, which runs outside a Flutter app bundle.
  final String? nativeLibraryDir;

  /// BCP-47-ish language code forwarded to the recognizer (e.g. `'en'`,
  /// `'ko'`).
  ///
  /// Both offline model families take one, and both read `''` as "detect the
  /// language from the audio". SenseVoice spells that `'auto'` instead, so
  /// [buildOfflineRecognizerConfig] passes it through
  /// [ModelCatalog.senseVoiceLanguage] rather than verbatim — a code
  /// SenseVoice was not trained on would otherwise decode *into* that
  /// language rather than fail.
  final String language;

  /// Forwarded to `sherpa.OfflineWhisperModelConfig.task`. `''` (the
  /// default) and `'transcribe'` behave the same; `'translate'` would ask
  /// Whisper to translate into English instead, which nothing here does.
  /// SenseVoice has no such option and ignores this.
  final String task;

  /// Absolute paths of every file the recognizer opens, in
  /// [ModelSpec.requiredFiles] order. Exactly what
  /// [SherpaOfflineRecognizer.create] checks for before loading anything.
  List<String> get modelPaths =>
      [for (final name in model.requiredFiles) '$modelDir/$name'];

  /// The one file in [modelPaths] whose name ends with [suffix].
  ///
  /// Throws a [StateError] naming the model when the catalog entry has no
  /// such file, which is a catalog bug rather than a missing download — the
  /// catalog test pins the file lists precisely so this cannot reach a user.
  String modelPathEndingWith(String suffix) {
    final matches =
        modelPaths.where((path) => path.endsWith(suffix)).toList();
    if (matches.length != 1) {
      throw StateError(
        'model ${model.id} declares ${matches.length} files ending in '
        '"$suffix"; exactly one is required',
      );
    }
    return matches.single;
  }
}

/// The sherpa-onnx recognizer configuration [config] describes.
///
/// Pure: it builds plain Dart config objects and loads nothing, so the
/// Whisper-vs-SenseVoice mapping is unit-testable without a model on disk or
/// the native library present.
sherpa.OfflineRecognizerConfig buildOfflineRecognizerConfig(
    OfflineWorkerConfig config) {
  switch (config.model.kind) {
    case ModelKind.whisper:
      return sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder: config.modelPathEndingWith('encoder.onnx'),
            decoder: config.modelPathEndingWith('decoder.onnx'),
            language: config.language,
            task: config.task,
          ),
          tokens: config.modelPathEndingWith('tokens.txt'),
          numThreads: config.numThreads,
          debug: false,
        ),
      );
    case ModelKind.senseVoice:
      return sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          senseVoice: sherpa.OfflineSenseVoiceModelConfig(
            model: config.modelPathEndingWith('.onnx'),
            language: ModelCatalog.senseVoiceLanguage(config.language),
            // Numbers, dates and times come back written out as words
            // without this ("twenty twenty six"), which reads badly in a
            // transcript the intelligence layer then summarizes.
            useInverseTextNormalization: true,
          ),
          tokens: config.modelPathEndingWith('tokens.txt'),
          numThreads: config.numThreads,
          debug: false,
        ),
      );
    case ModelKind.streamingZipformer:
    case ModelKind.vad:
      throw ArgumentError(
        '${config.model.id} is a ${config.model.kind} model and cannot be '
        'decoded by the offline worker',
      );
  }
}

/// The slice of sherpa-onnx's offline recognizer an utterance decode needs.
/// Implemented for real by [SherpaOfflineRecognizer] and faked in tests.
abstract class OfflineRecognizerApi {
  /// Decodes one whole utterance and returns its text.
  String recognize(Float32List samples, int sampleRate);

  void dispose();
}

/// Builds a recognizer for [config]. Swapped out in tests.
typedef OfflineRecognizerFactory = OfflineRecognizerApi Function(
    OfflineWorkerConfig config);

// ---------------------------------------------------------------------------
// Worker protocol
// ---------------------------------------------------------------------------

/// Builds the VAD and the recognizer. Answered once both are loaded, or with
/// an error if either could not be.
class OfflineInitCommand {
  const OfflineInitCommand(this.config);
  final OfflineWorkerConfig config;
}

/// One chunk of PCM16 audio. Sent as a notification — the main isolate never
/// waits for a decode. The bytes travel as [TransferableTypedData] so they
/// are moved rather than copied.
class OfflineFeedCommand {
  const OfflineFeedCommand(this.pcm16, this.at);

  final TransferableTypedData pcm16;

  /// Wall clock at which this chunk's first sample was captured.
  final DateTime at;
}

/// Flushes the detector's tail, emits whatever utterance was still in
/// progress, and keeps the worker running.
class OfflineFlushCommand {
  const OfflineFlushCommand();
}

/// Flushes the tail, emits it, and frees the VAD and the recognizer.
class OfflineStopCommand {
  const OfflineStopCommand();
}

/// One decoded utterance, on its way back to the main isolate.
class OfflineSegmentEvent {
  const OfflineSegmentEvent({
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
/// decoded as one recognizer call. There is deliberately no timer anywhere in
/// this class: a fixed tick would cut mid-word, a silence boundary does not.
class OfflineWorkerCore {
  OfflineWorkerCore({
    required this.emit,
    VadFactory? vadFactory,
    OfflineRecognizerFactory? recognizerFactory,
  })  : _vadFactory = vadFactory ?? SileroVad.create,
        _recognizerFactory = recognizerFactory ?? SherpaOfflineRecognizer.create;

  /// Where finalized segments go. In the worker this is `IsolateWorker.emit`.
  final void Function(Object? event) emit;

  final VadFactory _vadFactory;
  final OfflineRecognizerFactory _recognizerFactory;

  VadApi? _vad;
  OfflineRecognizerApi? _recognizer;
  OfflineWorkerConfig? _config;

  /// Anchors [VadTimeline]'s sample-zero to the wall clock of the very first
  /// chunk fed this session. Set once and never touched again: re-anchoring
  /// on a later chunk would make timestamps depend on how far behind real
  /// time the feed loop happened to be, rather than being fixed the moment
  /// the session starts. This is why timestamps are deterministic under test
  /// and independent of decode latency.
  VadTimeline? _timeline;

  /// Handles one command. Suitable as an [IsolateRequestHandler].
  Object? handle(Object? command) {
    if (command is OfflineInitCommand) {
      _init(command.config);
      return null;
    }
    if (command is OfflineFeedCommand) {
      _feed(command.pcm16.materialize().asUint8List(), command.at);
      return null;
    }
    if (command is OfflineFlushCommand) {
      _flush();
      return null;
    }
    if (command is OfflineStopCommand) {
      _stop();
      return null;
    }
    throw ArgumentError('unknown offline worker command: $command');
  }

  void _init(OfflineWorkerConfig config) {
    if (_recognizer != null) return;
    // Two sample rates that have to agree: the detector cuts segments by
    // sample index and [VadTimeline] turns those indices back into seconds
    // using this config's rate, so a mismatch would silently skew every
    // timestamp rather than fail.
    if (config.sampleRate != config.vad.sampleRate) {
      throw ArgumentError(
        'offline worker sample rate ${config.sampleRate} does not match the '
        'VAD sample rate ${config.vad.sampleRate}',
      );
    }
    _config = config;
    _vad = _vadFactory(config.vad);
    _recognizer = _recognizerFactory(config);
  }

  void _feed(Uint8List pcm16, DateTime at) {
    final vad = _vad;
    final config = _config;
    if (vad == null || config == null) {
      throw StateError('offline worker fed audio before init');
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
      emit(OfflineSegmentEvent(
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
  /// the isolate is torn down without a [OfflineStopCommand].
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

/// [OfflineRecognizerApi] on top of the real sherpa-onnx offline bindings.
/// Only ever constructed inside the worker isolate.
class SherpaOfflineRecognizer implements OfflineRecognizerApi {
  SherpaOfflineRecognizer._(this._recognizer);

  final sherpa.OfflineRecognizer _recognizer;
  bool _disposed = false;

  /// Loads the model in [config]. Throws a [StateError] naming the missing
  /// file when the model is not on disk — downloading it is `model_store`'s
  /// job (LO-40), not the worker's.
  static OfflineRecognizerApi create(OfflineWorkerConfig config) {
    for (final path in config.modelPaths) {
      if (!File(path).existsSync()) {
        throw StateError(
          '${config.model.displayName} model file missing: $path. Install '
          'the model from the Models screen before local transcription can '
          'start.',
        );
      }
    }

    // Built before the bindings are touched: an unsupported model kind is a
    // programming error, and finding out about it without having loaded a
    // native library first keeps the failure clean.
    final recognizerConfig = buildOfflineRecognizerConfig(config);

    // Bindings are per-isolate statics, so this runs in the worker.
    sherpa.initBindings(config.nativeLibraryDir);

    final recognizer = sherpa.OfflineRecognizer(recognizerConfig);
    return SherpaOfflineRecognizer._(recognizer);
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
Future<void> offlineWorkerMain(IsolateBootstrap bootstrap) {
  OfflineWorkerCore? core;
  return IsolateWorker.serve(
    bootstrap,
    (worker) {
      core = OfflineWorkerCore(emit: worker.emit);
      return core!.handle;
    },
    onShutdown: () => core?.disposeQuietly(),
  );
}

/// The main-isolate handle to a running worker. An interface so callers can
/// be tested without spawning an isolate.
abstract class OfflineWorkerClient {
  /// Starts the worker and loads the VAD and the model. Throws if either
  /// cannot be loaded.
  Future<void> start(OfflineWorkerConfig config);

  /// [OfflineSegmentEvent]s, plus [IsolateWorkerError]s for failures that
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

/// [OfflineWorkerClient] backed by a real isolate.
///
/// [events] is a controller of this object's own rather than the channel's,
/// so a caller can subscribe before [start] has spawned anything. Forwarding
/// is synchronous, which keeps a final segment ahead of the answer to the
/// [OfflineStopCommand] that produced it.
class IsolateOfflineWorkerClient implements OfflineWorkerClient {
  final StreamController<Object?> _events =
      StreamController<Object?>.broadcast(sync: true);

  IsolateChannel? _channel;
  StreamSubscription<Object?>? _channelEvents;

  @override
  Stream<Object?> get events => _events.stream;

  @override
  Future<void> start(OfflineWorkerConfig config) async {
    final channel = await IsolateChannel.spawn(
      offlineWorkerMain,
      debugName: 'offline-worker',
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
      await channel.request(OfflineInitCommand(config));
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
      OfflineFeedCommand(
          TransferableTypedData.fromList(<Uint8List>[pcm16]), at),
    );
  }

  @override
  Future<void> flush() async {
    final channel = _channel;
    if (channel == null) return;
    try {
      await channel.request(const OfflineFlushCommand());
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
      await channel.request(const OfflineStopCommand());
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
