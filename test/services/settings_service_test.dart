import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:libreomi/services/settings_service.dart';
import 'package:libreomi/services/secret_store.dart';
import 'package:libreomi/transcription/model_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsService.deepgramModel', () {
    test('defaults to nova-2', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());

      expect(SettingsService.deepgramModel, 'nova-2');
    });

    test('setting to nova-3 persists and reads back', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());

      SettingsService.deepgramModel = 'nova-3';

      expect(SettingsService.deepgramModel, 'nova-3');
    });

    test('falls back to nova-2 for a garbage stored value', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'deepgram_model': 'bogus',
      });
      await SettingsService.init(secretStore: InMemorySecretStore());

      expect(SettingsService.deepgramModel, 'nova-2');
    });
  });

  group('SettingsService.batteryOptimizationPromptShown', () {
    test('defaults to false on a fresh install', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());

      expect(SettingsService.batteryOptimizationPromptShown, isFalse);
    });

    test('setting it to true persists and reads back', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());

      SettingsService.batteryOptimizationPromptShown = true;

      expect(SettingsService.batteryOptimizationPromptShown, isTrue);
    });

    test('reads a value stored by an earlier run', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'battery_optimization_prompt_shown': true,
      });
      await SettingsService.init(secretStore: InMemorySecretStore());

      expect(SettingsService.batteryOptimizationPromptShown, isTrue);
    });
  });

  group('SettingsService.deepgramCost', () {
    test('equals minutes used times price per minute for nova-2', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());

      SettingsService.deepgramModel = 'nova-2';
      SettingsService.deepgramMinutesUsed = 10.0;

      expect(SettingsService.deepgramCost, closeTo(10.0 * 0.0059, 1e-9));
    });

    test('equals minutes used times price per minute for nova-3', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());

      SettingsService.deepgramModel = 'nova-3';
      SettingsService.deepgramMinutesUsed = 7.5;

      expect(SettingsService.deepgramCost, closeTo(7.5 * 0.0059, 1e-9));
    });
  });

  group('SettingsService API keys', () {
    test('fresh install with no legacy values: getters empty, migration flag set, nothing written', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = InMemorySecretStore();

      await SettingsService.init(secretStore: store);

      expect(SettingsService.deepgramApiKey, '');
      expect(SettingsService.openaiApiKey, '');
      expect(SettingsService.secureKeysMigrated, isTrue);
      expect(store.values, isEmpty);
    });

    test('migrates legacy plaintext values into secure storage and removes them from prefs', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'deepgram_api_key': 'dg-legacy',
        'openai_api_key': 'oa-legacy',
      });
      final store = InMemorySecretStore();

      await SettingsService.init(secretStore: store);

      expect(SettingsService.deepgramApiKey, 'dg-legacy');
      expect(SettingsService.openaiApiKey, 'oa-legacy');
      expect(store.values['deepgram_api_key'], 'dg-legacy');
      expect(store.values['openai_api_key'], 'oa-legacy');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('deepgram_api_key'), isNull);
      expect(prefs.getString('openai_api_key'), isNull);
      expect(SettingsService.secureKeysMigrated, isTrue);
    });

    test('already migrated: secure values win over any stale legacy pref value', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'secure_keys_migrated': true,
        'deepgram_api_key': 'dg-stale-legacy',
      });
      final store = InMemorySecretStore({
        'deepgram_api_key': 'dg-secure',
        'openai_api_key': 'oa-secure',
      });

      await SettingsService.init(secretStore: store);

      expect(SettingsService.deepgramApiKey, 'dg-secure');
      expect(SettingsService.openaiApiKey, 'oa-secure');
    });

    test('restart loads the cache from the secret store', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'secure_keys_migrated': true,
      });
      final store = InMemorySecretStore({
        'deepgram_api_key': 'dg-from-store',
        'openai_api_key': 'oa-from-store',
      });

      await SettingsService.init(secretStore: store);

      expect(SettingsService.deepgramApiKey, 'dg-from-store');
      expect(SettingsService.openaiApiKey, 'oa-from-store');
    });

    test('setter updates the cache synchronously and the store asynchronously', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = InMemorySecretStore();
      await SettingsService.init(secretStore: store);

      SettingsService.deepgramApiKey = 'new';

      expect(SettingsService.deepgramApiKey, 'new');

      await Future<void>.delayed(Duration.zero);

      expect(store.values['deepgram_api_key'], 'new');
    });

    test('setting an empty string deletes the cache entry and the store entry', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = InMemorySecretStore({'deepgram_api_key': 'dg-secure'});
      await SettingsService.init(secretStore: store);
      expect(SettingsService.deepgramApiKey, 'dg-secure');

      SettingsService.deepgramApiKey = '';
      expect(SettingsService.deepgramApiKey, '');

      await Future<void>.delayed(Duration.zero);

      expect(store.values.containsKey('deepgram_api_key'), isFalse);
    });

    test('a partly failed migration writes nothing back and stays unflagged', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'deepgram_api_key': 'dg-legacy',
        'openai_api_key': 'oa-legacy',
      });
      final store = InMemorySecretStore()..failWritesFor.add('openai_api_key');

      await SettingsService.init(secretStore: store);

      // The key that made it across is in the secure store, but because the
      // second write threw, neither plaintext value is deleted and the flag
      // stays false so the next launch retries.
      expect(store.values['deepgram_api_key'], 'dg-legacy');
      expect(store.values.containsKey('openai_api_key'), isFalse);
      expect(SettingsService.secureKeysMigrated, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('deepgram_api_key'), 'dg-legacy');
      expect(prefs.getString('openai_api_key'), 'oa-legacy');
    });

    test('a migration that failed once completes on the next launch', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'deepgram_api_key': 'dg-legacy',
        'openai_api_key': 'oa-legacy',
      });
      final store = InMemorySecretStore()..failing = true;

      await SettingsService.init(secretStore: store);
      expect(SettingsService.secureKeysMigrated, isFalse);

      // Second launch, with the store working again.
      store.failing = false;
      await SettingsService.init(secretStore: store);

      expect(SettingsService.deepgramApiKey, 'dg-legacy');
      expect(SettingsService.openaiApiKey, 'oa-legacy');
      expect(store.values['deepgram_api_key'], 'dg-legacy');
      expect(store.values['openai_api_key'], 'oa-legacy');
      expect(SettingsService.secureKeysMigrated, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('deepgram_api_key'), isNull);
      expect(prefs.getString('openai_api_key'), isNull);
    });

    test('a failing secret store does not throw and leaves legacy prefs untouched', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'deepgram_api_key': 'dg-legacy',
        'openai_api_key': 'oa-legacy',
      });
      final store = InMemorySecretStore()..failing = true;

      await SettingsService.init(secretStore: store);

      expect(SettingsService.deepgramApiKey, '');
      expect(SettingsService.openaiApiKey, '');
      expect(SettingsService.secureKeysMigrated, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('deepgram_api_key'), 'dg-legacy');
      expect(prefs.getString('openai_api_key'), 'oa-legacy');
    });
  });

  group('SettingsService.localSttLanguage', () {
    Future<void> boot([Map<String, Object> values = const {}]) async {
      SharedPreferences.setMockInitialValues(Map<String, Object>.from(values));
      await SettingsService.init(secretStore: InMemorySecretStore());
    }

    test('defaults to English, independently of the Deepgram language',
        () async {
      await boot(<String, Object>{'language': 'de'});

      expect(SettingsService.localSttLanguage, 'en');
      expect(SettingsService.language, 'de',
          reason: 'the cloud language is a separate preference');
    });

    test('setting to ko persists and reads back', () async {
      await boot();

      SettingsService.localSttLanguage = 'ko';

      expect(SettingsService.localSttLanguage, 'ko');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('local_stt_language'), 'ko');
    });

    test('a value the catalog has no model for reduces to en', () async {
      // Written by a future build, or corrupted. Returning it verbatim would
      // send the Sherpa mode looking for a model directory that cannot exist.
      await boot(<String, Object>{'local_stt_language': 'jp'});
      expect(SettingsService.localSttLanguage, 'en');

      await boot(<String, Object>{'local_stt_language': ''});
      expect(SettingsService.localSttLanguage, 'en');
    });

    test('sherpaModelId follows the language', () async {
      await boot();
      expect(SettingsService.sherpaModelId,
          ModelCatalog.streamingZipformerEn20M.id);

      SettingsService.localSttLanguage = 'ko';
      expect(SettingsService.sherpaModelId,
          ModelCatalog.streamingZipformerKo.id);
    });

    test('sherpaModelId is always a real catalog entry', () async {
      await boot(<String, Object>{'local_stt_language': 'jp'});
      expect(ModelCatalog.byId(SettingsService.sherpaModelId), isNotNull);
    });
  });

  group('SettingsService.offlineSttModelId (LO-71)', () {
    Future<void> boot([Map<String, Object> values = const {}]) async {
      SharedPreferences.setMockInitialValues(Map<String, Object>.from(values));
      await SettingsService.init(secretStore: InMemorySecretStore());
    }

    test('defaults to Whisper tiny on a fresh install', () async {
      await boot();
      expect(SettingsService.offlineSttModelId, ModelCatalog.whisperTiny.id);
    });

    test('setting to SenseVoice persists under the new key and reads back',
        () async {
      await boot();

      SettingsService.offlineSttModelId = ModelCatalog.senseVoice.id;

      expect(SettingsService.offlineSttModelId, ModelCatalog.senseVoice.id);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('offline_stt_model'), ModelCatalog.senseVoice.id);
    });

    test('an id this build has no offline model for reduces to the default',
        () async {
      // Written by a future build, or corrupted. Returned verbatim it would
      // send the batch mode looking for a directory that cannot exist.
      await boot(<String, Object>{'offline_stt_model': 'sherpa-onnx-whisper-small'});
      expect(SettingsService.offlineSttModelId,
          ModelCatalog.defaultOfflineModel.id);

      // A real catalog entry that this path still cannot decode.
      await boot(<String, Object>{
        'offline_stt_model': ModelCatalog.streamingZipformerKo.id,
      });
      expect(SettingsService.offlineSttModelId,
          ModelCatalog.defaultOfflineModel.id);
    });

    test('is always a real catalog entry', () async {
      await boot(<String, Object>{'offline_stt_model': 'nonsense'});
      expect(ModelCatalog.byId(SettingsService.offlineSttModelId), isNotNull);
    });

    group('legacy whisper_model_size fallback', () {
      // The one path in LO-71 that an existing install actually walks: the
      // new key is absent on first launch after the update, so the old size
      // preference has to carry the user's choice over. Getting this wrong
      // silently resets everyone who picked Whisper base back to tiny.
      test("'base' is promoted to the Whisper base catalog id", () async {
        await boot(<String, Object>{'whisper_model_size': 'base'});
        expect(SettingsService.offlineSttModelId, ModelCatalog.whisperBase.id);
      });

      test("'tiny' is promoted to the Whisper tiny catalog id", () async {
        await boot(<String, Object>{'whisper_model_size': 'tiny'});
        expect(SettingsService.offlineSttModelId, ModelCatalog.whisperTiny.id);
      });

      test('a garbage legacy size still lands on a real model', () async {
        await boot(<String, Object>{'whisper_model_size': 'small'});
        expect(SettingsService.offlineSttModelId, ModelCatalog.whisperTiny.id);
      });

      test('the new key wins when both are present', () async {
        await boot(<String, Object>{
          'whisper_model_size': 'base',
          'offline_stt_model': ModelCatalog.senseVoice.id,
        });
        expect(SettingsService.offlineSttModelId, ModelCatalog.senseVoice.id);
      });

      test('writing the new key leaves the legacy one alone and takes effect',
          () async {
        await boot(<String, Object>{'whisper_model_size': 'base'});

        SettingsService.offlineSttModelId = ModelCatalog.senseVoice.id;

        expect(SettingsService.offlineSttModelId, ModelCatalog.senseVoice.id);
        final prefs = await SharedPreferences.getInstance();
        // Never written again, and never cleaned up either: a user who
        // downgrades keeps the size their old build understands.
        expect(prefs.getString('whisper_model_size'), 'base');
      });
    });
  });

  group('SettingsService.llmBaseUrl', () {
    test('defaults to the OpenAI base URL', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());

      expect(SettingsService.llmBaseUrl, 'https://api.openai.com/v1');
    });

    test('normalizes on write: trailing slashes are stripped', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());

      SettingsService.llmBaseUrl = 'http://localhost:11434/v1///';

      expect(SettingsService.llmBaseUrl, 'http://localhost:11434/v1');
    });

    test('normalizes a stored raw value on read', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'llm_base_url': '  https://openrouter.ai/api/v1/  ',
      });
      await SettingsService.init(secretStore: InMemorySecretStore());

      expect(SettingsService.llmBaseUrl, 'https://openrouter.ai/api/v1');
    });
  });

  group('SettingsService.llmCustomModels', () {
    test('defaults to empty', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());

      expect(SettingsService.llmCustomModels, isEmpty);
    });

    test('round-trips a list of model ids', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());

      SettingsService.llmCustomModels = ['my-model', 'another-model'];

      expect(SettingsService.llmCustomModels, ['my-model', 'another-model']);
    });

    test('malformed JSON reads back as empty', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'llm_custom_models': 'not json',
      });
      await SettingsService.init(secretStore: InMemorySecretStore());

      expect(SettingsService.llmCustomModels, isEmpty);
    });

    test('a JSON value with non-string entries reads back as empty', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'llm_custom_models': '["ok", 42, "also-ok"]',
      });
      await SettingsService.init(secretStore: InMemorySecretStore());

      expect(SettingsService.llmCustomModels, isEmpty);
    });

    test('a JSON object instead of a list reads back as empty', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'llm_custom_models': '{"a": 1}',
      });
      await SettingsService.init(secretStore: InMemorySecretStore());

      expect(SettingsService.llmCustomModels, isEmpty);
    });
  });

  group('SettingsService.llmPricing', () {
    test('defaults to defaultLlmPricing when unset', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());

      expect(SettingsService.llmPricing, SettingsService.defaultLlmPricing);
    });

    test('round-trips an edited table exactly', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());

      final table = {
        'my-model': {'input': 0.12, 'output': 0.34},
        'gpt-4.1-mini': {'input': 0.40, 'output': 1.60},
      };
      SettingsService.llmPricing = table;

      expect(SettingsService.llmPricing, table);
    });

    test('malformed JSON reads back as defaults', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'llm_pricing': 'not json',
      });
      await SettingsService.init(secretStore: InMemorySecretStore());

      expect(SettingsService.llmPricing, SettingsService.defaultLlmPricing);
    });

    test('a malformed shape (missing input/output) reads back as defaults',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'llm_pricing': '{"my-model": {"input": "oops"}}',
      });
      await SettingsService.init(secretStore: InMemorySecretStore());

      expect(SettingsService.llmPricing, SettingsService.defaultLlmPricing);
    });

    test('resetLlmPricing removes the override', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());

      SettingsService.llmPricing = {
        'my-model': {'input': 1.0, 'output': 2.0},
      };
      expect(SettingsService.llmPricing, isNot(SettingsService.defaultLlmPricing));

      SettingsService.resetLlmPricing();

      expect(SettingsService.llmPricing, SettingsService.defaultLlmPricing);
    });
  });

  group('SettingsService.llmCost / totalApiCost', () {
    test('llmCost is null for a model with no known pricing', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());

      SettingsService.openaiModel = 'some-unknown-model';
      SettingsService.openaiInputTokens = 1000;
      SettingsService.openaiOutputTokens = 1000;

      expect(SettingsService.llmCost, isNull);
    });

    test('llmCost computes from the pricing table for a known model', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());

      SettingsService.openaiModel = 'gpt-4.1-mini';
      SettingsService.openaiInputTokens = 1000000;
      SettingsService.openaiOutputTokens = 1000000;

      // defaultLlmPricing['gpt-4.1-mini'] = {'input': 0.40, 'output': 1.60}
      expect(SettingsService.llmCost, closeTo(0.40 + 1.60, 1e-9));
    });

    test('totalApiCost is null when llmCost is null', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());

      SettingsService.openaiModel = 'some-unknown-model';
      SettingsService.deepgramMinutesUsed = 5.0;

      expect(SettingsService.totalApiCost, isNull);
    });

    test('totalApiCost sums deepgramCost and llmCost when both are known',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());

      SettingsService.deepgramModel = 'nova-2';
      SettingsService.deepgramMinutesUsed = 10.0;
      SettingsService.openaiModel = 'gpt-4.1-mini';
      SettingsService.openaiInputTokens = 1000000;
      SettingsService.openaiOutputTokens = 1000000;

      final expected = 10.0 * 0.0059 + (0.40 + 1.60);
      expect(SettingsService.totalApiCost, closeTo(expected, 1e-9));
    });
  });

  group('SettingsService.exactTaskReminders', () {
    test('defaults to off so reminders stay inexact (LO-50)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());

      expect(SettingsService.exactTaskReminders, isFalse);
    });

    test('round-trips through SharedPreferences', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());

      SettingsService.exactTaskReminders = true;
      expect(SettingsService.exactTaskReminders, isTrue);

      SettingsService.exactTaskReminders = false;
      expect(SettingsService.exactTaskReminders, isFalse);
    });

    test('reads a value stored by a previous launch', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'exact_task_reminders': true,
      });
      await SettingsService.init(secretStore: InMemorySecretStore());

      expect(SettingsService.exactTaskReminders, isTrue);
    });
  });
}
