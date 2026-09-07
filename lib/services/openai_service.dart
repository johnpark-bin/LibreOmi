/// Direct OpenAI-compatible chat API service.
///
/// "OpenAI-compatible" because the base URL is user-configurable (LO-60):
/// besides OpenAI's own API, this also talks to OpenRouter, Ollama,
/// LM Studio and any other server that speaks the same `/chat/completions`
/// and `/models` shapes.
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'llm_endpoint.dart';
import 'settings_service.dart';

/// Thrown when the OpenAI-compatible HTTP API responds with a non-200 status.
///
/// Callers (see `lib/intelligence/openai_client.dart`) map this into a
/// retryable/permanent distinction based on [statusCode].
class OpenAiHttpException implements Exception {
  OpenAiHttpException(this.statusCode, [this.body]);
  final int statusCode;
  final String? body;
  @override
  String toString() => 'OpenAI API error: $statusCode';
}

/// Result of probing an LLM endpoint's `/models` listing. Never throws;
/// see [OpenAIService.testConnection].
class LlmConnectionResult {
  final bool ok;
  final String message;
  final List<String> models;

  const LlmConnectionResult({
    required this.ok,
    required this.message,
    this.models = const [],
  });
}

/// Status codes that indicate the server rejected the *request shape*
/// (e.g. an unsupported `response_format`), rather than an auth or
/// availability problem. Only these are worth retrying without JSON mode.
const Set<int> _jsonModeUnsupportedStatuses = {400, 404, 415, 422};

class OpenAIService {
  final String apiKey;
  final String model;

  /// Base URL for every HTTP call this service makes, already normalized.
  /// NOTE: this does NOT read [SettingsService] itself — it must stay
  /// constructible in unit tests without SharedPreferences. The
  /// app-facing entry point, `OpenAiClient.fromApiKey`, is responsible for
  /// passing the user's configured `SettingsService.llmBaseUrl` in.
  final String baseUrl;

  /// Optional HTTP client for tests. When null, a fresh [http.Client] is
  /// used per call via the top-level `http.post`, matching the original
  /// behaviour; tests can inject a `MockClient` to avoid real network calls.
  final http.Client? _client;

  OpenAIService({
    required this.apiKey,
    String? model,
    String? baseUrl,
    http.Client? client,
  })  : model = model ?? SettingsService.openaiModel,
        baseUrl = normalizeLlmBaseUrl(baseUrl ?? defaultLlmBaseUrl),
        _client = client;

  Future<http.Response> _post(Uri url, {required Map<String, String> headers, required Object body}) {
    final client = _client;
    if (client == null) {
      return http.post(url, headers: headers, body: body);
    }
    return client.post(url, headers: headers, body: body);
  }

  Future<http.Response> _get(Uri url, {required Map<String, String> headers}) {
    final client = _client;
    if (client == null) {
      return http.get(url, headers: headers);
    }
    return client.get(url, headers: headers);
  }

