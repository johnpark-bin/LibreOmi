import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/models/conversation.dart';
import 'package:libreomi/services/notification_ids.dart';

Task taskAt(DateTime createdAt, {String id = 'task-1'}) => Task(
      id: id,
      title: 'Buy milk',
      createdAt: createdAt,
      dueDate: createdAt.add(const Duration(hours: 1)),
    );

void main() {
  group('notificationIdForTask', () {
    test('is stable for the same task', () {
      final task = taskAt(DateTime.utc(2026, 9, 6, 12, 30, 45, 123));

      expect(notificationIdForTask(task), notificationIdForTask(task));
    });

    test('depends only on createdAt, not on the UUID', () {
      final createdAt = DateTime.utc(2026, 9, 6, 12, 30, 45, 123);

      expect(
        notificationIdForTask(taskAt(createdAt, id: 'uuid-a')),
        notificationIdForTask(taskAt(createdAt, id: 'uuid-b')),
      );
    });

    test('survives a round trip through the database row format', () {
      final task = taskAt(DateTime.utc(2026, 9, 6, 12, 30, 45, 123));
      final restored = Task.fromDbRow({
        'id': task.id,
        'title': task.title,
        'description': null,
        'due_date': task.dueDate!.millisecondsSinceEpoch,
        'created_at': task.createdAt.millisecondsSinceEpoch,
        'source_conversation_id': null,
        'is_completed': 0,
      });

      expect(notificationIdForTask(restored), notificationIdForTask(task));
    });

    test('differs for tasks created milliseconds apart', () {
      final first = DateTime.utc(2026, 9, 6, 12, 30, 45, 123);

      // Several tasks are created in one summarisation pass, within the same
      // second, so second-resolution ids would collide here.
      expect(
        notificationIdForTask(taskAt(first)),
        isNot(notificationIdForTask(taskAt(first.add(const Duration(milliseconds: 1))))),
      );
      expect(
        notificationIdForTask(taskAt(first)),
        isNot(notificationIdForTask(taskAt(first.add(const Duration(milliseconds: 400))))),
      );
    });

    test('is a positive 31-bit integer for a wide range of timestamps', () {
      final samples = <DateTime>[
        DateTime.fromMillisecondsSinceEpoch(0),
        DateTime.fromMillisecondsSinceEpoch(1),
        DateTime.utc(1999, 12, 31, 23, 59, 59, 999),
        DateTime.utc(2026, 9, 6),
        DateTime.utc(2038, 1, 19, 3, 14, 8),
        DateTime.utc(2100, 1, 1),
      ];

      for (final createdAt in samples) {
        final id = notificationIdForTask(taskAt(createdAt));
        expect(id, greaterThanOrEqualTo(0), reason: 'createdAt=$createdAt');
        expect(id, lessThanOrEqualTo(0x7fffffff), reason: 'createdAt=$createdAt');
      }
    });

    test('handles a createdAt before the epoch without going negative', () {
      final id = notificationIdForTask(taskAt(DateTime.utc(1969, 7, 20)));

      expect(id, greaterThanOrEqualTo(0));
      expect(id, lessThanOrEqualTo(0x7fffffff));
    });
  });
}
