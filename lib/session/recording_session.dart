/// The recording session state machine of `docs/03-architecture.md` §4
/// (LO-33).
///
/// This owns everything that happens between "audio is flowing" and "a
/// conversation has been handed to [ConversationFinalizer]": the state
/// machine itself, the live segment list, the 2-minute silence timeout, the
/// button gestures, and the hold-to-ask exchange.
///
/// What it deliberately does **not** own is everything that needs
/// `SettingsService`, runtime permissions or the Android foreground service:
/// building the transcriber for the selected mode, asking for the microphone,
/// and bringing the foreground service up before any audio flows (docs/04 §4)
/// stay in `controllers/session_controller.dart`, which hands the ready-made
/// pieces to [start]. That keeps `lib/session` free of platform and settings
/// dependencies (`docs/03-architecture.md` §1) and keeps the ordering
/// constraints that can only be verified on a device in one place.
library;

import 'dart:async';
import 'dart:typed_data';

import '../audio/audio_routing.dart';
import '../audio/audio_source.dart';
import '../audio/opus_decoder.dart';
import '../core/clock.dart';
import '../core/ids.dart';
import '../core/log.dart';
import '../device/omi_device.dart';
import '../device/omi_gatt.dart';
import '../intelligence/llm_client.dart';
import '../models/conversation.dart';
import '../transcription/transcriber.dart';
import 'button_handler.dart';
import 'conversation_finalizer.dart';
import 'session_state.dart';
import 'silence_detector.dart';

const _log = Log('Session');

/// The system prompt hold-to-ask answers are generated with. Kept verbatim
/// from the pre-LO-33 monolith's `_processAiQuery`: the answer is delivered
/// as a notification, which is why it insists on brevity.
const String holdToAskSystemPrompt =
    "You are Omi, a helpful AI wearable assistant. Your responses are on "
    "notifications, so they MUST be extremely concise. Aim for just the answer. "
    "Navigate straight to the point. No fluff.";

/// Builds the transcription backend for one session. [useOpusEncoding] is
/// true for the Omi path, which streams Opus, and false for the phone mic,
/// which streams raw PCM16. The returned transcriber must not have been
/// started yet: the session subscribes to it first so nothing produced
/// during start-up is lost.
typedef TranscriberFactory = Future<StreamingTranscriber> Function({
  required bool useOpusEncoding,
});

/// Builds the Opus decoder the Omi path needs, already initialized.
///
/// Nullable so a test can opt out of the native Opus library, which is not
/// available under `flutter test`. In production this never returns null: a
/// decoder that cannot be initialized throws, and the session start it aborts
/// is the same abort the pre-LO-33 code produced.
typedef OpusDecoderFactory = Future<OpusDecoder?> Function();

/// The connected wearable, or null. A lookup rather than a stored reference
/// because the device object is replaced on every reconnect.
typedef DeviceLookup = OmiDevice? Function();

/// Opens or closes the underlying audio transport (for the Omi path,
/// `OmiDevice.startAudioStream` / `stopAudioStream`). The [AudioSource] only
/// transforms the packet stream; it does not own it, which is why the
/// session takes these separately.
typedef TransportControl = Future<void> Function();

/// Waits for [duration]. Injected so the hold-to-ask trailing-audio delay
/// does not make tests wait for real time.
typedef SessionDelay = Future<void> Function(Duration duration);

Future<void> _realDelay(Duration duration) => Future<void>.delayed(duration);

Future<OpusDecoder> _realOpusDecoder() async {
  final decoder = OpusDecoder();
  await decoder.initialize();
  return decoder;
}

/// One completed hold-to-ask exchange.
///
/// Carries the question as well as the answer because the answer is now also
/// appended to the chat page (issue #33): a bare assistant message with no
/// visible question reads as an orphan there.
class AiAnswer {
  const AiAnswer({required this.question, required this.answer});

  final String question;
  final String answer;

