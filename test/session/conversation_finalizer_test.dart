import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import 'package:libreomi/core/clock.dart';
import 'package:libreomi/core/ids.dart';
import 'package:libreomi/data/conversation_repo.dart';
import 'package:libreomi/data/memory_repo.dart';
import 'package:libreomi/data/task_repo.dart';
import 'package:libreomi/intelligence/llm_client.dart';
import 'package:libreomi/models/conversation.dart';
import 'package:libreomi/services/notification_ids.dart';
import 'package:libreomi/session/conversation_finalizer.dart';

import '../data/test_db.dart';

/// A deterministic [IdGenerator] for stable assertions: each call returns
/// the next id from a fixed sequence.
class FakeIdGenerator implements IdGenerator {
  FakeIdGenerator(this._ids);

  final List<String> _ids;
  int _index = 0;

  @override
  String newId() => _ids[_index++];
}

class _ScheduledReminder {
  _ScheduledReminder({required this.id, required this.title, required this.dueDate});

  final int id;
  final String title;
  final DateTime dueDate;
}

void main() {
  useFfiDatabaseFactory();

  late Database db;
  late List<Conversation> enqueued;
  late List<_ScheduledReminder> reminders;
  late int conversationSavedCalls;
  late int insightsAppliedCalls;
  late FakeIdGenerator ids;
  late FixedClock clock;
  late ConversationFinalizer finalizer;
  late Future<void> Function(Conversation) enqueuer;

  setUp(() async {
    db = await openTestDb();
    enqueued = [];
    reminders = [];
    conversationSavedCalls = 0;
    insightsAppliedCalls = 0;
    ids = FakeIdGenerator(['memory-1', 'memory-2', 'task-1', 'task-2', 'task-3']);
    clock = FixedClock(DateTime(2026, 1, 1, 12));
    enqueuer = (conversation) async {
      enqueued.add(conversation);
    };

    finalizer = ConversationFinalizer(
      database: () async => db,
      enqueue: (conversation) => enqueuer(conversation),
      scheduleReminder: ({required id, required title, required dueDate}) async {
        reminders.add(_ScheduledReminder(id: id, title: title, dueDate: dueDate));
      },
      ids: ids,
      clock: clock,
      onConversationSaved: () async {
        conversationSavedCalls++;
      },
      onInsightsApplied: () async {
        insightsAppliedCalls++;
      },
    );
  });

  group('finalize', () {
    test('fills a placeholder title for a title-less conversation and enqueues it once', () async {
      final conversation = Conversation(
        id: 'c1',
        createdAt: DateTime(2026, 3, 4, 10, 30),
      );

      await finalizer.finalize(conversation);

      final expectedTitle =
          'Conversation ${conversation.createdAt.toString().substring(0, 16)}';
      expect(conversation.title, expectedTitle);

      final stored = await ConversationRepo(db).byId('c1');
      expect(stored, isNotNull);
      expect(stored!.title, expectedTitle);

      expect(enqueued, hasLength(1));
      expect(enqueued.single.id, 'c1');
      expect(conversationSavedCalls, 1);
    });

    test('keeps an already-set title (SD-card path)', () async {
      final conversation = Conversation(
        id: 'c2',
        createdAt: DateTime(2026, 3, 4, 10, 30),
        title: 'SD Card Recording',
      );

      await finalizer.finalize(conversation);

      expect(conversation.title, 'SD Card Recording');
      final stored = await ConversationRepo(db).byId('c2');
      expect(stored!.title, 'SD Card Recording');
    });

    test('an enqueuer that throws does not prevent the conversation from being persisted', () async {
      enqueuer = (conversation) async {
        throw Exception('queue insert failed');
      };
      final conversation = Conversation(
        id: 'c3',
        createdAt: DateTime(2026, 3, 4, 10, 30),
      );

      await finalizer.finalize(conversation);

      final stored = await ConversationRepo(db).byId('c3');
      expect(stored, isNotNull);
    });
  });

  group('applyInsights', () {
    Future<void> seedConversation(String id, {String title = ''}) async {
      await ConversationRepo(db).save(Conversation(
        id: id,
        createdAt: DateTime(2026, 1, 1),
        title: title,
      ));
    }

    test('updates title and summary of the stored row', () async {
      await seedConversation('conv-1');

      await finalizer.applyInsights(
        'conv-1',
        const ConversationInsights(
          title: 'New Title',
          summary: 'A short summary',
          memories: [],
          tasks: [],
        ),
      );

      final stored = await ConversationRepo(db).byId('conv-1');
      expect(stored!.title, 'New Title');
      expect(stored.summary, 'A short summary');
    });

    test('stores the trimmed title, as the pre-LO-33 code did', () async {
      await seedConversation('conv-trim');

      await finalizer.applyInsights(
        'conv-trim',
        const ConversationInsights(
          title: '  Trip planning\n',
          summary: '',
          memories: [],
          tasks: [],
        ),
      );

      expect((await ConversationRepo(db).byId('conv-trim'))!.title, 'Trip planning');
    });

    test('a blank title leaves the placeholder the save wrote', () async {
      await seedConversation('conv-blank', title: 'Conversation 2026-01-01 00:00');

      await finalizer.applyInsights(
        'conv-blank',
        const ConversationInsights(
          title: '   ',
          summary: 'A summary the model did produce',
          memories: [],
          tasks: [],
        ),
      );

      final stored = await ConversationRepo(db).byId('conv-blank');
      // Only the title is protected: the summary is applied either way, which
      // is what `_applyFinalizationResult` did.
      expect(stored!.title, 'Conversation 2026-01-01 00:00');
      expect(stored.summary, 'A summary the model did produce');
    });

    test('stores a new memory with category fact and skips a near-duplicate', () async {
      await seedConversation('conv-2');
      await MemoryRepo(db).save(Memory(
        id: 'existing-memory',
        content: 'User likes coffee',
        category: 'fact',
        createdAt: DateTime(2026, 1, 1),
      ));

      await finalizer.applyInsights(
        'conv-2',
        const ConversationInsights(
          title: '',
          summary: '',
          memories: ['User likes coffee in the morning', 'User owns a cat'],
          tasks: [],
        ),
      );

      final memories = await MemoryRepo(db).all();
      // The seeded memory, plus exactly one new one (the coffee variant is a
      // substring-match duplicate of the seeded memory and must be skipped).
      expect(memories, hasLength(2));
      final newMemory = memories.firstWhere((m) => m.id != 'existing-memory');
      expect(newMemory.content, 'User owns a cat');
      expect(newMemory.category, 'fact');
      expect(newMemory.createdAt, clock.now());
    });

    test('stores a new task, skips a duplicate, and schedules exactly one reminder for a due date', () async {
      await seedConversation('conv-3');
      await TaskRepo(db).save(Task(
        id: 'existing-task',
        title: 'Buy milk',
        createdAt: DateTime(2026, 1, 1),
      ));

      final dueDate = DateTime(2026, 2, 1, 9);
      await finalizer.applyInsights(
        'conv-3',
        ConversationInsights(
          title: '',
          summary: '',
          memories: const [],
          tasks: [
            const TaskDraft(title: 'Buy milk today'), // duplicate, skipped
            TaskDraft(title: 'Call the dentist', dueDate: dueDate),
          ],
        ),
      );

      final tasks = await TaskRepo(db).all();
      expect(tasks, hasLength(2));
      final saved = tasks.firstWhere((t) => t.id != 'existing-task');
      expect(saved.title, 'Call the dentist');
      expect(saved.dueDate, dueDate);

      expect(reminders, hasLength(1));
      expect(reminders.single.title, 'Call the dentist');
      expect(reminders.single.dueDate, dueDate);
      expect(reminders.single.id, notificationIdForTask(saved));
    });

    test('is a silent no-op for a conversation id that is not in the database', () async {
      await finalizer.applyInsights(
        'missing-conversation',
        const ConversationInsights(
          title: 'Should not be applied',
          summary: 'Should not be applied',
          memories: ['Should not be saved'],
          tasks: [TaskDraft(title: 'Should not be saved')],
        ),
      );

      expect(await MemoryRepo(db).all(), isEmpty);
      expect(await TaskRepo(db).all(), isEmpty);
      expect(reminders, isEmpty);
      expect(insightsAppliedCalls, 0);
    });

    test('invokes onInsightsApplied', () async {
      await seedConversation('conv-4');

      await finalizer.applyInsights(
        'conv-4',
        const ConversationInsights(
          title: 'T',
          summary: 'S',
          memories: [],
          tasks: [],
        ),
      );

      expect(insightsAppliedCalls, 1);
    });
  });
}
