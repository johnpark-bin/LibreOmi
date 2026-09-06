/// Installs, verifies, measures and removes the on-device speech models
/// described by `model_catalog.dart` (LO-40).
///
/// Models live under `getApplicationSupportDirectory()/models/<id>/`, which
/// on Android is `/data/user/0/<pkg>/files/models` — outside the Auto Backup
/// set once `res/xml/backup_rules.xml` excludes it, unlike the documents
/// directory the transcription services used to download into
/// (`docs/04-android-platform-notes.md` §8).
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'model_catalog.dart';

/// Where an install has got to. The store reports byte counts only while
/// [downloading]; extraction runs in a background isolate and cannot report
/// progress from inside the codec, so it is an indeterminate phase.
enum ModelInstallPhase { downloading, extracting, verifying, done }

/// One progress tick from [ModelStore.install].
class ModelInstallProgress {
  const ModelInstallProgress({
    required this.phase,
    this.receivedBytes = 0,
    this.totalBytes,
  });

  final ModelInstallPhase phase;

  /// Bytes downloaded so far. Zero outside [ModelInstallPhase.downloading].
  final int receivedBytes;

  /// Total bytes expected, or null when the server sent no `Content-Length`
  /// and the catalog has nothing to fall back on.
  final int? totalBytes;

  /// 0..1, or null when the total is unknown — the caller should show an
  /// indeterminate indicator then.
  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    final value = receivedBytes / total;
    return value < 0
        ? 0
        : value > 1
            ? 1
            : value;
  }

  @override
  String toString() =>
      'ModelInstallProgress($phase, $receivedBytes/${totalBytes ?? '?'})';
}

/// Passed into [ModelStore.install] to stop an install in flight.
///
/// Cancellation is cooperative and checked between downloaded chunks and at
/// each phase boundary. Once extraction has started it runs to completion in
/// its isolate — the store then throws away the staged files rather than
/// promoting them, so a cancel is still honoured, just not instantly.
class ModelInstallCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// Thrown by [ModelStore.install] when the caller cancelled it.
class ModelInstallCancelled implements Exception {
  const ModelInstallCancelled(this.modelId);

  final String modelId;

  @override
  String toString() => 'Model install cancelled: $modelId';
}

/// Thrown by [ModelStore.install] when the download or extraction failed.
class ModelInstallException implements Exception {
  const ModelInstallException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Thrown by [ModelStore.requireInstalledDir] when a transcription path asks
/// for a model the user has not downloaded.
///
/// [message] is written to be shown to the user as-is: it names the model and
/// points at the screen that can fix it, because the alternative — starting a
/// session that silently transcribes nothing — is worse.
class ModelNotInstalledException implements Exception {
  const ModelNotInstalledException(this.spec);

  final ModelSpec spec;

  String get message =>
      '${spec.displayName} is not downloaded yet. Open Settings → Models to '
      'download it (${_megabytes(spec.archiveBytes)} MB), then start again.';

  @override
  String toString() => message;
}

/// A directory found under the models root.
class InstalledModel {
  const InstalledModel({
    required this.id,
    required this.spec,
    required this.bytes,
    required this.complete,
  });

  final String id;

  /// The catalog entry this directory belongs to, or null for a directory
  /// left behind by a build whose catalog had an entry this one dropped.
  final ModelSpec? spec;

  final int bytes;

  /// True when every [ModelSpec.requiredFiles] entry is present and non-empty.
  /// Always false for an unknown [spec], which has no file list to check.
  final bool complete;
}

/// Resolves a directory lazily, so tests can hand the store a temp dir
/// instead of a plugin channel.
typedef DirectoryProvider = Future<Directory> Function();

class ModelStore {
  ModelStore({
    DirectoryProvider? supportDirectory,
    DirectoryProvider? legacyDocumentsDirectory,
    http.Client? client,
  })  : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
        _legacyDocumentsDirectory =
            legacyDocumentsDirectory ?? getApplicationDocumentsDirectory,
        _client = client;

