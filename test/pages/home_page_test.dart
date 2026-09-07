/// The LO-34 acceptance test for the live tab: `DeviceTab` reads its state
/// from `DeviceController` and `SessionController` instead of the deleted
/// monolithic provider, and re-renders when the device connects.
///
/// The scan button itself is not tapped here: `_startScan` goes through the
/// top-level `appPermissions` in `lib/platform/permission_gateway.dart`,
/// which is a `final` with no injection seam, so a tap would end in
/// `permission_handler`'s plugin channel. Adding that seam is a change to
/// `platform/` and belongs to its own issue; the wiring this test has to
/// prove -- that the tab reads both controllers -- is covered by the connect
/// path below, which reaches `DeviceController` directly.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:libreomi/device/device_manager.dart';
import 'package:libreomi/pages/home_page.dart';
import 'package:libreomi/services/secret_store.dart';
import 'package:libreomi/services/settings_service.dart';

import 'controller_harness.dart';

import '../support/localized_app.dart';

void main() {
  setUp(() async {
    // The tab reads settings while building, so the service has to be
    // initialised the way main() does it, against an in-memory store.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SettingsService.init(secretStore: InMemorySecretStore());
  });

  Future<PageControllers> pumpDeviceTab(WidgetTester tester) async {
    final controllers = await PageControllers.create();
    // The tab reads `deviceState`, which only moves once the connection-state
    // listener is attached -- the same call `main.dart`'s bootstrap makes.
    await controllers.device.init();
    await tester.pumpWidget(
      controllers.wrap(const LocalizedApp(home: Scaffold(body: DeviceTab()))),
    );
    return controllers;
  }

  testWidgets('renders the disconnected view from DeviceController', (
    WidgetTester tester,
  ) async {
    await pumpDeviceTab(tester);

    expect(find.text('Start Capturing'), findsOneWidget);
    expect(find.text('Connected'), findsNothing);
  });

  testWidgets('switches to the connected view when the device connects', (
    WidgetTester tester,
  ) async {
    final controllers = await pumpDeviceTab(tester);

    await controllers.device.connectToDevice(
      const DiscoveredDevice(id: 'omi-1', name: 'Omi', rssi: -50),
    );
    await tester.pump();

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Omi Device Ready'), findsOneWidget);
    expect(find.text('Start Capturing'), findsNothing);
  });

  testWidgets('reads the listening state from SessionController', (
    WidgetTester tester,
  ) async {
    final controllers = await pumpDeviceTab(tester);

    await controllers.device.connectToDevice(
      const DiscoveredDevice(id: 'omi-1', name: 'Omi', rssi: -50),
    );
    await tester.pump();

    // The label is `session.isListening ? 'Stop Listening' : 'Start Listening'`,
    // so this is the connected view reading the session controller.
    expect(find.text('Start Listening'), findsOneWidget);
    expect(find.text('Stop Listening'), findsNothing);
  });
}
