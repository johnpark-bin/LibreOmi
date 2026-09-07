/// The backup file format, and the two directions across it (LO-61).
///
/// This is the single definition of what a LibreOmi export contains. The
/// repositories in this directory own individual tables; this file owns the
/// document that carries four of them out of the app and back in.
///
/// The payload is deliberately the models' own `toJson()` shape rather than a
/// copy of the SQLite file: a database file couples a backup to
/// [AppDatabase.schemaVersion], and a `.db` is awkward to hand to a share
/// sheet. `pending_finalizations` is *not* exported — it is retry state for
/// this install, not user data, and restoring it elsewhere would queue
/// summarisation for conversations that install has never seen.
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/ids.dart';
import 'chat_repo.dart';

/// Format revision of the document produced by [exportAll].
///
/// Bump this only for a change [importAll] cannot read; add the old number to
/// [supportedFormatVersions] whenever it can.
const int exportFormatVersion = 1;

/// Versions [importAll] accepts.
const Set<int> supportedFormatVersions = {exportFormatVersion};

/// The app version stamped into an export, kept in step with `pubspec.yaml`'s
/// `version:` name (docs/08-dev-workflow.md §7.1). Informational only: nothing
/// on the import side branches on it.
const String exportAppVersion = '0.1.0';

/// The tables a backup carries, in insert order.
const List<String> _exportedTables = [
  'conversations',
  'memories',
  'tasks',
  'chat_messages',
];

/// How [importAll] treats rows that are already in the database.
enum ImportMode {
  /// Keep everything already stored, adding the file's rows on top: a row
  /// whose id is new is inserted, a row whose id already exists is overwritten
  /// with the file's version. Rows absent from the file are left alone.
  merge,

  /// Replace the library: the four exported tables are emptied first, so what
  /// is left afterwards is exactly the file's contents.
  replace,
}

/// What one [importAll] call did.
///
/// [inserted] and [updated] count rows actually written; [skipped] counts rows
/// the file contained but that failed validation. [errors] describes the first
/// few skips so the UI can say *why* without rendering thousands of lines.
class ImportReport {
  ImportReport({
    required this.inserted,
    required this.updated,
    required this.skipped,
    required this.errors,
  });

  final int inserted;
  final int updated;
  final int skipped;
  final List<String> errors;

  @override
  String toString() =>
      'ImportReport(inserted: $inserted, updated: $updated, '
      'skipped: $skipped, errors: ${errors.length})';
}

/// Thrown when the document itself cannot be read: not a JSON object, an
/// unsupported [exportFormatVersion], or no recognisable payload at all.
///
/// A row-level problem never throws — it is counted in [ImportReport.skipped].
class ImportFormatException implements Exception {
  ImportFormatException(this.message);

  final String message;

  @override
  String toString() => 'ImportFormatException: $message';
}

/// Reads the whole library out of [db] as a JSON-encodable map.
///
/// Queries the tables directly rather than going through the repositories:
/// their `limit` defaults are sized for list views, and a backup that quietly
/// stopped at the newest 50 conversations would be worse than no backup.
Future<Map<String, dynamic>> exportAll(
  Database db, {
  String appVersion = exportAppVersion,
  DateTime? now,
}) async {
  final payload = <String, dynamic>{
    'format_version': exportFormatVersion,
    'app_version': appVersion,
    'exported_at': (now ?? DateTime.now()).toIso8601String(),
  };
  for (final table in _exportedTables) {
    final rows = await db.query(table, orderBy: _exportOrderBy(table));
    payload[table] = rows.map(_rowToJson).toList();
  }
  return payload;
}

/// How each table's rows are ordered in the document.
///
/// Chronological for everything else, but `chat_messages` goes out in `seq`
/// order (schema v6, LO-65) so the array itself carries the insertion order —
/// that is what lets a file written before the column existed, or edited by
/// hand, still be restored in the right order from its array positions alone.
String _exportOrderBy(String table) => table == 'chat_messages'
    ? 'seq ASC, created_at ASC, id ASC'
    : 'created_at ASC, id ASC';

/// The default filename for an export taken at [at], e.g.
/// `libreomi-export-20260908-1432.json`.
String exportFileName(DateTime at) {
  String two(int v) => v.toString().padLeft(2, '0');
  final local = at.toLocal();
  return 'libreomi-export-${local.year}${two(local.month)}${two(local.day)}'
      '-${two(local.hour)}${two(local.minute)}.json';
}

