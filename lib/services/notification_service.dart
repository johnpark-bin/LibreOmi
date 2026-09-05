import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flutter/material.dart';

import 'notification_channels.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

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
        // Inexact delivery: the reminder may arrive a few minutes late, which
        // is fine for a due-date nudge. `preciseAlarm: true` needs
        // SCHEDULE_EXACT_ALARM, which Android 14 stopped pre-granting to apps
        // targeting API 33+ (we target 35), so it would silently degrade to
        // this anyway unless the user opts in from system settings. An explicit
        // opt-in setting is left to a follow-up issue.
        preciseAlarm: false,
        // Maps to AlarmManager.setAndAllowWhileIdle: it fires during Doze
        // rather than being deferred to a maintenance window, but the system
        // rate-limits such alarms to roughly one per app per 9 minutes and the
        // delivery time is inexact.
        allowWhileIdle: true,
      ),
    );
    debugPrint('Scheduled notification for task: $title at $scheduledDate (ID: $id)');
  }

  Future<void> cancelTaskNotification(int id) async {
    await AwesomeNotifications().cancel(id);
    debugPrint('Cancelled notification ID: $id');
  }

  Future<void> resetGlobalBadge() async {
    await AwesomeNotifications().resetGlobalBadge();
  }
}
