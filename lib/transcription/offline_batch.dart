/// [StreamingTranscriber] for the on-device offline batch path (Whisper or
/// SenseVoice, whichever the settings pick).
///
/// Both the recognizer and the Silero VAD it segments audio with live
/// in a worker isolate (`offline_worker.dart`), so nothing here decodes
/// audio: this file resolves the recognizer and VAD model directories, starts
/// the worker, forwards PCM16 chunks to it and turns the segments it sends
/// back into [TranscriptSegment]s. That is why `package:sherpa_onnx` is not
/// imported here — see LO-42 in `docs/06-roadmap.md`.
///
/// "Batch" no longer means the fixed 3-second timer the deleted
/// `services/whisper_service.dart` ran: it means one decode per
/// VAD-detected utterance, so a decode never cuts audio mid-word. LO-51
/// retired that service along with the SD-card import stubs that were its
/// last caller; file transcription now goes through
/// `transcription/offline_file_transcriber.dart`.
library;

import 'dart:async';
import 'dart:typed_data';

import '../audio/audio_source.dart';
import '../core/models.dart';
import 'isolate_channel.dart';
import 'model_catalog.dart';
import 'model_store.dart';
import 'transcriber.dart';
import 'vad.dart';
import 'offline_worker.dart';

/// Always consumes raw PCM16: the recognizer never sees Opus, because the
/// Omi path decodes Opus to PCM before handing audio to a transcriber.
class OfflineBatchTranscriber implements StreamingTranscriber {
  OfflineBatchTranscriber({
    this.modelId = '',
    this.language = 'en',
    String? modelDir,
    String? vadModelPath,
    int numThreads = 2,
    ModelStore? modelStore,
    OfflineWorkerClient? workerClient,
  })  : _modelDir = modelDir,
        _vadModelPath = vadModelPath,
        _numThreads = numThreads,
        _modelStore = modelStore,
        _client = workerClient ?? IsolateOfflineWorkerClient();

  /// Catalog id of the offline model to decode with, straight off
  /// `SettingsService.offlineSttModelId`. Reduced through
  /// [ModelCatalog.offlineModel] in [start], so `''` — and any id this build
  /// does not know — resolves to [ModelCatalog.defaultOfflineModel] rather
  /// than failing.
  final String modelId;

  /// [modelId] resolved to a catalog entry, and the single place this class
  /// reduces it.
  ModelSpec get model => ModelCatalog.offlineModel(modelId);

  /// Language to transcribe in (`'en'` or `'ko'`, LO-44). Reduced through
  /// [ModelCatalog.localSttLanguage] in [start] before it reaches the
  /// worker — same defensive contract [modelId] gets, so a stale or
  /// corrupted preference cannot leave the worker with a language the
  /// catalog does not offer.
  final String language;

  /// Where the model files live. Null means "wherever the [ModelStore]
  /// installed `ModelCatalog.offlineModel(modelId)`", resolved on
  /// [start].
  final String? _modelDir;

  /// Path to the installed `silero_vad.onnx`. Null means "wherever the
  /// [ModelStore] installed [ModelCatalog.sileroVad]", resolved on [start].
  final String? _vadModelPath;

  final int _numThreads;

  /// Only consulted when [_modelDir] or [_vadModelPath] is null. Injectable
  /// so a test never touches `path_provider`.
  final ModelStore? _modelStore;

  final OfflineWorkerClient _client;

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
    final String vadModelPath;
    try {
      // Built lazily and reused for both lookups, rather than one ModelStore
      // per model.
      final store = _modelStore ?? ModelStore();
      modelDir = _modelDir ??
          await store.requireInstalledDir(model);
      vadModelPath = _vadModelPath ??
          '${await store.requireInstalledDir(ModelCatalog.sileroVad)}/'
              '${ModelCatalog.sileroVadFileName}';
    } catch (e) {
      // ModelNotInstalledException's message names the screen that fixes it,
      // so it is worth surfacing verbatim.
      _reportError('$e');
      rethrow;
    }

    final config = OfflineWorkerConfig(
      model: model,
      modelDir: modelDir,
      vad: VadConfig(modelPath: vadModelPath),
      numThreads: _numThreads,
      // Reduced through ModelCatalog.localSttLanguage, same as the model
      // above: an empty language would let the recognizer auto-detect and
      // risk mislabeling Korean speech as something else.
      //
      // The trade-off is deliberate and is a behaviour change: before LO-44
      // this path passed no language at all, so Whisper auto-detected. It is
      // now pinned to whatever the settings picker holds, which means a user
      // speaking a third language into local Whisper no longer gets
      // detection. Widening `ModelCatalog.localSttLanguages` — or adding an
      // explicit "auto" entry that maps back to '' — is how that comes back.
      language: ModelCatalog.localSttLanguage(language),
      task: 'transcribe',
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
      _reportError('Failed to start ${model.displayName}: $e');
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
    if (event is OfflineSegmentEvent) {
      if (_segmentsController.isClosed) return;
      _segmentsController.add(TranscriptSegment(
        text: event.text,
        // Neither offline recognizer diarizes, so every segment is speaker 0 — the
        // same assumption the upstream service made.
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
