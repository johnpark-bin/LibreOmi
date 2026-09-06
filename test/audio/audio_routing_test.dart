import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/audio/audio_routing.dart';
import 'package:libreomi/audio/audio_source.dart';

void main() {
  group('routeAudioChunk', () {
    test('opus chunk to opus-accepting backend passes through', () {
      expect(
        routeAudioChunk(
          chunk: AudioEncoding.opus,
          accepted: AudioEncoding.opus,
        ),
        AudioRouting.passThrough,
      );
    });

    test('pcm16 chunk to pcm16-accepting backend passes through', () {
      expect(
        routeAudioChunk(
          chunk: AudioEncoding.pcm16,
          accepted: AudioEncoding.pcm16,
        ),
        AudioRouting.passThrough,
      );
    });

    test('opus chunk to pcm16-accepting backend is decoded', () {
      expect(
        routeAudioChunk(
          chunk: AudioEncoding.opus,
          accepted: AudioEncoding.pcm16,
        ),
        AudioRouting.decodeOpus,
      );
    });

    test('pcm16 chunk to opus-accepting backend is dropped', () {
      expect(
        routeAudioChunk(
          chunk: AudioEncoding.pcm16,
          accepted: AudioEncoding.opus,
        ),
        AudioRouting.drop,
      );
    });
  });
}
