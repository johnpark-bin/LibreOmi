@Tags(['native'])
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/audio/wav.dart';
import 'package:libreomi/transcription/offline_file_transcriber.dart';

/// Exercises the real Whisper + Silero VAD decode over a real WAV file, the
/// same env-var gate `whisper_native_test.dart` uses for LO-42. CI has none
/// of the three models, so this file registers a skipped placeholder unless
/// all three environment variables below are set:
///
/// ```bash
/// SHERPA_WHISPER_DIR=<dir with tiny-encoder.onnx, tiny-decoder.onnx, tiny-tokens.txt> \
/// SHERPA_VAD_MODEL=<path to silero_vad.onnx> \
/// SHERPA_NATIVE_DIR=~/.pub-cache/hosted/pub.dev/sherpa_onnx_macos-<v>/macos \
/// SHERPA_WHISPER_TEST_WAV=<path to a real speech WAV, 16kHz mono PCM16> \
///   mise exec -- flutter test test/transcription/offline_file_transcriber_native_test.dart
/// ```
///
/// [SHERPA_WHISPER_TEST_WAV] is pasted into a couple of seconds of silence at
/// known offsets — same construction as `whisper_native_test.dart` — so the
/// synthetic file this test writes is not silence-only (which would legally
/// decode to zero segments and prove nothing).
const int _sampleRate = 16000;

void main() {
  final whisperDir = Platform.environment['SHERPA_WHISPER_DIR'];
  final vadModel = Platform.environment['SHERPA_VAD_MODEL'];
  final nativeDir = Platform.environment['SHERPA_NATIVE_DIR'];
  final testWavPath = Platform.environment['SHERPA_WHISPER_TEST_WAV'];

  if (whisperDir == null ||
      !Directory(whisperDir).existsSync() ||
      vadModel == null ||
      !File(vadModel).existsSync() ||
      testWavPath == null ||
      !File(testWavPath).existsSync()) {
    test('offline file transcriber native run (skipped)', () {},
        skip: 'SHERPA_WHISPER_DIR, SHERPA_VAD_MODEL and '
            'SHERPA_WHISPER_TEST_WAV are not all set to existing paths; set '
            'them to run this test locally (see LO-51).');
    return;
  }

  test('a real WAV decodes to at least one non-empty, time-ordered segment',
      () async {
    if (nativeDir != null) _preloadOnnxRuntime(nativeDir);

    final speech = _readWavPcm16(File(testWavPath));

    // 1 s lead-in silence, the speech clip, 1 s trailing silence: enough
    // quiet on both sides for the VAD to close a segment around the speech
    // without the file being silence-only.
    final silence = Uint8List(_sampleRate * 2); // 1 second, 16-bit mono
    final builder = BytesBuilder();
    builder.add(silence);
    builder.add(speech);
    builder.add(silence);
    final pcm = builder.takeBytes();

    final tempDir = Directory.systemTemp.createTempSync('offline_file_transcriber_native');
    final wavFile = File('${tempDir.path}/input.wav');
    try {
      wavFile.writeAsBytesSync(buildWav(pcm));

      final transcriber = OfflineFileTranscriber(
        modelDir: whisperDir,
        vadModelPath: vadModel,
        nativeLibraryDir: nativeDir,
      );

      final segments = await transcriber.transcribe(wavFile);

      expect(segments, isNotEmpty);
      for (final segment in segments) {
        expect(segment.text.trim(), isNotEmpty);
      }
      for (var i = 1; i < segments.length; i++) {
        expect(segments[i].startTime,
            greaterThanOrEqualTo(segments[i - 1].startTime));
      }
    } finally {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// Extracts the PCM16 samples of a canonical WAV file's `data` chunk without
/// depending on `parseWav` (this test exercises the app end-to-end, so it
/// reads its input WAV independently). Same scan as `whisper_native_test.dart`.
Uint8List _readWavPcm16(File file) {
  final bytes = file.readAsBytesSync();
  for (var i = 12; i + 8 <= bytes.length; i++) {
    if (bytes[i] == 0x64 && // 'd'
        bytes[i + 1] == 0x61 && // 'a'
        bytes[i + 2] == 0x74 && // 't'
        bytes[i + 3] == 0x61) {
      // 'a'
      final sizeOffset = i + 4;
      final size = ByteData.sublistView(bytes, sizeOffset, sizeOffset + 4)
          .getUint32(0, Endian.little);
      final dataStart = sizeOffset + 4;
      final dataEnd = (dataStart + size).clamp(0, bytes.length);
      return bytes.sublist(dataStart, dataEnd);
    }
  }
  throw StateError('no data chunk found in ${file.path}');
}

/// Opens the desktop onnxruntime before anything loads the sherpa C API that
/// depends on it — the same @rpath dance `whisper_native_test.dart` does.
void _preloadOnnxRuntime(String nativeDir) {
  final onnxruntime = Directory(nativeDir)
      .listSync()
      .whereType<File>()
      .map((f) => f.path)
      .where((path) =>
          path.split('/').last.startsWith('libonnxruntime') &&
          (path.endsWith('.dylib') || path.endsWith('.so')))
      .toList();
  expect(onnxruntime, isNotEmpty, reason: 'no libonnxruntime in $nativeDir');
  DynamicLibrary.open(onnxruntime.first);
}
