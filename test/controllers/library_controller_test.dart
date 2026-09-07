import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import 'package:libreomi/controllers/library_controller.dart';
import 'package:libreomi/data/chat_repo.dart';
import 'package:libreomi/data/conversation_repo.dart';
import 'package:libreomi/data/memory_repo.dart';
import 'package:libreomi/data/task_repo.dart';
import 'package:libreomi/models/conversation.dart';
import 'package:libreomi/services/notification_ids.dart';

import '../data/test_db.dart';

class _ScheduledReminder {
  _ScheduledReminder({required this.id, required this.title, required this.dueDate});

  final int id;
  final String title;
  final DateTime dueDate;
}

void main() {
  useFfiDatabaseFactory();

  late Database db;
  late List<int> cancelledIds;
  late List<_ScheduledReminder> scheduledReminders;
  late LibraryController controller;

  setUp(() async {
    db = await openTestDb();
    cancelledIds = [];
    scheduledReminders = [];

    controller = LibraryController(
      database: () async => db,
      cancelReminder: (id) async {
        cancelledIds.add(id);
      },
      scheduleReminder: ({required id, required title, required dueDate}) async {
        scheduledReminders.add(_ScheduledReminder(id: id, title: title, dueDate: dueDate));
      },
    );
  });

  test('loadConversations / loadMemories / loadTasks read what was seeded', () async {
    await ConversationRepo(db).save(
      Conversation(id: 'c1', createdAt: DateTime(2026, 1, 1), title: 'Standup'),
    );
    await MemoryRepo(db).save(
      Memory(id: 'm1', content: 'Likes tea', category: 'fact', createdAt: DateTime(2026, 1, 1)),
    );
    await TaskRepo(db).save(
      Task(id: 't1', title: 'Buy milk', createdAt: DateTime(2026, 1, 1)),
    );

    await controller.loadConversations();
    await controller.loadMemories();
    await controller.loadTasks();

    expect(controller.conversations.map((c) => c.id), ['c1']);
    expect(controller.memories.map((m) => m.id), ['m1']);
    expect(controller.tasks.map((t) => t.id), ['t1']);
  });

  test('reloadAll loads conversations, memories and tasks together', () async {
    await ConversationRepo(db).save(
      Conversation(id: 'c1', createdAt: DateTime(2026, 1, 1)),
    );
    await MemoryRepo(db).save(
      Memory(id: 'm1', content: 'x', category: 'fact', createdAt: DateTime(2026, 1, 1)),
    );
    await TaskRepo(db).save(Task(id: 't1', title: 'x', createdAt: DateTime(2026, 1, 1)));

    await controller.reloadAll();

    expect(controller.conversations, hasLength(1));
    expect(controller.memories, hasLength(1));
    expect(controller.tasks, hasLength(1));
  });

  test('deleteConversation removes the row and refreshes the list', () async {
    await ConversationRepo(db).save(Conversation(id: 'c1', createdAt: DateTime(2026, 1, 1)));
    await controller.loadConversations();
    expect(controller.conversations, hasLength(1));

    await controller.deleteConversation('c1');

    expect(controller.conversations, isEmpty);
    expect(await ConversationRepo(db).byId('c1'), isNull);
  });

  test('addMemory stores a trimmed manual memory and refreshes the list', () async {
    await controller.addMemory('  loves coffee  ');

    expect(controller.memories, hasLength(1));
    expect(controller.memories.single.content, 'loves coffee');
    expect(controller.memories.single.category, 'manual');
  });

  test('updateMemory persists the new content and refreshes the list', () async {
    await MemoryRepo(db).save(
      Memory(id: 'm1', content: 'old', category: 'fact', createdAt: DateTime(2026, 1, 1)),
    );

    await controller.updateMemory('m1', 'new');

    expect(controller.memories.single.content, 'new');
  });

  test('deleteMemory removes the row and refreshes the list', () async {
    await MemoryRepo(db).save(
      Memory(id: 'm1', content: 'x', category: 'fact', createdAt: DateTime(2026, 1, 1)),
    );

    await controller.deleteMemory('m1');

    expect(controller.memories, isEmpty);
    expect(await MemoryRepo(db).all(), isEmpty);
  });

  test('deleteTask cancels the reminder using notificationIdForTask before deleting', () async {
    final task = Task(
      id: 't1',
      title: 'Call back',
      createdAt: DateTime(2026, 1, 1),
      notificationId: 4242,
    );
    await TaskRepo(db).save(task);
    await controller.loadTasks();

    await controller.deleteTask('t1');

    expect(cancelledIds, [notificationIdForTask(task)]);
    expect(controller.tasks, isEmpty);
    expect(await TaskRepo(db).all(), isEmpty);
  });

  test('toggleTaskCompletion(false) reschedules a future-dated task', () async {
    final dueDate = DateTime.now().add(const Duration(days: 1));
    final task = Task(
      id: 't1',
      title: 'Follow up',
      dueDate: dueDate,
      createdAt: DateTime(2026, 1, 1),
      isCompleted: true,
      notificationId: 99,
    );
    await TaskRepo(db).save(task);
    await controller.loadTasks();

    await controller.toggleTaskCompletion('t1', false);

    expect(scheduledReminders, hasLength(1));
    expect(scheduledReminders.single.id, 99);
    expect(scheduledReminders.single.title, 'Follow up');
    expect(controller.tasks.single.isCompleted, isFalse);
  });

  test('toggleTaskCompletion(true) cancels the reminder', () async {
    final task = Task(
      id: 't1',
      title: 'Follow up',
      dueDate: DateTime.now().add(const Duration(days: 1)),
      createdAt: DateTime(2026, 1, 1),
      notificationId: 77,
    );
    await TaskRepo(db).save(task);
    await controller.loadTasks();

    await controller.toggleTaskCompletion('t1', true);

    expect(cancelledIds, [77]);
    expect(controller.tasks.single.isCompleted, isTrue);
  });

  test('exportAllData returns all four collections', () async {
    await ConversationRepo(db).save(Conversation(id: 'c1', createdAt: DateTime(2026, 1, 1)));
    await MemoryRepo(db).save(
      Memory(id: 'm1', content: 'x', category: 'fact', createdAt: DateTime(2026, 1, 1)),
    );
    await TaskRepo(db).save(Task(id: 't1', title: 'x', createdAt: DateTime(2026, 1, 1)));
    await ChatRepo(db).save(ChatMessage(
      id: 'cm1',
      text: 'what do I drink',
      isUser: true,
      createdAt: DateTime(2026, 1, 1),
    ));

    final export = await controller.exportAllData();

    expect(export['app_version'], '2.1.0');
    expect(export['export_date'], isA<String>());
    expect(export['conversations'], hasLength(1));
    expect(export['memories'], hasLength(1));
    expect(export['tasks'], hasLength(1));
    // Chat history is exported too: it was the collection LO-35 added last, so
    // an export that silently drops it is the plausible regression here.
    expect(export['chat_messages'], hasLength(1));
    expect(
      (export['chat_messages'] as List).single,
      containsPair('text', 'what do I drink'),
    );
    // The persisted reminder id has to survive an export/import round trip, or
    // a restored task would schedule under a different id.
    expect(
      (export['tasks'] as List).single,
      containsPair('notification_id', isA<int>()),
    );
  });
}
