import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flutter/material.dart';

import '../platform/exact_alarm.dart';
import '../platform/exact_alarm_gateway.dart' show exactAlarm;
import 'notification_channels.dart';
import 'settings_service.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  /// Exact-alarm facade consulted by [scheduleTaskNotification]. Injectable
  /// so a test can drive the precise/inexact decision without a plugin
  /// channel; defaults to the app-wide instance.
  ExactAlarm exactAlarmFacade = exactAlarm;

  Future<void> initialize() async {
    await AwesomeNotifications().initialize(
      NotificationChannels.defaultIcon,
      NotificationChannels.all,
      channelGroups: NotificationChannels.groups,
      debug: false,
    );

    // Request permission
    await AwesomeNotifications().isNotificationAllowed().then((isAllowed) {
      if (!isAllowed) {
        AwesomeNotifications().requestPermissionToSendNotifications();
      }
    });

    // Clear badges on init
    await AwesomeNotifications().resetGlobalBadge();
  }

  Future<void> showAiResponse(String message) async {
    await AwesomeNotifications().createNotification(
      content: NotificationContent(
        id: DateTime.now().millisecondsSinceEpoch.remainder(100000),
        channelKey: NotificationChannels.aiResponses,
        title: 'Omi',
        body: message,
        notificationLayout: NotificationLayout.BigText,
      ),
    );
  }

  Future<void> showNotification(String title, String body) async {
    await AwesomeNotifications().createNotification(
      content: NotificationContent(
        id: DateTime.now().millisecondsSinceEpoch.remainder(100000),
        channelKey: NotificationChannels.device,
        title: title,
        body: body,
        notificationLayout: NotificationLayout.Default,
      ),
    );
  }

  Future<void> scheduleTaskNotification({
    required int id,
    required String title,
    required DateTime dueDate,
  }) async {
    final now = DateTime.now();
    // Only schedule if due date is in the future
    if (dueDate.isBefore(now)) return;

    // If due date is very close (less than 5 seconds), add a small buffer
    // to ensure the system processes it correctly
    var scheduledDate = dueDate;
    if (dueDate.difference(now).inSeconds < 5) {
      scheduledDate = now.add(const Duration(seconds: 5));
    }

    // Inexact by default: the reminder may arrive a few minutes late, which
    // is fine for a due-date nudge, and it needs no permission.
    // `preciseAlarm: true` needs SCHEDULE_EXACT_ALARM, which Android 14
    // stopped pre-granting to apps targeting API 33+ (we target 35), so it is
    // used only when the user turned the opt-in on *and* the permission is
    // granted right now (LO-50). Re-read here rather than cached, so a
    // permission revoked between two reminders degrades to inexact instead of
    // being rejected by the platform.
    bool precise;
    try {
      precise = await exactAlarmFacade.shouldUsePreciseAlarm(
        optIn: SettingsService.exactTaskReminders,
      );
    } catch (e) {
      // An unreachable permission channel must not cost the user the
      // reminder: fall back to the inexact schedule this method used before
      // the opt-in existed.
      debugPrint('Exact-alarm status unavailable, scheduling inexact: $e');
      precise = false;
    }

    await AwesomeNotifications().createNotification(
      content: NotificationContent(
        id: id,
        channelKey: NotificationChannels.taskReminders,
        title: 'Task Due: $title',
        body: 'It is time to complete your task.',
        notificationLayout: NotificationLayout.Default,
        category: NotificationCategory.Reminder,
        wakeUpScreen: true,
      ),
      schedule: NotificationCalendar.fromDate(
        date: scheduledDate,
        preciseAlarm: precise,
        // Maps to AlarmManager.setAndAllowWhileIdle: it fires during Doze
        // rather than being deferred to a maintenance window, but the system
        // rate-limits such alarms to roughly one per app per 9 minutes and the
        // delivery time is inexact. Kept on in both modes: it is what carries
        // the inexact fallback through Doze.
        allowWhileIdle: true,
      ),
    );
    debugPrint(
      'Scheduled notification for task: $title at $scheduledDate '
      '(ID: $id, preciseAlarm: $precise)',
    );
  }

  Future<void> cancelTaskNotification(int id) async {
    await AwesomeNotifications().cancel(id);
    debugPrint('Cancelled notification ID: $id');
  }

  Future<void> resetGlobalBadge() async {
    await AwesomeNotifications().resetGlobalBadge();
  }
}