  final DirectoryProvider _supportDirectory;
  final DirectoryProvider _legacyDocumentsDirectory;

  /// Null until the first download. Owned by the store when it creates one,
  /// and never closed: it lives as long as the process does.
  http.Client? _client;

  /// Subdirectories of the models root that hold work in progress rather than
  /// an installed model. Both start with a dot so they sort away from real
  /// entries and are easy to skip in [listInstalled].
  static const String _tempDirName = '.tmp';
  static const String _stagingPrefix = '.staging-';

  /// The legacy layout: the pre-LO-40 services downloaded into these two
  /// directories under `getApplicationDocumentsDirectory()`, keyed by the
  /// same model name that is now [ModelSpec.id].
  static const List<String> _legacySubdirectories = [
    'sherpa_models',
    'whisper_models',
  ];

  Future<Directory> _modelsRoot() async {
    final support = await _supportDirectory();
    final root = Directory('${support.path}/models');
    if (!root.existsSync()) {
      root.createSync(recursive: true);
    }
    return root;
  }

  /// The directory [spec] is (or would be) installed in. Does not create it
  /// and does not imply the model is there — see [isInstalled].
  Future<Directory> installedDir(ModelSpec spec) async {
    final root = await _modelsRoot();
    return Directory('${root.path}/${spec.directoryName}');
  }

  /// True when every file [spec] needs is present and non-empty.
  ///
  /// Size, not just existence: a download interrupted by a process kill under
  /// the old layout left zero-byte `.onnx` files behind, and sherpa-onnx
  /// crashes rather than reporting an error when handed one.
  Future<bool> isInstalled(ModelSpec spec) async {
    final dir = await installedDir(spec);
    return _hasAllRequiredFiles(dir, spec);
  }

  /// The installed directory path, or a [ModelNotInstalledException] the
  /// caller can surface to the user verbatim.
  Future<String> requireInstalledDir(ModelSpec spec) async {
    final dir = await installedDir(spec);
    if (!_hasAllRequiredFiles(dir, spec)) {
      throw ModelNotInstalledException(spec);
    }
    return dir.path;
  }

  /// Bytes [spec] occupies on disk, or 0 when it is not installed.
  Future<int> sizeOnDisk(ModelSpec spec) async {
    final dir = await installedDir(spec);
    return _directorySize(dir);
  }

  /// Removes [spec]'s directory. A no-op when it is not there.
  Future<void> delete(ModelSpec spec) => deleteById(spec.directoryName);

  /// Removes one directory under the models root by name.
  ///
  /// Takes an id rather than a [ModelSpec] so [listInstalled] entries with no
  /// catalog entry — models a previous build installed and this one no longer
  /// knows about — can still be deleted to reclaim their space. A no-op when
  /// the directory is not there.
  Future<void> deleteById(String id) async {
    final root = await _modelsRoot();
    final dir = Directory('${root.path}/$id');
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  }

  /// Everything sitting under the models root, including directories with no
  /// catalog entry and partial installs, so the models page can offer to
  /// reclaim their space.
  Future<List<InstalledModel>> listInstalled() async {
    final root = await _modelsRoot();
    final entries = <InstalledModel>[];
    for (final entity in root.listSync()) {
      if (entity is! Directory) continue;
      final id = entity.path.split(Platform.pathSeparator).last;
      if (id == _tempDirName || id.startsWith(_stagingPrefix)) continue;
      final spec = ModelCatalog.byId(id);
      entries.add(InstalledModel(
        id: id,
        spec: spec,
        bytes: _directorySize(entity),
        complete: spec != null && _hasAllRequiredFiles(entity, spec),
      ));
    }
    entries.sort((a, b) => a.id.compareTo(b.id));
    return entries;
  }

