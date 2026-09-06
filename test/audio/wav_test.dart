import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/audio/wav.dart';

/// Reads the four ASCII bytes at [offset] -- the chunk tags a WAV reader
/// dispatches on -- so a failure names the tag that was wrong rather than a
/// byte value.
String _tag(Uint8List bytes, int offset) =>
    String.fromCharCodes(bytes.sublist(offset, offset + 4));

void main() {
  group('buildWavHeader', () {
    test('lays out a canonical 44-byte 16 kHz mono PCM16 header', () {
      final header = buildWavHeader(1000);
      final view = ByteData.sublistView(header);

      expect(header.length, wavHeaderSize);
      expect(_tag(header, 0), 'RIFF');
      // Everything after the size field: 36 header bytes plus the payload.
      expect(view.getUint32(4, Endian.little), 1036);
      expect(_tag(header, 8), 'WAVE');
      expect(_tag(header, 12), 'fmt ');
      expect(view.getUint32(16, Endian.little), 16);
      expect(view.getUint16(20, Endian.little), 1, reason: 'PCM format tag');
      expect(view.getUint16(22, Endian.little), 1, reason: 'mono');
      expect(view.getUint32(24, Endian.little), 16000);
      expect(view.getUint32(28, Endian.little), 32000, reason: 'byte rate');
      expect(view.getUint16(32, Endian.little), 2, reason: 'block align');
      expect(view.getUint16(34, Endian.little), 16);
      expect(_tag(header, 36), 'data');
      expect(view.getUint32(40, Endian.little), 1000);
    });

    test('rejects a negative payload size', () {
      expect(() => buildWavHeader(-1), throwsArgumentError);
    });
  });

  group('parseWav', () {
    test('round-trips what buildWav produced', () {
      final pcm = Uint8List.fromList(List<int>.generate(320, (i) => i % 256));
      final parsed = parseWav(buildWav(pcm));

      expect(parsed.sampleRate, 16000);
      expect(parsed.channels, 1);
      expect(parsed.bitsPerSample, 16);
      expect(parsed.pcm, pcm);
      // 320 bytes = 160 frames at 16 kHz.
      expect(parsed.durationSeconds, closeTo(0.01, 1e-9));
    });

    test('skips chunks between `fmt ` and `data`', () {
      // A `LIST` chunk with an odd body, so the word-alignment pad byte is
      // exercised too: a parser that forgets it lands one byte short of the
      // next tag and never finds `data`.
      final pcm = Uint8List.fromList([1, 2, 3, 4]);
      final canonical = buildWav(pcm);
      final list = <int>[
        ...'LIST'.codeUnits,
        3, 0, 0, 0, // chunk size 3 (odd)
        0x49, 0x4e, 0x46, // body
        0, // pad
      ];
      final withList = Uint8List.fromList([
        ...canonical.sublist(0, 36), // through the `fmt ` chunk
        ...list,
        ...canonical.sublist(36), // `data` chunk
      ]);
      // The RIFF size field is now stale, which a reader must not care about.
      final parsed = parseWav(withList);
      expect(parsed.pcm, pcm);
    });

    test('uses the bytes actually present when `data` overruns the file', () {
      // What an interrupted recording looks like: the header claims more
      // payload than was ever written. Truncating beats discarding it.
      final full = buildWav(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]));
      final truncated = Uint8List.sublistView(full, 0, full.length - 4);
      expect(parseWav(truncated).pcm, Uint8List.fromList([1, 2, 3, 4]));
    });

    test('reports non-PCM, headerless and data-less inputs', () {
      expect(() => parseWav(Uint8List(4)), throwsA(isA<WavFormatException>()));
      expect(
        () => parseWav(Uint8List.fromList('NOPE'.codeUnits + List.filled(40, 0))),
        throwsA(isA<WavFormatException>()),
      );

      // Header only: `fmt ` present, `data` absent.
      final headerOnly = buildWavHeader(0).sublist(0, 36);
      expect(() => parseWav(headerOnly), throwsA(isA<WavFormatException>()));

      // IEEE float (format tag 3) is a WAV this app never writes and the
      // worker's PCM16 conversion would silently misread.
      final float = buildWav(Uint8List(4));
      ByteData.sublistView(float).setUint16(20, 3, Endian.little);
      expect(() => parseWav(float), throwsA(isA<WavFormatException>()));
    });
  });
}
