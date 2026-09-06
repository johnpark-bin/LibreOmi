// [AudioSource] adapter over [MicService], the phone-microphone recorder.
import 'dart:async';
import 'dart:typed_data';

import 'audio_source.dart';
import 'mic_recorder.dart';

/// Wraps the phone microphone as an [AudioSource], emitting
/// [AudioEncoding.pcm16] chunks. Defaults to the real recorder; a test passes
/// its own [MicRecorder].
class PhoneMicSource implements AudioSource {
  PhoneMicSource({MicRecorder? mic, DateTime Function()? now})
      : _mic = mic ?? MicServiceRecorder(),
        _now = now ?? DateTime.now;

  final MicRecorder _mic;
  final DateTime Function() _now;

  StreamSubscription<Uint8List>? _subscription;
  StreamController<AudioChunk>? _controller;

  /// Starts the underlying recorder and lets any failure (permission
  /// denied, mic busy, ...) propagate as an exception.
  ///
  /// This exists because [start] is synchronous and cannot itself surface a
  /// recorder failure to the caller as a thrown exception; the app needs
  /// that failure to roll back the session it just opened. Call this before
  /// [start] to catch the error at the call site, or rely on [start] to call
  /// it for you and forward the error onto the returned stream.
  Future<void> prepare() => _mic.startRecording();

  @override
  Stream<AudioChunk> start() {
    // Same reasoning as OmiAudioSource: emission must be synchronous so it
    // doesn't reorder against button-event handling.
    final controller = StreamController<AudioChunk>.broadcast(sync: true);
    _controller = controller;

    _subscription = _mic.audioStream.listen(
      (data) {
        // Create a properly aligned copy of the audio data. This is needed
        // because Int16List.view requires a properly aligned buffer, and
        // the buffer handed to us by the recorder is not guaranteed to be.
        final alignedData = Uint8List.fromList(data);
        controller.add(
          AudioChunk(
            bytes: alignedData,
            encoding: AudioEncoding.pcm16,
            at: _now(),
          ),
        );
      },
      onError: controller.addError,
      onDone: controller.close,
    );

    // Fire-and-forget so a caller holding only the AudioSource interface
    // still gets the recorder started; MicService.startRecording() is
    // idempotent, so calling it again from an explicit prepare() call is
    // harmless. Any failure is forwarded onto the stream rather than
    // thrown here, since start() is not async.
    unawaited(prepare().catchError((Object e) => controller.addError(e)));

    return controller.stream;
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _controller?.close();
    _controller = null;
    await _mic.stopRecording();
  }
}
