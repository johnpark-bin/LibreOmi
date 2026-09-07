import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:libreomi/pages/settings_page.dart';
import 'package:libreomi/platform/battery_optimization.dart';
import 'package:libreomi/platform/exact_alarm.dart';
import 'package:libreomi/services/secret_store.dart';
import 'package:libreomi/services/settings_service.dart';
import 'package:libreomi/transcription/model_catalog.dart';

import 'controller_harness.dart';

/// Scripts the platform answers for [BatteryOptimization] so tests never
/// touch a plugin channel. Shape mirrors
/// `test/platform/battery_optimization_test.dart`'s
/// `FakeBatteryOptimizationGateway`, kept local so the two test files stay
/// independent.
class _FakeBatteryOptimizationGateway implements BatteryOptimizationGateway {
  _FakeBatteryOptimizationGateway({
    this.ignoring,
    this.requestResult,
    this.failing = false,
  });

  bool? ignoring;
  final bool? requestResult;

  /// Makes both platform calls throw, standing in for a plugin channel that
  /// is unavailable.
  final bool failing;

  int requestCalls = 0;

  @override
  Future<bool?> isIgnoring() async {
    if (failing) {
      throw StateError('permission_handler unavailable');
    }
    return ignoring;
  }

  @override
  Future<bool?> requestIgnore() async {
    requestCalls++;
    if (failing) {
      throw StateError('permission_handler unavailable');
    }
    if (requestResult != null) {
      ignoring = requestResult;
    }
    return requestResult;
  }

  @override
  Future<String?> manufacturer() async => null;
}

/// Scripts the platform answers for [ExactAlarm], mirroring
/// [_FakeBatteryOptimizationGateway] so tests never touch a plugin channel.
class _FakeExactAlarmGateway implements ExactAlarmGateway {
  _FakeExactAlarmGateway({
    this.currentStatus = ExactAlarmStatus.denied,
    this.afterOpenSettings,
    this.failing = false,
  });

  ExactAlarmStatus currentStatus;
  final ExactAlarmStatus? afterOpenSettings;

  /// Makes both platform calls throw, standing in for a plugin channel that
  /// is unavailable.
  final bool failing;

  int openSettingsCalls = 0;

  @override
  Future<ExactAlarmStatus> status() async {
    if (failing) {
      throw StateError('permission_handler unavailable');
    }
    return currentStatus;
  }

  @override
  Future<ExactAlarmStatus> openSettings() async {
    openSettingsCalls++;
    if (failing) {
      throw StateError('permission_handler unavailable');
    }
    if (afterOpenSettings != null) {
      currentStatus = afterOpenSettings!;
    }
    return currentStatus;
  }
}

