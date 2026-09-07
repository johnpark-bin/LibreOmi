/// Settings service for storing API keys locally
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../transcription/model_catalog.dart';
import 'llm_endpoint.dart' as llm_endpoint;
import 'secret_store.dart';

class SettingsService {
  static SharedPreferences? _prefs;

  static const String _deepgramApiKeyKey = 'deepgram_api_key';
  static const String _openaiApiKeyKey = 'openai_api_key';
  static const String _secureKeysMigratedKey = 'secure_keys_migrated';

  /// In-memory cache of the two secrets, loaded from [_secretStore] at
  /// [init] time so the synchronous getters below can keep working without
  /// changing their signatures (12+ call sites across lib/ read them
  /// synchronously).
  static final Map<String, String> _secrets = {};
  static SecretStore? _secretStore;

  /// Loads settings and secrets. [secretStore] is injectable for tests; in
  /// production a real [SecureStorageSecretStore] is used.
  ///
  /// All secret-store IO is wrapped in try/catch: a unit-test host without
  /// the plugin, or a device with a broken keystore, must not prevent the
  /// app from booting. On failure we log and continue with an empty secret
  /// cache, and we skip the one-time migration below so legacy plaintext
  /// values are not deleted before we have proven we can write their secure
  /// replacement.
  static Future<void> init({SecretStore? secretStore}) async {
    _prefs = await SharedPreferences.getInstance();
    _secrets.clear();
    _secretStore = secretStore ?? SecureStorageSecretStore();

    bool loadedOk = true;
    try {
      final deepgram = await _secretStore!.read(_deepgramApiKeyKey);
      if (deepgram != null && deepgram.isNotEmpty) {
        _secrets[_deepgramApiKeyKey] = deepgram;
      }
      final openai = await _secretStore!.read(_openaiApiKeyKey);
      if (openai != null && openai.isNotEmpty) {
        _secrets[_openaiApiKeyKey] = openai;
      }
    } catch (e) {
      loadedOk = false;
      debugPrint('SettingsService: failed to load secrets from secure storage: $e');
    }

    if (loadedOk) {
      await _migrateLegacyKeysIfNeeded();
    }
  }

  /// One-time migration of the plaintext API keys that used to live in
  /// SharedPreferences into [_secretStore]. Guarded by [_secureKeysMigratedKey]
  /// so it only ever runs once it has succeeded.
  static Future<void> _migrateLegacyKeysIfNeeded() async {
    if (prefs.getBool(_secureKeysMigratedKey) ?? false) {
      return;
    }

    try {
      for (final key in [_deepgramApiKeyKey, _openaiApiKeyKey]) {
        final hasSecure = (_secrets[key] ?? '').isNotEmpty;
        final legacy = prefs.getString(key) ?? '';
        if (!hasSecure && legacy.isNotEmpty) {
          await _secretStore!.write(key, legacy);
          _secrets[key] = legacy;
        }
      }
    } catch (e) {
      debugPrint('SettingsService: migration to secure storage failed, will retry on next launch: $e');
      return;
    }

    await prefs.remove(_deepgramApiKeyKey);
    await prefs.remove(_openaiApiKeyKey);
    await prefs.setBool(_secureKeysMigratedKey, true);
  }

  /// Whether the legacy-plaintext-to-secure-storage migration has completed.
  static bool get secureKeysMigrated => prefs.getBool(_secureKeysMigratedKey) ?? false;

  static SharedPreferences get prefs {
    if (_prefs == null) {
      throw Exception('SettingsService not initialized. Call init() first.');
    }
    return _prefs!;
  }

  static SecretStore get _store {
    if (_secretStore == null) {
      throw Exception('SettingsService not initialized. Call init() first.');
    }
    return _secretStore!;
  }

  /// Updates the cache immediately (so the setter stays synchronous) and
  /// fires the secure-store write without awaiting it.
  ///
  /// A failed write is logged and otherwise swallowed. Nothing retries it:
  /// [init] only reads, so the value stays usable for the rest of this
  /// session and is then silently gone on the next launch. That is the
  /// accepted trade-off for keeping the setter synchronous — surfacing the
  /// failure in the settings UI is left as follow-up work.
  static void _setSecret(String key, String value) {
    if (value.isEmpty) {
      _secrets.remove(key);
      _store.delete(key).catchError((Object e) {
        debugPrint('SettingsService: failed to delete secret "$key": $e');
      });
    } else {
      _secrets[key] = value;
      _store.write(key, value).catchError((Object e) {
        debugPrint('SettingsService: failed to write secret "$key": $e');
      });
    }
  }

