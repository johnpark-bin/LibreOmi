/// SD Card Sync Service for Omi device
/// Handles reading audio data from Omi's SD card storage, syncing to phone,
/// transcribing, and deleting from device.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../device/omi_gatt.dart';
import '../device/omi_storage.dart';
import 'sdcard_transfer.dart';

/// Represents a WAL (Write-Ahead Log) file from SD card
enum WalStatus {
  pending,    // Found on device, not yet synced
  syncing,    // Currently being synced
  synced,     // Successfully synced
  failed,     // Sync failed
}

class SdCardWal {
  final int timerStart;
  final BleAudioCodec codec;
  final int storageOffset;
  final int storageTotalBytes;
  int seconds;
  WalStatus status;
  String? localFilePath;
  
  /// Progress 0.0 - 1.0
  double syncProgress = 0.0;
  
  /// Estimated time remaining in seconds
  int? syncEtaSeconds;
  
  SdCardWal({
    required this.timerStart,
    required this.codec,
    required this.storageOffset,
    required this.storageTotalBytes,
    required this.seconds,
    this.status = WalStatus.pending,
    this.localFilePath,
  });
  
  String get id => 'sdcard_$timerStart';
  
  int get bytesToSync => storageTotalBytes - storageOffset;
  
  String get durationFormatted {
    final mins = seconds ~/ 60;
    final secs = seconds % 60;
    if (mins > 0) {
      return '${mins}m ${secs}s';
    }
    return '${secs}s';
  }
  
