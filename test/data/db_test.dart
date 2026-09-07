import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' show join;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:libreomi/data/db.dart';

/// The v3 schema exactly as it shipped, frozen here on purpose: a migration
/// test that reuses the current DDL would pass even if a migration step were
/// missing.
const List<String> _schemaV3 = <String>[
  '''
  CREATE TABLE conversations (
    id TEXT PRIMARY KEY,
    created_at INTEGER NOT NULL,
    title TEXT,
    summary TEXT,
    transcript TEXT
  )
  ''',
  '''
  CREATE TABLE chat_messages (
    id TEXT PRIMARY KEY,
    conversation_id TEXT,
    text TEXT NOT NULL,
    is_user INTEGER NOT NULL,
    created_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE memories (
    id TEXT PRIMARY KEY,
    content TEXT NOT NULL,
    category TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    source_conversation_id TEXT
  )
  ''',
  '''
  CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    description TEXT,
    due_date INTEGER,
    created_at INTEGER NOT NULL,
    source_conversation_id TEXT,
    is_completed INTEGER NOT NULL DEFAULT 0
  )
  ''',
];

/// The v4 addition, likewise frozen.
const String _pendingFinalizationsV4 = '''
  CREATE TABLE pending_finalizations (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    transcript TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL,
    last_error TEXT,
    created_at INTEGER NOT NULL
  )
''';

Future<Database> _openAt(int version, List<String> schema) async {
  final db = await databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(version: version, singleInstance: false),
  );
  for (final statement in schema) {
    await db.execute(statement);
  }
  return db;
}

/// The v5 schema, frozen for the same reason: `tasks` gained
/// `notification_id` and `chat_messages` still had no `seq`.
const List<String> _schemaV5 = <String>[
  '''
  CREATE TABLE conversations (
    id TEXT PRIMARY KEY,
    created_at INTEGER NOT NULL,
    title TEXT,
    summary TEXT,
    transcript TEXT
  )
  ''',
  '''
  CREATE TABLE chat_messages (
    id TEXT PRIMARY KEY,
    conversation_id TEXT,
    text TEXT NOT NULL,
    is_user INTEGER NOT NULL,
    created_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE memories (
    id TEXT PRIMARY KEY,
    content TEXT NOT NULL,
    category TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    source_conversation_id TEXT
  )
  ''',
  '''
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
  ''',
  _pendingFinalizationsV4,
];

Future<Database> _openV3() => _openAt(3, _schemaV3);

Future<Database> _openV4() =>
    _openAt(4, <String>[..._schemaV3, _pendingFinalizationsV4]);

Future<Database> _openV5() => _openAt(5, _schemaV5);

/// Writes one pre-v6 chat row. No `seq`: the column is what the v6 step adds.
Future<void> _insertChatMessage(
  Database db, {
  required String id,
  required int createdAt,
  String text = 'hello',
  bool isUser = true,
}) async {
  await db.insert('chat_messages', <String, Object?>{
    'id': id,
    'conversation_id': null,
    'text': text,
    'is_user': isUser ? 1 : 0,
    'created_at': createdAt,
  });
}

Future<List<Object?>> _chatSeqsById(Database db) async {
  final rows = await db.query('chat_messages', orderBy: 'id ASC');
  return rows.map((row) => row['seq']).toList();
}

Future<Set<String>> _tableNames(Database db) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table'",
  );
  return rows.map((row) => row['name'] as String).toSet();
}

/// Every column's full definition, not just its type: a fresh install and an
/// upgraded one can agree on names and types while differing in `NOT NULL`,
/// a default, or the primary key.
Future<Map<String, Map<String, Object?>>> _columns(
  Database db,
  String table,
) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return <String, Map<String, Object?>>{
    for (final row in rows)
      row['name'] as String: <String, Object?>{
        'type': row['type'],
        'notnull': row['notnull'],
        'dflt_value': row['dflt_value'],
        'pk': row['pk'],
      },
  };
}

