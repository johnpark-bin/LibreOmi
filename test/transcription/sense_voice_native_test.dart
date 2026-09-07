@Tags(['native'])
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/transcription/isolate_channel.dart';
import 'package:libreomi/transcription/model_catalog.dart';
import 'package:libreomi/transcription/offline_worker.dart';
import 'package:libreomi/transcription/vad.dart';

/// LO-71's acceptance question is narrower than LO-42's: not "where are the
/// cuts", which `offline_worker_native_test.dart` already answers for this
/// worker, but "does the generalized worker actually load and decode a
/// SenseVoice model, and does one model really transcribe Korean and English
/// in the same session". Only a real model can answer that, and CI has none,
/// so this file registers a skipped placeholder unless the environment
/// variables below are set:
///
/// ```bash
/// SHERPA_SENSE_VOICE_DIR=<dir with model.int8.onnx, tokens.txt, test_wavs/> \
/// SHERPA_VAD_MODEL=<path to silero_vad.onnx> \
/// SHERPA_NATIVE_DIR=~/.pub-cache/hosted/pub.dev/sherpa_onnx_macos-<v>/macos \
///   mise exec -- flutter test test/transcription/sense_voice_native_test.dart
/// ```
///
/// The signal is built rather than recorded: the model ships `test_wavs/ko.wav`
/// and `test_wavs/en.wav`, and this pastes them into silence at known offsets,
/// so a Korean and an English utterance reach the recognizer as two separate
/// VAD segments in one session.
const int _sampleRate = 16000;

/// Silence around each clip. Comfortably longer than
/// `VadConfig.minSilenceDuration` (0.5 s), so the detector closes a segment
/// between the two clips rather than running them together.
const double _gapSeconds = 1.5;

/// Extracts the PCM16 samples of a canonical WAV file's `data` chunk without
/// adding a WAV-parsing dependency. Same scan as `offline_worker_native_test`.
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

/// [clips] laid out in silence, one gap between each and at both ends.
Uint8List _buildStream(List<Uint8List> clips) {
  final builder = BytesBuilder();
  void addSilence() =>
      builder.add(Uint8List((_gapSeconds * _sampleRate).round() * 2));

  addSilence();
  for (final clip in clips) {
    builder.add(clip);
    addSilence();
  }
  return builder.takeBytes();
}

/// Opens the desktop onnxruntime before anything loads the sherpa C API that
/// depends on it — the same @rpath dance the other native tests do.
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

void main() {
  final modelDir = Platform.environment['SHERPA_SENSE_VOICE_DIR'];
  final vadModel = Platform.environment['SHERPA_VAD_MODEL'];
  final nativeDir = Platform.environment['SHERPA_NATIVE_DIR'];

  if (modelDir == null ||
      !Directory(modelDir).existsSync() ||
      vadModel == null ||
      !File(vadModel).existsSync()) {
    test('SenseVoice + silero VAD native run (skipped)', () {},
        skip: 'SHERPA_SENSE_VOICE_DIR and SHERPA_VAD_MODEL are not both set '
            'to existing paths; set them to run this test locally '
            '(see LO-71).');
    return;
  }

  test('one SenseVoice model decodes Korean and English in one session',
      () async {
    if (nativeDir != null) _preloadOnnxRuntime(nativeDir);

    final clips = <Uint8List>[];
    for (final name in ['ko.wav', 'en.wav']) {
      final wav = File('$modelDir/test_wavs/$name');
      expect(wav.existsSync(), isTrue,
          reason: 'expected test wav at ${wav.path}');
      clips.add(_readWavPcm16(wav));
    }
    final pcm16 = _buildStream(clips);

    final channel = await IsolateChannel.spawn(
      offlineWorkerMain,
      debugName: 'sense-voice-native-test',
    );
    final events = <Object?>[];
    final sub = channel.events.listen(events.add);

    // `language: ''` on purpose: ModelCatalog.senseVoiceLanguage turns that
    // into SenseVoice's own 'auto', which is the setting the Korean and
    // English halves of this stream both have to survive.
    await channel.request(OfflineInitCommand(OfflineWorkerConfig(
      model: ModelCatalog.senseVoice,
      modelDir: modelDir,
      vad: VadConfig(modelPath: vadModel, nativeLibraryDir: nativeDir),
      nativeLibraryDir: nativeDir,
    )));

    // 100 ms of 16 kHz mono PCM16 per chunk, the same shape the Omi path
    // delivers.
    const chunkBytes = 3200;
    final start = DateTime.now();
    var offset = 0;
    var at = start;
    while (offset < pcm16.length) {
      final end = (offset + chunkBytes).clamp(0, pcm16.length);
      final chunk = pcm16.sublist(offset, end);
      channel.notify(OfflineFeedCommand(
        TransferableTypedData.fromList(<Uint8List>[chunk]),
        at,
      ));
      at = at.add(Duration(
        microseconds: (chunk.length ~/ 2) *
            Duration.microsecondsPerSecond ~/
            _sampleRate,
      ));
      offset = end;
      // Let the worker drain notifications between chunks.
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }

    await channel.request(const OfflineStopCommand());
    await channel.close();
    await sub.cancel();

    final errors = events.whereType<IsolateWorkerError>().toList();
    expect(errors, isEmpty, reason: 'unexpected worker errors: $errors');

    final segments = events.whereType<OfflineSegmentEvent>().toList();
    for (final segment in segments) {
      // ignore: avoid_print
      print('  [${segment.startTime.toStringAsFixed(2)}, '
          '${segment.endTime.toStringAsFixed(2)}] ${segment.text}');
    }

    // Two clips separated by more than the VAD's minimum silence: at least
    // one segment each, and timestamps that describe the same instants the
    // Whisper path's do.
    expect(segments.length, greaterThanOrEqualTo(2));
    for (final segment in segments) {
      expect(segment.text.trim(), isNotEmpty);
      expect(segment.endTime, greaterThan(segment.startTime));
      expect(segment.endAt.isBefore(segment.startAt), isFalse);
      expect(
        segment.startAt.difference(start).inMilliseconds,
        closeTo(segment.startTime * 1000, 2),
      );
    }

    final all = segments.map((s) => s.text).join(' ');
    // The clips are fixed, so this is deterministic. Hangul in the first and
    // Latin script in the second is the actual claim being tested: one
    // offline model transcribing both, which no Whisper entry in the catalog
    // does without being pinned to a language first.
    expect(all, matches(RegExp(r'[가-힣]')),
        reason: 'no Hangul decoded from ko.wav: $all');
    expect(all, matches(RegExp(r'[A-Za-z]{3,}')),
        reason: 'no Latin words decoded from en.wav: $all');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
