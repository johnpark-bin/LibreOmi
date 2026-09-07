import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../services/openai_service.dart';
import '../services/settings_service.dart';
import 'llm_client.dart';

/// [LlmClient] backed by [OpenAIService], talking to any OpenAI-compatible
/// endpoint (OpenAI itself, OpenRouter, Ollama, LM Studio, ...). Wraps the
/// service's HTTP calls and translates its untyped map/exception surface
/// into the typed [LlmClient] contract.
class OpenAiClient implements LlmClient {
  /// Primary constructor: wraps an already-configured [OpenAIService]. This
  /// is what tests use (with a `MockClient` wired into the service) and
  /// what the provider uses today, since it already rebuilds an
  /// `OpenAIService` per call from the stored API key.
  OpenAiClient({required OpenAIService service}) : _service = service;

  /// Convenience constructor for callers that only have raw credentials.
  ///
  /// This is the app-facing entry point (used by `lib/controllers/`), so
  /// [baseUrl] defaults to the user's configured `SettingsService.llmBaseUrl`
  /// when omitted — mirroring how [model] already defaults to
  /// `SettingsService.openaiModel`.
  OpenAiClient.fromApiKey({required String apiKey, String? model, String? baseUrl, http.Client? client})
      : _service = OpenAIService(
          apiKey: apiKey,
          model: model,
          baseUrl: baseUrl ?? SettingsService.llmBaseUrl,
          client: client,
        );

  final OpenAIService _service;

  @override
  Future<ConversationInsights> summarize(String transcript, {DateTime? now}) async {
    try {
      final map = await _service.summarizeConversation(transcript, currentTime: now);
      return ConversationInsights.fromMap(map);
    } catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<String> chat(String user, {String? context}) async {
    try {
      return await _service.chat(userMessage: user, conversationContext: context);
    } catch (e) {
      throw _mapException(e);
    }
  }

  /// Maps an error thrown by [OpenAIService] into an [LlmException],
  /// preserving it as [LlmException.cause].
  ///
  /// - [OpenAiHttpException] with status 429 or >= 500 is retryable
  ///   (rate limit / transient server error); any other non-2xx status is
  ///   permanent (e.g. 401 bad key, 400 bad request).
  /// - Network-layer failures (no response received at all) are retryable.
  /// - [FormatException] (malformed/missing response content) and anything
  ///   else unrecognized is treated as permanent, since retrying an
  ///   unparseable response is unlikely to help.
  LlmException _mapException(Object error) {
    if (error is OpenAiHttpException) {
      if (error.statusCode == 429 || error.statusCode >= 500) {
        return LlmRetryableException('OpenAI API error: ${error.statusCode}', error);
      }
      return LlmPermanentException('OpenAI API error: ${error.statusCode}', error);
    }
    if (error is SocketException ||
        error is TimeoutException ||
        error is http.ClientException ||
        error is HttpException) {
      return LlmRetryableException('OpenAI network error: $error', error);
    }
    if (error is FormatException) {
      return LlmPermanentException('OpenAI response error: ${error.message}', error);
    }
    return LlmPermanentException('OpenAI error: $error', error);
  }
}
