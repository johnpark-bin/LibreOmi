import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:libreomi/transcription/model_catalog.dart';
import 'package:libreomi/transcription/model_store.dart';

/// A catalog entry with a made-up URL and a three-file payload, so the tests
/// never touch the network or a 120 MB archive. Shaped exactly like a real
/// entry: everything nested under one top directory, only some of which the
/// store is supposed to extract.
const ModelSpec _spec = ModelSpec(
  id: 'test-model',
  kind: ModelKind.whisper,
  displayName: 'Test model',
  url: 'https://example.invalid/test-model.tar.bz2',
  archiveTopDir: 'test-model',
  requiredFiles: ['encoder.onnx', 'tokens.txt'],
  archiveBytes: 1024,
  installedBytes: 2048,
  languages: ['en'],
);

/// Serves a fixed body in [chunkCount] pieces, letting a test cancel between
/// them. Bypasses `MockClient`, which would deliver the whole body at once.
class _FakeClient extends http.BaseClient {
  _FakeClient(
    this.body, {
    this.statusCode = 200,
    this.chunkCount = 4,
    this.sendContentLength = true,
    this.onChunk,
  });

  final List<int> body;
  final int statusCode;
  final int chunkCount;
  final bool sendContentLength;

  /// Called with the 0-based index after each chunk is handed over, so a test
  /// can cancel mid-download.
  final void Function(int index)? onChunk;

  final List<Uri> requestedUrls = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestedUrls.add(request.url);
    final chunkSize = (body.length / chunkCount).ceil();
    final controller = StreamController<List<int>>();
    unawaited(() async {
      var index = 0;
      for (var start = 0; start < body.length; start += chunkSize) {
        final end =
            start + chunkSize > body.length ? body.length : start + chunkSize;
        controller.add(Uint8List.fromList(body.sublist(start, end)));
        // Let the consumer run before the next chunk, so a cancel triggered
        // from onChunk is seen by the loop that reads the stream.
        await Future<void>.delayed(Duration.zero);
        onChunk?.call(index++);
      }
      await controller.close();
    }());
    return http.StreamedResponse(
      controller.stream,
      statusCode,
      contentLength: sendContentLength ? body.length : null,
      request: request,
    );
  }
}

/// Builds a `.tar.bz2` whose entries sit under [topDir], the same shape the
/// upstream sherpa-onnx release archives have.
List<int> _buildArchive(String topDir, Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.add(ArchiveFile.string('$topDir/${entry.key}', entry.value));
  }
  return BZip2Encoder().encodeBytes(TarEncoder().encodeBytes(archive));
}

/// Serves a different body per URL, and holds [gateUrl]'s response open
/// until [gate] completes, so one install can be parked mid-download while
/// another runs to completion.
class _GatedClient extends http.BaseClient {
  _GatedClient({
    required this.bodies,
    required this.gateUrl,
    required this.gate,
  });

  final Map<String, List<int>> bodies;
  final String gateUrl;
  final Future<void> gate;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = bodies[request.url.toString()]!;
    final controller = StreamController<List<int>>();
    unawaited(() async {
      final half = body.length ~/ 2;
      controller.add(Uint8List.fromList(body.sublist(0, half)));
      if (request.url.toString() == gateUrl) {
        await gate;
      }
      controller.add(Uint8List.fromList(body.sublist(half)));
      await controller.close();
    }());
    return http.StreamedResponse(
      controller.stream,
      200,
      contentLength: body.length,
      request: request,
    );
  }
}

