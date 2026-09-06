import 'package:flutter_test/flutter_test.dart';

import 'package:libreomi/data/finalization_repo.dart';

import 'test_db.dart';

void main() {
  useFfiDatabaseFactory();

  PendingFinalizationRow makeRow({
    required String id,
    required String conversationId,
    int attempts = 0,
    required DateTime nextAttemptAt,
    required DateTime createdAt,
    String? lastError,
  }) {
    return PendingFinalizationRow(
      id: id,
      conversationId: conversationId,
      transcript: 'transcript for $conversationId',
      attempts: attempts,
      nextAttemptAt: nextAttemptAt,
      lastError: lastError,
      createdAt: createdAt,
    );
  }

  group('FinalizationRepo.insert/all/forConversation/delete', () {
    test('round trips a row', () async {
      final db = await openTestDb();
      final repo = FinalizationRepo(db);

      await repo.insert(makeRow(
        id: 'p1',
        conversationId: 'c1',
        nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(1000),
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      final all = await repo.all();
      expect(all, hasLength(1));
      expect(all.single.id, 'p1');
      expect(all.single.conversationId, 'c1');
      expect(all.single.transcript, 'transcript for c1');
    });

    test('all orders by created_at ASC', () async {
      final db = await openTestDb();
      final repo = FinalizationRepo(db);

      await repo.insert(makeRow(
        id: 'p1',
        conversationId: 'c1',
        nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(3000),
        createdAt: DateTime.fromMillisecondsSinceEpoch(3000),
      ));
      await repo.insert(makeRow(
        id: 'p2',
        conversationId: 'c2',
        nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(1000),
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      final all = await repo.all();
      expect(all.map((r) => r.id).toList(), ['p2', 'p1']);
    });

    test('forConversation filters by conversation id', () async {
      final db = await openTestDb();
      final repo = FinalizationRepo(db);

      await repo.insert(makeRow(
        id: 'p1',
        conversationId: 'c1',
        nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(1000),
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));
      await repo.insert(makeRow(
        id: 'p2',
        conversationId: 'c2',
        nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(1000),
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      final rows = await repo.forConversation('c1');
      expect(rows, hasLength(1));
      expect(rows.single.id, 'p1');
    });

    test('delete removes the row', () async {
      final db = await openTestDb();
      final repo = FinalizationRepo(db);

      await repo.insert(makeRow(
        id: 'p1',
        conversationId: 'c1',
        nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(1000),
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));
      await repo.delete('p1');

      expect(await repo.all(), isEmpty);
    });
  });

  group('FinalizationRepo.due', () {
    test('filters by attempts < maxAttempts and next_attempt_at <= now',
        () async {
      final db = await openTestDb();
      final repo = FinalizationRepo(db);

      // Due: attempts below cap, already due.
      await repo.insert(makeRow(
        id: 'due-early',
        conversationId: 'c1',
        attempts: 0,
        nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(1000),
        createdAt: DateTime.fromMillisecondsSinceEpoch(500),
      ));
      // Due later than the "now" used below: not due yet.
      await repo.insert(makeRow(
        id: 'not-due-yet',
        conversationId: 'c2',
        attempts: 0,
        nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(9000),
        createdAt: DateTime.fromMillisecondsSinceEpoch(500),
      ));
      // Held: attempts at the cap.
      await repo.insert(makeRow(
        id: 'held',
        conversationId: 'c3',
        attempts: 10,
        nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(1000),
        createdAt: DateTime.fromMillisecondsSinceEpoch(500),
      ));
      // Due and created later, to check ordering.
      await repo.insert(makeRow(
        id: 'due-late',
        conversationId: 'c4',
        attempts: 0,
        nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(1500),
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      final due = await repo.due(
        maxAttempts: 10,
        now: DateTime.fromMillisecondsSinceEpoch(5000),
      );

      expect(due.map((r) => r.id).toList(), ['due-early', 'due-late']);
    });
  });

  group('FinalizationRepo.updateAttempt', () {
    test('updates attempts, next_attempt_at and last_error', () async {
      final db = await openTestDb();
      final repo = FinalizationRepo(db);

      await repo.insert(makeRow(
        id: 'p1',
        conversationId: 'c1',
        nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(1000),
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      await repo.updateAttempt(
        id: 'p1',
        attempts: 1,
        nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(2000),
        lastError: 'boom',
      );

      final row = (await repo.all()).single;
      expect(row.attempts, 1);
      expect(row.nextAttemptAt, DateTime.fromMillisecondsSinceEpoch(2000));
      expect(row.lastError, 'boom');
    });

    test('omitting nextAttemptAt leaves the existing due time untouched',
        () async {
      final db = await openTestDb();
      final repo = FinalizationRepo(db);

      await repo.insert(makeRow(
        id: 'p1',
        conversationId: 'c1',
        nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(1234),
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      await repo.updateAttempt(
        id: 'p1',
        attempts: 10,
        lastError: 'permanent failure',
      );

      final row = (await repo.all()).single;
      expect(row.attempts, 10);
      expect(row.nextAttemptAt, DateTime.fromMillisecondsSinceEpoch(1234));
      expect(row.lastError, 'permanent failure');
    });
  });
}
