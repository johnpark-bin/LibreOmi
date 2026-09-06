/// Canonical WAV (RIFF) header building and parsing for the 16 kHz mono
/// PCM16 audio this app records and transcribes.
///
/// Before LO-51 the header was built inline in `SessionController`
/// (`_buildWavHeader` plus two little-endian helpers) and every other place
/// that needed to read one scanned for the `data` chunk by hand. Both live
/// here now so the SD-card import path, the audio self-test playback and the
/// tests agree on one layout. Nothing in this file does I/O: callers hand it
/// bytes and get bytes back.
library;

import 'dart:typed_data';

/// The one audio format this app produces: 16 kHz, mono, signed 16-bit
/// little-endian PCM. Both the Omi device (after Opus decode) and the phone
/// microphone deliver exactly this, so it is a constant rather than a
/// parameter of [buildWavHeader].
const int wavSampleRate = 16000;
const int wavChannels = 1;
const int wavBitsPerSample = 16;

/// Bytes in a canonical 44-byte RIFF/WAVE header with a single `fmt ` chunk
/// followed immediately by `data`.
const int wavHeaderSize = 44;

/// Thrown when bytes handed to [parseWav] are not a WAV file this app can
/// read. The message names what was wrong so an import failure is
/// diagnosable from a log line alone.
class WavFormatException implements Exception {
  const WavFormatException(this.message);
  final String message;

  @override
  String toString() => 'WavFormatException: $message';
}

/// A parsed WAV file: its format fields plus a view of the `data` chunk.
class WavData {
  const WavData({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.pcm,
  });

  final int sampleRate;
  final int channels;
  final int bitsPerSample;

  /// The raw `data` chunk payload, still in the source encoding (PCM16
  /// little-endian for anything this app writes).
  final Uint8List pcm;

  /// Length of the audio in seconds, or 0 when the header's format fields
  /// would make that a division by zero.
  double get durationSeconds {
    final bytesPerFrame = channels * (bitsPerSample ~/ 8);
    if (bytesPerFrame <= 0 || sampleRate <= 0) return 0;
    return pcm.length / (bytesPerFrame * sampleRate);
  }
}

/// Builds the 44-byte canonical header for [dataSize] bytes of PCM payload.
///
/// The defaults are [wavSampleRate] / [wavChannels] / [wavBitsPerSample];
/// they are parameters only so a test can build a header this app would not
/// otherwise produce.
Uint8List buildWavHeader(
  int dataSize, {
  int sampleRate = wavSampleRate,
  int channels = wavChannels,
  int bitsPerSample = wavBitsPerSample,
}) {
  if (dataSize < 0) {
    throw ArgumentError.value(dataSize, 'dataSize', 'must not be negative');
  }
  final blockAlign = channels * bitsPerSample ~/ 8;
  final byteRate = sampleRate * blockAlign;

  final header = Uint8List(wavHeaderSize);
  final view = ByteData.sublistView(header);

  _writeAscii(header, 0, 'RIFF');
  // Everything after this field: the 36 remaining header bytes plus payload.
  view.setUint32(4, dataSize + 36, Endian.little);
  _writeAscii(header, 8, 'WAVE');
  _writeAscii(header, 12, 'fmt ');
  view.setUint32(16, 16, Endian.little); // PCM `fmt ` chunk size
  view.setUint16(20, 1, Endian.little); // format tag: PCM
  view.setUint16(22, channels, Endian.little);
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, byteRate, Endian.little);
  view.setUint16(32, blockAlign, Endian.little);
  view.setUint16(34, bitsPerSample, Endian.little);
  _writeAscii(header, 36, 'data');
  view.setUint32(40, dataSize, Endian.little);
  return header;
}

/// Concatenates [buildWavHeader] and [pcm] into a complete WAV file.
Uint8List buildWav(
  List<int> pcm, {
  int sampleRate = wavSampleRate,
  int channels = wavChannels,
  int bitsPerSample = wavBitsPerSample,
}) {
  final header = buildWavHeader(
    pcm.length,
    sampleRate: sampleRate,
    channels: channels,
    bitsPerSample: bitsPerSample,
  );
  final out = Uint8List(header.length + pcm.length);
  out.setRange(0, header.length, header);
  out.setRange(header.length, out.length, pcm);
  return out;
}

/// Reads [bytes] as a WAV file, walking the chunk list rather than assuming
/// the canonical 44-byte layout: files written by other tools legitimately
/// carry `LIST`/`fact` chunks between `fmt ` and `data`, and the sherpa test
/// WAVs do.
///
/// Throws [WavFormatException] rather than returning null so an import that
/// hands the user a failure can quote a reason.
WavData parseWav(Uint8List bytes) {
  if (bytes.length < 12) {
    throw const WavFormatException('shorter than a RIFF header');
  }
  if (!_matchesAscii(bytes, 0, 'RIFF') || !_matchesAscii(bytes, 8, 'WAVE')) {
    throw const WavFormatException('not a RIFF/WAVE file');
  }

  final view = ByteData.sublistView(bytes);
  int? sampleRate;
  int? channels;
  int? bitsPerSample;

  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final size = view.getUint32(offset + 4, Endian.little);
    final bodyStart = offset + 8;

    if (_matchesAscii(bytes, offset, 'fmt ')) {
      if (size < 16 || bodyStart + 16 > bytes.length) {
        throw const WavFormatException('truncated `fmt ` chunk');
      }
      final formatTag = view.getUint16(bodyStart, Endian.little);
      // 1 is PCM; 0xFFFE is WAVE_FORMAT_EXTENSIBLE, whose sub-format this
      // parser does not read. Nothing in this app writes either variant of
      // float audio, so refusing anything else is the safe default.
      if (formatTag != 1) {
        throw WavFormatException('unsupported WAV format tag $formatTag');
      }
      channels = view.getUint16(bodyStart + 2, Endian.little);
      sampleRate = view.getUint32(bodyStart + 4, Endian.little);
      bitsPerSample = view.getUint16(bodyStart + 14, Endian.little);
    } else if (_matchesAscii(bytes, offset, 'data')) {
      if (sampleRate == null || channels == null || bitsPerSample == null) {
        throw const WavFormatException('`data` chunk before `fmt `');
      }
      // A `data` size that overruns the buffer means a truncated file --
      // common when a recording was interrupted -- so the available bytes
      // are used rather than throwing the recording away.
      final end = bodyStart + size > bytes.length ? bytes.length : bodyStart + size;
      return WavData(
        sampleRate: sampleRate,
        channels: channels,
        bitsPerSample: bitsPerSample,
        pcm: Uint8List.sublistView(bytes, bodyStart, end),
      );
    }

    // Chunks are word-aligned: an odd size is followed by one pad byte.
    offset = bodyStart + size + (size.isOdd ? 1 : 0);
  }

  throw const WavFormatException('no `data` chunk');
}

void _writeAscii(Uint8List target, int offset, String ascii) {
  for (var i = 0; i < ascii.length; i++) {
    target[offset + i] = ascii.codeUnitAt(i);
  }
}

bool _matchesAscii(Uint8List bytes, int offset, String ascii) {
  if (offset + ascii.length > bytes.length) return false;
  for (var i = 0; i < ascii.length; i++) {
    if (bytes[offset + i] != ascii.codeUnitAt(i)) return false;
  }
  return true;
}
