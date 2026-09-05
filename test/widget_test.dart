import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:libreomi/main.dart';
import 'package:libreomi/services/settings_service.dart';

void main() {
  setUp(() async {
    // The home page reads settings while building, so the service has to be
    // initialised the way main() does it, against an in-memory store.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SettingsService.init();
  });

  testWidgets('App builds successfully', (WidgetTester tester) async {
    await tester.pumpWidget(const LibreOmiApp());
    expect(find.text('LibreOmi'), findsOneWidget);
  });
}
