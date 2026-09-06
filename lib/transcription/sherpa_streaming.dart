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

import 'package:path_provider/path_provider.dart';

import '../audio/audio_source.dart';
import '../models/conversation.dart';
import 'isolate_channel.dart';
import 'sherpa_worker.dart';
import 'transcriber.dart';

/// Model the upstream service downloaded to, and the layout the default
/// [SherpaWorkerConfig] file names describe.
///
/// Transitional: model download, catalogue and on-disk layout move to
/// `model_store.dart` (LO-40), which will pass `modelDir` in explicitly and
/// let this constant and the `path_provider` import go away.
const String _defaultModelName =
    'sherpa-onnx-streaming-zipformer-en-20M-2023-02-17';

/// Always consumes raw PCM16: sherpa never sees Opus, because the Omi path
/// decodes Opus to PCM before handing audio to a transcriber.
class SherpaStreamingTranscriber implements StreamingTranscriber {
  SherpaStreamingTranscriber({
    String? modelDir,
    int numThreads = 2,
    SherpaWorkerClient? workerClient,
  })  : _modelDir = modelDir,
        _numThreads = numThreads,
        _client = workerClient ?? IsolateSherpaWorkerClient();

  /// Where the model files live. Null means the upstream location under the
  /// application documents directory, resolved on [start].
  final String? _modelDir;

  final int _numThreads;
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

    final config = SherpaWorkerConfig(
      modelDir: _modelDir ?? await _defaultModelDir(),
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

  static Future<String> _defaultModelDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/sherpa_models/$_defaultModelName';
  }
}
