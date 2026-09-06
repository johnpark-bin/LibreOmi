/// Extracts the button-event mapping and the "still processing the previous
/// event" debounce out of `AppProvider._handleButtonPress` into a pure,
/// unit-testable class.
library;

import '../device/omi_gatt.dart';

/// What the session should do in response to a button event.
enum SessionCommand {
  /// Single tap: start hold-to-ask when idle, finish it and answer when
  /// active. It is a toggle (not a press/release pair) because the device
  /// firmware only delivers a `singleTap` reliably; `singleTapRelease` is
  /// not used to drive the state machine.
  toggleHoldToAsk,

  /// Double tap: save the current conversation now.
  saveNow,

  /// Nothing to do (long-press start/end, single-tap release, unknown).
  ///
  /// Long press is ignored on purpose: current Omi firmware repurposes a
  /// long press to power the device off, so treating it as an app-level
  /// gesture would fight the device's own behavior.
  ignore,
}

/// Maps raw [ButtonEvent]s to [SessionCommand]s and debounces them.
///
/// The old `_handleButtonPress` set an `_isProcessingButtonEvent` flag at
/// the top of the handler and cleared it on every exit path, including the
/// ignored ones, so a slow await (e.g. `startListening()` or the AI query)
/// could not be re-entered by a fresh button notification arriving mid-flight.
/// This class reproduces that: [accept] marks the handler busy for every
/// non-null result, and the caller must call [finish] when done.
class ButtonHandler {
  bool _isProcessing = false;

  /// Whether a command handed out by [accept] has not been [finish]ed yet.
  bool get isProcessing => _isProcessing;

  /// Maps [event] to the command the session should run.
  ///
  /// Returns null when the event is dropped by the debounce (a previous
  /// command is still running). On a non-null result the handler is marked
  /// busy and the caller MUST call [finish] when the command completes.
  SessionCommand? accept(ButtonEvent event) {
    if (_isProcessing) return null;
    _isProcessing = true;

    switch (event) {
      case ButtonEvent.singleTap:
        return SessionCommand.toggleHoldToAsk;
      case ButtonEvent.doubleTap:
        return SessionCommand.saveNow;
      case ButtonEvent.singleTapRelease:
      case ButtonEvent.longPressStart:
      case ButtonEvent.longPressEnd:
      case ButtonEvent.unknown:
        return SessionCommand.ignore;
    }
  }

  /// Releases the debounce.
  void finish() {
    _isProcessing = false;
  }
}
