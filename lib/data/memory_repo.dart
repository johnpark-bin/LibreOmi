/// Instance repository for the `memories` table (LO-35).
///
/// Reproduces the pre-LO-35 monolith's memory statics exactly, against an
/// already-open [Database] instead of the process-wide singleton.
library;

import 'package:sqflite/sqflite.dart';

import '../core/models.dart';

class MemoryRepo {
  MemoryRepo(this._db);

  final Database _db;

  Future<void> save(Memory memory) async {
    await _db.insert(
      'memories',
      {
        'id': memory.id,
        'content': memory.content,
        'category': memory.category,
        'created_at': memory.createdAt.millisecondsSinceEpoch,
        'source_conversation_id': memory.sourceConversationId,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Memory>> all({int limit = 100}) async {
    final rows = await _db.query(
      'memories',
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map((row) => Memory.fromDbRow(row)).toList();
  }

  Future<void> delete(String id) async {
    await _db.delete('memories', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateContent(String id, String content) async {
    await _db.update(
      'memories',
      {'content': content},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Dedup rule, unchanged: lowercase+trim, then exact match or either side
  /// containing the other. Scans every row rather than filtering in SQL
  /// because the comparison is substring-based, not equality.
  Future<bool> hasSimilar(String content) async {
    final normalizedContent = content.toLowerCase().trim();

    final rows = await _db.query('memories');
    for (final row in rows) {
      final existingContent = (row['content'] as String).toLowerCase().trim();
      if (existingContent == normalizedContent ||
          existingContent.contains(normalizedContent) ||
          normalizedContent.contains(existingContent)) {
        return true;
      }
    }
    return false;
  }
}
