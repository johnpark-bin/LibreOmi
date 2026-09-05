/// Pure-Dart Omi BLE protocol constants and helpers.
///
/// This file intentionally has no dependency on `package:flutter_blue_plus`
/// so it can be unit tested without a BLE stack or a Flutter widget test
/// harness. See docs/05-omi-ble-protocol.md for the protocol reference.
library;

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
