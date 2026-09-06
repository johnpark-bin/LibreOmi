/// Pure-Dart classification of Android GATT connect failures.
///
/// This file intentionally has no dependency on `package:flutter_blue_plus`
/// (or any Flutter package) so it can be unit tested without a BLE stack or
/// a Flutter widget test harness. It is used by `BleService.connect()` to
/// decide whether a connect failure is transient and worth retrying.
library;

/// Android GATT_ERROR (0x85): the classic "connect failed, try again"
/// status. Seen constantly on real devices right after a disconnect or
/// when the peripheral is briefly out of range.
const int gattErrorStatus = 133;

/// 0x101: flutter_blue_plus/Android generic connection failure status.
/// In practice this is equally transient as [gattErrorStatus] and should
/// be retried the same way.
const int gattFailureStatus = 257;

/// Total connect attempts to make, including the first (non-retry) attempt.
const int maxConnectAttempts = 3;

/// Delay to wait *before* each retry attempt.
///
/// Index 0 is the delay before the 2nd attempt, index 1 is the delay
/// before the 3rd attempt, and so on. This list must always have exactly
/// `maxConnectAttempts - 1` entries, one per retry (the first attempt
/// never waits).
const List<Duration> connectRetryDelays = [
  Duration(seconds: 1),
  Duration(seconds: 2),
];

/// Whether [status] is a GATT status worth retrying a connect for.
bool isRetryableGattStatus(int status) {
  return status == gattErrorStatus || status == gattFailureStatus;
}

/// Matches a `code: <int>` style status, e.g. `android-code: 133` or
/// `apple-code: -1`, as produced by `FlutterBluePlusException.toString()`:
/// `'FlutterBluePlusException | $function | $sPlatform-code: $code | $description'`.
///
/// The optional leading word (`android`/`apple`/...) plus `-` before `code:`
/// is consumed so we don't accidentally match unrelated `code:` occurrences
/// elsewhere in a message, and the number may be negative (iOS statuses).
final RegExp _platformCodeStatus = RegExp(r'(?:[A-Za-z]+-)?code:\s*(-?\d+)');

/// Matches the numeric status out of Flutter's `PlatformException.toString()`
/// rendering: `PlatformException(133, GATT_ERROR, null, null)`.
final RegExp _platformExceptionStatus = RegExp(r'PlatformException\((-?\d+),');

/// Extracts the numeric GATT/platform status code out of [error], without
/// importing `package:flutter_blue_plus`, by parsing `error.toString()`.
///
/// Tries, in order:
/// 1. A `code: <int>` match (with an optional leading platform word), as
///    produced by `FlutterBluePlusException.toString()`.
/// 2. A `PlatformException(<int>,` match, as produced by a Flutter
///    `PlatformException.toString()`.
///
/// Returns `null` when neither shape is present. This deliberately does not
/// grab the first digit sequence anywhere in the string, so unrelated
/// numbers in a message (e.g. a timeout duration) are not mistaken for a
/// status code.
int? gattStatusOf(Object error) {
  final message = error.toString();

  final platformCodeMatch = _platformCodeStatus.firstMatch(message);
  if (platformCodeMatch != null) {
    return int.tryParse(platformCodeMatch.group(1)!);
  }

  final platformExceptionMatch = _platformExceptionStatus.firstMatch(message);
  if (platformExceptionMatch != null) {
    return int.tryParse(platformExceptionMatch.group(1)!);
  }

  return null;
}

/// Whether [error] represents a retryable GATT connect failure, i.e.
/// [gattStatusOf] returns a non-null status and [isRetryableGattStatus]
/// is true for it.
bool isRetryableGattError(Object error) {
  final status = gattStatusOf(error);
  return status != null && isRetryableGattStatus(status);
}
