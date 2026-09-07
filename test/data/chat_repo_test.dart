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

    test('orders oldest first, using id as a tiebreaker', () async {
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
      // created_at 500 first, then the two tied at 1000 broken by id ASC.
      expect(all.map((m) => m.id).toList(), ['z', 'a', 'b']);
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
