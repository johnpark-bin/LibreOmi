import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/core/ids.dart';

void main() {
  group('UuidIdGenerator', () {
    test('newId returns a well-formed v4 UUID', () {
      final generator = UuidIdGenerator();
      final id = generator.newId();

      final v4Pattern = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(v4Pattern.hasMatch(id), isTrue);
    });

    test('newId returns unique values across calls', () {
      final generator = UuidIdGenerator();
      final ids = List.generate(20, (_) => generator.newId());
      expect(ids.toSet().length, ids.length);
    });
  });
}
