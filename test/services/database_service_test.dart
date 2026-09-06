import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:libreomi/core/ids.dart';
import 'package:libreomi/data/db.dart';
import 'package:libreomi/models/conversation.dart';
import 'package:libreomi/services/database_service.dart';
import 'package:libreomi/services/notification_ids.dart';

/// LO-35 moved the SQL into `lib/data`, leaving `DatabaseService` as a facade
/// that every existing caller still uses. These tests go through the facade —
/// not the repositories — so a delegation wired to the wrong repo or dropped
/// on the way is caught here.

Task _task({
  required String id,
  required String title,
  DateTime? createdAt,
  bool isCompleted = false,
  int? notificationId,
}) =>
    Task(
      id: id,
      title: title,
      createdAt: createdAt ?? DateTime.fromMillisecondsSinceEpoch(1000),
      isCompleted: isCompleted,
      notificationId: notificationId,
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: AppDatabase.schemaVersion,
        singleInstance: false,
      ),
    );
    await AppDatabase.createSchema(db);
    AppDatabase.overrideForTests(db);
  });

  tearDown(() async {
    AppDatabase.overrideForTests(null);
    await db.close();
  });

  group('DatabaseService conversations', () {
    test('round trips a conversation with its segments', () async {
      await DatabaseService.saveConversation(Conversation(
        id: 'c1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
        title: 'Tea',
        summary: 'about tea',
        segments: [
          TranscriptSegment(
            text: 'hello',
            speakerId: 0,
            startTime: 0,
            endTime: 1.5,
          ),
        ],
      ));

      final restored = await DatabaseService.getConversation('c1');
      expect(restored, isNotNull);
      expect(restored!.title, 'Tea');
      expect(restored.segments.single.text, 'hello');
      expect(restored.segments.single.endTime, 1.5);
    });

    test('lists newest first, honours the limit, and deletes', () async {
      for (var i = 0; i < 3; i++) {
        await DatabaseService.saveConversation(Conversation(
          id: 'c$i',
          createdAt: DateTime.fromMillisecondsSinceEpoch(1000 * (i + 1)),
          title: 'c$i',
        ));
      }

      expect(
        (await DatabaseService.getConversations()).map((c) => c.id),
        <String>['c2', 'c1', 'c0'],
      );
      expect(await DatabaseService.getConversations(limit: 2), hasLength(2));

      await DatabaseService.deleteConversation('c2');
      expect(await DatabaseService.getConversation('c2'), isNull);
    });

    test('context text is empty with no conversations', () async {
      expect(await DatabaseService.getAllConversationsContext(), '');
    });

    test('context text carries title, summary and transcript', () async {
      await DatabaseService.saveConversation(Conversation(
        id: 'c1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
        title: 'Tea',
        summary: 'about tea',
        segments: [
          TranscriptSegment(
            text: 'I drink tea',
            speakerId: 1,
            startTime: 0,
            endTime: 1,
          ),
        ],
      ));

      final context = await DatabaseService.getAllConversationsContext();
      expect(context, contains('Title: Tea'));
      expect(context, contains('Summary: about tea'));
      expect(context, contains('Speaker 1: I drink tea'));
    });
  });

  group('DatabaseService memories', () {
    test('saves, lists, updates and deletes', () async {
      await DatabaseService.saveMemory(Memory(
        id: 'm1',
        content: 'User drinks tea',
        category: 'fact',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      expect((await DatabaseService.getMemories()).single.content,
          'User drinks tea');

      await DatabaseService.updateMemory('m1', 'User drinks coffee');
      expect((await DatabaseService.getMemories()).single.content,
          'User drinks coffee');

      await DatabaseService.deleteMemory('m1');
      expect(await DatabaseService.getMemories(), isEmpty);
    });

    test('dedup ignores case and matches either way round', () async {
      await DatabaseService.saveMemory(Memory(
        id: 'm1',
        content: 'User drinks tea',
        category: 'fact',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      expect(await DatabaseService.hasSimilarMemory('  user DRINKS tea '),
          isTrue);
      expect(await DatabaseService.hasSimilarMemory('drinks tea'), isTrue);
      expect(
        await DatabaseService.hasSimilarMemory('User drinks tea every morning'),
        isTrue,
      );
      expect(await DatabaseService.hasSimilarMemory('User plays chess'),
          isFalse);
    });
  });

  group('DatabaseService tasks', () {
    test('persists the notification id and reads it back', () async {
      final createdAt = DateTime.fromMillisecondsSinceEpoch(1757155845123);
      await DatabaseService.saveTask(_task(
        id: 't1',
        title: 'Buy milk',
        createdAt: createdAt,
      ));

      final restored = (await DatabaseService.getTasks()).single;
      expect(restored.notificationId, fallbackNotificationId(createdAt));
      // The id a caller gets is the same one the pre-v5 derivation produced,
      // so a reminder scheduled before the upgrade stays cancellable.
      expect(notificationIdForTask(restored),
          fallbackNotificationId(createdAt));
    });

    test('keeps an explicit notification id instead of deriving one', () async {
      await DatabaseService.saveTask(_task(
        id: 't1',
        title: 'Buy milk',
        notificationId: 4242,
      ));

      expect((await DatabaseService.getTasks()).single.notificationId, 4242);
    });

    test('lists incomplete first, then completes and deletes', () async {
      await DatabaseService.saveTask(_task(id: 't1', title: 'Buy milk'));
      await DatabaseService.saveTask(
          _task(id: 't2', title: 'Call plumber', isCompleted: true));

      expect(
        (await DatabaseService.getTasks()).map((t) => t.id),
        <String>['t1', 't2'],
      );

      await DatabaseService.updateTaskCompletion('t1', true);
      expect(
        (await DatabaseService.getTasks()).firstWhere((t) => t.id == 't1').isCompleted,
        isTrue,
      );

      await DatabaseService.deleteTask('t1');
      expect((await DatabaseService.getTasks()).map((t) => t.id), <String>['t2']);
    });

    test('dedup only looks at incomplete tasks', () async {
      await DatabaseService.saveTask(
          _task(id: 't1', title: 'Buy milk', isCompleted: true));

      expect(await DatabaseService.hasSimilarTask('buy milk'), isFalse);

      await DatabaseService.saveTask(_task(id: 't2', title: 'Buy milk'));
      expect(await DatabaseService.hasSimilarTask('buy milk'), isTrue);
    });
  });

  group('DatabaseService chat history', () {
    test('persists messages oldest first and clears them', () async {
      await DatabaseService.saveChatMessage(ChatMessage(
        id: 'cm2',
        text: 'you said you drink tea',
        isUser: false,
        createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
      ));
      await DatabaseService.saveChatMessage(ChatMessage(
        id: 'cm1',
        text: 'what do I drink',
        isUser: true,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        conversationId: 'c1',
      ));

      final messages = await DatabaseService.getChatMessages();
      expect(messages.map((m) => m.id), <String>['cm1', 'cm2']);
      expect(messages.first.isUser, isTrue);
      expect(messages.first.conversationId, 'c1');
      expect(messages.last.isUser, isFalse);
      expect(messages.last.conversationId, isNull);

      await DatabaseService.deleteChatMessage('cm1');
      expect(await DatabaseService.getChatMessages(), hasLength(1));

      await DatabaseService.clearChatMessages();
      expect(await DatabaseService.getChatMessages(), isEmpty);
    });
  });

  group('DatabaseService.exportAllData', () {
    test('includes every table, chat history among them', () async {
      await DatabaseService.saveConversation(Conversation(
        id: 'c1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        title: 'Tea',
      ));
      await DatabaseService.saveMemory(Memory(
        id: 'm1',
        content: 'User drinks tea',
        category: 'fact',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));
      await DatabaseService.saveTask(_task(id: 't1', title: 'Buy milk'));
      await DatabaseService.saveChatMessage(ChatMessage(
        id: 'cm1',
        text: 'what do I drink',
        isUser: true,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      final export = await DatabaseService.exportAllData();

      expect(export['conversations'], hasLength(1));
      expect(export['memories'], hasLength(1));
      expect(export['tasks'], hasLength(1));
      expect(export['chat_messages'], hasLength(1));
      expect((export['chat_messages'] as List).single,
          containsPair('text', 'what do I drink'));
      // The persisted reminder id has to survive an export/import round trip,
      // or a restored task would schedule under a different id.
      expect((export['tasks'] as List).single,
          containsPair('notification_id', isA<int>()));
      expect(export['export_date'], isA<String>());
    });
  });
}