  /// Chat with the configured LLM using conversation context
  Future<String> chat({
    required String userMessage,
    String? conversationContext,
  }) async {
    try {
      final messages = <Map<String, String>>[];

      // System message with context
      String systemPrompt = 'You are a helpful AI assistant. You have access to the user\'s conversation history and memories.';

      if (conversationContext != null && conversationContext.isNotEmpty) {
        systemPrompt += '''

Here is the user's recent conversation history for context:

$conversationContext

Use this context to provide personalized and relevant responses. Reference specific conversations when appropriate.''';
      }

      messages.add({
        'role': 'system',
        'content': systemPrompt,
      });

      messages.add({
        'role': 'user',
        'content': userMessage,
      });

      final response = await _post(
        llmChatCompletionsUrl(baseUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': model,
          'messages': messages,
          'max_tokens': 1000,
        }),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final content = json['choices']?[0]?['message']?['content'];

        _trackUsage(json['usage']);

        return content ?? 'No response generated';
      } else {
        debugPrint('OpenAI API error: ${response.statusCode} ${response.body}');
        throw OpenAiHttpException(response.statusCode, response.body);
      }
    } catch (e) {
      debugPrint('OpenAI chat error: $e');
      rethrow;
    }
  }

  /// Builds the summarize-conversation request body. When [jsonMode] is
  /// true, asks the server to constrain output to a JSON object via
  /// `response_format`; some OpenAI-compatible servers (Ollama, LM Studio,
  /// some OpenRouter models) reject that field outright, so callers retry
  /// once with [jsonMode] false on a request-shape rejection.
  Map<String, dynamic> _summarizeBody(String transcript, DateTime now, {required bool jsonMode}) {
    final timeContext = 'Current date/time: ${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final body = <String, dynamic>{
      'model': model,
      'messages': [
        {
          'role': 'system',
          'content': '''You analyze conversations and extract key information.
$timeContext

Respond with JSON only:
{
  "title": "short descriptive title",
  "summary": "brief 1-2 sentence summary",
  "memories": ["important fact 1", "important fact 2"],
  "tasks": [
    {"title": "task description", "due_date": "2024-12-12T18:00:00"}
  ]
}

For memories, extract ONLY important facts worth remembering long-term, such as:
- Names (e.g., "User's name is Karsten")
- Preferences (e.g., "User prefers tea over coffee")
- Personal details (e.g., "User works as a software engineer")

For tasks, extract actionable items mentioned:
- Things the user needs to do (e.g., "I have to write my essay tonight" → task with due_date tonight around 6pm)
- Appointments or deadlines mentioned
- Use ISO 8601 format for due_date (or null if no time mentioned)
- Infer reasonable times: "tonight" = 6pm today, "tomorrow morning" = 9am tomorrow

If there are no notable facts/tasks, return empty arrays.
Keep each item as a short, clear statement.'''
        },
        {
          'role': 'user',
          'content': 'Analyze this conversation:\n\n$transcript'
        }
      ],
      'max_tokens': 700,
    };
    if (jsonMode) {
      body['response_format'] = {'type': 'json_object'};
    }
    return body;
  }

  /// Generate a title, summary, extract memories and tasks from a conversation.
  ///
  /// Throws [OpenAiHttpException] on a non-200 response, [FormatException]
  /// if a 200 response has no message content, and lets network exceptions
  /// propagate unchanged. This used to swallow all failures and return a
  /// fixed "Untitled Conversation" sentinel map instead; callers that relied
  /// on that sentinel (see `FinalizationQueue`) now need to reconstruct it
  /// from the thrown exception.
  // TODO(LO-23): FinalizationQueue's sentinel-map heuristic is retired once
  // the queue itself is migrated to consume typed errors directly.
  Future<Map<String, dynamic>> summarizeConversation(String transcript, {DateTime? currentTime}) async {
    final now = currentTime ?? DateTime.now();
    final url = llmChatCompletionsUrl(baseUrl);
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    };

    var response = await _post(
      url,
      headers: headers,
      body: jsonEncode(_summarizeBody(transcript, now, jsonMode: true)),
    );

    // Some OpenAI-compatible servers reject `response_format`; a rejected
    // request (not an auth/availability failure) is worth one retry without
    // it. 401/403/429/5xx are left alone since dropping JSON mode won't fix
    // those.
    if (_jsonModeUnsupportedStatuses.contains(response.statusCode)) {
      debugPrint(
        'OpenAI summarize: server rejected response_format (status ${response.statusCode}); retrying without JSON mode',
      );
      response = await _post(
        url,
        headers: headers,
        body: jsonEncode(_summarizeBody(transcript, now, jsonMode: false)),
      );
    }

    if (response.statusCode != 200) {
      debugPrint('OpenAI summarize API error: ${response.statusCode} ${response.body}');
      throw OpenAiHttpException(response.statusCode, response.body);
    }

    final json = jsonDecode(response.body);
    final content = json['choices']?[0]?['message']?['content'];

    _trackUsage(json['usage']);

    if (content == null) {
      debugPrint('OpenAI summarize error: no content in response');
      throw FormatException('OpenAI returned no summary content');
    }

    final parsed = _parseSummaryContent(content);
    return {
      'title': parsed['title'] ?? 'Untitled Conversation',
      'summary': parsed['summary'] ?? '',
      'memories': (parsed['memories'] as List?)?.cast<String>() ?? [],
      'tasks': parsed['tasks'] ?? [],
    };
  }

  /// Parses the LLM's summary content into a JSON map. Models sometimes
  /// wrap the JSON in a ```json code fence or prepend prose despite being
  /// asked for JSON only; fall back to scanning for a balanced object.
  Map<String, dynamic> _parseSummaryContent(String content) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      // fall through to extraction below
    }
    final extracted = extractJsonObject(content);
    if (extracted != null) {
      return extracted;
    }
    throw FormatException('LLM returned no parseable JSON summary');
  }

  /// Tracks token usage from a response's `usage` field, if present.
  /// Tolerates a partial/malformed usage object (missing or non-int token
  /// fields are treated as 0) since not every OpenAI-compatible server
  /// sends a complete usage block.
  void _trackUsage(dynamic usage) {
    // `is! Map` rather than `== null`: an OpenAI-compatible server may send
    // `"usage": []` or a scalar, and indexing that would throw out of an
    // otherwise successful summarize call.
    if (usage is! Map) return;
    final promptTokens = usage['prompt_tokens'];
    final completionTokens = usage['completion_tokens'];
    SettingsService.addOpenAIUsage(
      promptTokens is int ? promptTokens : 0,
      completionTokens is int ? completionTokens : 0,
    );
  }

  /// Probes the configured endpoint's model listing. Never throws.
  Future<LlmConnectionResult> testConnection() async {
    try {
      final response = await _get(
        llmModelsUrl(baseUrl),
        headers: {'Authorization': 'Bearer $apiKey'},
      );

      if (response.statusCode != 200) {
        final excerpt = _truncate(response.body, 200);
        return LlmConnectionResult(
          ok: false,
          message: 'Connection failed: HTTP ${response.statusCode} — $excerpt',
        );
      }

      final models = _parseModelIds(response.body);
      return LlmConnectionResult(
        ok: true,
        message: 'Connected — ${models.length} models',
        models: models,
      );
    } catch (e) {
      return LlmConnectionResult(ok: false, message: e.toString());
    }
  }

  /// Parses the OpenAI-compatible `{"data":[{"id":"..."}]}` model-listing
  /// shape. Tolerates a missing/odd shape by returning an empty list.
  List<String> _parseModelIds(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return const [];
      final data = decoded['data'];
      if (data is! List) return const [];
      return data
          .map((entry) => entry is Map ? entry['id'] : null)
          .whereType<String>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  String _truncate(String s, int maxLength) {
    if (s.length <= maxLength) return s;
    return '${s.substring(0, maxLength)}…';
  }
}
