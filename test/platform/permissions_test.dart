import 'package:flutter_test/flutter_test.dart';

import 'package:libreomi/platform/permissions.dart';

/// Records the exact permission list passed to each [request] call and
/// returns a scripted outcome map, so tests can assert both "what was asked
/// for" and "what came back" without touching any plugin channel.
class FakePermissionGateway implements PermissionGateway {
  FakePermissionGateway({this.sdkInt, this.scriptedOutcomes = const {}});

  final int? sdkInt;
  final Map<AppPermission, PermissionOutcome> scriptedOutcomes;

  final List<List<AppPermission>> requestedBatches = <List<AppPermission>>[];
  bool settingsOpened = false;

  @override
  Future<int?> androidSdkInt() async => sdkInt;

  @override
  Future<Map<AppPermission, PermissionOutcome>> request(
    List<AppPermission> permissions,
  ) async {
    requestedBatches.add(permissions);
    return <AppPermission, PermissionOutcome>{
      for (final p in permissions)
        p: scriptedOutcomes[p] ?? PermissionOutcome.granted,
    };
  }

  @override
  Future<bool> openSettings() async {
    settingsOpened = true;
    return true;
  }
}

void main() {
  group('AppPermissions.ensureBleScan', () {
    test('sdk 30 requests exactly [fineLocation]', () async {
      final gateway = FakePermissionGateway(sdkInt: 30);
      final permissions = AppPermissions(gateway);

      final outcome = await permissions.ensureBleScan();

      expect(gateway.requestedBatches, [
        [AppPermission.fineLocation],
      ]);
      expect(outcome, PermissionOutcome.granted);
    });

    test('sdk 31 requests exactly [bluetoothScan, bluetoothConnect]',
        () async {
      final gateway = FakePermissionGateway(sdkInt: 31);
      final permissions = AppPermissions(gateway);

      await permissions.ensureBleScan();

      expect(gateway.requestedBatches, [
        [AppPermission.bluetoothScan, AppPermission.bluetoothConnect],
      ]);
    });

    test('sdk 33 requests exactly [bluetoothScan, bluetoothConnect]',
        () async {
      final gateway = FakePermissionGateway(sdkInt: 33);
      final permissions = AppPermissions(gateway);

      await permissions.ensureBleScan();

      expect(gateway.requestedBatches, [
        [AppPermission.bluetoothScan, AppPermission.bluetoothConnect],
      ]);
    });
  });

  group('AppPermissions.ensureNotifications', () {
    test('sdk 30 requests nothing and returns granted', () async {
      final gateway = FakePermissionGateway(sdkInt: 30);
      final permissions = AppPermissions(gateway);

      final outcome = await permissions.ensureNotifications();

      expect(gateway.requestedBatches, isEmpty);
      expect(outcome, PermissionOutcome.granted);
    });

    test('sdk 32 requests nothing and returns granted', () async {
      final gateway = FakePermissionGateway(sdkInt: 32);
      final permissions = AppPermissions(gateway);

      final outcome = await permissions.ensureNotifications();

      expect(gateway.requestedBatches, isEmpty);
      expect(outcome, PermissionOutcome.granted);
    });

    test('sdk 33 requests exactly [notification]', () async {
      final gateway = FakePermissionGateway(sdkInt: 33);
      final permissions = AppPermissions(gateway);

      await permissions.ensureNotifications();

      expect(gateway.requestedBatches, [
        [AppPermission.notification],
      ]);
    });
  });

  group('AppPermissions.ensureMicrophone', () {
    test('requests exactly [microphone] on Android', () async {
      final gateway = FakePermissionGateway(sdkInt: 33);
      final permissions = AppPermissions(gateway);

      await permissions.ensureMicrophone();

      expect(gateway.requestedBatches, [
        [AppPermission.microphone],
      ]);
    });
  });

  group('AppPermissions on non-Android', () {
    test('all three methods request nothing and return granted', () async {
      final gateway = FakePermissionGateway(sdkInt: null);
      final permissions = AppPermissions(gateway);

      expect(await permissions.ensureNotifications(), PermissionOutcome.granted);
      expect(await permissions.ensureBleScan(), PermissionOutcome.granted);
      expect(await permissions.ensureMicrophone(), PermissionOutcome.granted);
      expect(gateway.requestedBatches, isEmpty);
    });
  });

  group('AppPermissions aggregation', () {
    test('scan granted + connect denied aggregates to denied', () async {
      final gateway = FakePermissionGateway(
        sdkInt: 31,
        scriptedOutcomes: {
          AppPermission.bluetoothScan: PermissionOutcome.granted,
          AppPermission.bluetoothConnect: PermissionOutcome.denied,
        },
      );
      final permissions = AppPermissions(gateway);

      final outcome = await permissions.ensureBleScan();

      expect(outcome, PermissionOutcome.denied);
    });

    test('scan granted + connect permanentlyDenied aggregates to '
        'permanentlyDenied', () async {
      final gateway = FakePermissionGateway(
        sdkInt: 31,
        scriptedOutcomes: {
          AppPermission.bluetoothScan: PermissionOutcome.granted,
          AppPermission.bluetoothConnect: PermissionOutcome.permanentlyDenied,
        },
      );
      final permissions = AppPermissions(gateway);

      final outcome = await permissions.ensureBleScan();

      expect(outcome, PermissionOutcome.permanentlyDenied);
    });

    test('both granted aggregates to granted', () async {
      final gateway = FakePermissionGateway(
        sdkInt: 31,
        scriptedOutcomes: {
          AppPermission.bluetoothScan: PermissionOutcome.granted,
          AppPermission.bluetoothConnect: PermissionOutcome.granted,
        },
      );
      final permissions = AppPermissions(gateway);

      final outcome = await permissions.ensureBleScan();

      expect(outcome, PermissionOutcome.granted);
    });
  });

  group('AppPermissions.openAppSettings', () {
    test('forwards to the gateway', () async {
      final gateway = FakePermissionGateway(sdkInt: 33);
      final permissions = AppPermissions(gateway);

      final opened = await permissions.openAppSettings();

      expect(opened, isTrue);
      expect(gateway.settingsOpened, isTrue);
    });
  });
}
