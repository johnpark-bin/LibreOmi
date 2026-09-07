@Tags(['native'])
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/transcription/isolate_channel.dart';
import 'package:libreomi/transcription/vad.dart';
import 'package:libreomi/transcription/model_catalog.dart';
import 'package:libreomi/transcription/offline_worker.dart';

/// The acceptance criterion for LO-42 is "no mid-word cuts on a 2-minute
/// test", which only a real Silero VAD driving a real Whisper decode can
/// demonstrate. CI has neither model, so this file registers a skipped
/// placeholder unless the three environment variables below are set:
///
/// ```bash
/// SHERPA_WHISPER_DIR=<dir with tiny-encoder.onnx, tiny-decoder.onnx, tiny-tokens.txt> \
/// SHERPA_VAD_MODEL=<path to silero_vad.onnx> \
/// SHERPA_NATIVE_DIR=~/.pub-cache/hosted/pub.dev/sherpa_onnx_macos-<v>/macos \
///   mise exec -- flutter test test/transcription/whisper_native_test.dart
/// ```
///
/// The signal is built rather than recorded: the model's own `test_wavs/0.wav`
/// (6.6 s of speech) is pasted into two minutes of silence at known offsets,
/// so the test knows exactly where every word is. That is what makes "no
/// mid-word cut" checkable — a segment that straddles one of those known
/// boundaries cut through speech, and a fixed 3-second timer would produce
/// nothing but such segments.
const int _sampleRate = 16000;

/// Silence between one speech block and the next. Comfortably longer than
/// `VadConfig.minSilenceDuration` (0.5 s), so the detector is meant to close
/// a segment in every gap.
const double _gapSeconds = 1.5;

/// Silence before the first block, so the stream does not open mid-speech.
const double _leadInSeconds = 1.0;

/// How much slack a segment edge gets against the speech block it belongs
/// to. The VAD trims leading and trailing silence and needs
/// `minSilenceDuration` of quiet before it closes, so an edge lands near the
/// block boundary rather than exactly on it.
const double _edgeToleranceSeconds = 0.75;

/// One block of speech in the synthetic stream.
class _SpeechBlock {
  const _SpeechBlock(this.startSeconds, this.endSeconds);
  final double startSeconds;
  final double endSeconds;

  bool contains(double seconds) =>
      seconds >= startSeconds && seconds <= endSeconds;
}

/// Extracts the PCM16 samples of a canonical WAV file's `data` chunk without
/// adding a WAV-parsing dependency. Same scan as `sherpa_native_test.dart`.
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

/// The two-minute stream, plus where its speech actually is.
class _SyntheticStream {
  const _SyntheticStream(this.pcm16, this.blocks);
  final Uint8List pcm16;
  final List<_SpeechBlock> blocks;

  double get durationSeconds => pcm16.length / 2 / _sampleRate;
}

/// Repeats [speech] into at least [minimumSeconds] of audio, separated by
/// silence, and records the offset of every block it wrote.
_SyntheticStream _buildStream(Uint8List speech, double minimumSeconds) {
  final builder = BytesBuilder();
  final blocks = <_SpeechBlock>[];

  void addSilence(double seconds) {
    builder.add(Uint8List((seconds * _sampleRate).round() * 2));
  }

  final speechSeconds = speech.length / 2 / _sampleRate;
  addSilence(_leadInSeconds);
  var cursor = _leadInSeconds;
  while (cursor < minimumSeconds) {
    blocks.add(_SpeechBlock(cursor, cursor + speechSeconds));
    builder.add(speech);
    cursor += speechSeconds;
    addSilence(_gapSeconds);
    cursor += _gapSeconds;
  }

  return _SyntheticStream(builder.takeBytes(), blocks);
}

