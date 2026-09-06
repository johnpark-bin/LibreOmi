// The LO-33 acceptance test: the whole session state machine of
// `docs/03-architecture.md` §4, driven with no hardware, no network and no
// real time.
//
// Every source of non-determinism is injected: a `FakeOmiDevice` replaying a
// recorded BLE session for audio and haptics, a fake transcriber that lets the
// test decide exactly when a segment appears, a fake timer factory for the
// silence timeout, a `FixedClock`, a counting id generator, and a delay
// function that does not wait.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:libreomi/audio/audio_source.dart';
import 'package:libreomi/audio/omi_audio_source.dart';
import 'package:libreomi/core/clock.dart';
import 'package:libreomi/core/ids.dart';
import 'package:libreomi/data/conversation_repo.dart';
import 'package:libreomi/device/fake_omi_device.dart';
import 'package:libreomi/device/omi_device.dart';
import 'package:libreomi/device/omi_gatt.dart';
import 'package:libreomi/intelligence/llm_client.dart';
import 'package:libreomi/models/conversation.dart';
import 'package:libreomi/session/conversation_finalizer.dart';
import 'package:libreomi/session/recording_session.dart';
import 'package:libreomi/session/session_state.dart';
import 'package:libreomi/session/silence_detector.dart';
import 'package:libreomi/transcription/transcriber.dart';

import '../data/test_db.dart';

/// A [Timer] stand-in the test fires by hand.
class _FakeTimer implements Timer {
  _FakeTimer(this.callback);

  final void Function() callback;
  bool _cancelled = false;

  @override
  bool get isActive => !_cancelled;

  @override
  int get tick => 0;

  @override
  void cancel() {
    _cancelled = true;
  }

  /// Fires the callback as a real timer would, unless it was cancelled.
  void fire() {
    if (_cancelled) return;
    callback();
  }
}

/// Hands out [_FakeTimer]s and remembers the most recent one, which is the
/// only one the silence detector ever has armed.
class _FakeTimers {
  _FakeTimer? latest;

  Timer create(Duration duration, void Function() callback) {
    final timer = _FakeTimer(callback);
    latest = timer;
    return timer;
  }

  /// Fires the pending silence timeout.
  void fireSilence() => latest?.fire();
}

/// A [StreamingTranscriber] the test feeds segments into directly.
class _FakeTranscriber implements StreamingTranscriber {
  _FakeTranscriber({this.acceptedEncoding = AudioEncoding.opus});

  @override
  final AudioEncoding acceptedEncoding;

  final _segments = StreamController<TranscriptSegment>.broadcast();
  final _errors = StreamController<String>.broadcast();

  /// Chunks handed to [feed], in order.
  final List<AudioChunk> fed = [];

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
  void feed(AudioChunk chunk) => fed.add(chunk);

  @override
  Future<void> stop() async {
    stopped = true;
    await _segments.close();
    await _errors.close();
  }

  /// Emits [text] as a finished segment and lets the session process it.
  Future<void> emit(String text) async {
    _segments.add(
      TranscriptSegment(text: text, speakerId: 0, startTime: 0, endTime: 1),
    );
    await Future<void>.delayed(Duration.zero);
  }
}

/// An [AudioSource] the test pushes chunks into.
class _FakeAudioSource implements AudioSource {
  final _controller = StreamController<AudioChunk>.broadcast();
  bool stopped = false;

  @override
  Stream<AudioChunk> start() => _controller.stream;

  @override
  Future<void> stop() async {
    stopped = true;
    await _controller.close();
  }

  Future<void> push(List<int> bytes, {AudioEncoding encoding = AudioEncoding.opus}) async {
    _controller.add(
      AudioChunk(
        bytes: Uint8List.fromList(bytes),
        encoding: encoding,
        at: DateTime(2026, 9, 6),
      ),
    );
    await Future<void>.delayed(Duration.zero);
  }
}

class _FakeLlmClient implements LlmClient {
  _FakeLlmClient({this.failure});

  /// The answer every [chat] call returns.
  static const String answer = 'Paris.';
  final Object? failure;

  final List<String> questions = [];

