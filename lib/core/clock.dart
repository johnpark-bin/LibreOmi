/// A minimal, injectable clock abstraction.
///
/// Code that needs "the current time" should depend on [Clock] rather than
/// calling `DateTime.now()` directly, so tests can substitute [FixedClock]
/// for deterministic behavior. Pure Dart (no Flutter import).
library;

/// Provides the current time.
abstract class Clock {
  /// Returns the current time.
  DateTime now();
}

/// A [Clock] backed by the real system time.
class SystemClock implements Clock {
  /// Creates a clock that delegates to `DateTime.now()`.
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}

/// A [Clock] that returns a fixed, test-controlled time.
///
/// Call [advance] to move the clock forward between assertions.
class FixedClock implements Clock {
  /// Creates a clock fixed at [initial].
  FixedClock(DateTime initial) : _current = initial;

  DateTime _current;

  @override
  DateTime now() => _current;

  /// Moves the clock forward by [duration].
  void advance(Duration duration) {
    _current = _current.add(duration);
  }
}
