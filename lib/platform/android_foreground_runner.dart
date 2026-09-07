/// Android implementation of [BackgroundRunner], wrapping
/// `flutter_foreground_task`.
///
/// See `docs/03-architecture.md` §5 and `docs/04-android-platform-notes.md` §4.
/// The service exists to keep the Flutter engine's main isolate unfrozen while
/// the screen is off; it deliberately runs no logic of its own, because every
/// BLE callback, the transcriber and the finalizer already live in the main
/// isolate.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../services/notification_channels.dart';
import 'background_runner.dart';

/// The entry point the foreground service uses to spin up its task isolate.
///
/// `flutter_foreground_task` looks this function up by callback handle after a
/// process restart, so it has to be a top-level function marked
/// `vm:entry-point` or tree shaking removes it from a release build.
@pragma('vm:entry-point')
void sessionForegroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_SessionTaskHandler());
}

/// A deliberately empty task handler. Nothing is scheduled on it
/// ([ForegroundTaskEventAction.nothing]); the session keeps running in the main
/// isolate and only needs the service for process priority.
class _SessionTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Keeps the app alive while a session records, by running a foreground
/// service of the type(s) the session actually needs.
class AndroidForegroundRunner implements BackgroundRunner {
  /// Notification id of the persistent session notification.
  ///
  /// Chosen above the range `NotificationService` uses for instant
  /// notifications (`millisecondsSinceEpoch.remainder(100000)`, i.e. below
  /// 100 000), so those can never overwrite it. Task reminders
  /// (`notificationIdForTask`) span the whole 31-bit range and could in
  /// principle land on this value; one exact hit in 2^31 is not worth a
  /// reservation scheme, and LO-35 replaces that id derivation anyway.
  static const int serviceNotificationId = 1000000;

  /// Name of the `<meta-data>` entry in `AndroidManifest.xml` that points at
  /// the monochrome status-bar icon. The plugin resolves the drawable through
  /// the manifest rather than by resource name.
  static const String iconMetaDataName = 'org.libreomi.app.NOTIFICATION_ICON';

  /// Title of the persistent notification. `update()` only carries the text,
  /// so the title is fixed here and in [SessionNotificationText].
  static const String _notificationTitle = 'LibreOmi';

  bool _initialized = false;

