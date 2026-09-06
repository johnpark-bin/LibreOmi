/// Pure-Dart Omi BLE protocol constants and helpers.
///
/// This is the single source of truth for the Omi GATT protocol: UUIDs, the
/// audio codec model, and packet parsers for audio, button, and storage
/// (SD card) data. This file intentionally has no dependency on
/// `package:flutter_blue_plus` or Flutter widgets, so it can be unit tested
/// without a BLE stack or a Flutter widget test harness. See
/// docs/05-omi-ble-protocol.md for the protocol reference.
library;

import 'dart:convert';
import 'dart:typed_data';

// Omi device UUIDs (extracted from original app)
const String omiServiceUuid = '19b10000-e8f2-537e-4f6c-d104768a1214';
const String audioDataStreamCharacteristicUuid = '19b10001-e8f2-537e-4f6c-d104768a1214';
const String audioCodecCharacteristicUuid = '19b10002-e8f2-537e-4f6c-d104768a1214';
const String batteryServiceUuid = '180f';
const String batteryLevelCharacteristicUuid = '2a19';
const String settingsServiceUuid = '19b10010-e8f2-537e-4f6c-d104768a1214';
const String settingsDimRatioCharacteristicUuid = '19b10011-e8f2-537e-4f6c-d104768a1214';
const String settingsMicGainCharacteristicUuid = '19b10012-e8f2-537e-4f6c-d104768a1214';
const String speakerDataStreamServiceUuid = 'cab1ab95-2ea5-4f4d-bb56-874b72cfc984';
const String speakerDataStreamCharacteristicUuid = 'cab1ab96-2ea5-4f4d-bb56-874b72cfc984';
const String buttonServiceUuid = '23ba7924-0000-1000-7450-346eac492e92';
const String buttonTriggerCharacteristicUuid = '23ba7925-0000-1000-7450-346eac492e92';

// Device Info Service
const String deviceInformationServiceUuid = '0000180a-0000-1000-8000-00805f9b34fb';
const String modelNumberCharacteristicUuid = '00002a24-0000-1000-8000-00805f9b34fb';
const String firmwareRevisionCharacteristicUuid = '00002a26-0000-1000-8000-00805f9b34fb';
const String hardwareRevisionCharacteristicUuid = '00002a27-0000-1000-8000-00805f9b34fb';
const String manufacturerNameCharacteristicUuid = '00002a29-0000-1000-8000-00805f9b34fb';

// Storage Service
const String storageDataStreamServiceUuid = '30295780-4301-eabd-2904-2849adfeae43';
const String storageDataStreamCharacteristicUuid = '30295781-4301-eabd-2904-2849adfeae43';
const String storageReadControlCharacteristicUuid = '30295782-4301-eabd-2904-2849adfeae43';

/// The Bluetooth SIG base UUID used to expand 16-bit and 32-bit short-form
/// UUIDs into their full 128-bit form: `0000xxxx-0000-1000-8000-00805F9B34FB`.
const String _bluetoothSigBaseUuidSuffix = '0000-1000-8000-00805f9b34fb';

final RegExp _hex4 = RegExp(r'^[0-9a-f]{4}$');
final RegExp _hex8 = RegExp(r'^[0-9a-f]{8}$');
final RegExp _hex32 = RegExp(r'^[0-9a-f]{32}$');
final RegExp _dashed36 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// Normalizes a BLE UUID string into a canonical lowercase 128-bit dashed
/// form suitable for use as a cache/lookup key.
///
/// - Trims whitespace, strips surrounding `{}`, and lowercases the value.
/// - A 4-hex-char short form (e.g. `180f`) expands using the Bluetooth SIG
///   base UUID to `0000180f-0000-1000-8000-00805f9b34fb`.
/// - An 8-hex-char short form (e.g. `0000180f`) expands the same way.
/// - A 32-hex-char value with no dashes gets dashes inserted in 8-4-4-4-12
///   form.
/// - A well-formed dashed 36-char value is returned lowercased, unchanged
///   otherwise.
/// - Anything else is returned trimmed and lowercased as-is (never throws).
String normalizeUuid(String uuid) {
  var value = uuid.trim();
  if (value.startsWith('{') && value.endsWith('}')) {
    value = value.substring(1, value.length - 1);
  }
  value = value.toLowerCase();

  if (_hex4.hasMatch(value)) {
    return '0000$value-$_bluetoothSigBaseUuidSuffix';
  }
  if (_hex8.hasMatch(value)) {
    return '$value-$_bluetoothSigBaseUuidSuffix';
  }
  if (_hex32.hasMatch(value)) {
    return '${value.substring(0, 8)}-${value.substring(8, 12)}-'
        '${value.substring(12, 16)}-${value.substring(16, 20)}-'
        '${value.substring(20, 32)}';
  }
  if (_dashed36.hasMatch(value)) {
    return value;
  }
  return value;
}