void main() {
  late Directory tempRoot;
  late Directory support;
  late Directory documents;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('model_store_test');
    support = Directory('${tempRoot.path}/support')..createSync();
    documents = Directory('${tempRoot.path}/documents')..createSync();
  });

  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  ModelStore buildStore(http.Client? client) => ModelStore(
        supportDirectory: () async => support,
        legacyDocumentsDirectory: () async => documents,
        client: client,
      );

  List<int> goodArchive() => _buildArchive('test-model', {
        'encoder.onnx': 'encoder-weights',
        'tokens.txt': 'a b c',
        // Ignored by the store: the real archives ship int8 copies and sample
        // wavs that would otherwise double the install size.
        'encoder.int8.onnx': 'int8-weights',
        'test_wavs/0.wav': 'not audio',
      });

  Directory modelDir() => Directory('${support.path}/models/${_spec.id}');

  group('install', () {
    test('downloads, extracts only the required files, and verifies',
        () async {
      final client = _FakeClient(goodArchive());
      final store = buildStore(client);

      final progress = await store.install(_spec).toList();

      expect(client.requestedUrls.single.toString(), _spec.url);
      expect(await store.isInstalled(_spec), isTrue);
      expect(File('${modelDir().path}/encoder.onnx').readAsStringSync(),
          'encoder-weights');
      expect(File('${modelDir().path}/tokens.txt').existsSync(), isTrue);
      expect(File('${modelDir().path}/encoder.int8.onnx').existsSync(), isFalse,
          reason: 'files outside requiredFiles must not be extracted');
      expect(Directory('${modelDir().path}/test_wavs').existsSync(), isFalse);

      expect(progress.last.phase, ModelInstallPhase.done);
      expect(
        progress.map((p) => p.phase).toSet(),
        containsAll(<ModelInstallPhase>[
          ModelInstallPhase.downloading,
          ModelInstallPhase.extracting,
          ModelInstallPhase.verifying,
          ModelInstallPhase.done,
        ]),
      );
    });

    test('reports monotonic download progress that ends at the total',
        () async {
      final body = goodArchive();
      final store = buildStore(_FakeClient(body, chunkCount: 5));

      final downloads = (await store.install(_spec).toList())
          .where((p) => p.phase == ModelInstallPhase.downloading)
          .toList();

      // The first tick is the "starting" one with no bytes yet.
      expect(downloads.first.receivedBytes, 0);
      expect(downloads.last.receivedBytes, body.length);
      expect(downloads.last.totalBytes, body.length);
      expect(downloads.last.fraction, 1.0);
      for (var i = 1; i < downloads.length; i++) {
        expect(downloads[i].receivedBytes,
            greaterThanOrEqualTo(downloads[i - 1].receivedBytes));
      }
    });

    test('falls back to the catalog size when there is no Content-Length',
        () async {
      final store = buildStore(
        _FakeClient(goodArchive(), sendContentLength: false),
      );

      final first = await store
          .install(_spec)
          .firstWhere((p) => p.phase == ModelInstallPhase.downloading);

      expect(first.totalBytes, _spec.archiveBytes);
    });

    test('leaves nothing behind when cancelled mid-download', () async {
      final token = ModelInstallCancelToken();
      final store = buildStore(
        _FakeClient(
          goodArchive(),
          chunkCount: 6,
          onChunk: (index) {
            if (index == 1) token.cancel();
          },
        ),
      );

      await expectLater(
        store.install(_spec, cancelToken: token).drain<void>(),
        throwsA(isA<ModelInstallCancelled>()),
      );

      expect(await store.isInstalled(_spec), isFalse);
      expect(modelDir().existsSync(), isFalse);
      final leftovers = Directory('${support.path}/models')
          .listSync()
          .map((e) => e.path.split(Platform.pathSeparator).last)
          .toList();
      expect(leftovers.where((n) => n.startsWith('.staging-')), isEmpty);
      expect(Directory('${support.path}/models/.tmp').listSync(), isEmpty);
    });

    test('fails on a non-200 response without creating the model directory',
        () async {
      final store = buildStore(_FakeClient(<int>[1, 2, 3], statusCode: 404));

      await expectLater(
        store.install(_spec).drain<void>(),
        throwsA(isA<ModelInstallException>()),
      );
      expect(modelDir().existsSync(), isFalse);
    });

    test('fails when the archive is missing a required file', () async {
      final store = buildStore(_FakeClient(_buildArchive('test-model', {
        'encoder.onnx': 'encoder-weights',
        // no tokens.txt
      })));

      await expectLater(
        store.install(_spec).drain<void>(),
        throwsA(isA<ModelInstallException>()),
      );
      expect(await store.isInstalled(_spec), isFalse);
    });

    test('keeps the previous install when a reinstall fails', () async {
      final store = buildStore(_FakeClient(goodArchive()));
      await store.install(_spec).drain<void>();
      expect(await store.isInstalled(_spec), isTrue);

      final broken = buildStore(_FakeClient(<int>[1, 2, 3], statusCode: 500));
      await expectLater(
        broken.install(_spec).drain<void>(),
        throwsA(isA<ModelInstallException>()),
      );

      expect(await store.isInstalled(_spec), isTrue);
      expect(File('${modelDir().path}/encoder.onnx').readAsStringSync(),
          'encoder-weights');
    });

    test('two installs at once do not delete each other\'s temp files',
        () async {
      // The models page enables a Download button per catalog row, so two
      // installs can overlap. They must not share a scratch directory: the
      // second used to recreate it and unlink the first's half-written
      // archive, which then failed minutes later at extraction time.
      const other = ModelSpec(
        id: 'test-model-two',
        kind: ModelKind.whisper,
        displayName: 'Second test model',
        url: 'https://example.invalid/test-model-two.tar.bz2',
        archiveTopDir: 'test-model-two',
        requiredFiles: ['encoder.onnx'],
        archiveBytes: 512,
        installedBytes: 1024,
        languages: ['en'],
      );

      // The first install is held open on its response body until the second
      // has run start to finish.
      final gate = Completer<void>();
      final firstBody = goodArchive();
      final store = ModelStore(
        supportDirectory: () async => support,
        legacyDocumentsDirectory: () async => documents,
        client: _GatedClient(
          bodies: {
            _spec.url: firstBody,
            other.url: _buildArchive('test-model-two', {
              'encoder.onnx': 'second-weights',
            }),
          },
          gateUrl: _spec.url,
          gate: gate.future,
        ),
      );

      final first = store.install(_spec).drain<void>();
      // Wait until the first install has actually put something under the
      // scratch root, so the second one genuinely overlaps it.
      final scratch = Directory('${support.path}/models/.tmp');
      while (!scratch.existsSync() ||
          scratch.listSync(recursive: true).isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await store.install(other).drain<void>();
      gate.complete();
      await first;

      expect(await store.isInstalled(_spec), isTrue);
      expect(await store.isInstalled(other), isTrue);
      expect(File('${modelDir().path}/encoder.onnx').readAsStringSync(),
          'encoder-weights');
    });

    test('does nothing until the returned stream is listened to', () async {
      final client = _FakeClient(goodArchive());
      final store = buildStore(client);

      store.install(_spec);
      await Future<void>.delayed(Duration.zero);

      expect(client.requestedUrls, isEmpty);
    });
  });

  group('queries', () {
    test('isInstalled rejects an empty required file', () async {
      final store = buildStore(_FakeClient(goodArchive()));
      await store.install(_spec).drain<void>();

      File('${modelDir().path}/tokens.txt').writeAsBytesSync(<int>[]);

      expect(await store.isInstalled(_spec), isFalse);
    });

    test('requireInstalledDir throws a user-facing message when missing',
        () async {
      final store = buildStore(null);

      await expectLater(
        store.requireInstalledDir(_spec),
        throwsA(
          isA<ModelNotInstalledException>().having(
            (e) => e.message,
            'message',
            allOf(contains('Test model'), contains('Settings')),
          ),
        ),
      );
    });

    test('sizeOnDisk and delete', () async {
      final store = buildStore(_FakeClient(goodArchive()));
      expect(await store.sizeOnDisk(_spec), 0);

      await store.install(_spec).drain<void>();
      expect(await store.sizeOnDisk(_spec),
          'encoder-weights'.length + 'a b c'.length);

      await store.delete(_spec);
      expect(await store.isInstalled(_spec), isFalse);
      expect(await store.sizeOnDisk(_spec), 0);
      await store.delete(_spec); // idempotent
    });

    test('clearScratch removes leftovers a killed install left behind',
        () async {
      final store = buildStore(_FakeClient(goodArchive()));
      await store.install(_spec).drain<void>();
      // What a process kill mid-install leaves: nothing else reclaims these,
      // since install only clears its own model's subtree.
      File('${support.path}/models/.tmp/dead-model/archive.tar.bz2')
        ..createSync(recursive: true)
        ..writeAsStringSync('half a download');
      Directory('${support.path}/models/.staging-dead-model')
          .createSync(recursive: true);

      expect(await store.clearScratch(), 2);

      expect(Directory('${support.path}/models/.tmp').existsSync(), isFalse);
      expect(
        Directory('${support.path}/models/.staging-dead-model').existsSync(),
        isFalse,
      );
      // The installed model is untouched.
      expect(await store.isInstalled(_spec), isTrue);
    });

    test('listInstalled reports catalog entries and strangers', () async {
      final store = buildStore(_FakeClient(goodArchive()));
      await store.install(_spec).drain<void>();
      Directory('${support.path}/models/${ModelCatalog.whisperTiny.id}')
          .createSync(recursive: true);
      Directory('${support.path}/models/left-over-from-an-old-build')
          .createSync(recursive: true);

      final installed = await store.listInstalled();

      expect(installed.map((e) => e.id), [
        'left-over-from-an-old-build',
        ModelCatalog.whisperTiny.id,
        _spec.id,
      ]);
      // The empty whisper directory is a known model but not a complete one.
      final whisper = installed
          .firstWhere((e) => e.id == ModelCatalog.whisperTiny.id);
      expect(whisper.spec, same(ModelCatalog.whisperTiny));
      expect(whisper.complete, isFalse);
      final stranger =
          installed.firstWhere((e) => e.id == 'left-over-from-an-old-build');
      expect(stranger.spec, isNull);
      expect(stranger.complete, isFalse);
      // Neither the temp nor the staging directory is reported as a model.
      expect(installed.map((e) => e.id), isNot(contains('.tmp')));
    });
  });

  group('migrateLegacyInstalls', () {
    void writeLegacy(String subdirectory, String id, String content) {
      final dir = Directory('${documents.path}/$subdirectory/$id')
        ..createSync(recursive: true);
      File('${dir.path}/encoder.onnx').writeAsStringSync(content);
    }

    test('moves both legacy directories into the support layout', () async {
      writeLegacy('sherpa_models', ModelCatalog.defaultStreaming.id, 'zip');
      writeLegacy('whisper_models', ModelCatalog.whisperTiny.id, 'whi');
      final store = buildStore(null);

      expect(await store.migrateLegacyInstalls(), 2);

      expect(
        File('${support.path}/models/${ModelCatalog.defaultStreaming.id}/'
                'encoder.onnx')
            .readAsStringSync(),
        'zip',
      );
      expect(
        File('${support.path}/models/${ModelCatalog.whisperTiny.id}/'
                'encoder.onnx')
            .readAsStringSync(),
        'whi',
      );
      expect(Directory('${documents.path}/sherpa_models').existsSync(), isFalse);
      expect(
          Directory('${documents.path}/whisper_models').existsSync(), isFalse);
    });

    test('is idempotent and a no-op with nothing to move', () async {
      final store = buildStore(null);
      expect(await store.migrateLegacyInstalls(), 0);

      writeLegacy('whisper_models', ModelCatalog.whisperTiny.id, 'whi');
      expect(await store.migrateLegacyInstalls(), 1);
      expect(await store.migrateLegacyInstalls(), 0);
    });

    test('drops the legacy copy when the new layout already has the model',
        () async {
      final target =
          Directory('${support.path}/models/${ModelCatalog.whisperTiny.id}')
            ..createSync(recursive: true);
      File('${target.path}/encoder.onnx').writeAsStringSync('new');
      writeLegacy('whisper_models', ModelCatalog.whisperTiny.id, 'old');

      final store = buildStore(null);
      expect(await store.migrateLegacyInstalls(), 0);

      expect(File('${target.path}/encoder.onnx').readAsStringSync(), 'new');
      expect(
          Directory('${documents.path}/whisper_models').existsSync(), isFalse);
    });

    test('survives a platform with no documents directory', () async {
      final store = ModelStore(
        supportDirectory: () async => support,
        legacyDocumentsDirectory: () async =>
            throw UnsupportedError('no documents directory'),
      );

      expect(await store.migrateLegacyInstalls(), 0);
    });
  });
}