  /// Deletes leftover scratch directories from installs that died before
  /// their `finally` ran — a process kill mid-download leaves up to an
  /// archive's worth of bytes behind, and nothing else reclaims them:
  /// `install` only clears its own model's subtree, and [listInstalled]
  /// deliberately hides scratch from the models page.
  ///
  /// Call this at startup only. It removes work in progress, so running it
  /// while an install is live would break that install.
  Future<int> clearScratch() async {
    final root = await _modelsRoot();
    var removed = 0;
    for (final entity in root.listSync()) {
      if (entity is! Directory) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name != _tempDirName && !name.startsWith(_stagingPrefix)) continue;
      _deleteQuietly(entity);
      removed++;
    }
    return removed;
  }

  /// Moves any model left in the pre-LO-40 documents-directory layout into
  /// the support directory, and returns how many were moved.
  ///
  /// Idempotent, and never overwrites: a model already installed in the new
  /// layout wins and the old copy is deleted, because keeping it would just
  /// occupy a backed-up directory forever.
  Future<int> migrateLegacyInstalls() async {
    Directory documents;
    try {
      documents = await _legacyDocumentsDirectory();
    } catch (_) {
      // No documents directory (desktop tests, a platform without the
      // plugin): nothing to migrate.
      return 0;
    }
    final root = await _modelsRoot();
    var moved = 0;

    for (final subdirectory in _legacySubdirectories) {
      final legacy = Directory('${documents.path}/$subdirectory');
      if (!legacy.existsSync()) continue;

      for (final entity in legacy.listSync()) {
        if (entity is! Directory) continue;
        final id = entity.path.split(Platform.pathSeparator).last;
        final target = Directory('${root.path}/$id');
        if (target.existsSync()) {
          entity.deleteSync(recursive: true);
          continue;
        }
        try {
          entity.renameSync(target.path);
        } on FileSystemException {
          // Different filesystems: fall back to a copy, and only drop the
          // original once the copy is complete.
          _copyDirectory(entity, target);
          entity.deleteSync(recursive: true);
        }
        moved++;
      }

      if (legacy.listSync().isEmpty) {
        legacy.deleteSync();
      }
    }
    return moved;
  }

