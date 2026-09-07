import 'package:flutter_test/flutter_test.dart';

import 'package:libreomi/data/chat_repo.dart';
import 'package:libreomi/models/conversation.dart';

import 'test_db.dart';

void main() {
  useFfiDatabaseFactory();

  ChatMessage makeMessage({
    required String id,
    required DateTime createdAt,
    String text = 'hello',
    bool isUser = true,
    String? conversationId,
  }) {
    return ChatMessage(
      id: id,
      text: text,
      isUser: isUser,
      createdAt: createdAt,
      conversationId: conversationId,
    );
  }

  group('ChatRepo insertion order (LO-65)', () {
    test('same-millisecond messages come back in the order they were saved',
        () async {
      // The tie the `seq` column exists to break: identical `created_at`, and
      // ids that sort the other way round, so a `created_at, id` order would
      // hand the pair back reversed.
      final db = await openTestDb();
      final repo = ChatRepo(db);
      final sameInstant = DateTime.fromMillisecondsSinceEpoch(1000);

      await repo.save(makeMessage(id: 'z', createdAt: sameInstant, text: 'Q'));
      await repo.save(makeMessage(
        id: 'a',
        createdAt: sameInstant,
        text: 'A',
        isUser: false,
      ));

      expect((await repo.all()).map((m) => m.text), ['Q', 'A']);
    });

    test('an older timestamp saved later still sorts last', () async {
      // `created_at` is display data, not the sort key: a clock that jumped
      // backwards must not reorder a history that was written in one go.
      final db = await openTestDb();
      final repo = ChatRepo(db);

      await repo.save(makeMessage(
        id: 'm1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
        text: 'written first',
      ));
      await repo.save(makeMessage(
        id: 'm2',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        text: 'written second',
      ));

      expect(
        (await repo.all()).map((m) => m.text),
        ['written first', 'written second'],
      );
    });

    test('save stamps a monotonically increasing seq', () async {
      final db = await openTestDb();
      final repo = ChatRepo(db);
      final sameInstant = DateTime.fromMillisecondsSinceEpoch(1000);

      for (final id in ['m1', 'm2', 'm3']) {
        await repo.save(makeMessage(id: id, createdAt: sameInstant));
      }

      final rows = await db.query('chat_messages', orderBy: 'id ASC');
      expect(rows.map((row) => row['seq']), [1, 2, 3]);
    });

    test('re-saving a stored id keeps its place in the history', () async {
      // `save` replaces on conflict, so a replayed write must not hand the
      // message a fresh `seq` and move it to the end of the transcript.
      final db = await openTestDb();
      final repo = ChatRepo(db);
      final sameInstant = DateTime.fromMillisecondsSinceEpoch(1000);
      await repo.save(makeMessage(id: 'm1', createdAt: sameInstant, text: 'Q'));
      await repo.save(makeMessage(id: 'm2', createdAt: sameInstant, text: 'A'));

      await repo.save(
        makeMessage(id: 'm1', createdAt: sameInstant, text: 'Q edited'),
      );

      expect((await repo.all()).map((m) => m.text), ['Q edited', 'A']);
    });

    test('the newest messages are the ones kept when limit bites', () async {
      // Same instant throughout, so only `seq` can tell the two ends of the
      // history apart -- which is what makes `limit` mean "the recent end".
      final db = await openTestDb();
      final repo = ChatRepo(db);
      final sameInstant = DateTime.fromMillisecondsSinceEpoch(1000);
      for (final id in ['m1', 'm2', 'm3']) {
        await repo.save(
          makeMessage(id: id, createdAt: sameInstant, text: id),
        );
      }

      expect((await repo.all(limit: 2)).map((m) => m.text), ['m2', 'm3']);
    });
  });

  group('ChatRepo.save/all', () {
    test('round trips a message', () async {
      final db = await openTestDb();
      final repo = ChatRepo(db);

      await repo.save(makeMessage(
        id: 'msg1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        text: 'hi there',
        conversationId: 'c1',
      ));

      final all = await repo.all();
      expect(all, hasLength(1));
      expect(all.single.id, 'msg1');
      expect(all.single.text, 'hi there');
      expect(all.single.conversationId, 'c1');
    });

    test('round trips an assistant message with no conversation', () async {
      // The other half of the row mapping: `is_user` is an INTEGER column and
      // `conversation_id` is nullable, so a reply about the whole library has
      // to come back as `isUser: false` with a null id rather than defaulting.
      final db = await openTestDb();
      final repo = ChatRepo(db);

      await repo.save(makeMessage(
        id: 'msg1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        text: 'you said you drink tea',
        isUser: false,
      ));

      final restored = (await repo.all()).single;
      expect(restored.isUser, isFalse);
      expect(restored.conversationId, isNull);
      expect(restored.text, 'you said you drink tea');
    });

    test('orders oldest first, by insertion order', () async {
      // Since schema v6 the order is the one the messages were saved in, not
      // the one their timestamps or ids happen to sort in -- the rows below
      // disagree on both counts.
      final db = await openTestDb();
      final repo = ChatRepo(db);

      await repo.save(makeMessage(
        id: 'b',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));
      await repo.save(makeMessage(
        id: 'a',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));
      await repo.save(makeMessage(
        id: 'z',
        createdAt: DateTime.fromMillisecondsSinceEpoch(500),
      ));

      final all = await repo.all();
      expect(all.map((m) => m.id).toList(), ['b', 'a', 'z']);
    });

    test('respects limit', () async {
      final db = await openTestDb();
      final repo = ChatRepo(db);

      for (var i = 0; i < 5; i++) {
        await repo.save(makeMessage(
          id: 'm$i',
          createdAt: DateTime.fromMillisecondsSinceEpoch(1000 * i),
        ));
      }

      expect(await repo.all(limit: 2), hasLength(2));
    });

    test('keeps the newest messages when the limit is hit', () async {
      // The limit is a window on the recent end of the history: a chat view
      // and a backup both want the latest messages, not the first ones ever
      // written.
      final db = await openTestDb();
      final repo = ChatRepo(db);
      for (var i = 0; i < 5; i++) {
        await repo.save(makeMessage(
          id: 'm$i',
          createdAt: DateTime.fromMillisecondsSinceEpoch(1000 * (i + 1)),
        ));
      }

      final recent = await repo.all(limit: 2);

      expect(recent.map((m) => m.id), <String>['m3', 'm4']);
    });

    test('save replaces an existing row with the same id', () async {
      final db = await openTestDb();
      final repo = ChatRepo(db);

      await repo.save(makeMessage(
        id: 'm1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        text: 'first',
      ));
      await repo.save(makeMessage(
        id: 'm1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        text: 'second',
      ));

      final all = await repo.all();
      expect(all, hasLength(1));
      expect(all.single.text, 'second');
    });
  });

  group('ChatRepo.delete/clear', () {
    test('delete removes one row', () async {
      final db = await openTestDb();
      final repo = ChatRepo(db);

      await repo.save(makeMessage(
        id: 'm1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));
      await repo.save(makeMessage(
        id: 'm2',
        createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
      ));

      await repo.delete('m1');

      final all = await repo.all();
      expect(all.map((m) => m.id).toList(), ['m2']);
    });

    test('clear removes every row', () async {
      final db = await openTestDb();
      final repo = ChatRepo(db);

      await repo.save(makeMessage(
        id: 'm1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));
      await repo.save(makeMessage(
        id: 'm2',
        createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
      ));

      await repo.clear();

      expect(await repo.all(), isEmpty);
    });
  });
}
