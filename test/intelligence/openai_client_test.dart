import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:libreomi/intelligence/llm_client.dart';
import 'package:libreomi/intelligence/openai_client.dart';
import 'package:libreomi/services/openai_service.dart';

/// Builds a chat-completion-shaped 200 response body. Omitting `usage`
/// (the default here) skips `SettingsService.addOpenAIUsage`, which touches
/// SharedPreferences and would otherwise require host test setup.
String _chatBody(String content, {bool withUsage = false}) {
  return jsonEncode({
    'choices': [
      {
        'message': {'content': content},
      },
    ],
    if (withUsage) 'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
  });
}

OpenAiClient _clientReturning(http.Response response) {
  final mock = MockClient((request) async => response);
  final service = OpenAIService(apiKey: 'test-key', model: 'gpt-4.1-mini', client: mock);
  return OpenAiClient(service: service);
}

void main() {
  group('OpenAiClient.summarize', () {
    test('returns typed insights on a well-formed 200 response', () async {
      final content = jsonEncode({
        'title': 'Weekend plans',
        'summary': 'Discussed hiking this weekend.',
        'memories': ['User enjoys hiking'],
        'tasks': [
          {'title': 'Pack backpack', 'due_date': '2026-09-12T09:00:00'},
        ],
      });
      final client = _clientReturning(http.Response(_chatBody(content), 200));

      final insights = await client.summarize('some transcript');

      expect(insights.title, 'Weekend plans');
      expect(insights.summary, 'Discussed hiking this weekend.');
      expect(insights.memories, ['User enjoys hiking']);
      expect(insights.tasks.single.title, 'Pack backpack');
      expect(insights.tasks.single.dueDate, DateTime.parse('2026-09-12T09:00:00'));
    });

    test('throws LlmRetryableException on 500', () async {
      final client = _clientReturning(http.Response('server error', 500));
      await expectLater(
        client.summarize('t'),
        throwsA(isA<LlmRetryableException>()),
      );
    });

    test('throws LlmRetryableException on 429', () async {
      final client = _clientReturning(http.Response('rate limited', 429));
      await expectLater(
        client.summarize('t'),
        throwsA(isA<LlmRetryableException>()),
      );
    });

    test('throws LlmPermanentException on 401', () async {
      final client = _clientReturning(http.Response('unauthorized', 401));
      await expectLater(
        client.summarize('t'),
        throwsA(isA<LlmPermanentException>()),
      );
    });

    test('throws LlmPermanentException on a 200 with no content', () async {
      final body = jsonEncode({
        'choices': [
          {
            'message': {'content': null},
          },
        ],
      });
      final client = _clientReturning(http.Response(body, 200));

      await expectLater(
        client.summarize('t'),
        throwsA(isA<LlmPermanentException>()),
      );
    });

    test('throws LlmRetryableException when the client throws a ClientException', () async {
      final mock = MockClient((request) async => throw http.ClientException('connection reset'));
      final service = OpenAIService(apiKey: 'test-key', model: 'gpt-4.1-mini', client: mock);
      final client = OpenAiClient(service: service);

      await expectLater(
        client.summarize('t'),
        throwsA(isA<LlmRetryableException>()),
      );
    });
  });

  group('OpenAiClient.chat', () {
    test('returns the content string on 200', () async {
      final client = _clientReturning(http.Response(_chatBody('Hello there!'), 200));
      final result = await client.chat('hi');
      expect(result, 'Hello there!');
    });

    test('throws LlmRetryableException on 503', () async {
      final client = _clientReturning(http.Response('unavailable', 503));
      await expectLater(
        client.chat('hi'),
        throwsA(isA<LlmRetryableException>()),
      );
    });

    test('throws LlmPermanentException on 400', () async {
      final client = _clientReturning(http.Response('bad request', 400));
      await expectLater(
        client.chat('hi'),
        throwsA(isA<LlmPermanentException>()),
      );
    });
  });
}
