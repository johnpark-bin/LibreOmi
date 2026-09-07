// The LO-34 unit 2 acceptance test: `SessionController` on its own, with a
// scripted `RecordingSession` and a `DeviceManager` over a fake host, so
// nothing here touches BLE, a plugin channel or real time.
//
// Follows the style of `test/session/recording_session_test.dart`: local
// `_Fake...` classes, no mocking package.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:libreomi/audio/audio_source.dart';
import 'package:libreomi/controllers/chat_controller.dart';
import 'package:libreomi/controllers/library_controller.dart';
import 'package:libreomi/controllers/session_controller.dart';
import 'package:libreomi/core/clock.dart';
import 'package:libreomi/core/ids.dart';
import 'package:libreomi/device/device_manager.dart';
import 'package:libreomi/device/omi_gatt.dart';
import 'package:libreomi/intelligence/llm_client.dart';
import 'package:libreomi/core/models.dart';
import 'package:libreomi/platform/background_reasons.dart';
import 'package:libreomi/platform/fake_background_runner.dart';
import 'package:libreomi/services/finalization_queue.dart';
import 'package:libreomi/services/secret_store.dart';
import 'package:libreomi/services/settings_service.dart';
import 'package:libreomi/session/conversation_finalizer.dart';
import 'package:libreomi/session/recording_session.dart';
import 'package:libreomi/transcription/transcriber.dart';

import '../data/test_db.dart';
import '../device/device_manager_test.dart' show FakeOmiDeviceHost, MapSavedDeviceStore;

/// A [StreamingTranscriber] the test controls directly: it never emits
/// anything on its own, so a session started against it just sits in
/// `listening` until the test says otherwise.
class _FakeTranscriber implements StreamingTranscriber {
  @override
  final AudioEncoding acceptedEncoding = AudioEncoding.opus;

  final _segments = StreamController<TranscriptSegment>.broadcast();
  final _errors = StreamController<String>.broadcast();

  bool started = false;
  bool stopped = false;

  @override
  Stream<TranscriptSegment> get segments => _segments.stream;

  @override
  Stream<String> get errors => _errors.stream;

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  void feed(AudioChunk chunk) {}

  @override
  Future<void> stop() async {
    stopped = true;
    await _segments.close();
    await _errors.close();
  }

  Future<void> emit(String text) async {
    _segments.add(
      TranscriptSegment(text: text, speakerId: 0, startTime: 0, endTime: 1),
    );
    await Future<void>.delayed(Duration.zero);
  }
}

class _FakeLlmClient implements LlmClient {
  @override
  Future<String> chat(String user, {String? context}) async => 'answer';

  @override
  Future<ConversationInsights> summarize(String transcript, {DateTime? now}) =>
      throw UnimplementedError();
}

class _CountingIds implements IdGenerator {
  int _next = 0;

  @override
  String newId() => 'id-${_next++}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useFfiDatabaseFactory();

  late FakeOmiDeviceHost host;
  late MapSavedDeviceStore saved;
  late DeviceManager deviceManager;
  late FakeBackgroundRunner runner;
  late LibraryController library;
  late ChatController chat;
  late _FakeTranscriber transcriber;
  late int transcriberCalls;
  late Object? transcriberFailure;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SettingsService.init(secretStore: InMemorySecretStore());

    host = FakeOmiDeviceHost();
    saved = MapSavedDeviceStore();
    deviceManager = DeviceManager(host: host, savedDevices: saved);
    runner = FakeBackgroundRunner();

    final libraryDb = await openTestDb();
    library = LibraryController(database: () async => libraryDb);
    final chatDb = await openTestDb();
    chat = ChatController(library: library, database: () async => chatDb);

