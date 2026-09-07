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

  Future<void> save(ChatMessage message) async {
    await _db.insert(
      'chat_messages',
      {
        'id': message.id,
        'conversation_id': message.conversationId,
        'text': message.text,
        'is_user': message.isUser ? 1 : 0,
        'created_at': message.createdAt.millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// The most recent [limit] messages, returned oldest first.
  ///
  /// The query orders descending and the result is reversed, so hitting the
  /// limit drops the *oldest* messages rather than the newest — a chat view
  /// and a backup both want the recent end of the history, and every other
  /// repo's `limit` means the same thing. `id` is a tiebreaker: two messages
  /// written in the same millisecond otherwise sort arbitrarily, and a stable
  /// order keeps a rendered transcript from reshuffling itself between reads.
  Future<List<ChatMessage>> all({int limit = 500}) async {
    final rows = await _db.query(
      'chat_messages',
      orderBy: 'created_at DESC, id DESC',
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
