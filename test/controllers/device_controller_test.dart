// The LO-34 unit 3 acceptance test: `DeviceController` on its own, driven
// through a `DeviceManager` over `FakeOmiDeviceHost` and a recording
// `SessionController` subclass, so nothing here touches BLE, a plugin
// channel or real time.
//
// Follows the style of `test/controllers/session_controller_test.dart`:
// local `_Fake...`/`_Recording...` classes, no mocking package. Several
// tests assert *call order* on the session, which is the point of the
// listener reproduced in `DeviceController.init()`.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:libreomi/controllers/chat_controller.dart';
import 'package:libreomi/controllers/device_controller.dart';
import 'package:libreomi/controllers/library_controller.dart';
import 'package:libreomi/controllers/session_controller.dart';
import 'package:libreomi/device/device_manager.dart';
import 'package:libreomi/device/fake_omi_device.dart';
import 'package:libreomi/device/omi_device.dart';
import 'package:libreomi/device/omi_gatt.dart';
import 'package:libreomi/platform/fake_background_runner.dart';
import 'package:libreomi/services/secret_store.dart';
import 'package:libreomi/services/settings_service.dart';

import '../data/test_db.dart';
import '../device/device_manager_test.dart' show FakeOmiDeviceHost, MapSavedDeviceStore;

/// A [SessionController] that records every call `DeviceController` makes
/// on it, in order, instead of running the real state machine. `isListening`
/// and `isUsingPhoneMic` are settable directly so a test can put the fake in
/// whatever state the scenario needs.
///
/// Built over a real `DeviceManager`/`LibraryController`/`ChatController`
/// (as `SessionController`'s own constructor requires), but every method
/// `DeviceController` touches is overridden here so the real `RecordingSession`
/// underneath is never exercised.
class _RecordingSessionController extends SessionController {
  _RecordingSessionController({
    required super.deviceManager,
    required super.library,
    required super.chat,
    required super.backgroundRunner,
  });

  final List<String> calls = [];

  bool listening = false;
  bool usingPhoneMic = false;

  @override
  bool get isListening => listening;

  @override
  bool get isUsingPhoneMic => usingPhoneMic;

  @override
  void endAwaitingReconnect() {
    calls.add('endAwaitingReconnect');
  }

  @override
  Future<void> startListeningIfReady() async {
    calls.add('startListeningIfReady');
  }

  @override
  void beginAwaitingReconnect() {
    calls.add('beginAwaitingReconnect');
  }

  @override
  Future<void> stopListeningForDeviceLoss() async {
    calls.add('stopListeningForDeviceLoss');
  }

  @override
  void onDeviceStateChanged() {
    calls.add('onDeviceStateChanged');
  }

  @override
  Future<void> handleButtonEvent(ButtonEvent event) async {
    calls.add('handleButtonEvent:$event');
  }

  @override
  Future<void> stopListening() async {
    calls.add('stopListening');
    listening = false;
  }

