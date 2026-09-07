@Tags(['native'])
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/audio/audio_source.dart';
import 'package:libreomi/core/models.dart';
import 'package:libreomi/transcription/isolate_channel.dart';
import 'package:libreomi/transcription/sherpa_streaming.dart';
import 'package:libreomi/transcription/sherpa_worker.dart';

/// Extracts the PCM16 samples of the `data` chunk of a canonical WAV file,
/// without adding a WAV-parsing dependency: scans for the 'data' fourcc and
/// returns everything after its 4-byte size field.
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

void main() {
  final modelDir = Platform.environment['SHERPA_MODEL_DIR'];
  final nativeDir = Platform.environment['SHERPA_NATIVE_DIR'];

  if (modelDir == null || !Directory(modelDir).existsSync()) {
    test('sherpa native recognition (skipped)', () {}, skip: 'SHERPA_MODEL_DIR '
        'is not set or does not exist; set it to run this test locally '
        '(see docs for LO-41).');
    return;
  }

  test('sherpa worker recognizes 0.wav end to end', () async {
    // The onnxruntime shared library carries an @rpath dependency that only
    // resolves once it has been opened directly, before the sherpa-onnx C
    // API library that depends on it is loaded inside the worker isolate.
    if (nativeDir != null) {
      final onnxruntime = Directory(nativeDir)
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((path) =>
              path.split('/').last.startsWith('libonnxruntime') &&
              (path.endsWith('.dylib') || path.endsWith('.so')))
          .toList();
      expect(onnxruntime, isNotEmpty,
          reason: 'no libonnxruntime in $nativeDir');
      DynamicLibrary.open(onnxruntime.first);
    }

    final wavFile = File('$modelDir/test_wavs/0.wav');
    expect(wavFile.existsSync(), isTrue,
        reason: 'expected test wav at ${wavFile.path}');
    final pcm16 = _readWavPcm16(wavFile);

    final channel = await IsolateChannel.spawn(
      sherpaWorkerMain,
      debugName: 'sherpa-native-test',
    );

    final events = <Object?>[];
    final sub = channel.events.listen(events.add);

    await channel.request(SherpaInitCommand(SherpaWorkerConfig(
      modelDir: modelDir,
      nativeLibraryDir: nativeDir,
    )));

    // 16 kHz mono PCM16: 100ms = 1600 samples = 3200 bytes.
    const chunkBytes = 3200;
    const sampleRate = 16000;
    var offset = 0;
    var at = DateTime.now();
    while (offset < pcm16.length) {
      final end = (offset + chunkBytes).clamp(0, pcm16.length);
      final chunk = pcm16.sublist(offset, end);
      channel.notify(SherpaFeedCommand(
        TransferableTypedData.fromList(<Uint8List>[chunk]),
        at,
      ));
      final chunkSamples = chunk.length ~/ 2;
      at = at.add(Duration(
        microseconds:
            (chunkSamples * Duration.microsecondsPerSecond / sampleRate)
                .round(),
      ));
      offset = end;
      // Give the worker a chance to drain notifications between chunks.
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    await channel.request(const SherpaStopCommand());
    await channel.close();
    await sub.cancel();

    final errorEvents = events.whereType<IsolateWorkerError>().toList();
    expect(errorEvents, isEmpty, reason: 'unexpected worker errors: $errorEvents');

    final segments = events.whereType<SherpaSegmentEvent>().toList();
    expect(segments, isNotEmpty, reason: 'expected at least one segment');

    for (final segment in segments) {
      expect(
        segment.endAt.isBefore(segment.startAt),
        isFalse,
        reason: 'segment endAt before startAt: $segment',
      );
    }

    final recognizedText =
        segments.map((s) => s.text).join(' ').toUpperCase();
    // ignore: avoid_print
    print('Recognized text: $recognizedText');

    // What this asserts is that a real model really decoded real audio
    // through the worker — not how accurate the model is. The pinned
    // `sherpa_onnx` 1.12.19 with the en-20M streaming Zipformer drops the
    // opening words of this clip ("AFTER EARLY NIGHTFALL") and garbles
    // "BROTHELS", on this code path and equally when the recognizer is
    // driven directly with sherpa's own `readWave`, so the shortfall is the
    // model's and not the isolate's. Requiring most of the transcript would
    // pin an accuracy the pinned model does not deliver; requiring a
    // majority of its words catches a worker that decodes nothing or
    // returns noise.
    const expected = <String>[
      'AFTER', 'EARLY', 'NIGHTFALL', 'THE', 'YELLOW', 'LAMPS', 'WOULD',
      'LIGHT', 'UP', 'HERE', 'AND', 'THERE', 'THE', 'SQUALID', 'QUARTER',
      'OF', 'THE', 'BROTHELS',
    ];
    final recognizedWords = recognizedText.split(RegExp(r'\s+')).toSet();
    final matched = expected.where(recognizedWords.contains).length;
    expect(
      matched,
      greaterThanOrEqualTo(expected.length ~/ 2),
      reason: 'only $matched of ${expected.length} expected words came back: '
          '$recognizedText',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('SherpaStreamingTranscriber emits segments over the real worker client',
      () async {
    // Covers the one seam the fake-based tests cannot: that
    // IsolateSherpaWorkerClient actually forwards the worker's events to a
    // listener that subscribed before start().
    if (nativeDir != null) {
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

    // The transcriber's own client cannot be told where the desktop native
    // library lives, so the model dir alone has to do — which is exactly the
    // production configuration on device.
    final transcriber = SherpaStreamingTranscriber(modelDir: modelDir);

    final segments = <TranscriptSegment>[];
    final errors = <String>[];
    // Subscribed before start(), as SessionController does.
    final segmentSub = transcriber.segments.listen(segments.add);
    final errorSub = transcriber.errors.listen(errors.add);

    await transcriber.start();

    final pcm16 = _readWavPcm16(File('$modelDir/test_wavs/0.wav'));
    const chunkBytes = 3200;
    var offset = 0;
    var at = DateTime.now();
    while (offset < pcm16.length) {
      final end = (offset + chunkBytes).clamp(0, pcm16.length);
      final chunk = pcm16.sublist(offset, end);
      transcriber.feed(AudioChunk(
        bytes: chunk,
        encoding: AudioEncoding.pcm16,
        at: at,
      ));
      at = at.add(Duration(
        microseconds: (chunk.length ~/ 2) *
            Duration.microsecondsPerSecond ~/
            16000,
      ));
      offset = end;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    await transcriber.stop();
    await segmentSub.cancel();
    await errorSub.cancel();

    expect(errors, isEmpty, reason: 'unexpected transcriber errors: $errors');
    expect(segments, isNotEmpty,
        reason: 'no segment reached a listener subscribed before start()');
    // ignore: avoid_print
    print('Transcriber text: ${segments.map((s) => s.text).join(' ')}');
    for (final segment in segments) {
      expect(segment.speakerId, 0);
      expect(segment.startAt, isNotNull);
      expect(segment.endAt, isNotNull);
      expect(segment.endAt!.isBefore(segment.startAt!), isFalse);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
