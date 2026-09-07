/// Owns the recording session -- everything between "audio is flowing" and
/// "the conversation has been handed off" that still needs settings,
/// permissions or the foreground service (LO-34, unit 2 of the pre-LO-34 monolith's
/// split, `docs/06-roadmap.md`).
///
/// Depends on `DeviceManager`, `LibraryController` and `ChatController` but
/// never on `DeviceController` -- the agreed dependency direction for the
/// whole refactor is `DeviceController -> SessionController -> {
/// DeviceManager, LibraryController, ChatController }`. Where this class
/// needs to reconnect to the saved device (the audio self-test path) it uses
/// [ensureSavedDeviceConnection], a late-bound callback `main.dart` wires in
/// once `DeviceController` exists.
library;

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import '../audio/audio_source.dart';
import '../audio/omi_audio_source.dart';
import '../audio/phone_mic_source.dart';
import '../audio/wav.dart';
import '../data/db.dart';
import '../device/device_manager.dart';
import '../device/omi_device.dart';
import '../device/omi_gatt.dart';
import '../intelligence/llm_client.dart';
import '../intelligence/openai_client.dart';
import '../l10n/l10n.dart';
import '../models/conversation.dart';
import '../platform/background_runner.dart';
import '../platform/background_runner_factory.dart';
import '../services/finalization_queue.dart';
import '../services/mic_service.dart';
import '../services/notification_service.dart';
import '../services/settings_service.dart';
import '../session/conversation_finalizer.dart';
import '../session/recording_session.dart';
import '../session/sdcard_import.dart';
import '../session/session_state.dart';
import '../transcription/deepgram_prerecorded.dart';
import '../transcription/deepgram_streaming.dart';
import '../transcription/offline_file_transcriber.dart';
import '../transcription/sherpa_streaming.dart';
import '../transcription/transcriber.dart';
import '../transcription/offline_batch.dart';
import 'chat_controller.dart';
import 'library_controller.dart';

