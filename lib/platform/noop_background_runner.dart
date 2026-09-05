/// A [BackgroundRunner] that does nothing.
library;

import 'background_runner.dart';

/// Used on every non-Android platform, where there is no foreground service
/// to run. Keeps call sites branch-free — per `AGENTS.md`, only files under
/// `lib/platform/` may branch on platform, and this class lets the rest of
/// the app call `BackgroundRunner` unconditionally instead of checking
/// `Platform.isAndroid` itself.
class NoopBackgroundRunner implements BackgroundRunner {
  @override
  Future<void> start({required Set<BackgroundReason> reasons}) async {}

  @override
  Future<void> update(String notificationText) async {}

  @override
  Future<void> stop() async {}
}
