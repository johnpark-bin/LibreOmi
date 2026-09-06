/// A replay-driven [OmiDevice] used by tests (and manual debugging without
/// hardware).
///
/// Reads the JSONL fixture format documented in `test/fixtures/README.md` and
/// replays it through the same streams a real device exposes, so code above
/// `device/` cannot tell the difference. See `lib/device/omi_ble_device.dart`
/// for the real adapter this stands in for.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'omi_device.dart';
import 'omi_gatt.dart';
import 'omi_storage.dart';

/// Which BLE notification channel a [CapturedEvent] came from.
///
/// Mirrors the `"ch"` field of a fixture line (`test/fixtures/README.md`).
enum CaptureChannel { audio, button, battery, storage }

String _channelName(CaptureChannel channel) {
  switch (channel) {
    case CaptureChannel.audio:
      return 'audio';
    case CaptureChannel.button:
      return 'button';
    case CaptureChannel.battery:
      return 'battery';
    case CaptureChannel.storage:
      return 'storage';
  }
}

CaptureChannel? _channelFromName(String name) {
  switch (name) {
    case 'audio':
      return CaptureChannel.audio;
    case 'button':
      return CaptureChannel.button;
    case 'battery':
      return CaptureChannel.battery;
    case 'storage':
      return CaptureChannel.storage;
    default:
      return null;
  }
}

/// One recorded BLE notification: when it arrived (relative to the start of
/// the session), which channel it came from, and its raw bytes (header
/// included, exactly as the device sent them).
class CapturedEvent {
  const CapturedEvent({
    required this.timeMs,
    required this.channel,
    required this.bytes,
  });

  final int timeMs;
  final CaptureChannel channel;
  final Uint8List bytes;
}

/// Encodes one [CapturedEvent] as a single JSONL line, per
/// `test/fixtures/README.md`.
///
/// This is the single place that knows the on-disk line shape; both
/// [FakeOmiDevice.fromJsonl] and `JsonlBleSessionCapture`
/// (`ble_session_capture.dart`) go through this pair of functions so the
/// encode and decode never drift apart.
String encodeCaptureLine(CapturedEvent event) {
  final map = {
    't': event.timeMs,
    'ch': _channelName(event.channel),
    'b': base64Encode(event.bytes),
  };
  return jsonEncode(map);
}

/// Decodes one JSONL line into a [CapturedEvent]. Returns `null` for a blank
/// line or a line that fails to parse in any way (malformed JSON, missing or
/// wrong-typed field, unknown channel, invalid base64) — callers are expected
/// to skip rather than fail, since a capture killed mid-write must still
/// replay everything captured before the truncated line.
CapturedEvent? decodeCaptureLine(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return null;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) return null;
    final t = decoded['t'];
    final ch = decoded['ch'];
    final b = decoded['b'];
    if (t is! int || ch is! String || b is! String) return null;
    final channel = _channelFromName(ch);
    if (channel == null) return null;
    final bytes = base64Decode(b);
    return CapturedEvent(timeMs: t, channel: channel, bytes: bytes);
  } catch (_) {
    return null;
  }
}

/// A fake [OmiStorage] that replays the `storage` channel of a
/// [FakeOmiDevice]'s fixture. Constructed by [FakeOmiDevice], not directly.
class FakeOmiStorage implements OmiStorage {
  FakeOmiStorage({
    List<int> listResult = const [],
  }) : _listResult = listResult;

  final List<int> _listResult;

  final StreamController<List<int>> _rawPacketsController =
      StreamController<List<int>>.broadcast(sync: true);
  final StreamController<StoragePacket> _packetsController =
      StreamController<StoragePacket>.broadcast(sync: true);

  bool _streaming = false;

  /// Arguments passed to [startRead], recorded for assertions.
  final List<({int offset, int fileNumber})> startReadCalls = [];

  /// Arguments passed to [clear], recorded for assertions.
  final List<int> clearFileNumbers = [];

  /// Number of [stopRead] calls, recorded for assertions.
  int stopReadCalls = 0;

  @override
  Stream<List<int>> get rawPackets => _rawPacketsController.stream;

