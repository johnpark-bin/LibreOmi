/// Owns the Omi wearable connection: scanning, connect/disconnect, the
/// auto-reconnect ladder, battery notifications and SD-card storage
/// detection (LO-34, unit 3 of the pre-LO-34 monolith's split,
/// `docs/06-roadmap.md`).
///
/// Depends on `DeviceManager` and holds a `SessionController` reference it
/// orchestrates -- the agreed dependency direction for the whole refactor is
/// `DeviceController -> SessionController -> { DeviceManager,
/// LibraryController, ChatController }`. `SessionController` never
/// references this class.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../device/device_manager.dart';
import '../device/omi_ble_device.dart';
import '../device/omi_device.dart';
import '../l10n/l10n.dart';
import '../platform/ble_capture_file.dart';
import '../services/ble/reconnect_backoff.dart';
import '../services/notification_service.dart';
import '../services/saved_device_store.dart';
import '../services/sdcard_sync_service.dart';
import '../services/settings_service.dart';
import 'session_controller.dart';

/// Creates the timer behind [DeviceController]'s auto-reconnect ladder. A
/// test can inject a fake factory to drive the ladder deterministically
/// instead of waiting on real time (see `session/silence_detector.dart`'s
/// `SessionTimerFactory`, the same seam shape).
typedef ReconnectTimerFactory = Timer Function(
  Duration duration,
  void Function() callback,
);

Timer _defaultReconnectTimerFactory(Duration duration, void Function() callback) =>
    Timer(duration, callback);

/// Builds the production [DeviceManager]. `main.dart` calls this once and
/// hands the result to both [SessionController] and [DeviceController].
DeviceManager createDeviceManager() => DeviceManager(
      host: BleDeviceHost(),
      savedDevices: const SettingsSavedDeviceStore(),
      capture: appSupportBleSessionCapture(
        enabled: () => SettingsService.captureBleSession,
      ),
    );

class DeviceController with ChangeNotifier, WidgetsBindingObserver {
  DeviceController({
    required DeviceManager deviceManager,
    required SessionController session,
    Future<void> Function(String title, String body)? notify,
    Future<void> Function()? resetBadge,
    ReconnectTimerFactory createTimer = _defaultReconnectTimerFactory,
  })  : _deviceManager = deviceManager,
        _session = session,
        _notify = notify ?? NotificationService().showNotification,
        _resetBadge = resetBadge ?? NotificationService().resetGlobalBadge,
        _createTimer = createTimer;

  final DeviceManager _deviceManager;
  final SessionController _session;

  /// Creates the timer behind the auto-reconnect ladder. Real `Timer` in
  /// production; a test injects a fake factory (matching
  /// `session/silence_detector.dart`'s `SessionTimerFactory` seam) so the
  /// ladder can be driven deterministically instead of waiting on real time.
  final ReconnectTimerFactory _createTimer;

  /// Shows a platform notification. In production
  /// `NotificationService().showNotification`; injected so a test needs no
  /// plugin channel.
  final Future<void> Function(String title, String body) _notify;

  /// Clears the app icon badge. In production
  /// `NotificationService().resetGlobalBadge`; injected for the same reason.
  final Future<void> Function() _resetBadge;

  /// The device manager backing this controller, for callers (pages) that
  /// need scanning/connect APIs beyond the ones re-exposed here.
  DeviceManager get deviceManager => _deviceManager;

  /// The currently connected device, or `null`.
  OmiDevice? get device => _deviceManager.current;

  // App lifecycle state
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;

  // Device state
  DeviceConnectionState _deviceState = DeviceConnectionState.disconnected;
  DeviceConnectionState get deviceState => _deviceState;
  int? _batteryLevel;
  int? get batteryLevel => _batteryLevel;

  // Battery notification tracking (to avoid duplicate alerts)
  bool _notified50 = false;
  bool _notified20 = false;

