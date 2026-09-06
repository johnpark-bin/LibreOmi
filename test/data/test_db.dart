/// Shared setup for the `lib/data` repository tests.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:libreomi/data/db.dart';

/// Points the global `databaseFactory` at `sqflite_common_ffi`, which is what
/// lets these tests run on a laptop instead of a device.
void useFfiDatabaseFactory() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
}

/// An empty in-memory database with the current schema, closed at the end of
/// the test. `singleInstance: false` so each test gets its own.
Future<Database> openTestDb() async {
  final db = await databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await AppDatabase.createSchema(db);
  addTearDown(db.close);
  return db;
}