  /// Runs inside [chat], i.e. while the session is in `answering`. Lets a
  /// test observe what the session does with audio that arrives mid-answer.
  Future<void> Function()? onChat;

  @override
  Future<String> chat(String user, {String? context}) async {
    questions.add(user);
    await onChat?.call();
    final failure = this.failure;
    if (failure != null) throw failure;
    return answer;
  }

  @override
  Future<ConversationInsights> summarize(String transcript, {DateTime? now}) =>
      throw UnimplementedError();
}

/// Records everything the session sends to the phone.
class _RecordingFeedback implements SessionFeedback {
  final List<HapticLevel> haptics = [];
  final List<String> notifications = [];
  final List<String> aiProgress = [];
  final List<String> aiAnswers = [];

  @override
  Future<void> haptic(HapticLevel level) async => haptics.add(level);

  @override
  Future<void> notify(String title, String body) async =>
      notifications.add('$title|$body');

  @override
  Future<void> notifyAiProgress(String message) async => aiProgress.add(message);

  @override
  Future<void> notifyAiAnswer(String message) async => aiAnswers.add(message);
}

class _CountingIds implements IdGenerator {
  int _next = 0;

  @override
  String newId() => 'id-${_next++}';
}

void main() {
  useFfiDatabaseFactory();

  late Database db;
  late _FakeTimers timers;
  late _FakeTranscriber transcriber;
  late _FakeAudioSource source;
  late _RecordingFeedback feedback;
  late _FakeLlmClient llm;
  late FakeOmiDevice device;
  late List<Conversation> enqueued;
  late RecordingSession session;

  /// Builds a session over the fakes above. [llmFailure] makes the hold-to-ask
  /// answer blow up; [transcriberEncoding] picks whether chunks pass straight
  /// through or would need a decode.
  /// Lets the microtask queue drain far enough for a `unawaited` finalization
  /// (open the database, persist, enqueue) to finish.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  Future<RecordingSession> buildSession({
    Object? llmFailure,
    AudioEncoding transcriberEncoding = AudioEncoding.opus,
    Future<void> Function()? onStartRequested,
    SessionDelay? delay,
  }) async {
    db = await openTestDb();
    timers = _FakeTimers();
    transcriber = _FakeTranscriber(acceptedEncoding: transcriberEncoding);
    source = _FakeAudioSource();
    feedback = _RecordingFeedback();
    llm = _FakeLlmClient(failure: llmFailure);
    device = FakeOmiDevice(const []);
    enqueued = [];

    final finalizer = ConversationFinalizer(
      database: () async => db,
      enqueue: (conversation) async => enqueued.add(conversation),
      scheduleReminder: ({required id, required title, required dueDate}) async {},
      ids: _CountingIds(),
      clock: FixedClock(DateTime(2026, 9, 6, 10)),
    );

    return RecordingSession(
      transcriberFactory: ({required bool useOpusEncoding}) async => transcriber,
      finalizer: finalizer,
      llmClientFactory: () => llm,
      device: () => device,
      // No native Opus library under `flutter test`; the fake transcriber
      // accepts what the fake source produces, so nothing needs decoding.
      opusDecoderFactory: () async => null,
      silenceDetector: SilenceDetector(
        timeout: const Duration(minutes: 2),
        clock: FixedClock(DateTime(2026, 9, 6, 10)),
        createTimer: timers.create,
      ),
      feedback: feedback,
      ids: _CountingIds(),
      clock: FixedClock(DateTime(2026, 9, 6, 10)),
      // The trailing-audio wait must not cost the test 1.5 real seconds.
      delay: delay ?? (_) async {},
      onStartRequested: onStartRequested,
    );
  }

  Future<void> startListening() =>
      session.start(source: source, useOpusEncoding: true);

  tearDown(() async {
    await session.dispose();
  });

  group('start and stop', () {
    test('start moves idle -> listening and opens a conversation', () async {
      session = await buildSession();
      final states = <SessionState>[];
      session.states.listen(states.add);

      expect(session.state, SessionState.idle);
      await startListening();
      await Future<void>.delayed(Duration.zero);

      expect(session.state, SessionState.listening);
      expect(states, [SessionState.listening]);
      expect(transcriber.started, isTrue);
      expect(session.currentConversation, isNotNull);
      expect(session.currentSegments, isEmpty);
    });

    test('the transport is opened after the transcriber and closed on stop', () async {
      session = await buildSession();
      final order = <String>[];

      await session.start(
        source: source,
        useOpusEncoding: true,
        openTransport: () async => order.add('open'),
        closeTransport: () async => order.add('close'),
      );
      expect(transcriber.started, isTrue);
      expect(order, ['open']);

      await session.stop();
      expect(order, ['open', 'close']);
      expect(transcriber.stopped, isTrue);
      expect(source.stopped, isTrue);
      expect(session.state, SessionState.idle);
    });

    test('a transport that fails to open leaves the session idle and releases the source', () async {
      session = await buildSession();
      var opened = false;

      await expectLater(
        session.start(
          source: source,
          useOpusEncoding: true,
          openTransport: () async {
            opened = true;
            throw StateError('no audio characteristic');
          },
          closeTransport: () async {},
        ),
        throwsStateError,
      );

      expect(opened, isTrue);
      expect(session.state, SessionState.idle);
      // The source is released even though the transport never came up.
      expect(source.stopped, isTrue);
      expect(transcriber.stopped, isTrue);
    });

    test('a transcriber that fails to build never opens the transport', () async {
      session = await buildSession();
      var opened = false;
      var closed = false;

      final failing = RecordingSession(
        transcriberFactory: ({required bool useOpusEncoding}) async =>
            throw StateError('no Deepgram key'),
        finalizer: ConversationFinalizer(
          database: () async => db,
          enqueue: (conversation) async => enqueued.add(conversation),
          scheduleReminder: ({required id, required title, required dueDate}) async {},
        ),
        llmClientFactory: () => llm,
        opusDecoderFactory: () async => null,
      );
      addTearDown(failing.dispose);

      await expectLater(
        failing.start(
          source: source,
          useOpusEncoding: true,
          openTransport: () async => opened = true,
          closeTransport: () async => closed = true,
        ),
        throwsStateError,
      );

      expect(opened, isFalse, reason: 'the transport is only opened once the transcriber is up');
      expect(closed, isFalse, reason: 'a transport that never opened is never closed');
      expect(failing.state, SessionState.idle);
      expect(source.stopped, isTrue);
    });
  });

  group('a single tap on an idle session', () {
    test('asks the caller to start one, then opens the query', () async {
      var startCalls = 0;
      session = await buildSession(
        onStartRequested: () async {
          startCalls++;
          await startListening();
        },
      );

      await session.handleButton(ButtonEvent.singleTap);

      expect(startCalls, 1);
      expect(session.state, SessionState.holdToAsk);
    });

    test('a start that fails leaves the session idle and still startable', () async {
      var attempts = 0;
      session = await buildSession(
        onStartRequested: () async {
          attempts++;
          // What `AppProvider.startListening` throws in cloud mode with no key.
          throw Exception('Please configure Deepgram API key in settings');
        },
      );

      await session.handleButton(ButtonEvent.singleTap);

      expect(attempts, 1);
      // Not holdToAsk: that state would strand the session for good, because
      // start() refuses to run once the state is no longer idle.
      expect(session.state, SessionState.idle);

      // The session is still usable: a normal start works afterwards.
      await startListening();
      expect(session.state, SessionState.listening);
    });
  });

  group('silence timeout', () {
    test('finalizes the conversation and comes straight back to listening', () async {
      session = await buildSession();
      await startListening();
      final states = <SessionState>[];
      session.states.listen(states.add);

      await transcriber.emit('we should book the flights tonight');
      final firstConversationId = session.currentConversation!.id;
      expect(session.currentSegments, hasLength(1));

      timers.fireSilence();
      await settle();

      expect(states, [SessionState.finalizing, SessionState.listening]);
      expect(session.state, SessionState.listening);
      // A new, empty conversation is open immediately so listening never stops.
      expect(session.currentConversation!.id, isNot(firstConversationId));
      expect(session.currentSegments, isEmpty);

      // The finished conversation went through the finalizer: persisted with
      // its segments and queued for summarisation.
      expect(enqueued.single.id, firstConversationId);
      final stored = await ConversationRepo(db).byId(firstConversationId);
      expect(stored, isNotNull);
      expect(stored!.segments.single.text, 'we should book the flights tonight');
      expect(stored.title, startsWith('Conversation '));
    });

    test('a timeout with nothing recorded finalizes nothing', () async {
      session = await buildSession();
      await startListening();

      timers.fireSilence();
      await settle();

      expect(enqueued, isEmpty);
      expect(session.state, SessionState.listening);
    });

    test('every segment re-arms the timeout', () async {
      session = await buildSession();
      await startListening();

      await transcriber.emit('first');
      final firstTimer = timers.latest;
      await transcriber.emit('second');

      expect(firstTimer!.isActive, isFalse, reason: 'the previous timeout is cancelled');
      expect(timers.latest, isNot(firstTimer));
      expect(session.currentSegments, hasLength(2));
    });
  });

  group('hold-to-ask', () {
    test('two single taps run listening -> holdToAsk -> answering -> listening', () async {
      session = await buildSession();
      await startListening();
      final states = <SessionState>[];
      session.states.listen(states.add);
      final answers = <AiAnswer>[];
      session.aiAnswers.listen(answers.add);

      await session.handleButton(ButtonEvent.singleTap);
      expect(session.state, SessionState.holdToAsk);
      expect(session.isHoldToAskActive, isTrue);

      // The question is transcribed into the conversation as well as into the
      // query buffer: it was said out loud in the room.
      await transcriber.emit('what is the capital of France');
      expect(session.currentSegments, hasLength(1));

      await session.handleButton(ButtonEvent.singleTap);
      await Future<void>.delayed(Duration.zero);

      expect(
        states,
        [SessionState.holdToAsk, SessionState.answering, SessionState.listening],
      );
      expect(session.state, SessionState.listening);
      expect(llm.questions, ['what is the capital of France']);
      expect(answers.single.question, 'what is the capital of France');
      expect(answers.single.answer, 'Paris.');
      // Delivered as a notification too, exactly as before LO-33.
      expect(feedback.aiAnswers, ['Paris.']);
      expect(feedback.aiProgress, ['Processing: what is the capital of France']);
    });

    test('both taps buzz the phone and the wearable', () async {
      session = await buildSession();
      await startListening();

      await session.handleButton(ButtonEvent.singleTap);
      await session.handleButton(ButtonEvent.singleTap);
      await Future<void>.delayed(Duration.zero);

      expect(device.haptics, [HapticLevel.medium, HapticLevel.short]);
      expect(feedback.haptics, [HapticLevel.medium, HapticLevel.short]);
    });

    test('no audio reaches the transcriber while answering', () async {
      session = await buildSession();
      await startListening();

      await source.push([1, 2, 3]);
      expect(transcriber.fed, hasLength(1));

      // Start and finish a query, pushing a chunk while the state is
      // `answering` from inside the LLM call itself.
      llm.onChat = () async => source.push([9, 9, 9]);
      await session.handleButton(ButtonEvent.singleTap);
      await session.handleButton(ButtonEvent.singleTap);
      await Future<void>.delayed(Duration.zero);

      expect(transcriber.fed, hasLength(1), reason: 'the mid-answer chunk was dropped');

      await source.push([4, 5, 6]);
      expect(transcriber.fed, hasLength(2), reason: 'audio flows again once listening resumes');
    });

    test('an empty question is refused without calling the model', () async {
      session = await buildSession();
      await startListening();

      await session.handleButton(ButtonEvent.singleTap);
      await session.handleButton(ButtonEvent.singleTap);
      await Future<void>.delayed(Duration.zero);

      expect(llm.questions, isEmpty);
      expect(feedback.aiAnswers, ["I couldn't hear that. Please try again."]);
      expect(session.state, SessionState.listening);
    });

    test('a failing model returns the session to listening', () async {
      session = await buildSession(llmFailure: const LlmRetryableException('offline'));
      await startListening();

      await session.handleButton(ButtonEvent.singleTap);
      await transcriber.emit('anything');
      await session.handleButton(ButtonEvent.singleTap);
      await Future<void>.delayed(Duration.zero);

      expect(feedback.aiAnswers, ['Failed to process question. Please try again.']);
      expect(session.state, SessionState.listening);
    });
  });

  group('double tap', () {
    test('saves the conversation immediately', () async {
      session = await buildSession();
      await startListening();
      await transcriber.emit('remember to water the plants');
      final conversationId = session.currentConversation!.id;

      await session.handleButton(ButtonEvent.doubleTap);
      await Future<void>.delayed(Duration.zero);

      expect(feedback.notifications, ['Double Tap|Saving conversation...']);
      expect(device.haptics, [HapticLevel.long]);
      expect(enqueued.single.id, conversationId);
      expect(session.currentConversation!.id, isNot(conversationId));
      expect(session.state, SessionState.listening);
    });

    test('says so when there is nothing to save', () async {
      session = await buildSession();
      await startListening();

      await session.handleButton(ButtonEvent.doubleTap);
      await Future<void>.delayed(Duration.zero);

      expect(feedback.notifications, ['Double Tap|No active conversation to save.']);
      expect(enqueued, isEmpty);
    });

    test('during a hold-to-ask query it saves without abandoning the query', () async {
      session = await buildSession();
      await startListening();

      await session.handleButton(ButtonEvent.singleTap);
      await transcriber.emit('what time is it');
      await session.handleButton(ButtonEvent.doubleTap);
      await Future<void>.delayed(Duration.zero);

      expect(enqueued, hasLength(1));
      expect(session.state, SessionState.holdToAsk);
    });
  });

  group('button debounce', () {
    test('an event arriving while a command runs is dropped', () async {
      session = await buildSession();
      await startListening();
      await transcriber.emit('something');

      // Do not await: the double tap is still running when the next event
      // arrives, which is exactly the bouncing-button case.
      final first = session.handleButton(ButtonEvent.doubleTap);
      await session.handleButton(ButtonEvent.doubleTap);
      await first;
      await Future<void>.delayed(Duration.zero);

      expect(feedback.notifications, hasLength(1));
      expect(enqueued, hasLength(1));
    });

    test('ignored gestures do not become commands', () async {
      session = await buildSession();
      await startListening();

      await session.handleButton(ButtonEvent.longPressStart);
      await session.handleButton(ButtonEvent.longPressEnd);
      await session.handleButton(ButtonEvent.singleTapRelease);

      expect(session.state, SessionState.listening);
      expect(feedback.notifications, isEmpty);
      expect(device.haptics, isEmpty);
    });
  });

  group('stop', () {
    test('a disconnect mid-session saves the pending conversation', () async {
      session = await buildSession();
      await startListening();
      await transcriber.emit('half a sentence before the wearable went out of range');
      final conversationId = session.currentConversation!.id;

      // What `AppProvider` does when the device-state listener sees a
      // disconnect while listening.
      await session.stop();

      expect(session.state, SessionState.idle);
      expect(session.currentConversation, isNull);
      expect(session.currentSegments, isEmpty);
      expect(enqueued.single.id, conversationId);
      final stored = await ConversationRepo(db).byId(conversationId);
      expect(stored!.segments, hasLength(1));
    });

    test('stopping with nothing recorded saves nothing', () async {
      session = await buildSession();
      await startListening();

      await session.stop();

      expect(enqueued, isEmpty);
      expect(session.state, SessionState.idle);
    });

    test('a stop that saves goes finalizing -> idle, never back to listening', () async {
      session = await buildSession();
      await startListening();
      await transcriber.emit('something worth keeping');
      final states = <SessionState>[];
      session.states.listen(states.add);

      await session.stop();

      // `docs/03-architecture.md` §4 draws `finalizing -> (listening | idle)`;
      // this is the idle edge, and no phantom conversation is opened on the
      // way through.
      expect(states, [SessionState.finalizing, SessionState.idle]);
      expect(session.currentConversation, isNull);
    });

    test('a disconnect while answering leaves the session idle, not listening', () async {
      // `AppProvider` calls stop() fire-and-forget when the wearable drops, so
      // it can land in the middle of the LLM round-trip. The answer must not
      // write `listening` back over a session that has been torn down.
      final answering = Completer<void>();
      final release = Completer<void>();
      session = await buildSession();
      await startListening();

      llm.onChat = () async {
        answering.complete();
        await release.future;
      };

      final query = () async {
        await session.handleButton(ButtonEvent.singleTap);
        // Said while the query is open, so it lands in the query buffer.
        await transcriber.emit('a question');
        await session.handleButton(ButtonEvent.singleTap);
      }();
      await answering.future;
      expect(session.state, SessionState.answering);

      await session.stop();
      expect(session.state, SessionState.idle);

      release.complete();
      await query;

      expect(session.state, SessionState.idle, reason: 'the answer must not resurrect the session');
      // And the session is genuinely reusable rather than stuck.
      await session.start(source: _FakeAudioSource(), useOpusEncoding: true);
      expect(session.state, SessionState.listening);
    });

    test('a disconnect during the trailing-audio wait abandons the query', () async {
      // The other half of the window: `stop()` can land inside the 1.5 s wait
      // that lets the transcriber catch up on the tail of the question.
      final waiting = Completer<void>();
      final release = Completer<void>();
      session = await buildSession(
        delay: (_) async {
          waiting.complete();
          await release.future;
        },
      );
      await startListening();

      await session.handleButton(ButtonEvent.singleTap);
      await transcriber.emit('a question nobody will answer');
      final query = session.handleButton(ButtonEvent.singleTap);
      await waiting.future;

      await session.stop();
      release.complete();
      await query;

      expect(session.state, SessionState.idle);
      expect(llm.questions, isEmpty, reason: 'the query is abandoned, not answered');
      expect(feedback.aiAnswers, isEmpty);
    });

    test('start() on a session that is not idle is an error, not a silent no-op', () async {
      session = await buildSession();
      await startListening();

      await expectLater(
        session.start(source: _FakeAudioSource(), useOpusEncoding: true),
        throwsStateError,
      );
    });

    test('stopping mid-query saves and leaves no session behind', () async {
      session = await buildSession();
      await startListening();
      await session.handleButton(ButtonEvent.singleTap);
      await transcriber.emit('mid-question');
      expect(session.state, SessionState.holdToAsk);

      await session.stop();

      expect(session.state, SessionState.idle);
      expect(enqueued, hasLength(1));
      expect(transcriber.stopped, isTrue);
      expect(source.stopped, isTrue);
    });
  });

  group('fixture replay', () {
    test('a recorded BLE session drives the session through OmiAudioSource', () async {
      final fixture =
          File('test/fixtures/omi_session_synthetic.jsonl').readAsStringSync();
      final replayDevice = FakeOmiDevice.fromJsonl(fixture);

      session = await buildSession();
      await session.start(
        source: OmiAudioSource(replayDevice.audioPackets),
        // The fake transcriber accepts Opus, so the frames pass straight
        // through and no native decoder is involved.
        useOpusEncoding: false,
      );
      await replayDevice.startAudioStream();
      await replayDevice.replay();
      await Future<void>.delayed(Duration.zero);

      expect(transcriber.fed, isNotEmpty);
      expect(
        transcriber.fed.every((chunk) => chunk.encoding == AudioEncoding.opus),
        isTrue,
      );
    });
  });

  group('the audio self-test tap', () {
    test('diverts audio away from the transcriber while it is set', () async {
      session = await buildSession(transcriberEncoding: AudioEncoding.pcm16);
      await startListening();

      final captured = <int>[];
      session.pcmTap = captured.addAll;
      await source.push([7, 8], encoding: AudioEncoding.pcm16);

      expect(captured, [7, 8]);
      expect(transcriber.fed, isEmpty);

      session.pcmTap = null;
      await source.push([1], encoding: AudioEncoding.pcm16);
      expect(transcriber.fed, hasLength(1));
    });
  });
}
