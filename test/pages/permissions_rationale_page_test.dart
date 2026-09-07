import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:libreomi/pages/permissions_rationale_page.dart';
import 'package:libreomi/platform/battery_optimization.dart';
import 'package:libreomi/platform/permissions.dart';
import 'package:libreomi/services/secret_store.dart';
import 'package:libreomi/services/settings_service.dart';

/// Scripts the runtime-permission answers this page reads. Records every
/// `request()` call so tests can assert the page never requests anything,
/// and every `openSettings()` call so the Open settings button can be
/// verified.
class _FakePermissionGateway implements PermissionGateway {
  _FakePermissionGateway({
    this.sdkInt,
    Map<AppPermission, PermissionOutcome>? statuses,
    this.failing = false,
  }) : scriptedStatuses = statuses ?? <AppPermission, PermissionOutcome>{};

  final int? sdkInt;
  final Map<AppPermission, PermissionOutcome> scriptedStatuses;
  final bool failing;

  final List<List<AppPermission>> requestCalls = <List<AppPermission>>[];
  int openSettingsCalls = 0;

  @override
  Future<int?> androidSdkInt() async {
    if (failing) {
      throw StateError('device_info_plus unavailable');
    }
    return sdkInt;
  }

  @override
  Future<Map<AppPermission, PermissionOutcome>> request(
    List<AppPermission> permissions,
  ) async {
    requestCalls.add(permissions);
    return <AppPermission, PermissionOutcome>{
      for (final p in permissions) p: scriptedStatuses[p] ?? PermissionOutcome.denied,
    };
  }

  @override
  Future<Map<AppPermission, PermissionOutcome>> statuses(
    List<AppPermission> permissions,
  ) async {
    if (failing) {
      throw StateError('permission_handler unavailable');
    }
    return <AppPermission, PermissionOutcome>{
      for (final p in permissions)
        if (scriptedStatuses.containsKey(p)) p: scriptedStatuses[p]!,
    };
  }

  @override
  Future<bool> openSettings() async {
    openSettingsCalls++;
    return true;
  }
}

/// Scripts battery-optimisation status for the last row.
class _FakeBatteryOptimizationGateway implements BatteryOptimizationGateway {
  _FakeBatteryOptimizationGateway({this.ignoring, this.failing = false});

  final bool? ignoring;
  final bool failing;

  @override
  Future<bool?> isIgnoring() async {
    if (failing) {
      throw StateError('permission_handler unavailable');
    }
    return ignoring;
  }

  @override
  Future<bool?> requestIgnore() async => ignoring;

  @override
  Future<String?> manufacturer() async => null;
}

