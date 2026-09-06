/// A minimal, injectable id generator abstraction.
///
/// Code that needs to mint new identifiers (e.g. for a conversation or task
/// row) should depend on [IdGenerator] rather than calling `package:uuid`
/// directly, so tests can substitute a fake for deterministic ids. Pure
/// Dart, depending only on `package:uuid`.
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
