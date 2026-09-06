import 'package:flutter_test/flutter_test.dart';

import 'package:libreomi/core/ids.dart';
import 'package:libreomi/data/task_repo.dart';
import 'package:libreomi/models/conversation.dart';

import 'test_db.dart';

void main() {
  useFfiDatabaseFactory();

  Task makeTask({
    required String id,
    required String title,
    required DateTime createdAt,
    DateTime? dueDate,
    bool isCompleted = false,
    int? notificationId,
  }) {
    return Task(
      id: id,
      title: title,
      createdAt: createdAt,
      dueDate: dueDate,
      isCompleted: isCompleted,
      notificationId: notificationId,
    );
  }

  group('TaskRepo.save/all/delete/setCompleted', () {
    test('round trips a task', () async {
      final db = await openTestDb();
      final repo = TaskRepo(db);

      await repo.save(makeTask(
        id: 't1',
        title: 'Buy milk',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      final all = await repo.all();
      expect(all, hasLength(1));
      expect(all.single.id, 't1');
      expect(all.single.title, 'Buy milk');
    });

    test('orders by is_completed ASC, due_date ASC, created_at DESC',
        () async {
      final db = await openTestDb();
      final repo = TaskRepo(db);

      await repo.save(makeTask(
        id: 'done',
        title: 'done task',
        createdAt: DateTime.fromMillisecondsSinceEpoch(5000),
        isCompleted: true,
      ));
      await repo.save(makeTask(
        id: 'due-late',
        title: 'due late',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        dueDate: DateTime.fromMillisecondsSinceEpoch(9000),
      ));
      await repo.save(makeTask(
        id: 'due-early',
        title: 'due early',
        createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
        dueDate: DateTime.fromMillisecondsSinceEpoch(3000),
      ));
      await repo.save(makeTask(
        id: 'newer-no-due',
        title: 'newer no due',
        createdAt: DateTime.fromMillisecondsSinceEpoch(4000),
      ));
      await repo.save(makeTask(
        id: 'older-no-due',
        title: 'older no due',
        createdAt: DateTime.fromMillisecondsSinceEpoch(3500),
      ));

      // SQLite sorts NULL first in an ASC ordering, so the no-due-date tasks
      // (still tiebroken by created_at DESC) come before the due-date ones.
      final all = await repo.all();
      expect(
        all.map((t) => t.id).toList(),
        ['newer-no-due', 'older-no-due', 'due-early', 'due-late', 'done'],
      );
    });

    test('all respects limit', () async {
      final db = await openTestDb();
      final repo = TaskRepo(db);

      for (var i = 0; i < 5; i++) {
        await repo.save(makeTask(
          id: 't$i',
          title: 'task $i',
          createdAt: DateTime.fromMillisecondsSinceEpoch(1000 * i),
        ));
      }

      expect(await repo.all(limit: 2), hasLength(2));
    });

    test('setCompleted updates is_completed', () async {
      final db = await openTestDb();
      final repo = TaskRepo(db);

      await repo.save(makeTask(
        id: 't1',
        title: 'task',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));
      await repo.setCompleted('t1', true);

      final all = await repo.all();
      expect(all.single.isCompleted, isTrue);
    });

    test('delete removes the row', () async {
      final db = await openTestDb();
      final repo = TaskRepo(db);

      await repo.save(makeTask(
        id: 't1',
        title: 'task',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));
      await repo.delete('t1');

      expect(await repo.all(), isEmpty);
    });
  });

  group('TaskRepo notification_id', () {
    test('persists an explicit notificationId and reads it back', () async {
      final db = await openTestDb();
      final repo = TaskRepo(db);

      await repo.save(makeTask(
        id: 't1',
        title: 'task',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        notificationId: 42,
      ));

      final read = await repo.all();
      expect(read.single.notificationId, 42);
    });

    test('falls back to fallbackNotificationId(createdAt) when absent',
        () async {
      final db = await openTestDb();
      final repo = TaskRepo(db);

      final createdAt = DateTime.fromMillisecondsSinceEpoch(123456789);
      await repo.save(makeTask(
        id: 't1',
        title: 'task',
        createdAt: createdAt,
      ));

      final read = await repo.all();
      expect(read.single.notificationId, fallbackNotificationId(createdAt));
    });
  });

  group('TaskRepo.hasSimilar', () {
    test('is case-insensitive and matches substrings among incomplete tasks',
        () async {
      final db = await openTestDb();
      final repo = TaskRepo(db);

      await repo.save(makeTask(
        id: 't1',
        title: 'Buy milk and eggs',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      expect(await repo.hasSimilar('buy milk'), isTrue);
      expect(await repo.hasSimilar('BUY MILK AND EGGS'), isTrue);
    });

    test('matches when an existing title is a substring of the new one',
        () async {
      final db = await openTestDb();
      final repo = TaskRepo(db);

      await repo.save(makeTask(
        id: 't1',
        title: 'buy milk',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      expect(await repo.hasSimilar('please buy milk today'), isTrue);
    });

    test('ignores completed tasks', () async {
      final db = await openTestDb();
      final repo = TaskRepo(db);

      await repo.save(makeTask(
        id: 't1',
        title: 'buy milk',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        isCompleted: true,
      ));

      expect(await repo.hasSimilar('buy milk'), isFalse);
    });

    test('returns false when nothing is similar', () async {
      final db = await openTestDb();
      final repo = TaskRepo(db);

      await repo.save(makeTask(
        id: 't1',
        title: 'buy milk',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      expect(await repo.hasSimilar('walk the dog'), isFalse);
    });
  });
}
