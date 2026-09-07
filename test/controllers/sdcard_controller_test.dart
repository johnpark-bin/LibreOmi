/// Unit tests for `lib/controllers/sdcard_controller.dart` (LO-52).
///
/// `SdCardController` takes the sync service, the file store and the import
/// entry point as injected closures/interfaces precisely so this can drive
/// the whole page state machine without a real device or `path_provider`
/// plugin channel, except where a test explicitly needs the real
/// `SdCardSyncService` writing a `.bin` under a mocked application-support
/// directory (mirroring `test/services/sdcard_sync_service_test.dart`).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/controllers/sdcard_controller.dart';
import 'package:libreomi/device/fake_omi_device.dart';
import 'package:libreomi/device/omi_gatt.dart';
import 'package:libreomi/device/omi_storage.dart';
import 'package:libreomi/services/sdcard_sync_service.dart';
import 'package:libreomi/session/sdcard_import.dart' show sdCardConversationTitle;

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

/// Points `path_provider`'s support/documents directories at temp
/// directories under [root] for the duration of a test. Copied from
/// `test/services/sdcard_sync_service_test.dart` — `SdCardSyncService`
/// writes the synced `.bin` under the application support directory, so the
/// real-transfer tests below need this even though the controller itself
/// never touches `path_provider` directly.
void _mockPathProvider(Directory root) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_pathProviderChannel, (call) async {
    switch (call.method) {
      case 'getApplicationSupportDirectory':
        return '${root.path}/support';
      case 'getApplicationDocumentsDirectory':
        return '${root.path}/documents';
    }
    return null;
  });
}

/// An in-memory [SyncedFileStore], substituting for the real
/// `SdCardSyncServiceFileStore` (which shells out to `path_provider`) in
/// every test that does not need a real transfer on disk.
class _FakeFileStore implements SyncedFileStore {
  _FakeFileStore([List<SyncedAudioFile> files = const []]) : _files = List.of(files);

  final List<SyncedAudioFile> _files;

  /// Every path handed to [delete] (individually or via [deleteAll]), in
  /// call order.
  final List<String> deletedPaths = [];

  @override
  Future<List<SyncedAudioFile>> list() async => List.unmodifiable(_files);

  @override
  Future<bool> delete(String filePath) async {
    final index = _files.indexWhere((f) => f.filePath == filePath);
    if (index == -1) return false;
    _files.removeAt(index);
    deletedPaths.add(filePath);
    return true;
  }

  @override
  Future<int> deleteAll() async {
    final removed = _files.length;
    deletedPaths.addAll(_files.map((f) => f.filePath));
    _files.clear();
    return removed;
  }
}

SyncedAudioFile _syncedFile(String path, {int sizeBytes = 1000}) {
  return SyncedAudioFile(
    filePath: path,
    fileName: path.split('/').last,
    sizeBytes: sizeBytes,
    createdAt: DateTime(2026, 1, 1),
    durationSeconds: 30,
    codec: BleAudioCodec.opus,
  );
}

/// An [OmiStorage] double for tests that need to control `clear()` and/or
/// the storage stream directly, without a fixture replay.
///
/// [packets]/[rawPackets] are broadcast controllers that are never fed
/// unless a test calls [deliver] itself, so a transfer started against this
/// storage stalls deterministically after `startRead` — exactly what the
/// cancel test needs instead of racing a fixture replay.
class _ScriptedStorage implements OmiStorage {
  _ScriptedStorage({List<int> listResult = const [], bool clearResult = true})
      : _listResult = listResult,
        _clearResult = clearResult;

  final List<int> _listResult;
  final bool _clearResult;

  final _packetsController = StreamController<StoragePacket>.broadcast(sync: true);
  final _rawPacketsController = StreamController<List<int>>.broadcast(sync: true);

  int startReadCalls = 0;
  int stopReadCalls = 0;

  @override
  Future<List<int>> list() async => _listResult;

  @override
  Future<void> startStream() async {}

  @override
  Future<void> stopStream() async {}

  @override
  Future<bool> startRead(int offset, {int fileNumber = 1}) async {
    startReadCalls++;
    return true;
  }

  @override
  Future<bool> stopRead() async {
    stopReadCalls++;
    return true;
  }

  @override
  Future<bool> clear({int fileNumber = 1}) async => _clearResult;

  @override
  Stream<StoragePacket> get packets => _packetsController.stream;

  @override
  Stream<List<int>> get rawPackets => _rawPacketsController.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('refreshPending without device support', () {
    test('leaves pending null and reports storage is not supported', () async {
      final controller = SdCardController(
        syncService: () => null,
        hasStorage: () => false,
        processFile: (_) async => throw UnimplementedError(),
        fileStore: _FakeFileStore(),
      );
      addTearDown(controller.dispose);

      await controller.refreshPending();

      expect(controller.pending, isNull);
      expect(controller.status.toLowerCase(), contains('not supported'));
    });
  });

