import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' show join;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:libreomi/services/database_service.dart';

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

Future<Database> _openV3() async {
  final db = await databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(version: 3, singleInstance: false),
  );
  for (final statement in _schemaV3) {
    await db.execute(statement);
  }
  return db;
}

Future<Set<String>> _tableNames(Database db) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table'",
  );
  return rows.map((row) => row['name'] as String).toSet();
}

Future<Map<String, String>> _columns(Database db, String table) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return <String, String>{
    for (final row in rows) row['name'] as String: row['type'] as String,
  };
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('DatabaseService schema v4', () {
    test('the declared version is 4', () {
      expect(DatabaseService.dbVersion, 4);
    });

    test('a v3 database gains pending_finalizations', () async {
      final db = await _openV3();
      addTearDown(db.close);

      expect(await _tableNames(db), isNot(contains('pending_finalizations')));

      await DatabaseService.migrate(db, 3, DatabaseService.dbVersion);

      expect(await _tableNames(db), contains('pending_finalizations'));
      expect(await _columns(db, 'pending_finalizations'), <String, String>{
        'id': 'TEXT',
        'conversation_id': 'TEXT',
        'transcript': 'TEXT',
        'attempts': 'INTEGER',
        'next_attempt_at': 'INTEGER',
        'last_error': 'TEXT',
        'created_at': 'INTEGER',
      });
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

      await DatabaseService.migrate(db, 3, DatabaseService.dbVersion);

      final conversations = await db.query('conversations');
      expect(conversations, hasLength(1));
      expect(conversations.single['title'], 'Before the upgrade');
      expect(await db.query('memories'), hasLength(1));
    });

    test('a fresh install gets the same tables as an upgraded one', () async {
      final fresh = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: DatabaseService.dbVersion,
          singleInstance: false,
        ),
      );
      addTearDown(fresh.close);
      await DatabaseService.createSchema(fresh);

      final upgraded = await _openV3();
      addTearDown(upgraded.close);
      await DatabaseService.migrate(upgraded, 3, DatabaseService.dbVersion);

      expect(await _tableNames(fresh), equals(await _tableNames(upgraded)));
      expect(
        await _columns(fresh, 'pending_finalizations'),
        equals(await _columns(upgraded, 'pending_finalizations')),
      );
    });

    test('a v1 database walks every step up to v4', () async {
      final db = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(version: 1, singleInstance: false),
      );
      addTearDown(db.close);
      await db.execute(_schemaV3.first);

      await DatabaseService.migrate(db, 1, DatabaseService.dbVersion);

      final tables = await _tableNames(db);
      expect(tables, containsAll(<String>['memories', 'tasks', 'pending_finalizations']));
    });

    test('running the same upgrade twice keeps the queued rows', () async {
      final db = await _openV3();
      addTearDown(db.close);
      await DatabaseService.migrate(db, 3, DatabaseService.dbVersion);

      await db.insert('pending_finalizations', <String, Object?>{
        'id': 'p1',
        'conversation_id': 'c1',
        'transcript': 'hello',
        'attempts': 0,
        'next_attempt_at': 1000,
        'created_at': 1000,
      });

      // The same step, not `migrate(db, 4, 4)`: replaying v3 -> v4 is what
      // actually exercises the `IF NOT EXISTS` guard. An interrupted upgrade
      // can leave a device asking for this step a second time.
      await DatabaseService.migrate(db, 3, DatabaseService.dbVersion);

      expect(await db.query('pending_finalizations'), hasLength(1));
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
      await v3.close();

      final v4 = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: DatabaseService.dbVersion,
          onCreate: (db, version) => DatabaseService.createSchema(db),
          onUpgrade: DatabaseService.migrate,
        ),
      );
      addTearDown(v4.close);

      expect(await v4.getVersion(), DatabaseService.dbVersion);
      expect(await _tableNames(v4), contains('pending_finalizations'));
      expect((await v4.query('conversations')).single['title'],
          'Survives the upgrade');
    });
  });
}