class SessionController extends ChangeNotifier {
  SessionController({
    required DeviceManager deviceManager,
    required LibraryController library,
    required ChatController chat,
    BackgroundRunner? backgroundRunner,
    FinalizationQueue? finalizationQueue,
    RecordingSession? session,
    Duration? reconnectGraceWindowOverride,
  })  : _deviceManager = deviceManager,
        _chat = chat,
        _backgroundRunner = backgroundRunner ?? createBackgroundRunner(),
        _reconnectGraceWindow = reconnectGraceWindowOverride ?? reconnectGraceWindow {
    _finalizer = ConversationFinalizer(
      database: AppDatabase.instance,
      enqueue: _enqueueFinalization,
      scheduleReminder: NotificationService().scheduleTaskNotification,
      onConversationSaved: library.loadConversations,
      onInsightsApplied: library.reloadAll,
    );
    _sdCardImporter = SdCardImporter(
      finalizer: _finalizer,
      transcriberFactory: _buildFileTranscriber,
      temporaryDirectory: getTemporaryDirectory,
    );
    _finalizationQueue = finalizationQueue ??
        FinalizationQueue(
          llmClient: _newLlmClient,
          applier: _finalizer.applyInsights,
        );
    _session = session ??
        RecordingSession(
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
  }

  final DeviceManager _deviceManager;
  final ChatController _chat;

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

  /// Post-processing for one synced SD-card recording: decode, transcribe,
  /// finalize (LO-51). Holds no state between imports; the transcriber is
  /// built per import from the settings in force at that moment.
  late final SdCardImporter _sdCardImporter;

  /// The session state machine (`docs/03-architecture.md` §4). Everything
  /// this controller used to do between "audio is flowing" and "the
  /// conversation has been handed off" now lives there; what stays here is
  /// what needs settings, permissions or the foreground service.
  late final RecordingSession _session;

  final MicService _micService = MicService();

  StreamSubscription<SessionState>? _sessionStateSubscription;
  StreamSubscription<List<TranscriptSegment>>? _sessionSegmentsSubscription;
  StreamSubscription<AiAnswer>? _sessionAnswerSubscription;

  /// Completes when the session's asynchronous teardown has finished. Chained
  /// onto by `DeviceController.dispose()`, which may only drop the device
  /// manager once the audio transport this closes is really shut.
  Future<void> get teardown => _teardown;
  Future<void> _teardown = Future<void>.value();

  /// Rate-limits rewrites of the persistent notification so a burst of
  /// transcript segments does not produce a burst of platform calls.
  final SessionNotificationThrottle _sessionNotificationThrottle =
      SessionNotificationThrottle();

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

  bool _isUsingPhoneMic = false;
  bool get isUsingPhoneMic => _isUsingPhoneMic;

  /// The conversation being recorded, owned by [_session].
  Conversation? get currentConversation => _session.currentConversation;

  /// Mirror of the session's live segments, kept so the pages can read them
  /// synchronously off a `Consumer` rebuild.
  List<TranscriptSegment> _liveSegments = [];
  List<TranscriptSegment> get liveSegments => _liveSegments;

  /// While the wearable is out of range the process has to stay alive or
  /// Android may kill it and no reconnect happens at all, so the foreground
  /// service outlives an involuntary disconnect for [reconnectGraceWindow].
  /// Without a bound an app left out of range would show a persistent
  /// notification forever, which is exactly what LO-24 (docs/04 section 4)
  /// forbids.
  static const Duration reconnectGraceWindow = Duration(minutes: 5);

  /// The grace window this instance actually uses. Defaults to the static
  /// [reconnectGraceWindow] above; a test can shorten it via the constructor's
  /// `reconnectGraceWindowOverride` rather than waiting 5 real minutes for
  /// `beginAwaitingReconnect()`'s timer to fire.
  final Duration _reconnectGraceWindow;
  bool _isAwaitingReconnect = false;
  Timer? _reconnectGraceTimer;

  // Hold-to-Ask AI, owned by [_session].
  bool get isHoldToAskActive => _session.isHoldToAskActive;
  bool get isAiQueryProcessing => _session.isAnswering;

  bool _isTestingAudio = false;
  bool get isTestingAudio => _isTestingAudio;

  bool _isLoadingModel = false;
  bool get isLoadingModel => _isLoadingModel;
  final List<int> _testAudioBuffer = [];
  // Constructed lazily rather than as an eager field: `AudioPlayer()` reaches
  // for the `audioplayers` plugin channel the moment it is created (not just
  // when `play()` is first called), so a test that builds a `SessionController`
  // and never exercises the test-audio playback path must not pay for it.
  AudioPlayer? _audioPlayerInstance;
  AudioPlayer get _audioPlayer => _audioPlayerInstance ??= AudioPlayer();

  /// Connects to the saved device on the audio self-test's behalf.
  /// `DeviceController` owns the auto-reconnect flag and the backoff ladder,
  /// and it depends on this class rather than the other way round, so
  /// `main.dart` assigns `deviceController.scanAndConnectToSavedDevice` here.
  Future<void> Function()? ensureSavedDeviceConnection;

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

  /// Mirrors the session's outputs into the state the pages read.
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
    // and, since #33, also recorded on the chat page. A failure recording it
    // must not escape into the app zone as an unhandled async error, same as
    // the other two subscriptions above (which cannot fail) and the button
    // subscription below.
    _sessionAnswerSubscription = _session.aiAnswers.listen((answer) {
      unawaited(_chat.recordAiAnswer(answer).catchError((Object error) {
        debugPrint('Failed to record AI answer in chat: $error');
      }));
    });
  }