  // API Keys
  static String get deepgramApiKey => _secrets[_deepgramApiKeyKey] ?? '';
  static set deepgramApiKey(String value) => _setSecret(_deepgramApiKeyKey, value);

  static String get openaiApiKey => _secrets[_openaiApiKeyKey] ?? '';
  static set openaiApiKey(String value) => _setSecret(_openaiApiKeyKey, value);

  // Settings
  static String get language => prefs.getString('language') ?? 'en';
  static set language(String value) => prefs.setString('language', value);

  static String get openaiModel => prefs.getString('openai_model') ?? 'gpt-4.1-mini';
  static set openaiModel(String value) => prefs.setString('openai_model', value);

  /// Base URL of the OpenAI-compatible LLM endpoint (LO-60). Defaults to
  /// OpenAI's own API; normalized (trailing slashes stripped) on both read
  /// and write so callers never need to re-normalize it.
  static const String defaultLlmBaseUrl = llm_endpoint.defaultLlmBaseUrl;

  static String get llmBaseUrl =>
      llm_endpoint.normalizeLlmBaseUrl(prefs.getString('llm_base_url') ?? defaultLlmBaseUrl);
  static set llmBaseUrl(String value) =>
      prefs.setString('llm_base_url', llm_endpoint.normalizeLlmBaseUrl(value));

  static const String _llmCustomModelsKey = 'llm_custom_models';