  @override
  String toString() => 'AiAnswer(question: $question, answer: $answer)';
}

/// The phone-side feedback a session produces: haptics and notifications.
///
/// Injected so `lib/session` depends on neither `flutter/services` nor
/// `awesome_notifications`; `controllers/session_controller.dart` supplies the production adapter and
/// tests supply a recorder. Device-side haptics do not go through here — the
/// session calls [OmiDevice.haptic] directly on the device it looks up.
abstract class SessionFeedback {
  /// A phone haptic pulse mirroring a device pulse of the same strength.
  Future<void> haptic(HapticLevel level);

  /// A plain notification (the double-tap save confirmations).
  Future<void> notify(String title, String body);

  /// The "Processing: ..." progress notification. The session always calls
  /// this; the implementation is what gates it on the user's setting.
  Future<void> notifyAiProgress(String message);

  /// The hold-to-ask answer, or the message shown when it could not be
  /// produced.
  Future<void> notifyAiAnswer(String message);
}

/// A [SessionFeedback] that does nothing, for tests and headless use.
class NoopSessionFeedback implements SessionFeedback {
  const NoopSessionFeedback();

  @override
  Future<void> haptic(HapticLevel level) async {}

  @override
  Future<void> notify(String title, String body) async {}

  @override
  Future<void> notifyAiProgress(String message) async {}

  @override
  Future<void> notifyAiAnswer(String message) async {}
}

/// Drives one recording session: audio in, transcript segments out,
/// conversations handed to [ConversationFinalizer].
class RecordingSession {
  RecordingSession({
    required TranscriberFactory transcriberFactory,
    required ConversationFinalizer finalizer,
    required LlmClientFactory llmClientFactory,
    DeviceLookup? device,
    OpusDecoderFactory opusDecoderFactory = _realOpusDecoder,
    SilenceDetector? silenceDetector,
    ButtonHandler? buttonHandler,
    SessionFeedback feedback = const NoopSessionFeedback(),
    IdGenerator? ids,
    Clock clock = const SystemClock(),
    Duration holdToAskTrailingDelay = const Duration(milliseconds: 1500),
    SessionDelay delay = _realDelay,
    Future<void> Function()? onStartRequested,
  })  : _transcriberFactory = transcriberFactory,
        _finalizer = finalizer,
        _llmClientFactory = llmClientFactory,
        _device = device ?? (() => null),
        _opusDecoderFactory = opusDecoderFactory,
        _silence = silenceDetector ?? SilenceDetector(),
        _buttons = buttonHandler ?? ButtonHandler(),
        _feedback = feedback,
        _ids = ids ?? UuidIdGenerator(),
        _clock = clock,
        _holdToAskTrailingDelay = holdToAskTrailingDelay,
        _delay = delay,
        _onStartRequested = onStartRequested {
    _silence.onSilence = _onSilenceTimeout;
  }

  final TranscriberFactory _transcriberFactory;
  final ConversationFinalizer _finalizer;
  final LlmClientFactory _llmClientFactory;
  final DeviceLookup _device;
  final OpusDecoderFactory _opusDecoderFactory;
  final SilenceDetector _silence;
  final ButtonHandler _buttons;
  final SessionFeedback _feedback;
  final IdGenerator _ids;
  final Clock _clock;
  final Duration _holdToAskTrailingDelay;
  final SessionDelay _delay;

  /// Starts a session on the caller's behalf. A single tap that arrives while
  /// nothing is recording is supposed to start recording *and* open a query,
  /// but only the caller knows how to bring the foreground service and the
  /// transcriber up, so the session asks rather than doing it itself.
  final Future<void> Function()? _onStartRequested;

  final _stateController = StreamController<SessionState>.broadcast();
  final _segmentsController =
      StreamController<List<TranscriptSegment>>.broadcast();
  final _answersController = StreamController<AiAnswer>.broadcast();

