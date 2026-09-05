/// App state provider for device, conversations, and recording
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../models/conversation.dart';
import '../platform/background_runner.dart';
import '../platform/background_runner_factory.dart';
import '../services/ble_service.dart';
import '../services/database_service.dart';
import '../services/deepgram_service.dart';
import '../services/openai_service.dart';
import '../services/settings_service.dart';
import '../services/sherpa_service.dart';
import '../services/whisper_service.dart';
import '../services/opus_decoder_service.dart';
import '../services/notification_ids.dart';
import '../services/notification_service.dart';
import '../services/mic_service.dart';
import '../services/sdcard_sync_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class AppProvider with ChangeNotifier, WidgetsBindingObserver {
  final BleService _bleService = BleService();
  final MicService _micService = MicService();
  SdCardSyncService? _sdCardSyncService;

  /// Keeps the process alive while a session records (docs/03 §5). A
  /// foreground service on Android, inert everywhere else. Injectable so a
  /// test can pass a `FakeBackgroundRunner`.
  final BackgroundRunner _backgroundRunner;

  /// Rate-limits rewrites of the persistent notification so a burst of
  /// transcript segments does not produce a burst of platform calls.
  final SessionNotificationThrottle _sessionNotificationThrottle =
      SessionNotificationThrottle();

  // App lifecycle state
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  DeepgramService? _deepgramService; // Transcription services
  SherpaService? _sherpaService;
  WhisperService? _whisperService;
  OpenAIService? _openaiService;
  OpusDecoderService? _opusDecoder;

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

  // Timer for connection polling
  Timer? _reconnectTimer;
  bool _isAutoReconnectEnabled = true;

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

  AppProvider({BackgroundRunner? backgroundRunner})
      : _backgroundRunner = backgroundRunner ?? createBackgroundRunner() {
    _init();
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
      _stateSubscription = _bleService.stateStream.listen((state) async {
        final previousState = _deviceState;
        _deviceState = state;

        // Auto-start listening when device connects (only if not using phone mic)
        if (state == DeviceConnectionState.connected &&
            !_isListening &&
            !_isUsingPhoneMic) {
          // Check for SD card storage support on any connection
          await _checkStorageSupport();
          _startListeningIfReady();
        }

        if (state == DeviceConnectionState.disconnected) {
          // Only stop listening if we were using Omi, not phone mic
          if (_isListening && !_isUsingPhoneMic) {
            stopListening();
          }

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
      _buttonSubscription = _bleService.buttonStream.listen(_handleButtonPress);

      // Load saved conversations, memories, and tasks
      await loadConversations();
      await loadMemories();
      await loadTasks();
    } catch (e) {
      debugPrint('AppProvider init error: $e');
    }

    // Start auto-reconnect timer
    _startReconnectTimer();
  }

  void _startReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!_isAutoReconnectEnabled) return;

      // Don't auto-reconnect when using phone mic
      if (_isUsingPhoneMic || _isListening) return;

      final savedId = SettingsService.savedDeviceId;
      if (savedId.isNotEmpty &&
          _deviceState == DeviceConnectionState.disconnected) {
        debugPrint('Auto-reconnect: Scanning for saved device...');
        scanAndConnectToSavedDevice();
      }
    });
  }

  Future<void> scanAndConnectToSavedDevice() async {
    final savedId = SettingsService.savedDeviceId;
    if (savedId.isNotEmpty) {
      debugPrint('Trying to auto-connect to saved device: $savedId');
      try {
        final success = await _bleService.connectToSavedDevice(savedId);
        if (success) {
          _batteryLevel = await _bleService.getBatteryLevel();
          _checkBatteryNotification();

          // Check for SD card storage support
          await _checkStorageSupport();

          notifyListeners();
          debugPrint('Auto-connected to saved device!');
        } else {
          debugPrint('Auto-connect failed - device may be out of range');
        }
      } catch (e) {
        debugPrint('Auto-connect error: $e');
      }
    }
  }

  // === Device Methods ===

  Stream<List<BleDevice>> scanForDevices() {
    return _bleService.scanForDevices();
  }

  Future<void> stopScan() async {
    await _bleService.stopScan();
  }

  Future<bool> connectToDevice(BleDevice device) async {
    final success = await _bleService.connect(device.device);
    if (success) {
      // Save device for auto-reconnect
      SettingsService.savedDeviceId = device.device.remoteId.str;
      SettingsService.savedDeviceName = device.name;

      _batteryLevel = await _bleService.getBatteryLevel();
      _checkBatteryNotification();

      // Check for SD card storage support
      await _checkStorageSupport();

      notifyListeners();
    }
    return success;
  }

  /// Check if the device supports SD card storage
  Future<void> _checkStorageSupport() async {
    _hasStorageSupport = await _bleService.hasStorageSupport();
    if (_hasStorageSupport) {
      _sdCardSyncService = SdCardSyncService(_bleService);
      debugPrint('SD card storage support detected');
    } else {
      _sdCardSyncService = null;
      debugPrint('No SD card storage support');
    }
    notifyListeners();
  }

  Future<void> disconnectDevice() async {
    await stopListening();
    await _bleService.disconnect();
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
      await _bleService.startAudioStream();

      // Initialize Opus decoder for Omi device (needed for local transcription and debug playback)
      _opusDecoder = OpusDecoderService();
      await _opusDecoder!.initialize();

      _audioSubscription = _bleService.audioStream.listen(_handleOmiAudioData);
    } catch (_) {
      // Setup failed, so the session never reaches listening: take the service
      // back down instead of leaving a notification for a session that is not
      // running.
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

    // Microphone-type foreground services may only be started while the app is
    // in the foreground on Android 14+ (docs/04 §3/§4), and this method is only
    // ever reached from a button tap, so the type is safe to request here.
    await _startBackgroundRunner(<BackgroundReason>{
      BackgroundReason.connectedDevice,
      BackgroundReason.microphone,
    });

    try {
      await _startTranscriptionServices(useOpusEncoding: false);

      // Start phone mic recording
      await _micService.startRecording();
      _audioSubscription = _micService.audioStream.listen(
        _handlePhoneMicAudioData,
      );
    } catch (_) {
      // Leaving the flag set would keep auto-reconnect switched off for the
      // rest of the process.
      _isUsingPhoneMic = false;
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

  /// Initialize transcription services based on selected mode
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

    // Start transcription service based on selected mode
    switch (transcriptionMode) {
      case 'sherpa':
        debugPrint(
          'Starting with LOCAL Sherpa-ONNX transcription (with diarization)',
        );
        _isLoadingModel = true;
        notifyListeners();

        _sherpaService = SherpaService(
          onTranscript: _onTranscriptReceived,
          onError: (error) => debugPrint('Sherpa error: $error'),
        );
        await _sherpaService!.initialize();
        _sherpaService!.startProcessing();

        _isLoadingModel = false;
        break;

      case 'whisper':
        debugPrint(
          'Starting with LOCAL Whisper transcription (${SettingsService.whisperModelSize})',
        );
        _isLoadingModel = true;
        notifyListeners();

        _whisperService = WhisperService(
          onTranscript: _onTranscriptReceived,
          onError: (error) => debugPrint('Whisper error: $error'),
          modelSize: SettingsService.whisperModelSize,
        );
        await _whisperService!.initialize();
        _whisperService!.startProcessing();

        _isLoadingModel = false;
        break;

      default: // 'cloud'
        debugPrint('Starting with CLOUD Deepgram transcription');
        _deepgramService = DeepgramService(
          apiKey: SettingsService.deepgramApiKey,
          language: SettingsService.language,
          onTranscript: _onTranscriptReceived,
          onError: (error) => debugPrint('Deepgram error: $error'),
          // Use linear16 for phone mic (raw PCM), opus for Omi
          encoding: useOpusEncoding ? 'opus' : 'linear16',
          sampleRate: 16000,
        );
        await _deepgramService!.connect();
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
    if (!_isListening) {
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

  void _onTranscriptReceived(List<TranscriptSegment> segments) {
    if (!_isListening) return;

    // Check for silence to handle end-of-utterance
    // ...

    // Accumulate for Hold-to-Ask
    if (_isHoldToAskActive) {
      for (var segment in segments) {
        if (segment.text.isNotEmpty) {
          _aiQueryTranscript += " ${segment.text}";
        }
      }
    }

    // Add segments to current conversation
    _liveSegments.addAll(segments);
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

  /// Save current conversation and start a new one
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

    // Generate summary and extract memories with OpenAI (in background)
    if (SettingsService.openaiApiKey.isNotEmpty) {
      _openaiService = OpenAIService(
        apiKey: SettingsService.openaiApiKey,
        model: SettingsService.openaiModel,
      );

      try {
        final result = await _openaiService!.summarizeConversation(
          conversationToSave.transcript,
        );
        conversationToSave.title = result['title'] ?? 'Untitled';
        conversationToSave.summary = result['summary'] ?? '';

        // Save extracted memories (with deduplication)
        final memories = result['memories'] as List<String>? ?? [];
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
                sourceConversationId: conversationToSave.id,
              );
              await DatabaseService.saveMemory(memory);
              debugPrint('Saved memory: ${memory.content}');
            } else {
              debugPrint('Skipped duplicate memory: $memoryContent');
            }
          }
        }
        await loadMemories();

        // Save extracted tasks (with deduplication)
        final tasks = result['tasks'] as List? ?? [];
        for (final taskData in tasks) {
          if (taskData is Map && taskData['title'] != null) {
            final title = taskData['title'].toString().trim();
            if (title.isNotEmpty) {
              final hasSimilar = await DatabaseService.hasSimilarTask(title);
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
                  title: title,
                  description: taskData['description']?.toString(),
                  dueDate: dueDate,
                  createdAt: DateTime.now(),
                  sourceConversationId: conversationToSave.id,
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
                debugPrint('Skipped duplicate task: $title');
              }
            }
          }
        }
        await loadTasks();
      } catch (e) {
        debugPrint('Failed to summarize: $e');
        conversationToSave.title =
            'Conversation ${conversationToSave.createdAt.toString().substring(0, 16)}';
      }
    } else {
      conversationToSave.title =
          'Conversation ${conversationToSave.createdAt.toString().substring(0, 16)}';
    }

    // Save to database
    await DatabaseService.saveConversation(conversationToSave);
    await loadConversations();

    debugPrint('Saved conversation: ${conversationToSave.title}');
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

    // Stop audio source
    if (_isUsingPhoneMic) {
      await _micService.stopRecording();
    } else {
      await _bleService.stopAudioStream();
    }

    // Clean up transcription services
    await _deepgramService?.disconnect();
    _deepgramService = null;
    _sherpaService?.stopProcessing();
    _sherpaService?.dispose();
    _sherpaService = null;
    _whisperService?.stopProcessing();
    _whisperService?.dispose();
    _whisperService = null;

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
    _openaiService = OpenAIService(
      apiKey: SettingsService.openaiApiKey,
      model: SettingsService.openaiModel,
    );

    try {
      final response = await _openaiService!.chat(
        userMessage: message,
        conversationContext: context,
      );

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
      final decoder = OpusDecoderService();
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

      // Try to summarize with OpenAI
      if (SettingsService.openaiApiKey.isNotEmpty) {
        _openaiService = OpenAIService(
          apiKey: SettingsService.openaiApiKey,
          model: SettingsService.openaiModel,
        );

        try {
          final result = await _openaiService!.summarizeConversation(
            transcript,
          );
          conversation.title = result['title'] ?? 'SD Card Recording';
          conversation.summary = result['summary'] ?? '';

          // Extract memories
          final memories = result['memories'] as List<String>? ?? [];
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
              }
            }
          }
          await loadMemories();

          // Extract tasks
          final tasks = result['tasks'] as List? ?? [];
          for (final taskData in tasks) {
            if (taskData is Map && taskData['title'] != null) {
              final title = taskData['title'].toString().trim();
              if (title.isNotEmpty) {
                final hasSimilar = await DatabaseService.hasSimilarTask(title);
                if (!hasSimilar) {
                  DateTime? dueDate;
                  if (taskData['due_date'] != null) {
                    try {
                      dueDate = DateTime.parse(taskData['due_date'].toString());
                    } catch (e) {
                      debugPrint('Failed to parse due date');
                    }
                  }
                  final task = Task(
                    id: const Uuid().v4(),
                    title: title,
                    description: taskData['description']?.toString(),
                    dueDate: dueDate,
                    createdAt: DateTime.now(),
                    sourceConversationId: conversation.id,
                  );
                  await DatabaseService.saveTask(task);
                }
              }
            }
          }
          await loadTasks();
        } catch (e) {
          debugPrint('Failed to summarize SD card recording: $e');
        }
      }

      await DatabaseService.saveConversation(conversation);
      await loadConversations();

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
        await Future.delayed(const Duration(seconds: 1)); // Wait for connection
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

  void _handleButtonPress(List<int> data) async {
    if (data.isEmpty) return;
    debugPrint("Raw Button Data (length ${data.length}): $data");

    if (data.length < 4) {
      debugPrint("Button Data too short, ignoring.");
      return;
    }

    // Debounce - prevent multiple button events from being processed too quickly
    if (_isProcessingButtonEvent) {
      debugPrint("Button event blocked - still processing previous event");
      return;
    }
    _isProcessingButtonEvent = true;

    // Parse button state exactly as Omi reference does
    // Little Endian Uint32: [2, 0, 0, 0] -> 2
    final buttonState = ByteData.view(
      Uint8List.fromList(data.sublist(0, 4).reversed.toList()).buffer,
    ).getUint32(0);
    debugPrint("Button State Parsed: $buttonState");

    // STATE 2: Double Tap (End/Save)
    if (buttonState == 2) {
      debugPrint("Double Tap Detected (State 2): Saving Conversation");
      HapticFeedback.heavyImpact(); // Confirm action (Phone)
      _bleService.triggerHaptic(3); // Confirm action (Omi - Long 500ms)
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
    if (buttonState == 1) {
      if (_isHoldToAskActive) {
        // Second click - end AI query and process
        debugPrint("Short Press (State 1): Ending AI Query");
        HapticFeedback.lightImpact(); // Confirm end (Phone)
        _bleService.triggerHaptic(1); // Confirm end (Omi - Short 20ms)

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
        _bleService.triggerHaptic(2); // Confirm start (Omi - Medium 50ms)
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
    if (buttonState == 4) {
      debugPrint("Short Press End (State 4) - Ignored (using toggle)");
      _isProcessingButtonEvent = false;
      return;
    }

    // STATE 3: Long Press Start (Disabled - now turns off device in new firmware)
    if (buttonState == 3) {
      debugPrint("Long Press Detected (State 3) - Disabled for AI Query");
      _isProcessingButtonEvent = false;
      return;
    }

    // STATE 5: Long Press End
    if (buttonState == 5) {
      debugPrint("Long Press Ended (State 5) - Ignoring (long press disabled)");
      _isProcessingButtonEvent = false;
      return;
    }
  }

  // Audio Data Handler for Omi device (Opus encoded)
  void _handleOmiAudioData(Uint8List audioData) {
    // Omi device audio has a 3-byte header that needs to be trimmed
    if (audioData.length <= 3) return;
    final trimmedAudio = audioData.sublist(3);

    // BUFFER for Voice Command if active
    if (_isCollectingVoiceCommand) {
      _voiceCommandBuffer.addAll(trimmedAudio);
    }

    // Decode Opus to PCM (needed for Sherpa and Debug Playback)
    final pcmData = _opusDecoder?.decode(trimmedAudio);

    if (_isTestingAudio) {
      if (pcmData != null) _testAudioBuffer.addAll(pcmData);
    } else {
      // PAUSE: If AI is processing a query, ignore incoming audio for the main conversation
      if (_isAiQueryProcessing) return;

      // Route to active transcription service
      final transcriptionMode = SettingsService.transcriptionMode;
      switch (transcriptionMode) {
        case 'sherpa':
          if (pcmData != null) _sherpaService?.addAudio(pcmData);
          break;
        case 'whisper':
          if (pcmData != null) _whisperService?.addAudio(pcmData);
          break;
        default: // cloud
          // Deepgram expects Opus when encoding='opus'
          if (_deepgramService != null) {
            _deepgramService?.sendAudio(trimmedAudio);
          }
      }
    }
  }

  // Audio Data Handler for phone microphone (raw PCM16)
  void _handlePhoneMicAudioData(Uint8List audioData) {
    if (audioData.isEmpty) return;

    // Create a properly aligned copy of the audio data
    // This is needed because Int16List.view requires proper buffer alignment
    final alignedData = Uint8List.fromList(audioData);

    // Route to active transcription service
    final transcriptionMode = SettingsService.transcriptionMode;
    switch (transcriptionMode) {
      case 'sherpa':
        _sherpaService?.addAudio(alignedData);
        break;
      case 'whisper':
        _whisperService?.addAudio(alignedData);
        break;
      default: // cloud
        // Deepgram expects linear16 when encoding='linear16'
        if (_deepgramService != null) {
          _deepgramService?.sendAudio(alignedData);
        }
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

    _openaiService = OpenAIService(
      apiKey: SettingsService.openaiApiKey,
      model: SettingsService.openaiModel,
    );

    try {
      // Chat
      final response = await _openaiService!.chat(
        userMessage: query,
        conversationContext:
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
    _stateSubscription?.cancel();
    _audioSubscription?.cancel();
    _buttonSubscription?.cancel();
    _silenceTimer?.cancel();
    _bleService.dispose();
    _deepgramService?.disconnect();
    // Do not leave a foreground service (and its notification) behind.
    unawaited(_backgroundRunner.stop());
    _audioPlayer.dispose();
    super.dispose();
  }
}