  /// `FlutterForegroundTask.init` only stores options in the Dart side of the
  /// plugin, so it is cheap and can run lazily on the first `start()` instead
  /// of at app launch.
  void _ensureInitialized() {
    if (_initialized) {
      return;
    }
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        // Reuses the channel the app already registers (docs/04 §6). Android
        // keeps the first definition of a channel id, so these options only
        // apply if NotificationChannels has not created `session` yet; the
        // low-importance, sound-free definition there is the intended one.
        channelId: NotificationChannels.session,
        channelName: 'Session',
        channelDescription:
            'Ongoing notification while a session is recording',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // No repeating callback: the handler is empty on purpose.
        eventAction: ForegroundTaskEventAction.nothing(),
        // A partial wake lock keeps the CPU available for the BLE and
        // transcription callbacks with the screen off (docs/03 §5 item 4).
        allowWakeLock: true,
        // Wi-Fi stays under the system's control; Deepgram traffic tolerates
        // Doze deferrals and a Wi-Fi lock costs battery for hours at a time.
        allowWifiLock: false,
        // Boot start is explicitly out of scope for v1 (docs/03 §5).
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        // Left at its default, the service comes back on its own: `onDestroy`
        // sets a 5 s restart alarm, and the restarted service runs the empty
        // handler above in a fresh engine — no session, no BLE, no transcriber
        // behind it, i.e. a notification that claims to be recording and that
        // the app cannot take down. An auto-restart could not resume the
        // session anyway, since the session lives in the main isolate.
        allowAutoRestart: false,
        // `stopWithTask` is deliberately NOT set here even though the service
        // must die with the app task. Setting it from Dart makes
        // ForegroundService.onStartCommand install TrackVisibilityUtils, which
        // stops the service as soon as no activity is resumed — that is every
        // screen-off, exactly the case LO-20 exists to survive. The manifest's
        // android:stopWithTask on the <service> gives the task-removal
        // behaviour on its own: ForegroundServiceUtils.isSetStopWithTaskFlag
        // falls back to the ServiceInfo flag when this preference is absent.
      ),
    );
    _initialized = true;
  }

  /// Whether the plugin reports a running service. Treats an unavailable
  /// platform channel as "not running" so a failed query can never leave a
  /// session unable to start.
  Future<bool> get _isRunning async {
    try {
      return await FlutterForegroundTask.isRunningService;
    } catch (e) {
      debugPrint('Foreground service state unavailable: $e');
      return false;
    }
  }

  @override
  Future<void> start({required Set<BackgroundReason> reasons}) async {
    if (reasons.isEmpty) {
      return;
    }
    _ensureInitialized();
    if (await _isRunning) {
      // Already up (e.g. a phone-mic session started while the Omi session was
      // running). The service type of a running service cannot be widened, so
      // the caller has to stop first; log rather than fail the session.
      debugPrint('Foreground service already running; not restarting it');
      return;
    }

    // No `labels:` on purpose. This is the one line the service posts before
    // `SessionController` takes over the updates, and it runs on a path that
    // may precede the first frame, so the English default is the honest
    // answer here; the next `update()` carries the user's language.
    final initialText = SessionNotificationText.forSession(
      usingPhoneMic: reasons.contains(BackgroundReason.microphone),
      deviceConnected: reasons.contains(BackgroundReason.connectedDevice),
      conversationLength: Duration.zero,
    );

    final result = await FlutterForegroundTask.startService(
      serviceId: serviceNotificationId,
      serviceTypes: _serviceTypes(reasons),
      notificationTitle: initialText.title,
      notificationText: initialText.text,
      notificationIcon: const NotificationIcon(
        metaDataName: iconMetaDataName,
      ),
      callback: sessionForegroundTaskCallback,
    );
    if (result is ServiceRequestFailure) {
      // Report rather than abort: the session still works while the app is in
      // the foreground, it just will not survive the screen going off. Two
      // starts are refused by the system rather than by us — any foreground
      // service started from the background on API 31+ without a battery
      // optimisation exemption, and a microphone-type one on API 34+ (see
      // [requiresForegroundStart]).
      final hint = requiresForegroundStart(reasons)
          ? ' (a microphone-type service can only be started while the app is '
              'in the foreground on Android 14+)'
          : '';
      debugPrint('Foreground service failed to start$hint: ${result.error}');
    }
  }

  @override
  Future<void> update(String notificationText) async {
    if (!await _isRunning) {
      return;
    }
    // Called from the transcript hot path, so it swallows everything: a
    // notification that is a few seconds stale must never break a session.
    try {
      final result = await FlutterForegroundTask.updateService(
        notificationTitle: _notificationTitle,
        notificationText: notificationText,
      );
      if (result is ServiceRequestFailure) {
        debugPrint('Foreground notification update failed: ${result.error}');
      }
    } catch (e) {
      debugPrint('Foreground notification update failed: $e');
    }
  }

  @override
  Future<void> stop() async {
    if (!await _isRunning) {
      return;
    }
    final result = await FlutterForegroundTask.stopService();
    if (result is ServiceRequestFailure) {
      debugPrint('Foreground service failed to stop: ${result.error}');
    }
  }

  /// Translates the reason set into the plugin's service types, going through
  /// [orderedBackgroundReasons] so the order that is unit-tested is the order
  /// actually handed to the plugin. The switch is exhaustive, so a new
  /// [BackgroundReason] fails to compile here instead of at runtime.
  List<ForegroundServiceTypes> _serviceTypes(Set<BackgroundReason> reasons) {
    return orderedBackgroundReasons(reasons)
        .map((reason) => switch (reason) {
              BackgroundReason.connectedDevice =>
                ForegroundServiceTypes.connectedDevice,
              BackgroundReason.microphone => ForegroundServiceTypes.microphone,
            })
        .toList(growable: false);
  }
}
