import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/core/clock.dart';
import 'package:libreomi/session/silence_detector.dart';

/// A fake [SessionTimerFactory] that never actually waits: it captures the
/// scheduled callback so the test can fire it manually, and records
/// cancellations so tests can assert a timer was replaced rather than
/// stacked. This is how the detector is made deterministic without
/// `package:fake_async`.
class FakeTimerFactory {
  int createdCount = 0;
  int cancelledCount = 0;
  void Function()? _pendingCallback;

  /// The durations the detector asked for, in order. Recorded so a test can
  /// pin the timeout itself, not just the arm/cancel bookkeeping.
  final List<Duration> requestedDurations = [];

  Timer call(Duration duration, void Function() callback) {
    createdCount++;
    requestedDurations.add(duration);
    _pendingCallback = callback;
    return _FakeTimer(this);
  }

  /// Simulates the timer elapsing: invokes the callback as the real `Timer`
  /// would, then clears it (a fired timer cannot fire twice).
  void fire() {
    final callback = _pendingCallback;
    _pendingCallback = null;
    callback?.call();
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this._factory);
  final FakeTimerFactory _factory;
  bool _cancelled = false;

  @override
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _factory.cancelledCount++;
    // Cancelling drops the pending callback, matching a real Timer.
    _factory._pendingCallback = null;
  }

  @override
  bool get isActive => !_cancelled;

  @override
  int get tick => 0;
}

void main() {
  group('the timeout itself', () {
    test('defaults to the 2 minutes docs/03 §4 specifies', () {
      expect(SilenceDetector().timeout, const Duration(minutes: 2));
    });

    test('arms the timer for exactly that duration', () {
      final timers = FakeTimerFactory();
      SilenceDetector(createTimer: timers.call).noteActivity();

      expect(timers.requestedDurations, [const Duration(minutes: 2)]);
    });
  });

  group('SilenceDetector', () {
    test('arms on first activity', () {
      final factory = FakeTimerFactory();
      final detector = SilenceDetector(createTimer: factory.call);

      expect(detector.isArmed, isFalse);

      detector.noteActivity();

      expect(detector.isArmed, isTrue);
      expect(factory.createdCount, 1);
    });

    test('re-arming cancels the previous timer instead of stacking', () {
      final factory = FakeTimerFactory();
      final detector = SilenceDetector(createTimer: factory.call);

      detector.noteActivity();
      detector.noteActivity();

      expect(factory.createdCount, 2);
      expect(factory.cancelledCount, 1);
      expect(detector.isArmed, isTrue);
    });

    test('firing calls onSilence and clears isArmed', () {
      final factory = FakeTimerFactory();
      final detector = SilenceDetector(createTimer: factory.call);
      var fired = false;
      detector.onSilence = () => fired = true;

      detector.noteActivity();
      factory.fire();

      expect(fired, isTrue);
      expect(detector.isArmed, isFalse);
    });

    test('cancel() prevents the callback from firing', () {
      final factory = FakeTimerFactory();
      final detector = SilenceDetector(createTimer: factory.call);
      var fired = false;
      detector.onSilence = () => fired = true;

      detector.noteActivity();
      detector.cancel();
      factory.fire();

      expect(fired, isFalse);
      expect(detector.isArmed, isFalse);
    });

    test('cancel() on a never-armed detector is a no-op', () {
      final factory = FakeTimerFactory();
      final detector = SilenceDetector(createTimer: factory.call);

      expect(() => detector.cancel(), returnsNormally);
      expect(detector.isArmed, isFalse);
      expect(factory.cancelledCount, 0);
    });

    test('lastActivityAt follows an injected FixedClock', () {
      final clock = FixedClock(DateTime(2026, 1, 1, 12));
      final factory = FakeTimerFactory();
      final detector = SilenceDetector(clock: clock, createTimer: factory.call);

      expect(detector.lastActivityAt, isNull);

      detector.noteActivity();
      expect(detector.lastActivityAt, DateTime(2026, 1, 1, 12));

      clock.advance(const Duration(minutes: 1));
      detector.noteActivity();
      expect(detector.lastActivityAt, DateTime(2026, 1, 1, 12, 1));
    });

    test('a fired timeout with no onSilence set does not throw', () {
      final factory = FakeTimerFactory();
      final detector = SilenceDetector(createTimer: factory.call);

      detector.noteActivity();

      expect(() => factory.fire(), returnsNormally);
      expect(detector.isArmed, isFalse);
    });

    test('dispose cancels and drops onSilence', () {
      final factory = FakeTimerFactory();
      final detector = SilenceDetector(createTimer: factory.call);
      var fired = false;
      detector.onSilence = () => fired = true;

      detector.noteActivity();
      detector.dispose();
      factory.fire();

      expect(fired, isFalse);
      expect(detector.isArmed, isFalse);
    });
  });
}
