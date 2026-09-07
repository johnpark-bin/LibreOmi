/// Pure-Dart exact-alarm model, importable from `flutter test` without
/// touching any plugin channel. See `docs/04-android-platform-notes.md` §3
/// and §6 for the permission this facade wraps and why task reminders are
/// inexact unless the user opts in.
library;

/// Whether the app may schedule exact alarms right now.
enum ExactAlarmStatus {
  /// `AlarmManager.canScheduleExactAlarms()` is true, either because the user
  /// allowed it in system settings or because the platform pre-granted it
  /// (API ≤ 30, and API 31–32 where `SCHEDULE_EXACT_ALARM` is granted at
  /// install time).
  granted,

  /// The permission is declared but the system has not granted it. On
  /// Android 14+ this is the default for an app targeting API 33+, which is
  /// what this app does (targetSdk 35).
  denied,

  /// There is nothing to ask for: not running on Android, where exact alarms
  /// are not a permission-gated concept.
  unsupported,
}

/// The platform surface [ExactAlarm] needs. Implemented for real by
/// `PluginExactAlarmGateway` (see `lib/platform/exact_alarm_gateway.dart`)
/// and faked in tests so this file never has to import a plugin.
abstract class ExactAlarmGateway {
  /// The current exact-alarm status.
  Future<ExactAlarmStatus> status();

  /// Sends the user to the system's "Alarms & reminders" screen and reports
  /// the status observed after they come back.
  Future<ExactAlarmStatus> openSettings();
}

/// The facade the app calls to decide how a task reminder is scheduled.
///
/// The opt-in toggle alone is not enough: `SCHEDULE_EXACT_ALARM` can be
/// revoked from system settings at any time, so the permission is re-read at
/// schedule time and a revoked permission silently degrades to an inexact
/// alarm rather than throwing.
class ExactAlarm {
  ExactAlarm(this.gateway);

  final ExactAlarmGateway gateway;

  /// The current exact-alarm status.
  Future<ExactAlarmStatus> status() => gateway.status();

  /// Opens the system screen where the user grants the permission, and
  /// reports the status observed on return.
  Future<ExactAlarmStatus> openSettings() => gateway.openSettings();

  /// Whether a reminder scheduled now should ask for an exact alarm.
  ///
  /// Short-circuits on [optIn] so the default (toggle off) costs no platform
  /// round-trip at all, keeping the scheduling path exactly as it was before
  /// this setting existed.
  Future<bool> shouldUsePreciseAlarm({required bool optIn}) async {
    if (!optIn) {
      return false;
    }
    return usePreciseAlarm(optIn: optIn, status: await gateway.status());
  }
}

/// The whole decision, as a pure function: an exact alarm is used only when
/// the user opted in *and* the system currently grants the permission.
///
/// [ExactAlarmStatus.unsupported] (not Android) yields false because
/// `preciseAlarm` is an Android-only scheduling flag; iOS delivers the
/// notification at the requested time regardless.
bool usePreciseAlarm({
  required bool optIn,
  required ExactAlarmStatus status,
}) =>
    optIn && status == ExactAlarmStatus.granted;