  @override
  Stream<StoragePacket> get packets => _packetsController.stream;

  @override
  Future<List<int>> list() async => _listResult;

  @override
  Future<void> startStream() async {
    _streaming = true;
  }

  @override
  Future<void> stopStream() async {
    _streaming = false;
  }

  @override
  Future<bool> startRead(int offset, {int fileNumber = 1}) async {
    startReadCalls.add((offset: offset, fileNumber: fileNumber));
    return true;
  }

  @override
  Future<bool> stopRead() async {
    stopReadCalls++;
    return true;
  }

  @override
  Future<bool> clear({int fileNumber = 1}) async {
    clearFileNumbers.add(fileNumber);
    return true;
  }

  /// Emits [bytes] on [rawPackets]/[packets] as though it just arrived over
  /// BLE, if [startStream] has been called. Used internally by
  /// [FakeOmiDevice.replay].
  void _deliver(Uint8List bytes) {
    if (!_streaming) return;
    _rawPacketsController.add(bytes);
    _packetsController.add(parseStoragePacket(bytes));
  }
}

/// A replay-driven [OmiDevice].
///
/// Construct with [FakeOmiDevice.fromJsonl] (from fixture text) or the plain
/// constructor (from an already-parsed event list), then call [replay] to
/// push the recorded notifications through the device's streams.
class FakeOmiDevice implements OmiDevice {
  FakeOmiDevice(
    this.events, {
    this.id = 'fake-omi-device',
    this.name = 'Fake Omi',
    BleAudioCodec codec = BleAudioCodec.opus,
    DeviceInfo deviceInfo = const DeviceInfo(),
    int? batteryLevel,
    int? micGain = 100,
    int? ledDim = 50,
    List<int> storageList = const [],
  })  : _codec = codec,
        _deviceInfo = deviceInfo,
        _batteryReadValue = batteryLevel,
        _micGain = micGain,
        _ledDim = ledDim,
        storage = FakeOmiStorage(listResult: storageList);

  /// Parses [source] (JSONL text, per `test/fixtures/README.md`) into a
  /// [FakeOmiDevice]. Malformed and blank lines are skipped; see
  /// [decodeCaptureLine].
  factory FakeOmiDevice.fromJsonl(
    String source, {
    String id = 'fake-omi-device',
    String name = 'Fake Omi',
    BleAudioCodec codec = BleAudioCodec.opus,
    DeviceInfo deviceInfo = const DeviceInfo(),
    int? batteryLevel,
    int? micGain = 100,
    int? ledDim = 50,
    List<int> storageList = const [],
  }) {
    final events = <CapturedEvent>[];
    for (final line in const LineSplitter().convert(source)) {
      final event = decodeCaptureLine(line);
      if (event != null) events.add(event);
    }
    return FakeOmiDevice(
      events,
      id: id,
      name: name,
      codec: codec,
      deviceInfo: deviceInfo,
      batteryLevel: batteryLevel,
      micGain: micGain,
      ledDim: ledDim,
      storageList: storageList,
    );
  }

  /// The parsed fixture, in file order.
  final List<CapturedEvent> events;

  @override
  final String id;

  @override
  final String name;

  final BleAudioCodec _codec;
  final DeviceInfo _deviceInfo;
  final int? _batteryReadValue;
  final int? _micGain;
  final int? _ledDim;

  @override
  final FakeOmiStorage storage;

  final StreamController<DeviceConnectionState> _connectionStateController =
      StreamController<DeviceConnectionState>.broadcast(sync: true);
  final StreamController<Uint8List> _audioPacketsController =
      StreamController<Uint8List>.broadcast(sync: true);
  final StreamController<ButtonEvent> _buttonEventsController =
      StreamController<ButtonEvent>.broadcast(sync: true);
  final StreamController<int> _batteryLevelController =
      StreamController<int>.broadcast(sync: true);

  DeviceConnectionState _state = DeviceConnectionState.disconnected;
  bool _audioStreaming = false;

  /// Recorded [writeMicGain] calls, in order.
  final List<int> micGainWrites = [];

