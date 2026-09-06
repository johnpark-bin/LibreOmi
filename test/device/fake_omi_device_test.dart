import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/device/fake_omi_device.dart';
import 'package:libreomi/device/omi_device.dart';
import 'package:libreomi/device/omi_gatt.dart';

void main() {
  group('encodeCaptureLine / decodeCaptureLine', () {
    test('round-trips channel, time and bytes', () {
      final event = CapturedEvent(
        timeMs: 1234,
        channel: CaptureChannel.audio,
        bytes: Uint8List.fromList([0, 1, 2, 3, 255]),
      );
      final line = encodeCaptureLine(event);
      final decoded = decodeCaptureLine(line);

      expect(decoded, isNotNull);
      expect(decoded!.timeMs, 1234);
      expect(decoded.channel, CaptureChannel.audio);
      expect(decoded.bytes, [0, 1, 2, 3, 255]);
    });

    test('round-trips every channel', () {
      for (final channel in CaptureChannel.values) {
        final event = CapturedEvent(timeMs: 0, channel: channel, bytes: Uint8List.fromList([9]));
        final decoded = decodeCaptureLine(encodeCaptureLine(event));
        expect(decoded!.channel, channel);
      }
    });

    test('decodeCaptureLine returns null for blank lines', () {
      expect(decodeCaptureLine(''), isNull);
      expect(decodeCaptureLine('   '), isNull);
    });

    test('decodeCaptureLine returns null for malformed JSON', () {
      expect(decodeCaptureLine('{not json'), isNull);
    });

    test('decodeCaptureLine returns null for missing fields', () {
      expect(decodeCaptureLine('{"t": 1, "ch": "audio"}'), isNull);
      expect(decodeCaptureLine('{"ch": "audio", "b": "AA=="}'), isNull);
    });

    test('decodeCaptureLine returns null for unknown channel', () {
      expect(decodeCaptureLine('{"t": 1, "ch": "nope", "b": "AA=="}'), isNull);
    });

    test('decodeCaptureLine returns null for invalid base64', () {
      expect(decodeCaptureLine('{"t": 1, "ch": "audio", "b": "not base64!!"}'), isNull);
    });
  });

  group('FakeOmiDevice.fromJsonl', () {
    test('skips malformed and blank lines', () {
      const source = '''
{"t": 0, "ch": "battery", "b": "Wg=="}

not json at all
{"t": 10, "ch": "button", "b": "AQAAAA=="}
{"t": 20, "ch": "unknown_channel", "b": "AA=="}

{"t": 30, "ch": "audio", "b": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="}
''';
      final device = FakeOmiDevice.fromJsonl(source);
      expect(device.events.length, 3);
      expect(device.events[0].channel, CaptureChannel.battery);
      expect(device.events[1].channel, CaptureChannel.button);
      expect(device.events[2].channel, CaptureChannel.audio);
    });
  });

  group('replaying the synthetic fixture', () {
    late String fixture;

    setUpAll(() {
      fixture = File('test/fixtures/omi_session_synthetic.jsonl').readAsStringSync();
    });

    test('delivers 200 audio packets, in packetIndex order, with a gap at 100', () async {
      final device = FakeOmiDevice.fromJsonl(fixture);
      await device.startAudioStream();

      final received = <Uint8List>[];
      final subscription = device.audioPackets.listen(received.add);

      await device.replay();
      await subscription.cancel();

      expect(received.length, 200);

      final packetIndices = received.map((raw) {
        final packet = stripAudioHeader(raw)!;
        return packet.packetIndex;
      }).toList();

      // Strictly increasing.
      for (var i = 1; i < packetIndices.length; i++) {
        expect(packetIndices[i], greaterThan(packetIndices[i - 1]));
      }

      // The gap: 99 is immediately followed by 101, never 100.
      final index99 = packetIndices.indexOf(99);
      expect(index99, greaterThanOrEqualTo(0));
      expect(packetIndices[index99 + 1], 101);
      expect(packetIndices.contains(100), isFalse);

      // Payload is derived from the packet index, not all zeros.
      final firstPacket = stripAudioHeader(received.first)!;
      expect(firstPacket.payload.any((b) => b != 0), isTrue);
    });

    test('button events decode to singleTap then doubleTap, in order', () async {
      final device = FakeOmiDevice.fromJsonl(fixture);
      final received = <ButtonEvent>[];
      device.buttonEvents.listen(received.add);

      await device.replay();

      expect(received, [ButtonEvent.singleTap, ButtonEvent.doubleTap]);
    });

    test('battery events are delivered in order', () async {
      final device = FakeOmiDevice.fromJsonl(fixture);
      final received = <int>[];
      device.batteryLevel.listen(received.add);

      await device.replay();

      expect(received, [96, 95]);
    });

    test('audio events are dropped before startAudioStream and delivered after', () async {
      final device = FakeOmiDevice.fromJsonl(fixture);
      final received = <Uint8List>[];
      device.audioPackets.listen(received.add);

      // Not started yet: replay must drop audio but still deliver button/battery.
      final buttonReceived = <ButtonEvent>[];
      device.buttonEvents.listen(buttonReceived.add);
      await device.replay();

      expect(received, isEmpty);
      expect(buttonReceived, isNotEmpty);

      // Now start and replay again: audio should be delivered.
      await device.startAudioStream();
      await device.replay();

      expect(received.length, 200);
    });
  });

  group('FakeOmiDevice basics', () {
    test('starts disconnected, connect() moves to connected and emits', () async {
      final device = FakeOmiDevice(const []);
      expect(device.state, DeviceConnectionState.disconnected);

      final states = <DeviceConnectionState>[];
      device.connectionState.listen(states.add);

      await device.connect();

      expect(device.state, DeviceConnectionState.connected);
      expect(states, [DeviceConnectionState.connected]);
    });

    test('disconnect() moves state to disconnected', () async {
      final device = FakeOmiDevice(const []);
      await device.connect();
      await device.disconnect();
      expect(device.state, DeviceConnectionState.disconnected);
    });

    test('reads return injectable canned values with sensible defaults', () async {
      final device = FakeOmiDevice(const []);
      expect(await device.readCodec(), BleAudioCodec.opus);
      expect((await device.readDeviceInfo()).isEmpty, isTrue);
      expect(await device.readBatteryLevel(), isNull);
      expect(await device.readMicGain(), 100);
      expect(await device.readLedDim(), 50);
    });

    test('writes record what they were asked to do', () async {
      final device = FakeOmiDevice(const []);
      await device.writeMicGain(75);
      await device.writeLedDim(30);
      await device.haptic(HapticLevel.medium);

      expect(device.micGainWrites, [75]);
      expect(device.ledDimWrites, [30]);
      expect(device.haptics, [HapticLevel.medium]);
    });

    test('storage list() and startRead/clear record arguments', () async {
      final device = FakeOmiDevice(const [], storageList: [1000, 200]);
      expect(await device.storage.list(), [1000, 200]);

      await device.storage.startRead(50, fileNumber: 2);
      await device.storage.clear(fileNumber: 2);

      expect(device.storage.startReadCalls, [(offset: 50, fileNumber: 2)]);
      expect(device.storage.clearFileNumbers, [2]);
    });

    test('storage replays the storage channel on rawPackets/packets after startStream', () async {
      final statusByte = Uint8List.fromList([0]);
      final device = FakeOmiDevice([
        CapturedEvent(timeMs: 0, channel: CaptureChannel.storage, bytes: statusByte),
      ]);

      final rawReceived = <List<int>>[];
      device.storage.rawPackets.listen(rawReceived.add);

      // Not streaming yet: dropped.
      await device.replay();
      expect(rawReceived, isEmpty);

      await device.storage.startStream();
      await device.replay();
      expect(rawReceived, [statusByte]);
    });
  });
}