/// Supported Omi audio codecs, keyed by the codec id sent over BLE.
///
/// See docs/05-omi-ble-protocol.md "Audio" for frame sizes and rates.
enum BleAudioCodec {
  pcm8(1),
  opus(20),
  opusFS320(21);

  final int codecId;
  const BleAudioCodec(this.codecId);

  int getFramesPerSecond() {
    switch (this) {
      case BleAudioCodec.pcm8:
        return 100;
      case BleAudioCodec.opus:
        return 100;
      case BleAudioCodec.opusFS320:
        return 50;
    }
  }

  int getFrameSize() {
    switch (this) {
      case BleAudioCodec.pcm8:
        return 160;
      case BleAudioCodec.opus:
        return 160;
      case BleAudioCodec.opusFS320:
        return 320;
    }
  }

  int getFramesLengthInBytes() {
    switch (this) {
      case BleAudioCodec.pcm8:
        return 160;
      case BleAudioCodec.opus:
        return 80;
      case BleAudioCodec.opusFS320:
        return 120;
    }
  }
}

/// Maps a raw codec id (as sent over the audio codec characteristic) to a
/// [BleAudioCodec], or `null` if the id is not recognized.
BleAudioCodec? codecFromId(int codecId) {
  switch (codecId) {
    case 1:
      return BleAudioCodec.pcm8;
    case 20:
      return BleAudioCodec.opus;
    case 21:
      return BleAudioCodec.opusFS320;
    default:
      return null;
  }
}

/// Minimum usable ATT MTU for streaming Omi audio notifications.
///
/// An Omi audio notification payload is 3 header bytes plus an 80-byte Opus
/// frame, i.e. 83 bytes. A BLE ATT notification carries `MTU - 3` bytes of
/// payload, so the negotiated MTU must be at least `83 + 3 = 86` bytes for a
/// full notification to fit in a single ATT packet.
const int minimumUsableMtu = 86;

/// Whether a negotiated ATT MTU is large enough to carry a full Omi audio
/// notification without fragmentation.
bool isMtuSufficient(int mtu) => mtu >= minimumUsableMtu;

/// Parses the storage read-control payload as consecutive signed int32
/// little-endian values, matching the on-device encoding used by
/// `getStorageList()`. A trailing partial group of fewer than 4 bytes is
/// ignored. Returns an empty list for empty input.
List<int> parseStorageList(List<int> raw) {
  final result = <int>[];
  final totalEntries = raw.length ~/ 4;
  for (var i = 0; i < totalEntries; i++) {
    final baseIndex = i * 4;
    final value = ((raw[baseIndex] |
                (raw[baseIndex + 1] << 8) |
                (raw[baseIndex + 2] << 16) |
                (raw[baseIndex + 3] << 24)) &
            0xFFFFFFFF)
        .toSigned(32);
    result.add(value);
  }
  return result;
}

/// Builds the 6-byte storage read-control command payload:
/// `[command, fileNumber, offset(4 bytes, big-endian)]`.
///
/// See docs/05-omi-ble-protocol.md "Storage (SD card) protocol".
List<int> buildStorageCommand({
  required int command,
  required int fileNumber,
  required int offset,
}) {
  return [
    command & 0xFF,
    fileNumber & 0xFF,
    (offset >> 24) & 0xFF,
    (offset >> 16) & 0xFF,
    (offset >> 8) & 0xFF,
    offset & 0xFF,
  ];
}

/// The single-byte "stop the current transfer" storage command (`0x03`).
///
/// Unlike [buildStorageCommand]'s 6-byte read/clear payload, upstream sends a
/// bare `0x03` for this one (*observed*); see docs/05-omi-ble-protocol.md
/// "Storage (SD card) protocol".
List<int> buildStorageStopCommand() => const [0x03];

/// Encodes a storage read-control command. This is the name used by the
/// LO-30 issue; it simply delegates to [buildStorageCommand] so there is a
/// single implementation of the encoding.
///
/// See docs/05-omi-ble-protocol.md "Storage (SD card) protocol".
List<int> encodeStorageCommand({
  required int command,
  required int fileNumber,
  required int offset,
}) =>
    buildStorageCommand(command: command, fileNumber: fileNumber, offset: offset);