void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    required _FakePermissionGateway permissionGateway,
    bool? batteryIgnoring,
    bool batteryFailing = false,
    bool isFirstRun = false,
    VoidCallback? onContinue,
  }) async {
    // The rationale list is longer than the default 800x600 test surface's
    // cache extent (five permission cards plus four prose sections), and
    // `ListView`'s sliver only builds elements within the viewport plus a
    // small cache — anything further down is never mounted at all. A taller
    // surface keeps every row reachable without a scroll in every test
    // below (same fix as `settings_page_test.dart`).
    tester.view.physicalSize = const Size(1080, 3400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: PermissionsRationalePage(
          // A fresh key per pump forces a new State (and thus a fresh
          // `initState` load) even when a test pumps the page more than
          // once with different scripted gateways — Flutter would otherwise
          // reuse the existing State and never re-run the load.
          key: UniqueKey(),
          isFirstRun: isFirstRun,
          permissionsOverride: AppPermissions(permissionGateway),
          batteryOptimizationOverride: BatteryOptimization(
            _FakeBatteryOptimizationGateway(
              ignoring: batteryIgnoring,
              failing: batteryFailing,
            ),
          ),
          onContinue: onContinue,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Continue still hands over when the settings store is broken', (
    tester,
  ) async {
    // `main.dart` shows this screen precisely when the settings store could
    // not be initialised, and the flag setter throws in that state. The user
    // must still get past the screen.
    //
    // Declared first on purpose: `SettingsService` keeps its `SharedPreferences`
    // in a static that nothing resets, so this is the only point in the file
    // where the store is genuinely uninitialised. Keep it above the tests that
    // call `SettingsService.init`; the assertion below fails loudly rather
    // than passing vacuously if that order ever changes.
    expect(() => SettingsService.rationaleShown, throwsA(isA<Exception>()));

    var continueCalls = 0;
    final gateway = _FakePermissionGateway(
      sdkInt: 33,
      statuses: <AppPermission, PermissionOutcome>{
        AppPermission.bluetoothScan: PermissionOutcome.granted,
        AppPermission.bluetoothConnect: PermissionOutcome.granted,
        AppPermission.microphone: PermissionOutcome.granted,
        AppPermission.notification: PermissionOutcome.granted,
      },
    );

    await pumpPage(
      tester,
      permissionGateway: gateway,
      batteryIgnoring: true,
      isFirstRun: true,
      onContinue: () => continueCalls++,
    );

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(continueCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders granted vs not-granted rows from scripted statuses', (
    tester,
  ) async {
    final gateway = _FakePermissionGateway(
      sdkInt: 33,
      statuses: <AppPermission, PermissionOutcome>{
        AppPermission.bluetoothScan: PermissionOutcome.granted,
        AppPermission.bluetoothConnect: PermissionOutcome.granted,
        AppPermission.microphone: PermissionOutcome.denied,
        AppPermission.notification: PermissionOutcome.granted,
      },
    );

    await pumpPage(tester, permissionGateway: gateway, batteryIgnoring: true);

    expect(find.text('Granted'), findsNWidgets(3)); // Bluetooth, notif, battery
    expect(find.text('Not granted'), findsOneWidget); // Microphone
  });

  testWidgets(
    'permanentlyDenied renders Denied — open settings and tapping opens settings',
    (tester) async {
      final gateway = _FakePermissionGateway(
        sdkInt: 33,
        statuses: <AppPermission, PermissionOutcome>{
          AppPermission.bluetoothScan: PermissionOutcome.permanentlyDenied,
          AppPermission.bluetoothConnect: PermissionOutcome.granted,
          AppPermission.microphone: PermissionOutcome.granted,
          AppPermission.notification: PermissionOutcome.granted,
        },
      );

      await pumpPage(
        tester,
        permissionGateway: gateway,
        batteryIgnoring: true,
      );

      expect(find.text('Denied — open settings'), findsOneWidget);

      // The Bluetooth card is the first one; find its Open settings button.
      final bluetoothCard = find.ancestor(
        of: find.text('Bluetooth'),
        matching: find.byType(Card),
      );
      final openSettingsButton = find.descendant(
        of: bluetoothCard,
        matching: find.text('Open settings'),
      );
      expect(openSettingsButton, findsOneWidget);

      await tester.tap(openSettingsButton);
      await tester.pumpAndSettle();

      expect(gateway.openSettingsCalls, 1);
    },
  );

  testWidgets('the page requests nothing', (tester) async {
    final gateway = _FakePermissionGateway(
      sdkInt: 33,
      statuses: <AppPermission, PermissionOutcome>{
        AppPermission.bluetoothScan: PermissionOutcome.granted,
        AppPermission.bluetoothConnect: PermissionOutcome.granted,
        AppPermission.microphone: PermissionOutcome.granted,
        AppPermission.notification: PermissionOutcome.granted,
      },
    );

    await pumpPage(tester, permissionGateway: gateway, batteryIgnoring: true);

    expect(gateway.requestCalls, isEmpty);
  });

  testWidgets(
    'API 30 shows the location-based Bluetooth row, not the API 31 row',
    (tester) async {
      final gateway = _FakePermissionGateway(
        sdkInt: 30,
        statuses: <AppPermission, PermissionOutcome>{
          AppPermission.fineLocation: PermissionOutcome.granted,
          AppPermission.microphone: PermissionOutcome.granted,
        },
      );

      await pumpPage(
        tester,
        permissionGateway: gateway,
        batteryIgnoring: true,
      );

      expect(find.text('Bluetooth (location permission)'), findsOneWidget);
      expect(find.text('Bluetooth'), findsNothing);
      expect(
        find.textContaining(
          'Android 11 and older require the location permission',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('notifications on API 30 show Not required on this Android version', (
    tester,
  ) async {
    final gateway = _FakePermissionGateway(
      sdkInt: 30,
      statuses: <AppPermission, PermissionOutcome>{
        AppPermission.fineLocation: PermissionOutcome.granted,
        AppPermission.microphone: PermissionOutcome.granted,
      },
    );

    await pumpPage(tester, permissionGateway: gateway, batteryIgnoring: true);

    expect(find.text('Not required on this Android version'), findsOneWidget);
  });

  testWidgets('battery optimisation chip reflects isIgnoring true/false/null', (
    tester,
  ) async {
    final gateway = _FakePermissionGateway(
      sdkInt: 33,
      statuses: <AppPermission, PermissionOutcome>{
        AppPermission.bluetoothScan: PermissionOutcome.granted,
        AppPermission.bluetoothConnect: PermissionOutcome.granted,
        AppPermission.microphone: PermissionOutcome.granted,
        AppPermission.notification: PermissionOutcome.granted,
      },
    );

    await pumpPage(tester, permissionGateway: gateway, batteryIgnoring: true);
    expect(find.text('Granted'), findsNWidgets(4));

    await pumpPage(
      tester,
      permissionGateway: _FakePermissionGateway(
        sdkInt: 33,
        statuses: <AppPermission, PermissionOutcome>{
          AppPermission.bluetoothScan: PermissionOutcome.granted,
          AppPermission.bluetoothConnect: PermissionOutcome.granted,
          AppPermission.microphone: PermissionOutcome.granted,
          AppPermission.notification: PermissionOutcome.granted,
        },
      ),
      batteryIgnoring: false,
    );
    expect(find.text('Not granted'), findsOneWidget);

    await pumpPage(
      tester,
      permissionGateway: _FakePermissionGateway(
        sdkInt: 33,
        statuses: <AppPermission, PermissionOutcome>{
          AppPermission.bluetoothScan: PermissionOutcome.granted,
          AppPermission.bluetoothConnect: PermissionOutcome.granted,
          AppPermission.microphone: PermissionOutcome.granted,
          AppPermission.notification: PermissionOutcome.granted,
        },
      ),
      batteryIgnoring: null,
    );
    expect(find.text('Not applicable'), findsOneWidget);
  });

  testWidgets('a throwing gateway leaves no spinner and renders Unknown', (
    tester,
  ) async {
    final gateway = _FakePermissionGateway(failing: true);

    await pumpPage(tester, permissionGateway: gateway, batteryFailing: true);

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Unknown'), findsWidgets);
  });

  testWidgets(
    'isFirstRun: true shows Continue, tapping it sets rationaleShown and calls onContinue once',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init(secretStore: InMemorySecretStore());

      var continueCalls = 0;
      final gateway = _FakePermissionGateway(
        sdkInt: 33,
        statuses: <AppPermission, PermissionOutcome>{
          AppPermission.bluetoothScan: PermissionOutcome.granted,
          AppPermission.bluetoothConnect: PermissionOutcome.granted,
          AppPermission.microphone: PermissionOutcome.granted,
          AppPermission.notification: PermissionOutcome.granted,
        },
      );

      await pumpPage(
        tester,
        permissionGateway: gateway,
        batteryIgnoring: true,
        isFirstRun: true,
        onContinue: () => continueCalls++,
      );

      expect(find.text('Continue'), findsOneWidget);
      expect(SettingsService.rationaleShown, isFalse);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(SettingsService.rationaleShown, isTrue);
      expect(continueCalls, 1);
    },
  );

  testWidgets('renders the four disclosure sections and the closing note', (
    tester,
  ) async {
    final gateway = _FakePermissionGateway(
      sdkInt: 33,
      statuses: <AppPermission, PermissionOutcome>{
        AppPermission.bluetoothScan: PermissionOutcome.granted,
        AppPermission.bluetoothConnect: PermissionOutcome.granted,
        AppPermission.microphone: PermissionOutcome.granted,
        AppPermission.notification: PermissionOutcome.granted,
      },
    );

    await pumpPage(tester, permissionGateway: gateway, batteryIgnoring: true);

    // The prose, not the status chips, is what Play's prominent disclosure
    // is judged on, so it is pinned here: a page that kept only the
    // permission cards would otherwise still pass this suite.
    expect(find.text('WHAT LIBREOMI COLLECTS'), findsOneWidget);
    expect(find.text('WHERE IT GOES'), findsOneWidget);
    expect(find.text('WHERE IT IS STORED'), findsOneWidget);
    expect(find.text('YOUR CONTROL'), findsOneWidget);
    expect(find.text('PERMISSIONS'), findsOneWidget);
    expect(
      find.textContaining('never asks for a permission'),
      findsOneWidget,
    );
    // The two claims most easily broken by an edit: what leaves the phone,
    // and that auto-backup carries the database.
    expect(
      find.textContaining('no capture is sent to any service'),
      findsOneWidget,
    );
    expect(
      find.textContaining('included in your Google account backup'),
      findsOneWidget,
    );
  });

  testWidgets('the first-run screen has no back arrow, the re-entry one does', (
    tester,
  ) async {
    _FakePermissionGateway granted() => _FakePermissionGateway(
      sdkInt: 33,
      statuses: <AppPermission, PermissionOutcome>{
        AppPermission.bluetoothScan: PermissionOutcome.granted,
        AppPermission.bluetoothConnect: PermissionOutcome.granted,
        AppPermission.microphone: PermissionOutcome.granted,
        AppPermission.notification: PermissionOutcome.granted,
      },
    );

    await pumpPage(
      tester,
      permissionGateway: granted(),
      batteryIgnoring: true,
      isFirstRun: true,
    );
    expect(find.byType(BackButton), findsNothing);

    // Pushed on top of another route, the re-entry form keeps the arrow.
    await tester.pumpWidget(
      MaterialApp(
        home: const Scaffold(body: SizedBox.shrink()),
        routes: <String, WidgetBuilder>{},
      ),
    );
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => PermissionsRationalePage(
          permissionsOverride: AppPermissions(granted()),
          batteryOptimizationOverride: BatteryOptimization(
            _FakeBatteryOptimizationGateway(ignoring: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(BackButton), findsOneWidget);
  });

  testWidgets('isFirstRun: false shows no Continue button', (tester) async {
    final gateway = _FakePermissionGateway(
      sdkInt: 33,
      statuses: <AppPermission, PermissionOutcome>{
        AppPermission.bluetoothScan: PermissionOutcome.granted,
        AppPermission.bluetoothConnect: PermissionOutcome.granted,
        AppPermission.microphone: PermissionOutcome.granted,
        AppPermission.notification: PermissionOutcome.granted,
      },
    );

    await pumpPage(
      tester,
      permissionGateway: gateway,
      batteryIgnoring: true,
      isFirstRun: false,
    );

    expect(find.text('Continue'), findsNothing);
  });
}
