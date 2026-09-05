import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:libreomi/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsService.deepgramModel', () {
    test('defaults to nova-2', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init();

      expect(SettingsService.deepgramModel, 'nova-2');
    });

    test('setting to nova-3 persists and reads back', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init();

      SettingsService.deepgramModel = 'nova-3';

      expect(SettingsService.deepgramModel, 'nova-3');
    });

    test('falls back to nova-2 for a garbage stored value', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'deepgram_model': 'bogus',
      });
      await SettingsService.init();

      expect(SettingsService.deepgramModel, 'nova-2');
    });
  });

  group('SettingsService.batteryOptimizationPromptShown', () {
    test('defaults to false on a fresh install', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init();

      expect(SettingsService.batteryOptimizationPromptShown, isFalse);
    });

    test('setting it to true persists and reads back', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init();

      SettingsService.batteryOptimizationPromptShown = true;

      expect(SettingsService.batteryOptimizationPromptShown, isTrue);
    });

    test('reads a value stored by an earlier run', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'battery_optimization_prompt_shown': true,
      });
      await SettingsService.init();

      expect(SettingsService.batteryOptimizationPromptShown, isTrue);
    });
  });

  group('SettingsService.deepgramCost', () {
    test('equals minutes used times price per minute for nova-2', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init();

      SettingsService.deepgramModel = 'nova-2';
      SettingsService.deepgramMinutesUsed = 10.0;

      expect(SettingsService.deepgramCost, closeTo(10.0 * 0.0059, 1e-9));
    });

    test('equals minutes used times price per minute for nova-3', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init();

      SettingsService.deepgramModel = 'nova-3';
      SettingsService.deepgramMinutesUsed = 7.5;

      expect(SettingsService.deepgramCost, closeTo(7.5 * 0.0059, 1e-9));
    });
  });
}