  @override
  Future<void> releaseBackgroundServiceIfIdle() async {
    calls.add('releaseBackgroundServiceIfIdle');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useFfiDatabaseFactory();

  late FakeOmiDeviceHost host;
  late MapSavedDeviceStore saved;
  late DeviceManager deviceManager;
  late _RecordingSessionController session;
  late List<(String, String)> notifications;
  late int resetBadgeCalls;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SettingsService.init(secretStore: InMemorySecretStore());

    host = FakeOmiDeviceHost();
    saved = MapSavedDeviceStore();
    deviceManager = DeviceManager(host: host, savedDevices: saved);

    final libraryDb = await openTestDb();
    final library = LibraryController(database: () async => libraryDb);
    final chatDb = await openTestDb();
    final chat = ChatController(library: library, database: () async => chatDb);

    session = _RecordingSessionController(
      deviceManager: deviceManager,
      library: library,
      chat: chat,
      backgroundRunner: FakeBackgroundRunner(),
    );

    notifications = [];
    resetBadgeCalls = 0;
  });

  tearDown(() async {
    await host.close();
  });

  Future<DeviceController> build({ReconnectTimerFactory? createTimer}) async {
    final controller = DeviceController(
      deviceManager: deviceManager,
      session: session,
      notify: (title, body) async {
        notifications.add((title, body));
      },
      resetBadge: () async {
        resetBadgeCalls++;
      },
      createTimer: createTimer ?? Timer.new,
    );
    // Two-phase construction (LO-34 unit 4): the constructor no longer
    // subscribes or schedules a reconnect on its own, so every test needs
    // this before the controller does anything.
    await controller.init();
    return controller;
  }

  /// Connects [deviceManager] to a fake device carrying [batteryLevel] and
  /// [storageList], bypassing `DeviceManager.connect()` (which cannot pass
  /// those through) the way `FakeOmiDeviceHost.bringUp` is meant to.
  Future<void> connect({int? batteryLevel, List<int> storageList = const []}) async {
    host.bringUp(
      FakeOmiDevice(const [], batteryLevel: batteryLevel, storageList: storageList),
    );
    // Let the async device-state listener (battery read, storage probe)
    // settle before the test asserts on it.
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  Future<void> disconnectAtHostLevel() async {
    host.setState(DeviceConnectionState.disconnected);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  group('connected', () {
    test('reads battery, probes storage, resets backoff and starts listening', () async {
      final controller = await build();
      addTearDown(controller.dispose);

      await connect(batteryLevel: 77, storageList: [1000, 0]);

      expect(controller.batteryLevel, 77);
      expect(controller.hasStorageSupport, isTrue);
      expect(controller.sdCardSyncService, isNotNull);
      expect(session.calls, contains('startListeningIfReady'));
    });

    test('does not start listening when the session is already listening', () async {
      session.listening = true;
      final controller = await build();
      addTearDown(controller.dispose);

      await connect(batteryLevel: 90);

      expect(controller.batteryLevel, 90, reason: 'battery is still read regardless');
      expect(controller.hasStorageSupport, isFalse, reason: 'storage probe is skipped too');
      expect(session.calls, isNot(contains('startListeningIfReady')));
    });

    test('does not start listening when using the phone mic', () async {
      session.usingPhoneMic = true;
      final controller = await build();
      addTearDown(controller.dispose);

      await connect(batteryLevel: 90);

      expect(session.calls, isNot(contains('startListeningIfReady')));
    });
  });

  group('involuntary disconnect', () {
    test('begins the grace window before stopping the session, when guards allow it', () async {
      // The guard `DeviceController.init()` checks reads
      // `SettingsService.savedDeviceId` (the saved-device flag the old
      // monolith used to check), not the `DeviceManager`'s own store.
      SettingsService.savedDeviceId = 'aa:bb';
      final controller = await build();
      addTearDown(controller.dispose);
      await connect();
      session.listening = true;

      session.calls.clear();
      await disconnectAtHostLevel();

      final beginIndex = session.calls.indexOf('beginAwaitingReconnect');
      final stopIndex = session.calls.indexOf('stopListeningForDeviceLoss');
      expect(beginIndex, greaterThanOrEqualTo(0));
      expect(stopIndex, greaterThanOrEqualTo(0));
      expect(beginIndex, lessThan(stopIndex));
    });

    test('does not begin the grace window when auto-reconnect is disabled, but still stops the session', () async {
      SettingsService.savedDeviceId = 'aa:bb';
      final controller = await build();
      addTearDown(controller.dispose);
      await connect();
      session.listening = true;

      // Disables auto-reconnect (and stops/releases via the fake, which sets
      // `listening` back to false); reconnect it and pretend it is listening
      // again so the guard under test is the only thing skipping the grace
      // window on the next disconnect.
      await controller.disconnectDevice();
      await connect();
      session.listening = true;

      session.calls.clear();
      await disconnectAtHostLevel();

      expect(session.calls, isNot(contains('beginAwaitingReconnect')));
      expect(session.calls, contains('stopListeningForDeviceLoss'));
    });

    test('does not begin the grace window without a saved device id, but still stops the session', () async {
      SettingsService.savedDeviceId = '';
      final controller = await build();
      addTearDown(controller.dispose);
      await connect();
      session.listening = true;

      session.calls.clear();
      await disconnectAtHostLevel();

      expect(session.calls, isNot(contains('beginAwaitingReconnect')));
      expect(session.calls, contains('stopListeningForDeviceLoss'));
    });
  });

  group('disconnectDevice', () {
    test('stops the session then releases the background service, in that order, '
        'and the ensuing disconnect neither begins a grace window nor schedules a reconnect', () async {
      saved.savedDeviceId = 'aa:bb';
      var timerRequests = 0;
      final controller = await build(
        createTimer: (duration, callback) {
          timerRequests++;
          return Timer(duration, callback);
        },
      );
      addTearDown(controller.dispose);
      await connect();
      session.listening = true;

      session.calls.clear();
      final timerRequestsBeforeDisconnect = timerRequests;
      await controller.disconnectDevice();

      final stopIndex = session.calls.indexOf('stopListening');
      final releaseIndex = session.calls.indexOf('releaseBackgroundServiceIfIdle');
      expect(stopIndex, greaterThanOrEqualTo(0));
      expect(releaseIndex, greaterThanOrEqualTo(0));
      expect(stopIndex, lessThan(releaseIndex));
      expect(session.calls, isNot(contains('beginAwaitingReconnect')));

      // Auto-reconnect is now off, so `_scheduleReconnect` returns before
      // ever asking for a timer -- deterministic, no real waiting needed.
      expect(timerRequests, timerRequestsBeforeDisconnect);
    });
  });

  group('battery notifications', () {
    test('crossing 50% notifies once, crossing 20% notifies once, and re-arms above the thresholds', () async {
      final controller = await build();
      addTearDown(controller.dispose);

      await connect(batteryLevel: 55);
      expect(notifications, isEmpty, reason: 'above both thresholds');

      await connect(batteryLevel: 45);
      expect(notifications, hasLength(1));
      expect(notifications.single.$1, 'Battery Getting Low');

      // A second read still under 50% must not notify again.
      await connect(batteryLevel: 40);
      expect(notifications, hasLength(1));

      await connect(batteryLevel: 15);
      expect(notifications, hasLength(2));
      expect(notifications.last.$1, 'Low Battery Warning');

      // Charged back above both thresholds re-arms both flags.
      await connect(batteryLevel: 90);
      await connect(batteryLevel: 45);
      expect(notifications, hasLength(3));
      expect(notifications.last.$1, 'Battery Getting Low');
    });

    test('respects the settings toggles', () async {
      SettingsService.notifyBatteryLow = false;
      SettingsService.notifyBatteryCritical = false;
      final controller = await build();
      addTearDown(controller.dispose);

      await connect(batteryLevel: 45);
      await connect(batteryLevel: 90);
      await connect(batteryLevel: 15);

      expect(notifications, isEmpty);
    });
  });

  group('storage support', () {
    test('an empty list() leaves hasStorageSupport false and sdCardSyncService null', () async {
      final controller = await build();
      addTearDown(controller.dispose);

      await connect(storageList: const []);

      expect(controller.hasStorageSupport, isFalse);
      expect(controller.sdCardSyncService, isNull);
    });

    test('a non-empty list() sets both', () async {
      final controller = await build();
      addTearDown(controller.dispose);

      await connect(storageList: const [4096, 0]);

      expect(controller.hasStorageSupport, isTrue);
      expect(controller.sdCardSyncService, isNotNull);
    });
  });

  group('app lifecycle', () {
    test('resets the badge when the app resumes, but not on other transitions', () async {
      final controller = await build();
      addTearDown(controller.dispose);

      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(resetBadgeCalls, 0);

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(resetBadgeCalls, 1);
    });
  });

  group('reconnect ladder', () {
    test('an attempt the guards skip does not advance the backoff', () async {
      // No saved device id, so `_attemptReconnect` finds `canAttempt` false
      // and reschedules with `advanceBackoff: false` -- mirroring
      // `test/services/ble/reconnect_backoff_test.dart`'s ladder semantics,
      // driven here through an injected timer factory rather than real time.
      saved.savedDeviceId = '';
      final requestedDelays = <Duration>[];
      void Function()? pending;
      final controller = await build(
        createTimer: (duration, callback) {
          requestedDelays.add(duration);
          pending = callback;
          return Timer(const Duration(days: 1), () {});
        },
      );
      addTearDown(controller.dispose);

      // `init()`'s own `_scheduleReconnect(advanceBackoff: false)` arms the
      // first, un-advanced attempt.
      expect(requestedDelays, [const Duration(seconds: 5)]);

      // Fire it: `_attemptReconnect` finds no saved device, so the next
      // schedule is `advanceBackoff: false` again -- same 5s base delay.
      pending!();
      await Future<void>.delayed(Duration.zero);
      expect(requestedDelays, [const Duration(seconds: 5), const Duration(seconds: 5)]);
      expect(host.armCalls, isEmpty);
    });
  });
}
