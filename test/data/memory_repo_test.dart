import 'package:flutter_test/flutter_test.dart';

import 'package:libreomi/data/memory_repo.dart';
import 'package:libreomi/models/conversation.dart';

import 'test_db.dart';

void main() {
  useFfiDatabaseFactory();

  Memory makeMemory({
    required String id,
    required String content,
    required DateTime createdAt,
    String category = 'fact',
  }) {
    return Memory(
      id: id,
      content: content,
      category: category,
      createdAt: createdAt,
      sourceConversationId: null,
    );
  }

  group('MemoryRepo.save/all/delete/updateContent', () {
    test('round trips a memory', () async {
      final db = await openTestDb();
      final repo = MemoryRepo(db);

      await repo.save(makeMemory(
        id: 'm1',
        content: 'User likes tea',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      final all = await repo.all();
      expect(all, hasLength(1));
      expect(all.single.id, 'm1');
      expect(all.single.content, 'User likes tea');
    });

    test('all orders by created_at DESC and respects limit', () async {
      final db = await openTestDb();
      final repo = MemoryRepo(db);

      await repo.save(makeMemory(
        id: 'm1',
        content: 'a',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));
      await repo.save(makeMemory(
        id: 'm2',
        content: 'b',
        createdAt: DateTime.fromMillisecondsSinceEpoch(3000),
      ));
      await repo.save(makeMemory(
        id: 'm3',
        content: 'c',
        createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
      ));

      final all = await repo.all();
      expect(all.map((m) => m.id).toList(), ['m2', 'm3', 'm1']);

      final limited = await repo.all(limit: 2);
      expect(limited.map((m) => m.id).toList(), ['m2', 'm3']);
    });

    test('delete removes the row', () async {
      final db = await openTestDb();
      final repo = MemoryRepo(db);

      await repo.save(makeMemory(
        id: 'm1',
        content: 'a',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));
      await repo.delete('m1');

      expect(await repo.all(), isEmpty);
    });

    test('updateContent changes only the content', () async {
      final db = await openTestDb();
      final repo = MemoryRepo(db);

      await repo.save(makeMemory(
        id: 'm1',
        content: 'old',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));
      await repo.updateContent('m1', 'new');

      final all = await repo.all();
      expect(all.single.content, 'new');
    });
  });

  group('MemoryRepo.hasSimilar', () {
    test('is case-insensitive and trims whitespace for exact matches',
        () async {
      final db = await openTestDb();
      final repo = MemoryRepo(db);

      await repo.save(makeMemory(
        id: 'm1',
        content: '  User Likes Tea  ',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      expect(await repo.hasSimilar('user likes tea'), isTrue);
    });

    test('matches when the new content is a substring of an existing one',
        () async {
      final db = await openTestDb();
      final repo = MemoryRepo(db);

      await repo.save(makeMemory(
        id: 'm1',
        content: 'User likes tea very much',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      expect(await repo.hasSimilar('likes tea'), isTrue);
    });

    test('matches when an existing content is a substring of the new one',
        () async {
      final db = await openTestDb();
      final repo = MemoryRepo(db);

      await repo.save(makeMemory(
        id: 'm1',
        content: 'likes tea',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      expect(await repo.hasSimilar('User likes tea very much'), isTrue);
    });

    test('returns false when nothing is similar', () async {
      final db = await openTestDb();
      final repo = MemoryRepo(db);

      await repo.save(makeMemory(
        id: 'm1',
        content: 'likes coffee',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      expect(await repo.hasSimilar('dislikes rain'), isFalse);
    });
  });
}
