import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/services/deepgram/deepgram_parser.dart';
import 'package:libreomi/services/deepgram_service.dart';

String _resultsMessage({
  required bool isFinal,
  double? duration,
  String? transcript,
  List<Map<String, dynamic>>? words,
}) {
  return jsonEncode({
    'type': 'Results',
    'is_final': isFinal,
    if (duration != null) 'duration': duration,
    'channel': {
      'alternatives': [
        {
          'transcript': transcript ?? '',
          'words': words ?? [],
        }
      ],
    },
  });
}


/// Decodes and parses in one step, mirroring what DeepgramService does.
DeepgramResult? _parse(String message) {
  final json = decodeDeepgramMessage(message);
  if (json == null || json['type'] != 'Results') return null;
  return parseDeepgramResults(json);
}

void main() {
  group('parseDeepgramResults', () {
    test('interim result (is_final: false) still parses segments', () {
      final message = _resultsMessage(
        isFinal: false,
        duration: 1.5,
        transcript: 'hello world',
        words: [
          {'word': 'hello', 'start': 0.0, 'end': 0.5, 'speaker': 0},
          {'word': 'world', 'start': 0.5, 'end': 1.0, 'speaker': 0},
        ],
      );

      final result = _parse(message);

      expect(result, isNotNull);
      expect(result!.isFinal, isFalse);
      expect(result.segments, hasLength(1));
      expect(result.segments.first.text, 'hello world');
    });

    test('final result reports isFinal and duration', () {
      final message = _resultsMessage(
        isFinal: true,
        duration: 3.0,
        transcript: 'hello',
        words: [
          {'word': 'hello', 'start': 0.0, 'end': 0.5, 'speaker': 0},
        ],
      );

      final result = _parse(message);

      expect(result, isNotNull);
      expect(result!.isFinal, isTrue);
      expect(result.duration, 3.0);
    });

    test('groups interleaved words by speaker in first-seen order', () {
      final message = _resultsMessage(
        isFinal: true,
        duration: 2.0,
        transcript: 'hi there hey you',
        words: [
          {'word': 'hi', 'start': 0.0, 'end': 0.2, 'speaker': 0},
          {'word': 'hey', 'start': 0.3, 'end': 0.5, 'speaker': 1},
          {'word': 'there', 'start': 0.6, 'end': 0.8, 'speaker': 0},
          {'word': 'you', 'start': 0.9, 'end': 1.1, 'speaker': 1},
        ],
      );

      final result = _parse(message);

      expect(result, isNotNull);
      expect(result!.segments, hasLength(2));

      final speaker0 = result.segments[0];
      expect(speaker0.speakerId, 0);
      expect(speaker0.text, 'hi there');
      expect(speaker0.startTime, 0.0);
      expect(speaker0.endTime, 0.8);

      final speaker1 = result.segments[1];
      expect(speaker1.speakerId, 1);
      expect(speaker1.text, 'hey you');
      expect(speaker1.startTime, 0.3);
      expect(speaker1.endTime, 1.1);
    });

    test('empty transcript yields no segments', () {
      final message = _resultsMessage(
        isFinal: true,
        duration: 1.0,
        transcript: '',
        words: [
          {'word': 'hi', 'start': 0.0, 'end': 0.2, 'speaker': 0},
        ],
      );

      final result = _parse(message);

      expect(result, isNotNull);
      expect(result!.segments, isEmpty);
    });

    test('word missing speaker key defaults to speaker 0', () {
      final message = _resultsMessage(
        isFinal: true,
        duration: 1.0,
        transcript: 'hi',
        words: [
          {'word': 'hi', 'start': 0.0, 'end': 0.2},
        ],
      );

      final result = _parse(message);

      expect(result, isNotNull);
      expect(result!.segments, hasLength(1));
      expect(result.segments.first.speakerId, 0);
    });

    test('a Metadata message is not a Results message', () {
      final message = jsonEncode({'type': 'Metadata', 'duration': 5.0});

      expect(_parse(message), isNull);
      expect(decodeDeepgramMessage(message)!['type'], 'Metadata');
    });

    test('malformed JSON decodes to null without throwing', () {
      expect(() => decodeDeepgramMessage('not json'), returnsNormally);
      expect(decodeDeepgramMessage('not json'), isNull);
      expect(decodeDeepgramMessage('[1, 2, 3]'), isNull);
    });

    test('an unexpected payload shape yields no segments and does not throw', () {
      final message = jsonEncode({
        'type': 'Results',
        'is_final': true,
        'duration': 2.0,
        'channel': {
          'alternatives': [
            {'transcript': 'hi', 'words': 'not-a-list'}
          ],
        },
      });

      final result = _parse(message);

      expect(result, isNotNull);
      expect(result!.segments, isEmpty);
      expect(result.duration, 2.0);
    });

    test('missing duration defaults to 0.0', () {
      final message = _resultsMessage(
        isFinal: true,
        transcript: 'hi',
        words: [
          {'word': 'hi', 'start': 0.0, 'end': 0.2, 'speaker': 0},
        ],
      );

      final result = _parse(message);

      expect(result, isNotNull);
      expect(result!.duration, 0.0);
    });
  });

  group('DeepgramResult.billableMinutes', () {
    test('an interim result is never billed', () {
      final result = _parse(_resultsMessage(
        isFinal: false,
        duration: 3.0,
        transcript: 'hello',
        words: [
          {'word': 'hello', 'start': 0.0, 'end': 0.5, 'speaker': 0},
        ],
      ));

      expect(result, isNotNull);
      expect(result!.billableMinutes, 0.0);
    });

    test('a final result is billed for its duration', () {
      final result = _parse(_resultsMessage(
        isFinal: true,
        duration: 3.0,
        transcript: 'hello',
        words: [
          {'word': 'hello', 'start': 0.0, 'end': 0.5, 'speaker': 0},
        ],
      ));

      expect(result, isNotNull);
      expect(result!.billableMinutes, closeTo(0.05, 1e-9));
    });

    test('a final result with no duration is not billed', () {
      final result = _parse(_resultsMessage(isFinal: true, transcript: 'hi'));

      expect(result, isNotNull);
      expect(result!.billableMinutes, 0.0);
    });

    test('summing only final results does not double count an utterance', () {
      // Deepgram interim results repeat and extend the same audio window.
      final messages = [
        _resultsMessage(isFinal: false, duration: 1.0, transcript: 'he'),
        _resultsMessage(isFinal: false, duration: 2.0, transcript: 'hello'),
        _resultsMessage(isFinal: true, duration: 3.0, transcript: 'hello you'),
      ];

      final total = messages
          .map(_parse)
          .fold<double>(0.0, (sum, r) => sum + r!.billableMinutes);

      // Naively summing every duration would bill 6 s instead of 3 s.
      expect(total, closeTo(3.0 / 60.0, 1e-9));
    });
  });

  group('DeepgramService.buildListenUri', () {
    test('includes model and preserves other query params', () {
      final uri = DeepgramService.buildListenUri(
        model: 'nova-3',
        language: 'en',
        sampleRate: 16000,
        encoding: 'opus',
      );

      expect(uri.queryParameters['model'], 'nova-3');
      expect(uri.queryParameters['language'], 'en');
      expect(uri.queryParameters['sample_rate'], '16000');
      expect(uri.queryParameters['encoding'], 'opus');
      expect(uri.queryParameters['punctuate'], 'true');
      expect(uri.queryParameters['diarize'], 'true');
      expect(uri.queryParameters['channels'], '1');
    });
  });
}
