/// Owns the SD-card page's state: what the device still holds, the transfer
/// in flight, the recordings already on the phone, and what each of them is
/// doing (LO-52, `docs/06-roadmap.md` M5).
///
/// The page used to hold all of this itself and reach past the controllers
/// into `services/sdcard_sync_service.dart`'s static file helpers, which made
/// every one of these transitions untestable. This class is the seam: it
/// takes the transfer service and the importer entry point as injected
/// closures, so a unit test drives the whole page state machine over a
/// `FakeOmiDevice` and an in-memory file store.
///
/// It deliberately owns no widgets and shows no dialogs — confirmation for
/// the destructive actions stays in `pages/sdcard_sync_page.dart`.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../l10n/l10n.dart';
import '../services/sdcard_sync_service.dart';
import '../session/sdcard_import.dart' show sdCardConversationTitle;

/// Where the synced `.bin` recordings on the phone are listed and deleted.
///
/// `SdCardSyncService` exposes these as static methods that call
/// `path_provider` directly, so a controller calling them straight would drag
/// a plugin channel into every unit test. Production keeps using them through
/// [SdCardSyncServiceFileStore]; tests substitute an in-memory double.
abstract class SyncedFileStore {
  Future<List<SyncedAudioFile>> list();

  /// `true` when the file was there and is now gone.
  Future<bool> delete(String filePath);

  /// The number of files actually removed.
  Future<int> deleteAll();
}

/// The production [SyncedFileStore]: the static helpers on
/// [SdCardSyncService], unchanged.
class SdCardSyncServiceFileStore implements SyncedFileStore {
  const SdCardSyncServiceFileStore();

  @override
  Future<List<SyncedAudioFile>> list() => SdCardSyncService.getSyncedFiles();

  @override
  Future<bool> delete(String filePath) =>
      SdCardSyncService.deleteSyncedFile(filePath);

  @override
  Future<int> deleteAll() => SdCardSyncService.deleteAllSyncedFiles();
}

/// Turns one synced recording into a conversation and returns its transcript.
/// In production this is `SessionController.processLocalAudioFile`, which
/// delegates to `session/sdcard_import.dart`.
typedef ProcessAudioFile = Future<String> Function(String filePath);

/// Where one synced recording is in the import pipeline.
///
/// [summarizing] covers the step between "the transcript exists" and "the
/// conversation is in the library": the reload and the removal of the `.bin`
/// the import consumed. It is not a report on the summariser itself --
/// `ConversationFinalizer.finalize` persists the conversation under a
/// placeholder title and *queues* the summarisation, and nothing here
/// observes that queue, which is why [done] still carries
/// [FileProcessState.summaryPending].
enum FileProcessStatus { idle, transcribing, summarizing, done, failed }

/// What the page shows for one synced recording.
@immutable
class FileProcessState {
  const FileProcessState({
    this.status = FileProcessStatus.idle,
    this.transcript,
    this.conversationTitle,
    this.summaryPending = false,
    this.error,
  });

  final FileProcessStatus status;

  /// The text the import produced, shown once [status] is
  /// [FileProcessStatus.done].
  final String? transcript;

  /// The title the conversation was saved under.
  final String? conversationTitle;

  /// The summariser had not run yet when the import returned, which is always
  /// the case today (see [FileProcessStatus.summarizing]).
  final bool summaryPending;

  /// Why the import failed, ready to show to the user.
  final String? error;

  bool get isBusy =>
      status == FileProcessStatus.transcribing ||
      status == FileProcessStatus.summarizing;
}

/// The SD-card page's state and the actions behind its buttons.
class SdCardController extends ChangeNotifier {
  SdCardController({
    required SdCardSyncService? Function() syncService,
    required bool Function() hasStorage,
    required ProcessAudioFile processFile,
    Listenable? deviceChanges,
    SyncedFileStore fileStore = const SdCardSyncServiceFileStore(),
    Future<void> Function()? onConversationImported,
  })  : _syncService = syncService,
        _hasStorage = hasStorage,
        _processFile = processFile,
        _fileStore = fileStore,
        _deviceChanges = deviceChanges,
        _onConversationImported = onConversationImported {
    // The service only exists once a device with storage is connected, so the
    // page's "not supported" view has to follow `DeviceController`.
    _deviceChanges?.addListener(_onDeviceChanged);
  }

  final SdCardSyncService? Function() _syncService;
  final bool Function() _hasStorage;
  final ProcessAudioFile _processFile;
  final SyncedFileStore _fileStore;
  final Listenable? _deviceChanges;
  final Future<void> Function()? _onConversationImported;

  bool _disposed = false;

  /// Whether the connected device offers SD-card storage at all.
  bool get hasStorage => _hasStorage();

  bool _checking = false;
  bool get checking => _checking;

  SdCardWal? _pending;

