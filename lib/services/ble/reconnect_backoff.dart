/// Pure-Dart exponential backoff calculator for BLE reconnection attempts.
///
/// This file intentionally has no dependency on `package:flutter_blue_plus`
/// or any Flutter widget code so it can be unit tested without a BLE stack
/// or a Flutter widget test harness.
library;

import 'dart:math';

/// Computes the delay to wait before the next BLE reconnection attempt,
/// following an exponential ladder (5s, 10s, 20s, 40s, capped at 60s) with
/// random jitter applied on top.
///
/// Jitter exists so that when many devices lose their connection at the
/// same time (e.g. after a phone-side BLE stack hiccup or an app restart),
/// they do not all retry in lockstep and hammer the peripheral/radio at the
/// exact same instant; spreading retries out slightly avoids a "thundering
/// herd" of simultaneous reconnect attempts.
class ReconnectBackoff {
  ReconnectBackoff({
    this.initialDelay = const Duration(seconds: 5),
    this.maxDelay = const Duration(seconds: 60),
    this.jitterFraction = 0.1,
    Random? random,
  }) : _random = random ?? Random();

  /// The base delay used for the very first attempt after a reset.
  final Duration initialDelay;

  /// The cap on the unjittered base delay. The jittered value returned by
  /// [nextDelay] may exceed this by up to [jitterFraction], but the base
  /// delay itself never does.
  final Duration maxDelay;

  /// Fraction (e.g. 0.1 for +/-10%) of uniform jitter applied to the base
  /// delay each time [nextDelay] is called.
  final double jitterFraction;

  final Random _random;

  int _attempt = 0;

  /// How many delays have been handed out since the last [reset]. Zero
  /// right after construction or a call to [reset].
  int get attempt => _attempt;

  /// The unjittered delay that the next call to [nextDelay] will jitter and
  /// return. Useful for logging and for deterministic assertions in tests.
  Duration get currentBaseDelay {
    // Guard against overflow: instead of computing
    // `initialDelay * 2^attempt` (which can overflow for a large attempt
    // count), double a running value step by step and stop as soon as it
    // reaches the cap.
    var base = initialDelay;
    for (var i = 0; i < _attempt; i++) {
      if (base >= maxDelay) {
        return maxDelay;
      }
      final doubled = base * 2;
      base = doubled >= maxDelay ? maxDelay : doubled;
    }
    return base > maxDelay ? maxDelay : base;
  }

  /// Returns the delay to wait before the next reconnection attempt, with
  /// uniform jitter of +/- [jitterFraction] applied to [currentBaseDelay],
  /// then advances the internal attempt counter.
  ///
  /// The returned value is never negative and never exceeds
  /// `maxDelay * (1 + jitterFraction)`.
  Duration nextDelay() {
    final base = currentBaseDelay;
    _attempt++;

    if (jitterFraction <= 0) {
      return base;
    }

    // Uniform jitter in [-jitterFraction, +jitterFraction] of the base.
    final jitterRange = base.inMicroseconds * jitterFraction;
    final offset = (_random.nextDouble() * 2 - 1) * jitterRange;
    final jitteredMicros = base.inMicroseconds + offset;

    final maxAllowedMicros = maxDelay.inMicroseconds * (1 + jitterFraction);
    final clampedMicros = jitteredMicros.clamp(0.0, maxAllowedMicros);

    return Duration(microseconds: clampedMicros.round());
  }

  /// Resets the backoff back to [initialDelay] and [attempt] `0`. Call this
  /// after a successful connection so the next disconnect starts the ladder
  /// over from the beginning.
  void reset() {
    _attempt = 0;
  }
}
