/// The sherpa-onnx streaming recognizer, and the only file allowed to import
/// it (LO-41).
///
/// Everything that touches the native recognizer runs in a worker isolate so
/// the decode loop never shares a thread with the BLE callbacks and the UI.
/// The layering is:
///
/// * [SherpaRecognizerApi] — the four native calls the decode loop needs,
///   behind an interface so [SherpaWorkerCore] is testable without a model.
/// * [SherpaWorkerCore] — PCM16 to float, decode, endpoint detection and
///   timestamps. Pure Dart, no isolate, no plugin.
/// * [sherpaWorkerMain] — the isolate entry point wiring the core to an
///   [IsolateWorker].
/// * [SherpaWorkerClient] — the main-isolate handle the transcriber talks to.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'isolate_channel.dart';

/// How to build the recognizer. Sent to the worker as-is, so every field must
/// be sendable across an isolate boundary.
class SherpaWorkerConfig {
  const SherpaWorkerConfig({
    required this.modelDir,
    this.encoder = 'encoder-epoch-99-avg-1.onnx',
    this.decoder = 'decoder-epoch-99-avg-1.onnx',
    this.joiner = 'joiner-epoch-99-avg-1.onnx',
    this.tokens = 'tokens.txt',
    this.numThreads = 2,
    this.enableEndpoint = true,
    this.sampleRate = 16000,
    this.nativeLibraryDir,
  });

  /// Directory holding the model files. Supplied by the caller — model
  /// download and layout belong to `model_store.dart` (LO-40), not here.
  final String modelDir;

  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;

  final int numThreads;
  final bool enableEndpoint;

  /// Sample rate of the PCM16 the worker is fed. The Omi path and the phone
  /// mic both deliver 16 kHz.
  final int sampleRate;

  /// Where to load `libsherpa-onnx-c-api` from. Null on device, where the
  /// bundled library is already on the loader's search path; set only by the
  /// desktop integration test, which runs outside a Flutter app bundle.
  final String? nativeLibraryDir;

  String get encoderPath => '$modelDir/$encoder';
  String get decoderPath => '$modelDir/$decoder';
  String get joinerPath => '$modelDir/$joiner';
  String get tokensPath => '$modelDir/$tokens';
}

/// One decoded utterance, as the recognizer sees it: the text plus the
/// per-token timestamps in seconds from the start of the utterance.
class SherpaRecognition {
  const SherpaRecognition({required this.text, required this.timestamps});

  final String text;
  final List<double> timestamps;
}

/// The slice of sherpa-onnx the decode loop uses. Implemented for real by
/// [SherpaOnnxRecognizer] and faked in tests.
abstract class SherpaRecognizerApi {
  void acceptWaveform(Float32List samples, int sampleRate);

  /// True while [decode] still has frames to consume.
  bool get isReady;
  void decode();

  /// True when the recognizer decided the utterance ended.
  bool get isEndpoint;

  SherpaRecognition getResult();

  /// Clears the stream so the next utterance starts from zero.
  void reset();

  /// Tells the recognizer no more audio is coming, so the tail can be
  /// decoded.
  void inputFinished();

  void dispose();
}

/// Builds a recognizer for [config]. Swapped out in tests.
typedef SherpaRecognizerFactory = SherpaRecognizerApi Function(
    SherpaWorkerConfig config);

// ---------------------------------------------------------------------------
// Worker protocol
// ---------------------------------------------------------------------------

/// Builds the recognizer. Answered once the model is loaded, or with an error
/// if it could not be.
class SherpaInitCommand {
  const SherpaInitCommand(this.config);
  final SherpaWorkerConfig config;
}

/// One chunk of PCM16 audio. Sent as a notification — the main isolate never
/// waits for a decode. The bytes travel as [TransferableTypedData] so they
/// are moved rather than copied.
class SherpaFeedCommand {
  const SherpaFeedCommand(this.pcm16, this.at);

  final TransferableTypedData pcm16;

  /// Wall clock at which this chunk's first sample was captured.
  final DateTime at;
}

/// Drops the current utterance without emitting it.
class SherpaResetCommand {
  const SherpaResetCommand();
}

/// Flushes the tail, emits whatever is left, and frees the recognizer.
class SherpaStopCommand {
  const SherpaStopCommand();
}

/// One finalized utterance, on its way back to the main isolate.
class SherpaSegmentEvent {
  const SherpaSegmentEvent({
    required this.text,
    required this.startTime,
    required this.endTime,
    required this.startAt,
    required this.endAt,
  });

  final String text;

  /// Seconds from the start of the utterance, from the token timestamps.
  final double startTime;
  final double endTime;

  /// Wall clock, derived from the [SherpaFeedCommand.at] of the chunks that
  /// made up this utterance.
  final DateTime startAt;
  final DateTime endAt;
}

// ---------------------------------------------------------------------------
// Core
// ---------------------------------------------------------------------------

