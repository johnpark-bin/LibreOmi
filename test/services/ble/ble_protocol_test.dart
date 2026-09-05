import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/services/ble/ble_protocol.dart';

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
}
