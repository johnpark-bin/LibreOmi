import 'dart:io' show Platform;

import 'package:permission_handler/permission_handler.dart' as ph;

import 'exact_alarm.dart';

/// The real [ExactAlarmGateway], backed by `permission_handler`.
///
/// Like `permission_gateway.dart` and `battery_optimization_gateway.dart`,
/// this file is allowed to branch on `Platform.isAndroid` (see `AGENTS.md`):
/// exact alarms are an Android concept, so the split is contained here and
/// the rest of the app talks to the pure-Dart facade instead.
class PluginExactAlarmGateway implements ExactAlarmGateway {
  @override
  Future<ExactAlarmStatus> status() async {
    if (!Platform.isAndroid) {
      return ExactAlarmStatus.unsupported;
    }
    // The plugin answers this one from `AlarmManager.canScheduleExactAlarms()`
    // on API 31+, and reports granted below that, which matches the platform:
    // exact alarms needed no permission before Android 12.
    return _toStatus(await ph.Permission.scheduleExactAlarm.status);
  }

  @override
  Future<ExactAlarmStatus> openSettings() async {
    if (!Platform.isAndroid) {
      return ExactAlarmStatus.unsupported;
    }
    // `permission_handler` maps this "permission" onto the
    // ACTION_REQUEST_SCHEDULE_EXACT_ALARM settings screen rather than a
    // runtime prompt, and resolves the future from `onActivityResult` with a
    // fresh `canScheduleExactAlarms()` reading — so the status returned here
    // already reflects what the user just did.
    return _toStatus(await ph.Permission.scheduleExactAlarm.request());
  }

  ExactAlarmStatus _toStatus(ph.PermissionStatus status) =>
      status.isGranted ? ExactAlarmStatus.granted : ExactAlarmStatus.denied;
}

/// App-wide [ExactAlarm] backed by the real plugin.
final ExactAlarm exactAlarm = ExactAlarm(PluginExactAlarmGateway());
