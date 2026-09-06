import 'package:flutter_test/flutter_test.dart';

import 'package:libreomi/transcription/model_catalog.dart';

void main() {
  group('ModelCatalog', () {
    test('ids are unique', () {
      final ids = ModelCatalog.all.map((s) => s.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('every archive entry downloads a tar.bz2 named after its top '
        'directory', () {
      for (final spec in ModelCatalog.all.where((s) => !s.isSingleFile)) {
        expect(
          spec.url,
          endsWith('${spec.archiveTopDir}.tar.bz2'),
          reason: '${spec.id} extracts by stripping archiveTopDir, so the '
              'archive name and that directory must agree',
        );
        expect(spec.id, spec.archiveTopDir);
      }
    });

    test('every single-file entry names exactly the file it downloads', () {
      final singles = ModelCatalog.all.where((s) => s.isSingleFile).toList();
      // A single-file spec is installed by moving the download into place
      // under its one required name, so more than one name has nowhere to
      // come from.
      expect(singles, isNotEmpty);
      for (final spec in singles) {
        expect(spec.requiredFiles, hasLength(1), reason: spec.id);
        expect(spec.url, endsWith('/${spec.requiredFiles.single}'),
            reason: spec.id);
        expect(spec.url, isNot(endsWith('.tar.bz2')), reason: spec.id);
      }
    });

    test('every entry declares required files and plausible sizes', () {
      for (final spec in ModelCatalog.all) {
        expect(spec.requiredFiles, isNotEmpty, reason: spec.id);
        expect(spec.requiredFiles.toSet().length, spec.requiredFiles.length);
        for (final path in spec.requiredFiles) {
          expect(path, isNot(startsWith('/')), reason: spec.id);
          expect(path, isNot(contains('..')), reason: spec.id);
        }
        expect(spec.archiveBytes, greaterThan(0), reason: spec.id);
        expect(spec.installedBytes, greaterThan(0), reason: spec.id);
        expect(spec.languages, isNotEmpty, reason: spec.id);
      }
    });

    test('no entry pins a checksum yet', () {
      // Guards the reasoning in ModelSpec.sha256: nothing verifies this field,
      // so a non-null value would be silently ignored.
      for (final spec in ModelCatalog.all) {
        expect(spec.sha256, isNull, reason: spec.id);
      }
    });

    test('silero VAD is a single-file spec the whisper path can find', () {
      const spec = ModelCatalog.sileroVad;
      expect(spec.kind, ModelKind.vad);
      expect(spec.isSingleFile, isTrue);
      expect(spec.requiredFiles, [ModelCatalog.sileroVadFileName]);
      expect(spec.archiveBytes, spec.installedBytes,
          reason: 'nothing is decompressed, so the two sizes are one number');
      expect(ModelCatalog.all, contains(spec),
          reason: 'the models page installs only what `all` lists, and '
              'without an installable VAD the whisper mode cannot start');
    });

    test('byId finds catalog entries and rejects strangers', () {
      expect(ModelCatalog.byId(ModelCatalog.whisperTiny.id),
          same(ModelCatalog.whisperTiny));
      expect(ModelCatalog.byId('not-a-model'), isNull);
    });

    group('whisper(size)', () {
      test('maps the SettingsService values', () {
        expect(ModelCatalog.whisper('tiny'), same(ModelCatalog.whisperTiny));
        expect(ModelCatalog.whisper('base'), same(ModelCatalog.whisperBase));
      });

      test('falls back to tiny for a stale preference', () {
        expect(ModelCatalog.whisper('small'), same(ModelCatalog.whisperTiny));
        expect(ModelCatalog.whisper(''), same(ModelCatalog.whisperTiny));
      });

      test('names the files WhisperService opens', () {
        // WhisperService builds `<dir>/<size>-encoder.onnx`,
        // `<size>-decoder.onnx` and `<size>-tokens.txt`; if the catalog
        // stopped extracting one of those, installs would verify green and
        // recognition would still fail.
        for (final size in ['tiny', 'base']) {
          final spec = ModelCatalog.whisper(size);
          expect(spec.requiredFiles, contains('$size-encoder.onnx'));
          expect(spec.requiredFiles, contains('$size-decoder.onnx'));
          expect(spec.requiredFiles, contains('$size-tokens.txt'));
        }
      });
    });

    test('every streaming entry names the files SherpaWorkerConfig defaults '
        'to', () {
      // SherpaStreamingTranscriber builds a SherpaWorkerConfig without
      // overriding its file names, so every streaming model in the catalog
      // has to use exactly these four. If a future entry does not, the
      // worker config has to grow per-model names before it can be added.
      final streaming = ModelCatalog.all
          .where((s) => s.kind == ModelKind.streamingZipformer)
          .toList();
      expect(streaming, hasLength(2));
      for (final spec in streaming) {
        expect(spec.requiredFiles, contains('encoder-epoch-99-avg-1.onnx'),
            reason: spec.id);
        expect(spec.requiredFiles, contains('decoder-epoch-99-avg-1.onnx'),
            reason: spec.id);
        expect(spec.requiredFiles, contains('joiner-epoch-99-avg-1.onnx'),
            reason: spec.id);
        expect(spec.requiredFiles, contains('tokens.txt'), reason: spec.id);
      }
    });

    test('every streaming entry is tagged with the one language it decodes',
        () {
      // A transducer is single-language, so 'multi' on one of these would
      // make streaming(language) unable to tell the two models apart.
      for (final spec in ModelCatalog.all
          .where((s) => s.kind == ModelKind.streamingZipformer)) {
        expect(spec.languages, hasLength(1), reason: spec.id);
        expect(spec.languages.single, isNot('multi'), reason: spec.id);
      }
    });

    group('streaming(language)', () {
      test('maps the SettingsService values', () {
        expect(ModelCatalog.streaming('en'),
            same(ModelCatalog.streamingZipformerEn20M));
        expect(ModelCatalog.streaming('ko'),
            same(ModelCatalog.streamingZipformerKo));
      });

      test('falls back to English for a stale preference', () {
        expect(ModelCatalog.streaming('jp'),
            same(ModelCatalog.streamingZipformerEn20M));
        expect(ModelCatalog.streaming(''),
            same(ModelCatalog.streamingZipformerEn20M));
      });

      test('defaultStreaming is the English entry', () {
        expect(ModelCatalog.defaultStreaming, same(ModelCatalog.streaming('en')));
      });

      test('every offered language resolves to a model tagged with it', () {
        expect(ModelCatalog.localSttLanguages, ['en', 'ko']);
        for (final language in ModelCatalog.localSttLanguages) {
          expect(ModelCatalog.localSttLanguage(language), language);
          expect(ModelCatalog.streaming(language).languages, [language],
              reason: language);
        }
      });
    });

    test('the Korean streaming entry points at the upstream release asset',
        () {
      // Sizes and the file list come from the `asr-models` release asset and
      // the `ls -lh` listing in the upstream docs (LO-44); a typo here is an
      // install that downloads 399 MB and then fails verification.
      const spec = ModelCatalog.streamingZipformerKo;
      expect(spec.id, 'sherpa-onnx-streaming-zipformer-korean-2024-06-16');
      expect(spec.languages, ['ko']);
      expect(spec.archiveBytes, 418218652);
      expect(spec.installedBytes, lessThan(spec.archiveBytes),
          reason: 'only four of the archive\'s files are extracted');
      expect(spec.requiredFiles, isNot(contains('bpe.model')),
          reason: 'nothing in the app reads the BPE model');
      expect(
        spec.requiredFiles.where((f) => f.contains('int8')),
        isEmpty,
        reason: 'the archive ships int8 copies the app never loads',
      );
    });
  });
}
