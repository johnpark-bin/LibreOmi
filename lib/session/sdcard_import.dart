/// Turns one synced SD-card recording into a finalized conversation
/// (LO-51, `docs/06-roadmap.md` M5).
///
/// This is the post-processing half of the SD-card path that
/// `docs/03-architecture.md` §6 lists as still owed by
/// `services/sdcard_sync_service.dart`: that service's job ends when the
/// `.bin` is on disk, and this class takes it from there — decode, WAV,
/// [FileTranscriber], [ConversationFinalizer]. It deliberately knows nothing
/// about BLE, and the transcriber is injected so neither Deepgram nor the
/// Whisper worker is reachable from a unit test.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../audio/opus_decoder.dart';
import '../audio/wav.dart';
import '../core/clock.dart';
import '../core/ids.dart';
import '../models/conversation.dart';
import '../transcription/transcriber.dart';
import 'conversation_finalizer.dart';

/// The title every SD-card import carries. [ConversationFinalizer.finalize]
/// only fills in a placeholder title when there is none, so this survives
/// until summarisation replaces it.
const String sdCardConversationTitle = 'SD Card Recording';

/// Builds the transcriber for one import. A factory rather than an instance
/// because the concrete transcriber depends on the *current* settings (cloud
/// vs. on-device) and because both implementations hold resources — an HTTP
/// client, a worker isolate — that should not outlive a single import.
typedef FileTranscriberFactory = FileTranscriber Function();

/// Decodes the codec frames read out of a `.bin` into 16 kHz mono PCM16.
/// Injected so a test never loads `opus_flutter`'s native library.
typedef FrameDecoder = Future<Uint8List> Function(List<Uint8List> frames);

/// Thrown when an import cannot proceed. Carries a message meant to be shown
/// to the user, so it names the file's problem rather than an internal one.
class SdCardImportException implements Exception {
  const SdCardImportException(this.message);
  final String message;

  @override
  String toString() => 'SdCardImportException: $message';
}

/// Splits a synced `.bin` into the codec frames it was written from.
///
/// `SdCardSyncService._saveFramesToFile` writes `[len int32 LE][frame]`
/// repeatedly (`docs/05-omi-ble-protocol.md` "SD card"), and the frame
/// boundaries are not optional: an Opus decoder needs whole packets, so
/// concatenating the payloads and re-splitting them later is impossible.
/// That is why this reads the file itself instead of calling
/// `SdCardSyncService.readAudioFile`, which returns the payloads already
/// concatenated and therefore un-decodable.
///
/// A trailing partial record — a sync interrupted mid-frame — ends the scan
/// instead of failing it, so an interrupted recording still transcribes up
/// to the cut.
List<Uint8List> readFramedPackets(Uint8List bytes) {
  final frames = <Uint8List>[];
  var offset = 0;
  while (offset + 4 <= bytes.length) {
    final length = bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
    offset += 4;
    // A zero or negative length would spin this loop forever on a corrupt
    // file; a length past the end is the interrupted-sync case.
    if (length <= 0 || offset + length > bytes.length) break;
    frames.add(Uint8List.sublistView(bytes, offset, offset + length));
    offset += length;
  }
  return frames;
}