  String get sizeFormatted {
    final bytes = bytesToSync;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Represents a locally synced audio file
class SyncedAudioFile {
  final String filePath;
  final String fileName;
  final int sizeBytes;
  final DateTime createdAt;
  final int? durationSeconds;
  final BleAudioCodec? codec;
  bool isProcessed;
  
  SyncedAudioFile({
    required this.filePath,
    required this.fileName,
    required this.sizeBytes,
    required this.createdAt,
    this.durationSeconds,
    this.codec,
    this.isProcessed = false,
  });
  
  String get sizeFormatted {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  
  String get durationFormatted {
    if (durationSeconds == null) return 'Unknown';
    final mins = durationSeconds! ~/ 60;
    final secs = durationSeconds! % 60;
    if (mins > 0) {
      return '${mins}m ${secs}s';
    }
    return '${secs}s';
  }
  
  String get dateFormatted {
    final now = DateTime.now();
    final diff = now.difference(createdAt);
    
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    
    return '${createdAt.month}/${createdAt.day}/${createdAt.year}';
  }
}

/// Sync progress listener callback
typedef SyncProgressCallback = void Function(double progress, String status);

/// Sync complete callback - provides path to saved audio file
typedef SyncCompleteCallback = void Function(String filePath, int durationSeconds);

/// Error callback
typedef SyncErrorCallback = void Function(String error);

/// Thrown internally to unwind an in-flight `_performSync` when
/// [SdCardSyncService.cancelSync] is called. Never surfaced to callers: by
/// the time it is thrown, `cancelSync` has already told the device to stop,
/// torn the subscription down and reset the sync state, so there is nothing
/// left to report as a failure.
class _SyncCancelled implements Exception {
  const _SyncCancelled();

  @override
  String toString() => 'sync cancelled';
}

class SdCardSyncService {
  final OmiStorage _storage;
  final Future<BleAudioCodec> Function() _readCodec;

  StreamSubscription? _storageSubscription;

  /// Bumped for every transfer, and again by [cancelSync]. A `_performSync`
  /// body only owns the shared state (`_storageSubscription`, the storage
  /// stream, the stop command) while its own generation is still the current
  /// one — otherwise a cancelled transfer's late timeout would abort the
  /// transfer that replaced it.
  int _transferGeneration = 0;

  /// The completer the current `_performSync` is waiting on, so [cancelSync]
  /// can unwind it instead of leaving it pending for `wal.seconds + 60`.
  Completer<void>? _activeCompleter;
  
  // Current sync state
  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;
  
  SdCardWal? _currentWal;
  SdCardWal? get currentWal => _currentWal;
  
  // Sync callbacks
  SyncProgressCallback? onProgress;
  SyncCompleteCallback? onComplete;
  SyncErrorCallback? onError;
  
  // Chunking constants
  static const int chunkSizeFrames = 6000; // ~60 seconds at 100fps
  
  /// Takes an [OmiStorage] rather than an [OmiDevice] so the SD-card path can
  /// be driven by a fake in tests, and a codec reader rather than the device
  /// itself for the same reason. The transfer loop itself is driven by
  /// [SdCardTransfer] over [OmiStorage.packets] (LO-50).
  SdCardSyncService({
    required OmiStorage storage,
    required Future<BleAudioCodec> Function() readCodec,
  })  : _storage = storage,
        _readCodec = readCodec;

  /// Check if SD card has data to sync
  Future<SdCardWal?> checkForPendingData() async {
    try {
      final storageList = await _storage.list();
      if (storageList.isEmpty) {
        debugPrint('No storage data available');
        return null;
      }
      
      final totalBytes = storageList[0];
      if (totalBytes <= 0) {
        debugPrint('Storage is empty');
        return null;
      }
      
      final storageOffset = storageList.length >= 2 ? storageList[1] : 0;
      if (storageOffset > totalBytes) {
        debugPrint('Bad storage state: offset > total');
        return null;
      }
      
      // Get audio codec
      final codec = await _readCodec();
      
      // Calculate duration - minimum 10 seconds to be worth syncing
      final bytesToSync = totalBytes - storageOffset;
      final framesPerSecond = codec.getFramesPerSecond();
      final frameLengthBytes = codec.getFramesLengthInBytes();
      final seconds = (bytesToSync / frameLengthBytes) ~/ framesPerSecond;
      
      if (seconds < 10) {
        debugPrint('Not enough data to sync: ${seconds}s');
        return null;
      }
      
      final timerStart = DateTime.now().millisecondsSinceEpoch ~/ 1000 - seconds;
      
      final wal = SdCardWal(
        timerStart: timerStart,
        codec: codec,
        storageOffset: storageOffset,
        storageTotalBytes: totalBytes,
        seconds: seconds,
      );
      
      debugPrint('Found SD card data: ${wal.durationFormatted} (${wal.sizeFormatted})');
      return wal;
      
    } catch (e) {
      debugPrint('Error checking SD card data: $e');
      return null;
    }
  }
  
  /// Start syncing SD card data
  Future<void> startSync({
    SyncProgressCallback? onProgress,
    SyncCompleteCallback? onComplete,
    SyncErrorCallback? onError,
  }) async {
    if (_isSyncing) {
      onError?.call('Sync already in progress');
      return;
    }
    
    this.onProgress = onProgress;
    this.onComplete = onComplete;
    this.onError = onError;
    
    // Check for pending data
    final wal = await checkForPendingData();
    if (wal == null) {
      onError?.call('No data to sync');
      return;
    }
    
    _currentWal = wal;
    _isSyncing = true;
    wal.status = WalStatus.syncing;
    
    onProgress?.call(0.0, 'Starting sync...');
    
    try {
      await _performSync(wal);
    } on _SyncCancelled {
      // cancelSync() already reset the state and stopped the device.
      debugPrint('Sync cancelled mid-transfer');
    } catch (e) {
      wal.status = WalStatus.failed;
      _isSyncing = false;
      onError?.call('Sync failed: $e');
      debugPrint('Sync error: $e');
    }
  }
  
  Future<void> _performSync(SdCardWal wal) async {
    debugPrint('Starting SD card sync: offset=${wal.storageOffset}, total=${wal.storageTotalBytes}');

    final startTime = DateTime.now();
    final transfer = SdCardTransfer(
      startOffset: wal.storageOffset,
      totalBytes: wal.storageTotalBytes,
    );

    final generation = ++_transferGeneration;
    final completer = Completer<void>();
    _activeCompleter = completer;
    bool hasError = false;
    Timer? timeoutTimer;

    // Start storage stream listener
    await _storage.startStream();

    _storageSubscription = _storage.packets.listen((StoragePacket packet) {
      if (hasError) return;

      // Cancel timeout once feed() reports we've received real data.
      final hadReceivedData = transfer.hasReceivedData;
      final outcome = transfer.feed(packet);
      if (!hadReceivedData && transfer.hasReceivedData) {
        timeoutTimer?.cancel();
        debugPrint('First data received from SD card');
      }

      if (packet.kind == StoragePacketKind.status) {
        debugPrint('Storage command response: ${packet.rawCode}');
      }

      switch (outcome) {
        case TransferOutcome.complete:
          debugPrint('Storage: Transfer complete');
          if (!completer.isCompleted) completer.complete();
          return;
        case TransferOutcome.empty:
          debugPrint('Storage: File is empty');
          if (!completer.isCompleted) completer.complete();
          return;
        case TransferOutcome.failed:
          debugPrint('Storage: Error code ${packet.rawCode}');
          hasError = true;
          if (!completer.isCompleted) completer.complete();
          return;
        case TransferOutcome.continuing:
          break;
      }

      // Update progress
      wal.syncProgress = transfer.progress;

      // Calculate ETA
      final elapsed = DateTime.now().difference(startTime);
      final eta = transfer.etaSeconds(elapsed);
      if (eta != null) {
        wal.syncEtaSeconds = eta;
      }

      onProgress?.call(wal.syncProgress, 'Syncing: ${(wal.syncProgress * 100).toInt()}%');
    });

    // Start transfer from device
    await _storage.startRead(wal.storageOffset);

    // Timeout for first data (5 seconds)
    timeoutTimer = Timer(const Duration(seconds: 5), () {
      if (!transfer.hasReceivedData && !completer.isCompleted) {
        hasError = true;
        completer.completeError(TimeoutException('No data received from SD card'));
      }
    });

    // Wait for transfer to complete
    try {
      await completer.future.timeout(
        Duration(seconds: wal.seconds + 60), // Give extra time beyond expected duration
        onTimeout: () {
          throw TimeoutException('Transfer timed out');
        },
      );
    } catch (e) {
      hasError = true;
      // Only stop the device if this transfer is still the current one: a
      // cancelled transfer's timeout must not abort its replacement.
      if (generation == _transferGeneration) await _stopRead();
      rethrow;
    } finally {
      timeoutTimer.cancel();
      if (generation == _transferGeneration) {
        await _storageSubscription?.cancel();
        _storageSubscription = null;
        await _storage.stopStream();
        _activeCompleter = null;
      }
    }

    // The awaits in the teardown above are real BLE round-trips, so a cancel
    // can land while they run. Everything below acts on the device (stop,
    // clear) and on the caller's callbacks, so an abandoned transfer must not
    // reach it.
    if (generation != _transferGeneration) throw const _SyncCancelled();

    if (hasError) {
      await _stopRead();
      throw Exception('Transfer failed');
    }

    // Save frames to file
    final frames = transfer.frames;
    if (frames.isNotEmpty) {
      final filePath = await _saveFramesToFile(frames, wal);
      wal.localFilePath = filePath;
      wal.status = WalStatus.synced;

      debugPrint('Saved ${frames.length} frames to: $filePath');

      // Clear data from device
      await _clearDeviceStorage(wal);

      _isSyncing = false;
      onProgress?.call(1.0, 'Sync complete!');
      onComplete?.call(filePath, wal.seconds);
    } else {
      _isSyncing = false;
      throw Exception('No frames received');
    }
  }

  /// Asks the device to stop an in-flight transfer, tolerating a
  /// false/throwing result so a teardown path never fails because of this.
  Future<void> _stopRead() async {
    try {
      await _storage.stopRead();
    } catch (e) {
      debugPrint('Warning: stopRead failed: $e');
    }
  }
  
  /// Directory synced `.bin` files live in: `<application support>/sdcard/`
  /// (docs/04-android-platform-notes.md §8), created if missing.
  static Future<Directory> _sdcardDirectory() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}/sdcard');
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    return directory;
  }

  /// One-time migration of `sdcard_audio_*` files left in
  /// `getApplicationDocumentsDirectory()` by pre-LO-50 builds into
  /// `<application support>/sdcard/`.
  ///
  /// Prefers an already-present file at the new location (dropping the
  /// stale legacy duplicate) and falls back to copy+delete on a
  /// cross-filesystem [FileSystemException], mirroring
  /// `ModelStore.migrateLegacyInstalls`. Returns `0` (rather than
  /// throwing) when `path_provider` has no directory to offer, e.g. on
  /// desktop test hosts.
  ///
  /// Called from [getSyncedFiles] so a user upgrading from a pre-LO-50 build
  /// still sees their existing recordings; it is idempotent and costs one
  /// directory listing once the legacy directory is empty.
  static Future<int> migrateLegacySyncedFiles() async {
    Directory documents;
    Directory target;
    try {
      documents = await getApplicationDocumentsDirectory();
      if (!documents.existsSync()) return 0;
      target = await _sdcardDirectory();
    } catch (_) {
      return 0;
    }

    List<FileSystemEntity> entries;
    try {
      entries = documents.listSync();
    } catch (e) {
      debugPrint('Legacy sdcard migration: cannot list documents: $e');
      return 0;
    }

    var moved = 0;

    for (final entity in entries) {
      if (entity is! File) continue;
      final fileName = entity.path.split(Platform.pathSeparator).last;
      if (!fileName.contains('sdcard_audio_')) continue;

      // One unreadable or vanished file must cost that file only: callers
      // list synced recordings through this, and a throw here would take the
      // whole listing down.
      try {
        final destinationPath = '${target.path}/$fileName';
        final destination = File(destinationPath);
        if (destination.existsSync()) {
          entity.deleteSync();
          continue;
        }

        try {
          entity.renameSync(destinationPath);
        } on FileSystemException {
          entity.copySync(destinationPath);
          entity.deleteSync();
        }
        moved++;
      } catch (e) {
        debugPrint('Legacy sdcard migration: skipped $fileName: $e');
      }
    }

    return moved;
  }

  /// Save audio frames to a local file
  Future<String> _saveFramesToFile(List<List<int>> frames, SdCardWal wal) async {
    final directory = await _sdcardDirectory();
    final filename = 'sdcard_audio_${wal.codec.name}_16000_1_${wal.timerStart}.bin';
    final filePath = '${directory.path}/$filename';
    
    final file = File(filePath);
    final sink = file.openWrite();
    
    for (final frame in frames) {
      // Format: <4 bytes length><data>
      sink.add([
        frame.length & 0xFF,
        (frame.length >> 8) & 0xFF,
        (frame.length >> 16) & 0xFF,
        (frame.length >> 24) & 0xFF,
      ]);
      sink.add(frame);
    }
    
    await sink.close();
    
    return filePath;
  }
  
  /// Clear synced data from device
  Future<void> _clearDeviceStorage(SdCardWal wal) async {
    try {
      // Command 1 = clear/acknowledge processed data
      // Parameters: fileNum (1 for SD card), command (1 = clear), offset (0)
      await _storage.clear();
      debugPrint('Cleared SD card storage after syncing ${wal.storageTotalBytes} bytes');
    } catch (e) {
      debugPrint('Warning: Failed to clear device storage: $e');
      // Don't throw - data is already saved locally
    }
  }
  
  /// Cancel ongoing sync
  Future<void> cancelSync() async {
    if (!_isSyncing) return;

    // Invalidate the in-flight transfer before touching shared state, so its
    // own teardown becomes a no-op instead of racing the next sync.
    _transferGeneration++;
    final pending = _activeCompleter;
    _activeCompleter = null;

    await _stopRead();
    await _storageSubscription?.cancel();
    _storageSubscription = null;
    await _storage.stopStream();

    // Unwind the waiter rather than leaving it pending for `seconds + 60`.
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const _SyncCancelled());
    }

