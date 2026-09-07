/// Builds the four LO-34 controllers over fakes, so a page widget test can be
/// wrapped in the same `MultiProvider` `main.dart` installs without touching
/// BLE, a plugin channel or a real database.
///
/// Nothing here calls `DeviceController.init()`: the pages only read state,
/// and leaving the connection-state and button subscriptions unattached keeps
/// a widget test free of the auto-start machinery `main.dart`'s bootstrap
/// wires up.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:libreomi/controllers/chat_controller.dart';
import 'package:libreomi/controllers/device_controller.dart';
import 'package:libreomi/controllers/library_controller.dart';
import 'package:libreomi/controllers/sdcard_controller.dart';
import 'package:libreomi/controllers/session_controller.dart';
import 'package:libreomi/device/device_manager.dart';
import 'package:libreomi/platform/fake_background_runner.dart';
import 'package:libreomi/services/sdcard_sync_service.dart' show SyncedAudioFile;

import 'package:sqflite/sqflite.dart';
import '../device/device_manager_test.dart'
    show FakeOmiDeviceHost, MapSavedDeviceStore;

/// In-memory [SyncedFileStore] double: a page test seeds [files] directly
/// instead of touching `path_provider`, which the production
/// `SdCardSyncServiceFileStore` calls into.
class FakeSyncedFileStore implements SyncedFileStore {
  final List<SyncedAudioFile> files = [];

  @override
  Future<List<SyncedAudioFile>> list() async => List.unmodifiable(files);

  @override
  Future<bool> delete(String filePath) async {
    final before = files.length;
    files.removeWhere((file) => file.filePath == filePath);
    return files.length != before;
  }

  @override
  Future<int> deleteAll() async {
    final removed = files.length;
    files.clear();
    return removed;
  }
}

/// A [Timer] that never fires and holds nothing, for the auto-reconnect
/// ladder a page test does not exercise.
class _InertTimer implements Timer {
  @override
  void cancel() {}

  @override
  bool get isActive => false;

  @override
  int get tick => 0;
}

/// The controller set a page test renders against, plus the fakes underneath
/// it so a test can script the device side and assert on the foreground
/// service.
class PageControllers {
  PageControllers._({
    required this.library,
    required this.chat,
    required this.session,
    required this.device,
    required this.sdCard,
    required this.sdCardFiles,
    required this.deviceManager,
    required this.host,
    required this.backgroundRunner,
  });

  final LibraryController library;
  final ChatController chat;
  final SessionController session;
  final DeviceController device;
  final SdCardController sdCard;

  /// The in-memory synced-file store backing [sdCard], so a page test can
  /// seed files without touching `path_provider`.
  final FakeSyncedFileStore sdCardFiles;
  final DeviceManager deviceManager;
  final FakeOmiDeviceHost host;
  final FakeBackgroundRunner backgroundRunner;

  /// Builds the set in the order `main.dart` does, over a scriptable device
  /// host and a database provider that is never invoked.
  ///
  /// No database is opened on purpose. Opening one through
  /// `sqflite_common_ffi` from inside a `testWidgets` body leaves the ffi
  /// isolate's port live in the widget binding's fake-async zone, and the
  /// next `pumpWidget` never returns. The pages these controllers back read
  /// only in-memory state, so a provider that throws documents that and
  /// fails loudly if a page ever starts loading rows in a widget test.
  static Future<PageControllers> create({FakeOmiDeviceHost? host}) async {
    Future<Database> noDatabase() => throw StateError(
          'PageControllers opens no database: a page widget test that needs '
          'rows should drive the controller directly in a plain test().',
        );
    final deviceHost = host ?? FakeOmiDeviceHost();
    final deviceManager = DeviceManager(
      host: deviceHost,
      savedDevices: MapSavedDeviceStore(),
    );
    final library = LibraryController(database: noDatabase);
    final chat = ChatController(library: library, database: noDatabase);
    final backgroundRunner = FakeBackgroundRunner();
    final session = SessionController(
      deviceManager: deviceManager,
      library: library,
      chat: chat,
      backgroundRunner: backgroundRunner,
    );
    final deviceController = DeviceController(
      deviceManager: deviceManager,
      session: session,
      notify: (_, __) async {},
      resetBadge: () async {},
      // The auto-reconnect ladder is not what a page test is about, and a
      // real `Timer` armed inside `testWidgets` is a pending timer the test
      // would then fail on.
      createTimer: (_, __) => _InertTimer(),
    );
    final sdCardFiles = FakeSyncedFileStore();
    final sdCardController = SdCardController(
      syncService: () => deviceController.sdCardSyncService,
      hasStorage: () => deviceController.hasStorageSupport,
      // A page test drives `processFile` through the controller's own
      // fakes, not through a real transcription pipeline; failing loudly
      // documents that no test should reach this without stubbing it.
      processFile: (filePath) => throw StateError(
        'PageControllers.processFile is not stubbed: pass a fake through '
        'the controller under test if a test needs to process a file.',
      ),
      fileStore: sdCardFiles,
      deviceChanges: deviceController,
    );
    // Same order as `main.dart`'s `dispose()`: the session goes down first,
    // because `DeviceController.dispose()` chains the device manager's
    // teardown onto `SessionController.teardown`, and that future is only a
    // real one once `SessionController.dispose()` has run. `sdCardController`
    // listens to `deviceController`, so it must go down before it.
    addTearDown(() {
      session.dispose();
      sdCardController.dispose();
      deviceController.dispose();
      chat.dispose();
      library.dispose();
    });
    return PageControllers._(
      library: library,
      chat: chat,
      session: session,
      device: deviceController,
      sdCard: sdCardController,
      sdCardFiles: sdCardFiles,
      deviceManager: deviceManager,
      host: deviceHost,
      backgroundRunner: backgroundRunner,
    );
  }

  /// The same provider tree `main.dart` installs, around [child].
  Widget wrap(Widget child) => MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryController>.value(value: library),
          ChangeNotifierProvider<ChatController>.value(value: chat),
          ChangeNotifierProvider<SessionController>.value(value: session),
          ChangeNotifierProvider<DeviceController>.value(value: device),
          ChangeNotifierProvider<SdCardController>.value(value: sdCard),
        ],
        child: child,
      );
}