  // Auto-reconnect scheduling (LO-22). Upstream polled every 5 s forever;
  // the saved device is now armed with `autoConnect`, so this timer only
  // re-arms a request that could not be placed and backs off 5 s -> 60 s.
  Timer? _reconnectTimer;
  final ReconnectBackoff _reconnectBackoff = ReconnectBackoff();
  bool _isAutoReconnectEnabled = true;
  bool _isReconnecting = false;

  /// Whether auto-reconnect is currently armed. Pages do not need this
  /// (`scanAndConnectToSavedDevice()`/`disconnectDevice()` flip it), but the
  /// guards this class applies before `session.beginAwaitingReconnect()` and
  /// the unit tests both read it.
  @visibleForTesting
  bool get isAutoReconnectEnabled => _isAutoReconnectEnabled;

  // SD Card Sync
  bool _hasStorageSupport = false;
  bool get hasStorageSupport => _hasStorageSupport;
  SdCardSyncService? _sdCardSyncService;
  SdCardSyncService? get sdCardSyncService => _sdCardSyncService;

  // Subscriptions
  StreamSubscription? _stateSubscription;
  StreamSubscription? _buttonSubscription;

  /// Wires the device-state and button-event subscriptions and arms the first
  /// auto-reconnect attempt. Split out of the constructor so `main.dart`'s
  /// bootstrap can order it precisely: it must run *after*
  /// `SessionController.reapStaleBackgroundService()`, because the
  /// device-state listener wired up here can auto-start a session, and the
  /// reap must not run after that and take the new session's foreground
  /// service down.
  Future<void> init() async {
    // Register app lifecycle observer
    WidgetsBinding.instance.addObserver(this);

    // Listen to device state changes
    _stateSubscription = _deviceManager.connectionState.listen((state) async {
      final previousState = _deviceState;
      _deviceState = state;

      if (state == DeviceConnectionState.connected) {
        // The link may have come up on its own (autoConnect), so the
        // post-connect work belongs here rather than at the call site that
        // only *armed* the request.
        _session.endAwaitingReconnect();
        _reconnectBackoff.reset();
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
        _batteryLevel = await _deviceManager.current?.readBatteryLevel();
        _checkBatteryNotification();
      }

      // Auto-start listening when device connects (only if not using phone mic)
      if (state == DeviceConnectionState.connected &&
          !_session.isListening &&
          !_session.isUsingPhoneMic) {
        // Check for SD card storage support on any connection
        await _checkStorageSupport();
        _session.startListeningIfReady();
      }

      if (state == DeviceConnectionState.disconnected) {
        // A session that was interrupted by the wearable going out of range
        // keeps the foreground service (and the process) alive while the
        // reconnect is pending. Must run before `stopListeningForDeviceLoss()`,
        // which would otherwise take the service straight down.
        //
        // `SessionController.beginAwaitingReconnect()` is guard-free; the two
        // guards the old monolith's `_beginAwaitingReconnect` used to apply
        // (`_isAutoReconnectEnabled` and a non-empty saved device id) move
        // here because the flag and the saved device belong to this class.
        if (previousState == DeviceConnectionState.connected &&
            _session.isListening &&
            !_session.isUsingPhoneMic) {
          if (_isAutoReconnectEnabled && SettingsService.savedDeviceId.isNotEmpty) {
            _session.beginAwaitingReconnect();
          }
        }

        // Only stop listening if we were using Omi, not phone mic
        if (_session.isListening && !_session.isUsingPhoneMic) {
          _session.stopListeningForDeviceLoss();
        }

        // (Re)start the ladder without advancing it: the previous
        // `connected` reset it, so this schedules the first 5 s attempt, and
        // a duplicate disconnect event cannot push that attempt further out.
        _scheduleReconnect(advanceBackoff: false);

        // Notify user of disconnection if it was previously connected
        // Only show notification if app is in background
        if (previousState == DeviceConnectionState.connected &&
            _appLifecycleState != AppLifecycleState.resumed) {
          unawaited(
            _notify(
              L10n.current.deviceController_disconnectedNotificationTitle,
              L10n.current.deviceController_disconnectedNotificationBody,
            ),
          );
        }
      }

      // A connection change alters the notification's first half, which the
      // throttle pushes immediately rather than at the next interval.
      _session.onDeviceStateChanged();

      notifyListeners();
    });

    // Listen to button events. `SessionController.handleButtonEvent` already
    // logs a command failure instead of letting it escape into the app zone.
    _buttonSubscription = _deviceManager.buttonEvents.listen(_session.handleButtonEvent);

    // Start auto-reconnect scheduling. No attempt has been made yet, so this
    // must not consume a rung of the ladder.
    _scheduleReconnect(advanceBackoff: false);
  }

