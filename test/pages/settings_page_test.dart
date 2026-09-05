import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:libreomi/pages/settings_page.dart';
import 'package:libreomi/providers/app_provider.dart';
import 'package:libreomi/services/settings_service.dart';

void main() {
  /// Boots SettingsService against an in-memory store and pumps the page.
  /// Every test states the stored settings it wants, so there is no hidden
  /// two-phase setup to unpick.
  Future<void> pumpSettingsPage(
    WidgetTester tester, {
    String? storedModel,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'transcription_mode': 'cloud',
      if (storedModel != null) 'deepgram_model': storedModel,
    });
    await SettingsService.init();

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppProvider(),
        child: const MaterialApp(home: SettingsPage()),
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
}