Future<void> _insertTask(
  Database db, {
  required String id,
  required int createdAt,
}) async {
  await db.insert('tasks', <String, Object?>{
    'id': id,
    'title': 'Buy milk',
    'description': null,
    'due_date': createdAt + 3600000,
    'created_at': createdAt,
    'source_conversation_id': null,
    'is_completed': 0,
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('AppDatabase schema v6', () {
    test('the declared version is 6', () {
      expect(AppDatabase.schemaVersion, 6);
    });

    test('createPendingFinalizationsTable creates the queue table on its own',
        () async {
      // `FinalizationQueue` and its tests build the queue table without going
      // through `createSchema`, so the standalone entry point has to work on an
      // otherwise empty database — and stay replayable, because an upgrade
      // interrupted by a crash asks for the v4 step again on the next launch.
      final db = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(db.close);

      await AppDatabase.createPendingFinalizationsTable(db);
      await AppDatabase.createPendingFinalizationsTable(db);

      expect(await _tableNames(db), contains('pending_finalizations'));
      expect(
        (await _columns(db, 'pending_finalizations')).keys,
        containsAll(<String>[
          'id',
          'conversation_id',
          'transcript',
          'attempts',
          'next_attempt_at',
          'last_error',
          'created_at',
        ]),
      );
    });

    test('a v4 database gains tasks.notification_id', () async {
      final db = await _openV4();
      addTearDown(db.close);

      expect(await _columns(db, 'tasks'), isNot(contains('notification_id')));

      await AppDatabase.migrate(db, 4, AppDatabase.schemaVersion);

      expect(await _columns(db, 'tasks'), contains('notification_id'));
    });

    test('existing tasks are backfilled with the pre-v5 derivation', () async {
      final db = await _openV4();
      addTearDown(db.close);

      // The same value `notificationIdForTask` computed before the column
      // existed: a reminder scheduled before the upgrade has to stay
      // cancellable after it.
      const createdAt = 1757155845123; // 2025-09-06T…, arbitrary but fixed
      await _insertTask(db, id: 't1', createdAt: createdAt);

      await AppDatabase.migrate(db, 4, AppDatabase.schemaVersion);

      final row = (await db.query('tasks', where: 'id = ?', whereArgs: ['t1']))
          .single;
      expect(row['notification_id'], createdAt & 0x7fffffff);
    });

    test('the backfill stays non-negative for a pre-epoch created_at', () async {
      final db = await _openV4();
      addTearDown(db.close);

      // Dart's `& 0x7fffffff` on a negative int yields a positive one; SQLite's
      // 64-bit two's-complement AND has to agree, or a task created before 1970
      // (a wrong device clock, an imported row) would get a negative id that
      // Awesome Notifications rejects.
      const createdAt = -14182940000; // 1969-07-20
      await _insertTask(db, id: 'pre-epoch', createdAt: createdAt);

      await AppDatabase.migrate(db, 4, AppDatabase.schemaVersion);

      final row = (await db.query(
        'tasks',
        where: 'id = ?',
        whereArgs: ['pre-epoch'],
      )).single;
      expect(row['notification_id'], createdAt & 0x7fffffff);
      expect(row['notification_id'] as int, greaterThanOrEqualTo(0));
      expect(row['notification_id'] as int, lessThanOrEqualTo(0x7fffffff));
    });

    test('a v4 database without chat_messages gains it', () async {
      // `chat_messages` shipped in the v1 create-schema but was never part of a
      // migration step, so a database that walked up from v1 can be missing it.
      final withoutChat = <String>[
        ..._schemaV3.where((s) => !s.contains('CREATE TABLE chat_messages')),
        _pendingFinalizationsV4,
      ];
      final db = await _openAt(4, withoutChat);
      addTearDown(db.close);

      expect(await _tableNames(db), isNot(contains('chat_messages')));

      await AppDatabase.migrate(db, 4, AppDatabase.schemaVersion);

      expect(await _tableNames(db), contains('chat_messages'));
    });

    test('a v3 database walks v4, v5 and v6 in one upgrade', () async {
      final db = await _openV3();
      addTearDown(db.close);
      await _insertTask(db, id: 't1', createdAt: 1000);

      await AppDatabase.migrate(db, 3, AppDatabase.schemaVersion);

      expect(await _tableNames(db), contains('pending_finalizations'));
      expect(await _columns(db, 'tasks'), contains('notification_id'));
      expect(
        (await db.query('tasks')).single['notification_id'],
        1000 & 0x7fffffff,
      );
    });

    test('the upgrade keeps the rows a user already had', () async {
      final db = await _openV3();
      addTearDown(db.close);

      await db.insert('conversations', <String, Object?>{
        'id': 'c1',
        'created_at': 1000,
        'title': 'Before the upgrade',
        'summary': 'kept',
        'transcript': '[]',
      });
      await db.insert('memories', <String, Object?>{
        'id': 'm1',
        'content': 'User drinks tea',
        'category': 'fact',
        'created_at': 1000,
        'source_conversation_id': 'c1',
      });
      await _insertTask(db, id: 't1', createdAt: 1000);
      await db.insert('chat_messages', <String, Object?>{
        'id': 'cm1',
        'conversation_id': null,
        'text': 'what did I say about tea',
        'is_user': 1,
        'created_at': 1000,
      });

      await AppDatabase.migrate(db, 3, AppDatabase.schemaVersion);

      expect(
        (await db.query('conversations')).single['title'],
        'Before the upgrade',
      );
      expect(await db.query('memories'), hasLength(1));
      expect((await db.query('tasks')).single['title'], 'Buy milk');
      expect(await db.query('chat_messages'), hasLength(1));
    });

    test('a fresh install gets the same tables and columns as an upgraded one',
        () async {
      final fresh = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: AppDatabase.schemaVersion,
          singleInstance: false,
        ),
      );
      addTearDown(fresh.close);
      await AppDatabase.createSchema(fresh);

      final upgraded = await _openV3();
      addTearDown(upgraded.close);
      await AppDatabase.migrate(upgraded, 3, AppDatabase.schemaVersion);

      expect(await _tableNames(fresh), equals(await _tableNames(upgraded)));
      for (final table in <String>[
        'conversations',
        'chat_messages',
        'memories',
        'tasks',
        'pending_finalizations',
      ]) {
        expect(
          await _columns(fresh, table),
          equals(await _columns(upgraded, table)),
          reason: table,
        );
      }
    });

    test('a v5 database gains chat_messages.seq', () async {
      final db = await _openV5();
      addTearDown(db.close);

      expect(await _columns(db, 'chat_messages'), isNot(contains('seq')));

      await AppDatabase.migrate(db, 5, AppDatabase.schemaVersion);

      expect(await _columns(db, 'chat_messages'), contains('seq'));
    });

    test('the v6 backfill keeps the order the rows were written in', () async {
      // Written oldest-last and with two of them sharing a `created_at`, which
      // is exactly the case the column exists for: the backfill has to come
      // from `rowid`, the order the inserts actually happened in, not from the
      // timestamps.
      final db = await _openV5();
      addTearDown(db.close);
      await _insertChatMessage(db, id: 'a', createdAt: 2000, text: 'first');
      await _insertChatMessage(db, id: 'b', createdAt: 1000, text: 'second');
      await _insertChatMessage(db, id: 'c', createdAt: 1000, text: 'third');

      await AppDatabase.migrate(db, 5, AppDatabase.schemaVersion);

      final rows = await db.query('chat_messages', orderBy: 'seq ASC');
      expect(rows.map((row) => row['text']), ['first', 'second', 'third']);
    });

    test('replaying the v6 step leaves the backfilled order alone', () async {
      final db = await _openV5();
      addTearDown(db.close);
      await _insertChatMessage(db, id: 'a', createdAt: 1000);
      await _insertChatMessage(db, id: 'b', createdAt: 1000);

      await AppDatabase.migrate(db, 5, AppDatabase.schemaVersion);
      final afterFirst = await _chatSeqsById(db);
      await AppDatabase.migrate(db, 5, AppDatabase.schemaVersion);

      expect(await _chatSeqsById(db), equals(afterFirst));
      expect(afterFirst, everyElement(isNotNull));
    });

    test('a v1 database walks every step up to v6', () async {
      final db = await _openAt(1, <String>[_schemaV3.first]);
      addTearDown(db.close);

      await AppDatabase.migrate(db, 1, AppDatabase.schemaVersion);

      expect(
        await _tableNames(db),
        containsAll(<String>[
          'memories',
          'tasks',
          'pending_finalizations',
          'chat_messages',
        ]),
      );
      expect(await _columns(db, 'tasks'), contains('notification_id'));
      expect(await _columns(db, 'chat_messages'), contains('seq'));
    });

    test('replaying the upgrade keeps rows and ids untouched', () async {
      final db = await _openV3();
      addTearDown(db.close);
      await _insertTask(db, id: 't1', createdAt: 1000);
      await AppDatabase.migrate(db, 3, AppDatabase.schemaVersion);

      await db.insert('pending_finalizations', <String, Object?>{
        'id': 'p1',
        'conversation_id': 'c1',
        'transcript': 'hello',
        'attempts': 0,
        'next_attempt_at': 1000,
        'created_at': 1000,
      });
      // A task saved after the upgrade carries an id that is *not* the
      // derivation, which the replayed backfill must leave alone.
      await db.update(
        'tasks',
        <String, Object?>{'notification_id': 7},
        where: 'id = ?',
        whereArgs: ['t1'],
      );

      // The same step, not `migrate(db, 5, 5)`: replaying v3 -> v5 is what
      // exercises the guards. An interrupted upgrade can leave a device asking
      // for these steps a second time.
      await AppDatabase.migrate(db, 3, AppDatabase.schemaVersion);

      expect(await db.query('pending_finalizations'), hasLength(1));
      expect((await db.query('tasks')).single['notification_id'], 7);
    });

    test('openDatabase runs the upgrade through onUpgrade', () async {
      // The tests above call `migrate` directly, which would still pass if the
      // callback were wired up wrongly. This one goes through the real
      // `openDatabase` path on a temp file, which an in-memory database cannot
      // do: it has to survive being closed and reopened at the new version.
      final directory = await Directory.systemTemp.createTemp('libreomi_db');
      addTearDown(() => directory.delete(recursive: true));
      final path = join(directory.path, 'migration.db');

      final v3 = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (db, version) async {
            for (final statement in _schemaV3) {
              await db.execute(statement);
            }
          },
        ),
      );
      await v3.insert('conversations', <String, Object?>{
        'id': 'c1',
        'created_at': 1000,
        'title': 'Survives the upgrade',
        'summary': '',
        'transcript': '[]',
      });
      await _insertTask(v3, id: 't1', createdAt: 1000);
      await v3.close();

      final v5 = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: AppDatabase.schemaVersion,
          onCreate: (db, version) => AppDatabase.createSchema(db),
          onUpgrade: AppDatabase.migrate,
        ),
      );
      addTearDown(v5.close);

      expect(await v5.getVersion(), AppDatabase.schemaVersion);
      expect(await _tableNames(v5), contains('pending_finalizations'));
      expect(
        (await v5.query('conversations')).single['title'],
        'Survives the upgrade',
      );
      expect(
        (await v5.query('tasks')).single['notification_id'],
        1000 & 0x7fffffff,
      );
    });
  });
}