  SessionState _state = SessionState.idle;
  Conversation? _conversation;
  List<TranscriptSegment> _segments = <TranscriptSegment>[];
  bool _hasActiveConversation = false;
  String _query = '';

  AudioSource? _source;
  StreamSubscription<AudioChunk>? _audioSubscription;
  StreamingTranscriber? _transcriber;
  StreamSubscription<TranscriptSegment>? _segmentsSubscription;
  StreamSubscription<String>? _errorsSubscription;
  OpusDecoder? _decoder;
  TransportControl? _closeTransport;

  /// While set, decoded PCM is handed to this sink and nothing reaches the
  /// transcriber. This is the audio self-test in settings, which records a
  /// few seconds and plays them back; it is a diagnostic tap, not part of the
  /// state machine.
  void Function(Uint8List pcm)? pcmTap;

  /// The current state.
  SessionState get state => _state;

  /// State transitions, in order.
  Stream<SessionState> get states => _stateController.stream;

  /// A snapshot of the current conversation's segments after every change.
  Stream<List<TranscriptSegment>> get liveSegments =>
      _segmentsController.stream;

  /// Completed hold-to-ask exchanges.
  Stream<AiAnswer> get aiAnswers => _answersController.stream;

  /// The conversation being recorded, or null when idle.
  Conversation? get currentConversation => _conversation;

  /// The segments recorded into the current conversation so far.
  List<TranscriptSegment> get currentSegments =>
      List<TranscriptSegment>.unmodifiable(_segments);

  /// Whether a hold-to-ask query is being collected.
  bool get isHoldToAskActive => _state == SessionState.holdToAsk;

  /// Whether a hold-to-ask query is being answered, which is when the main
  /// conversation's transcription is paused.
  bool get isAnswering => _state == SessionState.answering;

  /// Opens a session over [source].
  ///
  /// The order below is the one the pre-LO-33 monolith's `startListening`
  /// used and it matters: the transcriber is subscribed and started before
  /// any audio can arrive, the transport is opened only once there is
  /// something to receive it, and the source is subscribed last.
  ///
  /// A failure at any step tears down what was already brought up and
  /// rethrows, so a retry cannot leave a previous transcriber running with
  /// nobody listening to it.
  Future<void> start({
    required AudioSource source,
    required bool useOpusEncoding,
    TransportControl? openTransport,
    TransportControl? closeTransport,
  }) async {
    if (_state != SessionState.idle) {
      // Throws rather than returning quietly: a caller that goes on to report
      // "listening" for a session that did not start would present a dead
      // session as a live one, which is exactly the failure this guard is
      // here to make impossible. Every path that can leave the machine
      // mid-flight (a failed hold-to-ask start, a stop during an answer)
      // returns it to `idle`, so reaching this is a bug, not a race.
      throw StateError('RecordingSession.start() called while $_state');
    }

    // Recorded before anything can fail so the teardown below always gets to
    // release the source, even when the transport never opened.
    _source = source;

    try {
      final transcriber =
          await _transcriberFactory(useOpusEncoding: useOpusEncoding);
      _transcriber = transcriber;
      // Subscribed before start() so nothing produced during start-up is lost.
      _segmentsSubscription = transcriber.segments.listen(_onSegment);
      // The runtime type stands in for the per-mode label the pre-LO-33
      // code logged, so `adb logcat` still says which backend complained.
      _errorsSubscription = transcriber.errors.listen(
        (error) => _log.d('${transcriber.runtimeType} error: $error'),
      );
      await transcriber.start();

      if (openTransport != null) {
        await openTransport();
        // Recorded only once the transport is actually open, so the teardown
        // below never closes a transport that was never opened.
        _closeTransport = closeTransport;
      }

      if (useOpusEncoding) {
        _decoder = await _opusDecoderFactory();
      }

      _audioSubscription = source.start().listen(_onAudioChunk);
    } catch (_) {
      await _teardown();
      rethrow;
    }

    _startNewConversation();
    _setState(SessionState.listening);
    _log.d('session started (opus: $useOpusEncoding)');
  }