    transcriber = _FakeTranscriber();
    transcriberCalls = 0;
    transcriberFailure = null;
  });

  /// Connects [deviceManager] to a fake device, as a real connect flow would.
  Future<void> connectDevice() async {
    await deviceManager.connect(
      const DiscoveredDevice(id: 'aa:bb', name: 'Omi', rssi: -50),
    );
  }

  /// Builds a [RecordingSession] over [transcriber] (or a factory that
  /// throws [transcriberFailure]), with the finalizer swallowing everything
  /// -- these tests only care about the state machine's effect on
  /// `SessionController`, not on persistence.
  RecordingSession buildSession({Future<void> Function()? onStartRequested}) {
    return RecordingSession(
      transcriberFactory: ({required bool useOpusEncoding}) async {
        transcriberCalls++;
        final failure = transcriberFailure;
        if (failure != null) throw failure;
        return transcriber;
      },
      finalizer: ConversationFinalizer(
        database: () async => throw UnimplementedError('not used by these tests'),
        enqueue: (conversation) async {},
        scheduleReminder: ({required id, required title, required dueDate}) async {},
        ids: _CountingIds(),
        clock: FixedClock(DateTime(2026, 9, 6, 10)),
      ),
      llmClientFactory: () => _FakeLlmClient(),
      device: () => deviceManager.current,
      // No native Opus library under `flutter test`.
      opusDecoderFactory: () async => null,
      ids: _CountingIds(),
      clock: FixedClock(DateTime(2026, 9, 6, 10)),
      // The hold-to-ask trailing wait must not cost the test 1.5 real seconds.
      delay: (_) async {},
      onStartRequested: onStartRequested,
    );
  }

  SessionController build({RecordingSession? session, Duration? graceWindow}) {
    return SessionController(
      deviceManager: deviceManager,
      library: library,
      chat: chat,
      backgroundRunner: runner,
      finalizationQueue: FinalizationQueue(
        llmClient: () => _FakeLlmClient(),
        applier: (id, insights) async {},
      ),
      session: session ?? buildSession(),
      reconnectGraceWindowOverride: graceWindow,
    );
  }

  tearDown(() async {
    await host.close();
  });

  test('startListening throws when the device is not connected', () async {
    final controller = build();
    addTearDown(controller.dispose);

    await expectLater(controller.startListening(), throwsException);
    expect(controller.isListening, isFalse);
  });

  test(
    'a successful start brings the background runner up before the session, '
    'with exactly {connectedDevice}',
    () async {
      await connectDevice();
      final controller = build();
      addTearDown(controller.dispose);

      await controller.startListening();

      expect(runner.startCalls, [
        {BackgroundReason.connectedDevice},
      ]);
      expect(transcriber.started, isTrue);
      expect(controller.isListening, isTrue);
    },
  );

  test('a session start that throws rolls the runner back down and rethrows', () async {
    await connectDevice();
    transcriberFailure = StateError('no Deepgram key');
    final controller = build();
    addTearDown(controller.dispose);

    await expectLater(controller.startListening(), throwsStateError);

    expect(runner.startCalls, hasLength(1));
    expect(runner.stopCount, 1);
    expect(controller.isListening, isFalse);
  });

  test('stopListening stops the session and takes the runner down; a second call is a no-op', () async {
    await connectDevice();
    final controller = build();
    addTearDown(controller.dispose);
    await controller.startListening();

    await controller.stopListening();
    expect(controller.isListening, isFalse);
    expect(runner.stopCount, 1);

    await controller.stopListening();
    expect(runner.stopCount, 1, reason: 'a second stop while already stopped is a no-op');
  });

  test('a second startListening while the first is still in flight does not start a second session', () async {
    await connectDevice();
    final gate = Completer<void>();
    // Blocks the transcriber factory until the test lets it through, so the
    // first `startListening()` is still in flight when the second is fired.
    final controller = build(
      session: RecordingSession(
        transcriberFactory: ({required bool useOpusEncoding}) async {
          transcriberCalls++;
          await gate.future;
          return transcriber;
        },
        finalizer: ConversationFinalizer(
          database: () async => throw UnimplementedError('not used by these tests'),
          enqueue: (conversation) async {},
          scheduleReminder: ({required id, required title, required dueDate}) async {},
        ),
        llmClientFactory: () => _FakeLlmClient(),
        device: () => deviceManager.current,
        opusDecoderFactory: () async => null,
      ),
    );
    addTearDown(controller.dispose);

    final first = controller.startListening();
    final second = controller.startListening();

    gate.complete();
    await first;
    await second;

    expect(transcriberCalls, 1);
    expect(controller.isListening, isTrue);
  });

  test(
    'beginAwaitingReconnect keeps the runner up across stopListening, and it '
    'goes down when the grace window expires',
    () async {
      await connectDevice();
      final controller = build(graceWindow: const Duration(milliseconds: 30));
      addTearDown(controller.dispose);
      await controller.startListening();

      controller.beginAwaitingReconnect();
      await controller.stopListening();
      expect(runner.stopCount, 0, reason: 'awaiting reconnect keeps the service up');

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(runner.stopCount, 1, reason: 'the grace window expired');
    },
  );

  test('a live-segment update from the session refreshes liveSegments and notifies listeners', () async {
    await connectDevice();
    final controller = build();
    addTearDown(controller.dispose);
    await controller.startListening();

    var notified = 0;
    controller.addListener(() => notified++);

    await transcriber.emit('we should book the flights tonight');

    expect(controller.liveSegments, hasLength(1));
    expect(controller.liveSegments.single.text, 'we should book the flights tonight');
    expect(notified, greaterThan(0));
  });

  test('an AiAnswer from the session reaches ChatController.recordAiAnswer', () async {
    await connectDevice();
    final session = buildSession();
    final controller = build(session: session);
    addTearDown(controller.dispose);
    await controller.startListening();

    // Single tap opens the hold-to-ask query; the question is transcribed
    // while it is open; a second single tap closes it and triggers the
    // fake LLM's answer.
    await session.handleButton(ButtonEvent.singleTap);
    expect(session.isHoldToAskActive, isTrue);
    await transcriber.emit('what is the capital of france');
    await session.handleButton(ButtonEvent.singleTap);
    // Let the answer subscription and its persistence writes settle.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(chat.chatMessages, isNotEmpty);
    expect(chat.chatMessages.any((m) => !m.isUser && m.text == 'answer'), isTrue);
  });

  test('startAudioTest installs session.pcmTap and clears it once the delay elapses', () async {
    await connectDevice();
    final session = buildSession();
    final controller = build(session: session);
    addTearDown(controller.dispose);
    await controller.startListening();

    expect(session.pcmTap, isNull);
    await controller.startAudioTest();
    expect(controller.isTestingAudio, isTrue);
    expect(session.pcmTap, isNotNull);

    await Future<void>.delayed(const Duration(seconds: 3, milliseconds: 100));
    expect(controller.isTestingAudio, isFalse);
    expect(session.pcmTap, isNull);
  });
}
