/// The abstraction the session layer uses to keep the app alive in the
/// background, as specified in `docs/03-architecture.md` §2 and §5. The real
/// implementation wraps `flutter_foreground_task` on Android; every other
/// platform uses [NoopBackgroundRunner] (see `noop_background_runner.dart`).
library;

import 'background_reasons.dart';

export 'background_reasons.dart';

/// Keeps the Flutter engine alive while a session is listening, by starting
/// (and stopping) an Android foreground service.
///
/// Contract:
/// - [start] must be called BEFORE the audio stream begins, so the process
///   is not killed mid-setup.
/// - [stop] must be called as soon as the session goes idle, whether or not a
///   device is still connected: an idle app must show no persistent
///   notification (LO-24), and one it cannot dismiss annoys users and Play
///   reviewers alike.
/// - [update] is best-effort: it must never throw into the caller, since it
///   is typically called from a hot path (segment/transcript updates) that
///   should not fail a session over a notification-text refresh.
abstract class BackgroundRunner {
  /// Starts the foreground service for the given [reasons]. See
  /// [requiresForegroundStart] for when this must be triggered by a
  /// foreground UI action rather than a background callback.
  ///
  /// [labels] translates the first notification text this posts. It defaults
  /// to English so a caller with no locale to hand still gets readable text;
  /// `SessionController` passes the user's language.
  Future<void> start({
    required Set<BackgroundReason> reasons,
    SessionNotificationLabels labels = const SessionNotificationLabels(),
  });

  /// Best-effort update of the persistent notification text. Must never
  /// throw into the caller.
  Future<void> update(String notificationText);

  /// Stops the foreground service. Safe to call when nothing is running.
  Future<void> stop();
}
