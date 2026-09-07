/// Transcriber interfaces that decouple `app_provider` from the concrete
/// transcription services (Deepgram, Sherpa, Whisper). See
/// `docs/03-architecture.md` §1 for the module layout these types live in.
library;

import 'dart:io';

import '../audio/audio_source.dart';
import '../core/models.dart';

/// A transcriber that consumes a live stream of [AudioChunk]s and produces
/// [TranscriptSegment]s as they become available.
///
/// Implementations wrap one of the existing `services/*_service.dart`
/// classes, translating their constructor-callback style into streams so
/// callers don't need to know which backend is active.
///
/// **One-shot.** Unlike [AudioSource], an implementation may not be restarted:
/// [stop] closes [segments] and [errors] for good, and a second [start] would
/// silently produce nothing. Build a fresh instance per session. This differs
/// deliberately from `AudioSource.start()`, which is restartable, because the
/// wrapped services are themselves disposed rather than paused.
abstract class StreamingTranscriber {
  /// The [AudioEncoding] this transcriber's [feed] expects. Callers must
  /// route only chunks of this encoding to it.
  AudioEncoding get acceptedEncoding;

  /// Builds and starts the underlying service. Must be called before [feed],
  /// and exactly once for the lifetime of this object (see the class doc).
  Future<void> start();

  /// Pushes one chunk of audio into the underlying service. A no-op before
  /// [start] or after [stop].
  void feed(AudioChunk chunk);

  /// Transcript segments as they are produced, in order.
  Stream<TranscriptSegment> get segments;

  /// Error messages surfaced by the underlying service.
  Stream<String> get errors;

  /// Stops the underlying service and closes [segments] and [errors]. Safe
  /// to call even if [start] was never called.
  Future<void> stop();
}

/// A transcriber that runs over a complete recording rather than a live
/// stream.
///
/// Two implementations, chosen by the transcription-mode setting and built
/// per import by `session/sdcard_import.dart` (LO-51):
/// `transcription/deepgram_prerecorded.dart` uploads the WAV to Deepgram's
/// pre-recorded endpoint, and `transcription/offline_file_transcriber.dart`
/// decodes it on device through the Whisper worker. Both on-device settings
/// modes resolve to the latter: a streaming model fed a whole file is less
/// accurate than one offline decode per VAD-detected utterance.
abstract class FileTranscriber {
  /// Transcribes [wav], which must be 16 kHz mono PCM16 -- what
  /// `audio/wav.dart` writes. The file is the caller's to delete; an
  /// implementation must not outlive the call holding a handle to it.
  Future<List<TranscriptSegment>> transcribe(File wav);
}
