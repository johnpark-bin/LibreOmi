/// Pure Dart helpers for the user-configurable LLM endpoint (LO-60).
///
/// Deliberately free of Flutter/plugin imports so it can be unit tested
/// without a widget or platform-channel host.
library;

import 'dart:convert';

/// Default base URL used when the user has not configured one.
const String defaultLlmBaseUrl = 'https://api.openai.com/v1';

/// Normalizes a user-supplied LLM base URL: trims whitespace and strips all
/// trailing slashes. Does NOT append or strip `/v1` — the user configures
/// the full base (e.g. `http://localhost:11434/v1`). An empty result falls
/// back to [defaultLlmBaseUrl].
String normalizeLlmBaseUrl(String raw) {
  var value = raw.trim();
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  if (value.isEmpty) {
    return defaultLlmBaseUrl;
  }
  return value;
}

/// The chat-completions endpoint for [base].
Uri llmChatCompletionsUrl(String base) =>
    Uri.parse('${normalizeLlmBaseUrl(base)}/chat/completions');

/// The models-listing endpoint for [base].
Uri llmModelsUrl(String base) =>
    Uri.parse('${normalizeLlmBaseUrl(base)}/models');

/// A named preset for a common OpenAI-compatible LLM provider.
class LlmPreset {
  final String id;
  final String label;
  final String baseUrl;
  final List<String> models;

  const LlmPreset({
    required this.id,
    required this.label,
    required this.baseUrl,
    required this.models,
  });
}

const LlmPreset _openaiPreset = LlmPreset(
  id: 'openai',
  label: 'OpenAI',
  baseUrl: defaultLlmBaseUrl,
  models: ['gpt-4.1', 'gpt-4.1-mini', 'gpt-4.1-nano', 'gpt-4o-mini', 'gpt-5-mini'],
);

const LlmPreset _openrouterPreset = LlmPreset(
  id: 'openrouter',
  label: 'OpenRouter',
  baseUrl: 'https://openrouter.ai/api/v1',
  models: [
    'openai/gpt-4.1-mini',
    'anthropic/claude-3.5-haiku',
    'meta-llama/llama-3.3-70b-instruct',
  ],
);

const LlmPreset _ollamaPreset = LlmPreset(
  id: 'ollama',
  label: 'Ollama (local)',
  baseUrl: 'http://localhost:11434/v1',
  models: ['llama3.2', 'qwen2.5', 'mistral'],
);

const LlmPreset _customPreset = LlmPreset(
  id: 'custom',
  label: 'Custom',
  baseUrl: '',
  models: [],
);

/// All built-in presets, in display order.
const List<LlmPreset> llmPresets = [
  _openaiPreset,
  _openrouterPreset,
  _ollamaPreset,
  _customPreset,
];

/// Returns the preset whose normalized [LlmPreset.baseUrl] matches
/// [baseUrl] (also normalized), or the "custom" preset if none match.
LlmPreset presetForBaseUrl(String baseUrl) {
  final normalized = normalizeLlmBaseUrl(baseUrl);
  for (final preset in llmPresets) {
    if (preset.baseUrl.isEmpty) continue;
    if (normalizeLlmBaseUrl(preset.baseUrl) == normalized) {
      return preset;
    }
  }
  return _customPreset;
}

/// Returns the preset with the given [id], or the "custom" preset if no
/// preset has that id.
LlmPreset presetById(String id) {
  for (final preset in llmPresets) {
    if (preset.id == id) {
      return preset;
    }
  }
  return _customPreset;
}

/// Extracts and decodes the first balanced top-level `{...}` JSON object
/// found in [raw], tolerating leading prose and ```json code fences.
/// Correctly skips braces inside JSON string literals (including escaped
/// quotes). Returns null if no balanced object can be parsed.
Map<String, dynamic>? extractJsonObject(String raw) {
  final start = raw.indexOf('{');
  if (start == -1) return null;

  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < raw.length; i++) {
    final ch = raw[i];

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }

    if (ch == '"') {
      inString = true;
      continue;
    }
    if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) {
        final candidate = raw.substring(start, i + 1);
        try {
          final decoded = jsonDecode(candidate);
          if (decoded is Map<String, dynamic>) {
            return decoded;
          }
          return null;
        } catch (_) {
          return null;
        }
      }
    }
  }
  return null;
}
