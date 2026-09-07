import 'package:flutter_test/flutter_test.dart';

import 'package:libreomi/platform/exact_alarm.dart';

/// Scripts the platform answers and records every call, so tests can assert
/// both "what was asked" and "what came back" without a plugin channel.
class FakeExactAlarmGateway implements ExactAlarmGateway {
  FakeExactAlarmGateway({
    this.current = ExactAlarmStatus.denied,
    this.afterSettings,
  });

  ExactAlarmStatus current;

  /// What the system reports once the user comes back from the settings
  /// screen. `null` leaves [current] untouched, standing in for a user who
  /// backed out without changing anything.
  final ExactAlarmStatus? afterSettings;

  int statusCalls = 0;
  int openSettingsCalls = 0;

  @override
  Future<ExactAlarmStatus> status() async {
    statusCalls++;
    return current;
  }

  @override
  Future<ExactAlarmStatus> openSettings() async {
    openSettingsCalls++;
    final after = afterSettings;
    if (after != null) {
      current = after;
    }
    return current;
  }
}

void main() {
  group('usePreciseAlarm', () {
    test('is false whenever the user has not opted in', () {
      for (final status in ExactAlarmStatus.values) {
        expect(
          usePreciseAlarm(optIn: false, status: status),
          isFalse,
          reason: 'opt-out must win over status $status',
        );
      }
    });

    test('is true only when opted in and the permission is granted', () {
      expect(
        usePreciseAlarm(optIn: true, status: ExactAlarmStatus.granted),
        isTrue,
      );
      expect(
        usePreciseAlarm(optIn: true, status: ExactAlarmStatus.denied),
        isFalse,
      );
      expect(
        usePreciseAlarm(optIn: true, status: ExactAlarmStatus.unsupported),
        isFalse,
      );
    });
  });

  group('ExactAlarm.shouldUsePreciseAlarm', () {
    test('does not touch the platform when the toggle is off', () async {
      final gateway = FakeExactAlarmGateway(
        current: ExactAlarmStatus.granted,
      );

      expect(
        await ExactAlarm(gateway).shouldUsePreciseAlarm(optIn: false),
        isFalse,
      );
      expect(gateway.statusCalls, 0);
    });

    test('re-reads the permission on every call when the toggle is on',
        () async {
      final gateway = FakeExactAlarmGateway(
        current: ExactAlarmStatus.granted,
      );
      final alarm = ExactAlarm(gateway);

      expect(await alarm.shouldUsePreciseAlarm(optIn: true), isTrue);

      // Revoked from system settings between two reminders: the next one
      // degrades to an inexact alarm instead of throwing.
      gateway.current = ExactAlarmStatus.denied;
      expect(await alarm.shouldUsePreciseAlarm(optIn: true), isFalse);
      expect(gateway.statusCalls, 2);
    });

    test('stays inexact off Android', () async {
      final gateway = FakeExactAlarmGateway(
        current: ExactAlarmStatus.unsupported,
      );

      expect(
        await ExactAlarm(gateway).shouldUsePreciseAlarm(optIn: true),
        isFalse,
      );
    });
  });

  group('ExactAlarm.openSettings', () {
    test('reports the status observed after the user comes back', () async {
      final gateway = FakeExactAlarmGateway(
        current: ExactAlarmStatus.denied,
        afterSettings: ExactAlarmStatus.granted,
      );
      final alarm = ExactAlarm(gateway);

      expect(await alarm.openSettings(), ExactAlarmStatus.granted);
      expect(gateway.openSettingsCalls, 1);
      expect(await alarm.status(), ExactAlarmStatus.granted);
    });

    test('reports denied when the user backs out unchanged', () async {
      final gateway = FakeExactAlarmGateway(current: ExactAlarmStatus.denied);

      expect(await ExactAlarm(gateway).openSettings(), ExactAlarmStatus.denied);
    });
  });
}
