import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:libreomi/services/notification_channels.dart';

void main() {
  group('NotificationChannels', () {
    test('registers exactly the four channels from docs/04 §6', () {
      final keys = NotificationChannels.all.map((c) => c.channelKey).toList();

      expect(keys, <String>[
        NotificationChannels.session,
        NotificationChannels.aiResponses,
        NotificationChannels.taskReminders,
        NotificationChannels.device,
      ]);
      expect(keys, <String>['session', 'ai_responses', 'task_reminders', 'device']);
      expect(keys.toSet(), hasLength(keys.length), reason: 'keys must be unique');
    });

    test('importance matches the role of each channel', () {
      final importance = <String, NotificationImportance?>{
        for (final c in NotificationChannels.all) c.channelKey!: c.importance,
      };

      expect(importance[NotificationChannels.session], NotificationImportance.Low);
      expect(importance[NotificationChannels.aiResponses], NotificationImportance.Max);
      expect(importance[NotificationChannels.taskReminders], NotificationImportance.High);
      expect(importance[NotificationChannels.device], NotificationImportance.Default);
    });

    test('the session channel stays quiet and sticky', () {
      final session = NotificationChannels.all
          .firstWhere((c) => c.channelKey == NotificationChannels.session);

      expect(session.playSound, isFalse);
      expect(session.enableVibration, isFalse);
      expect(session.channelShowBadge, isFalse);
      expect(session.locked, isTrue);
    });

    test('every channel is filed under the one declared group', () {
      expect(NotificationChannels.groups, hasLength(1));
      expect(NotificationChannels.groups.single.channelGroupKey,
          NotificationChannels.channelGroupKey);
      expect(
        NotificationChannels.all.map((c) => c.channelGroupKey),
        everyElement(NotificationChannels.channelGroupKey),
      );
    });

    test('no channel asks for a sound resource the APK does not ship', () {
      expect(
        NotificationChannels.all.map((c) => c.soundSource),
        everyElement(isNull),
      );
    });

    test('the small icon points at the monochrome drawable', () {
      expect(NotificationChannels.defaultIcon,
          'resource://drawable/ic_notification');
    });
  });
}