  /// Downloads, extracts and verifies [spec], emitting progress as it goes.
  ///
  /// Nothing happens until the returned stream is listened to. The stream
  /// ends after a [ModelInstallPhase.done] tick, or with a
  /// [ModelInstallCancelled] / [ModelInstallException] error.
  ///
  /// Installs of *different* models may overlap; each gets its own scratch
  /// and staging directory. Two installs of the same [spec] at once would
  /// share both and corrupt each other — the models page cannot start one,
  /// since a row shows Cancel rather than Download while it is installing. Either way the
  /// temporary and staging directories are cleaned up, and an install that
  /// fails leaves any previously installed copy of [spec] untouched: the new
  /// files are only swapped in once they have been verified.
  Stream<ModelInstallProgress> install(
    ModelSpec spec, {
    ModelInstallCancelToken? cancelToken,
  }) async* {
    final token = cancelToken ?? ModelInstallCancelToken();
    final root = await _modelsRoot();
    // Per-model subtree, not the shared `.tmp` directory: the models page
    // lets two downloads run at once, and recreating a shared directory
    // would delete the other install's half-written archive out from under
    // it — the sink would go on writing to an unlinked inode and the
    // decoder would then fail on a file that is no longer there.
    final tempDir = Directory('${root.path}/$_tempDirName/${spec.id}');
    final staging = Directory('${root.path}/$_stagingPrefix${spec.id}');
    final archive = File('${tempDir.path}/archive.tar.bz2');
    final tar = File('${tempDir.path}/archive.tar');

    try {
      _recreate(tempDir);
      _recreate(staging);

      // 1. Download. The only phase with a meaningful byte count, and the
      // only one the user waits minutes for.
      yield ModelInstallProgress(
        phase: ModelInstallPhase.downloading,
        totalBytes: spec.archiveBytes,
      );
      yield* _download(spec, archive, token);
      _throwIfCancelled(token, spec);

      // 2. Extract, in an isolate: bunzip2 over ~120 MB is seconds of solid
      // CPU and would otherwise freeze the UI thread.
      yield const ModelInstallProgress(phase: ModelInstallPhase.extracting);
      // Locals, not the File/Directory/ModelSpec objects: only plain
      // sendable values may be captured by the isolate closure.
      final archivePath = archive.path;
      final tarPath = tar.path;
      final stagingPath = staging.path;
      final topDirectory = spec.archiveTopDir;
      final requiredFiles = List<String>.of(spec.requiredFiles);
      final extracted = await Isolate.run(
        () => _extractRequiredFiles(
          archivePath: archivePath,
          tarPath: tarPath,
          destinationPath: stagingPath,
          topDirectory: topDirectory,
          requiredFiles: requiredFiles,
        ),
      );
      _throwIfCancelled(token, spec);

      // 3. Verify before anything is promoted.
      yield const ModelInstallProgress(phase: ModelInstallPhase.verifying);
      final missing = spec.requiredFiles
          .where((path) => !extracted.contains(path))
          .toList();
      if (missing.isNotEmpty) {
        throw ModelInstallException(
          'Archive for ${spec.id} is missing ${missing.join(', ')}',
        );
      }
      if (!_hasAllRequiredFiles(staging, spec)) {
        throw ModelInstallException(
          'Extracted files for ${spec.id} are incomplete or empty',
        );
      }

      // 4. Swap in. Deleting the old directory first keeps the window where
      // neither copy exists as short as a rename.
      final target = Directory('${root.path}/${spec.directoryName}');
      if (target.existsSync()) {
        target.deleteSync(recursive: true);
      }
      staging.renameSync(target.path);

      yield const ModelInstallProgress(phase: ModelInstallPhase.done);
    } finally {
      _deleteQuietly(tempDir);
      _deleteQuietly(staging);
    }
  }

  /// Streams the archive to [destination], yielding a tick per chunk.
  Stream<ModelInstallProgress> _download(
    ModelSpec spec,
    File destination,
    ModelInstallCancelToken token,
  ) async* {
    final client = _client ??= http.Client();
    final request = http.Request('GET', Uri.parse(spec.url));
    final response = await client.send(request);

    if (response.statusCode != 200) {
      throw ModelInstallException(
        'Download of ${spec.id} failed: HTTP ${response.statusCode}',
      );
    }

    // The catalog size is the fallback so the bar is still determinate on a
    // server that sends no Content-Length; the header wins when present
    // because it describes the bytes actually arriving.
    final total = response.contentLength ?? spec.archiveBytes;
    final sink = destination.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        if (token.isCancelled) break;
        sink.add(chunk);
        received += chunk.length;
        yield ModelInstallProgress(
          phase: ModelInstallPhase.downloading,
          receivedBytes: received,
          totalBytes: total,
        );
      }
    } finally {
      await sink.close();
    }

    _throwIfCancelled(token, spec);

    if (received == 0) {
      throw ModelInstallException('Download of ${spec.id} returned no data');
    }
  }

  void _throwIfCancelled(ModelInstallCancelToken token, ModelSpec spec) {
    if (token.isCancelled) {
      throw ModelInstallCancelled(spec.id);
    }
  }

  static bool _hasAllRequiredFiles(Directory dir, ModelSpec spec) {
    if (!dir.existsSync()) return false;
    for (final relative in spec.requiredFiles) {
      final file = File('${dir.path}/$relative');
      if (!file.existsSync() || file.lengthSync() == 0) return false;
    }
    return true;
  }

  static int _directorySize(Directory dir) {
    if (!dir.existsSync()) return 0;
    var bytes = 0;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is File) bytes += entity.lengthSync();
    }
    return bytes;
  }

  static void _recreate(Directory dir) {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
  }

  static void _deleteQuietly(FileSystemEntity entity) {
    try {
      if (entity.existsSync()) entity.deleteSync(recursive: true);
    } on FileSystemException {
      // A leftover temp file is not worth failing an otherwise good install
      // over; the next install recreates the directory anyway.
    }
  }

  static void _copyDirectory(Directory from, Directory to) {
    to.createSync(recursive: true);
    for (final entity in from.listSync(recursive: true, followLinks: false)) {
      final relative = entity.path.substring(from.path.length + 1);
      if (entity is Directory) {
        Directory('${to.path}/$relative').createSync(recursive: true);
      } else if (entity is File) {
        final target = File('${to.path}/$relative');
        target.parent.createSync(recursive: true);
        entity.copySync(target.path);
      }
    }
  }
}

