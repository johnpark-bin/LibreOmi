/// Instance repository for the `chat_messages` table (LO-35).
///
/// New persistence: the pre-LO-35 monolith had no chat statics, so this is not
/// a straight port, but it follows the same shape as the other repos in this
/// directory.
library;

import 'package:sqflite/sqflite.dart';

import '../models/conversation.dart';

class ChatRepo {
  ChatRepo(this._db);

  final Database _db;

  /// Stores [message], stamping it with the next insertion order (LO-65).
  ///
  /// Reading the current maximum and inserting have to be one transaction:
  /// two messages saved concurrently would otherwise read the same maximum
  /// and claim the same `seq`, which is the tie this column exists to break.
  /// Re-saving an id that is already stored keeps that row's `seq`, so an
  /// edit or a replayed write does not move the message to the end of the
  /// history.
  Future<void> save(ChatMessage message) async {
    await _db.transaction((txn) async {
      final existing = await txn.query(
        'chat_messages',
        columns: ['seq'],
        where: 'id = ?',
        whereArgs: [message.id],
        limit: 1,
      );
      final int seq;
      if (existing.isNotEmpty && existing.first['seq'] != null) {
        seq = existing.first['seq'] as int;
      } else {
        seq = await nextSeq(txn);
      }
      await txn.insert(
        'chat_messages',
        {
          'id': message.id,
          'conversation_id': message.conversationId,
          'text': message.text,
          'is_user': message.isUser ? 1 : 0,
          'created_at': message.createdAt.millisecondsSinceEpoch,
          'seq': seq,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  /// The insertion order the next message written through [executor] takes.
  ///
  /// Shared with the importer, which assigns `seq` to rows a backup does not
  /// carry one for, so both writers agree on where the counter stands.
  static Future<int> nextSeq(DatabaseExecutor executor) async {
    final rows = await executor.rawQuery(
      'SELECT COALESCE(MAX(seq), 0) AS max_seq FROM chat_messages',
    );
    return (rows.first['max_seq'] as int) + 1;
  }

  /// The most recent [limit] messages, returned oldest first.
  ///
  /// The query orders descending and the result is reversed, so hitting the
  /// limit drops the *oldest* messages rather than the newest — a chat view
  /// and a backup both want the recent end of the history, and every other
  /// repo's `limit` means the same thing.
  ///
  /// `seq` is the sort key (LO-65), not `created_at`: a question and the
  /// answer to it are routinely written in the same millisecond, and the
  /// stored timestamp cannot tell them apart. `created_at` and `id` stay on
  /// as trailing tiebreakers so a row that somehow reached the table without
  /// a `seq` still sorts deterministically instead of arbitrarily.
  Future<List<ChatMessage>> all({int limit = 500}) async {
    final rows = await _db.query(
      'chat_messages',
      orderBy: 'seq DESC, created_at DESC, id DESC',
      limit: limit,
    );
    return rows.reversed.map((row) => ChatMessage.fromDbRow(row)).toList();
  }

  Future<void> delete(String id) async {
    await _db.delete('chat_messages', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clear() async {
    await _db.delete('chat_messages');
  }
}
