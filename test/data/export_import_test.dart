import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:libreomi/data/chat_repo.dart';
import 'package:libreomi/data/conversation_repo.dart';
import 'package:libreomi/data/export_import.dart';
import 'package:libreomi/data/memory_repo.dart';
import 'package:libreomi/data/task_repo.dart';
import 'package:libreomi/models/conversation.dart';

import 'test_db.dart';

void main() {
  useFfiDatabaseFactory();

  group('exportFileName', () {
    test('formats the local timestamp', () {
      expect(
        exportFileName(DateTime(2026, 9, 8, 14, 32)),
        'libreomi-export-20260908-1432.json',
      );
    });
  });

  group('exportAll / importAll round trip', () {
    test('every row comes back identical via replace into an empty db',
        () async {
      final source = await openTestDb();
      final target = await openTestDb();

      final conversation = Conversation(
        id: 'c1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        title: 'Standup',
        summary: 'Discussed roadmap',
        segments: [
          TranscriptSegment(
            text: 'hello',
            speakerId: 0,
            startTime: 0,
            endTime: 1,
            isUser: true,
          ),
          TranscriptSegment(
            text: 'hi there',
            speakerId: 1,
            startTime: 1,
            endTime: 2,
          ),
        ],
      );
      await ConversationRepo(source).save(conversation);

      final memory = Memory(
        id: 'm1',
        content: 'User likes tea',
        category: 'preference',
        createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
        sourceConversationId: 'c1',
      );
      await MemoryRepo(source).save(memory);

      final dueTask = Task(
        id: 't1',
        title: 'Buy milk',
        createdAt: DateTime.fromMillisecondsSinceEpoch(3000),
        dueDate: DateTime.fromMillisecondsSinceEpoch(9000),
      );
      final completedTask = Task(
        id: 't2',
        title: 'Send report',
        createdAt: DateTime.fromMillisecondsSinceEpoch(4000),
        isCompleted: true,
      );
      final notifiedTask = Task(
        id: 't3',
        title: 'Call back',
        createdAt: DateTime.fromMillisecondsSinceEpoch(5000),
        notificationId: 999,
      );
      await TaskRepo(source).save(dueTask);
      await TaskRepo(source).save(completedTask);
      await TaskRepo(source).save(notifiedTask);

      final chatFromUser = ChatMessage(
        id: 'ch1',
        text: 'What did I say?',
        isUser: true,
        createdAt: DateTime.fromMillisecondsSinceEpoch(6000),
        conversationId: 'c1',
      );
      final chatReply = ChatMessage(
        id: 'ch2',
        text: 'You said hello',
        isUser: false,
        createdAt: DateTime.fromMillisecondsSinceEpoch(7000),
      );
      await ChatRepo(source).save(chatFromUser);
      await ChatRepo(source).save(chatReply);

      // Round-trip the document through JSON, the way a real export/import
      // does via a file, rather than handing importAll the in-memory map
      // exportAll built.
      final document =
          jsonDecode(jsonEncode(await exportAll(source))) as Map<String, dynamic>;

      final report =
          await importAll(target, document, mode: ImportMode.replace);
      expect(report.inserted, 7);
      expect(report.updated, 0);
      expect(report.skipped, 0);
      expect(report.errors, isEmpty);

      final conversations = await ConversationRepo(target).all();
      expect(conversations, hasLength(1));
      final importedConversation = conversations.single;
      expect(importedConversation.id, 'c1');
      expect(importedConversation.title, 'Standup');
      expect(importedConversation.summary, 'Discussed roadmap');
      expect(importedConversation.segments, hasLength(2));
      expect(importedConversation.segments[0].text, 'hello');
      expect(importedConversation.segments[0].isUser, isTrue);
      expect(importedConversation.segments[1].text, 'hi there');
      expect(importedConversation.segments[1].isUser, isFalse);

      final memories = await MemoryRepo(target).all();
      expect(memories, hasLength(1));
      expect(memories.single.content, 'User likes tea');
      expect(memories.single.category, 'preference');
      expect(memories.single.sourceConversationId, 'c1');

      final tasksById = {
        for (final task in await TaskRepo(target).all()) task.id: task,
      };
      expect(tasksById.keys, containsAll(['t1', 't2', 't3']));
      expect(
        tasksById['t1']!.dueDate!.millisecondsSinceEpoch,
        dueTask.dueDate!.millisecondsSinceEpoch,
      );
      expect(tasksById['t1']!.isCompleted, isFalse);
      expect(tasksById['t2']!.isCompleted, isTrue);
      expect(tasksById['t3']!.notificationId, 999);

      final chatsById = {
        for (final message in await ChatRepo(target).all()) message.id: message,
      };
      expect(chatsById['ch1']!.isUser, isTrue);
      expect(chatsById['ch1']!.conversationId, 'c1');
      expect(chatsById['ch1']!.text, 'What did I say?');
      expect(chatsById['ch2']!.isUser, isFalse);
      expect(chatsById['ch2']!.conversationId, isNull);
    });
  });

  group('ImportMode.merge', () {
    test('keeps untouched rows, inserts new ids and overwrites existing ones',
        () async {
      final db = await openTestDb();
      await MemoryRepo(db).save(Memory(
        id: 'keep',
        content: 'kept memory',
        category: 'fact',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));
      await MemoryRepo(db).save(Memory(
        id: 'old',
        content: 'old content',
        category: 'fact',
        createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
      ));

      final document = {
        'format_version': 1,
        'memories': [
          {
            'id': 'old',
            'content': 'new content',
            'category': 'fact',
            'created_at': 2000,
          },
          {
            'id': 'new',
            'content': 'brand new',
            'category': 'fact',
            'created_at': 3000,
          },
        ],
      };

      final report = await importAll(db, document, mode: ImportMode.merge);
      expect(report.inserted, 1);
      expect(report.updated, 1);
      expect(report.skipped, 0);

      final memoriesById = {
        for (final memory in await MemoryRepo(db).all()) memory.id: memory,
      };
      expect(memoriesById.keys, containsAll(['keep', 'old', 'new']));
      expect(memoriesById['keep']!.content, 'kept memory');
      expect(memoriesById['old']!.content, 'new content');
      expect(memoriesById['new']!.content, 'brand new');
    });
  });

  group('ImportMode.replace', () {
    test('empties all four exported tables, including ones the document '
        'does not mention', () async {
      final db = await openTestDb();
      await TaskRepo(db).save(Task(
        id: 't1',
        title: 'old task',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));
      await ConversationRepo(db).save(Conversation(
        id: 'c1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));
      await ChatRepo(db).save(ChatMessage(
        id: 'ch1',
        text: 'hi',
        isUser: true,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      final document = {
        'format_version': 1,
        'memories': [
          {
            'id': 'm1',
            'content': 'only memory',
            'category': 'fact',
            'created_at': 1000,
          },
        ],
      };

      await importAll(db, document, mode: ImportMode.replace);

      expect(await TaskRepo(db).all(), isEmpty);
      expect(await ConversationRepo(db).all(), isEmpty);
      expect(await ChatRepo(db).all(), isEmpty);
      expect(
        (await MemoryRepo(db).all()).map((memory) => memory.id),
        ['m1'],
      );
    });
  });

  group('pending_finalizations', () {
    test('is neither exported nor touched by an import, in either mode',
        () async {
      final db = await openTestDb();
      await db.insert('pending_finalizations', {
        'id': 'pf1',
        'conversation_id': 'c1',
        'transcript': '[]',
        'attempts': 0,
        'next_attempt_at': 1000,
        'created_at': 1000,
      });

      final exported = await exportAll(db);
      expect(exported.containsKey('pending_finalizations'), isFalse);

      await importAll(
        db,
        {'format_version': 1, 'memories': <Object?>[]},
        mode: ImportMode.merge,
      );
      expect(await db.query('pending_finalizations'), hasLength(1));

      await importAll(
        db,
        {'format_version': 1, 'memories': <Object?>[]},
        mode: ImportMode.replace,
      );
      expect(await db.query('pending_finalizations'), hasLength(1));
    });
  });

  group('malformed documents throw ImportFormatException, unchanged db', () {
    test('an unsupported format_version', () async {
      final db = await openTestDb();
      await MemoryRepo(db).save(Memory(
        id: 'm1',
        content: 'existing',
        category: 'fact',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      await expectLater(
        importAll(db, {
          'format_version': 99,
          'memories': <Object?>[
            {
              'id': 'm2',
              'content': 'new',
              'category': 'fact',
              'created_at': 2000,
            },
          ],
        }),
        throwsA(isA<ImportFormatException>()),
      );
      final memories = await MemoryRepo(db).all();
      expect(memories, hasLength(1));
      expect(memories.single.id, 'm1');
    });

    test('a table key whose value is not a list', () async {
      final db = await openTestDb();
      await expectLater(
        importAll(db, {'format_version': 1, 'memories': 'not-a-list'}),
        throwsA(isA<ImportFormatException>()),
      );
      expect(await MemoryRepo(db).all(), isEmpty);
    });

    test('a document with none of the four table keys', () async {
      final db = await openTestDb();
      await expectLater(
        importAll(db, {'format_version': 1, 'unrelated': 'x'}),
        throwsA(isA<ImportFormatException>()),
      );
    });
  });

  group('malformed rows are skipped and counted', () {
    test('bad rows are skipped, the valid row in the same document imports',
        () async {
      final db = await openTestDb();
      final document = {
        'format_version': 1,
        'memories': <Object?>[
          'not-an-object',
          {'content': 'no id', 'category': 'fact', 'created_at': 1000},
          {'id': 'm3', 'content': 'no created_at', 'category': 'fact'},
          {'id': 'm4', 'category': 'fact', 'created_at': 1000},
          {
            'id': 'm5',
            'content': 'good memory',
            'category': 'fact',
            'created_at': 1000,
          },
        ],
      };

      final report = await importAll(db, document, mode: ImportMode.merge);
      expect(report.skipped, 4);
      expect(report.inserted, 1);
      expect(report.updated, 0);
      expect(report.errors, isNotEmpty);

      final memories = await MemoryRepo(db).all();
      expect(memories.map((memory) => memory.id), ['m5']);
    });
  });

  group('pre-LO-61 backups without format_version', () {
    test('are accepted and imported as version 1', () async {
      final db = await openTestDb();
      final document = {
        'memories': <Object?>[
          {
            'id': 'm1',
            'content': 'legacy memory',
            'category': 'fact',
            'created_at': 1000,
          },
        ],
      };

      final report = await importAll(db, document);
      expect(report.inserted, 1);
      expect(report.skipped, 0);

      final memories = await MemoryRepo(db).all();
      expect(memories, hasLength(1));
      expect(memories.single.content, 'legacy memory');
    });
  });
}