  /// Schedules the next auto-reconnect attempt with an exponential backoff
  /// (LO-22, `docs/03-architecture.md` section 5). No BLE scan is involved:
  /// the saved device is armed with `autoConnect`, which the OS retries on its
  /// own, so an attempt here is only a cheap re-arm of that request.
  ///
  /// [advanceBackoff] is false when no attempt was actually made (a duplicate
  /// disconnect event, a tick the guards skipped): the ladder must only grow
  /// for attempts that happened, or a phone-mic session or a slow
  /// `stopListening()` would silently push the first real attempt out to the
  /// 60 s ceiling.
  void _scheduleReconnect({bool advanceBackoff = true}) {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (!_isAutoReconnectEnabled) return;
    if (_deviceState == DeviceConnectionState.connected) return;

    final delay = advanceBackoff
        ? _reconnectBackoff.nextDelay()
        : _reconnectBackoff.currentBaseDelay;
    debugPrint(
      '[LibreOmi/BLE] auto-reconnect: next attempt in ${delay.inMilliseconds} ms '
      '(attempt ${_reconnectBackoff.attempt})',
    );
    _reconnectTimer = _createTimer(delay, () {
      unawaited(_attemptReconnect());
    });
  }

  Future<void> _attemptReconnect() async {
    _reconnectTimer = null;
    if (!_isAutoReconnectEnabled) return;

    final savedId = SettingsService.savedDeviceId;
    // Don't auto-reconnect when using the phone mic, while a session is
    // running, while an attempt is already in flight, or while a connection
    // (including a manual one) is being set up — `connecting` is not
    // `disconnected`, and arming on top of a manual connect would race it.
    final canAttempt = savedId.isNotEmpty &&
        !_isReconnecting &&
        !_session.isUsingPhoneMic &&
        !_session.isListening &&
        _deviceState == DeviceConnectionState.disconnected;
    if (canAttempt) {
      await _armSavedDeviceConnection();
    }

    // Arming is not connecting: keep the ladder running until the device
    // actually comes back, at which point the state listener resets it.
    _scheduleReconnect(advanceBackoff: canAttempt);
  }

  /// Asks the device manager to keep waiting for the saved device.
  ///
  /// `DeviceManager.connectToSavedDevice()` returns as soon as the request is
  /// armed, so there is no connection to post-process here — the device-state
  /// listener does that whenever the link actually comes up.
  Future<void> _armSavedDeviceConnection() async {
    final savedId = _deviceManager.savedDeviceId;
    if (savedId.isEmpty) return;
    // Arming while a link is up or coming up is refused by the platform
    // without telling us, which would leave the service believing in a
    // request that does not exist.
    if (_deviceState != DeviceConnectionState.disconnected) {
      debugPrint('[LibreOmi/BLE] not arming autoConnect while $_deviceState');
      return;
    }
    _isReconnecting = true;
    try {
      final armed = await _deviceManager.connectToSavedDevice();
      debugPrint(
        armed
            ? '[LibreOmi/BLE] auto-reconnect: autoConnect armed for $savedId'
            : '[LibreOmi/BLE] auto-reconnect: could not arm autoConnect, retrying with backoff',
      );
    } catch (e) {
      debugPrint('Auto-connect error: $e');
    } finally {
      _isReconnecting = false;
    }
  }

