/// Instance repository for the `conversations` table (LO-35).
///
/// Reproduces `DatabaseService`'s conversation statics exactly, against an
/// already-open [Database] instead of the process-wide singleton, so the
/// facade in `services/database_service.dart` can later delegate to this
/// without changing behaviour.
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/conversation.dart';

class ConversationRepo {
  ConversationRepo(this._db);

  final Database _db;

  Future<void> save(Conversation conversation) async {
    await _db.insert(
      'conversations',
      {
        'id': conversation.id,
        'created_at': conversation.createdAt.millisecondsSinceEpoch,
        'title': conversation.title,
        'summary': conversation.summary,
        'transcript':
            jsonEncode(conversation.segments.map((s) => s.toJson()).toList()),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Conversation>> all({int limit = 50}) async {
    final rows = await _db.query(
      'conversations',
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map((row) => Conversation.fromDbRow(row)).toList();
  }

  Future<Conversation?> byId(String id) async {
    final rows = await _db.query(
      'conversations',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return Conversation.fromDbRow(rows.first);
  }

  Future<void> delete(String id) async {
    await _db.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }

  /// Formatted text blob for AI prompt context, byte-for-byte identical to
  /// the old `getAllConversationsContext` (including its whitespace).
  Future<String> contextText({int limit = 10}) async {
    final conversations = await all(limit: limit);
    if (conversations.isEmpty) return '';

    return conversations.map((c) {
      return '''
--- Conversation from ${c.createdAt.toLocal()} ---
Title: ${c.title}
Summary: ${c.summary}
Transcript:
${c.transcript}
''';
    }).join('\n\n');
  }
}
