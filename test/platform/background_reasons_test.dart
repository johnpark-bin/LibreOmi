import 'package:flutter_test/flutter_test.dart';

import 'package:libreomi/platform/background_reasons.dart';

void main() {
  group('orderedBackgroundReasons', () {
    test('empty set returns empty list', () {
      expect(orderedBackgroundReasons(<BackgroundReason>{}), isEmpty);
    });

    test('orders connectedDevice before microphone regardless of set order', () {
      expect(
        orderedBackgroundReasons({
          BackgroundReason.microphone,
          BackgroundReason.connectedDevice,
        }),
        [BackgroundReason.connectedDevice, BackgroundReason.microphone],
      );
    });

    test('keeps a single reason', () {
      expect(
        orderedBackgroundReasons({BackgroundReason.microphone}),
        [BackgroundReason.microphone],
      );
    });
  });

  group('androidForegroundServiceTypes', () {
    test('empty set returns empty list', () {
      expect(androidForegroundServiceTypes(<BackgroundReason>{}), <String>[]);
    });

    test('connectedDevice only returns [connectedDevice]', () {
      expect(
        androidForegroundServiceTypes({BackgroundReason.connectedDevice}),
        ['connectedDevice'],
      );
    });

    test('microphone only returns [microphone]', () {
      expect(
        androidForegroundServiceTypes({BackgroundReason.microphone}),
        ['microphone'],
      );
    });

    test('both reasons returns connectedDevice before microphone', () {
      expect(
        androidForegroundServiceTypes({
          BackgroundReason.microphone,
          BackgroundReason.connectedDevice,
        }),
        ['connectedDevice', 'microphone'],
      );
    });
  });

  group('requiresForegroundStart', () {
    test('false for empty set', () {
      expect(requiresForegroundStart(<BackgroundReason>{}), isFalse);
    });

    test('false for connectedDevice only', () {
      expect(
        requiresForegroundStart({BackgroundReason.connectedDevice}),
        isFalse,
      );
    });

    test('true when microphone is present', () {
      expect(
        requiresForegroundStart({BackgroundReason.microphone}),
        isTrue,
      );
      expect(
        requiresForegroundStart({
          BackgroundReason.connectedDevice,
          BackgroundReason.microphone,
        }),
        isTrue,
      );
    });
  });

  group('formatConversationLength', () {
    test('0 seconds', () {
      expect(formatConversationLength(Duration.zero), '00:00');
    });

    test('7 seconds', () {
      expect(formatConversationLength(const Duration(seconds: 7)), '00:07');
    });

    test('12 minutes 34 seconds', () {
      expect(
        formatConversationLength(
          const Duration(minutes: 12, seconds: 34),
        ),
        '12:34',
      );
    });

    test('exactly 1 hour', () {
      expect(
        formatConversationLength(const Duration(hours: 1)),
        '1:00:00',
      );
    });

    test('1 hour 2 minutes 3 seconds', () {
      expect(
        formatConversationLength(
          const Duration(hours: 1, minutes: 2, seconds: 3),
        ),
        '1:02:03',
      );
    });

    test('negative duration clamps to 00:00', () {
      expect(
        formatConversationLength(const Duration(seconds: -5)),
        '00:00',
      );
    });
  });

  group('SessionNotificationText.forSession', () {
    test('phone mic', () {
      final text = SessionNotificationText.forSession(
        usingPhoneMic: true,
        deviceConnected: false,
        conversationLength: const Duration(seconds: 7),
      );
      expect(text.title, 'LibreOmi');
      expect(text.text, 'Phone mic · 00:07');
    });

    test('Omi connected', () {
      final text = SessionNotificationText.forSession(
        usingPhoneMic: false,
        deviceConnected: true,
        conversationLength: const Duration(minutes: 1),
      );
      expect(text.text, 'Omi connected · 01:00');
    });

    test('Omi disconnected', () {
      final text = SessionNotificationText.forSession(
        usingPhoneMic: false,
        deviceConnected: false,
        conversationLength: const Duration(seconds: 30),
      );
      expect(text.text, 'Omi disconnected · 00:30');
    });

    test('value equality', () {
      final a = SessionNotificationText.forSession(
        usingPhoneMic: false,
        deviceConnected: true,
        conversationLength: const Duration(seconds: 5),
      );
      final b = SessionNotificationText.forSession(
        usingPhoneMic: false,
        deviceConnected: true,
        conversationLength: const Duration(seconds: 5),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('SessionNotificationThrottle', () {
    test('first call always pushes', () {
      final throttle = SessionNotificationThrottle();
      final now = DateTime(2026, 1, 1, 12, 0, 0);
      final candidate = SessionNotificationText.forSession(
        usingPhoneMic: false,
        deviceConnected: true,
        conversationLength: const Duration(seconds: 1),
      );

      expect(throttle.next(candidate, now), candidate);
    });

    test('duration-only change inside minInterval is suppressed', () {
      final throttle = SessionNotificationThrottle();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      final first = SessionNotificationText.forSession(
        usingPhoneMic: false,
        deviceConnected: true,
        conversationLength: const Duration(seconds: 1),
      );
      throttle.next(first, t0);

      final second = SessionNotificationText.forSession(
        usingPhoneMic: false,
        deviceConnected: true,
        conversationLength: const Duration(seconds: 10),
      );
      final result = throttle.next(second, t0.add(const Duration(seconds: 10)));

      expect(result, isNull);
    });

    test('same duration-only change after minInterval is pushed', () {
      final throttle = SessionNotificationThrottle();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      final first = SessionNotificationText.forSession(
        usingPhoneMic: false,
        deviceConnected: true,
        conversationLength: const Duration(seconds: 1),
      );
      throttle.next(first, t0);

      final second = SessionNotificationText.forSession(
        usingPhoneMic: false,
        deviceConnected: true,
        conversationLength: const Duration(seconds: 40),
      );
      final result = throttle.next(second, t0.add(const Duration(seconds: 31)));

      expect(result, second);
    });

    test('source change inside minInterval is pushed immediately', () {
      final throttle = SessionNotificationThrottle();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      final first = SessionNotificationText.forSession(
        usingPhoneMic: false,
        deviceConnected: true,
        conversationLength: const Duration(seconds: 1),
      );
      throttle.next(first, t0);

      final second = SessionNotificationText.forSession(
        usingPhoneMic: false,
        deviceConnected: false,
        conversationLength: const Duration(seconds: 2),
      );
      final result = throttle.next(second, t0.add(const Duration(seconds: 2)));

      expect(result, second);
    });

    test('reset() makes the next call push again', () {
      final throttle = SessionNotificationThrottle();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      final first = SessionNotificationText.forSession(
        usingPhoneMic: false,
        deviceConnected: true,
        conversationLength: const Duration(seconds: 1),
      );
      throttle.next(first, t0);
      throttle.reset();

      final second = SessionNotificationText.forSession(
        usingPhoneMic: false,
        deviceConnected: true,
        conversationLength: const Duration(seconds: 2),
      );
      final result = throttle.next(second, t0.add(const Duration(seconds: 1)));

      expect(result, second);
    });
  });
}