  /// Recorded [writeLedDim] calls, in order.
  final List<int> ledDimWrites = [];

  /// Recorded [haptic] calls, in order.
  final List<HapticLevel> haptics = [];

  @override
  DeviceConnectionState get state => _state;

  @override
  Stream<DeviceConnectionState> get connectionState =>
      _connectionStateController.stream;

  @override
  Stream<Uint8List> get audioPackets => _audioPacketsController.stream;

  @override
  Stream<ButtonEvent> get buttonEvents => _buttonEventsController.stream;

  @override
  Stream<int> get batteryLevel => _batteryLevelController.stream;

  /// Moves [state] to [DeviceConnectionState.connected] and emits on
  /// [connectionState]. Not part of [OmiDevice] — a fixture-only convenience,
  /// mirroring what a real connect flow would do before replay starts.
  Future<void> connect() async {
    _state = DeviceConnectionState.connected;
    _connectionStateController.add(_state);
  }

  @override
  Future<void> startAudioStream() async {
    _audioStreaming = true;
  }

  @override
  Future<void> stopAudioStream() async {
    _audioStreaming = false;
  }

  /// Replays every event in [events] through the device's streams.
  ///
  /// By default, events are emitted eagerly and deterministically — as fast
  /// as stream consumers accept them, with no timers — so tests stay fast and
  /// reproducible. With `realTime: true`, each event is instead emitted after
  /// a timer delay matching its `t` value (relative to the first event),
  /// which is useful for manually driving the app against a fixture at a
  /// believable pace.
  ///
  /// Audio events are dropped unless [startAudioStream] has already been
  /// called (mirroring a real device, which only sends audio notifications
  /// while subscribed); button, battery, and storage events are always
  /// delivered regardless of the audio-stream gate.
  Future<void> replay({bool realTime = false}) async {
    var previousTimeMs = events.isEmpty ? 0 : events.first.timeMs;
    for (final event in events) {
      if (realTime) {
        final delay = event.timeMs - previousTimeMs;
        if (delay > 0) {
          await Future<void>.delayed(Duration(milliseconds: delay));
        }
        previousTimeMs = event.timeMs;
      }
      _deliver(event);
    }
  }

  /// Delivers one notification immediately, outside of a fixture replay.
  ///
  /// Lets a test drive the device's streams event by event without having to
  /// build a fixture first; [replay] routes through the same path.
  void emit(CaptureChannel channel, Uint8List bytes, {int timeMs = 0}) {
    _deliver(CapturedEvent(timeMs: timeMs, channel: channel, bytes: bytes));
  }

  void _deliver(CapturedEvent event) {
    switch (event.channel) {
      case CaptureChannel.audio:
        if (!_audioStreaming) return;
        _audioPacketsController.add(event.bytes);
        break;
      case CaptureChannel.button:
        final decoded = parseButtonEvent(event.bytes);
        if (decoded != null) _buttonEventsController.add(decoded);
        break;
      case CaptureChannel.battery:
        if (event.bytes.isEmpty) return;
        _batteryLevelController.add(event.bytes.first);
        break;
      case CaptureChannel.storage:
        storage._deliver(event.bytes);
        break;
    }
  }

  @override
  Future<BleAudioCodec> readCodec() async => _codec;

  @override
  Future<DeviceInfo> readDeviceInfo() async => _deviceInfo;

  @override
  Future<int?> readBatteryLevel() async {
    final value = _batteryReadValue;
    if (value != null) _batteryLevelController.add(value);
    return value;
  }

  @override
  Future<int?> readMicGain() async => _micGain;

  @override
  Future<void> writeMicGain(int value) async {
    micGainWrites.add(value);
  }

  @override
  Future<int?> readLedDim() async => _ledDim;

  @override
  Future<void> writeLedDim(int value) async {
    ledDimWrites.add(value);
  }

  @override
  Future<void> haptic(HapticLevel level) async {
    haptics.add(level);
  }

  @override
  Future<void> disconnect() async {
    _state = DeviceConnectionState.disconnected;
    _connectionStateController.add(_state);
  }
}