/// The decode loop, with no isolate and no native code of its own.
///
/// Wall-clock timestamps come from the audio timeline rather than from
/// `DateTime.now()`: [SherpaSegmentEvent.startAt] is the `at` of the first
/// chunk of the utterance and [SherpaSegmentEvent.endAt] is the end of the
/// chunk that tripped the endpoint (`at` plus the chunk's own duration).
/// That is both more accurate than reading the clock after a decode and
/// deterministic under test.
class SherpaWorkerCore {
  SherpaWorkerCore({
    required this.emit,
    SherpaRecognizerFactory? recognizerFactory,
  }) : _factory = recognizerFactory ?? SherpaOnnxRecognizer.create;

  /// Where finalized segments go. In the worker this is `IsolateWorker.emit`.
  final void Function(Object? event) emit;

  final SherpaRecognizerFactory _factory;

  SherpaRecognizerApi? _recognizer;
  SherpaWorkerConfig? _config;

  /// Wall clock of the first chunk of the utterance being decoded.
  DateTime? _utteranceStart;

  /// End of the most recent chunk, used as the end of a tail flushed by
  /// [SherpaStopCommand].
  DateTime? _lastChunkEnd;

  /// Handles one command. Suitable as an [IsolateRequestHandler].
  Object? handle(Object? command) {
    if (command is SherpaInitCommand) {
      _init(command.config);
      return null;
    }
    if (command is SherpaFeedCommand) {
      _feed(command.pcm16.materialize().asUint8List(), command.at);
      return null;
    }
    if (command is SherpaResetCommand) {
      _resetUtterance();
      return null;
    }
    if (command is SherpaStopCommand) {
      _stop();
      return null;
    }
    throw ArgumentError('unknown sherpa worker command: $command');
  }

  void _init(SherpaWorkerConfig config) {
    if (_recognizer != null) return;
    _config = config;
    _recognizer = _factory(config);
  }

  void _feed(Uint8List pcm16, DateTime at) {
    final recognizer = _recognizer;
    final config = _config;
    if (recognizer == null || config == null) {
      throw StateError('sherpa worker fed audio before init');
    }

    final samples = pcm16ToFloat32(pcm16);
    if (samples.isEmpty) return;

    _utteranceStart ??= at;
    final chunkEnd = at.add(Duration(
      microseconds:
          (samples.length * Duration.microsecondsPerSecond / config.sampleRate)
              .round(),
    ));
    _lastChunkEnd = chunkEnd;

    recognizer.acceptWaveform(samples, config.sampleRate);
    while (recognizer.isReady) {
      recognizer.decode();
    }

    if (!recognizer.isEndpoint) return;

    final result = recognizer.getResult();
    // Reset on every endpoint, text or not: leaving a stream un-reset after
    // an endpoint keeps the next utterance's timestamps running on from this
    // one. Silence simply produces no segment.
    recognizer.reset();
    _emitSegment(result, chunkEnd);
    _utteranceStart = null;
  }

  void _resetUtterance() {
    _recognizer?.reset();
    _utteranceStart = null;
  }

  void _stop() {
    final recognizer = _recognizer;
    if (recognizer == null) return;
    try {
      recognizer.inputFinished();
      while (recognizer.isReady) {
        recognizer.decode();
      }
      _emitSegment(
        recognizer.getResult(),
        _lastChunkEnd ?? _utteranceStart ?? DateTime.now(),
      );
    } finally {
      _utteranceStart = null;
      _lastChunkEnd = null;
      _recognizer = null;
      recognizer.dispose();
    }
  }

  void _emitSegment(SherpaRecognition result, DateTime endAt) {
    final text = result.text.trim();
    if (text.isEmpty) return;
    final startAt = _utteranceStart ?? endAt;
    emit(SherpaSegmentEvent(
      text: text,
      startTime: result.timestamps.isEmpty ? 0 : result.timestamps.first,
      endTime: result.timestamps.isEmpty ? 0 : result.timestamps.last,
      startAt: startAt,
      endAt: endAt.isBefore(startAt) ? startAt : endAt,
    ));
  }

  /// Frees the recognizer without emitting anything. Called when the isolate
  /// is torn down without a [SherpaStopCommand].
  void disposeQuietly() {
    _recognizer?.dispose();
    _recognizer = null;
  }
}

/// Converts little-endian PCM16 bytes to the float samples sherpa wants.
/// A trailing odd byte is dropped: chunk boundaries can split a sample.
Float32List pcm16ToFloat32(Uint8List bytes) {
  final validLength = bytes.length - (bytes.length % 2);
  if (validLength == 0) return Float32List(0);

  // ByteData keeps this safe whatever the buffer's alignment is.
  final view = ByteData.sublistView(bytes, 0, validLength);
  final samples = Float32List(validLength ~/ 2);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return samples;
}

// ---------------------------------------------------------------------------
// Real recognizer
// ---------------------------------------------------------------------------

/// [SherpaRecognizerApi] on top of the real sherpa-onnx bindings. Only ever
/// constructed inside the worker isolate.
class SherpaOnnxRecognizer implements SherpaRecognizerApi {
  SherpaOnnxRecognizer._(this._recognizer, this._stream);