/// Writes [document] into [db] according to [mode].
///
/// The whole import is one transaction: a document that fails validation
/// part-way through leaves the database exactly as it was. Rows that fail
/// validation individually are skipped rather than aborting the import, since
/// one truncated row should not cost the user the other ten thousand.
///
/// Throws [ImportFormatException] for a document this build cannot read.
Future<ImportReport> importAll(
  Database db,
  Map<String, dynamic> document, {
  ImportMode mode = ImportMode.merge,
}) async {
  final formatVersion = _formatVersionOf(document);
  if (!supportedFormatVersions.contains(formatVersion)) {
    throw ImportFormatException(
      'Unsupported export format version $formatVersion; this build reads '
      '${supportedFormatVersions.join(', ')}.',
    );
  }

  var sawPayload = false;
  for (final table in _exportedTables) {
    final raw = document[table];
    if (raw == null) continue;
    if (raw is! List) {
      throw ImportFormatException('"$table" is not a list of rows.');
    }
    sawPayload = true;
  }
  if (!sawPayload) {
    throw ImportFormatException(
      'No conversations, memories, tasks or chat messages in this file.',
    );
  }

  var inserted = 0;
  var updated = 0;
  var skipped = 0;
  final errors = <String>[];

  void skip(String table, int index, String reason) {
    skipped++;
    if (errors.length < _maxReportedErrors) {
      errors.add('$table[$index]: $reason');
    }
  }

  await db.transaction((txn) async {
    if (mode == ImportMode.replace) {
      for (final table in _exportedTables) {
        await txn.delete(table);
      }
    }

    for (final table in _exportedTables) {
      final rows = document[table];
      if (rows is! List) continue;

      final existingIds = mode == ImportMode.replace
          ? <String>{}
          : (await txn.query(table, columns: ['id']))
              .map((row) => row['id'] as String)
              .toSet();

      // Where the file's chat history is placed (LO-65). `chatSeqBase` is the
      // shift applied to the file's own `seq` values: 0 after a replace has
      // emptied the table, so they survive the round trip untouched, and the
      // stored maximum in a merge, so the whole imported history lands past
      // what is already there instead of interleaving with it at arbitrary
      // positions. `nextChatSeq` is the counter for rows the file gives no
      // `seq` at all.
      var nextChatSeq =
          table == 'chat_messages' ? await ChatRepo.nextSeq(txn) : 0;
      final chatSeqBase = nextChatSeq - 1;

      // Chat rows the file re-sends keep the place they already have, the
      // same rule `ChatRepo.save` applies to a replayed write: importing one
      // backup twice must not drag its messages past the chat that happened
      // in between.
      final storedChatSeqs = table == 'chat_messages' && existingIds.isNotEmpty
          ? <String, int>{
              for (final row in await txn.query(
                'chat_messages',
                columns: ['id', 'seq'],
              ))
                if (row['seq'] != null) row['id'] as String: row['seq'] as int,
            }
          : const <String, int>{};

      for (var index = 0; index < rows.length; index++) {
        final raw = rows[index];
        if (raw is! Map) {
          skip(table, index, 'not an object');
          continue;
        }
        final Map<String, dynamic> row;
        try {
          row = raw.map((key, value) => MapEntry(key as String, value));
        } on TypeError {
          skip(table, index, 'has non-string keys');
          continue;
        }

        final Map<String, Object?> values;
        try {
          values = _toDbRow(table, row);
        } on FormatException catch (e) {
          skip(table, index, e.message);
          continue;
        }

        if (table == 'chat_messages') {
          // A file written before schema v6 — or one edited by hand — has no
          // `seq`, so the row's position in the array is the only record of
          // the order it was written in; the running counter turns that into
          // a `seq` that cannot collide with the ones already handed out.
          final fileSeq = values['seq'] as int?;
          final stored = storedChatSeqs[values['id'] as String];
          final seq = stored ??
              (fileSeq != null && fileSeq > 0
                  ? chatSeqBase + fileSeq
                  : nextChatSeq);
          values['seq'] = seq;
          if (seq >= nextChatSeq) nextChatSeq = seq + 1;
        }

        final id = values['id'] as String;
        final isUpdate = existingIds.contains(id);
        await txn.insert(
          table,
          values,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        if (isUpdate) {
          updated++;
        } else {
          inserted++;
          existingIds.add(id);
        }
      }
    }
  });

  return ImportReport(
    inserted: inserted,
    updated: updated,
    skipped: skipped,
    errors: errors,
  );
}

/// A one-line description of a document's contents, for the confirmation
/// dialog: the counts the user is about to import.
Map<String, int> summarize(Map<String, dynamic> document) {
  final counts = <String, int>{};
  for (final table in _exportedTables) {
    final rows = document[table];
    counts[table] = rows is List ? rows.length : 0;
  }
  return counts;
}

const int _maxReportedErrors = 10;

/// A document without `format_version` predates LO-61. Its four arrays have
/// the same shape as version 1's, so it is read as version 1 rather than
/// rejected — refusing to restore the backups the first release produced
/// would defeat the point of the feature.
int _formatVersionOf(Map<String, dynamic> document) {
  final raw = document['format_version'];
  if (raw == null) return 1;
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  throw ImportFormatException('"format_version" is not a number.');
}

/// Turns a queried row into its JSON form.
///
/// The columns are already JSON-safe scalars (`INTEGER`/`TEXT`), so this only
/// has to drop the immutability of sqflite's read-only maps. `conversations`
/// keeps its `transcript` as the encoded segment JSON exactly as stored: the
/// export is a copy of the row, and re-encoding it through
/// [TranscriptSegment] would silently rewrite anything the model does not
/// model.
Map<String, dynamic> _rowToJson(Map<String, Object?> row) =>
    Map<String, dynamic>.from(row);

/// Validates one JSON row and returns the column map to insert.
///
/// Throws [FormatException] with a short reason when the row cannot be
/// stored; the caller turns that into a skip.
Map<String, Object?> _toDbRow(String table, Map<String, dynamic> row) {
  switch (table) {
    case 'conversations':
      return {
        'id': _requireId(row),
        'created_at': _requireEpoch(row, 'created_at'),
        'title': _optionalString(row, 'title') ?? '',
        'summary': _optionalString(row, 'summary') ?? '',
        'transcript': _transcriptOf(row),
      };
    case 'memories':
      return {
        'id': _requireId(row),
        'content': _requireString(row, 'content'),
        'category': _optionalString(row, 'category') ?? 'fact',
        'created_at': _requireEpoch(row, 'created_at'),
        'source_conversation_id': _optionalString(row, 'source_conversation_id'),
      };
    case 'tasks':
      final createdAt = _requireEpoch(row, 'created_at');
      return {
        'id': _requireId(row),
        'title': _requireString(row, 'title'),
        'description': _optionalString(row, 'description'),
        'due_date': _optionalEpoch(row, 'due_date'),
        'created_at': createdAt,
        'source_conversation_id': _optionalString(row, 'source_conversation_id'),
        'is_completed': _boolAsInt(row['is_completed']),
        // A task exported before schema v5 has no notification id. Deriving it
        // the same way the v5 migration backfilled the column keeps a reminder
        // scheduled before the backup cancellable after the restore.
        'notification_id': _optionalInt(row, 'notification_id') ??
            fallbackNotificationId(
              DateTime.fromMillisecondsSinceEpoch(createdAt),
            ),
      };
    case 'chat_messages':
      return {
        'id': _requireId(row),
        'conversation_id': _optionalString(row, 'conversation_id'),
        'text': _optionalString(row, 'text') ?? '',
        'is_user': _boolAsInt(row['is_user']),
        'created_at': _requireEpoch(row, 'created_at'),
        // A message exported before schema v6 has no insertion order. Left
        // null here and filled in from the row's position in the array by
        // [importAll], which is the only place that knows both the position
        // and where the table's counter currently stands.
        'seq': _optionalInt(row, 'seq'),
      };
    default:
      throw FormatException('unknown table "$table"');
  }
}

/// `transcript` is the stored segment JSON. An export written by [exportAll]
/// carries the column verbatim; a hand-edited file may instead carry the
/// model's `segments` list, which is what `Conversation.toJson()` produces —
/// both are accepted, and anything else stores an empty transcript rather
/// than losing the conversation's title and summary.
String _transcriptOf(Map<String, dynamic> row) {
  final transcript = row['transcript'];
  if (transcript is String) return transcript;
  final segments = row['segments'];
  if (segments is List) return _jsonEncode(segments);
  return '';
}

String _jsonEncode(Object? value) => jsonEncode(value);

String _requireId(Map<String, dynamic> row) {
  final id = row['id'];
  if (id is String && id.isNotEmpty) return id;
  throw const FormatException('missing "id"');
}

String _requireString(Map<String, dynamic> row, String key) {
  final value = row[key];
  if (value is String) return value;
  throw FormatException('missing "$key"');
}

String? _optionalString(Map<String, dynamic> row, String key) {
  final value = row[key];
  return value is String ? value : null;
}

int _requireEpoch(Map<String, dynamic> row, String key) {
  final value = _optionalInt(row, key);
  if (value == null) throw FormatException('missing "$key"');
  return value;
}

int? _optionalEpoch(Map<String, dynamic> row, String key) =>
    _optionalInt(row, key);

int? _optionalInt(Map<String, dynamic> row, String key) {
  final value = row[key];
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

/// `is_user` / `is_completed` are `INTEGER` columns but arrive as either a
/// number or a bool depending on which `toJson()` wrote them.
int _boolAsInt(Object? value) {
  if (value is bool) return value ? 1 : 0;
  if (value is num) return value == 0 ? 0 : 1;
  return 0;
}