  /// Closes the session, saving whatever was recorded but not yet finalized.
  Future<void> stop() async {
    if (_state == SessionState.idle) return;

    _silence.cancel();
    if (_hasActiveConversation && _segments.isNotEmpty) {
      // Emits `finalizing` then `idle`: there is no new conversation to open,
      // which is the `finalizing -> idle` edge of `docs/03-architecture.md` §4.
      await _finalizeCurrent(stopping: true);
    } else {
      _clearConversation();
      _setState(SessionState.idle);
    }

    await _teardown();
    _log.d('session stopped');
  }

  /// Saves the current conversation without waiting for silence (double tap,
  /// or the manual save in the UI). A no-op when nothing has been recorded.
  Future<void> saveNow() async {
    if (_state == SessionState.idle) return;
    if (_segments.isEmpty) return;
    await _finalizeCurrent();
  }

  /// Handles one button notification from the wearable.
  ///
  /// Events that arrive while a previous command is still running are dropped
  /// by [ButtonHandler], which is what stops a bouncing button from opening
  /// and closing a query in the same breath.
  Future<void> handleButton(ButtonEvent event) async {
    final command = _buttons.accept(event);
    if (command == null) {
      _log.d('button event $event dropped: previous command still running');
      return;
    }
    try {
      switch (command) {
        case SessionCommand.saveNow:
          await _saveOnDoubleTap();
        case SessionCommand.toggleHoldToAsk:
          await _toggleHoldToAsk();
        case SessionCommand.ignore:
          _log.d('button event $event ignored');
      }
    } finally {
      _buttons.finish();
    }
  }

  /// Releases everything this session holds. The session cannot be reused
  /// afterwards: its streams are closed for good.
  Future<void> dispose() async {
    _silence.dispose();
    // Before the controllers close, so a late reader cannot see a disposed
    // session still claiming to listen.
    _state = SessionState.idle;
    await _teardown();
    await _stateController.close();
    await _segmentsController.close();
    await _answersController.close();
  }

  // === Button commands ===

  Future<void> _saveOnDoubleTap() async {
    // Fire-and-forget, as before LO-33: a haptic or a notification that hangs
    // (no permission, a busy platform channel) must not delay the save.
    unawaited(_feedback.haptic(HapticLevel.long));
    unawaited(_deviceHaptic(HapticLevel.long));

    if (_segments.isEmpty) {
      unawaited(_feedback.notify('Double Tap', 'No active conversation to save.'));
      return;
    }
    unawaited(_feedback.notify('Double Tap', 'Saving conversation...'));
    await saveNow();
  }

  Future<void> _toggleHoldToAsk() async {
    if (_state == SessionState.holdToAsk) {
      await _finishHoldToAsk();
    } else {
      await _beginHoldToAsk();
    }
  }

  Future<void> _beginHoldToAsk() async {
    unawaited(_feedback.haptic(HapticLevel.medium));
    unawaited(_deviceHaptic(HapticLevel.medium));

    // A tap on an idle session means "record and ask": bring the session up
    // first, because [start] refuses to run once the state has moved on.
    if (_state == SessionState.idle) {
      final start = _onStartRequested;
      if (start == null) {
        _log.d('single tap on an idle session with no way to start one');
        return;
      }
      try {
        await start();
      } catch (e) {
        _log.d('could not start listening for the query: $e');
      }
      // A start that failed leaves the session idle, and moving to holdToAsk
      // anyway would strand it for good: [start] refuses to run once the
      // state is no longer idle, and nothing would ever bring it back. Stay
      // idle instead, so the next attempt (a button tap, or the UI) works.
      if (_state != SessionState.listening) {
        _log.d('hold-to-ask cancelled: the session did not start');
        return;
      }
    }

    _query = '';
    _setState(SessionState.holdToAsk);
  }

