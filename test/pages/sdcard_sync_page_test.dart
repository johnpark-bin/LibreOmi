/// Widget tests for [SdCardSyncPage], the LO-52 rewrite that turned the page
/// into a thin view over [SdCardController].
///
/// `PageControllers.sdCard` always reports `hasStorage == false` (no fake
/// device is connected), so tests that need the sync view build their own
/// [SdCardController] over a [FakeSyncedFileStore] and a stubbed
/// `processFile`, and render it through a nested provider inside the
/// harness's tree -- the nearest `SdCardController` wins, while
/// `DeviceController` still comes from the harness underneath it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:libreomi/controllers/sdcard_controller.dart';
import 'package:libreomi/device/omi_gatt.dart';
import 'package:libreomi/device/omi_storage.dart';
import 'package:libreomi/pages/conversations_page.dart';
import 'package:libreomi/pages/sdcard_sync_page.dart';
import 'package:libreomi/services/sdcard_sync_service.dart';

import 'controller_harness.dart';

import '../support/localized_app.dart';

/// [OmiStorage] double that is never actually called: [_StuckSyncService]
/// overrides every method that would touch it.
class _UnusedOmiStorage implements OmiStorage {
  @override
  Future<List<int>> list() async => const [];

  @override
  Future<void> startStream() async {}

  @override
  Future<void> stopStream() async {}

  @override
  Future<bool> startRead(int offset, {int fileNumber = 1}) async => true;

  @override
  Future<bool> stopRead() async => true;

  @override
  Future<bool> clear({int fileNumber = 1}) async => true;

  @override
  Stream<List<int>> get rawPackets => const Stream.empty();

  @override
  Stream<StoragePacket> get packets => const Stream.empty();
}

/// A [SdCardSyncService] whose [startSync] reports progress once and then
/// hangs on a [Completer] that only [cancelSync] resolves.
///
/// `SdCardSyncService` is a concrete class (not an interface) because it
/// drives the real BLE transfer protocol, so a page test overrides its two
/// entry points rather than re-implementing that protocol against a fake
/// [OmiStorage]: `_performSync`'s real transfer loop involves a real 5s
/// no-data `Timer` and a `Future.timeout` of `wal.seconds + 60`, neither of
/// which this test's fake-clock zone ever advances -- driving them for real
/// left transfers permanently stuck (confirmed by running the flow directly:
/// `flutter_tester` processes sat spinning indefinitely). Overriding the two
/// public entry points keeps the "sync is in flight, Cancel ends it" contract
/// under test without going through that machinery.
class _StuckSyncService extends SdCardSyncService {
  _StuckSyncService()
      : super(storage: _UnusedOmiStorage(), readCodec: () async => BleAudioCodec.pcm8);

  int cancelCalls = 0;
  final Completer<void> _stuck = Completer<void>();

  @override
  Future<void> startSync({
    SyncProgressCallback? onProgress,
    SyncCompleteCallback? onComplete,
    SyncErrorCallback? onError,
  }) async {
    onProgress?.call(0.0, 'Starting sync...');
    await _stuck.future;
  }

  @override
  Future<void> cancelSync() async {
    cancelCalls++;
    if (!_stuck.isCompleted) _stuck.complete();
  }
}

/// Records every call and lets a test choose success or failure per path.
class _FakeProcessFile {
  final List<String> calls = [];

  /// Paths that should fail; everything else succeeds with [transcriptFor].
  final Set<String> failing = {};

  String transcriptFor(String filePath) => 'Transcript for $filePath';

  Future<String> call(String filePath) async {
    calls.add(filePath);
    if (failing.contains(filePath)) {
      throw Exception('boom');
    }
    return transcriptFor(filePath);
  }
}

/// A `createdAt` far enough in the past that `SyncedAudioFile.dateFormatted`
/// always renders as `month/day/year` rather than a relative "Xd ago" --
/// which depends on the wall clock at test-run time, not a fixed "today".
final _fixedCreatedAt = DateTime(2020, 1, 1);

SyncedAudioFile _file(
  String path, {
  int sizeBytes = 1024,
  int durationSeconds = 42,
}) {
  return SyncedAudioFile(
    filePath: path,
    fileName: path.split('/').last,
    sizeBytes: sizeBytes,
    createdAt: _fixedCreatedAt,
    durationSeconds: durationSeconds,
  );
}

