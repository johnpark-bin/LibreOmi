/// App state provider for device, conversations, and recording
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../audio/audio_routing.dart';
import '../audio/audio_source.dart';
import '../audio/omi_audio_source.dart';
import '../audio/opus_decoder.dart';
import '../audio/phone_mic_source.dart';
import '../device/device_manager.dart';
import '../device/omi_ble_device.dart';
import '../device/omi_device.dart';
import '../device/omi_gatt.dart';
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

  /// Rate-limits rewrites of the persistent notification so a burst of
  /// transcript segments does not produce a burst of platform calls.
  final SessionNotificationThrottle _sessionNotificationThrottle =
      SessionNotificationThrottle();

  // App lifecycle state
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  /// The one transcription backend for the current session, whichever mode
  /// settings selected. Built in [_startTranscriptionServices] and torn down
  /// in [stopListening].
  StreamingTranscriber? _transcriber;
  StreamSubscription<TranscriptSegment>? _segmentsSubscription;
  StreamSubscription<String>? _transcriberErrorsSubscription;

  /// The audio producer feeding [_transcriber]: an [OmiAudioSource] over the
  /// BLE notification stream, or a [PhoneMicSource] over the phone mic.
  AudioSource? _audioSource;

  OpusDecoder? _opusDecoder;

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

  // Phone mic state
  bool _isUsingPhoneMic = false;
  bool get isUsingPhoneMic => _isUsingPhoneMic;

  // Current conversation being recorded
  Conversation? _currentConversation;
  Conversation? get currentConversation => _currentConversation;
  List<TranscriptSegment> _liveSegments = [];
  List<TranscriptSegment> get liveSegments => _liveSegments;

  // Silence detection for auto-save
  static const Duration silenceTimeout = Duration(minutes: 2);
  Timer? _silenceTimer;
  DateTime? _lastTranscriptTime;
  bool _hasActiveConversation = false;

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

  // Hold-to-Ask AI
  DateTime? _buttonPressStartTime;
  String _aiQueryTranscript = ''; // Captured text from active transcriber
  bool _isHoldToAskActive = false;
  bool _isAiQueryProcessing = false; // Pauses main conversation transcription
  bool _isProcessingButtonEvent = false; // Debounce for button events
  bool get isHoldToAskActive => _isHoldToAskActive;
  bool get isAiQueryProcessing => _isAiQueryProcessing;

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
  StreamSubscription? _audioSubscription;
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
    _finalizationQueue = finalizationQueue ??
        FinalizationQueue(
          summarizer: _summarizeForQueue,
          applier: _applyFinalizationResult,
        );
    _init();
  }

  /// The queue's summariser. Built per call because the key and the model can
  /// change in settings between a conversation being queued and being retried.
  ///
  /// Deliberately a local: a drain runs in the background and would otherwise
  /// be able to swap a shared client out from under a chat request that is
  /// between its own assignment and its use. Every [LlmClient] call site in
  /// this class follows the same rule, so no shared field exists at all.
  ///
  /// TODO(LO-23): the queue still consumes an untyped map and reads the
  /// "Untitled Conversation" sentinel as "retry this later", so a failed
  /// summarisation is folded back into that sentinel here instead of being
  /// surfaced as the [LlmException] the client now throws. LO-23 makes the
  /// queue take typed errors and this bridge goes away with it.
  Future<Map<String, dynamic>> _summarizeForQueue(String transcript) async {
    final client = OpenAiClient.fromApiKey(
      apiKey: SettingsService.openaiApiKey,
      model: SettingsService.openaiModel,
    );
    try {
      final insights = await client.summarize(transcript);
      return insights.toMap();
    } on LlmException catch (e) {
      debugPrint('OpenAI summarize error: $e');
      return <String, dynamic>{
        'title': 'Untitled Conversation',
        'summary': '',
        'memories': <String>[],
        'tasks': <dynamic>[],
      };
    }
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

      // Listen to button events
      _buttonSubscription = _deviceManager.buttonEvents.listen(_handleButtonPress);

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
    if (_isListening) return;

    _isUsingPhoneMic = false;

    // The foreground service goes up before any audio flows, so the process is
    // never killed mid-setup (docs/04 §4). An Omi session only needs the
    // connectedDevice type; the microphone type is reserved for the phone-mic
    // path, which Android 14+ allows to start from the foreground only.
    await _startBackgroundRunner(<BackgroundReason>{
      BackgroundReason.connectedDevice,
    });

    try {
      await _startTranscriptionServices(useOpusEncoding: true);

      // Start audio stream from Omi device
      await _deviceManager.current?.startAudioStream();

      // Initialize Opus decoder for Omi device (needed for local transcription and debug playback)
      _opusDecoder = OpusDecoder();
      await _opusDecoder!.initialize();

      // The source only transforms the BLE notification stream (header strip,
      // encoding tag); starting and stopping the stream itself stays with
      // the device, so the session lifecycle above is unchanged.
      final source = OmiAudioSource(_deviceManager.audioPackets);
      _audioSource = source;
      _audioSubscription = source.start().listen(_handleOmiAudioChunk);
    } catch (_) {
      // Setup failed, so the session never reaches listening: take the service
      // back down instead of leaving a notification for a session that is not
      // running.
      await _discardHalfStartedSession();
      await _stopBackgroundRunnerWhenIdle();
      rethrow;
    }

    _isListening = true;
    _startNewConversation();
    notifyListeners();

    debugPrint(
      'Started continuous listening with Omi device (${SettingsService.transcriptionMode})',
    );
  }

  /// Start continuous listening using iPhone microphone
  Future<void> startListeningWithPhoneMic() async {
    if (_isListening) return;

    // Check mic permission
    final hasPermission = await _micService.hasPermission();
    if (!hasPermission) {
      throw Exception(
        'Microphone permission denied. Please enable in Settings.',
      );
    }

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
      await _startTranscriptionServices(useOpusEncoding: false);

      // Start phone mic recording. `prepare()` rather than relying on
      // `start()` to kick the recorder off, because only an awaited call can
      // surface a recorder failure as an exception here, which is what rolls
      // the half-open session back below.
      final source = PhoneMicSource();
      _audioSource = source;
      await source.prepare();
      _audioSubscription = source.start().listen(_handlePhoneMicAudioChunk);
    } catch (_) {
      // Leaving the flag set would keep auto-reconnect switched off for the
      // rest of the process.
      _isUsingPhoneMic = false;
      await _discardHalfStartedSession();
      await _stopBackgroundRunnerWhenIdle();
      rethrow;
    }

    _isListening = true;
    _startNewConversation();
    notifyListeners();

    debugPrint(
      'Started continuous listening with iPhone microphone (${SettingsService.transcriptionMode})',
    );
  }

  /// Releases the session state a failed `startListening*` managed to bring
  /// up. [stopListening] cannot do this job: it returns early while
  /// `_isListening` is false, which it still is on this path. Without it a
  /// retry would overwrite the subscriptions and leave the previous ones
  /// listening to a transcriber whose controllers are never closed.
  ///
  /// Does *not* call `OmiDevice.stopAudioStream()`: the caller knows whether
  /// it got that far, and the phone-mic path has already cleared
  /// `_isUsingPhoneMic` by the time this runs, so the flag cannot be used to
  /// decide. Notifications left enabled by a setup that failed after
  /// `startAudioStream()` are the same leak `main` had; see the PR follow-up
  /// note.
  Future<void> _discardHalfStartedSession() async {
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await _audioSource?.stop();
    _audioSource = null;
    await _segmentsSubscription?.cancel();
    _segmentsSubscription = null;
    await _transcriberErrorsSubscription?.cancel();
    _transcriberErrorsSubscription = null;
    await _transcriber?.stop();
    _transcriber = null;
    _opusDecoder?.dispose();
    _opusDecoder = null;
  }

  /// Build and start the one transcription backend the selected mode calls
  /// for. [useOpusEncoding] is true for the Omi path, which streams Opus, and
  /// false for the phone mic, which streams raw PCM16.
  Future<void> _startTranscriptionServices({
    required bool useOpusEncoding,
  }) async {
    final transcriptionMode = SettingsService.transcriptionMode;

    // Validate API keys for cloud mode
    if (transcriptionMode == 'cloud' && !SettingsService.hasDeepgramKey) {
      throw Exception(
        'Please configure Deepgram API key in settings or switch to local transcription',
      );
    }

    final StreamingTranscriber transcriber;
    final String errorLabel;

    // Build the transcriber for the selected mode
    switch (transcriptionMode) {
      case 'sherpa':
        debugPrint(
          'Starting with LOCAL Sherpa-ONNX transcription (with diarization)',
        );
        _isLoadingModel = true;
        notifyListeners();

        transcriber = SherpaStreamingTranscriber();
        errorLabel = 'Sherpa';

      case 'whisper':
        debugPrint(
          'Starting with LOCAL Whisper transcription (${SettingsService.whisperModelSize})',
        );
        _isLoadingModel = true;
        notifyListeners();

        transcriber = WhisperBatchTranscriber(
          modelSize: SettingsService.whisperModelSize,
        );
        errorLabel = 'Whisper';

      default: // 'cloud'
        debugPrint('Starting with CLOUD Deepgram transcription');
        transcriber = DeepgramStreamingTranscriber(
          apiKey: SettingsService.deepgramApiKey,
          language: SettingsService.language,
          // Deepgram gets linear16 for the phone mic (raw PCM), opus for Omi.
          encoding: useOpusEncoding ? AudioEncoding.opus : AudioEncoding.pcm16,
          sampleRate: 16000,
        );
        errorLabel = 'Deepgram';
    }

    _transcriber = transcriber;
    // Subscribed before start() so nothing produced during start-up is lost.
    _segmentsSubscription = transcriber.segments.listen(_onSegmentReceived);
    _transcriberErrorsSubscription = transcriber.errors.listen(
      (error) => debugPrint('$errorLabel error: $error'),
    );

    try {
      await transcriber.start();
    } finally {
      // In a `finally` so a model that fails to load does not leave the
      // spinner up for the rest of the process.
      _isLoadingModel = false;
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
    final startedAt = _currentConversation?.createdAt;
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

  void _startNewConversation() {
    _currentConversation = Conversation(
      id: const Uuid().v4(),
      createdAt: DateTime.now(),
    );
    _liveSegments = [];
    _hasActiveConversation = false;
    _lastTranscriptTime = null;
    _cancelSilenceTimer();
    debugPrint('Started new conversation: ${_currentConversation!.id}');
  }

  void _onSegmentReceived(TranscriptSegment segment) {
    if (!_isListening) return;

    // Check for silence to handle end-of-utterance
    // ...

    // Accumulate for Hold-to-Ask
    if (_isHoldToAskActive && segment.text.isNotEmpty) {
      _aiQueryTranscript += " ${segment.text}";
    }

    // Add the segment to the current conversation
    _liveSegments.add(segment);
    _lastTranscriptTime = DateTime.now();
    _hasActiveConversation = true;

    // Reset silence timer
    _resetSilenceTimer();

    // Keep the persistent notification's conversation length roughly current.
    _updateSessionNotification();

    notifyListeners();
  }

  void _resetSilenceTimer() {
    _cancelSilenceTimer();

    _silenceTimer = Timer(silenceTimeout, () {
      if (_hasActiveConversation && _liveSegments.isNotEmpty) {
        debugPrint('Silence timeout reached - saving conversation');
        _saveCurrentConversation();
      }
    });
  }

  void _cancelSilenceTimer() {
    _silenceTimer?.cancel();
    _silenceTimer = null;
  }

  /// Save current conversation and start a new one.
  ///
  /// The conversation is written to the database with a placeholder title
  /// *before* any network call, and the summarisation is handed to
  /// [_finalizationQueue] (LO-23). A conversation recorded in a tunnel is
  /// therefore never lost; its title and summary fill in later, so History can
  /// show a placeholder row for a while.
  Future<void> _saveCurrentConversation() async {
    if (_currentConversation == null || _liveSegments.isEmpty) {
      _startNewConversation();
      return;
    }

    // Copy data before resetting
    final conversationToSave = _currentConversation!;
    conversationToSave.segments = List.from(_liveSegments);

    // Start new conversation immediately so listening continues
    _startNewConversation();
    notifyListeners();

    conversationToSave.title =
        'Conversation ${conversationToSave.createdAt.toString().substring(0, 16)}';

    await DatabaseService.saveConversation(conversationToSave);
    await loadConversations();

    await _enqueueFinalization(conversationToSave);

    debugPrint('Saved conversation: ${conversationToSave.title}');
  }

  /// Queues the summarisation of [conversation] and nudges the queue once so a
  /// phone that is online does not wait for the next poll.
  ///
  /// Without an OpenAI key there is nothing to summarise, so the placeholder
  /// title stays as the final one and no row is queued.
  Future<void> _enqueueFinalization(Conversation conversation) async {
    if (SettingsService.openaiApiKey.isEmpty) return;
    if (conversation.transcript.trim().isEmpty) return;

    try {
      await _finalizationQueue.enqueue(
        conversationId: conversation.id,
        transcript: conversation.transcript,
      );
      // Fire and forget: if this attempt fails the queue keeps the row and
      // retries it on the next connectivity event or poll.
      _drainFinalizationQueue();
    } catch (e) {
      debugPrint('Failed to queue finalization: $e');
    }
  }

  /// Writes a finished summarisation back into storage. Called by
  /// [_finalizationQueue] once a request finally succeeds, which can be long
  /// after the conversation itself was saved.
  ///
  /// This is the memory/task extraction both save paths used to run inline; it
  /// only moved to one place inside this provider. Folding it (and this whole
  /// method) into `session/conversation_finalizer.dart` is LO-33 in M3.
  Future<void> _applyFinalizationResult(
    String conversationId,
    Map<String, dynamic> result,
  ) async {
    final conversation = await DatabaseService.getConversation(conversationId);
    if (conversation == null) {
      // Deleted while the request sat in the queue: nothing left to fill in.
      debugPrint('Finalization result for a deleted conversation: $conversationId');
      return;
    }

    final title = (result['title'] as String?)?.trim();
    if (title != null && title.isNotEmpty) {
      conversation.title = title;
    }
    conversation.summary = (result['summary'] as String?) ?? '';
    await DatabaseService.saveConversation(conversation);

    // Save extracted memories (with deduplication)
    final memories = (result['memories'] as List?)?.cast<String>() ?? const <String>[];
    for (final memoryContent in memories) {
      if (memoryContent.trim().isNotEmpty) {
        final hasSimilar = await DatabaseService.hasSimilarMemory(
          memoryContent,
        );
        if (!hasSimilar) {
          final memory = Memory(
            id: const Uuid().v4(),
            content: memoryContent.trim(),
            category: 'fact',
            createdAt: DateTime.now(),
            sourceConversationId: conversation.id,
          );
          await DatabaseService.saveMemory(memory);
          debugPrint('Saved memory: ${memory.content}');
        } else {
          debugPrint('Skipped duplicate memory: $memoryContent');
        }
      }
    }

    // Save extracted tasks (with deduplication)
    final tasks = result['tasks'] as List? ?? const [];
    for (final taskData in tasks) {
      if (taskData is Map && taskData['title'] != null) {
        final taskTitle = taskData['title'].toString().trim();
        if (taskTitle.isNotEmpty) {
          final hasSimilar = await DatabaseService.hasSimilarTask(taskTitle);
          if (!hasSimilar) {
            DateTime? dueDate;
            if (taskData['due_date'] != null) {
              try {
                dueDate = DateTime.parse(taskData['due_date'].toString());
              } catch (e) {
                debugPrint(
                  'Failed to parse due date: ${taskData['due_date']}',
                );
              }
            }
            final task = Task(
              id: const Uuid().v4(),
              title: taskTitle,
              description: taskData['description']?.toString(),
              dueDate: dueDate,
              createdAt: DateTime.now(),
              sourceConversationId: conversation.id,
            );
            await DatabaseService.saveTask(task);

            // Schedule notification if due date is set
            if (task.dueDate != null) {
              await NotificationService().scheduleTaskNotification(
                id: notificationIdForTask(task),
                title: task.title,
                dueDate: task.dueDate!,
              );
            }

            debugPrint('Saved task: ${task.title} (due: ${task.dueDate})');
          } else {
            debugPrint('Skipped duplicate task: $taskTitle');
          }
        }
      }
    }

    await loadConversations();
    await loadMemories();
    await loadTasks();

    debugPrint('Finalized conversation: ${conversation.title}');
  }

  /// Manually save current conversation without waiting for silence
  Future<void> manualSaveConversation() async {
    if (_liveSegments.isNotEmpty) {
      await _saveCurrentConversation();
    }
  }

  /// Stop listening
  Future<void> stopListening() async {
    if (!_isListening) return;

    _cancelSilenceTimer();

    // Save any pending conversation
    if (_hasActiveConversation && _liveSegments.isNotEmpty) {
      await _saveCurrentConversation();
    }

    await _audioSubscription?.cancel();
    _audioSubscription = null;

    // Stop audio source. PhoneMicSource owns the recorder, so stopping it is
    // enough there; OmiAudioSource does not own the BLE stream, so that one
    // still has to be stopped explicitly.
    await _audioSource?.stop();
    _audioSource = null;
    if (!_isUsingPhoneMic) {
      await _deviceManager.current?.stopAudioStream();
    }

    // Clean up the transcription backend
    await _segmentsSubscription?.cancel();
    _segmentsSubscription = null;
    await _transcriberErrorsSubscription?.cancel();
    _transcriberErrorsSubscription = null;
    await _transcriber?.stop();
    _transcriber = null;

    _opusDecoder?.dispose();
    _opusDecoder = null;

    _isListening = false;
    _isUsingPhoneMic = false;
    _currentConversation = null;
    _liveSegments = [];

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

    // Get AI response
    final llmClient = OpenAiClient.fromApiKey(
      apiKey: SettingsService.openaiApiKey,
      model: SettingsService.openaiModel,
    );

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

      // Persist first, summarise later: an SD-card import can run while the
      // phone is offline, and the recording must not depend on that call
      // succeeding (LO-23).
      await DatabaseService.saveConversation(conversation);
      await loadConversations();

      await _enqueueFinalization(conversation);

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
    notifyListeners();

    // Record for 3 seconds
    Future.delayed(const Duration(seconds: 3), () async {
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

  Timer?
  _doubleTapTimer; // Keep mainly for debouncing if needed, but logic is now state-driven

  // Audio Buffering for Hold-to-Ask
  List<int> _voiceCommandBuffer = [];
  bool _isCollectingVoiceCommand = false;

  void _handleButtonPress(ButtonEvent event) async {
    // Debounce - prevent multiple button events from being processed too quickly
    if (_isProcessingButtonEvent) {
      debugPrint("Button event blocked - still processing previous event");
      return;
    }
    _isProcessingButtonEvent = true;

    debugPrint("Button Event Parsed: $event");

    // STATE 2: Double Tap (End/Save)
    if (event == ButtonEvent.doubleTap) {
      debugPrint("Double Tap Detected (State 2): Saving Conversation");
      HapticFeedback.heavyImpact(); // Confirm action (Phone)
      _deviceManager.current?.haptic(HapticLevel.long); // Confirm action (Omi - Long 500ms)
      if (_liveSegments.isEmpty) {
        NotificationService().showNotification(
          "Double Tap",
          "No active conversation to save.",
        );
      } else {
        NotificationService().showNotification(
          "Double Tap",
          "Saving conversation...",
        );
        await manualSaveConversation();
      }
      _isProcessingButtonEvent = false;
      return;
    }

    // STATE 1: Short Press (Toggle - first click starts, second click ends)
    if (event == ButtonEvent.singleTap) {
      if (_isHoldToAskActive) {
        // Second click - end AI query and process
        debugPrint("Short Press (State 1): Ending AI Query");
        HapticFeedback.lightImpact(); // Confirm end (Phone)
        _deviceManager.current?.haptic(HapticLevel.short); // Confirm end (Omi - Short 20ms)

        // Wait to capture trailing audio
        await Future.delayed(const Duration(milliseconds: 1500));

        _isHoldToAskActive = false;
        _isCollectingVoiceCommand = false;
        notifyListeners();

        debugPrint("Final Query Transcript: '$_aiQueryTranscript'");

        _isAiQueryProcessing = true;

        await _processAiQuery();

        _isAiQueryProcessing = false;
        _buttonPressStartTime = null;
        _voiceCommandBuffer = [];
      } else {
        // First click - start AI query
        debugPrint("Short Press (State 1): Starting AI Query");
        HapticFeedback.mediumImpact(); // Confirm start (Phone)
        _deviceManager.current?.haptic(HapticLevel.medium); // Confirm start (Omi - Medium 50ms)
        _buttonPressStartTime = DateTime.now();
        _isHoldToAskActive = true;
        _aiQueryTranscript = '';

        _isCollectingVoiceCommand = true;
        _voiceCommandBuffer = [];

        if (!_isListening) {
          // startListening() brings the foreground service up before it touches
          // the audio stream and installs the subscription itself; opening the
          // stream here first would invert that order and leak a subscription.
          try {
            await startListening();
          } catch (e) {
            debugPrint('Could not start listening for the query: $e');
          }
        }

        notifyListeners();
      }
      _isProcessingButtonEvent = false;
      return;
    }

    // STATE 4: Short Press End (Not used with toggle - ignore)
    if (event == ButtonEvent.singleTapRelease) {
      debugPrint("Short Press End (State 4) - Ignored (using toggle)");
      _isProcessingButtonEvent = false;
      return;
    }

    // STATE 3: Long Press Start (Disabled - now turns off device in new firmware)
    if (event == ButtonEvent.longPressStart) {
      debugPrint("Long Press Detected (State 3) - Disabled for AI Query");
      _isProcessingButtonEvent = false;
      return;
    }

    // STATE 5: Long Press End
    if (event == ButtonEvent.longPressEnd) {
      debugPrint("Long Press Ended (State 5) - Ignoring (long press disabled)");
      _isProcessingButtonEvent = false;
      return;
    }
  }

  // Audio Data Handler for the Omi device (Opus encoded, header already
  // stripped by OmiAudioSource)
  void _handleOmiAudioChunk(AudioChunk chunk) {
    // BUFFER for Voice Command if active
    if (_isCollectingVoiceCommand) {
      _voiceCommandBuffer.addAll(chunk.bytes);
    }

    // Decode Opus to PCM (needed for Sherpa and Debug Playback)
    final pcmData = _opusDecoder?.decode(chunk.bytes);

    if (_isTestingAudio) {
      if (pcmData != null) _testAudioBuffer.addAll(pcmData);
      return;
    }

    // PAUSE: If AI is processing a query, ignore incoming audio for the main conversation
    if (_isAiQueryProcessing) return;

    _feedTranscriber(chunk, decodedPcm: pcmData);
  }

  // Audio Data Handler for the phone microphone (raw PCM16)
  void _handlePhoneMicAudioChunk(AudioChunk chunk) {
    if (chunk.bytes.isEmpty) return;

    _feedTranscriber(chunk);
  }

  /// Hands one chunk to the active transcriber, decoding it first when the
  /// backend only accepts PCM16. [decodedPcm] lets the Omi path reuse the
  /// decode it already ran for debug playback instead of decoding twice; a
  /// chunk whose decode failed or which cannot be converted is dropped, which
  /// is what the per-mode routing did before.
  void _feedTranscriber(AudioChunk chunk, {Uint8List? decodedPcm}) {
    final transcriber = _transcriber;
    if (transcriber == null) return;

    switch (routeAudioChunk(
      chunk: chunk.encoding,
      accepted: transcriber.acceptedEncoding,
    )) {
      case AudioRouting.passThrough:
        transcriber.feed(chunk);
      case AudioRouting.decodeOpus:
        final pcm = decodedPcm ?? _opusDecoder?.decode(chunk.bytes);
        if (pcm == null) return;
        transcriber.feed(
          AudioChunk(
            bytes: pcm,
            encoding: AudioEncoding.pcm16,
            at: chunk.at,
          ),
        );
      case AudioRouting.drop:
        break;
    }
  }

  Future<void> _processAiQuery() async {
    final query = _aiQueryTranscript.trim();
    if (query.isEmpty) {
      NotificationService().showAiResponse(
        "I couldn't hear that. Please try again.",
      );
      return;
    }

    // Notify user we are processing
    if (SettingsService.notifyProcessing) {
      NotificationService().showAiResponse("Processing: $query");
    }

    final llmClient = OpenAiClient.fromApiKey(
      apiKey: SettingsService.openaiApiKey,
      model: SettingsService.openaiModel,
    );

    try {
      // Chat
      final response = await llmClient.chat(
        query,
        context:
            "You are Omi, a helpful AI wearable assistant. Your responses are on notifications, so they MUST be extremely concise. Aim for just the answer. Navigate straight to the point. No fluff.",
      );

      debugPrint('AI Response: $response');
      NotificationService().showAiResponse(response);
    } catch (e) {
      debugPrint("AI Query failed: $e");
      NotificationService().showAiResponse(
        "Failed to process question. Please try again.",
      );
    }
  }

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
    _audioSubscription?.cancel();
    _buttonSubscription?.cancel();
    _silenceTimer?.cancel();
    unawaited(_deviceManager.dispose());
    _segmentsSubscription?.cancel();
    _transcriberErrorsSubscription?.cancel();
    final transcriber = _transcriber;
    if (transcriber != null) {
      unawaited(transcriber.stop());
    }
    unawaited(_finalizationQueue.stop());
    // Do not leave a foreground service (and its notification) behind.
    unawaited(_backgroundRunner.stop());
    _audioPlayer.dispose();
    super.dispose();
  }
}
