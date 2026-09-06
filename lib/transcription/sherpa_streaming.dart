/// [StreamingTranscriber] for the on-device sherpa-onnx streaming Zipformer.
///
/// The recognizer itself lives in a worker isolate (`sherpa_worker.dart`), so
/// nothing here decodes audio: this file resolves the model directory, starts
/// the worker, forwards PCM16 chunks to it and turns the segments it sends
/// back into [TranscriptSegment]s. That is why `package:sherpa_onnx` is not
/// imported here — see LO-41 in `docs/06-roadmap.md`.
library;

import 'dart:async';
import 'dart:typed_data';

import '../audio/audio_source.dart';
import '../models/conversation.dart';
import 'isolate_channel.dart';
import 'model_catalog.dart';
import 'model_store.dart';
import 'sherpa_worker.dart';
import 'transcriber.dart';

/// Always consumes raw PCM16: sherpa never sees Opus, because the Omi path
/// decodes Opus to PCM before handing audio to a transcriber.
class SherpaStreamingTranscriber implements StreamingTranscriber {
  SherpaStreamingTranscriber({
    String? modelDir,
    int numThreads = 2,
    this.language = 'en',
    ModelStore? modelStore,
    SherpaWorkerClient? workerClient,
  })  : _modelDir = modelDir,
        _numThreads = numThreads,
        _modelStore = modelStore,
        _client = workerClient ?? IsolateSherpaWorkerClient();

  /// Where the model files live. Null means "wherever the [ModelStore]
  /// installed `ModelCatalog.streaming(language)`", resolved on [start].
  final String? _modelDir;

  final int _numThreads;

  /// Language to load the streaming model for (`'en'` or `'ko'`, LO-44).
  /// Reduced through [ModelCatalog.localSttLanguage] in [start]. Only
  /// consulted when [_modelDir] is null — an injected directory always wins.
  ///
  /// Not forwarded into [SherpaWorkerConfig]: both catalog specs
  /// ([ModelCatalog.streamingZipformerEn20M] and
  /// [ModelCatalog.streamingZipformerKo]) use the same four file names, so
  /// the worker's default encoder/decoder/joiner/tokens names already load
  /// either model unchanged (pinned by a `model_catalog_test.dart` case).
  final String language;

  /// Only consulted when [_modelDir] is null. Injectable so a test never
  /// touches `path_provider`.
  final ModelStore? _modelStore;

  final SherpaWorkerClient _client;

  StreamSubscription<Object?>? _events;
  bool _started = false;
  bool _stopped = false;

  final StreamController<TranscriptSegment> _segmentsController =
      StreamController<TranscriptSegment>.broadcast(sync: true);
  final StreamController<String> _errorsController =
      StreamController<String>.broadcast(sync: true);

  @override
  AudioEncoding get acceptedEncoding => AudioEncoding.pcm16;

  @override
  Stream<TranscriptSegment> get segments => _segmentsController.stream;

  @override
  Stream<String> get errors => _errorsController.stream;

  @override
  Future<void> start() async {
    if (_started || _stopped) return;
    _started = true;

    final String modelDir;
    try {
      modelDir = _modelDir ??
          await (_modelStore ?? ModelStore())
              .requireInstalledDir(ModelCatalog.streaming(language));
    } catch (e) {
      // ModelNotInstalledException's message names the screen that fixes it,
      // so it is worth surfacing verbatim.
      _reportError('$e');
      rethrow;
    }

    final config = SherpaWorkerConfig(
      modelDir: modelDir,
      numThreads: _numThreads,
    );

    // Subscribed before init so a model-loading failure inside the worker is
    // reported on [errors] as well as thrown.
    _events = _client.events.listen(
      _onWorkerEvent,
      onError: (Object error) => _reportError('$error'),
    );

    try {
      await _client.start(config);
    } catch (e) {
      _reportError('Failed to start Sherpa-ONNX: $e');
      rethrow;
    }
  }

  @override
  void feed(AudioChunk chunk) {
    if (!_started || _stopped) return;
    // Copied because the worker takes ownership of what it is handed and
    // the chunk's buffer is shared with the session's other consumers.
    _client.feed(Uint8List.fromList(chunk.bytes), chunk.at);
  }

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    if (_started) {
      await _client.stop();
    }
    await _events?.cancel();
    _events = null;
    await _segmentsController.close();
    await _errorsController.close();
  }

  void _onWorkerEvent(Object? event) {
    if (event is SherpaSegmentEvent) {
      if (_segmentsController.isClosed) return;
      _segmentsController.add(TranscriptSegment(
        text: event.text,
        // Sherpa has no diarization, so every segment is speaker 0 — the same
        // assumption the upstream service made.
        speakerId: 0,
        startTime: event.startTime,
        endTime: event.endTime,
        startAt: event.startAt,
        endAt: event.endAt,
      ));
      return;
    }
    if (event is IsolateWorkerError) {
      _reportError(event.message);
    }
  }

  void _reportError(String message) {
    if (!_errorsController.isClosed) _errorsController.add(message);
  }
}