  group('refreshPending over a real device', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('sdcard_controller_test_');
      _mockPathProvider(tempRoot);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathProviderChannel, null);
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    test('reports the pending WAL found on the fixture device', () async {
      final fixture = File('test/fixtures/omi_sdcard_transfer.jsonl').readAsStringSync();
      final device = FakeOmiDevice.fromJsonl(fixture, storageList: [100000, 0]);
      final service = SdCardSyncService(
        storage: device.storage,
        readCodec: () async => BleAudioCodec.opus,
      );
      final controller = SdCardController(
        syncService: () => service,
        hasStorage: () => true,
        processFile: (_) async => throw UnimplementedError(),
        fileStore: _FakeFileStore(),
      );
      addTearDown(controller.dispose);

      await controller.refreshPending();

      final pending = controller.pending;
      expect(pending, isNotNull);
      expect(controller.status, contains(pending!.durationFormatted));
      expect(controller.status, contains(pending.sizeFormatted));
    });

    test('startSync drives a full fixture transfer end to end', () async {
      final fixture = File('test/fixtures/omi_sdcard_transfer.jsonl').readAsStringSync();
      final device = FakeOmiDevice.fromJsonl(fixture, storageList: [100000, 0]);
      final service = SdCardSyncService(
        storage: device.storage,
        readCodec: () async => BleAudioCodec.opus,
      );
      final controller = SdCardController(
        syncService: () => service,
        hasStorage: () => true,
        processFile: (_) async => throw UnimplementedError(),
        // Real file store on purpose: this asserts `syncedFiles` picks up
        // the `.bin` startSync writes to disk.
      );
      addTearDown(controller.dispose);

      final progressReadings = <double>[];
      controller.addListener(() => progressReadings.add(controller.syncProgress));

      final syncFuture = controller.startSync();
      // Let checkForPendingData/startStream's microtasks drain before the
      // fixture is replayed, matching sdcard_sync_service_test.dart: the
      // service's subscription to storage.packets must be in place before
      // events are delivered through the fake's synchronous streams.
      await Future<void>.delayed(Duration.zero);
      await device.replay();
      final savedPath = await syncFuture;

      for (var i = 1; i < progressReadings.length; i++) {
        expect(progressReadings[i], greaterThanOrEqualTo(progressReadings[i - 1]));
      }
      expect(controller.syncProgress, 1.0);
      expect(controller.syncing, isFalse);

      expect(savedPath, isNotNull);
      expect(File(savedPath!).existsSync(), isTrue);
      expect(savedPath, endsWith('.bin'));

      expect(controller.syncedFiles, isNotEmpty);
      expect(controller.syncedFiles.any((f) => f.filePath == savedPath), isTrue);
    });
  });

  group('cancelSync', () {
    test('stops a stalled transfer deterministically', () async {
      final storage = _ScriptedStorage(listResult: [100000, 0]);
      final service = SdCardSyncService(
        storage: storage,
        readCodec: () async => BleAudioCodec.opus,
      );
      final controller = SdCardController(
        syncService: () => service,
        hasStorage: () => true,
        processFile: (_) async => throw UnimplementedError(),
        fileStore: _FakeFileStore(),
      );
      addTearDown(controller.dispose);

      // Start without awaiting: `storage.packets` never emits, so this
      // would otherwise hang until the service's `wal.seconds + 60` timeout.
      final syncFuture = controller.startSync();
      await Future<void>.delayed(Duration.zero);
      expect(controller.syncing, isTrue);

      await controller.cancelSync();
      await syncFuture;

      expect(controller.syncing, isFalse);
      expect(controller.syncProgress, 0.0);
      expect(controller.status, 'Sync cancelled');
      expect(storage.stopReadCalls, 1);
      // A cancel is not a failure the page should pop a red snackbar for.
      expect(controller.syncError, isNull);
    });
  });

  group('syncError', () {
    test('is set when a transfer cannot start and cleared by the next try',
        () async {
      // An empty storage listing makes `checkForPendingData` return null,
      // which is the service's 'No data to sync' error path.
      final service = SdCardSyncService(
        storage: _ScriptedStorage(listResult: const []),
        readCodec: () async => BleAudioCodec.opus,
      );
      final controller = SdCardController(
        syncService: () => service,
        hasStorage: () => true,
        processFile: (_) async => throw UnimplementedError(),
        fileStore: _FakeFileStore(),
      );
      addTearDown(controller.dispose);

      final path = await controller.startSync();

      expect(path, isNull);
      expect(controller.syncError, isNotNull);
      expect(controller.syncing, isFalse);

      // Cleared before the guard, so a second attempt never hands the page
      // the previous attempt's error.
      await controller.startSync();
      expect(controller.syncError, isNotNull);

      final quiet = SdCardController(
        syncService: () => null,
        hasStorage: () => true,
        processFile: (_) async => throw UnimplementedError(),
        fileStore: _FakeFileStore(),
      );
      addTearDown(quiet.dispose);
      expect(await quiet.startSync(), isNull);
      expect(quiet.syncError, isNull);
    });
  });

  group('storage support appearing', () {
    test('refreshes what the device holds on the false -> true edge only',
        () async {
      final deviceChanges = ChangeNotifier();
      var hasStorage = false;
      var checks = 0;
      final service = SdCardSyncService(
        storage: _ScriptedStorage(listResult: [100000, 0]),
        readCodec: () async {
          checks++;
          return BleAudioCodec.opus;
        },
      );
      final controller = SdCardController(
        syncService: () => service,
        hasStorage: () => hasStorage,
        processFile: (_) async => throw UnimplementedError(),
        fileStore: _FakeFileStore(),
        deviceChanges: deviceChanges,
      );
      addTearDown(() {
        controller.dispose();
        deviceChanges.dispose();
      });

      // A notification with no storage yet asks the device nothing.
      deviceChanges.notifyListeners();
      await pumpEventQueue();
      expect(controller.pending, isNull);
      expect(checks, 0);

      hasStorage = true;
      deviceChanges.notifyListeners();
      await pumpEventQueue();
      expect(controller.pending, isNotNull);
      expect(checks, 1);

      // Still true: this is not an edge, and must not re-ask.
      deviceChanges.notifyListeners();
      await pumpEventQueue();
      expect(checks, 1);
    });
  });

  group('processFile', () {
    test('success walks transcribing -> ... -> done and deletes the file', () async {
      const path = '/fake/sdcard/rec.bin';
      final store = _FakeFileStore([_syncedFile(path)]);
      var importedCount = 0;

      final controller = SdCardController(
        syncService: () => null,
        hasStorage: () => false,
        processFile: (filePath) async {
          expect(filePath, path);
          return 'the transcript';
        },
        fileStore: store,
        onConversationImported: () async {
          importedCount++;
        },
      );
      addTearDown(controller.dispose);

      final observedStatuses = <FileProcessStatus>[];
      controller.addListener(() {
        observedStatuses.add(controller.processStateOf(path).status);
      });

      await controller.processFile(path);

      // The whole point of the three states: an import is reported as
      // "saved, summary still queued" before it is reported as done, and
      // never blips back to idle in between.
      expect(
        observedStatuses,
        containsAllInOrder([
          FileProcessStatus.transcribing,
          FileProcessStatus.summarizing,
          FileProcessStatus.done,
        ]),
      );
      expect(observedStatuses.last, FileProcessStatus.done);
      expect(observedStatuses, isNot(contains(FileProcessStatus.idle)));

      final finalState = controller.processStateOf(path);
      expect(finalState.status, FileProcessStatus.done);
      expect(finalState.summaryPending, isTrue);
      expect(finalState.conversationTitle, sdCardConversationTitle);
      expect(finalState.transcript, 'the transcript');

      expect(importedCount, 1);
      expect(store.deletedPaths, [path]);
    });

    test('failure keeps the file and reports the error without deleting it', () async {
      const path = '/fake/sdcard/rec.bin';
      final store = _FakeFileStore([_syncedFile(path)]);

      final controller = SdCardController(
        syncService: () => null,
        hasStorage: () => false,
        processFile: (_) async => throw Exception('decode boom'),
        fileStore: store,
        onConversationImported: () async {
          fail('onConversationImported must not fire when processFile throws');
        },
      );
      addTearDown(controller.dispose);

      await controller.processFile(path);

      final state = controller.processStateOf(path);
      expect(state.status, FileProcessStatus.failed);
      expect(state.error, isNotNull);
      expect(store.deletedPaths, isEmpty);
    });
  });

  group('deleteFile / deleteAll', () {
    test('deleteFile removes one file and updates syncedFiles/storageUsageBytes', () async {
      final store = _FakeFileStore([
        _syncedFile('/fake/a.bin', sizeBytes: 100),
        _syncedFile('/fake/b.bin', sizeBytes: 200),
        _syncedFile('/fake/c.bin', sizeBytes: 300),
      ]);
      final controller = SdCardController(
        syncService: () => null,
        hasStorage: () => false,
        processFile: (_) async => throw UnimplementedError(),
        fileStore: store,
      );
      addTearDown(controller.dispose);

      await controller.refreshSyncedFiles();
      expect(controller.storageUsageBytes, 600);

      final deleted = await controller.deleteFile('/fake/b.bin');

      expect(deleted, isTrue);
      expect(store.deletedPaths, ['/fake/b.bin']);
      expect(controller.syncedFiles.map((f) => f.filePath), ['/fake/a.bin', '/fake/c.bin']);
      expect(controller.storageUsageBytes, 400);
    });

    test('deleteAll clears every file and zeroes storageUsageBytes', () async {
      final store = _FakeFileStore([
        _syncedFile('/fake/a.bin', sizeBytes: 100),
        _syncedFile('/fake/b.bin', sizeBytes: 200),
      ]);
      final controller = SdCardController(
        syncService: () => null,
        hasStorage: () => false,
        processFile: (_) async => throw UnimplementedError(),
        fileStore: store,
      );
      addTearDown(controller.dispose);

      await controller.refreshSyncedFiles();

      final deletedCount = await controller.deleteAll();

      expect(deletedCount, 2);
      expect(store.deletedPaths, unorderedEquals(['/fake/a.bin', '/fake/b.bin']));
      expect(controller.syncedFiles, isEmpty);
      expect(controller.storageUsageBytes, 0);
    });
  });

  group('result cards outliving the page', () {
    test('clearFinishedResults drops finished imports and keeps busy ones', () async {
      final store = _FakeFileStore([
        _syncedFile('/fake/done.bin'),
        _syncedFile('/fake/busy.bin'),
      ]);
      final release = Completer<String>();
      final controller = SdCardController(
        syncService: () => null,
        hasStorage: () => false,
        processFile: (path) =>
            path == '/fake/busy.bin' ? release.future : Future.value('text'),
        fileStore: store,
      );
      addTearDown(controller.dispose);

      await controller.refreshSyncedFiles();
      await controller.processFile('/fake/done.bin');
      // Left in flight on purpose: a card for an import still running must
      // survive the page being reopened.
      unawaited(controller.processFile('/fake/busy.bin'));
      await pumpEventQueue();

      expect(
        controller.processStateOf('/fake/done.bin').status,
        FileProcessStatus.done,
      );
      expect(
        controller.processStateOf('/fake/busy.bin').status,
        FileProcessStatus.transcribing,
      );

      controller.clearFinishedResults();

      expect(
        controller.processStateOf('/fake/done.bin').status,
        FileProcessStatus.idle,
      );
      expect(
        controller.processStateOf('/fake/busy.bin').status,
        FileProcessStatus.transcribing,
      );

      release.complete('text');
      await pumpEventQueue();
    });

    test('deleteAll keeps the result of an import that removed its own file',
        () async {
      final store = _FakeFileStore([
        _syncedFile('/fake/imported.bin'),
        _syncedFile('/fake/other.bin'),
      ]);
      final controller = SdCardController(
        syncService: () => null,
        hasStorage: () => false,
        processFile: (_) async => 'the transcript',
        fileStore: store,
      );
      addTearDown(controller.dispose);

      await controller.refreshSyncedFiles();
      await controller.processFile('/fake/imported.bin');

      // The import consumed its own `.bin`, so "delete all" never touches
      // it -- and must not throw its result away either.
      await controller.deleteAll();

      expect(
        controller.processStateOf('/fake/imported.bin').status,
        FileProcessStatus.done,
      );
      expect(controller.syncedFiles, isEmpty);
    });
  });

  group('clearDeviceStorage', () {
    test('success clears pending and reports it in the status', () async {
      final storage = _ScriptedStorage(listResult: [100000, 0], clearResult: true);
      final service = SdCardSyncService(
        storage: storage,
        readCodec: () async => BleAudioCodec.opus,
      );
      final controller = SdCardController(
        syncService: () => service,
        hasStorage: () => true,
        processFile: (_) async => throw UnimplementedError(),
        fileStore: _FakeFileStore(),
      );
      addTearDown(controller.dispose);

      // Give the controller something pending to clear.
      await controller.refreshPending();
      expect(controller.pending, isNotNull);

      final success = await controller.clearDeviceStorage();

      expect(success, isTrue);
      expect(controller.pending, isNull);
      expect(controller.status.toLowerCase(), contains('cleared'));
    });

    test('failure leaves the failure status and does not throw', () async {
      final storage = _ScriptedStorage(listResult: [100000, 0], clearResult: false);
      final service = SdCardSyncService(
        storage: storage,
        readCodec: () async => BleAudioCodec.opus,
      );
      final controller = SdCardController(
        syncService: () => service,
        hasStorage: () => true,
        processFile: (_) async => throw UnimplementedError(),
        fileStore: _FakeFileStore(),
      );
      addTearDown(controller.dispose);

      final success = await controller.clearDeviceStorage();

      expect(success, isFalse);
      expect(controller.status.toLowerCase(), contains('failed'));
    });
  });
}
