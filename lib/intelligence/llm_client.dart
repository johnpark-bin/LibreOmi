/// Provider-agnostic interface for the LLM-backed operations this app needs:
/// summarizing a conversation transcript into structured insights, and
/// answering an ad-hoc chat message with optional context. Concrete
/// implementations (e.g. `OpenAiClient`) wrap a specific provider's SDK/HTTP
/// service and translate its errors into [LlmException]s so callers can
/// reason about retryability without knowing which provider is behind it.
library;

/// A single actionable item extracted from a conversation.
class TaskDraft {
  const TaskDraft({required this.title, this.description, this.dueDate});

  final String title;
  final String? description;
  final DateTime? dueDate;
}

/// The structured result of summarizing a conversation transcript: a title,
/// a short summary, durable facts worth remembering, and any tasks the
/// speaker mentioned.
class ConversationInsights {
  const ConversationInsights({
    required this.title,
    required this.summary,
    required this.memories,
    required this.tasks,
  });

  final String title;
  final String summary;
  final List<String> memories;
  final List<TaskDraft> tasks;

  /// Builds insights from the raw JSON map an LLM summarization call
  /// returns. Defensive in the same way the legacy
  /// `OpenAIService.summarizeConversation` map path was: every field is
  /// optional and a malformed entry is dropped rather than thrown on, so a
  /// slightly-off model response degrades gracefully instead of crashing
  /// the finalization pipeline.
  factory ConversationInsights.fromMap(Map<String, dynamic> map) {
    final rawTitle = map['title'];
    final title = (rawTitle is String && rawTitle.trim().isNotEmpty)
        ? rawTitle
        : 'Untitled Conversation';

    final rawSummary = map['summary'];
    final summary = rawSummary is String ? rawSummary : '';

    final rawMemories = map['memories'];
    final memories = rawMemories is List ? rawMemories.cast<String>() : const <String>[];

    final rawTasks = map['tasks'];
    final tasks = <TaskDraft>[];
    if (rawTasks is List) {
      for (final entry in rawTasks) {
        if (entry is! Map) continue;
        final rawTitle = entry['title'];
        if (rawTitle is! String || rawTitle.trim().isEmpty) continue;
        final rawDescription = entry['description'];
        final rawDueDate = entry['due_date'];
        tasks.add(TaskDraft(
          title: rawTitle,
          description: rawDescription is String ? rawDescription : null,
          dueDate: rawDueDate is String ? DateTime.tryParse(rawDueDate) : null,
        ));
      }
    }

    return ConversationInsights(title: title, summary: summary, memories: memories, tasks: tasks);
  }

  /// Renders these insights back into the untyped map shape that
  /// `FinalizationQueue` and `AppProvider._applyFinalizationResult` still
  /// consume. This bridge exists only because the queue is still map-based;
  /// it goes away once LO-23 migrates the queue to typed results.
  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'summary': summary,
      'memories': memories,
      'tasks': [
        for (final task in tasks)
          {
            'title': task.title,
            'description': task.description,
            'due_date': task.dueDate?.toIso8601String(),
          },
      ],
    };
  }
}

/// Base type for errors an [LlmClient] implementation can throw, so callers
/// can catch this single type when they only care that *something* went
/// wrong, or catch the two subtypes below when the distinction matters
/// (e.g. deciding whether to retry).
abstract class LlmException implements Exception {
  const LlmException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// An error worth retrying: a network failure, a rate limit (429), or a
/// server-side error (5xx).
class LlmRetryableException extends LlmException {
  const LlmRetryableException(super.message, [super.cause]);
}

/// An error not worth retrying: a client error other than 429 (e.g. 401,
/// 400), or a response that could not be parsed as expected.
class LlmPermanentException extends LlmException {
  const LlmPermanentException(super.message, [super.cause]);
}

/// Provider-agnostic LLM operations used by the conversation finalization
/// and chat features.
abstract class LlmClient {
  /// Summarizes [transcript] into structured insights. [now] anchors
  /// relative due-date inference (e.g. "tonight"); defaults to the current
  /// time when omitted.
  ///
  /// Throws an [LlmException] on failure -- never returns a sentinel value.
  Future<ConversationInsights> summarize(String transcript, {DateTime? now});

  /// Answers [user]'s message, optionally grounded in [context] (e.g.
  /// recent conversation history).
  ///
  /// Throws an [LlmException] on failure.
  Future<String> chat(String user, {String? context});
}
