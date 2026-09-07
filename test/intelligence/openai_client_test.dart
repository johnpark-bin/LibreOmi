import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:libreomi/intelligence/llm_client.dart';
import 'package:libreomi/intelligence/openai_client.dart';
import 'package:libreomi/services/openai_service.dart';
import 'package:libreomi/services/secret_store.dart';
import 'package:libreomi/services/settings_service.dart';

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

  group('base URL routing', () {
    test('chat hits <configured base>/chat/completions', () async {
      final requests = <http.Request>[];
      final mock = MockClient((request) async {
        requests.add(request);
        return http.Response(_chatBody('hi there'), 200);
      });
      final service = OpenAIService(
        apiKey: 'test-key',
        model: 'gpt-4.1-mini',
        baseUrl: 'http://localhost:11434/v1',
        client: mock,
      );
      final client = OpenAiClient(service: service);

      await client.chat('hi');

      expect(requests, hasLength(1));
      expect(requests.single.url.toString(), 'http://localhost:11434/v1/chat/completions');
    });

    test('summarizeConversation hits <configured base>/chat/completions', () async {
      final requests = <http.Request>[];
      final content = jsonEncode({'title': 't', 'summary': 's', 'memories': [], 'tasks': []});
      final mock = MockClient((request) async {
        requests.add(request);
        return http.Response(_chatBody(content), 200);
      });
      final service = OpenAIService(
        apiKey: 'test-key',
        model: 'gpt-4.1-mini',
        baseUrl: 'http://localhost:11434/v1',
        client: mock,
      );
      final client = OpenAiClient(service: service);

      await client.summarize('t');

      expect(requests, hasLength(1));
      expect(requests.single.url.toString(), 'http://localhost:11434/v1/chat/completions');
    });

    test('a base URL with a trailing slash normalizes correctly', () async {
      final requests = <http.Request>[];
      final mock = MockClient((request) async {
        requests.add(request);
        return http.Response(_chatBody('hi there'), 200);
      });
      final service = OpenAIService(
        apiKey: 'test-key',
        model: 'gpt-4.1-mini',
        baseUrl: 'http://localhost:11434/v1/',
        client: mock,
      );
      final client = OpenAiClient(service: service);

      await client.chat('hi');

      expect(requests.single.url.toString(), 'http://localhost:11434/v1/chat/completions');
    });
  });

  group('summarizeConversation JSON-mode fallback', () {
    test('falls back to non-JSON mode once when the first request is rejected (400) and returns insights', () async {
      final requests = <http.Request>[];
      final content = jsonEncode({
        'title': 'Fallback title',
        'summary': 'Fallback summary',
        'memories': [],
        'tasks': [],
      });
      var callCount = 0;
      final mock = MockClient((request) async {
        callCount++;
        requests.add(request);
        if (callCount == 1) {
          return http.Response('bad request', 400);
        }
        return http.Response(_chatBody(content), 200);
      });
      final service = OpenAIService(apiKey: 'test-key', model: 'gpt-4.1-mini', client: mock);
      final client = OpenAiClient(service: service);

      final insights = await client.summarize('t');

      expect(insights.title, 'Fallback title');
      expect(requests, hasLength(2));
      expect(requests[0].body, contains('response_format'));
      expect(requests[1].body, isNot(contains('response_format')));
    });

    test('does not fall back / retry on 401 (permanent, single request)', () async {
      final requests = <http.Request>[];
      final mock = MockClient((request) async {
        requests.add(request);
        return http.Response('unauthorized', 401);
      });
      final service = OpenAIService(apiKey: 'test-key', model: 'gpt-4.1-mini', client: mock);
      final client = OpenAiClient(service: service);

      await expectLater(
        client.summarize('t'),
        throwsA(isA<LlmPermanentException>()),
      );
      expect(requests, hasLength(1));
    });

    test('does not fall back / retry on 500 (retryable, single request)', () async {
      final requests = <http.Request>[];
      final mock = MockClient((request) async {
        requests.add(request);
        return http.Response('server error', 500);
      });
      final service = OpenAIService(apiKey: 'test-key', model: 'gpt-4.1-mini', client: mock);
      final client = OpenAiClient(service: service);

      await expectLater(
        client.summarize('t'),
        throwsA(isA<LlmRetryableException>()),
      );
      expect(requests, hasLength(1));
    });
  });

  group('summarizeConversation content parsing', () {
    test('parses content wrapped in a ```json code fence', () async {
      final content = '```json\n${jsonEncode({
        'title': 'Fenced title',
        'summary': 'Fenced summary',
        'memories': [],
        'tasks': [],
      })}\n```';
      final client = _clientReturning(http.Response(_chatBody(content), 200));

      final insights = await client.summarize('t');

      expect(insights.title, 'Fenced title');
      expect(insights.summary, 'Fenced summary');
    });

    test('parses content with leading prose before the JSON object', () async {
      final content = 'Sure, here is the analysis:\n${jsonEncode({
        'title': 'Prose title',
        'summary': 'Prose summary',
        'memories': [],
        'tasks': [],
      })}';
      final client = _clientReturning(http.Response(_chatBody(content), 200));

      final insights = await client.summarize('t');

      expect(insights.title, 'Prose title');
      expect(insights.summary, 'Prose summary');
    });

    test('throws LlmPermanentException when content is not JSON at all', () async {
      final client = _clientReturning(http.Response(_chatBody('this is not json at all'), 200));

      await expectLater(
        client.summarize('t'),
        throwsA(isA<LlmPermanentException>()),
      );
    });
  });

  group('summarizeConversation usage tracking', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());
    });

    test('a 200 whose usage is present but empty ({}) does not throw and leaves counters unchanged', () async {
      final content = jsonEncode({'title': 't', 'summary': 's', 'memories': [], 'tasks': []});
      final body = jsonEncode({
        'choices': [
          {
            'message': {'content': content},
          },
        ],
        'usage': <String, dynamic>{},
      });
      final client = _clientReturning(http.Response(body, 200));

      final before = (SettingsService.openaiInputTokens, SettingsService.openaiOutputTokens);
      await client.summarize('t');

      expect(SettingsService.openaiInputTokens, before.$1);
      expect(SettingsService.openaiOutputTokens, before.$2);
    });

    test('a 200 whose usage is not an object at all does not throw', () async {
      final content = jsonEncode({'title': 't', 'summary': 's', 'memories': [], 'tasks': []});
      final body = jsonEncode({
        'choices': [
          {
            'message': {'content': content},
          },
        ],
        'usage': <dynamic>[],
      });
      final client = _clientReturning(http.Response(body, 200));

      final before = (SettingsService.openaiInputTokens, SettingsService.openaiOutputTokens);
      final insights = await client.summarize('t');

      expect(insights.title, 't');
      expect(SettingsService.openaiInputTokens, before.$1);
      expect(SettingsService.openaiOutputTokens, before.$2);
    });
  });

  group('OpenAIService.testConnection', () {
    test('200 with a data list returns ok:true and parsed model ids', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'gpt-4.1-mini'},
              {'id': 'gpt-4.1-nano'},
            ],
          }),
          200,
        );
      });
      final service = OpenAIService(apiKey: 'test-key', model: 'gpt-4.1-mini', client: mock);

      final result = await service.testConnection();

      expect(result.ok, isTrue);
      expect(result.models, ['gpt-4.1-mini', 'gpt-4.1-nano']);
    });

    test('401 returns ok:false with the status code in the message', () async {
      final mock = MockClient((request) async => http.Response('unauthorized', 401));
      final service = OpenAIService(apiKey: 'test-key', model: 'gpt-4.1-mini', client: mock);

      final result = await service.testConnection();

      expect(result.ok, isFalse);
      expect(result.message, contains('401'));
    });

    test('a thrown ClientException returns ok:false without rethrowing', () async {
      final mock = MockClient((request) async => throw http.ClientException('connection reset'));
      final service = OpenAIService(apiKey: 'test-key', model: 'gpt-4.1-mini', client: mock);

      final result = await service.testConnection();

      expect(result.ok, isFalse);
    });
  });
}
