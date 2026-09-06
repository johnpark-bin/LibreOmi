/// Adapts [WhisperService] to the [StreamingTranscriber] interface.
///
/// Named `whisper_batch.dart` per docs/03-architecture.md §1: despite
/// implementing [StreamingTranscriber], [WhisperService] batches audio
/// internally on a 3-second timer rather than transcribing continuously,
/// so segments arrive in bursts rather than as a smooth stream.
library;

import 'dart:async';

import '../audio/audio_source.dart';
import '../models/conversation.dart';
import '../services/whisper_service.dart';
import 'transcriber.dart';

/// Builds a [WhisperService], taking the callbacks the real service wants
/// at construction time. Overridable in tests to inject a fake.
typedef WhisperServiceFactory = WhisperService Function({
  required void Function(List<TranscriptSegment>) onTranscript,
  required void Function(String) onError,
});

/// Wraps [WhisperService] for the on-device batch ASR path. Always consumes
/// raw PCM16, since Whisper never sees Opus (the Omi path decodes Opus to
/// PCM before handing audio to it).
class WhisperBatchTranscriber implements StreamingTranscriber {
  WhisperBatchTranscriber({
    this.modelSize = 'tiny',
    WhisperServiceFactory? serviceFactory,
  }) : _serviceFactory = serviceFactory ?? _defaultFactory(modelSize);

  final String modelSize;
  final WhisperServiceFactory _serviceFactory;

  WhisperService? _service;

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

  static WhisperServiceFactory _defaultFactory(String modelSize) {
    return ({required onTranscript, required onError}) => WhisperService(
          onTranscript: onTranscript,
          onError: onError,
          modelSize: modelSize,
        );
  }

  @override
  Future<void> start() async {
    // Callbacks below run synchronously (sync: true controllers) so they
    // fire inline with the original onTranscript/onError callback timing
    // the audio pipeline in app_provider relies on for ordering.
    _service = _serviceFactory(
      onTranscript: (segs) {
        for (final s in segs) {
          if (!_segmentsController.isClosed) _segmentsController.add(s);
        }
      },
      onError: (e) {
        if (!_errorsController.isClosed) _errorsController.add(e);
      },
    );
    await _service!.initialize();
    _service!.startProcessing();
  }

  @override
  void feed(AudioChunk chunk) {
    _service?.addAudio(chunk.bytes);
  }

  @override
  Future<void> stop() async {
    _service?.stopProcessing();
    _service?.dispose();
    await _segmentsController.close();
    await _errorsController.close();
    _service = null;
  }
}
