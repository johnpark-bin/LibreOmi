/// Owns the conversation / memory / task lists the pages read (LO-34, unit
/// 1 of the pre-LO-34 monolith's split, `docs/06-roadmap.md`).
///
/// Talks to `ConversationRepo`, `MemoryRepo`, `TaskRepo` and `ChatRepo`
/// directly, which is what let LO-64 delete the static database facade the old
/// monolith used.
library;

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../data/conversation_repo.dart';
import '../data/db.dart';
import '../data/export_import.dart';
import '../data/memory_repo.dart';
import '../data/task_repo.dart';
import '../models/conversation.dart';
import '../services/notification_ids.dart';
import '../services/notification_service.dart';

/// Cancels the reminder for a task's notification id. In production this is
/// `NotificationService().cancelTaskNotification`; injected so this class
/// does not depend on `awesome_notifications`.
typedef CancelReminder = Future<void> Function(int id);

/// Schedules a due-date reminder. Same shape as
/// `session/conversation_finalizer.dart`'s `ScheduleReminder`, injected for
/// the same reason.
typedef ScheduleReminder = Future<void> Function({
  required int id,
  required String title,
  required DateTime dueDate,
});

class LibraryController extends ChangeNotifier {
  LibraryController({
    Future<Database> Function()? database,
    CancelReminder? cancelReminder,
    ScheduleReminder? scheduleReminder,
  })  : _database = database ?? AppDatabase.instance,
        _cancelReminder =
            cancelReminder ?? NotificationService().cancelTaskNotification,
        _scheduleReminder =
            scheduleReminder ?? NotificationService().scheduleTaskNotification;

  final Future<Database> Function() _database;
  final CancelReminder _cancelReminder;
  final ScheduleReminder _scheduleReminder;

  List<Conversation> _conversations = [];
  List<Conversation> get conversations => _conversations;

  List<Memory> _memories = [];
  List<Memory> get memories => _memories;

  List<Task> _tasks = [];
  List<Task> get tasks => _tasks;

  // === Conversations Methods ===

  Future<void> loadConversations() async {
    _conversations = await ConversationRepo(await _database()).all();
    notifyListeners();
  }

  Future<void> deleteConversation(String id) async {
    await ConversationRepo(await _database()).delete(id);
    await loadConversations();
  }

  /// Reloads everything a finished summarisation can have touched: the old
  /// the old monolith's `_reloadFinalizedData`.
  Future<void> reloadAll() async {
    await loadConversations();
    await loadMemories();
    await loadTasks();
  }

  // === Memory Methods ===

  Future<void> loadMemories() async {
    _memories = await MemoryRepo(await _database()).all();
    notifyListeners();
  }

  Future<void> deleteMemory(String id) async {
    await MemoryRepo(await _database()).delete(id);
    await loadMemories();
  }

  Future<void> updateMemory(String id, String content) async {
    await MemoryRepo(await _database()).updateContent(id, content);
    await loadMemories();
  }

  Future<void> addMemory(String content, {String? sourceConversationId}) async {
    final memory = Memory(
      id: const Uuid().v4(),
      content: content.trim(),
      category: 'manual',
      createdAt: DateTime.now(),
      sourceConversationId: sourceConversationId,
    );
    await MemoryRepo(await _database()).save(memory);
    await loadMemories();
  }

  // === Task Methods ===

  Future<void> loadTasks() async {
    _tasks = await TaskRepo(await _database()).all();
    notifyListeners();
  }

  Task? _findTaskById(String id) {
    final index = _tasks.indexWhere((t) => t.id == id);
    return index == -1 ? null : _tasks[index];
  }

  /// Cancels the reminder for [id] if the task is still in memory. The
  /// notification id derives from the persisted `createdAt` (or the
  /// persisted `notification_id` column since schema v5), so a task we
  /// cannot see is a task whose reminder we cannot address. Every UI path
  /// operates on a task taken from [tasks], so this is not reachable today.
  Future<void> _cancelTaskNotification(String id) async {
    final task = _findTaskById(id);
    if (task == null) return;
    await _cancelReminder(notificationIdForTask(task));
  }

  Future<void> deleteTask(String id) async {
    // Cancel the notification before the row goes away: the id is derived
    // from the task's createdAt, which we can only read while it is loaded.
    await _cancelTaskNotification(id);

    await TaskRepo(await _database()).delete(id);
    await loadTasks();
  }

  Future<void> toggleTaskCompletion(String id, bool isCompleted) async {
    await TaskRepo(await _database()).setCompleted(id, isCompleted);

    // Manage notification
    if (isCompleted) {
      await _cancelTaskNotification(id);
    } else {
      // Find task to reschedule if needed
      final task = _findTaskById(id);
      if (task != null &&
          task.dueDate != null &&
          task.dueDate!.isAfter(DateTime.now())) {
        await _scheduleReminder(
          id: notificationIdForTask(task),
          title: task.title,
          dueDate: task.dueDate!,
        );
      }
    }

    await loadTasks();
  }

  /// The whole library as a backup document. The format lives in
  /// `data/export_import.dart` (LO-61); this stays as the UI's entry point.
  Future<Map<String, dynamic>> exportAllData() async =>
      exportAll(await _database());

  /// Restores a backup document and reloads every list from the database.
  ///
  /// Throws [ImportFormatException] for a file this build cannot read; rows
  /// that fail validation are reported in the result rather than thrown.
  Future<ImportReport> importAllData(
    Map<String, dynamic> document, {
    ImportMode mode = ImportMode.merge,
  }) async {
    final report = await importAll(await _database(), document, mode: mode);
    await reloadAll();
    return report;
  }
}
