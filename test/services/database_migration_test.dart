import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:libreomi/data/db.dart';
import 'package:libreomi/services/database_service.dart';

// The migration itself is covered in `test/data/db_test.dart`, which owns the
// frozen per-version DDL. What this file protects is the other half of LO-35:
// `DatabaseService` stayed a facade, so every caller that still says
// `DatabaseService.migrate` has to reach the same schema as `AppDatabase`.

/// The v3 schema exactly as it shipped, frozen on purpose.
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

Future<Database> _openEmpty(int version) => databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: version, singleInstance: false),
    );

Future<Map<String, Map<String, String>>> _schema(Database db) async {
  final tables = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table'",
  );
  final result = <String, Map<String, String>>{};
  for (final table in tables) {
    final name = table['name'] as String;
    if (name.startsWith('sqlite_') || name == 'android_metadata') continue;
    final columns = await db.rawQuery('PRAGMA table_info($name)');
    result[name] = <String, String>{
      for (final column in columns)
        column['name'] as String: column['type'] as String,
    };
  }
  return result;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('DatabaseService schema facade', () {
    test('reports the AppDatabase version, which is 5', () {
      expect(DatabaseService.dbVersion, AppDatabase.schemaVersion);
      expect(DatabaseService.dbVersion, 5);
    });

    test('createSchema builds exactly the AppDatabase schema', () async {
      final viaFacade = await _openEmpty(DatabaseService.dbVersion);
      addTearDown(viaFacade.close);
      await DatabaseService.createSchema(viaFacade);

      final direct = await _openEmpty(AppDatabase.schemaVersion);
      addTearDown(direct.close);
      await AppDatabase.createSchema(direct);

      expect(await _schema(viaFacade), equals(await _schema(direct)));
    });

    test('migrate walks a v3 database all the way to v5', () async {
      final viaFacade = await _openV3();
      addTearDown(viaFacade.close);
      await DatabaseService.migrate(viaFacade, 3, DatabaseService.dbVersion);

      final direct = await _openV3();
      addTearDown(direct.close);
      await AppDatabase.migrate(direct, 3, AppDatabase.schemaVersion);

      expect(await _schema(viaFacade), equals(await _schema(direct)));
      expect(
        (await _schema(viaFacade))['tasks'],
        contains('notification_id'),
      );
    });

    test('createPendingFinalizationsTable still creates the queue table',
        () async {
      // `FinalizationQueue`'s own tests call this static; LO-35 must not have
      // moved it out from under them.
      final db = await _openEmpty(DatabaseService.dbVersion);
      addTearDown(db.close);

      await DatabaseService.createPendingFinalizationsTable(db);

      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      );
      expect(
        tables.map((row) => row['name']),
        contains('pending_finalizations'),
      );
    });
  });
}