/// One decoded Omi audio notification.
///
/// See docs/05-omi-ble-protocol.md "Audio" — the notification layout is
/// `[packetIndex lo][packetIndex hi][frameIndex][payload…]`.
class AudioPacket {
  /// Uint16 little-endian packet index. Omibutfree ignores this value;
  /// LibreOmi may use it to detect gaps as a BLE health metric.
  final int packetIndex;

  /// Single-byte frame index.
  final int frameIndex;

  /// The remaining bytes: one Opus frame (or PCM, depending on codec).
  final Uint8List payload;

  const AudioPacket({
    required this.packetIndex,
    required this.frameIndex,
    required this.payload,
  });
}

/// Strips the 3-byte Omi audio header from a raw BLE notification and
/// returns the parsed [AudioPacket], or `null` when the payload is too
/// short to contain a header (`raw.length <= 3`), matching today's
/// `_handleOmiAudioData` behaviour.
///
/// See docs/05-omi-ble-protocol.md "Audio".
AudioPacket? stripAudioHeader(List<int> raw) {
  if (raw.length <= 3) return null;
  final packetIndex = raw[0] | (raw[1] << 8);
  final frameIndex = raw[2];
  final payload = Uint8List.fromList(raw.sublist(3));
  return AudioPacket(
    packetIndex: packetIndex,
    frameIndex: frameIndex,
    payload: payload,
  );
}

/// Omi button events, decoded from the first 4 bytes of a button
/// notification. Values 1-5 are *observed* (see
/// docs/05-omi-ble-protocol.md "Button events"); anything else maps to
/// [unknown].
enum ButtonEvent {
  singleTap(1),
  doubleTap(2),
  longPressStart(3),
  singleTapRelease(4),
  longPressEnd(5),
  unknown(-1);

  final int code;
  const ButtonEvent(this.code);
}

/// Parses a button notification payload. Returns `null` when fewer than 4
/// bytes are available (matching today's `_handleButtonPress` guard);
/// otherwise reads the first 4 bytes as an unsigned little-endian uint32
/// and maps it to a [ButtonEvent], defaulting to [ButtonEvent.unknown] for
/// values outside 1-5.
///
/// The original app computed this via
/// `ByteData.view(Uint8List.fromList(data.sublist(0,4).reversed.toList()).buffer).getUint32(0)`,
/// which reverses the 4 bytes and reads them big-endian — exactly
/// equivalent to reading them directly as little-endian, which is what
/// this function does.
ButtonEvent? parseButtonEvent(List<int> raw) {
  if (raw.length < 4) return null;
  final bytes = Uint8List.fromList(raw.sublist(0, 4));
  final value = ByteData.sublistView(bytes).getUint32(0, Endian.little);
  switch (value) {
    case 1:
      return ButtonEvent.singleTap;
    case 2:
      return ButtonEvent.doubleTap;
    case 3:
      return ButtonEvent.longPressStart;
    case 4:
      return ButtonEvent.singleTapRelease;
    case 5:
      return ButtonEvent.longPressEnd;
    default:
      return ButtonEvent.unknown;
  }
}

/// Interpreted status of a 1-byte storage response, per
/// docs/05-omi-ble-protocol.md "Storage (SD card) protocol" (*observed*).
enum StorageStatus { ready, badFileSize, fileEmpty, transferComplete, error }

/// Discriminates the three storage response shapes documented in
/// docs/05-omi-ble-protocol.md "Storage (SD card) protocol".
enum StoragePacketKind { status, audioFrame, multiFrame, unknown }

/// A parsed storage-data-characteristic response.
///
/// Exactly one of [status]/[rawCode], [frame], or [frames] is populated,
/// selected by [kind]. Use [StoragePacketKind.unknown] for any length that
/// is not 1, 83, or 440 bytes.
class StoragePacket {
  final StoragePacketKind kind;

  /// Populated when [kind] is [StoragePacketKind.status].
  final StorageStatus? status;

  /// The raw single status byte, populated alongside [status].
  final int? rawCode;

  /// Populated when [kind] is [StoragePacketKind.audioFrame]: the single
  /// Opus frame extracted from an 83-byte packet.
  final Uint8List? frame;

  /// Populated when [kind] is [StoragePacketKind.multiFrame]: the Opus
  /// frames extracted from a 440-byte packet.
  final List<Uint8List>? frames;

  const StoragePacket._({
    required this.kind,
    this.status,
    this.rawCode,
    this.frame,
    this.frames,
  });

