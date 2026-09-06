/// The recording session's state machine, exactly as drawn in
/// `docs/03-architecture.md` §4:
///
/// ```
/// idle ──connect & keys ok──▶ listening ──single tap──▶ holdToAsk ──single tap──▶ answering ──▶ listening
///   ▲                            │
///   └────────── stop ────────────┴──▶ finalizing ──▶ (listening | idle)
/// ```
///
/// [SessionState.finalizing] is transient: the current conversation is
/// handed off to `ConversationFinalizer` asynchronously and a new empty
/// conversation starts immediately, so listening never actually stops while
/// finalization runs in the background.
library;

/// One state of the session state machine described above.
enum SessionState {
  /// No device session running; nothing is being recorded.
  idle,

  /// Audio flows to the active transcriber; segments append to the current
  /// conversation.
  listening,

  /// A single tap while listening started a hold-to-ask query: segments are
  /// additionally accumulated into the query buffer and an overlay is shown.
  holdToAsk,

  /// Transcription of the main conversation is paused while the captured
  /// query is answered by the LLM chat.
  answering,

  /// The current conversation is being handed off to `ConversationFinalizer`
  /// asynchronously; transient because a new empty conversation starts
  /// immediately, so listening never stops.
  finalizing,
}
