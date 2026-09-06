// [AudioSource] adapter over the raw BLE audio notification stream from an
// Omi device.
import 'dart:async';
import 'dart:typed_data';

import 'audio_source.dart';

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

  final Stream<Uint8List> _rawPackets;
  final AudioEncoding encoding;
  final DateTime Function() _now;

  StreamSubscription<Uint8List>? _subscription;
  StreamController<AudioChunk>? _controller;

  @override
  Stream<AudioChunk> start() {
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
        // Omi device audio has a 3-byte header that needs to be trimmed.
        if (packet.length <= 3) return;
        // TODO(LO-31): use omi_gatt.stripAudioHeader once LO-31 lands.
        final trimmed = packet.sublist(3);
        controller.add(
          AudioChunk(bytes: trimmed, encoding: encoding, at: _now()),
        );
      },
      onError: controller.addError,
      onDone: controller.close,
    );

    return controller.stream;
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _controller?.close();
    _controller = null;
  }
}
