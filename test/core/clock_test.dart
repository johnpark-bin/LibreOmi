import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/core/clock.dart';

void main() {
  group('SystemClock', () {
    test('now returns a time close to DateTime.now()', () {
      final clock = const SystemClock();
      final before = DateTime.now();
      final result = clock.now();
      final after = DateTime.now();

      expect(result.isBefore(before), isFalse);
      expect(result.isAfter(after), isFalse);
    });
  });

  group('FixedClock', () {
    test('now returns the fixed time', () {
      final fixed = DateTime.utc(2024, 1, 1, 12);
      final clock = FixedClock(fixed);
      expect(clock.now(), fixed);
    });

    test('advance moves the clock forward', () {
      final fixed = DateTime.utc(2024, 1, 1, 12);
      final clock = FixedClock(fixed);
      clock.advance(const Duration(hours: 1));
      expect(clock.now(), fixed.add(const Duration(hours: 1)));
    });

    test('advance is cumulative across multiple calls', () {
      final fixed = DateTime.utc(2024, 1, 1, 12);
      final clock = FixedClock(fixed);
      clock.advance(const Duration(minutes: 30));
      clock.advance(const Duration(minutes: 30));
      expect(clock.now(), fixed.add(const Duration(hours: 1)));
    });
  });
}