  Future<void> _finishHoldToAsk() async {
    unawaited(_feedback.haptic(HapticLevel.short));
    unawaited(_deviceHaptic(HapticLevel.short));

    // Stay in holdToAsk across this wait on purpose: the transcriber is still
    // catching up on the tail of the question, and those segments belong in
    // the query buffer.
    await _delay(_holdToAskTrailingDelay);

    // The session can be torn down underneath both awaits in this method: the
    // wearable going out of range makes `SessionController` call `stop()` without
    // waiting for anything here. Writing a state back afterwards would
    // resurrect a session whose transcriber, source and transport are gone.
    if (_state != SessionState.holdToAsk) {
      _log.d('hold-to-ask abandoned: the session left holdToAsk while waiting');
      _query = '';
      return;
    }

    final question = _query.trim();
    _query = '';
    _setState(SessionState.answering);
    try {
      await _answer(question);
    } finally {
      // Back to listening even when answering blew up, or the session would
      // silently drop audio for the rest of its life — but only if this is
      // still the session that started answering.
      if (_state == SessionState.answering) {
        _setState(SessionState.listening);
      }
    }
  }

  Future<void> _answer(String question) async {
    if (question.isEmpty) {
      unawaited(
        _feedback.notifyAiAnswer("I couldn't hear that. Please try again."),
      );
      return;
    }

    unawaited(_feedback.notifyAiProgress('Processing: $question'));

    try {
      final answer = await _llmClientFactory().chat(
        question,
        context: holdToAskSystemPrompt,
      );
      _log.d('hold-to-ask answer: $answer');
      unawaited(_feedback.notifyAiAnswer(answer));
      if (!_answersController.isClosed) {
        _answersController.add(AiAnswer(question: question, answer: answer));
      }
    } catch (e) {
      _log.d('hold-to-ask query failed: $e');
      unawaited(
        _feedback.notifyAiAnswer('Failed to process question. Please try again.'),
      );
    }
  }

  Future<void> _deviceHaptic(HapticLevel level) async {
    final device = _device();
    if (device == null) return;
    try {
      await device.haptic(level);
    } catch (e) {
      _log.d('device haptic failed: $e');
    }
  }

  // === Transcript and audio ===

  void _onSegment(TranscriptSegment segment) {
    if (_state == SessionState.idle) return;

    // A hold-to-ask query is transcribed into the conversation *and* into the
    // query buffer; the question is part of what was said in the room.
    if (_state == SessionState.holdToAsk && segment.text.isNotEmpty) {
      _query += ' ${segment.text}';
    }

    _segments.add(segment);
    _hasActiveConversation = true;
    _silence.noteActivity();
    _emitSegments();
  }

  void _onAudioChunk(AudioChunk chunk) {
    if (chunk.bytes.isEmpty) return;

    final tap = pcmTap;
    if (tap != null) {
      final pcm = chunk.encoding == AudioEncoding.opus
          ? _decoder?.decode(chunk.bytes)
          : chunk.bytes;
      if (pcm != null) tap(pcm);
      return;
    }

    // The main conversation's transcription is paused while the assistant
    // answers (`docs/03-architecture.md` §4).
    if (_state == SessionState.answering) return;

    _feedTranscriber(chunk);
  }

