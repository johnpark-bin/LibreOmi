/// Table access for `pending_finalizations` (LO-35).
///
/// This is deliberately policy-free: backoff, `maxAttempts`, and what counts
/// as "held" all stay in `services/finalization_queue.dart`, which since
/// LO-33 is the only caller and reads every row through this repo -- the
/// "held" predicate is an extension it declares on [PendingFinalizationRow]
/// rather than a field here. Nothing in this file imports
/// `finalization_queue.dart`: `lib/data` must not depend on `lib/services`
/// (see docs/03-architecture.md).
library;

import 'package:sqflite/sqflite.dart';

/// One row of `pending_finalizations`.
class PendingFinalizationRow {
  PendingFinalizationRow({
    required this.id,
    required this.conversationId,
    required this.transcript,
    required this.attempts,
    required this.nextAttemptAt,
    required this.lastError,
    required this.createdAt,
  });

  final String id;
  final String conversationId;
  final String transcript;
  final int attempts;
  final DateTime nextAttemptAt;
  final String? lastError;
  final DateTime createdAt;

  factory PendingFinalizationRow.fromRow(Map<String, Object?> row) {
    return PendingFinalizationRow(
      id: row['id'] as String,
      conversationId: row['conversation_id'] as String,
      transcript: row['transcript'] as String,
      attempts: row['attempts'] as int,
      nextAttemptAt:
          DateTime.fromMillisecondsSinceEpoch(row['next_attempt_at'] as int),
      lastError: row['last_error'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    );
  }

  Map<String, Object?> toRow() => {
        'id': id,
        'conversation_id': conversationId,
        'transcript': transcript,
        'attempts': attempts,
        'next_attempt_at': nextAttemptAt.millisecondsSinceEpoch,
        'last_error': lastError,
        'created_at': createdAt.millisecondsSinceEpoch,
      };
}

class FinalizationRepo {
  FinalizationRepo(this._db);

  final Database _db;

  Future<void> insert(PendingFinalizationRow row) async {
    await _db.insert('pending_finalizations', row.toRow());
  }

  Future<List<PendingFinalizationRow>> all() async {
    final rows = await _db.query(
      'pending_finalizations',
      orderBy: 'created_at ASC',
    );
    return rows.map(PendingFinalizationRow.fromRow).toList();
  }

  Future<List<PendingFinalizationRow>> forConversation(
    String conversationId,
  ) async {
    final rows = await _db.query(
      'pending_finalizations',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
    return rows.map(PendingFinalizationRow.fromRow).toList();
  }

  Future<List<PendingFinalizationRow>> due({
    required int maxAttempts,
    required DateTime now,
  }) async {
    final rows = await _db.query(
      'pending_finalizations',
      where: 'attempts < ? AND next_attempt_at <= ?',
      whereArgs: [maxAttempts, now.millisecondsSinceEpoch],
      orderBy: 'next_attempt_at ASC, created_at ASC',
    );
    return rows.map(PendingFinalizationRow.fromRow).toList();
  }

  /// Only includes `next_attempt_at` in the update when non-null, so a
  /// permanent-failure update (which only touches `attempts`/`last_error`)
  /// does not clobber the existing due time.
  Future<void> updateAttempt({
    required String id,
    required int attempts,
    DateTime? nextAttemptAt,
    String? lastError,
  }) async {
    final values = <String, Object?>{
      'attempts': attempts,
      'last_error': lastError,
    };
    if (nextAttemptAt != null) {
      values['next_attempt_at'] = nextAttemptAt.millisecondsSinceEpoch;
    }
    await _db.update(
      'pending_finalizations',
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> delete(String id) async {
    await _db.delete('pending_finalizations', where: 'id = ?', whereArgs: [id]);
  }
}
