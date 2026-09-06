import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:libreomi/pages/settings_page.dart';
import 'package:libreomi/platform/battery_optimization.dart';
import 'package:libreomi/services/secret_store.dart';
import 'package:libreomi/services/settings_service.dart';

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

void main() {
  /// Boots SettingsService against an in-memory store and pumps the page.
  /// Every test states the stored settings it wants, so there is no hidden
  /// two-phase setup to unpick.
  Future<void> pumpSettingsPage(
    WidgetTester tester, {
    String? storedModel,
    BatteryOptimization? batteryOptimizationOverride,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'transcription_mode': 'cloud',
      if (storedModel != null) 'deepgram_model': storedModel,
    });
    await SettingsService.init(secretStore: InMemorySecretStore());

    final controllers = await PageControllers.create();
    await tester.pumpWidget(
      controllers.wrap(
        MaterialApp(
          home: SettingsPage(
            batteryOptimizationOverride: batteryOptimizationOverride,
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
}
