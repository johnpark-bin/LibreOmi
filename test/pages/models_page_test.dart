import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:libreomi/pages/models_page.dart';
import 'package:libreomi/transcription/model_catalog.dart';
import 'package:libreomi/transcription/model_store.dart';

/// Serves a fixed body in chunks. Trimmed copy of the fake in
/// `test/transcription/model_store_test.dart`, kept local so this test file
/// does not reach into another test file's internals.
class _FakeClient extends http.BaseClient {
  _FakeClient(this.body, {this.chunkCount = 4});

  final List<int> body;
  final int chunkCount;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final chunkSize = (body.length / chunkCount).ceil();
    final controller = StreamController<List<int>>();
    unawaited(() async {
      for (var start = 0; start < body.length; start += chunkSize) {
        final end =
            start + chunkSize > body.length ? body.length : start + chunkSize;
        controller.add(Uint8List.fromList(body.sublist(start, end)));
        await Future<void>.delayed(Duration.zero);
      }
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

/// A client that answers every request with a server error.
class _FailingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      const Stream<List<int>>.empty(),
      500,
      request: request,
    );
  }
}

/// A client whose response body the test feeds by hand, so an install can be
/// inspected and cancelled while it is still downloading.
class _ManualClient extends http.BaseClient {
  final StreamController<List<int>> body = StreamController<List<int>>();
  final int contentLength;

  _ManualClient({required this.contentLength});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      body.stream,
      200,
      contentLength: contentLength,
      request: request,
    );
  }
}

/// Builds a `.tar.bz2` whose entries sit under [topDir], matching the shape
/// of a real catalog archive.
List<int> _buildArchive(String topDir, Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.add(ArchiveFile.string('$topDir/${entry.key}', entry.value));
  }
  return BZip2Encoder().encodeBytes(TarEncoder().encodeBytes(archive));
}

void main() {
  late Directory tempRoot;
  late Directory support;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('models_page_test');
    support = Directory('${tempRoot.path}/support')..createSync();
  });

  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  ModelStore buildStore({http.Client? client}) => ModelStore(
        supportDirectory: () async => support,
        legacyDocumentsDirectory: () async =>
            Directory('${tempRoot.path}/documents')..createSync(),
        client: client,
      );

  final spec = ModelCatalog.streamingZipformerEn20M;

  /// Creates the model's directory under the support root with a few bytes
  /// per required file, so `sizeOnDisk` and `isInstalled` see a real install
  /// without a real (127 MB) archive.
  void seedInstalled(ModelSpec spec, {String content = 'weights'}) {
    final dir = Directory('${support.path}/models/${spec.directoryName}')
      ..createSync(recursive: true);
    for (final relative in spec.requiredFiles) {
      File('${dir.path}/$relative').writeAsStringSync(content);
    }
  }

  Future<void> pumpModelsPage(WidgetTester tester, ModelStore store) async {
    await tester.pumpWidget(MaterialApp(home: ModelsPage(store: store)));
    await tester.pumpAndSettle();
  }

  testWidgets('a model with nothing installed shows Download and its size', (
    WidgetTester tester,
  ) async {
    final store = buildStore();
    await pumpModelsPage(tester, store);

    expect(find.text(spec.displayName), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Download'), findsWidgets);
    expect(find.text('Download 122 MB · 88 MB on disk'), findsOneWidget);
  });

  testWidgets(
    'an installed model shows its on-disk size and a Delete action that '
    'removes the directory after confirming',
    (WidgetTester tester) async {
      final store = buildStore();
      seedInstalled(spec, content: 'abcde');
      await pumpModelsPage(tester, store);

      final expectedMb =
          (spec.requiredFiles.length * 5 / (1024 * 1024)).round();
      expect(find.text('$expectedMb MB installed'), findsOneWidget);

      final deleteButtons = find.widgetWithIcon(IconButton, Icons.delete_outline);
      expect(deleteButtons, findsWidgets);
      await tester.tap(deleteButtons.first);
      await tester.pumpAndSettle();

      // The confirmation dialog is up; nothing is deleted yet.
      expect(await store.isInstalled(spec), isTrue);
      expect(find.text('Delete'), findsWidgets);

      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();

      expect(await store.isInstalled(spec), isFalse);
      expect(find.text('Download 122 MB · 88 MB on disk'), findsOneWidget);
    },
  );

  testWidgets('an install driven by the fake client shows progress and ends installed', (
    WidgetTester tester,
  ) async {
    final archiveBytes = _buildArchive(spec.archiveTopDir, {
      for (final relative in spec.requiredFiles) relative: 'weights-$relative',
    });
    final store = buildStore(
      client: _FakeClient(archiveBytes, chunkCount: 6),
    );
    await pumpModelsPage(tester, store);

    // The install's stream is created and listened to inside `tap`'s
    // `onPressed` callback, and its extraction phase runs in a real isolate
    // (`Isolate.run`) — one that deadlocks unless the whole thing, tap
    // included, runs inside `runAsync`'s real zone rather than the fake one
    // `testWidgets` normally drives. Only the wait is here; `pump` below
    // picks up every `setState` the stream's progress ticks made meanwhile.
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(ElevatedButton, 'Download').first);
      while (!await store.isInstalled(spec)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();

    // The install has finished: the row now shows Delete instead of Cancel,
    // and the model is really on disk.
    expect(await store.isInstalled(spec), isTrue);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsNothing);
    expect(find.widgetWithIcon(IconButton, Icons.delete_outline), findsWidgets);
  });

  testWidgets('a failed download reports the error and restores the row', (
    WidgetTester tester,
  ) async {
    final store = buildStore(client: _FailingClient());
    await pumpModelsPage(tester, store);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(ElevatedButton, 'Download').first);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('HTTP 500'), findsOneWidget);
    expect(await store.isInstalled(spec), isFalse);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsNothing);
    expect(find.widgetWithText(ElevatedButton, 'Download'),
        findsNWidgets(ModelCatalog.all.length));
  });

  testWidgets('a download in flight shows a progress bar, a percentage and Cancel', (
    WidgetTester tester,
  ) async {
    final client = _ManualClient(contentLength: 4 * 1024 * 1024);
    final store = buildStore(client: client);
    await pumpModelsPage(tester, store);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(ElevatedButton, 'Download').first);
      client.body.add(Uint8List(1024 * 1024));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
    expect(find.text('1 / 4 MB (25%)'), findsOneWidget);
    // Every row but the one installing still offers Download.
    expect(find.widgetWithText(ElevatedButton, 'Download'),
        findsNWidgets(ModelCatalog.all.length - 1));

    await tester.runAsync(() async {
      await client.body.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
  });

  testWidgets('Cancel abandons the install and returns the row to Download', (
    WidgetTester tester,
  ) async {
    final client = _ManualClient(contentLength: 4 * 1024 * 1024);
    final store = buildStore(client: client);
    await pumpModelsPage(tester, store);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(ElevatedButton, 'Download').first);
      client.body.add(Uint8List(1024 * 1024));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.runAsync(() async {
      // The download loop is parked on the next chunk; closing the body lets
      // it notice the cancelled token.
      await client.body.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(await store.isInstalled(spec), isFalse);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.widgetWithText(ElevatedButton, 'Download'),
        findsNWidgets(ModelCatalog.all.length));
    // A cancel is the user's own doing, so it is not reported as a failure.
    expect(find.byType(SnackBar), findsNothing);
  });
}