/// Decompresses [archivePath] (`.tar.bz2`) and writes the entries named in
/// [requiredFiles] into [destinationPath], returning the ones it found.
///
/// Runs on its own isolate (see [ModelStore.install]), so it must stay a
/// top-level function over plain sendable arguments. Two passes over disk
/// rather than one in memory: bunzip2 streams into [tarPath], the tar reader
/// streams each wanted entry out of it, and nothing larger than one buffered
/// chunk is held at a time. [archivePath] is deleted once it has been
/// decompressed, so the three copies never coexist. Entries outside [requiredFiles] — the int8 copies
/// of every weight and the `test_wavs/` samples the upstream archives ship —
/// are skipped, which is most of the archive.
List<String> _extractRequiredFiles({
  required String archivePath,
  required String tarPath,
  required String destinationPath,
  required String topDirectory,
  required List<String> requiredFiles,
}) {
  final compressed = InputFileStream(archivePath);
  final tarOut = OutputFileStream(tarPath);
  try {
    BZip2Decoder().decodeStream(compressed, tarOut);
  } finally {
    tarOut.closeSync();
    compressed.closeSync();
  }
  // The compressed copy is dead weight from here on, and holding it would
  // put the peak at archive + tar + extracted files at once — around 350 MB
  // for the zipformer, which a nearly full phone may not have. Failing to
  // delete it costs disk, not correctness, so it must not fail the install:
  // `ModelStore.install` removes the whole scratch directory afterwards.
  try {
    File(archivePath).deleteSync();
  } on FileSystemException {
    // Ignored on purpose, see above.
  }

  final wanted = requiredFiles.toSet();
  final extracted = <String>[];
  final tarIn = InputFileStream(tarPath);
  try {
    TarDecoder().decodeStream(tarIn, callback: (file) {
      if (!file.isFile) return;
      final relative = _stripTopDirectory(file.name, topDirectory);
      if (relative == null || !wanted.contains(relative)) {
        file.closeSync();
        return;
      }
      final target = File('$destinationPath/$relative');
      target.parent.createSync(recursive: true);
      final out = OutputFileStream(target.path);
      try {
        file.writeContent(out);
      } finally {
        out.closeSync();
        file.closeSync();
      }
      extracted.add(relative);
    });
  } finally {
    tarIn.closeSync();
  }
  return extracted;
}

/// `sherpa-onnx-whisper-tiny/tiny-encoder.onnx` → `tiny-encoder.onnx`.
///
/// Returns null for an entry outside [topDirectory], which also rejects the
/// `../` paths a hostile archive would use to write outside the destination.
String? _stripTopDirectory(String name, String topDirectory) {
  final normalized = name.startsWith('./') ? name.substring(2) : name;
  final prefix = '$topDirectory/';
  if (!normalized.startsWith(prefix)) return null;
  final relative = normalized.substring(prefix.length);
  if (relative.isEmpty || relative.contains('..')) return null;
  return relative;
}

String _megabytes(int bytes) => (bytes / (1024 * 1024)).round().toString();
