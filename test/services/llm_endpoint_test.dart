import 'package:flutter_test/flutter_test.dart';

import 'package:libreomi/services/llm_endpoint.dart';

void main() {
  group('normalizeLlmBaseUrl', () {
    test('strips a single trailing slash', () {
      expect(normalizeLlmBaseUrl('https://api.openai.com/v1/'),
          'https://api.openai.com/v1');
    });

    test('strips multiple trailing slashes', () {
      expect(normalizeLlmBaseUrl('https://api.openai.com/v1///'),
          'https://api.openai.com/v1');
    });

    test('trims surrounding whitespace', () {
      expect(normalizeLlmBaseUrl('  https://api.openai.com/v1  '),
          'https://api.openai.com/v1');
    });

    test('empty string falls back to the default', () {
      expect(normalizeLlmBaseUrl(''), defaultLlmBaseUrl);
      expect(normalizeLlmBaseUrl('   '), defaultLlmBaseUrl);
      expect(normalizeLlmBaseUrl('///'), defaultLlmBaseUrl);
    });

    test('does not append or strip /v1', () {
      expect(normalizeLlmBaseUrl('http://localhost:11434/v1'),
          'http://localhost:11434/v1');
      expect(normalizeLlmBaseUrl('http://localhost:11434'),
          'http://localhost:11434');
    });
  });

  group('llmChatCompletionsUrl / llmModelsUrl', () {
    test('OpenAI', () {
      expect(llmChatCompletionsUrl('https://api.openai.com/v1').toString(),
          'https://api.openai.com/v1/chat/completions');
      expect(llmModelsUrl('https://api.openai.com/v1').toString(),
          'https://api.openai.com/v1/models');
    });

    test('OpenRouter', () {
      expect(llmChatCompletionsUrl('https://openrouter.ai/api/v1').toString(),
          'https://openrouter.ai/api/v1/chat/completions');
      expect(llmModelsUrl('https://openrouter.ai/api/v1').toString(),
          'https://openrouter.ai/api/v1/models');
    });

    test('Ollama local base with trailing slash', () {
      expect(
          llmChatCompletionsUrl('http://localhost:11434/v1/').toString(),
          'http://localhost:11434/v1/chat/completions');
      expect(llmModelsUrl('http://localhost:11434/v1/').toString(),
          'http://localhost:11434/v1/models');
    });
  });

  group('presetForBaseUrl / presetById', () {
    test('matches the OpenAI preset', () {
      expect(presetForBaseUrl('https://api.openai.com/v1/').id, 'openai');
    });

    test('matches the OpenRouter preset', () {
      expect(presetForBaseUrl('https://openrouter.ai/api/v1').id, 'openrouter');
    });

    test('matches the Ollama preset', () {
      expect(presetForBaseUrl('http://localhost:11434/v1').id, 'ollama');
    });

    test('an unknown base URL falls back to custom', () {
      expect(presetForBaseUrl('https://example.com/api').id, 'custom');
    });

    test('presetById looks up by id and falls back to custom', () {
      expect(presetById('openai').label, 'OpenAI');
      expect(presetById('nonexistent').id, 'custom');
    });
  });

  group('extractJsonObject', () {
    test('parses a plain JSON object', () {
      expect(extractJsonObject('{"a": 1, "b": 2}'), {'a': 1, 'b': 2});
    });

    test('parses JSON inside a ```json code fence', () {
      const raw = '''
Here you go:
```json
{"a": 1, "b": "two"}
```
Thanks!
''';
      expect(extractJsonObject(raw), {'a': 1, 'b': 'two'});
    });

    test('parses JSON after leading prose', () {
      const raw = 'Sure, here is the result: {"result": true}';
      expect(extractJsonObject(raw), {'result': true});
    });

    test('skips braces inside string values, including escaped quotes', () {
      const raw = r'{"note": "use {curly} and \"quoted\" text", "ok": 1}';
      expect(extractJsonObject(raw), {
        'note': 'use {curly} and "quoted" text',
        'ok': 1,
      });
    });

    test('garbage input returns null', () {
      expect(extractJsonObject('not json at all'), isNull);
      expect(extractJsonObject(''), isNull);
      expect(extractJsonObject('{unterminated'), isNull);
    });
  });
}
