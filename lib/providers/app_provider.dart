/// App state provider for device, conversations, and recording
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../audio/audio_source.dart';
import '../audio/omi_audio_source.dart';
import '../audio/opus_decoder.dart';
import '../audio/phone_mic_source.dart';
import '../device/device_manager.dart';
import '../device/omi_ble_device.dart';
import '../device/omi_device.dart';
import '../intelligence/llm_client.dart';
import '../intelligence/openai_client.dart';
import '../models/conversation.dart';
import '../platform/background_runner.dart';
import '../platform/ble_capture_file.dart';
import '../platform/background_runner_factory.dart';
import '../services/ble/reconnect_backoff.dart';
import '../services/database_service.dart';
import '../services/finalization_queue.dart';
import '../services/saved_device_store.dart';
import '../services/settings_service.dart';
import '../services/sherpa_service.dart';
import '../services/whisper_service.dart';
import '../services/notification_ids.dart';
import '../services/notification_service.dart';
import '../services/mic_service.dart';
import '../services/sdcard_sync_service.dart';
import '../session/conversation_finalizer.dart';
import '../session/recording_session.dart';
import '../session/session_state.dart';
import '../transcription/deepgram_streaming.dart';
import '../transcription/sherpa_streaming.dart';
import '../transcription/transcriber.dart';
import '../transcription/whisper_batch.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class AppProvider with ChangeNotifier, WidgetsBindingObserver {
  final DeviceManager _deviceManager;

  /// The device manager backing this provider, for callers (pages) that need
  /// scanning/connect APIs beyond the ones re-exposed here.
  DeviceManager get deviceManager => _deviceManager;

  /// The currently connected device, or `null`.
  OmiDevice? get device => _deviceManager.current;

  final MicService _micService = MicService();
  SdCardSyncService? _sdCardSyncService;

  /// Keeps the process alive while a session records (docs/03 §5). A
  /// foreground service on Android, inert everywhere else. Injectable so a
  /// test can pass a `FakeBackgroundRunner`.
  final BackgroundRunner _backgroundRunner;

  /// Holds summarisation requests that could not run yet and retries them when
  /// the network comes back (LO-23, `docs/06-roadmap.md`). A conversation is
  /// always persisted before its request is queued, so nothing is lost when the
  /// phone is offline or dozing.
  late final FinalizationQueue _finalizationQueue;

  /// The one place a conversation is persisted and its insights applied, for
  /// both the live path and the SD-card import path (LO-33).
  late final ConversationFinalizer _finalizer;

  /// The session state machine (`docs/03-architecture.md` §4). Everything
  /// this provider used to do between "audio is flowing" and "the
  /// conversation has been handed off" now lives there; what stays here is
  /// what needs settings, permissions or the foreground service.
  late final RecordingSession _session;

  StreamSubscription<SessionState>? _sessionStateSubscription;
  StreamSubscription<List<TranscriptSegment>>? _sessionSegmentsSubscription;
  StreamSubscription<AiAnswer>? _sessionAnswerSubscription;

  /// Rate-limits rewrites of the persistent notification so a burst of
  /// transcript segments does not produce a burst of platform calls.
  final SessionNotificationThrottle _sessionNotificationThrottle =
      SessionNotificationThrottle();

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

  bool _isListening = false;
  bool get isListening => _isListening;

  /// True from the first line of a `startListening*` until it finishes.
  ///
  /// [_isListening] is only set once the session is actually up, so without
  /// this a second start arriving in between would sail past the guard below:
  /// it would overwrite the first session's transcriber and subscriptions,
  /// and its own rollback would take the foreground service down under a
  /// session that is about to declare itself live.
  bool _isStarting = false;

  // Phone mic state
  bool _isUsingPhoneMic = false;
  bool get isUsingPhoneMic => _isUsingPhoneMic;

  /// The conversation being recorded, owned by [_session].
  Conversation? get currentConversation => _session.currentConversation;

  /// Mirror of the session's live segments, kept so the pages can read them
  /// synchronously off a `Consumer` rebuild.
  List<TranscriptSegment> _liveSegments = [];
  List<TranscriptSegment> get liveSegments => _liveSegments;

  // Auto-reconnect scheduling (LO-22). Upstream polled every 5 s forever;
  // the saved device is now armed with `autoConnect`, so this timer only
  // re-arms a request that could not be placed and backs off 5 s -> 60 s.
  Timer? _reconnectTimer;
  final ReconnectBackoff _reconnectBackoff = ReconnectBackoff();
  bool _isAutoReconnectEnabled = true;
  bool _isReconnecting = false;

  /// While the wearable is out of range the process has to stay alive or
  /// Android may kill it and no reconnect happens at all, so the foreground
  /// service outlives an involuntary disconnect for [reconnectGraceWindow].
  /// Without a bound an app left out of range would show a persistent
  /// notification forever, which is exactly what LO-24 (docs/04 section 4)
  /// forbids.
  static const Duration reconnectGraceWindow = Duration(minutes: 5);
  bool _isAwaitingReconnect = false;
  Timer? _reconnectGraceTimer;

  // Hold-to-Ask AI, owned by [_session].
  bool get isHoldToAskActive => _session.isHoldToAskActive;
  bool get isAiQueryProcessing => _session.isAnswering;

  // Conversations list
  List<Conversation> _conversations = [];
  List<Conversation> get conversations => _conversations;

  // Memories list
  List<Memory> _memories = [];
  List<Memory> get memories => _memories;

  // Tasks list
  List<Task> _tasks = [];
  List<Task> get tasks => _tasks;

  // Chat
  List<ChatMessage> _chatMessages = [];
  List<ChatMessage> get chatMessages => _chatMessages;
  bool _isChatLoading = false;
  bool get isChatLoading => _isChatLoading;

  // Audio Test
  bool _isTestingAudio = false;
  bool get isTestingAudio => _isTestingAudio;

  // Model loading state
  bool _isLoadingModel = false;
  bool get isLoadingModel => _isLoadingModel;
  List<int> _testAudioBuffer = [];
  final AudioPlayer _audioPlayer = AudioPlayer(); // Added

  // SD Card Sync
  bool _hasStorageSupport = false;
  bool get hasStorageSupport => _hasStorageSupport;
  SdCardSyncService? get sdCardSyncService => _sdCardSyncService;

  // Subscriptions
  StreamSubscription? _stateSubscription;
  StreamSubscription? _buttonSubscription;

  AppProvider({
    BackgroundRunner? backgroundRunner,
    FinalizationQueue? finalizationQueue,
    DeviceManager? deviceManager,
  })  : _backgroundRunner = backgroundRunner ?? createBackgroundRunner(),
        _deviceManager = deviceManager ??
            DeviceManager(
              host: BleDeviceHost(),
              savedDevices: const SettingsSavedDeviceStore(),
              capture: appSupportBleSessionCapture(
                enabled: () => SettingsService.captureBleSession,
              ),
            ) {
    _finalizer = ConversationFinalizer(
      database: () => DatabaseService.database,
      enqueue: _enqueueFinalization,
      scheduleReminder: NotificationService().scheduleTaskNotification,
      onConversationSaved: loadConversations,
      onInsightsApplied: _reloadFinalizedData,
    );
    _finalizationQueue = finalizationQueue ??
        FinalizationQueue(
          llmClient: _newLlmClient,
          applier: _finalizer.applyInsights,
        );
    _session = RecordingSession(
      transcriberFactory: _buildTranscriber,
      finalizer: _finalizer,
      llmClientFactory: _newLlmClient,
      device: () => _deviceManager.current,
      feedback: const _PlatformSessionFeedback(),
      // A single tap on an idle session means "record and ask"; only this
      // class knows how to bring the foreground service up first.
      onStartRequested: startListening,
    );
    _watchSession();
    _init();
  }

  /// Builds the LLM client for one call.
  ///
  /// Deliberately not a shared field: a background drain would otherwise be
  /// able to swap the client out from under a chat request that is between
  /// its own assignment and its use, and the key and model can change in
  /// settings between a conversation being queued and being retried.
  LlmClient _newLlmClient() => OpenAiClient.fromApiKey(
        apiKey: SettingsService.openaiApiKey,
        model: SettingsService.openaiModel,
      );

  /// Mirrors the session's outputs into the provider state the pages read.
  void _watchSession() {
    _sessionStateSubscription = _session.states.listen((_) {
      _updateSessionNotification();
      notifyListeners();
    });
    _sessionSegmentsSubscription = _session.liveSegments.listen((segments) {
      _liveSegments = segments;
      // Keeps the persistent notification's conversation length roughly
      // current; the throttle drops updates that only move the clock.
      _updateSessionNotification();
      notifyListeners();
    });
    // The hold-to-ask answer is delivered as a notification by the session
    // and, since #33, also recorded on the chat page.
    _sessionAnswerSubscription = _session.aiAnswers.listen(_recordAiAnswer);
  }

  void _recordAiAnswer(AiAnswer answer) {
    _chatMessages.add(
      ChatMessage(
        id: const Uuid().v4(),
        text: answer.question,
        isUser: true,
        createdAt: DateTime.now(),
      ),
    );
    _chatMessages.add(
      ChatMessage(
        id: const Uuid().v4(),
        text: answer.answer,
        isUser: false,
        createdAt: DateTime.now(),
      ),
    );
    notifyListeners();
  }

  /// Reloads everything a finished summarisation can have touched.
  Future<void> _reloadFinalizedData() async {
    await loadConversations();
    await loadMemories();
    await loadTasks();
  }

  /// Kicks the queue without letting its failure escape into the app zone.
  /// `drainOnce` can throw before its first await (opening the database), so a
  /// bare `unawaited` here would become an unhandled async error.
  void _drainFinalizationQueue() {
    unawaited(
      _finalizationQueue.drainOnce().catchError((Object error) {
        debugPrint('Finalization drain failed: $error');
        return 0;
      }),
    );
  }

  Future<void> _init() async {
    // Register app lifecycle observer
    WidgetsBinding.instance.addObserver(this);

    // Nothing is recording yet, so any foreground service still up belongs to
    // a previous process that did not shut down cleanly. Reap it, otherwise a
    // notification claiming to record would survive with no session behind it.
    // Awaited on purpose: it has to finish before the device-state listener
    // below can start a session, or the reap could take that session's service
    // down instead.
    await _stopBackgroundRunnerWhenIdle();

    try {
      // Listen to device state changes
      _stateSubscription = _deviceManager.connectionState.listen((state) async {
        final previousState = _deviceState;
        _deviceState = state;

        if (state == DeviceConnectionState.connected) {
          // The link may have come up on its own (autoConnect), so the
          // post-connect work belongs here rather than at the call site that
          // only *armed* the request.
          _endAwaitingReconnect();
          _reconnectBackoff.reset();
          _reconnectTimer?.cancel();
          _reconnectTimer = null;
          _batteryLevel = await _deviceManager.current?.readBatteryLevel();
          _checkBatteryNotification();
        }

        // Auto-start listening when device connects (only if not using phone mic)
        if (state == DeviceConnectionState.connected &&
            !_isListening &&
            !_isUsingPhoneMic) {
          // Check for SD card storage support on any connection
          await _checkStorageSupport();
          _startListeningIfReady();
        }

        if (state == DeviceConnectionState.disconnected) {
          // A session that was interrupted by the wearable going out of range
          // keeps the foreground service (and the process) alive while the
          // reconnect is pending. Must run before `stopListening()`, which
          // would otherwise take the service straight down.
          if (previousState == DeviceConnectionState.connected &&
              _isListening &&
              !_isUsingPhoneMic) {
            _beginAwaitingReconnect();
          }

          // Only stop listening if we were using Omi, not phone mic
          if (_isListening && !_isUsingPhoneMic) {
            stopListening();
          }

          // (Re)start the ladder without advancing it: the previous
          // `connected` reset it, so this schedules the first 5 s attempt, and
          // a duplicate disconnect event cannot push that attempt further out.
          _scheduleReconnect(advanceBackoff: false);

          // Notify user of disconnection if it was previously connected
          // Only show notification if app is in background
          if (previousState == DeviceConnectionState.connected &&
              _appLifecycleState != AppLifecycleState.resumed) {
            NotificationService().showNotification(
              "Omi Disconnected",
              "Your device connection was lost.",
            );
          }
        }

        // A connection change alters the notification's first half, which the
        // throttle pushes immediately rather than at the next interval.
        _updateSessionNotification();

        notifyListeners();
      });

      // Listen to button events. A command that fails (a database write, a
      // platform channel) must not escape into the app zone as an unhandled
      // async error, so it is logged here instead.
      _buttonSubscription = _deviceManager.buttonEvents.listen((event) {
        unawaited(
          _session.handleButton(event).catchError((Object error) {
            debugPrint('Button command failed: $error');
          }),
        );
      });

      // Load saved conversations, memories, and tasks
      await loadConversations();
      await loadMemories();
      await loadTasks();

      // Deliberately after the loads: the queue lives entirely in the
      // database, so starting it before storage has proven usable would only
      // arm a timer with nothing to drain. Anything left over from a previous
      // process (killed mid-retry, or queued while offline) is picked up by
      // this first drain.
      _finalizationQueue.start();
      _drainFinalizationQueue();
    } catch (e) {
      debugPrint('AppProvider init error: $e');
    }

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
    _reconnectTimer = Timer(delay, () {
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
        !_isUsingPhoneMic &&
        !_isListening &&
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

  /// Keeps the foreground service up while an interrupted session waits for
  /// the wearable to come back, for at most [reconnectGraceWindow].
  void _beginAwaitingReconnect() {
    if (!_isAutoReconnectEnabled) return;
    if (SettingsService.savedDeviceId.isEmpty) return;
    _isAwaitingReconnect = true;
    _reconnectGraceTimer?.cancel();
    _reconnectGraceTimer = Timer(reconnectGraceWindow, () {
      _reconnectGraceTimer = null;
      _isAwaitingReconnect = false;
      debugPrint('[LibreOmi/BLE] reconnect grace window expired, stopping background runner');
      // Stopping the runner takes the notification with it, so there is
      // nothing left to refresh here.
      unawaited(_stopBackgroundRunnerWhenIdle());
    });
    _updateSessionNotification();
  }

  void _endAwaitingReconnect() {
    _reconnectGraceTimer?.cancel();
    _reconnectGraceTimer = null;
    _isAwaitingReconnect = false;
  }

  /// Resolves true once the device is connected, false on timeout.
  ///
  /// Uses an explicit subscription rather than `firstWhere().timeout()`:
  /// a timeout on the future would leave the underlying listener on the
  /// broadcast stream until the next connection.
  Future<bool> _waitForConnection(Duration timeout) async {
    if (_deviceState == DeviceConnectionState.connected) return true;
    final completer = Completer<bool>();
    final subscription = _deviceManager.connectionState.listen((state) {
      if (state == DeviceConnectionState.connected && !completer.isCompleted) {
        completer.complete(true);
      }
    });
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(false);
    });
    try {
      return await completer.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
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
    _endAwaitingReconnect();
    await stopListening();
    await _deviceManager.disconnect();
    await _stopBackgroundRunnerWhenIdle();
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
        NotificationService().showNotification(
          'Low Battery Warning',
          'Omi battery is at $_batteryLevel%. Please charge soon.',
        );
      }
    } else if (_batteryLevel! <= 50 && !_notified50) {
      _notified50 = true;
      if (SettingsService.notifyBatteryLow) {
        NotificationService().showNotification(
          'Battery Getting Low',
          'Omi battery is at $_batteryLevel%.',
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

  // === Continuous Listening Methods ===

  Future<void> _startListeningIfReady() async {
    if (SettingsService.hasApiKeys) {
      await startListening();
    }
  }

  /// Start continuous listening using Omi device
  Future<void> startListening() async {
    if (_deviceState != DeviceConnectionState.connected) {
      throw Exception('No Omi device connected');
    }
    if (_isListening || _isStarting) return;

    _isStarting = true;
    try {
      _isUsingPhoneMic = false;

      // The foreground service goes up before any audio flows, so the process
      // is never killed mid-setup (docs/04 §4). An Omi session only needs the
      // connectedDevice type; the microphone type is reserved for the
      // phone-mic path, which Android 14+ allows to start from the foreground
      // only.
      await _startBackgroundRunner(<BackgroundReason>{
        BackgroundReason.connectedDevice,
      });

      try {
        // The source only transforms the BLE notification stream (header
        // strip, encoding tag); starting and stopping the stream itself stays
        // with the device, which is why the session gets it as a separate
        // transport pair.
        await _session.start(
          source: OmiAudioSource(_deviceManager.audioPackets),
          useOpusEncoding: true,
          openTransport: () async {
            await _deviceManager.current?.startAudioStream();
          },
          closeTransport: () async {
            await _deviceManager.current?.stopAudioStream();
          },
        );
      } catch (_) {
        // Setup failed, so the session never reaches listening: take the
        // service back down instead of leaving a notification for a session
        // that is not running. The session has already released whatever it
        // brought up.
        await _stopBackgroundRunnerWhenIdle();
        rethrow;
      } finally {
        // In a `finally` so a model that fails to load does not leave the
        // spinner up for the rest of the process.
        _isLoadingModel = false;
      }

      _isListening = true;
      notifyListeners();

      debugPrint(
        'Started continuous listening with Omi device (${SettingsService.transcriptionMode})',
      );
    } finally {
      _isStarting = false;
    }
  }

  /// Start continuous listening using iPhone microphone
  Future<void> startListeningWithPhoneMic() async {
    if (_isListening || _isStarting) return;

    // Check mic permission
    final hasPermission = await _micService.hasPermission();
    if (!hasPermission) {
      throw Exception(
        'Microphone permission denied. Please enable in Settings.',
      );
    }

    _isStarting = true;
    try {
      await _startPhoneMicSession();
    } finally {
      _isStarting = false;
    }
  }

  /// The body of [startListeningWithPhoneMic], split out only so the
  /// re-entrancy flag can be released in one `finally` around all of it.
  Future<void> _startPhoneMicSession() async {
    _isUsingPhoneMic = true;
    // The session continues on the phone mic, so there is no interrupted Omi
    // session left to hold the service open for.
    _endAwaitingReconnect();

    // Microphone-type foreground services may only be started while the app is
    // in the foreground on Android 14+ (docs/04 §3/§4), and this method is only
    // ever reached from a button tap, so the type is safe to request here.
    await _startBackgroundRunner(<BackgroundReason>{
      BackgroundReason.connectedDevice,
      BackgroundReason.microphone,
    });

    try {
      // `prepare()` rather than relying on `start()` to kick the recorder off,
      // because only an awaited call can surface a recorder failure as an
      // exception here, which is what rolls the half-open session back below.
      // Handed to the session as the transport so it runs after the
      // transcriber is up, exactly as it did before LO-33.
      final source = PhoneMicSource();
      await _session.start(
        source: source,
        useOpusEncoding: false,
        openTransport: source.prepare,
      );
    } catch (_) {
      // Leaving the flag set would keep auto-reconnect switched off for the
      // rest of the process.
      _isUsingPhoneMic = false;
      await _stopBackgroundRunnerWhenIdle();
      rethrow;
    } finally {
      _isLoadingModel = false;
    }

    _isListening = true;
    notifyListeners();

    debugPrint(
      'Started continuous listening with iPhone microphone (${SettingsService.transcriptionMode})',
    );
  }

  /// Builds the one transcription backend the selected mode calls for, for
  /// [RecordingSession] to subscribe to and start. [useOpusEncoding] is true
  /// for the Omi path, which streams Opus, and false for the phone mic, which
  /// streams raw PCM16.
  ///
  /// Stays here rather than in `lib/session`: which backend to build is a
  /// settings question, and `SettingsService` is a process-wide static the
  /// session layer must not depend on (`docs/03-architecture.md` §1).
  Future<StreamingTranscriber> _buildTranscriber({
    required bool useOpusEncoding,
  }) async {
    final transcriptionMode = SettingsService.transcriptionMode;

    // Validate API keys for cloud mode
    if (transcriptionMode == 'cloud' && !SettingsService.hasDeepgramKey) {
      throw Exception(
        'Please configure Deepgram API key in settings or switch to local transcription',
      );
    }

    switch (transcriptionMode) {
      case 'sherpa':
        debugPrint(
          'Starting with LOCAL Sherpa-ONNX transcription (with diarization)',
        );
        _isLoadingModel = true;
        notifyListeners();
        return SherpaStreamingTranscriber();

      case 'whisper':
        debugPrint(
          'Starting with LOCAL Whisper transcription (${SettingsService.whisperModelSize})',
        );
        _isLoadingModel = true;
        notifyListeners();
        return WhisperBatchTranscriber(
          modelSize: SettingsService.whisperModelSize,
        );

      default: // 'cloud'
        debugPrint('Starting with CLOUD Deepgram transcription');
        return DeepgramStreamingTranscriber(
          apiKey: SettingsService.deepgramApiKey,
          language: SettingsService.language,
          // Deepgram gets linear16 for the phone mic (raw PCM), opus for Omi.
          encoding: useOpusEncoding ? AudioEncoding.opus : AudioEncoding.pcm16,
          sampleRate: 16000,
        );
    }
  }

  /// Brings the foreground service up for [reasons]. Never throws: a session
  /// that cannot get a service still works while the app is in the foreground,
  /// so a failure here must not abort recording.
  Future<void> _startBackgroundRunner(Set<BackgroundReason> reasons) async {
    _sessionNotificationThrottle.reset();
    try {
      await _backgroundRunner.start(reasons: reasons);
    } catch (e) {
      debugPrint('Background runner failed to start: $e');
    }
  }

  /// Takes the foreground service down once the session is no longer
  /// listening. An idle session shows no persistent notification, whether or
  /// not the wearable is still connected (LO-24, `docs/06-roadmap.md`).
  Future<void> _stopBackgroundRunnerWhenIdle() async {
    if (_isListening) {
      return;
    }
    // An interrupted session is not idle: the process has to survive until the
    // wearable is back or the grace window expires (LO-22).
    if (_isAwaitingReconnect) {
      return;
    }
    _sessionNotificationThrottle.reset();
    try {
      await _backgroundRunner.stop();
    } catch (e) {
      debugPrint('Background runner failed to stop: $e');
    }
  }

  /// Refreshes the persistent notification with the connection state and the
  /// length of the conversation being recorded. Cheap to call often: the
  /// throttle drops updates that only move the clock forward.
  void _updateSessionNotification() {
    if (!_isListening && !_isAwaitingReconnect) {
      return;
    }
    final startedAt = _session.currentConversation?.createdAt;
    final now = DateTime.now();
    final candidate = SessionNotificationText.forSession(
      usingPhoneMic: _isUsingPhoneMic,
      deviceConnected: _deviceState == DeviceConnectionState.connected,
      conversationLength:
          startedAt == null ? Duration.zero : now.difference(startedAt),
    );
    final next = _sessionNotificationThrottle.next(candidate, now);
    if (next == null) {
      return;
    }
    unawaited(_backgroundRunner.update(next.text));
  }

  /// Queues the summarisation of [conversation] and nudges the queue once so a
  /// phone that is online does not wait for the next poll.
  ///
  /// Without an OpenAI key there is nothing to summarise, so the placeholder
  /// title [ConversationFinalizer] wrote stays as the final one and no row is
  /// queued. Passed to the finalizer, which logs and swallows a failure here:
  /// the conversation itself is already persisted.
  Future<void> _enqueueFinalization(Conversation conversation) async {
    if (SettingsService.openaiApiKey.isEmpty) return;
    if (conversation.transcript.trim().isEmpty) return;

    await _finalizationQueue.enqueue(
      conversationId: conversation.id,
      transcript: conversation.transcript,
    );
    // Fire and forget: if this attempt fails the queue keeps the row and
    // retries it on the next connectivity event or poll.
    _drainFinalizationQueue();
  }

  /// Manually save current conversation without waiting for silence
  Future<void> manualSaveConversation() => _session.saveNow();

  /// Stop listening.
  ///
  /// The session saves whatever it has not finalized yet and releases the
  /// transcriber, the audio source and the device audio stream; what is left
  /// here is the foreground service and the flags the pages read.
  Future<void> stopListening() async {
    if (!_isListening) return;

    await _session.stop();

    _isListening = false;
    _isUsingPhoneMic = false;

    await _stopBackgroundRunnerWhenIdle();

    notifyListeners();

    debugPrint('Stopped continuous listening');
  }

  // === Conversations Methods ===

  Future<void> loadConversations() async {
    _conversations = await DatabaseService.getConversations();
    notifyListeners();
  }

  Future<void> deleteConversation(String id) async {
    await DatabaseService.deleteConversation(id);
    await loadConversations();
  }

  // === Chat Methods ===

  Future<void> sendChatMessage(String message) async {
    if (message.trim().isEmpty) return;
    if (!SettingsService.hasOpenAIKey) {
      throw Exception('Please configure OpenAI API key in settings');
    }

    // Add user message
    _chatMessages.add(
      ChatMessage(
        id: const Uuid().v4(),
        text: message,
        isUser: true,
        createdAt: DateTime.now(),
      ),
    );
    _isChatLoading = true;
    notifyListeners();

    // Build context from recent conversations
    final context = _buildMemoryContext();

    // Get AI response. Built per call for the same reason every other
    // [LlmClient] call site here is: see [_newLlmClient].
    final llmClient = _newLlmClient();

    try {
      final response = await llmClient.chat(message, context: context);

      _chatMessages.add(
        ChatMessage(
          id: const Uuid().v4(),
          text: response,
          isUser: false,
          createdAt: DateTime.now(),
        ),
      );
    } catch (e) {
      _chatMessages.add(
        ChatMessage(
          id: const Uuid().v4(),
          text: 'Error: ${e.toString()}',
          isUser: false,
          createdAt: DateTime.now(),
        ),
      );
    }

    _isChatLoading = false;
    notifyListeners();
  }

  String _buildMemoryContext() {
    final buffer = StringBuffer();

    // Include stored memories first
    if (_memories.isNotEmpty) {
      buffer.writeln('Important facts about the user:');
      for (final memory in _memories.take(20)) {
        buffer.writeln('• ${memory.content}');
      }
      buffer.writeln('');
    }

    // Then add recent conversation summaries
    if (_conversations.isNotEmpty) {
      buffer.writeln('Recent conversation summaries:');
      final recent = _conversations.take(5);
      for (final conv in recent) {
        buffer.writeln('---');
        buffer.writeln('Date: ${conv.createdAt.toString().substring(0, 16)}');
        if (conv.title.isNotEmpty) buffer.writeln('Topic: ${conv.title}');
        if (conv.summary.isNotEmpty) buffer.writeln('Summary: ${conv.summary}');
      }
    }

    return buffer.toString();
  }

  Future<void> loadMemories() async {
    _memories = await DatabaseService.getMemories();
    notifyListeners();
  }

  Future<void> deleteMemory(String id) async {
    await DatabaseService.deleteMemory(id);
    await loadMemories();
  }

  Future<void> updateMemory(String id, String content) async {
    await DatabaseService.updateMemory(id, content);
    await loadMemories();
  }

  Future<void> addMemory(String content, {String? sourceConversationId}) async {
    final memory = Memory(
      id: const Uuid().v4(),
      content: content.trim(),
      category: 'manual',
      createdAt: DateTime.now(),
      sourceConversationId: sourceConversationId,
    );
    await DatabaseService.saveMemory(memory);
    await loadMemories();
  }

  Future<void> loadTasks() async {
    _tasks = await DatabaseService.getTasks();
    notifyListeners();
  }

  Task? _findTaskById(String id) {
    final index = _tasks.indexWhere((t) => t.id == id);
    return index == -1 ? null : _tasks[index];
  }

  /// Cancels the reminder for [id] if the task is still in memory. The
  /// notification id derives from the persisted `createdAt`, so a task we
  /// cannot see is a task whose reminder we cannot address. Every UI path
  /// operates on a task taken from [tasks], so this is not reachable today;
  /// LO-35 can drop the caveat by reading the id back from the tasks table.
  Future<void> _cancelTaskNotification(String id) async {
    final task = _findTaskById(id);
    if (task == null) return;
    await NotificationService().cancelTaskNotification(
      notificationIdForTask(task),
    );
  }

  Future<void> deleteTask(String id) async {
    // Cancel the notification before the row goes away: the id is derived
    // from the task's createdAt, which we can only read while it is loaded.
    await _cancelTaskNotification(id);

    await DatabaseService.deleteTask(id);
    await loadTasks();
  }

  Future<void> toggleTaskCompletion(String id, bool isCompleted) async {
    await DatabaseService.updateTaskCompletion(id, isCompleted);

    // Manage notification
    if (isCompleted) {
      await _cancelTaskNotification(id);
    } else {
      // Find task to reschedule if needed
      final task = _findTaskById(id);
      if (task != null &&
          task.dueDate != null &&
          task.dueDate!.isAfter(DateTime.now())) {
        await NotificationService().scheduleTaskNotification(
          id: notificationIdForTask(task),
          title: task.title,
          dueDate: task.dueDate!,
        );
      }
    }

    await loadTasks();
  }

  void clearChat() {
    _chatMessages = [];
    notifyListeners();
  }

  /// Process a local audio file from SD card sync
  /// Returns the transcript text
  Future<String> processLocalAudioFile(String filePath) async {
    debugPrint('Processing local audio file: $filePath');

    // Read the audio data
    final audioData = await SdCardSyncService.readAudioFile(filePath);
    if (audioData == null || audioData.isEmpty) {
      throw Exception('Failed to read audio file');
    }

    debugPrint('Read ${audioData.length} bytes of audio data');

    // Determine codec from filename
    final isOpus = filePath.contains('opus');

    // If Opus, decode to PCM first
    List<int> pcmData;
    if (isOpus) {
      final decoder = OpusDecoder();
      await decoder.initialize();

      // Decode Opus frames
      pcmData = [];
      int offset = 0;
      while (offset < audioData.length) {
        // Each frame is prefixed with 4-byte length
        if (offset + 4 > audioData.length) break;

        final frameLength =
            audioData[offset] |
            (audioData[offset + 1] << 8) |
            (audioData[offset + 2] << 16) |
            (audioData[offset + 3] << 24);
        offset += 4;

        if (offset + frameLength > audioData.length) break;

        final frame = audioData.sublist(offset, offset + frameLength);
        final decoded = decoder.decode(Uint8List.fromList(frame));
        if (decoded != null) {
          pcmData.addAll(decoded);
        }
        offset += frameLength;
      }

      decoder.dispose();
      debugPrint('Decoded ${pcmData.length} bytes of PCM audio');
    } else {
      pcmData = audioData.toList();
    }

    // Transcribe using the configured transcription method
    final transcriptionMode = SettingsService.transcriptionMode;
    String transcript = '';

    switch (transcriptionMode) {
      case 'whisper':
        debugPrint('Using Whisper for local transcription');
        transcript = await _transcribeWithWhisper(Uint8List.fromList(pcmData));
        break;

      case 'sherpa':
        debugPrint('Using Sherpa for local transcription');
        transcript = await _transcribeWithSherpa(Uint8List.fromList(pcmData));
        break;

      default: // cloud
        debugPrint('Using Deepgram for transcription');
        transcript = await _transcribeWithDeepgram(Uint8List.fromList(pcmData));
    }

    // Save as a conversation if we got a transcript
    if (transcript.isNotEmpty) {
      final conversation = Conversation(
        id: const Uuid().v4(),
        createdAt: DateTime.now(),
        title: 'SD Card Recording',
        segments: [
          TranscriptSegment(
            text: transcript,
            speakerId: 0,
            startTime: 0,
            endTime: 0,
          ),
        ],
      );

      // The same finalizer the live path uses (LO-33): persist first,
      // summarise later, because an SD-card import can run while the phone is
      // offline and the recording must not depend on that call succeeding
      // (LO-23). The title set above survives — the finalizer only fills in a
      // placeholder when there is none.
      await _finalizer.finalize(conversation);

      debugPrint(
        'Saved SD card recording as conversation: ${conversation.title}',
      );
    }

    return transcript;
  }

  Future<String> _transcribeWithWhisper(Uint8List pcmData) async {
    final whisper = WhisperService(modelSize: SettingsService.whisperModelSize);

    try {
      await whisper.initialize();

      // Process all audio at once
      whisper.addAudio(pcmData);

      // Wait for processing
      await Future.delayed(const Duration(seconds: 5));

      whisper.stopProcessing();

      // Get accumulated transcript from the service
      // Note: The current WhisperService uses callbacks, so we'd need to modify it
      // For now, return a placeholder
      return 'Transcription with Whisper completed';
    } finally {
      whisper.dispose();
    }
  }

  Future<String> _transcribeWithSherpa(Uint8List pcmData) async {
    final sherpa = SherpaService();

    try {
      await sherpa.initialize();

      // Process all audio
      sherpa.addAudio(pcmData);

      // Wait for processing
      await Future.delayed(const Duration(seconds: 5));

      sherpa.stopProcessing();

      return 'Transcription with Sherpa completed';
    } finally {
      sherpa.dispose();
    }
  }

  Future<String> _transcribeWithDeepgram(Uint8List pcmData) async {
    if (!SettingsService.hasDeepgramKey) {
      throw Exception('Deepgram API key not configured');
    }

    // For file transcription, we'd need to use Deepgram's file upload API
    // instead of the streaming API
    // This is a placeholder - the actual implementation would upload the file

    // Save PCM to temporary WAV file
    final tempDir = await getTemporaryDirectory();
    final wavFile = File(
      '${tempDir.path}/sdcard_audio_${DateTime.now().millisecondsSinceEpoch}.wav',
    );

    // Create WAV header
    final header = _buildWavHeader(pcmData.length);
    final wavData = BytesBuilder();
    wavData.add(header);
    wavData.add(pcmData);
    await wavFile.writeAsBytes(wavData.toBytes());

    debugPrint('Saved temporary WAV file: ${wavFile.path}');

    // TODO: Implement Deepgram file upload API
    // For now return placeholder
    return 'Audio file saved. Cloud transcription pending.';
  }

  Future<void> startAudioTest() async {
    if (_isTestingAudio) return;

    // Ensure listening is active
    if (!_isListening) {
      if (SettingsService.savedDeviceId.isNotEmpty) {
        await scanAndConnectToSavedDevice();
        // Arming autoConnect returns immediately, so wait for the link itself
        // rather than for a fixed delay. A timeout falls through to the
        // not-connected branch below.
        await _waitForConnection(const Duration(seconds: 5));
      }
      if (_deviceState == DeviceConnectionState.connected) {
        await startListening();
      } else {
        notifyListeners(); // Error?
        return;
      }
    }

    debugPrint('Starting Audio Test...');
    _isTestingAudio = true;
    _testAudioBuffer.clear();
    // Divert decoded PCM away from the transcriber for the duration of the
    // test, which is what the old `_isTestingAudio` early-return in the audio
    // handler did.
    _session.pcmTap = _testAudioBuffer.addAll;
    notifyListeners();

    // Record for 3 seconds
    Future.delayed(const Duration(seconds: 3), () async {
      _session.pcmTap = null;
      debugPrint(
        'Audio Test Recording finished. Buffer size: ${_testAudioBuffer.length}',
      );
      _isTestingAudio = false;
      notifyListeners();

      if (_testAudioBuffer.isNotEmpty) {
        await _playBackTestAudio();
      }
    });
  }

  Future<void> _playBackTestAudio() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/test_audio.wav');

      // Create WAV header
      final pcmData = Uint8List.fromList(_testAudioBuffer);
      final header = _buildWavHeader(pcmData.length);
      final wavData = BytesBuilder();
      wavData.add(header);
      wavData.add(pcmData);

      await tempFile.writeAsBytes(wavData.toBytes());
      debugPrint('Playing back audio test file: ${tempFile.path}');

      await _audioPlayer.play(DeviceFileSource(tempFile.path));
    } catch (e) {
      debugPrint('Audio playback error: $e');
    }
  }

  Uint8List _buildWavHeader(int dataSize) {
    const sampleRate = 16000;
    const channels = 1;
    const bitsPerSample = 16;
    final fileSize = dataSize + 36;
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;

    final header = BytesBuilder();
    header.add('RIFF'.codeUnits);
    header.add(_int32ToBytes(fileSize));
    header.add('WAVE'.codeUnits);
    header.add('fmt '.codeUnits);
    header.add(_int32ToBytes(16));
    header.add(_int16ToBytes(1));
    header.add(_int16ToBytes(channels));
    header.add(_int32ToBytes(sampleRate));
    header.add(_int32ToBytes(byteRate));
    header.add(_int16ToBytes(blockAlign));
    header.add(_int16ToBytes(bitsPerSample));
    header.add('data'.codeUnits);
    header.add(_int32ToBytes(dataSize));
    return header.toBytes();
  }

  Uint8List _int32ToBytes(int value) =>
      Uint8List(4)..buffer.asByteData().setInt32(0, value, Endian.little);
  Uint8List _int16ToBytes(int value) =>
      Uint8List(2)..buffer.asByteData().setInt16(0, value, Endian.little);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleState = state;
    debugPrint('App lifecycle state: $state');

    if (state == AppLifecycleState.resumed) {
      NotificationService().resetGlobalBadge();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reconnectTimer?.cancel();
    _reconnectGraceTimer?.cancel();
    _stateSubscription?.cancel();
    _buttonSubscription?.cancel();
    _sessionStateSubscription?.cancel();
    _sessionSegmentsSubscription?.cancel();
    _sessionAnswerSubscription?.cancel();
    // The session's teardown closes the audio transport, which reaches back
    // into the device manager, so the manager may only go down afterwards.
    unawaited(
      _session.dispose().whenComplete(_deviceManager.dispose).catchError(
        (Object error) {
          debugPrint('Provider teardown failed: $error');
        },
      ),
    );
    unawaited(_finalizationQueue.stop());
    // Do not leave a foreground service (and its notification) behind.
    unawaited(_backgroundRunner.stop());
    _audioPlayer.dispose();
    super.dispose();
  }
}

/// The production [SessionFeedback]: phone haptics through `flutter/services`
/// and notifications through `NotificationService`.
///
/// Lives here rather than in `lib/session` so the session layer depends on
/// neither `flutter/services` nor `awesome_notifications`
/// (`docs/03-architecture.md` §1), and so the "is the processing notification
/// enabled" setting stays on this side of the boundary with the rest of
/// `SettingsService`.
class _PlatformSessionFeedback implements SessionFeedback {
  const _PlatformSessionFeedback();

  /// Mirrors the device pulse the session sends with the phone impact the
  /// pre-LO-33 button handler paired it with: short/medium/long ->
  /// light/medium/heavy.
  @override
  Future<void> haptic(HapticLevel level) async {
    switch (level) {
      case HapticLevel.short:
        await HapticFeedback.lightImpact();
      case HapticLevel.medium:
        await HapticFeedback.mediumImpact();
      case HapticLevel.long:
        await HapticFeedback.heavyImpact();
    }
  }

  @override
  Future<void> notify(String title, String body) =>
      NotificationService().showNotification(title, body);

  @override
  Future<void> notifyAiProgress(String message) async {
    if (!SettingsService.notifyProcessing) return;
    await NotificationService().showAiResponse(message);
  }

  @override
  Future<void> notifyAiAnswer(String message) =>
      NotificationService().showAiResponse(message);
}
