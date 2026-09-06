// [AudioSource] adapter over the raw BLE audio notification stream from an
// Omi device.
import 'dart:async';
import 'dart:typed_data';

import '../core/log.dart';
import '../device/omi_gatt.dart';
import 'audio_source.dart';

const _log = Log('Audio');

/// Turns raw Omi BLE audio packets into [AudioChunk]s.
///
/// This is a pure transform: it does not own [rawPackets] and never starts
/// or stops the device's audio notification stream itself — the caller is
/// responsible for that. It only strips the Omi audio header and wraps the
/// remaining bytes.
class OmiAudioSource implements AudioSource {
  OmiAudioSource(
    this._rawPackets, {
    this.encoding = AudioEncoding.opus,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// How many gap reports a single stream may log. A link that drops packets
  /// steadily would otherwise produce one line per notification at 50-100 Hz;
  /// see the same rationale in `BleService`'s packet-length logging.
  static const int maxGapLogs = 5;

  final Stream<Uint8List> _rawPackets;
  final AudioEncoding encoding;
  final DateTime Function() _now;

  StreamSubscription<Uint8List>? _subscription;
  StreamController<AudioChunk>? _controller;

  int _lastPacketIndex = -1;
  int _gapCount = 0;
  int _gapLogCount = 0;

  /// How many packet-index discontinuities were seen since [start].
  ///
  /// `docs/05-omi-ble-protocol.md` "Audio" asks LibreOmi to log gaps as a BLE
  /// health metric; this counter is the programmatic view of the same thing.
  int get gapCount => _gapCount;

  @override
  Stream<AudioChunk> start() {
    _lastPacketIndex = -1;
    _gapCount = 0;
    _gapLogCount = 0;

    // sync: true is required here: the callers this replaces (the
    // transcription service's addAudio/sendAudio calls) used to run
    // synchronously inside the BLE notification callback. Buffering the
    // emission through an async hop would let a button-event handler run
    // between a chunk's arrival and its delivery, reordering transcript
    // accumulation against button events.
    final controller = StreamController<AudioChunk>.broadcast(sync: true);
    _controller = controller;

    _subscription = _rawPackets.listen(
      (packet) {
        // `stripAudioHeader` returns null for the short packets the upstream
        // `_handleOmiAudioData` dropped (`length <= 3`), so the guard and the
        // parse are the same call.
        final parsed = stripAudioHeader(packet);
        if (parsed == null) return;
        _noteGap(parsed.packetIndex);
        controller.add(
          AudioChunk(bytes: parsed.payload, encoding: encoding, at: _now()),
        );
      },
      onError: controller.addError,
      onDone: controller.close,
    );

    return controller.stream;
  }

  /// Records a packet-index discontinuity. The index is a uint16 that wraps,
  /// so the successor of 65535 is 0 and is not a gap.
  void _noteGap(int packetIndex) {
    final previous = _lastPacketIndex;
    _lastPacketIndex = packetIndex;
    if (previous < 0) return;
    final expected = (previous + 1) & 0xFFFF;
    if (packetIndex == expected) return;
    _gapCount++;
    if (_gapLogCount < maxGapLogs) {
      _gapLogCount++;
      _log.d('audio packet gap: expected $expected, got $packetIndex '
          '(gaps=$_gapCount)');
    }
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _controller?.close();
    _controller = null;
  }
}