  const StoragePacket.statusPacket(StorageStatus status, int rawCode)
      : this._(kind: StoragePacketKind.status, status: status, rawCode: rawCode);

  const StoragePacket.audioFramePacket(Uint8List frame)
      : this._(kind: StoragePacketKind.audioFrame, frame: frame);

  const StoragePacket.multiFramePacket(List<Uint8List> frames)
      : this._(kind: StoragePacketKind.multiFrame, frames: frames);

  const StoragePacket.unknownPacket() : this._(kind: StoragePacketKind.unknown);
}

/// Parses a storage-data-characteristic response into a [StoragePacket].
///
/// See docs/05-omi-ble-protocol.md "Storage (SD card) protocol":
/// - 1-byte packets carry a status code: `0` ready, `3` bad file size,
///   `4` file empty, `100` transfer complete, anything else = error
///   (*observed*).
/// - 83-byte packets are `[hdr0][hdr1][hdr2][len][data(len)…]`, one Opus
///   frame (*observed*). **Deviation from upstream**: upstream does
///   `value.sublist(4, 4 + value[3])`, which throws a `RangeError` when
///   `value[3] > 79` (more bytes than are actually present). This parser
///   clamps the length to the bytes actually available instead of
///   throwing — a deliberate hardening decision for this pure parser.
/// - 440-byte packets are repeated `[len][data(len)]` records, with
///   `len == 0` treated as a single padding byte (*observed*). This parser
///   reproduces the upstream loop exactly, including its
///   `if (packageOffset + 1 + packageSize >= value.length) break;`
///   condition. That condition drops a trailing record that ends exactly
///   on the last byte of the packet — this is upstream-observed behaviour,
///   deliberately preserved here for a no-behaviour-change refactor.
///   Fixing it is deferred.
/// - Any other length yields [StoragePacketKind.unknown] rather than
///   throwing.
StoragePacket parseStoragePacket(List<int> raw) {
  if (raw.length == 1) {
    final code = raw[0];
    final StorageStatus status;
    switch (code) {
      case 0:
        status = StorageStatus.ready;
        break;
      case 3:
        status = StorageStatus.badFileSize;
        break;
      case 4:
        status = StorageStatus.fileEmpty;
        break;
      case 100:
        status = StorageStatus.transferComplete;
        break;
      default:
        status = StorageStatus.error;
    }
    return StoragePacket.statusPacket(status, code);
  }

  if (raw.length == 83) {
    final declaredLength = raw[3];
    final available = raw.length - 4;
    final length = declaredLength > available ? available : declaredLength;
    final frame = Uint8List.fromList(raw.sublist(4, 4 + length));
    return StoragePacket.audioFramePacket(frame);
  }

  if (raw.length == 440) {
    final frames = <Uint8List>[];
    var packageOffset = 0;
    while (packageOffset < raw.length - 1) {
      final packageSize = raw[packageOffset];
      if (packageSize == 0) {
        packageOffset++;
        continue;
      }
      if (packageOffset + 1 + packageSize >= raw.length) break;

      final frame = Uint8List.fromList(
        raw.sublist(packageOffset + 1, packageOffset + 1 + packageSize),
      );
      frames.add(frame);
      packageOffset += packageSize + 1;
    }
    return StoragePacket.multiFramePacket(frames);
  }

  return const StoragePacket.unknownPacket();
}

/// Decodes a Device Information Service characteristic value (Model,
/// Firmware, Hardware, Manufacturer — see docs/05-omi-ble-protocol.md "GATT
/// services and characteristics") as a UTF-8 string.
///
/// Decodes leniently (malformed bytes are replaced rather than throwing),
/// strips trailing NUL bytes, then trims surrounding whitespace. Returns
/// `''` for empty input.
///
/// `BleService` reads these characteristics with `String.fromCharCodes(val)`,
/// which is Latin-1-ish, keeps trailing NULs and does not trim. LO-31
/// repointed the one caller through `OmiBleDevice.readDeviceInfo()`, which
/// recovers the original bytes from that string's code units and re-decodes
/// them here — a deliberate behaviour change, not a pure move.
String decodeDeviceInfoString(List<int> raw) {
  if (raw.isEmpty) return '';
  var end = raw.length;
  while (end > 0 && raw[end - 1] == 0) {
    end--;
  }
  final trimmedBytes = raw.sublist(0, end);
  final decoded = utf8.decode(trimmedBytes, allowMalformed: true);
  return decoded.trim();
}
