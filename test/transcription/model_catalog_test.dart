import 'package:flutter_test/flutter_test.dart';

import 'package:libreomi/transcription/model_catalog.dart';

void main() {
  group('ModelCatalog', () {
    test('ids are unique', () {
      final ids = ModelCatalog.all.map((s) => s.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('every entry downloads a tar.bz2 named after its top directory', () {
      for (final spec in ModelCatalog.all) {
        expect(
          spec.url,
          endsWith('${spec.archiveTopDir}.tar.bz2'),
          reason: '${spec.id} extracts by stripping archiveTopDir, so the '
              'archive name and that directory must agree',
        );
        expect(spec.id, spec.archiveTopDir);
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

    test('the streaming default names the files SherpaService opens', () {
      final spec = ModelCatalog.defaultStreaming;
      expect(spec.kind, ModelKind.streamingZipformer);
      expect(spec.requiredFiles, contains('encoder-epoch-99-avg-1.onnx'));
      expect(spec.requiredFiles, contains('decoder-epoch-99-avg-1.onnx'));
      expect(spec.requiredFiles, contains('joiner-epoch-99-avg-1.onnx'));
      expect(spec.requiredFiles, contains('tokens.txt'));
    });
  });
}
