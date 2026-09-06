/// Extracts the 2-minute silence auto-save timer out of the pre-LO-33
/// recording monolith (`_resetSilenceTimer` / `_cancelSilenceTimer`) into a
/// small, injectable unit so it can be unit tested without waiting on a real
/// `Timer`.
library;

import 'dart:async';

import '../core/clock.dart';

/// Creates the [Timer] that fires [callback] after [duration].
///
/// Injectable so tests can substitute a fake that captures the callback
/// instead of a real, time-based `Timer`.
typedef SessionTimerFactory = Timer Function(Duration duration, void Function() callback);

/// The production [SessionTimerFactory]: a real `Timer`.
Timer defaultSessionTimerFactory(Duration duration, void Function() callback) => Timer(duration, callback);

/// Watches for silence (no transcript activity) and fires [onSilence] once
/// [timeout] elapses without a further [noteActivity] call.
///
/// Mirrors the old monolith's `_resetSilenceTimer` / `_cancelSilenceTimer`
/// pair: every activity cancels and re-arms a single timer, so at most one
/// timeout is ever pending. [Clock] and [SessionTimerFactory] are both
/// injectable so tests can drive this deterministically, without any real
/// waiting.
class SilenceDetector {
  SilenceDetector({
    this.timeout = const Duration(minutes: 2),
    Clock clock = const SystemClock(),
    SessionTimerFactory createTimer = defaultSessionTimerFactory,
  })  : _clock = clock,
        _createTimer = createTimer;

  /// How long to wait for activity before firing [onSilence].
  final Duration timeout;

  final Clock _clock;
  final SessionTimerFactory _createTimer;

  Timer? _timer;
  DateTime? _lastActivityAt;

  /// Invoked when [timeout] elapses with no further [noteActivity] call.
  ///
  /// Set by the owner (the recording session) after construction, because
  /// the detector is injectable and the owner is what reacts to silence.
  void Function()? onSilence;

  /// Whether a timeout is currently pending.
  bool get isArmed => _timer != null;

  /// When [noteActivity] was last called, or null if never.
  DateTime? get lastActivityAt => _lastActivityAt;

  /// Records that something was heard: cancels any pending timeout and arms
  /// a fresh one.
  void noteActivity() {
    _lastActivityAt = _clock.now();
    cancel();
    _timer = _createTimer(timeout, _onTimeout);
  }

  /// Cancels a pending timeout without recording activity.
  ///
  /// A no-op when nothing is armed, matching the old code's unconditional
  /// `_silenceTimer?.cancel()`.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void _onTimeout() {
    _timer = null;
    onSilence?.call();
  }

  /// Cancels and drops [onSilence].
  void dispose() {
    cancel();
    onSilence = null;
  }
}
