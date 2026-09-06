import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/core/result.dart';

void main() {
  group('Success', () {
    const result = Success<int>(42);

    test('isSuccess/isFailure', () {
      expect(result.isSuccess, isTrue);
      expect(result.isFailure, isFalse);
    });

    test('valueOrNull returns the value', () {
      expect(result.valueOrNull, 42);
    });

    test('fold invokes onSuccess with the value', () {
      final folded = result.fold(
        onSuccess: (value) => 'ok:$value',
        onFailure: (message, cause) => 'err:$message',
      );
      expect(folded, 'ok:42');
    });
  });

  group('Failure', () {
    final cause = Exception('boom');
    late Failure<int> result;

    setUp(() {
      result = Failure<int>('something went wrong', cause: cause);
    });

    test('isSuccess/isFailure', () {
      expect(result.isSuccess, isFalse);
      expect(result.isFailure, isTrue);
    });

    test('valueOrNull returns null', () {
      expect(result.valueOrNull, isNull);
    });

    test('fold invokes onFailure with the message and cause', () {
      final folded = result.fold(
        onSuccess: (value) => 'ok:$value',
        onFailure: (message, cause) => 'err:$message:$cause',
      );
      expect(folded, 'err:something went wrong:$cause');
    });

    test('exposes message and cause fields', () {
      expect(result.message, 'something went wrong');
      expect(result.cause, cause);
    });
  });
}
