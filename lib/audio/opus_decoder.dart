// The `lib/audio/` face of [OpusDecoderService].
//
// The service itself still lives under `lib/services/` and is expected to
// move into this directory in a later milestone (see docs/03-architecture.md
// §6); this wrapper lets `lib/audio/` code depend on the `OpusDecoder` name
// without reaching into `lib/services/` directly.
import 'dart:typed_data';

import '../services/opus_decoder_service.dart';

/// The `lib/audio/` face of [OpusDecoderService]; see the file comment above.
class OpusDecoder {
  OpusDecoder([OpusDecoderService? service])
      : _service = service ?? OpusDecoderService();

  final OpusDecoderService _service;

  bool get isInitialized => _service.isInitialized;

  Future<void> initialize() => _service.initialize();

  Uint8List? decode(Uint8List opus) => _service.decode(opus);

  void dispose() => _service.dispose();
}
