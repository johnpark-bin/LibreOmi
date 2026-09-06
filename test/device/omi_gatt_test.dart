import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/device/omi_gatt.dart';

void main() {
  group('normalizeUuid', () {
    test('expands 16-bit short form', () {
      expect(normalizeUuid('180f'), '0000180f-0000-1000-8000-00805f9b34fb');
    });

    test('expands 32-bit short form', () {
      expect(normalizeUuid('0000180f'), '0000180f-0000-1000-8000-00805f9b34fb');
    });

    test('inserts dashes into a dashless 128-bit uuid', () {
      expect(
        normalizeUuid('19b10000e8f2537e4f6cd104768a1214'),
        '19b10000-e8f2-537e-4f6c-d104768a1214',
      );
    });

    test('lowercases an already-dashed uppercase uuid', () {
      expect(
        normalizeUuid('19B10000-E8F2-537E-4F6C-D104768A1214'),
        '19b10000-e8f2-537e-4f6c-d104768a1214',
      );
    });

    test('strips surrounding braces', () {
      expect(
        normalizeUuid('{19b10000-e8f2-537e-4f6c-d104768a1214}'),
        '19b10000-e8f2-537e-4f6c-d104768a1214',
      );
    });

    test('returns garbage input trimmed and lowercased without throwing', () {
      expect(normalizeUuid('  NOT-A-UUID  '), 'not-a-uuid');
    });

    test('batteryServiceUuid and its full form normalize to the same key', () {
      expect(
        normalizeUuid(batteryServiceUuid),
        normalizeUuid('0000180F-0000-1000-8000-00805F9B34FB'),
      );
    });
  });

  group('codecFromId', () {
    test('1 maps to pcm8', () {
      expect(codecFromId(1), BleAudioCodec.pcm8);
    });

    test('20 maps to opus', () {
      expect(codecFromId(20), BleAudioCodec.opus);
    });

    test('21 maps to opusFS320', () {
      expect(codecFromId(21), BleAudioCodec.opusFS320);
    });

    test('unknown ids map to null', () {
      expect(codecFromId(0), isNull);
      expect(codecFromId(2), isNull);
      expect(codecFromId(255), isNull);
    });
  });

  group('isMtuSufficient', () {
    test('23 (default BLE MTU) is insufficient', () {
      expect(isMtuSufficient(23), isFalse);
    });

    test('85 is insufficient', () {
      expect(isMtuSufficient(85), isFalse);
    });

    test('86 is sufficient', () {
      expect(isMtuSufficient(86), isTrue);
    });

    test('512 is sufficient', () {
      expect(isMtuSufficient(512), isTrue);
    });
  });

  group('parseStorageList', () {
    test('empty input returns empty list', () {
      expect(parseStorageList(const []), isEmpty);
    });

    test('one entry decodes correctly', () {
      // 300 = 0x0000012C, little-endian bytes.
      expect(parseStorageList(const [0x2C, 0x01, 0x00, 0x00]), [300]);
    });

    test('two entries decode correctly', () {
      expect(
        parseStorageList(const [
          0x2C, 0x01, 0x00, 0x00, // 300
          0x00, 0x00, 0x00, 0x00, // 0
        ]),
        [300, 0],
      );
    });

    test('trailing partial group of fewer than 4 bytes is ignored', () {
      expect(
        parseStorageList(const [0x2C, 0x01, 0x00, 0x00, 0xFF, 0xFF]),
        [300],
      );
    });

    test('high bit set decodes as a negative int (signed semantics)', () {
      // 0xFFFFFFFF little-endian -> -1 when interpreted as signed int32.
      expect(
        parseStorageList(const [0xFF, 0xFF, 0xFF, 0xFF]),
        [-1],
      );
    });
  });

  group('buildStorageStopCommand', () {
    test('is the bare 0x03 byte, not the 6-byte read/clear payload', () {
      // docs/05-omi-ble-protocol.md "Storage (SD card) protocol": command 3
      // is sent as a single byte, which is why it needs its own encoder.
      expect(buildStorageStopCommand(), [0x03]);
    });
  });

  group('buildStorageCommand', () {
    test('returns exactly 6 bytes', () {
      final bytes = buildStorageCommand(command: 0, fileNumber: 1, offset: 0);
      expect(bytes, hasLength(6));
    });

    test('encodes offset big-endian', () {
      final bytes = buildStorageCommand(
        command: 0,
        fileNumber: 1,
        offset: 0x01020304,
      );
      expect(bytes, [0, 1, 0x01, 0x02, 0x03, 0x04]);
    });

    test('silently truncates an offset above 0xFFFFFFFF', () {
      final bytes = encodeStorageCommand(
        command: 0,
        fileNumber: 0,
        offset: 0x1AABBCCDD, // the leading 0x1 has nowhere to go
      );
      expect(bytes, [0, 0, 0xAA, 0xBB, 0xCC, 0xDD]);
    });

    test('masks out-of-range command and fileNumber to a single byte', () {
      final bytes = buildStorageCommand(
        command: 0x1FF, // -> 0xFF
        fileNumber: 0x101, // -> 0x01
        offset: 0,
      );
      expect(bytes, [0xFF, 0x01, 0, 0, 0, 0]);
    });

    test('offset 0 encodes as four zero bytes', () {
      final bytes = buildStorageCommand(command: 1, fileNumber: 2, offset: 0);
      expect(bytes, [1, 2, 0, 0, 0, 0]);
    });
  });

  group('encodeStorageCommand', () {
    test('delegates to buildStorageCommand (offset 0)', () {
      expect(
        encodeStorageCommand(command: 0, fileNumber: 1, offset: 0),
        buildStorageCommand(command: 0, fileNumber: 1, offset: 0),
      );
    });

    test('encodes a large offset that exercises all four bytes', () {
      final bytes = encodeStorageCommand(
        command: 2,
        fileNumber: 5,
        offset: 0xAABBCCDD,
      );
      expect(bytes, [2, 5, 0xAA, 0xBB, 0xCC, 0xDD]);
    });

    test('silently truncates an offset above 0xFFFFFFFF', () {
      final bytes = encodeStorageCommand(
        command: 0,
        fileNumber: 0,
        offset: 0x1AABBCCDD, // the leading 0x1 has nowhere to go
      );
      expect(bytes, [0, 0, 0xAA, 0xBB, 0xCC, 0xDD]);
    });

    test('masks out-of-range command and fileNumber to a single byte', () {
      final bytes = encodeStorageCommand(
        command: 0x2FF, // -> 0xFF
        fileNumber: 0x300, // -> 0x00
        offset: 1,
      );
      expect(bytes, [0xFF, 0x00, 0, 0, 0, 1]);
    });
  });

  group('stripAudioHeader', () {
    test('exactly 3 bytes returns null', () {
      expect(stripAudioHeader(const [1, 2, 3]), isNull);
    });

    test('fewer than 3 bytes returns null', () {
      expect(stripAudioHeader(const []), isNull);
      expect(stripAudioHeader(const [1]), isNull);
    });

    test('4 bytes yields a single-byte payload', () {
      final packet = stripAudioHeader(const [0x01, 0x00, 0x05, 0xAB]);
      expect(packet, isNotNull);
      expect(packet!.packetIndex, 1);
      expect(packet.frameIndex, 5);
      expect(packet.payload, [0xAB]);
    });

    test('realistic 83-byte packet assembles packetIndex little-endian', () {
      final raw = <int>[
        0x34, 0x12, // packetIndex = 0x1234 little-endian
        0x07, // frameIndex
        ...List<int>.generate(80, (i) => i & 0xFF), // 80-byte opus payload
      ];
      expect(raw.length, 83);
      final packet = stripAudioHeader(raw);
      expect(packet, isNotNull);
      expect(packet!.packetIndex, 0x1234);
      expect(packet.frameIndex, 7);
      expect(packet.payload, hasLength(80));
      expect(packet.payload, List<int>.generate(80, (i) => i & 0xFF));
    });

    test('packetIndex high byte contributes correctly', () {
      final packet = stripAudioHeader(const [0x00, 0x01, 0x00, 0x00]);
      expect(packet!.packetIndex, 256);
    });
  });

  group('parseButtonEvent', () {
    test('reads the full 32 bits, not just the first byte', () {
      // 0x00000100 = 256: byte 0 is 0, so a single-byte read would say
      // "unknown" for the wrong reason. This pins the whole uint32.
      expect(parseButtonEvent(const [0x00, 0x01, 0x00, 0x00]), ButtonEvent.unknown);
      // 0x00000001 differs only in byte order and must decode as a tap.
      expect(parseButtonEvent(const [0x01, 0x00, 0x00, 0x00]), ButtonEvent.singleTap);
    });

    test('3-byte input returns null', () {
      expect(parseButtonEvent(const [1, 0, 0]), isNull);
    });

    test('empty input returns null', () {
      expect(parseButtonEvent(const []), isNull);
    });

    test('code 1 maps to singleTap', () {
      expect(parseButtonEvent(const [1, 0, 0, 0]), ButtonEvent.singleTap);
    });

    test('code 2 maps to doubleTap', () {
      expect(parseButtonEvent(const [2, 0, 0, 0]), ButtonEvent.doubleTap);
    });

    test('code 3 maps to longPressStart', () {
      expect(parseButtonEvent(const [3, 0, 0, 0]), ButtonEvent.longPressStart);
    });

    test('code 4 maps to singleTapRelease', () {
      expect(parseButtonEvent(const [4, 0, 0, 0]), ButtonEvent.singleTapRelease);
    });

    test('code 5 maps to longPressEnd', () {
      expect(parseButtonEvent(const [5, 0, 0, 0]), ButtonEvent.longPressEnd);
    });

    test('code 0 maps to unknown', () {
      expect(parseButtonEvent(const [0, 0, 0, 0]), ButtonEvent.unknown);
    });

    test('code 6 maps to unknown', () {
      expect(parseButtonEvent(const [6, 0, 0, 0]), ButtonEvent.unknown);
    });

    test('code 255 maps to unknown', () {
      expect(parseButtonEvent(const [255, 0, 0, 0]), ButtonEvent.unknown);
    });

    test('more than 4 bytes only reads the first 4', () {
      expect(
        parseButtonEvent(const [2, 0, 0, 0, 0xFF, 0xFF, 0xFF]),
        ButtonEvent.doubleTap,
      );
    });

    test('little-endian read matches the reversed-bytes-then-big-endian trick', () {
      // Upstream: ByteData.view(Uint8List.fromList(data.sublist(0,4).reversed
      // .toList()).buffer).getUint32(0) -- equivalent to a direct
      // little-endian read of the first 4 bytes.
      const raw = [0x02, 0x00, 0x00, 0x00];
      final reversedBigEndian = ByteData.sublistView(
        Uint8List.fromList(raw.reversed.toList()),
      ).getUint32(0);
      expect(reversedBigEndian, 2);
      expect(parseButtonEvent(raw), ButtonEvent.doubleTap);
    });
  });

  group('parseStoragePacket - status (1-byte)', () {
    test('code 0 is ready', () {
      final packet = parseStoragePacket(const [0]);
      expect(packet.kind, StoragePacketKind.status);
      expect(packet.status, StorageStatus.ready);
      expect(packet.rawCode, 0);
    });

    test('code 3 is badFileSize', () {
      final packet = parseStoragePacket(const [3]);
      expect(packet.status, StorageStatus.badFileSize);
      expect(packet.rawCode, 3);
    });

    test('code 4 is fileEmpty', () {
      final packet = parseStoragePacket(const [4]);
      expect(packet.status, StorageStatus.fileEmpty);
    });

    test('code 100 is transferComplete', () {
      final packet = parseStoragePacket(const [100]);
      expect(packet.status, StorageStatus.transferComplete);
    });

    test('an unrecognized code is error', () {
      final packet = parseStoragePacket(const [77]);
      expect(packet.status, StorageStatus.error);
      expect(packet.rawCode, 77);
    });
  });

  group('parseStoragePacket - 83-byte audio frame', () {
    test('normal length byte extracts exactly that many bytes', () {
      final raw = <int>[0xAA, 0xBB, 0xCC, 10, ...List<int>.filled(79, 0)];
      expect(raw.length, 83);
      final packet = parseStoragePacket(raw);
      expect(packet.kind, StoragePacketKind.audioFrame);
      expect(packet.frame, hasLength(10));
    });

    test('an over-large length byte is clamped to the available bytes', () {
      // value[3] = 200, but only 79 data bytes are actually present.
      final raw = <int>[0xAA, 0xBB, 0xCC, 200, ...List<int>.filled(79, 1)];
      expect(raw.length, 83);
      final packet = parseStoragePacket(raw);
      expect(packet.kind, StoragePacketKind.audioFrame);
      expect(packet.frame, hasLength(79));
    });

    test('length byte 79 is the un-clamped upper boundary', () {
      final raw = <int>[0xAA, 0xBB, 0xCC, 79, ...List<int>.filled(79, 7)];
      expect(raw.length, 83);
      final packet = parseStoragePacket(raw);
      expect(packet.kind, StoragePacketKind.audioFrame);
      expect(packet.frame, hasLength(79));
      expect(packet.frame!.every((b) => b == 7), isTrue);
    });

    test('length byte 0 yields an empty frame', () {
      final raw = <int>[0xAA, 0xBB, 0xCC, 0, ...List<int>.filled(79, 0)];
      final packet = parseStoragePacket(raw);
      expect(packet.frame, isEmpty);
    });
  });

  group('parseStoragePacket - 440-byte multi-frame', () {
    test('several frames with embedded len==0 padding', () {
      final raw = <int>[];
      raw.addAll([3, 0xAA, 0xBB, 0xCC]); // frame of 3 bytes
      raw.add(0); // padding byte
      raw.addAll([2, 0x01, 0x02]); // frame of 2 bytes
      // Pad the rest with zero-length "records" (each consumed as 1 padding byte).
      while (raw.length < 440) {
        raw.add(0);
      }
      expect(raw.length, 440);

      final packet = parseStoragePacket(raw);
      expect(packet.kind, StoragePacketKind.multiFrame);
      expect(packet.frames, hasLength(2));
      expect(packet.frames![0], [0xAA, 0xBB, 0xCC]);
      expect(packet.frames![1], [0x01, 0x02]);
    });

    test('a record that would run past the end is dropped (upstream-observed)', () {
      final raw = List<int>.filled(440, 0);
      // Place a record starting near the very end whose declared size runs
      // past the buffer: packageOffset + 1 + packageSize >= value.length.
      raw[438] = 5; // packageSize = 5 at offset 438; 438+1+5=444 >= 440 -> break
      final packet = parseStoragePacket(raw);
      expect(packet.kind, StoragePacketKind.multiFrame);
      // No frame should include the dangling record.
      expect(packet.frames, isEmpty);
    });

    test('a record ending exactly on the last byte is dropped by the preserved upstream bug', () {
      // packageOffset=437, packageSize=2 -> 437+1+2=440 >= 440 -> break,
      // even though bytes [438,439] would fit exactly.
      final raw = List<int>.filled(440, 0);
      raw[437] = 2;
      raw[438] = 0x11;
      raw[439] = 0x22;
      final packet = parseStoragePacket(raw);
      expect(packet.frames, isEmpty);
    });
  });

  group('parseStoragePacket - unknown length', () {
    test('a length that is not 1, 83, or 440 yields unknown', () {
      final packet = parseStoragePacket(List<int>.filled(10, 0));
      expect(packet.kind, StoragePacketKind.unknown);
      expect(packet.status, isNull);
      expect(packet.frame, isNull);
      expect(packet.frames, isNull);
    });

    test('empty input yields unknown', () {
      final packet = parseStoragePacket(const []);
      expect(packet.kind, StoragePacketKind.unknown);
    });
  });

  group('decodeDeviceInfoString', () {
    test('empty input returns empty string', () {
      expect(decodeDeviceInfoString(const []), '');
    });

    test('strips trailing NUL bytes', () {
      final bytes = [...utf8.encode('Omi DevKit'), 0, 0, 0];
      expect(decodeDeviceInfoString(bytes), 'Omi DevKit');
    });

    test('trims surrounding whitespace', () {
      final bytes = utf8.encode('  1.0.4  ');
      expect(decodeDeviceInfoString(bytes), '1.0.4');
    });

    test('decodes malformed bytes leniently without throwing', () {
      final bytes = [0xFF, 0xFE, 0x41];
      expect(() => decodeDeviceInfoString(bytes), returnsNormally);
    });

    test('all-NUL input returns empty string', () {
      expect(decodeDeviceInfoString(const [0, 0, 0]), '');
    });
  });
}
