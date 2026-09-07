/// [FileTranscriber] for the on-device offline decode path (LO-51).
///
/// Both the "whisper" and the "sherpa" on-device settings modes route FILE
/// transcription through this class rather than through their respective
/// streaming transcribers: pushing a whole recording through a streaming
/// model produces worse text than decoding each VAD-detected utterance
/// offline, one whole utterance at a time, the way `offline_batch.dart`
/// already does for a live session. See LO-51 in `docs/06-roadmap.md`.
///
/// This file resolves the recognizer and VAD model directories, starts the
/// worker isolate from `offline_worker.dart`, feeds it the WAV's PCM16 in
/// chunks and collects the segments it sends back. Nothing here decodes
/// audio itself.
library;

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

import '../audio/wav.dart';
import '../core/models.dart';
import 'isolate_channel.dart';
import 'model_catalog.dart';
import 'model_store.dart';
import 'transcriber.dart';
import 'vad.dart';
import 'offline_worker.dart';

/// Decodes a complete WAV file with the offline recognizer the settings pick.
///
/// Requires 16 kHz mono PCM16 input — the same assumption the worker's VAD
/// and the offline recognizers both make — and throws an [ArgumentError]
/// naming the actual format otherwise, rather than silently mistranscribing
/// resampled or multi-channel audio.
class OfflineFileTranscriber implements FileTranscriber {
  OfflineFileTranscriber({
    this.modelId = '',
    this.language = 'en',
    String? modelDir,
    String? vadModelPath,
    int numThreads = 2,
    this.nativeLibraryDir,
    ModelStore? modelStore,
    OfflineWorkerClient Function()? workerClientFactory,
    this.chunkBytes = 32000,
    this.recordingStartedAt,
  })  : _modelDir = modelDir,
        _vadModelPath = vadModelPath,
        _numThreads = numThreads,
        _modelStore = modelStore,
        _workerClientFactory =
            workerClientFactory ?? (() => IsolateOfflineWorkerClient());

  /// Catalog id of the offline model to decode with, straight off
  /// `SettingsService.offlineSttModelId` and reduced through
  /// [ModelCatalog.offlineModel] the same way
  /// `OfflineBatchTranscriber.modelId` is.
  final String modelId;

  /// [modelId] resolved to a catalog entry.
  ModelSpec get model => ModelCatalog.offlineModel(modelId);

  /// Language to transcribe in (`'en'` or `'ko'`). Reduced through
  /// [ModelCatalog.localSttLanguage] before it reaches the worker, same
  /// defensive contract `OfflineBatchTranscriber.language` uses for the
  /// streaming path.
  final String language;

  /// Where the model files live. Null means "wherever the [ModelStore]
  /// installed `ModelCatalog.offlineModel(modelId)`", resolved on
  /// [transcribe].
  final String? _modelDir;

  /// Path to the installed `silero_vad.onnx`. Null means "wherever the
  /// [ModelStore] installed [ModelCatalog.sileroVad]", resolved on
  /// [transcribe].
  final String? _vadModelPath;

  final int _numThreads;

  /// Where to load `libsherpa-onnx-c-api` from. Null on device; set only by
  /// a desktop integration test, same as [OfflineWorkerConfig.nativeLibraryDir].
  final String? nativeLibraryDir;

  /// Only consulted when a model directory above is null. Injectable so a
  /// test never touches `path_provider`.
  final ModelStore? _modelStore;

  final OfflineWorkerClient Function() _workerClientFactory;

  /// Bytes of PCM16 fed to the worker per [OfflineWorkerClient.feed] call.
  /// Defaults to 32000 bytes: one second of 16 kHz mono PCM16.
  final int chunkBytes;

  /// Wall-clock origin for the synthetic `at` each chunk is fed with. The
  /// worker derives every segment's wall-clock timestamps from the `at` of
  /// the first chunk plus the sample index reached since ([offline_worker.dart]),
  /// so a file transcode — which has no live capture clock — needs a
  /// stand-in origin. Defaults to [DateTime.now] at the start of
  /// [transcribe]; a caller that knows when the recording actually started
  /// (e.g. from the file's own metadata) can pass it here to get accurate
  /// [TranscriptSegment.startAt]/[TranscriptSegment.endAt] values.
  final DateTime? recordingStartedAt;

