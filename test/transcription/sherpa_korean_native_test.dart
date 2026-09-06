@Tags(['native'])
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/transcription/isolate_channel.dart';
import 'package:libreomi/transcription/model_catalog.dart';
import 'package:libreomi/transcription/sherpa_worker.dart';

/// One second of 16 kHz PCM16 that is not silence: a 220 Hz tone with a
/// little deterministic noise on top.
///
/// Deliberately synthetic. Whether the model turns Korean speech into
/// Korean text is a question only the owner's device can answer (see the
/// LO-44 PR); what this file can answer on a laptop is narrower and still
/// worth pinning — that the Korean archive's file layout matches what
/// [SherpaWorkerConfig] looks for, and that the pinned `sherpa_onnx` build
/// loads a 300 MB Korean transducer and decodes through it without
/// crashing the isolate.
Uint8List _syntheticPcm16({int sampleRate = 16000, int samples = 16000}) {
  final bytes = Uint8List(samples * 2);
  final view = ByteData.sublistView(bytes);
  final random = Random(20240616);
  for (var i = 0; i < samples; i++) {
    final tone = sin(2 * pi * 220 * i / sampleRate) * 8000;
    final noise = (random.nextDouble() - 0.5) * 1000;
    view.setInt16(i * 2, (tone + noise).round(), Endian.little);
  }
  return bytes;
}

void main() {
  final modelDir = Platform.environment['SHERPA_KO_MODEL_DIR'];
  final nativeDir = Platform.environment['SHERPA_NATIVE_DIR'];

  if (modelDir == null || !Directory(modelDir).existsSync()) {
    test('sherpa Korean native load (skipped)', () {},
        skip: 'SHERPA_KO_MODEL_DIR is not set or does not exist. Set it to a '
            'directory holding an extracted '
            '${ModelCatalog.streamingZipformerKo.id} to run this test '
            'locally (see LO-44 in docs/06-roadmap.md).');
    return;
  }

  test('the Korean streaming Zipformer loads and decodes without crashing',
      () async {
    // Every file the catalog promises has to be where the worker looks for
    // it, or an install would verify green and recognition would still fail.
    for (final name in ModelCatalog.streamingZipformerKo.requiredFiles) {
      expect(File('$modelDir/$name').existsSync(), isTrue,
          reason: 'expected $name in $modelDir; the catalog extracts exactly '
              'these four files out of the archive');
    }

    // The onnxruntime shared library carries an @rpath dependency that only
    // resolves once it has been opened directly, before the sherpa-onnx C
    // API library that depends on it is loaded inside the worker isolate.
    // Same dance as sherpa_native_test.dart.
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

    final channel = await IsolateChannel.spawn(
      sherpaWorkerMain,
      debugName: 'sherpa-korean-native-test',
    );

    final events = <Object?>[];
    final sub = channel.events.listen(events.add);

    // No file names are passed: the point of this test is that the worker's
    // defaults are right for the Korean model too.
    await channel.request(SherpaInitCommand(SherpaWorkerConfig(
      modelDir: modelDir,
      nativeLibraryDir: nativeDir,
    )));

    final pcm16 = _syntheticPcm16();
    const chunkBytes = 3200; // 100 ms at 16 kHz mono PCM16.
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
      at = at.add(Duration(
        microseconds: (chunk.length ~/ 2) *
            Duration.microsecondsPerSecond ~/
            sampleRate,
      ));
      offset = end;
      // Give the worker a chance to drain notifications between chunks.
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    await channel.request(const SherpaStopCommand());
    await channel.close();
    await sub.cancel();

    final errorEvents = events.whereType<IsolateWorkerError>().toList();
    expect(errorEvents, isEmpty,
        reason: 'unexpected worker errors: $errorEvents');

    // A tone is not speech, so the model is free to emit nothing. What it may
    // not do is emit a segment that ends before it starts.
    for (final segment in events.whereType<SherpaSegmentEvent>()) {
      expect(segment.endAt.isBefore(segment.startAt), isFalse,
          reason: 'segment endAt before startAt: $segment');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
