/// A minimal, injectable id generator abstraction.
///
/// Code that needs to mint new identifiers (e.g. for a conversation or task
/// row) should depend on [IdGenerator] rather than calling `package:uuid`
/// directly, so tests can substitute a fake for deterministic ids. Pure
/// Dart, depending only on `package:uuid`.
///
/// [fallbackNotificationId] also lives here because both the data layer and
/// the notification helper need it and neither may depend on the other.
library;

import 'package:uuid/uuid.dart';

/// Generates new unique identifiers.
abstract class IdGenerator {
  /// Returns a newly generated unique id.
  String newId();
}

/// An [IdGenerator] that produces RFC 4122 version 4 (random) UUIDs.
class UuidIdGenerator implements IdGenerator {
  /// Creates a UUID-based id generator.
  UuidIdGenerator() : _uuid = const Uuid();

  final Uuid _uuid;

  @override
  String newId() => _uuid.v4();
}

/// The notification id derived from a task's creation time.
///
/// Awesome Notifications addresses a scheduled notification by a 32-bit signed
/// integer, so this folds the creation time into 31 bits. Two callers have to
/// agree on it and would drift if either owned it: the v5 migration backfills
/// `tasks.notification_id` with the same expression in SQL
/// (`created_at & 2147483647`, see `data/db.dart`), and
/// `services/notification_ids.dart` falls back to it for a task that has not
/// been through the database. The consequences of the fold are documented at
/// `notificationIdForTask`.
int fallbackNotificationId(DateTime createdAt) =>
    createdAt.millisecondsSinceEpoch & 0x7fffffff;
