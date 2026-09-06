// The slice of [MicService] that [PhoneMicSource] needs, so the source can be
// driven in a test without the `record` plugin.
//
// [MicService] is a singleton whose only generative constructor is private, so
// it cannot be subclassed or faked from outside its own library. Rather than
// widen that class for the sake of a test, `lib/audio/` declares the three
// members it actually uses and adapts the service to them.
import 'dart:async';
import 'dart:typed_data';

import '../services/mic_service.dart';

/// The recorder contract [PhoneMicSource] depends on.
abstract class MicRecorder {
  /// Raw PCM16 buffers as the recorder produces them.
  Stream<Uint8List> get audioStream;

  /// Starts recording. Throws when the microphone is unavailable (permission
  /// denied, device busy). Idempotent: a second call while already recording
  /// is a no-op.
  Future<void> startRecording();

  /// Stops recording. Safe to call when not recording.
  Future<void> stopRecording();
}

/// Adapts the real [MicService] singleton to [MicRecorder].
class MicServiceRecorder implements MicRecorder {
  MicServiceRecorder([MicService? mic]) : _mic = mic ?? MicService();

  final MicService _mic;

  @override
  Stream<Uint8List> get audioStream => _mic.audioStream;

  @override
  Future<void> startRecording() => _mic.startRecording();

  @override
  Future<void> stopRecording() => _mic.stopRecording();
}
