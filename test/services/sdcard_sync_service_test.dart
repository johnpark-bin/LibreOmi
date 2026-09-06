import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/device/fake_omi_device.dart';
import 'package:libreomi/device/omi_gatt.dart';
import 'package:libreomi/services/sdcard_sync_service.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

/// Points `path_provider`'s support/documents directories at temp
/// directories under [root] for the duration of a test.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('sdcard_sync_service_test_');
    _mockPathProvider(tempRoot);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  group('fixture replay integration', () {
    test('syncs 39 frames into a .bin file under support/sdcard/', () async {
      final fixture = File('test/fixtures/omi_sdcard_transfer.jsonl').readAsStringSync();
      // 100000 bytes / 80 bytes-per-frame / 100 fps == 12.5s >= the 10s
      // checkForPendingData requires; offset 0.
      final device = FakeOmiDevice.fromJsonl(
        fixture,
        storageList: [100000, 0],
      );

      final service = SdCardSyncService(
        storage: device.storage,
        readCodec: () async => BleAudioCodec.opus,
      );

      final progressReadings = <double>[];
      String? completedFilePath;
      int? completedSeconds;
      String? errorMessage;

      final syncFuture = service.startSync(
        onProgress: (progress, status) => progressReadings.add(progress),
        onComplete: (filePath, seconds) {
          completedFilePath = filePath;
          completedSeconds = seconds;
        },
        onError: (error) => errorMessage = error,
      );

      // startSync is async (checkForPendingData awaits, then _performSync
      // awaits startStream() before subscribing). Let those microtasks
      // drain before replaying, so the service's subscription to
      // storage.packets is in place before events are delivered through
      // the fake's synchronous broadcast controllers.
      await Future<void>.delayed(Duration.zero);

      await device.replay();
      await syncFuture;

      expect(errorMessage, isNull);
      expect(completedFilePath, isNotNull);
      expect(completedSeconds, isNotNull);

      final file = File(completedFilePath!);
      expect(file.existsSync(), isTrue);

      final supportSdcardDir = Directory('${tempRoot.path}/support/sdcard');
      expect(file.parent.path, supportSdcardDir.path);
      expect(
        file.uri.pathSegments.last,
        matches(RegExp(r'^sdcard_audio_opus_16000_1_\d+\.bin$')),
      );

      // [len int32 LE][frame] layout round-trips.
      final decoded = await SdCardSyncService.readAudioFile(completedFilePath!);
      expect(decoded, isNotNull);

      final bytes = await file.readAsBytes();
      var offset = 0;
      var frameCount = 0;
      var totalFrameBytes = 0;
      while (offset < bytes.length) {
        final length = bytes[offset] |
            (bytes[offset + 1] << 8) |
            (bytes[offset + 2] << 16) |
            (bytes[offset + 3] << 24);
        offset += 4;
        offset += length;
        totalFrameBytes += length;
        frameCount++;
      }
      // Fixed expectations from the fixture (test/fixtures/README.md):
      // 24 x 83-byte packets carry 79-byte frames, 3 x 440-byte packets carry
      // five 80-byte frames each. 24*79 + 15*80 == 3096 frame bytes, plus a
      // 4-byte length prefix per frame == 3252 bytes on disk. Pinning these
      // rather than deriving them from the file is what makes a truncation or
      // off-by-one in the parser fail here.
      expect(frameCount, 39);
      expect(totalFrameBytes, 3096);
      expect(bytes.length, 3252);
      expect(decoded!.length, 3096);

      // The fixture's payload bytes are derived from the packet index, so a
      // frame that was sliced at the wrong offset shows up in the contents.
      final firstFrame = bytes.sublist(4, 4 + 79);
      expect(firstFrame, [for (var j = 0; j < 79; j++) (0 * 31 + j) & 0xFF]);
      // Second frame: packet index 1, so payload byte j is (31 + j) & 0xFF.
      final secondFrame = bytes.sublist(4 + 79 + 4, 4 + 79 + 4 + 79);
      expect(secondFrame, [for (var j = 0; j < 79; j++) (1 * 31 + j) & 0xFF]);
      // First frame of the first 440-byte packet (k = 0, r = 0).
      final firstMultiFrameStart = 24 * (4 + 79) + 4;
      expect(
        bytes.sublist(firstMultiFrameStart, firstMultiFrameStart + 80),
        [for (var j = 0; j < 80; j++) j & 0xFF],
      );

      // Progress reported was monotonically non-decreasing.
      for (var i = 1; i < progressReadings.length; i++) {
        expect(progressReadings[i], greaterThanOrEqualTo(progressReadings[i - 1]));
      }

      // startReadCalls has one entry with the expected offset.
      expect(device.storage.startReadCalls, hasLength(1));
      expect(device.storage.startReadCalls.single.offset, 0);

      // Device storage cleared after a successful sync.
      expect(device.storage.clearFileNumbers, isNotEmpty);
    });
  });

  group('cancelSync', () {
    test('sends stopRead and marks the wal failed', () async {
      final fixture = File('test/fixtures/omi_sdcard_transfer.jsonl').readAsStringSync();
      final device = FakeOmiDevice.fromJsonl(
        fixture,
        storageList: [100000, 0],
      );

      final service = SdCardSyncService(
        storage: device.storage,
        readCodec: () async => BleAudioCodec.opus,
      );

      final errors = <String>[];
      final syncFuture = service.startSync(
        onProgress: (_, __) {},
        onComplete: (_, __) {},
        onError: errors.add,
      );

      await Future<void>.delayed(Duration.zero);

      expect(service.isSyncing, isTrue);
      final wal = service.currentWal;

      await service.cancelSync();

      // cancelSync unwinds the waiting transfer, so this resolves now rather
      // than sitting on the service's `wal.seconds + 60` timeout.
      await syncFuture;

      expect(device.storage.stopReadCalls, 1);
      expect(wal?.status, WalStatus.failed);
      expect(service.isSyncing, isFalse);
      // A cancel is not a failure: no error callback is fired.
      expect(errors, isEmpty);
    });

    test('a cancelled transfer cannot abort the sync that replaces it', () async {
      final fixture = File('test/fixtures/omi_sdcard_transfer.jsonl').readAsStringSync();
      final device = FakeOmiDevice.fromJsonl(
        fixture,
        storageList: [100000, 0],
      );
      final service = SdCardSyncService(
        storage: device.storage,
        readCodec: () async => BleAudioCodec.opus,
      );

      final firstSync = service.startSync(
        onProgress: (_, __) {},
        onComplete: (_, __) {},
        onError: (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      await service.cancelSync();
      await firstSync;

      // Retry immediately, as a user would after cancelling.
      String? completedFilePath;
      String? errorMessage;
      final secondSync = service.startSync(
        onProgress: (_, __) {},
        onComplete: (filePath, _) => completedFilePath = filePath,
        onError: (error) => errorMessage = error,
      );
      await Future<void>.delayed(Duration.zero);
      await device.replay();
      await secondSync;

      expect(errorMessage, isNull);
      expect(completedFilePath, isNotNull);
      // Exactly the one stop the cancel sent — the abandoned transfer must
      // not fire a second 0x03 at the transfer that replaced it.
      expect(device.storage.stopReadCalls, 1);
      expect(device.storage.startReadCalls, hasLength(2));
    });
  });

  group('legacy migration', () {
    Future<void> writeLegacyFile(String path, List<int> contents) async {
      final file = File(path);
      file.parent.createSync(recursive: true);
      await file.writeAsBytes(contents);
    }

    test('moves a legacy sdcard_audio_ file into support/sdcard, preserving contents', () async {
      final documentsDir = Directory('${tempRoot.path}/documents')..createSync(recursive: true);
      final legacyPath = '${documentsDir.path}/sdcard_audio_opus_16000_1_111.bin';
      await writeLegacyFile(legacyPath, [1, 2, 3, 4, 5]);

      final moved = await SdCardSyncService.migrateLegacySyncedFiles();
      expect(moved, 1);

      final newPath = '${tempRoot.path}/support/sdcard/sdcard_audio_opus_16000_1_111.bin';
      final newFile = File(newPath);
      expect(newFile.existsSync(), isTrue);
      expect(await newFile.readAsBytes(), [1, 2, 3, 4, 5]);
      expect(File(legacyPath).existsSync(), isFalse);
    });

    test('an existing file at the new location wins and the legacy copy is removed', () async {
      final documentsDir = Directory('${tempRoot.path}/documents')..createSync(recursive: true);
      final legacyPath = '${documentsDir.path}/sdcard_audio_opus_16000_1_222.bin';
      await writeLegacyFile(legacyPath, [9, 9, 9]);

      final newDir = Directory('${tempRoot.path}/support/sdcard')..createSync(recursive: true);
      final newPath = '${newDir.path}/sdcard_audio_opus_16000_1_222.bin';
      await writeLegacyFile(newPath, [1, 1, 1]);

      final moved = await SdCardSyncService.migrateLegacySyncedFiles();
      expect(moved, 0);

      expect(File(legacyPath).existsSync(), isFalse);
      expect(await File(newPath).readAsBytes(), [1, 1, 1]);
    });

    test('running twice is a no-op the second time', () async {
      final documentsDir = Directory('${tempRoot.path}/documents')..createSync(recursive: true);
      final legacyPath = '${documentsDir.path}/sdcard_audio_opus_16000_1_333.bin';
      await writeLegacyFile(legacyPath, [7, 7]);

      final firstRun = await SdCardSyncService.migrateLegacySyncedFiles();
      expect(firstRun, 1);

      final secondRun = await SdCardSyncService.migrateLegacySyncedFiles();
      expect(secondRun, 0);
    });

    test('returns 0 rather than throwing when path_provider has no directory', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathProviderChannel, (call) async => null);

      final moved = await SdCardSyncService.migrateLegacySyncedFiles();
      expect(moved, 0);
    });
  });

  group('getSyncedFiles', () {
    test('lists files from the new support/sdcard/ location', () async {
      final newDir = Directory('${tempRoot.path}/support/sdcard')..createSync(recursive: true);
      final filePath = '${newDir.path}/sdcard_audio_opus_16000_1_444.bin';
      await File(filePath).writeAsBytes([1, 2, 3]);

      final files = await SdCardSyncService.getSyncedFiles();
      expect(files, hasLength(1));
      expect(files.single.filePath, filePath);
    });
  });
}