  /// What the device still holds, or `null` when there is nothing to sync.
  SdCardWal? get pending => _pending;

  bool _syncing = false;
  bool get syncing => _syncing;

  double _syncProgress = 0.0;

  /// 0.0 – 1.0, and never allowed to move backwards within one transfer, so
  /// the page's progress ring cannot jump back on a late packet.
  double get syncProgress => _syncProgress;

  int? _syncEtaSeconds;
  int? get syncEtaSeconds => _syncEtaSeconds;

  bool _clearing = false;
  bool get clearing => _clearing;

  String? _syncError;

  /// Why the last transfer failed, or `null` when the last one did not.
  /// The page shows its failure snackbar off this rather than off [status],
  /// which is a sentence meant for a human, not a flag.
  String? get syncError => _syncError;

  String _status = '';

  /// The one line of human-readable state the page's status card shows.
  String get status => _status;

  List<SyncedAudioFile> _syncedFiles = const [];
  List<SyncedAudioFile> get syncedFiles => _syncedFiles;

  /// Bytes the synced recordings take up on the phone.
  int get storageUsageBytes =>
      _syncedFiles.fold(0, (sum, file) => sum + file.sizeBytes);

  final Map<String, FileProcessState> _processing = {};

  /// Per-file import state, keyed by file path. Files never processed in this
  /// session are absent; [processStateOf] fills in the idle default.
  Map<String, FileProcessState> get processing => Map.unmodifiable(_processing);

  FileProcessState processStateOf(String filePath) =>
      _processing[filePath] ?? const FileProcessState();

  /// True while any recording is being imported.
  bool get isProcessing => _processing.values.any((state) => state.isBusy);

  void _onDeviceChanged() {
    // `hasStorage` is read through the closure, so there is nothing to
    // recompute -- but the moment it turns true is the moment there is
    // something to ask the device about. Without this, a page opened before
    // the device connected would keep claiming "All Caught Up!" until the
    // user tapped "Check Again".
    final hasStorageNow = hasStorage;
    final appeared = hasStorageNow && !_hadStorage;
    _hadStorage = hasStorageNow;
    _notify();
    if (appeared) unawaited(refreshPending());
  }

  /// What [hasStorage] read the last time the device notified, so the
  /// false -> true edge can be spotted.
  bool _hadStorage = false;

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// Forgets the results of imports that have finished.
  ///
  /// The controller outlives the page (it is app-scoped in `main.dart`),
  /// where the page's own state used to die on pop -- so without this, every
  /// result card ever produced would still be on screen the next time the
  /// page is opened. In-flight imports are kept: they are still happening.
  void clearFinishedResults() {
    _processing.removeWhere((_, state) => !state.isBusy);
    _notify();
  }

  /// First load: what is on the device, and what is already on the phone.
  Future<void> load() async {
    await Future.wait([refreshPending(), refreshSyncedFiles()]);
  }

  /// Asks the device what it still holds.
  Future<void> refreshPending() async {
    final service = _syncService();
    if (!hasStorage || service == null) {
      _pending = null;
      _status = L10n.current.sdcardController_notSupportedStatus;
      _notify();
      return;
    }

    _checking = true;
    _status = L10n.current.sdcardController_checkingStatus;
    _notify();

    SdCardWal? wal;
    try {
      wal = await service.checkForPendingData();
    } catch (e) {
      _checking = false;
      _pending = null;
      _status = L10n.current.sdcardController_checkFailedStatus('$e');
      _notify();
      return;
    }

    _checking = false;
    _pending = wal;
    _status = wal != null
        ? L10n.current.sdcardController_foundPendingStatus(
            wal.durationFormatted, wal.sizeFormatted)
        : L10n.current.sdcardController_noPendingStatus;
    _notify();
  }

  /// Re-lists the recordings already on the phone.
  Future<void> refreshSyncedFiles() async {
    try {
      _syncedFiles = await _fileStore.list();
    } catch (e) {
      debugPrint('Failed to list synced files: $e');
      _syncedFiles = const [];
    }
    // Per-file state is deliberately *not* pruned against the listing here:
    // a finished import deletes its own `.bin`, and dropping its state would
    // blank the result the page has just been asked to show. The delete
    // actions below forget the state of what the user removes instead.
    _notify();
  }

