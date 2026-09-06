/// Adapts [SherpaService] to the [StreamingTranscriber] interface.
library;

import 'dart:async';

import '../audio/audio_source.dart';
import '../models/conversation.dart';
import '../services/sherpa_service.dart';
import 'transcriber.dart';

/// Builds a [SherpaService], taking the callbacks the real service wants at
/// construction time. Overridable in tests to inject a fake.
typedef SherpaServiceFactory = SherpaService Function({
  required void Function(List<TranscriptSegment>) onTranscript,
  required void Function(String) onError,
});

/// Wraps [SherpaService] for the on-device streaming ASR path. Always
/// consumes raw PCM16, since Sherpa never sees Opus (the Omi path decodes
/// Opus to PCM before handing audio to it).
class SherpaStreamingTranscriber implements StreamingTranscriber {
  SherpaStreamingTranscriber({SherpaServiceFactory? serviceFactory})
      : _serviceFactory = serviceFactory ?? _defaultFactory;

  final SherpaServiceFactory _serviceFactory;

  SherpaService? _service;

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

  static SherpaService _defaultFactory({
    required void Function(List<TranscriptSegment>) onTranscript,
    required void Function(String) onError,
  }) {
    return SherpaService(onTranscript: onTranscript, onError: onError);
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