  @override
  Future<List<TranscriptSegment>> transcribe(File wav) async {
    final bytes = await wav.readAsBytes();
    final parsed = parseWav(bytes);
    // The sample width matters as much as the rate: `parseWav` accepts any
    // integer PCM, and 8-bit samples reinterpreted as PCM16 by
    // `pcm16ToFloat32` would decode into a confident-looking transcript of
    // noise rather than failing.
    if (parsed.sampleRate != wavSampleRate ||
        parsed.channels != wavChannels ||
        parsed.bitsPerSample != wavBitsPerSample) {
      throw ArgumentError(
        'OfflineFileTranscriber requires ${wavSampleRate}Hz mono '
        '$wavBitsPerSample-bit PCM, got ${parsed.sampleRate}Hz '
        '${parsed.channels}-channel ${parsed.bitsPerSample}-bit audio '
        '(${wav.path})',
      );
    }

    final String modelDir;
    final String vadModelPath;
    // ModelNotInstalledException's message already names the screen that
    // fixes it, so it is left to propagate verbatim rather than wrapped.
    final store = _modelStore ?? ModelStore();
    modelDir = _modelDir ?? await store.requireInstalledDir(model);
    vadModelPath = _vadModelPath ??
        '${await store.requireInstalledDir(ModelCatalog.sileroVad)}/'
            '${ModelCatalog.sileroVadFileName}';

    final config = OfflineWorkerConfig(
      model: model,
      modelDir: modelDir,
      // The VAD loads the sherpa-onnx library itself, before the recognizer
      // does, so the desktop test's library directory has to reach it too --
      // otherwise `initBindings` inside the worker falls back to the bare
      // library name and the isolate dies on `dlopen`.
      vad: VadConfig(
        modelPath: vadModelPath,
        nativeLibraryDir: nativeLibraryDir,
      ),
      numThreads: _numThreads,
      nativeLibraryDir: nativeLibraryDir,
      language: ModelCatalog.localSttLanguage(language),
      task: 'transcribe',
    );

    final client = _workerClientFactory();
    final segments = <TranscriptSegment>[];
    final errors = <String>[];

    final subscription = client.events.listen((event) {
      if (event is OfflineSegmentEvent) {
        segments.add(TranscriptSegment(
          text: event.text,
          // The offline recognizers have no diarization, same assumption
          // offline_batch.dart
          // makes for the streaming path.
          speakerId: 0,
          startTime: event.startTime,
          endTime: event.endTime,
          startAt: event.startAt,
          endAt: event.endAt,
        ));
        return;
      }
      if (event is IsolateWorkerError) {
        errors.add(event.message);
      }
    });

    var stopped = false;
    try {
      await client.start(config);

      final pcm = parsed.pcm;
      var offset = 0;
      var at = recordingStartedAt ?? DateTime.now();
      while (offset < pcm.length) {
        final end = (offset + chunkBytes).clamp(0, pcm.length);
        // One copy, not two: `feed` takes ownership of what it is handed,
        // so a copy is required -- but `sublist` would already have made one.
        final chunk =
            Uint8List.fromList(Uint8List.sublistView(pcm, offset, end));
        client.feed(chunk, at);
        // Advance the synthetic clock by exactly the audio duration this
        // chunk represents, so the worker's timeline stays in lockstep with
        // sample position rather than with wall-clock time this loop
        // actually took.
        final sampleCount = chunk.length ~/ 2;
        at = at.add(Duration(
          microseconds:
              sampleCount * Duration.microsecondsPerSecond ~/ wavSampleRate,
        ));
        offset = end;
      }

      // Flushed explicitly, ahead of stop, so the trailing utterance is
      // deterministically emitted before shutdown tears down the recognizer
      // (stop() flushes too, but relying on that would leave the tail's
      // timing coupled to shutdown rather than to the feed loop finishing).
      await client.flush();
      await client.stop();
      stopped = true;
    } finally {
      // A throw anywhere above skips the `stop()` in the try, and a started
      // worker holds an isolate and a loaded model until something shuts it
      // down. `stop()` on an already-stopped client is a no-op, so the only
      // case this covers is the failure one.
      if (!stopped) {
        try {
          await client.stop();
        } catch (e) {
          debugPrint('Failed to stop the offline worker after an error: $e');
        }
      }
      await subscription.cancel();
    }

    if (errors.isNotEmpty) {
      // Nothing decoded: the errors are the whole story, so they are the
      // failure.
      if (segments.isEmpty) throw Exception(errors.first);
      // Something decoded *and* the worker complained, which means the
      // transcript is silently short. It is still worth returning -- a
      // partial import beats none -- but it must not pass unremarked, or a
      // truncated recording gets finalized as a complete conversation.
      debugPrint(
        'Offline worker reported ${errors.length} error(s) while transcribing '
        '${wav.path}; the transcript may be incomplete: ${errors.join('; ')}',
      );
    }
    return segments;
  }
}