  /// Hands one chunk to the active transcriber, decoding it first when the
  /// backend only accepts PCM16. A chunk whose decode failed, or which cannot
  /// be converted at all, is dropped.
  void _feedTranscriber(AudioChunk chunk) {
    final transcriber = _transcriber;
    if (transcriber == null) return;

    switch (routeAudioChunk(
      chunk: chunk.encoding,
      accepted: transcriber.acceptedEncoding,
    )) {
      case AudioRouting.passThrough:
        transcriber.feed(chunk);
      case AudioRouting.decodeOpus:
        final pcm = _decoder?.decode(chunk.bytes);
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

  // === Conversation lifecycle ===

  void _onSilenceTimeout() {
    if (_hasActiveConversation && _segments.isNotEmpty) {
      _log.d('silence timeout reached, saving conversation');
      // Nobody is waiting on this one, so a failure here (the database, the
      // caller's reload) would otherwise surface as an unhandled async error.
      unawaited(
        _finalizeCurrent().catchError((Object error) {
          _log.d('silence-triggered finalization failed: $error');
        }),
      );
    }
  }

  void _startNewConversation() {
    _conversation = Conversation(id: _ids.newId(), createdAt: _clock.now());
    _segments = <TranscriptSegment>[];
    _hasActiveConversation = false;
    _silence.cancel();
    _emitSegments();
    _log.d('started new conversation: ${_conversation!.id}');
  }

  void _clearConversation() {
    _conversation = null;
    _segments = <TranscriptSegment>[];
    _hasActiveConversation = false;
    _silence.cancel();
    _emitSegments();
  }

  /// Hands the current conversation to [ConversationFinalizer] and, unless the
  /// session is [stopping], starts a fresh one.
  ///
  /// The next conversation is opened, and the state is restored, *before* the
  /// finalizer is awaited: a hand-off is asynchronous and listening must not
  /// pause for it (`docs/03-architecture.md` §4). The returned future still
  /// completes only once the hand-off is done, so [stop] can wait for it.
  Future<void> _finalizeCurrent({bool stopping = false}) async {
    final conversation = _conversation;
    if (conversation == null || _segments.isEmpty) {
      if (!stopping) _startNewConversation();
      return;
    }
    conversation.segments = List<TranscriptSegment>.of(_segments);

    // A double tap during a hold-to-ask query saves the conversation without
    // abandoning the query, so the state to come back to is whatever we were
    // in — not unconditionally `listening`.
    final SessionState resume;
    if (stopping) {
      resume = SessionState.idle;
    } else {
      resume = _state == SessionState.idle ? SessionState.listening : _state;
    }

    _setState(SessionState.finalizing);
    if (stopping) {
      _clearConversation();
    } else {
      _startNewConversation();
    }
    _setState(resume);

    await _finalizer.finalize(conversation);
  }

  // === Plumbing ===

  void _setState(SessionState next) {
    if (_state == next) return;
    _state = next;
    if (!_stateController.isClosed) {
      _stateController.add(next);
    }
  }

  void _emitSegments() {
    if (!_segmentsController.isClosed) {
      _segmentsController.add(List<TranscriptSegment>.of(_segments));
    }
  }

  /// Releases the per-session resources, in the reverse of the order [start]
  /// brought them up. Also the rollback for a [start] that failed half-way,
  /// which is why every step tolerates a null.
  Future<void> _teardown() async {
    // Every field is read and cleared *before* its shutdown is awaited, so a
    // second teardown running concurrently (a dispose landing inside a start)
    // cannot pick the same subscription up and release it twice.
    final audioSubscription = _audioSubscription;
    _audioSubscription = null;
    await audioSubscription?.cancel();

    final source = _source;
    _source = null;
    await source?.stop();

    // The source only transforms the packet stream; the transport underneath
    // it has to be closed separately.
    final closeTransport = _closeTransport;
    _closeTransport = null;
    if (closeTransport != null) {
      try {
        await closeTransport();
      } catch (e) {
        _log.d('closing the audio transport failed: $e');
      }
    }

    final segmentsSubscription = _segmentsSubscription;
    _segmentsSubscription = null;
    await segmentsSubscription?.cancel();

    final errorsSubscription = _errorsSubscription;
    _errorsSubscription = null;
    await errorsSubscription?.cancel();

    final transcriber = _transcriber;
    _transcriber = null;
    await transcriber?.stop();

    final decoder = _decoder;
    _decoder = null;
    decoder?.dispose();
  }
}
