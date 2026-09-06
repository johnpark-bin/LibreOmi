// The common interface every audio producer (Omi BLE device, phone
// microphone, ...) implements, so the rest of the app can consume audio
// without knowing where it came from.
import 'dart:async';
import 'dart:typed_data';

/// How the bytes in an [AudioChunk] are encoded.
enum AudioEncoding {
  /// Opus-compressed audio, as produced by the Omi device.
  opus,

  /// Raw signed 16-bit little-endian PCM samples.
  pcm16,
}

/// One buffer of audio pulled off an [AudioSource], tagged with its
/// encoding and the time it was captured.
class AudioChunk {
  const AudioChunk({
    required this.bytes,
    required this.encoding,
    required this.at,
  });

  final Uint8List bytes;
  final AudioEncoding encoding;
  final DateTime at;
}

/// A source of audio the app can start and stop, independent of the
/// underlying transport (BLE notifications, a microphone recorder, ...).
abstract class AudioSource {
  /// Begins producing [AudioChunk]s. Safe to call again after [stop].
  Stream<AudioChunk> start();

  /// Stops production and releases any resources held by [start].
  Future<void> stop();
}