  /// Starts the finalization queue and drains it once.
  ///
  /// Deliberately not run from this class's constructor: the queue lives
  /// entirely in the database, so starting it before storage has proven
  /// usable would only arm a timer with nothing to drain. `main.dart` calls
  /// this after `LibraryController` has loaded conversations/memories/tasks
  /// -- the ordering the old monolith's `_init()` used to enforce by loading those
  /// lists itself before starting the queue. Anything left over from a
  /// previous process (killed mid-retry, or queued while offline) is picked
  /// up by this first drain.
  Future<void> init() async {
    _finalizationQueue.start();
    _drainFinalizationQueue();
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

  /// Resolves true once the device is connected, false on timeout.
  ///
  /// Uses an explicit subscription rather than `firstWhere().timeout()`:
  /// a timeout on the future would leave the underlying listener on the
  /// broadcast stream until the next connection.
  Future<bool> _waitForConnection(Duration timeout) async {
    if (_deviceManager.state == DeviceConnectionState.connected) return true;
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

  // === Continuous Listening Methods ===

  /// The old monolith's `_startListeningIfReady`, called by `DeviceController`
  /// after a device connects (only if not using the phone mic).
  Future<void> startListeningIfReady() async {
    if (SettingsService.hasApiKeys) {
      await startListening();
    }
  }

  /// Start continuous listening using Omi device
  Future<void> startListening() async {
    if (!_deviceManager.isConnected) {
      throw Exception(L10n.current.sessionController_noDeviceConnectedError);
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
        await releaseBackgroundServiceIfIdle();
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
        L10n.current.sessionController_micPermissionDeniedError,
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
    endAwaitingReconnect();

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
      await releaseBackgroundServiceIfIdle();
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
        L10n.current.sessionController_deepgramKeyMissingError,
      );
    }

    switch (transcriptionMode) {
      case 'sherpa':
        debugPrint(
          'Starting with LOCAL Sherpa-ONNX transcription (with diarization, '
          '${SettingsService.localSttLanguage})',
        );
        _isLoadingModel = true;
        notifyListeners();
        return SherpaStreamingTranscriber(
          language: SettingsService.localSttLanguage,
        );

      case 'whisper':
        debugPrint(
          'Starting with LOCAL offline transcription '
          '(${SettingsService.offlineSttModelId}, '
          '${SettingsService.localSttLanguage})',
        );
        _isLoadingModel = true;
        notifyListeners();
        return OfflineBatchTranscriber(
          modelId: SettingsService.offlineSttModelId,
          language: SettingsService.localSttLanguage,
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
  ///
  /// Reaps a foreground service left behind by a process that did not shut
  /// down cleanly. Nothing is recording yet at this point, so any service
  /// still up belongs to a previous process; without this a notification
  /// claiming to record would survive with no session behind it.
  ///
  /// Awaited by the bootstrap in `main.dart` before `DeviceController.init()`,
  /// because that starts the listener which can auto-start a session -- and
  /// the reap would then take that session's service down instead.
  Future<void> reapStaleBackgroundService() => releaseBackgroundServiceIfIdle();

  /// Public because `DeviceController` calls this too: the old monolith's `disconnectDevice()`
  /// used to call `_stopBackgroundRunnerWhenIdle()` after `stopListening()`,
  /// and unit 3's equivalent needs the same call.
  Future<void> releaseBackgroundServiceIfIdle() async {
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
    final l10n = L10n.current;
    final candidate = SessionNotificationText.forSession(
      usingPhoneMic: _isUsingPhoneMic,
      deviceConnected: _deviceManager.isConnected,
      conversationLength:
          startedAt == null ? Duration.zero : now.difference(startedAt),
      labels: SessionNotificationLabels(
        phoneMic: l10n.session_notification_sourcePhoneMic,
        omiConnected: l10n.session_notification_sourceOmiConnected,
        omiDisconnected: l10n.session_notification_sourceOmiDisconnected,
      ),
    );
    final next = _sessionNotificationThrottle.next(candidate, now);
    if (next == null) {
      return;
    }
    unawaited(_backgroundRunner.update(next.text));
  }

  /// Refreshes the persistent notification after a connection change: the
  /// old monolith's `_updateSessionNotification()` call at the end of the
  /// device-state listener. `DeviceController` calls this from its own
  /// listener once it has finished updating its own state.
  void onDeviceStateChanged() {
    _updateSessionNotification();
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

    await releaseBackgroundServiceIfIdle();

    notifyListeners();

    debugPrint('Stopped continuous listening');
  }

  /// What `DeviceController`'s device-state listener calls when the wearable
  /// goes out of range mid-session: the same `stopListening()` above, kept as
  /// a separate name so the call site documents *why* it is stopping.
  Future<void> stopListeningForDeviceLoss() => stopListening();

  /// Keeps the foreground service up while an interrupted session waits for
  /// the wearable to come back, for at most [reconnectGraceWindow].
  ///
  /// The `_isAutoReconnectEnabled` / saved-device guards the old monolith used to
  /// check before calling this now live in `DeviceController`, which owns
  /// auto-reconnect: it must only call this when both are true.
  void beginAwaitingReconnect() {
    _isAwaitingReconnect = true;
    _reconnectGraceTimer?.cancel();
    _reconnectGraceTimer = Timer(_reconnectGraceWindow, () {
      _reconnectGraceTimer = null;
      _isAwaitingReconnect = false;
      debugPrint('[LibreOmi/BLE] reconnect grace window expired, stopping background runner');
      // Stopping the runner takes the notification with it, so there is
      // nothing left to refresh here.
      unawaited(releaseBackgroundServiceIfIdle());
    });
    _updateSessionNotification();
  }

  /// Ends the reconnect grace window, whether it expired on its own or the
  /// device came back first. Guard-free -- unlike [beginAwaitingReconnect] --
  /// because ending it is always safe, from whichever side calls it.
  void endAwaitingReconnect() {
    _reconnectGraceTimer?.cancel();
    _reconnectGraceTimer = null;
    _isAwaitingReconnect = false;
  }

  /// The body of the old monolith's `_buttonSubscription` listener.
  /// `DeviceController` owns the subscription on `deviceManager.buttonEvents`
  /// in unit 3; a command that fails (a database write, a platform channel)
  /// must not escape into the app zone as an unhandled async error, so it is
  /// logged here instead.
  Future<void> handleButtonEvent(ButtonEvent event) async {
    await _session.handleButton(event).catchError((Object error) {
      debugPrint('Button command failed: $error');
    });
  }

  /// Imports one synced SD-card recording (LO-51). The work itself lives in
  /// [SdCardImporter]; this method only supplies what needs settings — which
  /// transcriber the user configured, and the Deepgram key and usage
  /// accounting that go with the cloud one.
  ///
  /// Before LO-51 the three `_transcribeWith*` helpers this replaces were
  /// upstream stubs that returned placeholder strings, so a synced recording
  /// could never become a conversation with a summary.
  Future<String> processLocalAudioFile(String filePath) async {
    debugPrint('Processing local audio file: $filePath');
    return _sdCardImporter.import(filePath);
  }

  /// Builds the [FileTranscriber] the current settings ask for.
  ///
  /// Both on-device modes resolve to [OfflineFileTranscriber]: the sherpa
  /// streaming model is built to decode audio as it arrives, and pushing a
  /// whole recording through it is measurably worse than one offline
  /// decode per VAD-detected utterance (docs/06-roadmap.md, LO-51).
  FileTranscriber _buildFileTranscriber() {
    if (SettingsService.useLocalTranscription) {
      return OfflineFileTranscriber(
        modelId: SettingsService.offlineSttModelId,
        language: SettingsService.localSttLanguage,
      );
    }
    if (!SettingsService.hasDeepgramKey) {
      throw Exception(L10n.current.sessionController_deepgramKeyNotConfiguredError);
    }
    return DeepgramPreRecordedTranscriber(
      apiKey: SettingsService.deepgramApiKey,
      model: SettingsService.deepgramModel,
      language: SettingsService.language,
      onUsage: SettingsService.addDeepgramUsage,
    );
  }

  Future<void> startAudioTest() async {
    if (_isTestingAudio) return;

    // Ensure listening is active
    if (!_isListening) {
      if (SettingsService.savedDeviceId.isNotEmpty) {
        await ensureSavedDeviceConnection?.call();
        // Arming autoConnect returns immediately, so wait for the link itself
        // rather than for a fixed delay. A timeout falls through to the
        // not-connected branch below.
        await _waitForConnection(const Duration(seconds: 5));
      }
      if (_deviceManager.isConnected) {
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
      await tempFile.writeAsBytes(buildWav(pcmData));
      debugPrint('Playing back audio test file: ${tempFile.path}');

      await _audioPlayer.play(DeviceFileSource(tempFile.path));
    } catch (e) {
      debugPrint('Audio playback error: $e');
    }
  }

  @override
  void dispose() {
    _reconnectGraceTimer?.cancel();
    _sessionStateSubscription?.cancel();
    _sessionSegmentsSubscription?.cancel();
    _sessionAnswerSubscription?.cancel();
    // The session's teardown closes the audio transport, which reaches back
    // into the device manager, so `DeviceController` may only dispose the
    // manager once this class's `dispose()` (and thus the session's) has
    // completed. Stored on `_teardown` (exposed as `teardown`) so
    // `DeviceController.dispose()` has a future to chain onto; still fired
    // `unawaited` here because this method itself does not wait on it.
    _teardown = _session.dispose().catchError((Object error) {
      debugPrint('Session teardown failed: $error');
    });
    unawaited(_teardown);
    unawaited(_finalizationQueue.stop());
    // Do not leave a foreground service (and its notification) behind.
    unawaited(_backgroundRunner.stop());
    _audioPlayerInstance?.dispose();
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
