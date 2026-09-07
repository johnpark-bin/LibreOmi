/// SQLite database: opening, schema creation and migrations (LO-35).
///
/// This is the single place that knows what the schema looks like. The
/// repositories in this directory take an already-open [Database]; only this
/// file talks to `sqflite`'s open/upgrade machinery, so a fresh install and an
/// upgraded install cannot drift apart.
library;

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  AppDatabase._();

  static const String _databaseName = 'libreomi.db';

  /// Schema version.
  ///
  /// * v2 added `memories`, v3 added `tasks`.
  /// * v4 added `pending_finalizations` (LO-23).
  /// * v5 added `tasks.notification_id` and made `chat_messages` part of the
  ///   migration path so chat can be persisted (LO-35).
  /// * v6 added `chat_messages.seq`, the insertion order chat history is read
  ///   back in (LO-65).
  static const int schemaVersion = 6;

  static Database? _database;

  /// The process-wide database, opened on first use.
  static Future<Database> instance() async {
    final existing = _database;
    if (existing != null) return existing;
    final opened = await _open();
    _database = opened;
    return opened;
  }

  static Future<Database> _open() async {
    final path = join(await getDatabasesPath(), _databaseName);
    return openDatabase(
      path,
      version: schemaVersion,
      onCreate: (db, version) => createSchema(db),
      onUpgrade: migrate,
    );
  }

  /// Creates the current schema from scratch. Exposed because the tests
  /// cannot reach an `openDatabase` callback.
  static Future<void> createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        created_at INTEGER NOT NULL,
        title TEXT,
        summary TEXT,
        transcript TEXT
      )
    ''');

    await _createChatMessagesTable(db);

    await db.execute('''
      CREATE TABLE memories (
        id TEXT PRIMARY KEY,
        content TEXT NOT NULL,
        category TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        source_conversation_id TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE tasks (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        description TEXT,
        due_date INTEGER,
        created_at INTEGER NOT NULL,
        source_conversation_id TEXT,
        is_completed INTEGER NOT NULL DEFAULT 0,
        notification_id INTEGER
      )
    ''');

    await createPendingFinalizationsTable(db);
  }

  /// Upgrades an existing database. One block per version so a device that
  /// skipped releases still walks every step. Every step is written so that
  /// replaying it is harmless: an upgrade interrupted by a crash asks for the
  /// same step again on the next launch.
  static Future<void> migrate(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS memories (
          id TEXT PRIMARY KEY,
          content TEXT NOT NULL,
          category TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          source_conversation_id TEXT
        )
      ''');
    }
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS tasks (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          description TEXT,
          due_date INTEGER,
          created_at INTEGER NOT NULL,
          source_conversation_id TEXT,
          is_completed INTEGER NOT NULL DEFAULT 0
        )
      ''');
    }
    if (oldVersion < 4) {
      await createPendingFinalizationsTable(db);
    }
    if (oldVersion < 5) {
      // `chat_messages` shipped in the v1 create-schema but was never part of
      // a migration step, so a database that reached v4 without it exists in
      // principle. Creating it here is what keeps a fresh install and an
      // upgraded one identical.
      await _createChatMessagesTable(db);
      await _addTaskNotificationId(db);
    }
    if (oldVersion < 6) {
      await _addChatMessageSeq(db);
    }
  }

  /// Summarisation requests that still have to run (LO-23).
  /// `next_attempt_at` is the epoch millisecond the row becomes due again, and
  /// `attempts` doubles as the held marker once it reaches the queue's cap.
  static Future<void> createPendingFinalizationsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_finalizations (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        transcript TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt_at INTEGER NOT NULL,
        last_error TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  /// Persisted AI chat history. `conversation_id` is nullable: the chat page
  /// asks about the whole library, not necessarily one conversation.
  ///
  /// `seq` is the insertion order (LO-65) and is what `ChatRepo` reads the
  /// history back in: `created_at` only has millisecond resolution, so a
  /// question and the answer to it can share a timestamp, and `id` is a
  /// random UUID that sorts arbitrarily. It is nullable so the v6 migration
  /// can use NULL as its "not assigned yet" marker; every write path fills
  /// it in.
  static Future<void> _createChatMessagesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS chat_messages (
        id TEXT PRIMARY KEY,
        conversation_id TEXT,
        text TEXT NOT NULL,
        is_user INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        seq INTEGER
      )
    ''');
  }

  /// Adds `chat_messages.seq` and backfills the rows that predate it.
  ///
  /// `rowid` is SQLite's own insertion counter, so it is the order those rows
  /// were written in — exactly what the column is for. It is copied out once
  /// here rather than used as the sort key directly, because a restored
  /// backup gets fresh rowids in whatever order the import happened to insert
  /// rows, while a copied `seq` survives the round trip.
  ///
  /// Both steps are safe to replay: the column is probed first (`ALTER TABLE`
  /// has no `IF NOT EXISTS`), and the backfill only touches rows that still
  /// have no `seq`.
  static Future<void> _addChatMessageSeq(Database db) async {
    if (!await _hasColumn(db, 'chat_messages', 'seq')) {
      await db.execute('ALTER TABLE chat_messages ADD COLUMN seq INTEGER');
    }
    await db.execute(
      'UPDATE chat_messages SET seq = rowid WHERE seq IS NULL',
    );
  }

  /// Adds `tasks.notification_id` and backfills the rows that predate it.
  ///
  /// The backfill reproduces `core/ids.dart`'s `fallbackNotificationId` exactly
  /// (`createdAt.millisecondsSinceEpoch & 0x7fffffff`), which is what
  /// `services/notification_ids.dart` returned before the column existed, so a
  /// reminder scheduled before the upgrade can still be cancelled after it.
  /// SQLite's `&` is a 64-bit two's-complement AND, which gives the same
  /// non-negative result as Dart's for a `created_at` before the epoch.
  ///
  /// `ALTER TABLE ... ADD COLUMN` has no `IF NOT EXISTS`, so the column is
  /// probed first; the backfill is idempotent on its own.
  static Future<void> _addTaskNotificationId(Database db) async {
    if (!await _hasColumn(db, 'tasks', 'notification_id')) {
      await db.execute('ALTER TABLE tasks ADD COLUMN notification_id INTEGER');
    }
    await db.execute(
      'UPDATE tasks SET notification_id = created_at & 2147483647 '
      'WHERE notification_id IS NULL',
    );
  }

  static Future<bool> _hasColumn(
    Database db,
    String table,
    String column,
  ) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows.any((row) => row['name'] == column);
  }
}
