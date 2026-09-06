import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/services/ble/reconnect_backoff.dart';

/// A fake [Random] that always returns a fixed `nextDouble()` value, so
/// jitter tests are fully deterministic.
class _FixedRandom implements Random {
  _FixedRandom(this.value);

  final double value;

  @override
  double nextDouble() => value;

  @override
  int nextInt(int max) => 0;

  @override
  bool nextBool() => false;
}

void main() {
  group('ReconnectBackoff ladder (jitter disabled)', () {
    test('follows the 5/10/20/40/60... ladder and caps at 60s', () {
      final backoff = ReconnectBackoff(jitterFraction: 0);

      expect(backoff.attempt, 0);
      expect(backoff.currentBaseDelay, const Duration(seconds: 5));

      expect(backoff.nextDelay(), const Duration(seconds: 5));
      expect(backoff.attempt, 1);

      expect(backoff.nextDelay(), const Duration(seconds: 10));
      expect(backoff.attempt, 2);

      expect(backoff.nextDelay(), const Duration(seconds: 20));
      expect(backoff.attempt, 3);

      expect(backoff.nextDelay(), const Duration(seconds: 40));
      expect(backoff.attempt, 4);

      expect(backoff.nextDelay(), const Duration(seconds: 60));
      expect(backoff.attempt, 5);

      // Further attempts stay capped at 60s.
      expect(backoff.nextDelay(), const Duration(seconds: 60));
      expect(backoff.attempt, 6);
    });

    test('cap holds across many attempts without overflow or going negative', () {
      final backoff = ReconnectBackoff(jitterFraction: 0);

      for (var i = 0; i < 20; i++) {
        final delay = backoff.nextDelay();
        expect(delay.isNegative, isFalse);
        expect(delay, lessThanOrEqualTo(const Duration(seconds: 60)));
        if (i >= 4) {
          expect(delay, const Duration(seconds: 60));
        }
      }
      expect(backoff.attempt, 20);
      expect(backoff.currentBaseDelay, const Duration(seconds: 60));
    });

    test('reset() returns the ladder to the initial 5s delay', () {
      final backoff = ReconnectBackoff(jitterFraction: 0);

      backoff.nextDelay();
      backoff.nextDelay();
      backoff.nextDelay();
      expect(backoff.attempt, 3);
      expect(backoff.currentBaseDelay, const Duration(seconds: 40));

      backoff.reset();

      expect(backoff.attempt, 0);
      expect(backoff.currentBaseDelay, const Duration(seconds: 5));
      expect(backoff.nextDelay(), const Duration(seconds: 5));
    });

    test('attempt counts delays handed out since construction/reset', () {
      final backoff = ReconnectBackoff(jitterFraction: 0);
      expect(backoff.attempt, 0);
      for (var i = 1; i <= 5; i++) {
        backoff.nextDelay();
        expect(backoff.attempt, i);
      }
    });
  });

  group('ReconnectBackoff jitter', () {
    test('jitter of 0 returns the exact unjittered base delay', () {
      final backoff = ReconnectBackoff(jitterFraction: 0);
      expect(backoff.nextDelay(), backoff.initialDelay);
    });

    test('with a fake Random pinned to 1.0 (max positive jitter), '
        'the delay is base * (1 + jitterFraction)', () {
      final backoff = ReconnectBackoff(
        jitterFraction: 0.1,
        random: _FixedRandom(1.0),
      );

      final delay = backoff.nextDelay();
      final expectedMicros = const Duration(seconds: 5).inMicroseconds * 1.1;
      expect(delay.inMicroseconds, closeTo(expectedMicros, 1));
    });

    test('with a fake Random pinned to 0.0 (max negative jitter), '
        'the delay is base * (1 - jitterFraction)', () {
      final backoff = ReconnectBackoff(
        jitterFraction: 0.1,
        random: _FixedRandom(0.0),
      );

      final delay = backoff.nextDelay();
      final expectedMicros = const Duration(seconds: 5).inMicroseconds * 0.9;
      expect(delay.inMicroseconds, closeTo(expectedMicros, 1));
    });

    test('with a fake Random pinned to 0.5 (no jitter offset), '
        'the delay equals the base exactly', () {
      final backoff = ReconnectBackoff(
        jitterFraction: 0.1,
        random: _FixedRandom(0.5),
      );

      expect(backoff.nextDelay(), const Duration(seconds: 5));
    });

    test('every jittered value stays within +/-10% of the base and positive '
        'across many attempts with a real seeded Random', () {
      final backoff = ReconnectBackoff(
        jitterFraction: 0.1,
        random: Random(42),
      );

      final bases = <Duration>[];
      for (var i = 0; i < 20; i++) {
        final base = backoff.currentBaseDelay;
        final delay = backoff.nextDelay();
        bases.add(base);

        expect(delay.isNegative, isFalse);
        final lowerBound = base.inMicroseconds * 0.9;
        final upperBound = base.inMicroseconds * 1.1;
        expect(delay.inMicroseconds, greaterThanOrEqualTo(lowerBound - 1));
        expect(delay.inMicroseconds, lessThanOrEqualTo(upperBound + 1));
      }

      // Sanity check the ladder itself was still followed underneath the
      // jitter (5, 10, 20, 40, 60, 60, ...).
      expect(bases[0], const Duration(seconds: 5));
      expect(bases[1], const Duration(seconds: 10));
      expect(bases[2], const Duration(seconds: 20));
      expect(bases[3], const Duration(seconds: 40));
      expect(bases[4], const Duration(seconds: 60));
      expect(bases[19], const Duration(seconds: 60));
    });
  });
}
