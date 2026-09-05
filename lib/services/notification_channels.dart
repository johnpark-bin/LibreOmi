import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flutter/material.dart';

/// Notification channel keys and definitions, kept in one place so a key string
/// is never spelled out twice and the layout can be asserted in a unit test
/// without initialising the plugin.
///
/// The four channels mirror `docs/04-android-platform-notes.md` §6.
abstract final class NotificationChannels {
  /// Small status-bar icon. Monochrome vector, see
  /// `android/app/src/main/res/drawable/ic_notification.xml`.
  static const String defaultIcon = 'resource://drawable/ic_notification';

  static const String channelGroupKey = 'libreomi_notifications';

  /// Persistent foreground-service notification while a session runs.
  /// Defined here so the channel exists from first launch; the background
  /// runner starts using it in LO-20.
  static const String session = 'session';

  /// Answers from the assistant. Max importance: they are a direct reply to
  /// something the wearer just asked for.
  static const String aiResponses = 'ai_responses';

  /// Scheduled reminders for due tasks.
  static const String taskReminders = 'task_reminders';

  /// Device chatter: battery level, disconnects, double-tap confirmations.
  static const String device = 'device';

  static const Color _accent = Color(0xFF9D50DD);

  /// Every channel the app registers, in importance order.
  static List<NotificationChannel> get all => <NotificationChannel>[
        NotificationChannel(
          channelGroupKey: channelGroupKey,
          channelKey: session,
          channelName: 'Session',
          channelDescription: 'Ongoing notification while a session is recording',
          defaultColor: _accent,
          importance: NotificationImportance.Low,
          channelShowBadge: false,
          playSound: false,
          enableVibration: false,
          locked: true,
        ),
        NotificationChannel(
          channelGroupKey: channelGroupKey,
          channelKey: aiResponses,
          channelName: 'AI Responses',
          channelDescription: 'Answers from the assistant',
          defaultColor: _accent,
          ledColor: Colors.white,
          importance: NotificationImportance.Max,
          channelShowBadge: true,
        ),
        NotificationChannel(
          channelGroupKey: channelGroupKey,
          channelKey: taskReminders,
          channelName: 'Task Reminders',
          channelDescription: 'Notifications for due tasks',
          defaultColor: _accent,
          ledColor: Colors.white,
          importance: NotificationImportance.High,
          channelShowBadge: true,
        ),
        NotificationChannel(
          channelGroupKey: channelGroupKey,
          channelKey: device,
          channelName: 'Device',
          channelDescription: 'Battery, connection state, and button confirmations',
          defaultColor: _accent,
          importance: NotificationImportance.Default,
          channelShowBadge: false,
        ),
      ];

  /// The single group the channels above are filed under.
  static List<NotificationChannelGroup> get groups =>
      <NotificationChannelGroup>[
        NotificationChannelGroup(
          channelGroupKey: channelGroupKey,
          channelGroupName: 'LibreOmi',
        ),
      ];
}
