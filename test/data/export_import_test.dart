import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

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
        description: 'Semi-skimmed, the big carton',
        createdAt: DateTime.fromMillisecondsSinceEpoch(3000),
        dueDate: DateTime.fromMillisecondsSinceEpoch(9000),
        sourceConversationId: 'c1',
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

      // Every column of every row, so a field dropped from the format or the
      // importer's row builder fails here rather than surviving because the
      // assertions below happen not to name it.
      final before = await _snapshot(source);

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

      expect(await _snapshot(target), before);

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

  group('chat message order (LO-65)', () {
    ChatMessage message(String id, {int createdAt = 1000}) => ChatMessage(
          id: id,
          text: id,
          isUser: true,
          createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
        );

    Future<List<String>> chatTexts(Database db) async =>
        (await ChatRepo(db).all()).map((m) => m.text).toList();

    test('the exported chat array is in insertion order', () async {
      // Every message shares a `created_at`, so ordering the export by the
      // timestamp would leave the array in an arbitrary order and the file
      // would carry no record of how the conversation actually ran.
      final db = await openTestDb();
      for (final id in ['c', 'a', 'b']) {
        await ChatRepo(db).save(message(id));
      }

      final document = await exportAll(db);

      expect(
        (document['chat_messages'] as List)
            .map((row) => (row as Map)['id'])
            .toList(),
        ['c', 'a', 'b'],
      );
    });

    test('a replace import restores the order the file was written in',
        () async {
      final source = await openTestDb();
      for (final id in ['first', 'second', 'third']) {
        await ChatRepo(source).save(message(id));
      }
      final document = await exportAll(source);

      final target = await openTestDb();
      await importAll(target, document, mode: ImportMode.replace);

      expect(await chatTexts(target), ['first', 'second', 'third']);
    });

    test('a file written before schema v6 keeps its array order', () async {
      // What a backup taken by the first release looks like: no `seq` on any
      // row, tied timestamps, and ids that sort the other way round. The
      // array positions are the only record of the order left.
      final db = await openTestDb();
      final document = <String, dynamic>{
        'format_version': 1,
        'chat_messages': [
          {'id': 'z', 'text': 'Q', 'is_user': 1, 'created_at': 1000},
          {'id': 'a', 'text': 'A', 'is_user': 0, 'created_at': 1000},
        ],
      };

      final report = await importAll(db, document);

      expect(report.skipped, 0);
      expect(await chatTexts(db), ['Q', 'A']);
    });

    test('a merge puts the imported history after the stored one', () async {
      // The seq values in the file start at 1 and would otherwise collide with
      // the rows already here, leaving the merged transcript interleaved.
      final db = await openTestDb();
      await ChatRepo(db).save(message('already here'));
      final source = await openTestDb();
      for (final id in ['imported 1', 'imported 2']) {
        await ChatRepo(source).save(message(id));
      }

      await importAll(db, await exportAll(source));

      expect(await chatTexts(db), [
        'already here',
        'imported 1',
        'imported 2',
      ]);
    });

    test('a partially stamped file still gives every row a distinct seq',
        () async {
      // A hand-edited document: one row carries a `seq`, the next does not.
      // The fallback counter has to step past the value already handed out
      // instead of reusing it.
      final db = await openTestDb();
      final document = <String, dynamic>{
        'format_version': 1,
        'chat_messages': [
          {'id': 'm1', 'text': 'one', 'is_user': 1, 'created_at': 1000},
          {
            'id': 'm2',
            'text': 'two',
            'is_user': 1,
            'created_at': 1000,
            'seq': 7,
          },
          {'id': 'm3', 'text': 'three', 'is_user': 1, 'created_at': 1000},
        ],
      };

      await importAll(db, document);

      final seqs = (await db.query('chat_messages', orderBy: 'seq ASC'))
          .map((row) => row['seq'])
          .toList();
      expect(seqs.toSet(), hasLength(3));
      expect(await chatTexts(db), ['one', 'two', 'three']);
    });
  });
}

/// Every row of every exported table, keyed by table and ordered by id, as the
/// database itself stores it. Comparing two of these is the strongest form of
/// "the round trip kept all rows" available without reimplementing the format.
Future<Map<String, List<Map<String, Object?>>>> _snapshot(Database db) async {
  final tables = ['conversations', 'memories', 'tasks', 'chat_messages'];
  return {
    for (final table in tables) table: await db.query(table, orderBy: 'id'),
  };
}
