/// Adapts [DeepgramService] to the [StreamingTranscriber] interface.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio/audio_source.dart';
import '../models/conversation.dart';
import '../services/deepgram_service.dart';
import 'transcriber.dart';

/// Builds a [DeepgramService], taking the callbacks the real service wants
/// at construction time. Overridable in tests to inject a fake.
typedef DeepgramServiceFactory = DeepgramService Function({
  required void Function(List<TranscriptSegment>) onTranscript,
  required void Function(String) onError,
});

/// Wraps [DeepgramService] for either the Omi (opus) or phone-mic (pcm16)
/// audio path, matching what `app_provider._startTranscriptionServices`
/// does today: opus maps to the Deepgram `'opus'` encoding, pcm16 maps to
/// `'linear16'`.
class DeepgramStreamingTranscriber implements StreamingTranscriber {
  DeepgramStreamingTranscriber({
    required AudioEncoding encoding,
    required this.apiKey,
    this.language = 'en',
    this.sampleRate = 16000,
    DeepgramServiceFactory? serviceFactory,
  })  : _encoding = encoding,
        _serviceFactory = serviceFactory ??
            _defaultFactory(encoding, apiKey, language, sampleRate);

  final AudioEncoding _encoding;
  final String apiKey;
  final String language;
  final int sampleRate;
  final DeepgramServiceFactory _serviceFactory;

  DeepgramService? _service;

  final StreamController<TranscriptSegment> _segmentsController =
      StreamController<TranscriptSegment>.broadcast(sync: true);
  final StreamController<String> _errorsController =
      StreamController<String>.broadcast(sync: true);

  @override
  AudioEncoding get acceptedEncoding => _encoding;

  @override
  Stream<TranscriptSegment> get segments => _segmentsController.stream;

  @override
  Stream<String> get errors => _errorsController.stream;

  /// Builds the real [DeepgramService] for [encoding]. Split out of
  /// [_defaultFactory] and exposed because the [AudioEncoding] to Deepgram
  /// `encoding` mapping is the one string in this adapter that silently
  /// breaks live captions on a device if it is wrong, and a test that
  /// injects its own factory never reaches it. Constructing the service
  /// performs no I/O -- only [DeepgramService.connect] opens a socket -- so
  /// a test can call this directly.
  @visibleForTesting
  static DeepgramService buildDeepgramService({
    required AudioEncoding encoding,
    required String apiKey,
    required String language,
    required int sampleRate,
    required void Function(List<TranscriptSegment>) onTranscript,
    required void Function(String) onError,
  }) {
    return DeepgramService(
      apiKey: apiKey,
      language: language,
      encoding: encoding == AudioEncoding.opus ? 'opus' : 'linear16',
      sampleRate: sampleRate,
      onTranscript: onTranscript,
      onError: onError,
    );
  }

  static DeepgramServiceFactory _defaultFactory(
    AudioEncoding encoding,
    String apiKey,
    String language,
    int sampleRate,
  ) {
    return ({required onTranscript, required onError}) => buildDeepgramService(
          encoding: encoding,
          apiKey: apiKey,
          language: language,
          sampleRate: sampleRate,
          onTranscript: onTranscript,
          onError: onError,
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
    await _service!.connect();
  }

  @override
  void feed(AudioChunk chunk) {
    _service?.sendAudio(chunk.bytes);
  }

  @override
  Future<void> stop() async {
    await _service?.disconnect();
    await _segmentsController.close();
    await _errorsController.close();
    _service = null;
  }
}
