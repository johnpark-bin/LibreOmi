// Pure decision function for what to do with an incoming [AudioChunk]
// given what encoding the active transcription backend accepts.
//
// Kept dependency-free so it can be unit tested without any audio
// plumbing, and reused by every [AudioSource] consumer that needs to
// decide whether to decode before forwarding a chunk.
import 'audio_source.dart';

/// What a chunk should be routed to.
enum AudioRouting {
  /// The chunk's encoding already matches what the backend accepts; forward
  /// the bytes unchanged.
  passThrough,

  /// The chunk is Opus but the backend only accepts PCM16; decode it first.
  decodeOpus,

  /// The chunk cannot be made to match what the backend accepts; discard it.
  drop,
}

/// Decides how a chunk encoded as [chunk] should be routed to a backend
/// that accepts [accepted].
AudioRouting routeAudioChunk({
  required AudioEncoding chunk,
  required AudioEncoding accepted,
}) {
  // Already in the format the backend wants: nothing to do.
  if (chunk == accepted) return AudioRouting.passThrough;

  // The only encoder direction the app supports: Opus source, PCM16 sink.
  if (chunk == AudioEncoding.opus && accepted == AudioEncoding.pcm16) {
    return AudioRouting.decodeOpus;
  }

  // PCM16 source, Opus-only sink: the app has no encoder, so this chunk
  // cannot be delivered. Today this combination cannot occur in practice —
  // the phone-mic path always configures the cloud backend for
  // linear16 — but the function still reports it explicitly rather than
  // pass through the wrong encoding.
  return AudioRouting.drop;
}