  final sherpa.OnlineRecognizer _recognizer;
  final sherpa.OnlineStream _stream;

  /// Loads the model in [config]. Throws a [StateError] naming the missing
  /// file when the model is not on disk — downloading it is `model_store`'s
  /// job (LO-40), not the worker's.
  static SherpaRecognizerApi create(SherpaWorkerConfig config) {
    for (final path in <String>[
      config.encoderPath,
      config.decoderPath,
      config.joinerPath,
      config.tokensPath,
    ]) {
      if (!File(path).existsSync()) {
        // Names the path rather than a place to fix it: the download UI is
        // LO-40's, and until it lands there is no screen to point at.
        throw StateError(
          'Sherpa model file missing: $path. The streaming model must be '
          'present under ${config.modelDir} before local transcription can '
          'start.',
        );
      }
    }

    // Bindings are per-isolate statics, so this runs in the worker.
    sherpa.initBindings(config.nativeLibraryDir);

    final recognizer = sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: config.encoderPath,
            decoder: config.decoderPath,
            joiner: config.joinerPath,
          ),
          tokens: config.tokensPath,
          numThreads: config.numThreads,
          debug: false,
        ),
        enableEndpoint: config.enableEndpoint,
      ),
    );
    return SherpaOnnxRecognizer._(recognizer, recognizer.createStream());
  }

  @override
  void acceptWaveform(Float32List samples, int sampleRate) =>
      _stream.acceptWaveform(samples: samples, sampleRate: sampleRate);

  @override
  bool get isReady => _recognizer.isReady(_stream);

  @override
  void decode() => _recognizer.decode(_stream);

  @override
  bool get isEndpoint => _recognizer.isEndpoint(_stream);

  @override
  SherpaRecognition getResult() {
    final result = _recognizer.getResult(_stream);
    return SherpaRecognition(text: result.text, timestamps: result.timestamps);
  }

  @override
  void reset() => _recognizer.reset(_stream);

  @override
  void inputFinished() => _stream.inputFinished();

  @override
  void dispose() {
    _stream.free();
    _recognizer.free();
  }
}

// ---------------------------------------------------------------------------
// Isolate entry point and client
// ---------------------------------------------------------------------------

/// Worker isolate entry point. Top-level, as [Isolate.spawn] requires.
Future<void> sherpaWorkerMain(IsolateBootstrap bootstrap) {
  SherpaWorkerCore? core;
  return IsolateWorker.serve(
    bootstrap,
    (worker) {
      core = SherpaWorkerCore(emit: worker.emit);
      return core!.handle;
    },
    onShutdown: () => core?.disposeQuietly(),
  );
}

/// The main-isolate handle to a running worker. An interface so
/// `SherpaStreamingTranscriber` can be tested without spawning an isolate.
abstract class SherpaWorkerClient {
  /// Starts the worker and loads the model. Throws if the model cannot be
  /// loaded.
  Future<void> start(SherpaWorkerConfig config);

  /// [SherpaSegmentEvent]s, plus [IsolateWorkerError]s for failures that
  /// happened outside a request. Stream errors mean the worker died.
  Stream<Object?> get events;

  /// Hands one PCM16 chunk to the worker. Never waits for the decode.
  void feed(Uint8List pcm16, DateTime at);

  /// Flushes the tail, then shuts the worker down. Any final segment reaches
  /// [events] before this future completes.
  Future<void> stop();
}

/// [SherpaWorkerClient] backed by a real isolate.
///
/// [events] is a controller of this object's own rather than the channel's,
/// so a caller can subscribe before [start] has spawned anything. Forwarding
/// is synchronous, which keeps a final segment ahead of the answer to the
/// [SherpaStopCommand] that produced it.
class IsolateSherpaWorkerClient implements SherpaWorkerClient {
  final StreamController<Object?> _events =
      StreamController<Object?>.broadcast(sync: true);

  IsolateChannel? _channel;
  StreamSubscription<Object?>? _channelEvents;

  @override
  Stream<Object?> get events => _events.stream;

  @override
  Future<void> start(SherpaWorkerConfig config) async {
    final channel = await IsolateChannel.spawn(
      sherpaWorkerMain,
      debugName: 'sherpa-worker',
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
      await channel.request(SherpaInitCommand(config));
    } catch (_) {
      await _shutdown(channel);
      rethrow;
    }
  }

  @override
  void feed(Uint8List pcm16, DateTime at) {
    // fromList takes ownership of the buffer it is given, so the caller hands
    // us a copy it no longer shares (see SherpaStreamingTranscriber.feed).
    //
    // Nothing bounds how many of these the worker's port can hold: a decode
    // that falls behind real time grows the queue. At 16 kHz mono that is
    // 32 kB per second of backlog, and the Omi path drops audio upstream long
    // before it matters, so a bound is deliberately left to whoever first
    // measures a need for one.
    _channel?.notify(
      SherpaFeedCommand(TransferableTypedData.fromList(<Uint8List>[pcm16]), at),
    );
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
      await channel.request(const SherpaStopCommand());
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