/// Recovers when the recording started from the name
/// `sdcard_audio_{codec}_16000_1_{unixStart}.bin`, which
/// `SdCardSyncService` writes with `unixStart` in whole seconds
/// (`docs/05-omi-ble-protocol.md` "SD card").
///
/// Returns null for a name that does not match, leaving the caller to fall
/// back to the file's modification time.
DateTime? recordingStartFromFileName(String path) {
  final name = path.split(Platform.pathSeparator).last;
  final match =
      RegExp(r'^sdcard_audio_.*_(\d{9,11})\.bin$').firstMatch(name);
  if (match == null) return null;
  final seconds = int.tryParse(match.group(1)!);
  if (seconds == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
}

/// Decodes Opus frames to PCM16 with the real `opus_flutter` decoder. The
/// default [FrameDecoder]; replaced in tests.
Future<Uint8List> decodeOpusFrames(List<Uint8List> frames) async {
  final decoder = OpusDecoder();
  await decoder.initialize();
  try {
    final pcm = BytesBuilder(copy: false);
    for (final frame in frames) {
      // A single bad frame is dropped rather than failing the import: the
      // rest of the recording is still worth transcribing.
      final decoded = decoder.decode(Uint8List.fromList(frame));
      if (decoded != null) pcm.add(decoded);
    }
    return pcm.toBytes();
  } finally {
    decoder.dispose();
  }
}

/// Imports synced SD-card recordings.
class SdCardImporter {
  SdCardImporter({
    required ConversationFinalizer finalizer,
    required FileTranscriberFactory transcriberFactory,
    required Future<Directory> Function() temporaryDirectory,
    FrameDecoder opusDecoder = decodeOpusFrames,
    IdGenerator? ids,
    Clock clock = const SystemClock(),
  })  : _finalizer = finalizer,
        _transcriberFactory = transcriberFactory,
        _temporaryDirectory = temporaryDirectory,
        _opusDecoder = opusDecoder,
        _ids = ids ?? UuidIdGenerator(),
        _clock = clock;

  final ConversationFinalizer _finalizer;
  final FileTranscriberFactory _transcriberFactory;
  final Future<Directory> Function() _temporaryDirectory;
  final FrameDecoder _opusDecoder;
  final IdGenerator _ids;
  final Clock _clock;

  /// Decodes, transcribes and finalizes the recording at [filePath], and
  /// returns its transcript.
  ///
  /// A recording that produced no text is *not* saved — an empty
  /// conversation gives the summarizer nothing to work with and would only
  /// clutter History — and it throws rather than returning an empty string.
  /// That is not pedantry: `pages/sdcard_sync_page.dart` treats any
  /// non-throwing return as success and deletes the `.bin` afterwards, so a
  /// quiet empty result would destroy the recording while saving nothing.
  Future<String> import(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw SdCardImportException('Audio file not found: $filePath');
    }

    final frames = readFramedPackets(await file.readAsBytes());
    if (frames.isEmpty) {
      throw SdCardImportException('No audio frames in $filePath');
    }

    final pcm = await _toPcm16(filePath, frames);
    if (pcm.isEmpty) {
      throw SdCardImportException('Decoded no audio from $filePath');
    }

    final recordedAt = recordingStartFromFileName(filePath) ??
        (await file.stat()).modified;

    final tempDir = await _temporaryDirectory();
    final wav = File(
      '${tempDir.path}/sdcard_import_${_clock.now().millisecondsSinceEpoch}.wav',
    );
    await wav.writeAsBytes(buildWav(pcm));

    final List<TranscriptSegment> segments;
    try {
      segments = await _transcriberFactory().transcribe(wav);
    } finally {
      // The WAV is a decode artefact, not user data: it is removed whether
      // the transcription succeeded or threw, so a failing import does not
      // leave copies of the recording in the cache directory.
      try {
        if (await wav.exists()) await wav.delete();
      } catch (e) {
        debugPrint('Failed to delete temporary WAV ${wav.path}: $e');
      }
    }

    final stamped = _stampWallClock(segments, recordedAt);
    final transcript =
        stamped.map((s) => s.text.trim()).where((t) => t.isNotEmpty).join(' ');
    if (transcript.isEmpty) {
      throw SdCardImportException('No speech recognized in $filePath');
    }

    final conversation = Conversation(
      id: _ids.newId(),
      createdAt: recordedAt,
      title: sdCardConversationTitle,
      segments: stamped,
    );

    // The same finalizer the live path uses (LO-33): persist first,
    // summarise later, because an SD-card import can run while the phone is
    // offline and the recording must not depend on that call succeeding
    // (LO-23).
    await _finalizer.finalize(conversation);
    return transcript;
  }

  Future<Uint8List> _toPcm16(String filePath, List<Uint8List> frames) async {
    final name = filePath.split(Platform.pathSeparator).last;
    if (name.contains('opus')) return _opusDecoder(frames);

    // `docs/05-omi-ble-protocol.md` records codec id 1 as *8-bit* PCM with a
    // question mark, and nothing in this repo has ever verified it against a
    // device. Guessing the sample width here would produce a confident-looking
    // conversation full of noise, so an unverified codec is refused instead.
    // If a real `pcm8` recording ever turns up, that observation belongs in
    // docs/05 first and the conversion second.
    throw SdCardImportException(
      'Unsupported codec in $name: only Opus recordings can be transcribed',
    );
  }

  /// Rewrites each segment's wall clock as [recordedAt] plus its
  /// transcriber-relative offset.
  ///
  /// Both transcribers time segments from the start of the *file*: Deepgram
  /// supplies only relative seconds, and the offline path's wall clock is
  /// whenever the decode happened to run. Neither is when the audio was
  /// captured, which is what History sorts and displays, so the offsets are
  /// re-anchored here — the one place that knows the recording's start.
  List<TranscriptSegment> _stampWallClock(
    List<TranscriptSegment> segments,
    DateTime recordedAt,
  ) {
    return [
      for (final s in segments)
        TranscriptSegment(
          text: s.text,
          speakerId: s.speakerId,
          startTime: s.startTime,
          endTime: s.endTime,
          isUser: s.isUser,
          startAt: recordedAt.add(_secondsToDuration(s.startTime)),
          endAt: recordedAt.add(_secondsToDuration(s.endTime)),
        ),
    ];
  }

  static Duration _secondsToDuration(double seconds) =>
      Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round());
}
