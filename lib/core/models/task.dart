/// The task model.
library;

/// A task extracted from conversations
class Task {
  final String id;
  final String title;
  final String? description;
  final DateTime? dueDate;
  final DateTime createdAt;
  final String? sourceConversationId;
  bool isCompleted;

  /// Stable id for this task's scheduled reminder, persisted since schema v5
  /// (`tasks.notification_id`). Null for a task that has not been through the
  /// database yet; `notificationIdForTask` then falls back to deriving one
  /// from [createdAt], which is what the column is backfilled with.
  final int? notificationId;

  Task({
    required this.id,
    required this.title,
    this.description,
    this.dueDate,
    required this.createdAt,
    this.sourceConversationId,
    this.isCompleted = false,
    this.notificationId,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'due_date': dueDate?.millisecondsSinceEpoch,
    'created_at': createdAt.millisecondsSinceEpoch,
    'source_conversation_id': sourceConversationId,
    'is_completed': isCompleted ? 1 : 0,
    'notification_id': notificationId,
  };

  factory Task.fromDbRow(Map<String, dynamic> row) {
    return Task(
      id: row['id'],
      title: row['title'],
      description: row['description'],
      dueDate: row['due_date'] != null 
          ? DateTime.fromMillisecondsSinceEpoch(row['due_date']) 
          : null,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at']),
      sourceConversationId: row['source_conversation_id'],
      isCompleted: row['is_completed'] == 1,
      notificationId: row['notification_id'] as int?,
    );
  }
}
