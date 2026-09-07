/// A [BackgroundRunner] fake for tests.
library;

import 'background_runner.dart';

/// Records every call made to it instead of touching any plugin. Exists for
/// use in `test/` and for future session tests (`docs/03-architecture.md`
/// §7).
class FakeBackgroundRunner implements BackgroundRunner {
  FakeBackgroundRunner({this.throwOnStart = false});

  /// When true, [start] throws instead of recording, to exercise the
  /// caller's error-handling paths.
  final bool throwOnStart;

  final List<Set<BackgroundReason>> startCalls = <Set<BackgroundReason>>[];
  final List<String> updates = <String>[];
  int stopCount = 0;

  /// Whether [start] has been called without a matching [stop]. Not part of
  /// [BackgroundRunner]; it is here so tests can assert the service's state.
  bool running = false;

  @override
  Future<void> start({
    required Set<BackgroundReason> reasons,
    SessionNotificationLabels labels = const SessionNotificationLabels(),
  }) async {
    if (throwOnStart) {
      throw StateError('FakeBackgroundRunner.start failed');
    }
    startCalls.add(reasons);
    running = true;
  }

  @override
  Future<void> update(String notificationText) async {
    updates.add(notificationText);
  }

  @override
  Future<void> stop() async {
    stopCount++;
    running = false;
  }
}