/// Opens the desktop onnxruntime before anything loads the sherpa C API that
/// depends on it — the same @rpath dance `sherpa_native_test.dart` does.
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
  final whisperDir = Platform.environment['SHERPA_WHISPER_DIR'];
  final vadModel = Platform.environment['SHERPA_VAD_MODEL'];
  final nativeDir = Platform.environment['SHERPA_NATIVE_DIR'];

  if (whisperDir == null ||
      !Directory(whisperDir).existsSync() ||
      vadModel == null ||
      !File(vadModel).existsSync()) {
    test('whisper + silero VAD native run (skipped)', () {},
        skip: 'SHERPA_WHISPER_DIR and SHERPA_VAD_MODEL are not both set to '
            'existing paths; set them to run this test locally (see LO-42).');
    return;
  }

  test('two minutes of speech-in-silence is cut on silence, not on a clock',
      () async {
    if (nativeDir != null) _preloadOnnxRuntime(nativeDir);

    final wavFile = File('$whisperDir/test_wavs/0.wav');
    expect(wavFile.existsSync(), isTrue,
        reason: 'expected test wav at ${wavFile.path}');
    final stream = _buildStream(_readWavPcm16(wavFile), 118);
    expect(stream.durationSeconds, greaterThan(115),
        reason: 'the acceptance criterion is a two-minute test');

    final channel = await IsolateChannel.spawn(
      offlineWorkerMain,
      debugName: 'offline-native-test',
    );
    final events = <Object?>[];
    final sub = channel.events.listen(events.add);

    await channel.request(OfflineInitCommand(OfflineWorkerConfig(
      model: ModelCatalog.whisperTiny,
      modelDir: whisperDir,
      vad: VadConfig(modelPath: vadModel, nativeLibraryDir: nativeDir),
      nativeLibraryDir: nativeDir,
    )));

    // 100 ms of 16 kHz mono PCM16 per chunk, the same shape the Omi path
    // delivers.
    const chunkBytes = 3200;
    final start = DateTime.now();
    var offset = 0;
    var at = start;
    while (offset < stream.pcm16.length) {
      final end = (offset + chunkBytes).clamp(0, stream.pcm16.length);
      final chunk = stream.pcm16.sublist(offset, end);
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
    // ignore: avoid_print
    print('blocks=${stream.blocks.length} segments=${segments.length} '
        'duration=${stream.durationSeconds.toStringAsFixed(1)}s');
    for (final segment in segments) {
      // ignore: avoid_print
      print('  [${segment.startTime.toStringAsFixed(2)}, '
          '${segment.endTime.toStringAsFixed(2)}] ${segment.text}');
    }

    expect(segments, isNotEmpty);
    // At least one segment per block of speech, and no more than three: the
    // detector may close inside a block at a natural pause, but a run of
    // short segments would mean it is cutting on something other than
    // speech. A fixed 3-second timer over this stream would produce ~39.
    expect(segments.length, greaterThanOrEqualTo(stream.blocks.length));
    expect(segments.length, lessThanOrEqualTo(stream.blocks.length * 3));

    for (final segment in segments) {
      // The clip is fixed, so this is deterministic: a segment that decoded
      // a fragment of the sentence rather than the whole utterance would
      // not carry the word that opens it.
      expect(segment.text.toLowerCase(), contains('nightfall'),
          reason: 'segment did not decode the whole utterance: '
              '${segment.text}');
      expect(segment.endTime, greaterThan(segment.startTime));
      expect(segment.endAt.isBefore(segment.startAt), isFalse);
      // Wall clock and relative seconds must describe the same instant.
      expect(
        segment.startAt.difference(start).inMilliseconds,
        closeTo(segment.startTime * 1000, 2),
      );
    }

    // Segments arrive in order and never overlap.
    for (var i = 1; i < segments.length; i++) {
      expect(segments[i].startTime,
          greaterThanOrEqualTo(segments[i - 1].endTime - 0.001));
    }

    // The heart of the acceptance criterion. Every segment must sit inside
    // one known block of speech: it may start late or end early (the VAD
    // trims silence), but it must not run past a block edge into the
    // silence beyond it, which is what a segment that cut a word in half
    // and carried on into the next utterance would look like.
    for (final segment in segments) {
      final midpoint = (segment.startTime + segment.endTime) / 2;
      final block = stream.blocks.where((b) => b.contains(midpoint)).toList();
      expect(block, hasLength(1),
          reason: 'segment [${segment.startTime}, ${segment.endTime}] has its '
              'midpoint in silence, so it spans a gap between utterances');
      expect(segment.startTime,
          greaterThan(block.single.startSeconds - _edgeToleranceSeconds),
          reason: 'segment starts before its block: ${segment.text}');
      expect(segment.endTime,
          lessThan(block.single.endSeconds + _edgeToleranceSeconds),
          reason: 'segment ends after its block: ${segment.text}');
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