/// Flushes pending microtasks and gives bounded-duration animations (route
/// transitions, dialog fades) time to finish, without `pumpAndSettle`'s
/// "pump until nothing is dirty" loop -- which never returns on this page,
/// since its pulse `AnimationController` repeats forever.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  /// Renders [controller] as the `SdCardController` the page sees, nested
  /// inside the harness's provider tree so `DeviceController` still comes
  /// from [controllers].
  Future<void> pumpPage(
    WidgetTester tester,
    PageControllers controllers,
    SdCardController controller,
  ) async {
    // Default 800x600 test surface clips the file list's trailing buttons
    // and the lower sections off-screen; a taller surface keeps everything
    // reachable without a scroll, matching settings_page_test's fix for the
    // same problem.
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      controllers.wrap(
        ChangeNotifierProvider<SdCardController>.value(
          value: controller,
          child: const LocalizedApp(home: SdCardSyncPage()),
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets('device not connected shows the no-support view, not the sync view', (
    WidgetTester tester,
  ) async {
    final controllers = await PageControllers.create();
    // The harness's own SdCardController: no fake device is connected, so
    // `hasStorage` is false and `deviceState` defaults to disconnected.
    await pumpPage(tester, controllers, controllers.sdCard);

    expect(find.text('Device Not Connected'), findsOneWidget);
    expect(find.text('Synced Files'), findsNothing);
    expect(find.text('Sync & Process'), findsNothing);
  });

  testWidgets('synced files render and the header shows the formatted total', (
    WidgetTester tester,
  ) async {
    final controllers = await PageControllers.create();
    final fileStore = FakeSyncedFileStore()
      ..files.addAll([
        _file('/sdcard/a.bin', sizeBytes: 500 * 1024, durationSeconds: 10),
        _file('/sdcard/b.bin', sizeBytes: 600 * 1024, durationSeconds: 20),
      ]);
    final process = _FakeProcessFile();
    final controller = SdCardController(
      syncService: () => null,
      hasStorage: () => true,
      processFile: process.call,
      fileStore: fileStore,
    );
    addTearDown(controller.dispose);

    await pumpPage(tester, controllers, controller);

    // Title and subtitle are separate `Text` widgets on the `ListTile`:
    // duration alone as the title, size + date as the subtitle.
    final dateFormatted = fileStore.files.first.dateFormatted;
    expect(find.text('2 files • 1.1 MB on your phone'), findsOneWidget);
    expect(find.text('10s'), findsOneWidget);
    expect(find.text('500.0 KB • $dateFormatted'), findsOneWidget);
    expect(find.text('20s'), findsOneWidget);
    expect(find.text('600.0 KB • $dateFormatted'), findsOneWidget);
  });

  testWidgets('tapping the process button calls processFile for that path', (
    WidgetTester tester,
  ) async {
    final controllers = await PageControllers.create();
    final fileStore = FakeSyncedFileStore()..files.add(_file('/sdcard/a.bin'));
    final process = _FakeProcessFile();
    final controller = SdCardController(
      syncService: () => null,
      hasStorage: () => true,
      processFile: process.call,
      fileStore: fileStore,
    );
    addTearDown(controller.dispose);

    await pumpPage(tester, controllers, controller);

    await tester.tap(find.byTooltip('Process & Transcribe'));
    await settle(tester);

    expect(process.calls, ['/sdcard/a.bin']);
  });

  testWidgets('a done file shows its transcript card and pushes ConversationsPage', (
    WidgetTester tester,
  ) async {
    final controllers = await PageControllers.create();
    final fileStore = FakeSyncedFileStore()..files.add(_file('/sdcard/a.bin'));
    final process = _FakeProcessFile();
    final controller = SdCardController(
      syncService: () => null,
      hasStorage: () => true,
      processFile: process.call,
      fileStore: fileStore,
    );
    addTearDown(controller.dispose);

    await pumpPage(tester, controllers, controller);

    await tester.tap(find.byTooltip('Process & Transcribe'));
    await settle(tester);

    expect(find.text(process.transcriptFor('/sdcard/a.bin')), findsOneWidget);
    expect(find.text('Summary pending'), findsOneWidget);
    expect(find.text('View in History'), findsOneWidget);

    await tester.tap(find.text('View in History'));
    await settle(tester);

    // Pushed without touching a database: `ConversationsPage` never calls
    // `LibraryController.load()`, only `.conversations` off state the
    // harness's controller already holds in memory.
    expect(find.byType(ConversationsPage), findsOneWidget);
  });

  testWidgets(
    'the done card survives the import deleting its own .bin',
    (WidgetTester tester) async {
      final controllers = await PageControllers.create();
      final fileStore = FakeSyncedFileStore()..files.add(_file('/sdcard/a.bin'));
      final process = _FakeProcessFile();
      final controller = SdCardController(
        syncService: () => null,
        hasStorage: () => true,
        processFile: process.call,
        fileStore: fileStore,
      );
      addTearDown(controller.dispose);

      await pumpPage(tester, controllers, controller);

      await tester.tap(find.byTooltip('Process & Transcribe'));
      await settle(tester);

      // A successful import deletes the recording it consumed, so the file
      // is gone from the listing -- and the result card must still be there.
      // Keying the cards off `syncedFiles` instead of the process states is
      // what made this card unreachable in the first draft of the page.
      expect(controller.syncedFiles, isEmpty);
      expect(
        controller.processStateOf('/sdcard/a.bin').status,
        FileProcessStatus.done,
      );
      expect(find.text('Summary pending'), findsOneWidget);
      expect(find.text('View in History'), findsOneWidget);
    },
  );

  testWidgets('a failed file shows the error and Retry calls processFile again', (
    WidgetTester tester,
  ) async {
    final controllers = await PageControllers.create();
    final fileStore = FakeSyncedFileStore()..files.add(_file('/sdcard/a.bin'));
    final process = _FakeProcessFile()..failing.add('/sdcard/a.bin');
    final controller = SdCardController(
      syncService: () => null,
      hasStorage: () => true,
      processFile: process.call,
      fileStore: fileStore,
    );
    addTearDown(controller.dispose);

    await pumpPage(tester, controllers, controller);

    await tester.tap(find.byTooltip('Process & Transcribe'));
    await settle(tester);

    // "Transcription failed" appears twice: the failed card's heading, and
    // the status card's status line (`SdCardController.processFile` sets
    // `status` to the same string on failure).
    expect(find.text('Transcription failed'), findsNWidgets(2));
    expect(find.textContaining('boom'), findsOneWidget);
    expect(process.calls, ['/sdcard/a.bin']);

    await tester.tap(find.text('Retry'));
    await settle(tester);

    expect(process.calls, ['/sdcard/a.bin', '/sdcard/a.bin']);
  });

  testWidgets('tapping Cancel during a sync calls cancelSync', (
    WidgetTester tester,
  ) async {
    final controllers = await PageControllers.create();
    final syncService = _StuckSyncService();
    final process = _FakeProcessFile();
    final controller = SdCardController(
      syncService: () => syncService,
      hasStorage: () => true,
      processFile: process.call,
      fileStore: FakeSyncedFileStore(),
    );
    addTearDown(controller.dispose);

    await pumpPage(tester, controllers, controller);

    // Not awaited: `_StuckSyncService.startSync` only resolves once
    // `cancelSync` completes its stuck `Completer` -- exactly the syncing
    // state under test.
    unawaited(controller.startSync());
    await settle(tester);

    expect(controller.syncing, isTrue);
    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await settle(tester);

    expect(syncService.cancelCalls, 1);
    expect(controller.syncing, isFalse);
  });

  testWidgets('deleting a file opens a confirmation dialog and removes it on confirm', (
    WidgetTester tester,
  ) async {
    final controllers = await PageControllers.create();
    final fileStore = FakeSyncedFileStore()..files.add(_file('/sdcard/a.bin'));
    final process = _FakeProcessFile();
    final controller = SdCardController(
      syncService: () => null,
      hasStorage: () => true,
      processFile: process.call,
      fileStore: fileStore,
    );
    addTearDown(controller.dispose);

    await pumpPage(tester, controllers, controller);

    expect(controller.syncedFiles, hasLength(1));

    await tester.tap(find.byTooltip('Delete'));
    await settle(tester);

    expect(find.text('Delete File'), findsOneWidget);
    expect(find.textContaining('a.bin'), findsWidgets);

    await tester.tap(find.text('Delete'));
    await settle(tester);

    expect(controller.syncedFiles, isEmpty);
    expect(find.text('Synced Files'), findsNothing);
  });
}