  /// Pulls the pending recording off the device. Returns the path of the
  /// saved `.bin`, or `null` when the transfer did not produce one.
  Future<String?> startSync() async {
    // Cleared before the guard, not after: an early return must not leave
    // the page holding the previous transfer's error.
    _syncError = null;
    final service = _syncService();
    if (service == null || _syncing) return null;

    _syncing = true;
    _syncProgress = 0.0;
    _syncEtaSeconds = null;
    _status = L10n.current.sdcardController_startingSyncStatus;
    _notify();

    String? syncedPath;
    await service.startSync(
      onProgress: (progress, status) {
        // Monotonic on purpose: `SdCardTransfer` reports progress off byte
        // offsets, and a retried chunk must not rewind the ring.
        if (progress > _syncProgress) _syncProgress = progress;
        _syncEtaSeconds = service.currentWal?.syncEtaSeconds;
        _status = status;
        _notify();
      },
      onComplete: (filePath, durationSeconds) {
        syncedPath = filePath;
        _syncing = false;
        _syncProgress = 1.0;
        _syncEtaSeconds = null;
        _status = L10n.current.sdcardController_syncCompleteStatus;
        _notify();
      },
      onError: (error) {
        _syncing = false;
        _syncError = error;
        _status = L10n.current.sdcardController_syncErrorStatus(error);
        _notify();
      },
    );

    if (syncedPath != null) {
      await refreshSyncedFiles();
      await refreshPending();
    }
    return syncedPath;
  }

  /// Stops an in-flight transfer. The partial data stays on the device.
  Future<void> cancelSync() async {
    final service = _syncService();
    await service?.cancelSync();
    _syncing = false;
    _syncProgress = 0.0;
    _syncEtaSeconds = null;
    // A cancel is the user's decision, not a failure to report back to them.
    _syncError = null;
    _status = L10n.current.sdcardController_syncCancelledStatus;
    _notify();
  }

  /// Transcribes one synced recording into a conversation.
  ///
  /// The `.bin` is deleted only on success, matching the contract
  /// `session/sdcard_import.dart` documents: an import that throws leaves the
  /// recording in place so it can be retried.
  Future<void> processFile(String filePath) async {
    if (processStateOf(filePath).isBusy) return;

    _processing[filePath] =
        const FileProcessState(status: FileProcessStatus.transcribing);
    _status = L10n.current.sdcardController_transcribingStatus;
    _notify();

    final String transcript;
    try {
      transcript = await _processFile(filePath);
    } catch (e) {
      _processing[filePath] = FileProcessState(
        status: FileProcessStatus.failed,
        error: '$e',
      );
      _status = L10n.current.sdcardController_transcriptionFailedStatus;
      _notify();
      return;
    }

    // The conversation is persisted by now, but under the placeholder title
    // `ConversationFinalizer` queues the summarisation behind.
    _processing[filePath] = FileProcessState(
      status: FileProcessStatus.summarizing,
      transcript: transcript,
      conversationTitle: sdCardConversationTitle,
      summaryPending: true,
    );
    _status = L10n.current.sdcardController_savedWaitingStatus;
    _notify();

    try {
      await _onConversationImported?.call();
    } catch (e) {
      debugPrint('Failed to reload the library after an import: $e');
    }

    // Deleted through the store rather than [deleteFile], which forgets the
    // per-file state -- and this file's state is the result to show.
    await _fileStore.delete(filePath);
    await refreshSyncedFiles();

    _processing[filePath] = FileProcessState(
      status: FileProcessStatus.done,
      transcript: transcript,
      conversationTitle: sdCardConversationTitle,
      summaryPending: true,
    );
    _status = L10n.current.sdcardController_processingCompleteStatus;
    _notify();
  }

  /// Deletes one synced recording from the phone.
  Future<bool> deleteFile(String filePath) async {
    final deleted = await _fileStore.delete(filePath);
    if (deleted) {
      _processing.remove(filePath);
      await refreshSyncedFiles();
    }
    return deleted;
  }

  /// Deletes every synced recording from the phone. Returns how many went.
  Future<int> deleteAll() async {
    // Only the listed files are the ones this removes -- an import that
    // already consumed its own `.bin` is not in the listing, and its result
    // card must survive.
    final removedPaths =
        _syncedFiles.map((file) => file.filePath).toSet();
    final deleted = await _fileStore.deleteAll();
    _processing.removeWhere((path, _) => removedPaths.contains(path));
    await refreshSyncedFiles();
    return deleted;
  }

  /// Wipes the device's own SD card, losing anything not synced yet.
  Future<bool> clearDeviceStorage() async {
    final service = _syncService();
    if (service == null) return false;

    _clearing = true;
    _status = L10n.current.sdcardController_clearingStorageStatus;
    _notify();

    bool success;
    try {
      success = await service.clearDeviceStorage();
    } catch (e) {
      success = false;
      debugPrint('Failed to clear device storage: $e');
    }

    _clearing = false;
    if (success) {
      // The device reports the new state on the next read, so the page shows
      // nothing pending until a refresh confirms it.
      _pending = null;
      _status = L10n.current.sdcardController_storageClearedStatus;
    } else {
      _status = L10n.current.sdcardController_clearStorageFailedStatus;
    }
    _notify();
    return success;
  }

  @override
  void dispose() {
    _disposed = true;
    _deviceChanges?.removeListener(_onDeviceChanged);
    super.dispose();
  }
}
