import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/device/omi_gatt.dart';
import 'package:libreomi/session/button_handler.dart';

void main() {
  group('ButtonHandler', () {
    test('singleTap maps to toggleHoldToAsk', () {
      final handler = ButtonHandler();
      expect(handler.accept(ButtonEvent.singleTap), SessionCommand.toggleHoldToAsk);
    });

    test('doubleTap maps to saveNow', () {
      final handler = ButtonHandler();
      expect(handler.accept(ButtonEvent.doubleTap), SessionCommand.saveNow);
    });

    test('singleTapRelease, longPressStart, longPressEnd, and unknown map to ignore', () {
      for (final event in [
        ButtonEvent.singleTapRelease,
        ButtonEvent.longPressStart,
        ButtonEvent.longPressEnd,
        ButtonEvent.unknown,
      ]) {
        final handler = ButtonHandler();
        expect(handler.accept(event), SessionCommand.ignore, reason: 'for $event');
      }
    });

    test('a second event while busy returns null', () {
      final handler = ButtonHandler();
      expect(handler.accept(ButtonEvent.singleTap), SessionCommand.toggleHoldToAsk);
      expect(handler.accept(ButtonEvent.doubleTap), isNull);
    });

    test('after finish() events are accepted again', () {
      final handler = ButtonHandler();
      expect(handler.accept(ButtonEvent.singleTap), SessionCommand.toggleHoldToAsk);
      handler.finish();
      expect(handler.accept(ButtonEvent.doubleTap), SessionCommand.saveNow);
    });

    test('an ignore result still marks the handler busy until finish()', () {
      final handler = ButtonHandler();
      expect(handler.accept(ButtonEvent.longPressStart), SessionCommand.ignore);
      expect(handler.isProcessing, isTrue);
      expect(handler.accept(ButtonEvent.singleTap), isNull);

      handler.finish();
      expect(handler.isProcessing, isFalse);
      expect(handler.accept(ButtonEvent.singleTap), SessionCommand.toggleHoldToAsk);
    });
  });
}
