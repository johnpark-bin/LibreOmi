import 'package:flutter_test/flutter_test.dart';

import 'package:libreomi/platform/background_runner.dart';
import 'package:libreomi/platform/fake_background_runner.dart';
import 'package:libreomi/platform/noop_background_runner.dart';

void main() {
  group('NoopBackgroundRunner', () {
    test('accepts every call and does nothing', () async {
      final BackgroundRunner runner = NoopBackgroundRunner();

      await expectLater(
        runner.start(reasons: {BackgroundReason.connectedDevice}),
        completes,
      );
      await expectLater(runner.update('anything'), completes);
      await expectLater(runner.stop(), completes);
      // stop() without a preceding start() must be a no-op too: it runs at
      // app start to reap a service left over by a previous process.
      await expectLater(runner.stop(), completes);
    });
  });

  group('FakeBackgroundRunner', () {
    test('records start reasons, updates and stops', () async {
      final FakeBackgroundRunner runner = FakeBackgroundRunner();
      final BackgroundRunner asInterface = runner;

      expect(runner.running, isFalse);

      await asInterface.start(reasons: {BackgroundReason.connectedDevice});
      await asInterface.update('Omi connected · 00:05');
      await asInterface.start(reasons: {
        BackgroundReason.connectedDevice,
        BackgroundReason.microphone,
      });
      await asInterface.stop();

      expect(runner.startCalls, [
        {BackgroundReason.connectedDevice},
        {BackgroundReason.connectedDevice, BackgroundReason.microphone},
      ]);
      expect(runner.updates, ['Omi connected · 00:05']);
      expect(runner.stopCount, 1);
      expect(runner.running, isFalse);
    });

    test('throwOnStart makes start() throw instead of recording', () async {
      final FakeBackgroundRunner runner = FakeBackgroundRunner(
        throwOnStart: true,
      );

      await expectLater(
        () => runner.start(reasons: {BackgroundReason.connectedDevice}),
        throwsStateError,
      );
      expect(runner.startCalls, isEmpty);
    });
  });
}