    if (_currentWal != null) {
      _currentWal!.status = WalStatus.failed;
    }
    
    _isSyncing = false;
    _currentWal = null;
    
    debugPrint('Sync cancelled');
  }
  
  /// Read and decode a synced audio file
  /// Returns PCM audio data ready for transcription
  static Future<Uint8List?> readAudioFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) {
        debugPrint('Audio file not found: $filePath');
        return null;
      }
      
      final bytes = await file.readAsBytes();
      final frames = <List<int>>[];
      
      int offset = 0;
      while (offset < bytes.length - 4) {
        final length = bytes[offset] |
                      (bytes[offset + 1] << 8) |
                      (bytes[offset + 2] << 16) |
                      (bytes[offset + 3] << 24);
        offset += 4;
        
        if (offset + length > bytes.length) break;
        
        frames.add(bytes.sublist(offset, offset + length));
        offset += length;
      }
      
      debugPrint('Read ${frames.length} frames from audio file');
      
      // Concatenate all frames
      final allBytes = <int>[];
      for (final frame in frames) {
        allBytes.addAll(frame);
      }
      
      return Uint8List.fromList(allBytes);
    } catch (e) {
      debugPrint('Error reading audio file: $e');
      return null;
    }
  }
  
  /// Delete a synced audio file
  static Future<void> deleteAudioFile(String filePath) async {
    try {
      final file = File(filePath);
      if (file.existsSync()) {
        await file.delete();
        debugPrint('Deleted audio file: $filePath');
      }
    } catch (e) {
      debugPrint('Error deleting audio file: $e');
    }
  }
  
  /// Get list of synced audio files with metadata
  static Future<List<SyncedAudioFile>> getSyncedFiles() async {
    // Runs before the listing so a user upgrading from a pre-LO-50 build
    // still sees the files that build wrote to the documents directory.
    // Idempotent, and cheap once the legacy directory holds nothing.
    await migrateLegacySyncedFiles();
    final directory = await _sdcardDirectory();
    final files = <SyncedAudioFile>[];
    
    for (final entity in directory.listSync()) {
      if (entity is File && entity.path.contains('sdcard_audio_')) {
        try {
          final stat = await entity.stat();
          final fileName = entity.path.split('/').last;
          
          // Parse codec and timestamp from filename
          // Format: sdcard_audio_{codec}_16000_1_{timestamp}.bin
          BleAudioCodec? codec;
          int? durationSeconds;
          
          if (fileName.contains('opus')) {
            codec = BleAudioCodec.opus;
            // Estimate duration: ~100 bytes per second for opus
            durationSeconds = stat.size ~/ 800;
          } else if (fileName.contains('pcm8')) {
            codec = BleAudioCodec.pcm8;
            durationSeconds = stat.size ~/ 16000;
          }
          
          files.add(SyncedAudioFile(
            filePath: entity.path,
            fileName: fileName,
            sizeBytes: stat.size,
            createdAt: stat.modified,
            durationSeconds: durationSeconds,
            codec: codec,
          ));
        } catch (e) {
          debugPrint('Error reading file info: $e');
        }
      }
    }
    
    // Sort by date, newest first
    files.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    
    return files;
  }
  
  /// Delete a specific synced audio file
  static Future<bool> deleteSyncedFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
        debugPrint('Deleted synced file: $filePath');
        return true;
      }
    } catch (e) {
      debugPrint('Error deleting file: $e');
    }
    return false;
  }
  
  /// Delete all synced audio files
  static Future<int> deleteAllSyncedFiles() async {
    final files = await getSyncedFiles();
    int deleted = 0;
    
    for (final file in files) {
      if (await deleteSyncedFile(file.filePath)) {
        deleted++;
      }
    }
    
    return deleted;
  }
  
  /// Clear all data from device SD card
  Future<bool> clearDeviceStorage() async {
    try {
      // Command 1 = clear storage
      final success = await _storage.clear();
      if (success) {
        debugPrint('Cleared device SD card storage');
      }
      return success;
    } catch (e) {
      debugPrint('Error clearing device storage: $e');
      return false;
    }
  }
  
  void dispose() {
    // Invalidate any in-flight transfer so its tail cannot act on a disposed
    // service, and unwind its waiter rather than leaving it parked for
    // `wal.seconds + 60`.
    _transferGeneration++;
    final pending = _activeCompleter;
    _activeCompleter = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const _SyncCancelled());
    }
    _storageSubscription?.cancel();
    _storageSubscription = null;
    _isSyncing = false;
  }
}

