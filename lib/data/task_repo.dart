/// Instance repository for the `tasks` table (LO-35).
///
/// Reproduces the pre-LO-35 monolith's task statics exactly, against an
/// already-open [Database] instead of the process-wide singleton.
library;

import 'package:sqflite/sqflite.dart';

import '../core/ids.dart';
import '../core/models.dart';

class TaskRepo {
  TaskRepo(this._db);

  final Database _db;

  /// Persists `notification_id`, added by the v5 schema. Falls back to
  /// [fallbackNotificationId] for a task that has not been assigned one yet
  /// -- the same value `notificationIdForTask` derived at call time before
  /// v5, so the id a task reports is unchanged, now persisted instead of
  /// recomputed.
  Future<void> save(Task task) async {
    await _db.insert(
      'tasks',
      {
        'id': task.id,
        'title': task.title,
        'description': task.description,
        'due_date': task.dueDate?.millisecondsSinceEpoch,
        'created_at': task.createdAt.millisecondsSinceEpoch,
        'source_conversation_id': task.sourceConversationId,
        'is_completed': task.isCompleted ? 1 : 0,
        'notification_id':
            task.notificationId ?? fallbackNotificationId(task.createdAt),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Task>> all({int limit = 100}) async {
    final rows = await _db.query(
      'tasks',
      orderBy: 'is_completed ASC, due_date ASC, created_at DESC',
      limit: limit,
    );
    return rows.map((row) => Task.fromDbRow(row)).toList();
  }

  Future<void> setCompleted(String id, bool isCompleted) async {
    await _db.update(
      'tasks',
      {'is_completed': isCompleted ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> delete(String id) async {
    await _db.delete('tasks', where: 'id = ?', whereArgs: [id]);
  }

  /// Dedup rule, unchanged: lowercase+trim, exact match or either side
  /// containing the other, scoped to incomplete tasks only.
  Future<bool> hasSimilar(String title) async {
    final normalizedTitle = title.toLowerCase().trim();

    final rows = await _db.query('tasks', where: 'is_completed = 0');
    for (final row in rows) {
      final existingTitle = (row['title'] as String).toLowerCase().trim();
      if (existingTitle == normalizedTitle ||
          existingTitle.contains(normalizedTitle) ||
          normalizedTitle.contains(existingTitle)) {
        return true;
      }
    }
    return false;
  }
}
