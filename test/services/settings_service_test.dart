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
}
