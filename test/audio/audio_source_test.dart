import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/audio/audio_source.dart';

void main() {
  test('AudioChunk stores the bytes, encoding and timestamp given to it', () {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final at = DateTime(2026, 1, 1);

    final chunk = AudioChunk(bytes: bytes, encoding: AudioEncoding.pcm16, at: at);

    expect(chunk.bytes, bytes);
    expect(chunk.encoding, AudioEncoding.pcm16);
    expect(chunk.at, at);
  });
}
