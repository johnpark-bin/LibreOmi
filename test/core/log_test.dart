import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/core/log.dart';

void main() {
  final originalSink = logSink;
  late List<String?> captured;

  setUp(() {
    captured = [];
    logSink = captured.add;
  });

  tearDown(() {
    logSink = originalSink;
  });

  group('Log', () {
    test('prefixes messages with [LibreOmi/<tag>]', () {
      const log = Log('BLE');
      log.d('connected');
      expect(captured, ['[LibreOmi/BLE] connected']);
    });

    test('uses the tag passed at construction for every call', () {
      const log = Log('Session');
      log.d('idle -> listening');
      log.d('listening -> finalizing');
      expect(captured, [
        '[LibreOmi/Session] idle -> listening',
        '[LibreOmi/Session] listening -> finalizing',
      ]);
    });

    test('does not write to the sink until d is called', () {
      const Log('Unused');
      expect(captured, isEmpty);
    });
  });
}