  /// User-initiated "connect to my saved device" (settings screen, audio
  /// test). Re-enables auto-reconnect, because an explicit disconnect turns
  /// it off, and restarts the backoff from its shortest delay.
  Future<void> scanAndConnectToSavedDevice() async {
    _isAutoReconnectEnabled = true;
    _reconnectBackoff.reset();
    if (!_isReconnecting) {
      await _armSavedDeviceConnection();
    }
    _scheduleReconnect(advanceBackoff: false);
  }

  // === Device Methods ===

  Stream<List<DiscoveredDevice>> scanForDevices() {
    return _deviceManager.scanForDevices();
  }

  Future<void> stopScan() async {
    await _deviceManager.stopScan();
  }

  Future<bool> connectToDevice(DiscoveredDevice device) async {
    _isAutoReconnectEnabled = true;
    final success = await _deviceManager.connect(device);
    if (success) {
      _batteryLevel = await _deviceManager.current?.readBatteryLevel();
      _checkBatteryNotification();

      // Check for SD card storage support
      await _checkStorageSupport();

      notifyListeners();
    }
    return success;
  }

  /// Check if the device supports SD card storage
  Future<void> _checkStorageSupport() async {
    final device = _deviceManager.current;
    final storage = device?.storage;
    _hasStorageSupport = storage != null && (await storage.list()).isNotEmpty;
    if (_hasStorageSupport) {
      _sdCardSyncService = SdCardSyncService(
        storage: storage!,
        readCodec: () => device!.readCodec(),
      );
      debugPrint('SD card storage support detected');
    } else {
      _sdCardSyncService = null;
      debugPrint('No SD card storage support');
    }
    notifyListeners();
  }

  /// Explicit, user-initiated disconnect.
  ///
  /// Auto-reconnect is switched off here: `autoConnect` would otherwise bring
  /// the link straight back up and the button would do nothing. A later
  /// `connectToDevice()` or `scanAndConnectToSavedDevice()` turns it back on.
  Future<void> disconnectDevice() async {
    _isAutoReconnectEnabled = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectBackoff.reset();
    _session.endAwaitingReconnect();
    await _session.stopListening();
    await _deviceManager.disconnect();
    await _session.releaseBackgroundServiceIfIdle();
    _batteryLevel = null;
    _notified50 = false;
    _notified20 = false;
    notifyListeners();
  }

  /// Check battery level and show notification at 50% and 20%
  void _checkBatteryNotification() {
    if (_batteryLevel == null) return;

    if (_batteryLevel! <= 20 && !_notified20) {
      _notified20 = true;
      if (SettingsService.notifyBatteryCritical) {
        unawaited(
          _notify(
            L10n.current.deviceController_lowBatteryTitle,
            L10n.current.deviceController_lowBatteryCriticalBody(_batteryLevel!),
          ),
        );
      }
    } else if (_batteryLevel! <= 50 && !_notified50) {
      _notified50 = true;
      if (SettingsService.notifyBatteryLow) {
        unawaited(
          _notify(
            L10n.current.deviceController_batteryGettingLowTitle,
            L10n.current.deviceController_batteryGettingLowBody(_batteryLevel!),
          ),
        );
      }
    }

    // Reset flags when charged above thresholds
    if (_batteryLevel! > 50) {
      _notified50 = false;
      _notified20 = false;
    } else if (_batteryLevel! > 20) {
      _notified20 = false;
    }
  }

  Future<void> forgetDevice() async {
    await disconnectDevice();
    SettingsService.clearSavedDevice();
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleState = state;
    debugPrint('App lifecycle state: $state');

    if (state == AppLifecycleState.resumed) {
      unawaited(_resetBadge());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reconnectTimer?.cancel();
    _stateSubscription?.cancel();
    _buttonSubscription?.cancel();
    // The session's teardown closes the audio transport, which reaches back
    // into the device manager, so the manager may only go down once that
    // teardown has actually finished.
    unawaited(
      _session.teardown.whenComplete(_deviceManager.dispose).catchError(
        (Object error) {
          debugPrint('Device controller teardown failed: $error');
        },
      ),
    );
    super.dispose();
  }
}
