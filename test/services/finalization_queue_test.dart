import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:libreomi/services/database_service.dart';
import 'package:libreomi/services/finalization_queue.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<Database> openTestDb() async {
    // `singleInstance: false` is required here: sqflite caches databases by
    // path, and every test opens the same `inMemoryDatabasePath` string, so
    // without this every test after the first would reuse (and see the
    // leftover rows of) the first test's in-memory database.
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await DatabaseService.createPendingFinalizationsTable(db);
    return db;
  }

  Map<String, dynamic> realResult({String title = 'Trip planning'}) => {
        'title': title,
        'summary': 'Discussed the itinerary for the trip.',
        'memories': <String>['Likes window seats'],
        'tasks': <dynamic>[],
      };

  Map<String, dynamic> sentinelResult() => {
        'title': 'Untitled Conversation',
        'summary': '',
        'memories': <String>[],
        'tasks': <dynamic>[],
      };

  group('finalizationRetryDelay', () {
    test('follows the 30s-doubling ladder and caps at 30 minutes', () {
      expect(finalizationRetryDelay(1), const Duration(seconds: 60));
      expect(finalizationRetryDelay(2), const Duration(seconds: 120));
      expect(finalizationRetryDelay(3), const Duration(seconds: 240));
      expect(finalizationRetryDelay(5), const Duration(seconds: 960));
      expect(finalizationRetryDelay(6), const Duration(seconds: 1800));
      expect(finalizationRetryDelay(40), const Duration(seconds: 1800));
      expect(finalizationRetryDelay(0), const Duration(seconds: 60));
    });
  });

  group('isRetryableFinalizationFailure', () {
    test('classifies known transient and permanent errors', () {
      expect(isRetryableFinalizationFailure(const SocketException('down')), isTrue);
      expect(isRetryableFinalizationFailure(TimeoutException('timed out')), isTrue);
      expect(isRetryableFinalizationFailure(FinalizationHttpException(500)), isTrue);
      expect(isRetryableFinalizationFailure(FinalizationHttpException(429)), isTrue);
      expect(isRetryableFinalizationFailure(FinalizationHttpException(401)), isFalse);
      expect(isRetryableFinalizationFailure(FinalizationHttpException(400)), isFalse);
      expect(isRetryableFinalizationFailure(StateError('bug')), isFalse);
    });
  });

  group('FinalizationQueue.enqueue', () {
    test('inserts one row with attempts 0, due now', () async {
      final db = await openTestDb();
      final fixedNow = DateTime(2026, 1, 1, 12);
      final queue = FinalizationQueue(
        summarizer: (_) async => realResult(),
        applier: (_, __) async {},
        databaseProvider: () async => db,
        now: () => fixedNow,
      );

      final id = await queue.enqueue(conversationId: 'c1', transcript: 't1');

      final entry = await queue.entryFor('c1');
      expect(entry, isNotNull);
      expect(entry!.id, id);
      expect(entry.attempts, 0);
      expect(entry.nextAttemptAt, fixedNow);
      expect(entry.lastError, isNull);
    });

    test('enqueuing the same conversation twice yields one row', () async {
      final db = await openTestDb();
      final queue = FinalizationQueue(
        summarizer: (_) async => realResult(),
        applier: (_, __) async {},
        databaseProvider: () async => db,
      );

      final id1 = await queue.enqueue(conversationId: 'c1', transcript: 't1');
      final id2 = await queue.enqueue(conversationId: 'c1', transcript: 't2');

      expect(id1, id2);
      final all = await queue.entries();
      expect(all.length, 1);
    });

    test('a held row is replaced by a fresh one on the next enqueue', () async {
      final db = await openTestDb();
      final queue = FinalizationQueue(
        summarizer: (_) async => throw FinalizationHttpException(401, 'bad key'),
        applier: (_, __) async {},
        databaseProvider: () async => db,
      );

      final heldId = await queue.enqueue(conversationId: 'c1', transcript: 't1');
      await queue.drainOnce();
      final held = await queue.entryFor('c1');
      expect(held!.isHeld, isTrue);

      // A new conversation-ending for the same conversation deserves a clean
      // slate rather than inheriting the exhausted row's attempt count.
      final freshId = await queue.enqueue(conversationId: 'c1', transcript: 't2');

      expect(freshId, isNot(heldId));
      final all = await queue.entries();
      expect(all.length, 1);
      expect(all.single.attempts, 0);
      expect(all.single.transcript, 't2');
      expect(all.single.isHeld, isFalse);
      expect(all.single.lastError, isNull);
    });
  });

  group('FinalizationQueue.drainOnce', () {
    test('success path: applier called, row deleted, returns 1', () async {
      final db = await openTestDb();
      String? appliedConversationId;
      Map<String, dynamic>? appliedResult;

      final queue = FinalizationQueue(
        summarizer: (_) async => realResult(),
        applier: (conversationId, result) async {
          appliedConversationId = conversationId;
          appliedResult = result;
        },
        databaseProvider: () async => db,
      );

      await queue.enqueue(conversationId: 'c1', transcript: 't1');
      final count = await queue.drainOnce();

      expect(count, 1);
      expect(appliedConversationId, 'c1');
      expect(appliedResult, isNotNull);
      expect(await queue.entryFor('c1'), isNull);
    });

    test('transient failure: row survives with attempts 1 and a future retry time', () async {
      final db = await openTestDb();
      var fixedNow = DateTime(2026, 1, 1, 12);

      final queue = FinalizationQueue(
        summarizer: (_) async => throw const SocketException('offline'),
        applier: (_, __) async {},
        databaseProvider: () async => db,
        now: () => fixedNow,
      );

      await queue.enqueue(conversationId: 'c1', transcript: 't1');
      final count = await queue.drainOnce();

      expect(count, 0);
      final entry = await queue.entryFor('c1');
      expect(entry, isNotNull);
      expect(entry!.attempts, 1);
      expect(entry.lastError, isNotNull);
      expect(entry.nextAttemptAt, fixedNow.add(const Duration(seconds: 60)));
      expect(entry.isHeld, isFalse);
    });

    test('swallowed sentinel is treated as transient failure', () async {
      final db = await openTestDb();

      final queue = FinalizationQueue(
        summarizer: (_) async => sentinelResult(),
        applier: (_, __) async {},
        databaseProvider: () async => db,
      );

      await queue.enqueue(conversationId: 'c1', transcript: 't1');
      final count = await queue.drainOnce();

      expect(count, 0);
      final entry = await queue.entryFor('c1');
      expect(entry, isNotNull);
      expect(entry!.attempts, 1);
    });

    test('genuine result with title "Untitled Conversation" but real content is a success', () async {
      final db = await openTestDb();
      Map<String, dynamic>? appliedResult;

      final queue = FinalizationQueue(
        summarizer: (_) async => {
              'title': 'Untitled Conversation',
              'summary': 'A real summary the model actually produced.',
              'memories': <String>[],
              'tasks': <dynamic>[],
            },
        applier: (_, result) async {
          appliedResult = result;
        },
        databaseProvider: () async => db,
      );

      await queue.enqueue(conversationId: 'c1', transcript: 't1');
      final count = await queue.drainOnce();

      expect(count, 1);
      expect(appliedResult, isNotNull);
      expect(await queue.entryFor('c1'), isNull);
    });

    test('permanent failure: row is immediately held and skipped next drain', () async {
      final db = await openTestDb();
      var summarizerCalls = 0;

      final queue = FinalizationQueue(
        summarizer: (_) async {
          summarizerCalls++;
          throw FinalizationHttpException(401, 'bad key');
        },
        applier: (_, __) async {},
        databaseProvider: () async => db,
      );

      await queue.enqueue(conversationId: 'c1', transcript: 't1');
      final count = await queue.drainOnce();

      expect(count, 0);
      expect(summarizerCalls, 1);
      final entry = await queue.entryFor('c1');
      expect(entry, isNotNull);
      expect(entry!.attempts, FinalizationQueue.maxAttempts);
      expect(entry.isHeld, isTrue);

      // A second drain should not call the summarizer again for this row.
      await queue.drainOnce();
      expect(summarizerCalls, 1);
    });

    test('not-yet-due rows are skipped until the clock advances past them', () async {
      final db = await openTestDb();
      var fixedNow = DateTime(2026, 1, 1, 12);
      var summarizerCalls = 0;

      final queue = FinalizationQueue(
        summarizer: (_) async {
          summarizerCalls++;
          return realResult();
        },
        applier: (_, __) async {},
        databaseProvider: () async => db,
        now: () => fixedNow,
      );

      final id = await queue.enqueue(conversationId: 'c1', transcript: 't1');
      // Push this row's due time into the future directly.
      await db.update(
        FinalizationQueue.tableName,
        {'next_attempt_at': fixedNow.add(const Duration(minutes: 5)).millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [id],
      );

      var count = await queue.drainOnce();
      expect(count, 0);
      expect(summarizerCalls, 0);

      fixedNow = fixedNow.add(const Duration(minutes: 6));
      count = await queue.drainOnce();
      expect(count, 1);
      expect(summarizerCalls, 1);
    });

    test('repeated transient failures eventually hold the row at maxAttempts', () async {
      final db = await openTestDb();
      var fixedNow = DateTime(2026, 1, 1, 12);

      final queue = FinalizationQueue(
        summarizer: (_) async => throw const SocketException('offline'),
        applier: (_, __) async {},
        databaseProvider: () async => db,
        now: () => fixedNow,
      );

      await queue.enqueue(conversationId: 'c1', transcript: 't1');

      for (var i = 0; i < FinalizationQueue.maxAttempts; i++) {
        await queue.drainOnce();
        final entry = await queue.entryFor('c1');
        // Jump the clock well past whatever backoff was just set so the
        // row is due again on the next iteration.
        fixedNow = entry!.nextAttemptAt.add(const Duration(seconds: 1));
      }

      final entry = await queue.entryFor('c1');
      expect(entry, isNotNull);
      expect(entry!.attempts, FinalizationQueue.maxAttempts);
      expect(entry.isHeld, isTrue);
    });

    test('one row failing does not stop a healthy row in the same drain', () async {
      final db = await openTestDb();
      final applied = <String>[];

      final queue = FinalizationQueue(
        summarizer: (transcript) async {
          if (transcript == 'bad') {
            throw const SocketException('offline');
          }
          return realResult();
        },
        applier: (conversationId, __) async {
          applied.add(conversationId);
        },
        databaseProvider: () async => db,
      );

      await queue.enqueue(conversationId: 'bad-convo', transcript: 'bad');
      await queue.enqueue(conversationId: 'good-convo', transcript: 'good');

      final count = await queue.drainOnce();

      expect(count, 1);
      expect(applied, ['good-convo']);
      expect(await queue.entryFor('good-convo'), isNull);
      final badEntry = await queue.entryFor('bad-convo');
      expect(badEntry, isNotNull);
      expect(badEntry!.attempts, 1);
    });

    test('applier throwing is treated as a failure and the row is not deleted', () async {
      final db = await openTestDb();

      final queue = FinalizationQueue(
        summarizer: (_) async => realResult(),
        applier: (_, __) async => throw const SocketException('applier failed'),
        databaseProvider: () async => db,
      );

      await queue.enqueue(conversationId: 'c1', transcript: 't1');
      final count = await queue.drainOnce();

      expect(count, 0);
      final entry = await queue.entryFor('c1');
      expect(entry, isNotNull);
      expect(entry!.attempts, 1);
    });
  });
}
