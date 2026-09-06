/// A thin, tag-prefixed wrapper over `debugPrint`.
///
/// Existing call sites (e.g. `lib/services/ble_service.dart`) log with an
/// ad hoc `'[LibreOmi/BLE] ...'` prefix passed straight to `debugPrint`.
/// [Log] centralizes that convention: construct one with a tag such as
/// `'BLE'` and call [Log.d] instead of building the prefix by hand.
///
/// The actual sink is the top-level [logSink], which defaults to
/// `debugPrint` but can be reassigned in tests to capture emitted lines
/// without printing to the console.
library;

import 'package:flutter/foundation.dart';

/// The sink that [Log] writes to. Defaults to [debugPrint]; tests may
/// replace this with a function that records lines instead of printing
/// them, and should restore it afterwards.
void Function(String? message) logSink = debugPrint;

/// A tagged logger that prefixes every line with `[LibreOmi/<tag>]`,
/// matching the convention already used across `lib/services/`.
class Log {
  /// Creates a logger tagged with [tag], e.g. `Log('BLE')` produces lines
  /// prefixed with `[LibreOmi/BLE]`.
  const Log(this.tag);

  /// The component name shown in the log prefix.
  final String tag;

  /// Writes [message] to [logSink], prefixed with `[LibreOmi/<tag>]`.
  void d(String message) {
    logSink('[LibreOmi/$tag] $message');
  }
}
