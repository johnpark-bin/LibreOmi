// The LO-31 acceptance test: a recorded BLE session replays on the desktop,
// through the same `AudioSource` the app uses on device, with no hardware.
//
// See `test/fixtures/README.md` for the fixture format and
// `docs/03-architecture.md` §7 for why this test exists.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/audio/audio_source.dart';
import 'package:libreomi/audio/omi_audio_source.dart';
import 'package:libreomi/core/log.dart';
import 'package:libreomi/device/fake_omi_device.dart';
import 'package:libreomi/device/omi_device.dart';
import 'package:libreomi/device/omi_gatt.dart';

void main() {
  late String fixture;

  setUpAll(() {
    fixture = File('test/fixtures/omi_session_synthetic.jsonl').readAsStringSync();
  });

  group('fixture replay through OmiAudioSource', () {
    late List<String> logLines;
    late void Function(String?) previousSink;

    setUp(() {
      logLines = [];
      previousSink = logSink;
      logSink = (message) => logLines.add(message ?? '');
    });

    tearDown(() {
      logSink = previousSink;
    });

    test('delivers every audio frame, header stripped, in order', () async {
      final device = FakeOmiDevice.fromJsonl(fixture);
      final source = OmiAudioSource(device.audioPackets);
      final chunks = <AudioChunk>[];
      final subscription = source.start().listen(chunks.add);

      await device.connect();
      await device.startAudioStream();
      await device.replay();

      // 200 audio events in the fixture, all 83 bytes: 3 header + 80 payload.
      expect(chunks, hasLength(200));
      expect(chunks.every((c) => c.bytes.length == 80), isTrue);
      expect(chunks.every((c) => c.encoding == AudioEncoding.opus), isTrue);

      // The payload is the notification minus its header, in fixture order.
      final rawAudio = device.events
          .where((e) => e.channel == CaptureChannel.audio)
          .toList();
      expect(rawAudio, hasLength(200));
      for (var i = 0; i < rawAudio.length; i++) {
        expect(
          chunks[i].bytes,
          Uint8List.fromList(rawAudio[i].bytes.sublist(3)),
          reason: 'frame $i payload must survive the header strip intact',
        );
      }

      await subscription.cancel();
      await source.stop();
    });

    test('detects and logs the packet-index gap the fixture contains', () async {
      final device = FakeOmiDevice.fromJsonl(fixture);
      final source = OmiAudioSource(device.audioPackets);
      final subscription = source.start().listen((_) {});

      await device.connect();
      await device.startAudioStream();
      await device.replay();

      // The fixture jumps 99 -> 101 exactly once (see test/fixtures/README.md).
      expect(source.gapCount, 1);
      expect(
        logLines.where((l) => l.contains('audio packet gap')),
        hasLength(1),
      );
      expect(logLines.single, contains('expected 100, got 101'));

      await subscription.cancel();
      await source.stop();
    });

    test('drops audio recorded before the session started the stream', () async {
      final device = FakeOmiDevice.fromJsonl(fixture);
      final source = OmiAudioSource(device.audioPackets);
      final chunks = <AudioChunk>[];
      final subscription = source.start().listen(chunks.add);

      await device.connect();
      // No startAudioStream(): the real device notifies nothing either.
      await device.replay();

      expect(chunks, isEmpty);
      expect(source.gapCount, 0);

      await subscription.cancel();
      await source.stop();
    });
  });

  test('button and battery notifications replay decoded and in order', () async {
    final device = FakeOmiDevice.fromJsonl(fixture);
    final buttons = <ButtonEvent>[];
    final battery = <int>[];
    final states = <DeviceConnectionState>[];
    device.buttonEvents.listen(buttons.add);
    device.batteryLevel.listen(battery.add);
    device.connectionState.listen(states.add);

    await device.connect();
    await device.startAudioStream();
    await device.replay();

    expect(buttons, [ButtonEvent.singleTap, ButtonEvent.doubleTap]);
    expect(battery, [96, 95]);
    expect(states, [DeviceConnectionState.connected]);

    await device.disconnect();
    expect(states.last, DeviceConnectionState.disconnected);
  });

  test('audio and button events keep their relative order', () async {
    final device = FakeOmiDevice.fromJsonl(fixture);
    final source = OmiAudioSource(device.audioPackets);
    final order = <String>[];
    final subscription = source.start().listen((_) => order.add('audio'));
    device.buttonEvents.listen((e) => order.add('button:${e.name}'));

    await device.connect();
    await device.startAudioStream();
    await device.replay();

    // The fixture's own ordering, recovered from the event list, is what the
    // pipeline must reproduce: `sync: true` controllers all the way down mean
    // no async hop can let a button event overtake an audio packet.
    final expected = device.events
        .where((e) =>
            e.channel == CaptureChannel.audio ||
            e.channel == CaptureChannel.button)
        .map((e) => e.channel == CaptureChannel.audio
            ? 'audio'
            : 'button:${parseButtonEvent(e.bytes)!.name}')
        .toList();

    expect(order, expected);

    await subscription.cancel();
    await source.stop();
  });
}
