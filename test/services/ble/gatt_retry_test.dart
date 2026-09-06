import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/services/ble/gatt_retry.dart';

void main() {
  group('isRetryableGattStatus', () {
    test('gattErrorStatus (133) is retryable', () {
      expect(isRetryableGattStatus(gattErrorStatus), isTrue);
    });

    test('gattFailureStatus (257) is retryable', () {
      expect(isRetryableGattStatus(gattFailureStatus), isTrue);
    });

    test('0 is not retryable', () {
      expect(isRetryableGattStatus(0), isFalse);
    });

    test('8 (connection timeout) is not retryable', () {
      expect(isRetryableGattStatus(8), isFalse);
    });

    test('19 is not retryable', () {
      expect(isRetryableGattStatus(19), isFalse);
    });

    test('147 is not retryable', () {
      expect(isRetryableGattStatus(147), isFalse);
    });
  });

  group('gattStatusOf', () {
    test('parses a FlutterBluePlusException-shaped android-code string', () {
      final error = Exception(
        'FlutterBluePlusException | connect | android-code: 133 | GATT_ERROR',
      );
      expect(gattStatusOf(error), 133);
    });

    test('parses a FlutterBluePlusException-shaped apple-code string', () {
      const error =
          'FlutterBluePlusException | connect | apple-code: -1 | timeout';
      expect(gattStatusOf(error), -1);
    });

    test('parses a PlatformException-shaped string', () {
      const error = 'PlatformException(133, GATT_ERROR, null, null)';
      expect(gattStatusOf(error), 133);
    });

    test('returns null for a plain exception with no status', () {
      expect(gattStatusOf(Exception('connect failed')), isNull);
    });

    test(
      'returns null (not the unrelated number) for a message containing '
      'an unrelated digit sequence',
      () {
        expect(
          gattStatusOf(Exception('timeout after 10 seconds')),
          isNull,
        );
      },
    );
  });

  group('isRetryableGattError', () {
    test('true for a 133 android-code string', () {
      final error = Exception(
        'FlutterBluePlusException | connect | android-code: 133 | GATT_ERROR',
      );
      expect(isRetryableGattError(error), isTrue);
    });

    test('true for a 257 android-code string', () {
      final error = Exception(
        'FlutterBluePlusException | connect | android-code: 257 | FAILURE',
      );
      expect(isRetryableGattError(error), isTrue);
    });

    test('false for an 8 android-code string', () {
      final error = Exception(
        'FlutterBluePlusException | connect | android-code: 8 | TIMEOUT',
      );
      expect(isRetryableGattError(error), isFalse);
    });
  });

  group('retry budget', () {
    test('there is exactly one delay per retry', () {
      // `BleService._connectWithGattRetry` indexes `connectRetryDelays` with
      // `attempt - 1`, so bumping `maxConnectAttempts` without extending the
      // list would throw a RangeError on the last retry.
      expect(connectRetryDelays.length, maxConnectAttempts - 1);
    });
  });
}
