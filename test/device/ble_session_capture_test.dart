import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/device/ble_session_capture.dart';
import 'package:libreomi/device/fake_omi_device.dart';

void main() {
  group('JsonlBleSessionCapture', () {
    test('writes nothing when enabled() is false', () async {
      final sink = StringBuffer();
      final capture = JsonlBleSessionCapture(
        enabled: () => false,
        openSink: () async => sink,
      );

      final device = FakeOmiDevice([
        CapturedEvent(
          timeMs: 0,
          channel: CaptureChannel.battery,
          bytes: Uint8List.fromList([90]),
        ),
      ]);
      await device.connect();
      await capture.start(device);
      await device.replay();
      await capture.stop();

      expect(sink.toString(), isEmpty);
    });

    test('writes one line per notification when enabled() is true', () async {
      final sink = StringBuffer();
      final capture = JsonlBleSessionCapture(
        enabled: () => true,
        openSink: () async => sink,
      );

      final device = FakeOmiDevice([
        CapturedEvent(
          timeMs: 0,
          channel: CaptureChannel.battery,
          bytes: Uint8List.fromList([90]),
        ),
        CapturedEvent(
          timeMs: 10,
          channel: CaptureChannel.button,
          bytes: Uint8List.fromList([1, 0, 0, 0]),
        ),
      ]);
      await device.connect();
      await device.startAudioStream();

      await capture.start(device);
      await device.replay();
      await capture.stop();

      final lines = sink.toString().split('\n').where((l) => l.trim().isNotEmpty).toList();
      expect(lines.length, 2);

      final decoded = lines.map(decodeCaptureLine).toList();
      expect(decoded[0]!.channel, CaptureChannel.battery);
      expect(decoded[0]!.bytes, [90]);
      expect(decoded[1]!.channel, CaptureChannel.button);
      expect(decoded[1]!.bytes, [1, 0, 0, 0]);
    });

    test('a second start() replaces the first instead of stacking it', () async {
      // A duplicate `connected` event used to stack a second set of stream
      // subscriptions, writing every notification twice and orphaning the
      // first sink unflushed.
      final sinks = <StringBuffer>[];
      var closes = 0;
      final capture = JsonlBleSessionCapture(
        enabled: () => true,
        openSink: () async {
          final sink = StringBuffer();
          sinks.add(sink);
          return sink;
        },
        closeSink: () async => closes++,
      );
      final device = FakeOmiDevice(const []);
      await device.connect();
      await device.startAudioStream();

      await capture.start(device);
      await capture.start(device);
      device.emit(CaptureChannel.battery, Uint8List.fromList([90]));
      await capture.stop();

      expect(sinks, hasLength(2), reason: 'the second start opens its own sink');
      expect(closes, 3, reason: 'the first sink is closed rather than orphaned');
      expect(sinks.first.toString(), isEmpty);
      final lines = sinks.last
          .toString()
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      expect(lines, hasLength(1), reason: 'one notification must write one line');
    });

    test('a failing openSink never throws and leaves the capture inert', () async {
      final capture = JsonlBleSessionCapture(
        enabled: () => true,
        openSink: () async => throw StateError('boom'),
      );
      final device = FakeOmiDevice(const []);
      await device.connect();

      // Must not throw.
      await capture.start(device);
      await capture.stop();
    });
  });
}
