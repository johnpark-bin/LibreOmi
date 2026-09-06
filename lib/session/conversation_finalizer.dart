/// The single place a conversation's finalization (persist -> summarize ->
/// apply insights) happens, for both the live recording path and the
/// SD-card import path (LO-33, `docs/03-architecture.md` section 4).
///
/// Before this class, `AppProvider._saveCurrentConversation` (live path) and
/// `AppProvider.processLocalAudioFile` (SD-card path) each persisted a
/// conversation and queued its summarisation inline, and
/// `AppProvider._applyFinalizationResult` wrote a finished summarisation back
/// into storage. This class is exactly that behaviour, extracted so both
/// call sites and the retry queue (`services/finalization_queue.dart`) share
/// one implementation instead of drifting apart.
library;

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../core/clock.dart';
import '../core/ids.dart';
import '../data/conversation_repo.dart';
import '../data/memory_repo.dart';
import '../data/task_repo.dart';
import '../intelligence/llm_client.dart';
import '../models/conversation.dart';
import '../services/notification_ids.dart';

/// Lazily opens (or returns) the process-wide database. Repos are built from
/// its result inside each call, mirroring how `FinalizationQueue` already
/// handles the lazily-opened database -- so this class never holds a `Database`
/// across an `await` boundary that a test's in-memory database might outlive.
typedef FinalizationDatabase = Future<Database> Function();

/// Hands [conversation] to the retry queue for summarisation. In production
/// this is `FinalizationQueue.enqueue` guarded by the "is an OpenAI key
/// configured / is the transcript non-empty" checks that live with settings.
typedef SummarizationEnqueuer = Future<void> Function(Conversation conversation);

/// Schedules a due-date reminder. In production this is
/// `NotificationService().scheduleTaskNotification`; injected so this class
/// does not depend on `awesome_notifications`.
typedef ScheduleReminder = Future<void> Function({
  required int id,
  required String title,
  required DateTime dueDate,
});

/// Persists conversations and applies their finalization results
/// (title/summary/memories/tasks), replacing the duplicated logic that used
/// to live inline in `AppProvider`.
class ConversationFinalizer {
  ConversationFinalizer({
    required FinalizationDatabase database,
    required SummarizationEnqueuer enqueue,
    required ScheduleReminder scheduleReminder,
    IdGenerator? ids,
    Clock clock = const SystemClock(),
    Future<void> Function()? onConversationSaved,
    Future<void> Function()? onInsightsApplied,
  })  : _database = database,
        _enqueue = enqueue,
        _scheduleReminder = scheduleReminder,
        _ids = ids ?? UuidIdGenerator(),
        _clock = clock,
        _onConversationSaved = onConversationSaved,
        _onInsightsApplied = onInsightsApplied;

  final FinalizationDatabase _database;
  final SummarizationEnqueuer _enqueue;
  final ScheduleReminder _scheduleReminder;
  final IdGenerator _ids;
  final Clock _clock;
  final Future<void> Function()? _onConversationSaved;
  final Future<void> Function()? _onInsightsApplied;

  /// Persists [conversation] immediately (with a placeholder title when it
  /// has none) and queues its summarisation.
  ///
  /// The title is only filled in when it is empty: the SD-card path arrives
  /// with the title `'SD Card Recording'` already set and must keep it, while
  /// the live recording path arrives with no title at all.
  Future<void> finalize(Conversation conversation) async {
    if (conversation.title.trim().isEmpty) {
      conversation.title =
          'Conversation ${conversation.createdAt.toString().substring(0, 16)}';
    }

    final db = await _database();
    await ConversationRepo(db).save(conversation);

    await _onConversationSaved?.call();

    // A queue insert that fails must not lose the conversation, which is
    // already persisted above -- so this is logged and swallowed rather than
    // allowed to propagate.
    try {
      await _enqueue(conversation);
    } catch (e) {
      debugPrint('Failed to queue finalization: $e');
    }
  }

  /// Writes a finished summarisation back into storage: title, summary,
  /// deduplicated memories and tasks, and reminders for tasks with due dates.
  ///
  /// Deliberately has no blanket try/catch: a failure here is how the retry
  /// queue learns the apply failed, so it must keep bubbling up.
  Future<void> applyInsights(
    String conversationId,
    ConversationInsights insights,
  ) async {
    final db = await _database();
    final conversationRepo = ConversationRepo(db);

    final conversation = await conversationRepo.byId(conversationId);
    if (conversation == null) {
      // Deleted while the request sat in the queue: nothing left to fill in.
      debugPrint(
        'Finalization result for a deleted conversation: $conversationId',
      );
      return;
    }

    // The trimmed value is what is stored, matching the old code's
    // `(result['title'] as String?)?.trim()`.
    final title = insights.title.trim();
    if (title.isNotEmpty) {
      conversation.title = title;
    }
    conversation.summary = insights.summary;
    await conversationRepo.save(conversation);

    final memoryRepo = MemoryRepo(db);
    for (final memoryContent in insights.memories) {
      if (memoryContent.trim().isEmpty) continue;
      // The untrimmed value is what is passed to `hasSimilar`, matching the
      // old code exactly.
      final hasSimilar = await memoryRepo.hasSimilar(memoryContent);
      if (!hasSimilar) {
        final memory = Memory(
          id: _ids.newId(),
          content: memoryContent.trim(),
          category: 'fact',
          createdAt: _clock.now(),
          sourceConversationId: conversation.id,
        );
        await memoryRepo.save(memory);
        debugPrint('Saved memory: ${memory.content}');
      } else {
        debugPrint('Skipped duplicate memory: $memoryContent');
      }
    }

    final taskRepo = TaskRepo(db);
    for (final draft in insights.tasks) {
      final taskTitle = draft.title.trim();
      if (taskTitle.isEmpty) continue;
      final hasSimilar = await taskRepo.hasSimilar(taskTitle);
      if (!hasSimilar) {
        final task = Task(
          id: _ids.newId(),
          title: taskTitle,
          description: draft.description,
          dueDate: draft.dueDate,
          createdAt: _clock.now(),
          sourceConversationId: conversation.id,
        );
        await taskRepo.save(task);

        if (task.dueDate != null) {
          await _scheduleReminder(
            id: notificationIdForTask(task),
            title: task.title,
            dueDate: task.dueDate!,
          );
        }

        debugPrint('Saved task: ${task.title} (due: ${task.dueDate})');
      } else {
        debugPrint('Skipped duplicate task: $taskTitle');
      }
    }

    await _onInsightsApplied?.call();

    debugPrint('Finalized conversation: ${conversation.title}');
  }
}