void main() {
  /// Boots SettingsService against an in-memory store and pumps the page.
  /// Every test states the stored settings it wants, so there is no hidden
  /// two-phase setup to unpick.
  Future<void> pumpSettingsPage(
    WidgetTester tester, {
    String? storedModel,
    String transcriptionMode = 'cloud',
    BatteryOptimization? batteryOptimizationOverride,
    ExactAlarm? exactAlarmOverride,
    bool? storedExactTaskReminders,
  }) async {
    // LO-40 added a "Manage models" row (and, conditionally, a hint line) to
    // the Transcription Engine card, which pushed the Deepgram/OpenAI
    // dropdowns just past the default 800x600 test surface's cache extent —
    // `ListView` only inflates elements within the viewport plus a small
    // cache, so anything further down is never built at all. A taller
    // surface keeps every section reachable without a scroll in every test
    // below, existing ones included.
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues(<String, Object>{
      'transcription_mode': transcriptionMode,
      if (storedModel != null) 'deepgram_model': storedModel,
      if (storedExactTaskReminders != null)
        'exact_task_reminders': storedExactTaskReminders,
    });
    await SettingsService.init(secretStore: InMemorySecretStore());

    final controllers = await PageControllers.create();
    await tester.pumpWidget(
      controllers.wrap(
        MaterialApp(
          home: SettingsPage(
            batteryOptimizationOverride: batteryOptimizationOverride,
            exactAlarmOverride: exactAlarmOverride,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the Deepgram model dropdown defaulting to Nova-2', (
    WidgetTester tester,
  ) async {
    await pumpSettingsPage(tester);

    expect(
      find.widgetWithText(DropdownButtonFormField<String>, 'Nova-2'),
      findsOneWidget,
    );
  });

  testWidgets('renders the stored model as the selected value', (
    WidgetTester tester,
  ) async {
    await pumpSettingsPage(tester, storedModel: 'nova-3');

    expect(
      find.widgetWithText(DropdownButtonFormField<String>, 'Nova-3'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(DropdownButtonFormField<String>, 'Nova-2'),
      findsNothing,
    );
  });

  testWidgets('shows the Manage models tile in the Transcription Engine section', (
    WidgetTester tester,
  ) async {
    await pumpSettingsPage(tester);

    final headerFinder = find.text('Transcription Engine'.toUpperCase());
    await tester.scrollUntilVisible(
      headerFinder,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(headerFinder, findsOneWidget);
    expect(find.text('Manage models'), findsOneWidget);
  });

  testWidgets('selecting Nova-3 updates SettingsService.deepgramModel', (
    WidgetTester tester,
  ) async {
    await pumpSettingsPage(tester);

    final dropdownFinder = find.widgetWithText(
      DropdownButtonFormField<String>,
      'Nova-2',
    );
    expect(dropdownFinder, findsOneWidget);

    await tester.ensureVisible(dropdownFinder);
    await tester.pumpAndSettle();

    await tester.tap(dropdownFinder);
    await tester.pumpAndSettle();

    // Multiple 'Nova-3' texts can appear (menu item); tap the last one shown.
    await tester.tap(find.text('Nova-3').last);
    await tester.pumpAndSettle();

    expect(SettingsService.deepgramModel, 'nova-3');
  });

  group('Local STT language picker (LO-44)', () {
    testWidgets('shows English and 한국어 segments for sherpa mode, defaulting to English', (
      WidgetTester tester,
    ) async {
      await pumpSettingsPage(tester, transcriptionMode: 'sherpa');

      final englishFinder = find.text('English');
      await tester.scrollUntilVisible(
        englishFinder,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(englishFinder, findsOneWidget);
      expect(find.text('한국어'), findsOneWidget);

      final segmentedButton = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(segmentedButton.selected, {'en'});
    });

    testWidgets('tapping 한국어 sets SettingsService.localSttLanguage to ko', (
      WidgetTester tester,
    ) async {
      await pumpSettingsPage(tester, transcriptionMode: 'sherpa');

      final koreanFinder = find.text('한국어');
      await tester.scrollUntilVisible(
        koreanFinder,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      await tester.tap(koreanFinder);
      await tester.pumpAndSettle();

      expect(SettingsService.localSttLanguage, 'ko');
      final segmentedButton = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(segmentedButton.selected, {'ko'});
    });

    testWidgets('hides the language picker in cloud mode', (
      WidgetTester tester,
    ) async {
      await pumpSettingsPage(tester, transcriptionMode: 'cloud');

      expect(find.text('Language:'), findsNothing);
      expect(find.text('한국어'), findsNothing);
    });

    testWidgets('shows both the language picker and the offline model picker '
        'in whisper mode', (
      WidgetTester tester,
    ) async {
      await pumpSettingsPage(tester, transcriptionMode: 'whisper');

      final modelFinder =
          find.textContaining(ModelCatalog.whisperTiny.displayName);
      await tester.scrollUntilVisible(
        modelFinder,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(modelFinder, findsOneWidget);
      expect(find.text('Language:'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('한국어'), findsOneWidget);
    });

    testWidgets(
        'the offline model picker offers every catalog offline model and '
        'stores the pick (LO-71)', (WidgetTester tester) async {
      await pumpSettingsPage(tester, transcriptionMode: 'whisper');
      expect(SettingsService.offlineSttModelId, ModelCatalog.whisperTiny.id);

      final selected =
          find.textContaining(ModelCatalog.whisperTiny.displayName);
      await tester.scrollUntilVisible(
        selected,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      await tester.tap(selected.first);
      await tester.pumpAndSettle();

      // The open menu lists the catalog's offline models and nothing else —
      // the streaming models are not decodable by this path.
      for (final spec in ModelCatalog.offlineModels) {
        expect(find.textContaining(spec.displayName), findsWidgets,
            reason: spec.id);
      }
      expect(
          find.textContaining(ModelCatalog.streamingZipformerKo.displayName),
          findsNothing);

      await tester
          .tap(find.textContaining(ModelCatalog.senseVoice.displayName).last);
      await tester.pumpAndSettle();

      expect(SettingsService.offlineSttModelId, ModelCatalog.senseVoice.id);
    });
  });

  group('Background reliability section', () {
    testWidgets('shows exempt status when already ignoring optimisation', (
      WidgetTester tester,
    ) async {
      final battery = BatteryOptimization(
        _FakeBatteryOptimizationGateway(ignoring: true),
      );
      await pumpSettingsPage(tester, batteryOptimizationOverride: battery);

      final headerFinder = find.text('Background reliability'.toUpperCase());
      await tester.scrollUntilVisible(
        headerFinder,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(headerFinder, findsOneWidget);
      expect(find.text('Exempt from battery optimisation'), findsOneWidget);
      expect(find.text('Request exemption'), findsNothing);
    });

    testWidgets(
      'shows optimisation-active status and the request row when not exempt',
      (WidgetTester tester) async {
        final battery = BatteryOptimization(
          _FakeBatteryOptimizationGateway(ignoring: false),
        );
        await pumpSettingsPage(tester, batteryOptimizationOverride: battery);

        final statusFinder = find.text('Battery optimisation is active');
        await tester.scrollUntilVisible(
          statusFinder,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();

        expect(statusFinder, findsOneWidget);
        expect(find.text('Request exemption'), findsOneWidget);
      },
    );

    testWidgets(
      'hides the request row off Android, where there is nothing to request',
      (WidgetTester tester) async {
        final battery = BatteryOptimization(
          _FakeBatteryOptimizationGateway(ignoring: null),
        );
        await pumpSettingsPage(tester, batteryOptimizationOverride: battery);

        final statusFinder = find.text('Not applicable on this platform');
        await tester.scrollUntilVisible(
          statusFinder,
          300,
          scrollable: find.byType(Scrollable).first,
        );

        expect(statusFinder, findsOneWidget);
        expect(find.text('Request exemption'), findsNothing);
      },
    );

    testWidgets(
      'a failed status check says so and still offers a retry',
      (WidgetTester tester) async {
        final battery = BatteryOptimization(
          _FakeBatteryOptimizationGateway(failing: true),
        );
        await pumpSettingsPage(tester, batteryOptimizationOverride: battery);

        final statusFinder = find.text('Could not check battery optimisation');
        await tester.scrollUntilVisible(
          statusFinder,
          300,
          scrollable: find.byType(Scrollable).first,
        );

        expect(statusFinder, findsOneWidget);
        expect(find.text('Request exemption'), findsOneWidget,
            reason: 'a failed check must leave a way to retry');
      },
    );

    testWidgets(
      'a failed exemption request reports it instead of hanging',
      (WidgetTester tester) async {
        final gateway = _FakeBatteryOptimizationGateway(failing: true);
        await pumpSettingsPage(
          tester,
          batteryOptimizationOverride: BatteryOptimization(gateway),
        );

        final requestTile = find.text('Request exemption');
        await tester.scrollUntilVisible(
          requestTile,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(requestTile);
        await tester.pumpAndSettle();

        expect(gateway.requestCalls, 1);
        expect(
          find.text('Could not open the battery optimisation dialog.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'tapping Request exemption calls the gateway and refreshes to exempt',
      (WidgetTester tester) async {
        final gateway = _FakeBatteryOptimizationGateway(
          ignoring: false,
          requestResult: true,
        );
        final battery = BatteryOptimization(gateway);
        await pumpSettingsPage(tester, batteryOptimizationOverride: battery);

        final requestTile = find.text('Request exemption');
        await tester.scrollUntilVisible(
          requestTile,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(requestTile, findsOneWidget);

        await tester.ensureVisible(requestTile);
        await tester.pumpAndSettle();

        await tester.tap(requestTile);
        await tester.pumpAndSettle();

        expect(gateway.requestCalls, 1);
        expect(find.text('Exempt from battery optimisation'), findsOneWidget);
        expect(find.text('Request exemption'), findsNothing);
      },
    );
  });

  group('Exact task reminders switch', () {
    Future<Finder> findExactAlarmSwitch(WidgetTester tester) async {
      final titleFinder = find.text('Exact task reminders');
      await tester.scrollUntilVisible(
        titleFinder,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      return find.ancestor(
        of: titleFinder,
        matching: find.byType(SwitchListTile),
      );
    }

    testWidgets('is off by default', (WidgetTester tester) async {
      await pumpSettingsPage(
        tester,
        exactAlarmOverride: ExactAlarm(_FakeExactAlarmGateway()),
      );

      final switchFinder = await findExactAlarmSwitch(tester);
      final tile = tester.widget<SwitchListTile>(switchFinder);
      expect(tile.value, isFalse);
    });

    testWidgets(
      'granted permission: tapping on sets the setting with no dialog',
      (WidgetTester tester) async {
        final gateway = _FakeExactAlarmGateway(
          currentStatus: ExactAlarmStatus.granted,
        );
        await pumpSettingsPage(
          tester,
          exactAlarmOverride: ExactAlarm(gateway),
        );

        final switchFinder = await findExactAlarmSwitch(tester);
        await tester.ensureVisible(switchFinder);
        await tester.pumpAndSettle();

        await tester.tap(switchFinder);
        await tester.pumpAndSettle();

        expect(SettingsService.exactTaskReminders, isTrue);
        expect(
          tester.widget<SwitchListTile>(switchFinder).value,
          isTrue,
        );
        expect(find.byType(AlertDialog), findsNothing);
        expect(gateway.openSettingsCalls, 0);
      },
    );

    testWidgets(
      'denied permission: tapping on shows a dialog, granting via settings '
      'turns the setting on',
      (WidgetTester tester) async {
        final gateway = _FakeExactAlarmGateway(
          currentStatus: ExactAlarmStatus.denied,
          afterOpenSettings: ExactAlarmStatus.granted,
        );
        await pumpSettingsPage(
          tester,
          exactAlarmOverride: ExactAlarm(gateway),
        );

        final switchFinder = await findExactAlarmSwitch(tester);
        await tester.ensureVisible(switchFinder);
        await tester.pumpAndSettle();

        await tester.tap(switchFinder);
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('Allow exact alarms'), findsOneWidget);

        await tester.tap(find.text('Open settings'));
        await tester.pumpAndSettle();

        expect(gateway.openSettingsCalls, 1);
        expect(SettingsService.exactTaskReminders, isTrue);
        expect(
          tester.widget<SwitchListTile>(switchFinder).value,
          isTrue,
        );
      },
    );

    testWidgets(
      'denied permission: still denied after settings keeps the setting off',
      (WidgetTester tester) async {
        final gateway = _FakeExactAlarmGateway(
          currentStatus: ExactAlarmStatus.denied,
          afterOpenSettings: ExactAlarmStatus.denied,
        );
        await pumpSettingsPage(
          tester,
          exactAlarmOverride: ExactAlarm(gateway),
        );

        final switchFinder = await findExactAlarmSwitch(tester);
        await tester.ensureVisible(switchFinder);
        await tester.pumpAndSettle();

        await tester.tap(switchFinder);
        await tester.pumpAndSettle();

        await tester.tap(find.text('Open settings'));
        await tester.pumpAndSettle();

        expect(gateway.openSettingsCalls, 1);
        expect(SettingsService.exactTaskReminders, isFalse);
        expect(
          tester.widget<SwitchListTile>(switchFinder).value,
          isFalse,
        );
      },
    );

    testWidgets(
      'a failed status check is treated as denied so the row still works',
      (WidgetTester tester) async {
        final gateway = _FakeExactAlarmGateway(failing: true);
        await pumpSettingsPage(
          tester,
          exactAlarmOverride: ExactAlarm(gateway),
        );

        final switchFinder = await findExactAlarmSwitch(tester);
        expect(
          tester.widget<SwitchListTile>(switchFinder).value,
          isFalse,
        );
        expect(tester.widget<SwitchListTile>(switchFinder).onChanged, isNotNull);
      },
    );

    testWidgets(
      'a stored opt-in with a denied permission renders the switch off',
      (WidgetTester tester) async {
        final gateway = _FakeExactAlarmGateway(
          currentStatus: ExactAlarmStatus.denied,
        );
        await pumpSettingsPage(
          tester,
          exactAlarmOverride: ExactAlarm(gateway),
          storedExactTaskReminders: true,
        );

        final switchFinder = await findExactAlarmSwitch(tester);
        expect(
          tester.widget<SwitchListTile>(switchFinder).value,
          isFalse,
        );
      },
    );
  });

  group('Privacy section', () {
    testWidgets('offers a way back into the permissions & privacy screen', (
      tester,
    ) async {
      await pumpSettingsPage(tester);

      expect(find.text('Permissions & privacy'), findsOneWidget);
    });
  });
}