  /// User-added model ids for the configured endpoint. Defensive on read:
  /// malformed JSON or a value containing non-string entries yields an
  /// empty list rather than throwing.
  static List<String> get llmCustomModels {
    final raw = prefs.getString(_llmCustomModelsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final result = <String>[];
      for (final item in decoded) {
        if (item is! String) return [];
        result.add(item);
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  static set llmCustomModels(List<String> value) =>
      prefs.setString(_llmCustomModelsKey, jsonEncode(value));

  /// Deepgram streaming model. Keys of [deepgramPricePerMinute] are the
  /// supported values; anything else falls back to the default.
  static String get deepgramModel {
    final stored = prefs.getString('deepgram_model') ?? defaultDeepgramModel;
    return deepgramPricePerMinute.containsKey(stored) ? stored : defaultDeepgramModel;
  }
  static set deepgramModel(String value) => prefs.setString('deepgram_model', value);
  
  // Transcription mode: 'cloud' (Deepgram), 'whisper', or 'sherpa'
  static String get transcriptionMode => prefs.getString('transcription_mode') ?? 'cloud';
  static set transcriptionMode(String value) => prefs.setString('transcription_mode', value);
  
  /// Catalog id of the offline model the batch ("Local") mode decodes with:
  /// Whisper tiny, Whisper base or SenseVoice (LO-71).
  ///
  /// Reduced through [ModelCatalog.offlineModel] on read, so a value written
  /// by a future build — or a corrupted preference — can never point the
  /// batch mode at a model this build cannot install.
  ///
  /// Before LO-71 this was `whisper_model_size`, holding `'tiny'` or
  /// `'base'`. That key is still read when the new one is absent, which
  /// carries an existing user's choice over without a migration step; the
  /// next write lands under the new key and the old one is never written
  /// again.
  static String get offlineSttModelId {
    final stored = prefs.getString('offline_stt_model');
    if (stored != null) return ModelCatalog.offlineModel(stored).id;
    final legacySize = prefs.getString('whisper_model_size');
    if (legacySize != null) return ModelCatalog.whisper(legacySize).id;
    return ModelCatalog.defaultOfflineModel.id;
  }

  static set offlineSttModelId(String value) =>
      prefs.setString('offline_stt_model', value);

  /// Language the on-device modes transcribe in: `'en'` (default) or `'ko'`
  /// (LO-44). Separate from [language], which is the Deepgram code for the
  /// cloud mode — the two engines take different values and a user can have
  /// one set without the other.
  ///
  /// Reduced through [ModelCatalog.localSttLanguage] on read, so a value
  /// written by a future build (or a corrupted preference) can never point
  /// the Sherpa mode at a model the catalog has no entry for.
  static String get localSttLanguage =>
      ModelCatalog.localSttLanguage(prefs.getString('local_stt_language') ?? 'en');
  static set localSttLanguage(String value) =>
      prefs.setString('local_stt_language', value);

  /// Catalog id of the streaming model the Sherpa mode loads, derived from
  /// [localSttLanguage].
  ///
  /// Deliberately not a stored preference of its own: the language is the
  /// only thing the user picks, and storing the id beside it would let the
  /// two disagree after a catalog change.
  static String get sherpaModelId => ModelCatalog.streaming(localSttLanguage).id;
  
  static bool get useLocalTranscription => transcriptionMode == 'sherpa' || transcriptionMode == 'whisper';
  static bool get useSherpa => transcriptionMode == 'sherpa';
  static bool get useWhisper => transcriptionMode == 'whisper';
  static bool get useDeepgram => transcriptionMode == 'cloud';
  
  // Audio source: 'omi' (default) or 'phone_mic'
  static String get audioSource => prefs.getString('audio_source') ?? 'omi';
  static set audioSource(String value) => prefs.setString('audio_source', value);
  
  static bool get useOmiDevice => audioSource == 'omi';
  static bool get usePhoneMic => audioSource == 'phone_mic';

  
  // Saved device for auto-connect
  static String get savedDeviceId => prefs.getString('saved_device_id') ?? '';
  static set savedDeviceId(String value) => prefs.setString('saved_device_id', value);
  
  static String get savedDeviceName => prefs.getString('saved_device_name') ?? '';
  static set savedDeviceName(String value) => prefs.setString('saved_device_name', value);
  
  static void clearSavedDevice() {
    prefs.remove('saved_device_id');
    prefs.remove('saved_device_name');
  }

  // Helper
  static bool get hasApiKeys => (deepgramApiKey.isNotEmpty || useLocalTranscription) && openaiApiKey.isNotEmpty;
  static bool get hasOpenAIKey => openaiApiKey.isNotEmpty;
  static bool get hasDeepgramKey => deepgramApiKey.isNotEmpty;
  
  // Notification settings
  static bool get notifyBatteryLow => prefs.getBool('notify_battery_low') ?? true;
  static set notifyBatteryLow(bool value) => prefs.setBool('notify_battery_low', value);
  
  static bool get notifyBatteryCritical => prefs.getBool('notify_battery_critical') ?? true;
  static set notifyBatteryCritical(bool value) => prefs.setBool('notify_battery_critical', value);
  
  static bool get notifyTaskReminders => prefs.getBool('notify_task_reminders') ?? true;
  static set notifyTaskReminders(bool value) => prefs.setBool('notify_task_reminders', value);
  
  static bool get notifyProcessing => prefs.getBool('notify_processing') ?? true;
  static set notifyProcessing(bool value) => prefs.setBool('notify_processing', value);

  /// Whether the developer "Capture BLE session" toggle is on (LO-31).
  /// When true, `JsonlBleSessionCapture` records connected devices' BLE
  /// notifications to a replay fixture `FakeOmiDevice` can read back (see
  /// `test/fixtures/README.md`).
  static bool get captureBleSession => prefs.getBool('capture_ble_session') ?? false;
  static set captureBleSession(bool value) => prefs.setBool('capture_ble_session', value);

  /// Whether the one-time battery-optimisation explanation dialog has already
  /// been shown before a session start (LO-21). Set once, so a user who
  /// refused is never asked automatically again; the settings page is the way
  /// back in.
  static bool get batteryOptimizationPromptShown =>
      prefs.getBool('battery_optimization_prompt_shown') ?? false;
  static set batteryOptimizationPromptShown(bool value) =>
      prefs.setBool('battery_optimization_prompt_shown', value);

  // iCloud backup
  static bool get icloudBackupEnabled => prefs.getBool('icloud_backup_enabled') ?? false;
  static set icloudBackupEnabled(bool value) => prefs.setBool('icloud_backup_enabled', value);
  
  // API Usage Tracking
  static double get deepgramMinutesUsed => prefs.getDouble('deepgram_minutes_used') ?? 0.0;
  static set deepgramMinutesUsed(double value) => prefs.setDouble('deepgram_minutes_used', value);
  
  static int get openaiInputTokens => prefs.getInt('openai_input_tokens') ?? 0;
  static set openaiInputTokens(int value) => prefs.setInt('openai_input_tokens', value);
  
  static int get openaiOutputTokens => prefs.getInt('openai_output_tokens') ?? 0;
  static set openaiOutputTokens(int value) => prefs.setInt('openai_output_tokens', value);
  
  // Track usage
  static void addDeepgramUsage(double minutes) {
    deepgramMinutesUsed = deepgramMinutesUsed + minutes;
  }
  
  static void addOpenAIUsage(int inputTokens, int outputTokens) {
    openaiInputTokens = openaiInputTokens + inputTokens;
    openaiOutputTokens = openaiOutputTokens + outputTokens;
  }
  
  static void resetUsageStats() {
    deepgramMinutesUsed = 0.0;
    openaiInputTokens = 0;
    openaiOutputTokens = 0;
  }
  
  // Pricing (per 1M tokens for the LLM, per minute for Deepgram)
  static const Map<String, Map<String, double>> defaultLlmPricing = {
    'gpt-5-nano': {'input': 0.10, 'output': 0.40},
    'gpt-5-mini': {'input': 0.40, 'output': 1.60},
    'gpt-5': {'input': 2.00, 'output': 8.00},
    'gpt-4o-mini': {'input': 0.15, 'output': 0.60},
    'gpt-4o': {'input': 2.50, 'output': 10.00},
    'gpt-4.1': {'input': 2.00, 'output': 8.00},
    'gpt-4.1-mini': {'input': 0.40, 'output': 1.60},
    'gpt-4.1-nano': {'input': 0.10, 'output': 0.40},
    'gpt-4-turbo': {'input': 10.00, 'output': 30.00},
    'gpt-3.5-turbo': {'input': 0.50, 'output': 1.50},
  };

  static const String _llmPricingKey = 'llm_pricing';

  /// The editable LLM pricing table (LO-60). Decoded from JSON stored under
  /// [_llmPricingKey]; when absent or malformed, [defaultLlmPricing] is
  /// returned instead of throwing.
  static Map<String, Map<String, double>> get llmPricing {
    final raw = prefs.getString(_llmPricingKey);
    if (raw == null || raw.isEmpty) return defaultLlmPricing;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return defaultLlmPricing;
      final result = <String, Map<String, double>>{};
      for (final entry in decoded.entries) {
        final modelId = entry.key;
        final value = entry.value;
        if (modelId is! String || value is! Map) return defaultLlmPricing;
        final input = value['input'];
        final output = value['output'];
        if (input is! num || output is! num) return defaultLlmPricing;
        result[modelId] = {
          'input': input.toDouble(),
          'output': output.toDouble(),
        };
      }
      return result;
    } catch (_) {
      return defaultLlmPricing;
    }
  }

  static set llmPricing(Map<String, Map<String, double>> value) =>
      prefs.setString(_llmPricingKey, jsonEncode(value));

  /// Removes the stored pricing override, reverting [llmPricing] to
  /// [defaultLlmPricing].
  static void resetLlmPricing() => prefs.remove(_llmPricingKey);

  static const String defaultDeepgramModel = 'nova-2';

  /// Streaming price per minute, per model. Both models are billed at the same
  /// published rate today; LO-60 makes only the LLM pricing table editable,
  /// this one stays fixed.
  static const Map<String, double> deepgramPricePerMinute = {
    'nova-2': 0.0059,
    'nova-3': 0.0059,
  };

  // Cost calculations
  static double get deepgramCost =>
      deepgramMinutesUsed *
      (deepgramPricePerMinute[deepgramModel] ??
          deepgramPricePerMinute[defaultDeepgramModel]!);

  /// Estimated LLM cost so far, or null when no pricing is known for
  /// [openaiModel] (no default-pricing assumption is made).
  static double? get llmCost {
    final pricing = llmPricing[openaiModel];
    if (pricing == null) return null;
    final inputCost = (openaiInputTokens / 1000000) * pricing['input']!;
    final outputCost = (openaiOutputTokens / 1000000) * pricing['output']!;
    return inputCost + outputCost;
  }

  static double? get totalApiCost {
    final llm = llmCost;
    if (llm == null) return null;
    return deepgramCost + llm;
  }

  /// Whether the user opted task reminders into exact alarms (LO-50).
  ///
  /// Off by default: reminders stay inexact, so the app works without
  /// `SCHEDULE_EXACT_ALARM`, which Android 14+ denies by default to apps
  /// targeting API 33+. Turning it on is not sufficient on its own — the
  /// permission is re-read at schedule time (see `platform/exact_alarm.dart`),
  /// so a revoked permission degrades back to an inexact alarm.
  static bool get exactTaskReminders =>
      prefs.getBool('exact_task_reminders') ?? false;
  static set exactTaskReminders(bool value) =>
      prefs.setBool('exact_task_reminders', value);
}
