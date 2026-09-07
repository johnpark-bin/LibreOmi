import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:libreomi/transcription/deepgram_prerecorded.dart';

void main() {
  group('DeepgramPreRecordedTranscriber', () {
    late File wavFile;
    final wavBytes = Uint8List.fromList(
      List<int>.generate(16, (i) => i),
    );

    setUp(() {
      wavFile = File(
        '${Directory.systemTemp.createTempSync('deepgram_test').path}/sample.wav',
      );
      wavFile.writeAsBytesSync(wavBytes);
    });

    tearDown(() {
      if (wavFile.existsSync()) wavFile.deleteSync();
      final parent = wavFile.parent;
      if (parent.existsSync()) parent.deleteSync(recursive: true);
    });

    String multiSpeakerBody({num? duration}) {
      return jsonEncode({
        if (duration != null) 'metadata': {'duration': duration},
        'results': {
          'channels': [
            {
              'alternatives': [
                {
                  'transcript': 'hello there general kenobi',
                  'words': [
                    {'word': 'hello', 'start': 0.0, 'end': 0.5, 'speaker': 0},
                    {'word': 'there', 'start': 0.5, 'end': 1.0, 'speaker': 0},
                    {
                      'word': 'general',
                      'start': 1.2,
                      'end': 1.6,
                      'speaker': 1
                    },
                    {'word': 'kenobi', 'start': 1.6, 'end': 2.0, 'speaker': 1},
                  ],
                },
              ],
            },
          ],
        },
      });
    }

    test('sends a POST with the correct URL, headers, and raw body bytes',
        () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(multiSpeakerBody(), 200);
      });

      final transcriber = DeepgramPreRecordedTranscriber(
        apiKey: 'secret-key',
        model: 'nova-2',
        language: 'en',
        client: client,
      );

      await transcriber.transcribe(wavFile);

      expect(captured.method, 'POST');
      expect(captured.url.host, 'api.deepgram.com');
      expect(captured.url.path, '/v1/listen');
      expect(captured.url.queryParameters['model'], 'nova-2');
      expect(captured.url.queryParameters['language'], 'en');
      expect(captured.url.queryParameters['punctuate'], 'true');
      expect(captured.url.queryParameters['diarize'], 'true');
      expect(captured.headers['Authorization'], 'Token secret-key');
      expect(captured.headers['Content-Type'], 'audio/wav');
      expect(captured.bodyBytes, wavBytes);
    });

    test('parses multi-speaker words into segments', () async {
      final client = MockClient((request) async {
        return http.Response(multiSpeakerBody(), 200);
      });

      final transcriber = DeepgramPreRecordedTranscriber(
        apiKey: 'k',
        client: client,
      );

      final segments = await transcriber.transcribe(wavFile);

      expect(segments, hasLength(2));

      expect(segments[0].speakerId, 0);
      expect(segments[0].text, 'hello there');
      expect(segments[0].startTime, 0.0);
      expect(segments[0].endTime, 1.0);

      expect(segments[1].speakerId, 1);
      expect(segments[1].text, 'general kenobi');
      expect(segments[1].startTime, 1.2);
      expect(segments[1].endTime, 2.0);
    });

    test('reports usage in minutes from metadata.duration', () async {
      final client = MockClient((request) async {
        return http.Response(multiSpeakerBody(duration: 120.0), 200);
      });

      double? reportedMinutes;
      final transcriber = DeepgramPreRecordedTranscriber(
        apiKey: 'k',
        client: client,
        onUsage: (minutes) => reportedMinutes = minutes,
      );

      await transcriber.transcribe(wavFile);

      expect(reportedMinutes, 2.0);
    });

    test('does not report usage when duration is missing or zero', () async {
      final client = MockClient((request) async {
        return http.Response(multiSpeakerBody(duration: 0.0), 200);
      });

      var usageCalled = false;
      final transcriber = DeepgramPreRecordedTranscriber(
        apiKey: 'k',
        client: client,
        onUsage: (_) => usageCalled = true,
      );

      await transcriber.transcribe(wavFile);

      expect(usageCalled, isFalse);
    });

    test('throws on a non-2xx response without leaking the API key',
        () async {
      final client = MockClient((request) async {
        return http.Response('{"err": "Unauthorized"}', 401);
      });

      final transcriber = DeepgramPreRecordedTranscriber(
        apiKey: 'super-secret-key',
        client: client,
      );

      await expectLater(
        () => transcriber.transcribe(wavFile),
        throwsA(
          predicate((e) {
            final message = e.toString();
            return e is Exception &&
                message.contains('401') &&
                !message.contains('super-secret-key');
          }),
        ),
      );
    });

    test('returns an empty list when the response has no results', () async {
      final client = MockClient((request) async {
        return http.Response(jsonEncode({'metadata': {}}), 200);
      });

      final transcriber = DeepgramPreRecordedTranscriber(
        apiKey: 'k',
        client: client,
      );

      final segments = await transcriber.transcribe(wavFile);

      expect(segments, isEmpty);
    });

    test('throws when a 2xx body will not decode as a JSON object', () async {
      // "no speech" and "the answer was garbage" must not look the same to
      // `SdCardImporter`, which deletes the recording once an import returns.
      for (final body in <String>['not json at all', '[1, 2, 3]']) {
        final transcriber = DeepgramPreRecordedTranscriber(
          apiKey: 'secret-key',
          client: MockClient((_) async => http.Response(body, 200)),
        );

        await expectLater(
          transcriber.transcribe(wavFile),
          throwsA(isA<Exception>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('Deepgram'), isNot(contains('secret-key'))),
          )),
        );
      }
    });

    test('closes the client it created itself', () async {
      // The class builds one per import when none is injected, so it has to
      // close it -- there is no dispose on `FileTranscriber` to do it later.
      // Observed through the client's own behaviour: a closed `http.Client`
      // throws on the next request.
      final transcriber = DeepgramPreRecordedTranscriber(apiKey: 'k');
      // The first request fails on its own (nothing answers in a unit test)
      // and that is fine. The second one is the assertion: `http.Client`
      // reports "Client is already closed" once it has been closed, which is
      // the only observable this class exposes.
      await expectLater(transcriber.transcribe(wavFile), throwsA(anything));
      await expectLater(
        transcriber.transcribe(wavFile),
        throwsA(isA<http.ClientException>().having(
          (e) => e.message,
          'message',
          contains('closed'),
        )),
      );
    });

    test('leaves a client it was given alone', () async {
      // A transcriber is built per import, so a client this class created has
      // to be closed with it; an injected one belongs to the caller and must
      // survive the call.
      final client = _ClosingMockClient(
        (_) async => http.Response(jsonEncode({'metadata': {}}), 200),
      );

      await DeepgramPreRecordedTranscriber(apiKey: 'k', client: client)
          .transcribe(wavFile);

      expect(client.closed, isFalse);
    });
  });
}

/// A [MockClient] that records whether anyone closed it.
class _ClosingMockClient extends MockClient {
  _ClosingMockClient(super.fn);

  bool closed = false;

  @override
  void close() {
    closed = true;
    super.close();
  }
}
