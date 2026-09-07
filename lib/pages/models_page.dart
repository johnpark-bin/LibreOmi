/// Settings screen for downloading and removing the on-device speech models
/// described by `transcription/model_catalog.dart` (LO-40).
///
/// An install lives on this page: [State.dispose] cancels the subscription,
/// which stops the generator in `ModelStore.install` and cleans its temporary
/// files up, so leaving the screen abandons a download in progress. Surviving
/// navigation would mean hoisting the install into a controller or a
/// foreground service, which LO-40 does not need.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../transcription/model_catalog.dart';
import '../transcription/model_store.dart';

class ModelsPage extends StatefulWidget {
  ModelsPage({super.key, ModelStore? store}) : store = store ?? ModelStore();

  /// Injected for widget tests so they never touch a plugin channel or the
  /// real network.
  final ModelStore store;

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  /// Whether each catalog entry is currently installed.
  final Map<String, bool> _installed = {};

  /// On-disk size of each installed catalog entry, in bytes.
  final Map<String, int> _sizes = {};

  /// Progress of an install in flight, keyed by [ModelSpec.id]. Absent when
  /// nothing is installing for that model.
  final Map<String, ModelInstallProgress> _progress = {};

  /// Cancel tokens for installs in flight, so the Cancel button can reach
  /// the right one.
  final Map<String, ModelInstallCancelToken> _cancelTokens = {};

  /// Subscriptions for installs in flight, cancelled in [dispose].
  final Map<String, StreamSubscription<ModelInstallProgress>> _subscriptions =
      {};

  /// Directories `store.listInstalled()` reports with no matching catalog
  /// entry — left behind by a build whose catalog has since dropped them.
  List<InstalledModel> _unknown = [];

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions.values) {
      subscription.cancel();
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    final installed = <String, bool>{};
    final sizes = <String, int>{};
    List<InstalledModel> unknown;
    try {
      for (final spec in ModelCatalog.all) {
        final isInstalled = await widget.store.isInstalled(spec);
        installed[spec.id] = isInstalled;
        sizes[spec.id] = isInstalled ? await widget.store.sizeOnDisk(spec) : 0;
      }
      final listed = await widget.store.listInstalled();
      unknown = listed.where((m) => m.spec == null).toList();
    } catch (e) {
      // A store that cannot reach its directory at all (no support directory
      // on this platform, no permission) must not leave the page spinning
      // forever: drop the loading state and say what happened.
      if (!mounted) return;
      setState(() => _loading = false);
      _showMessage('Could not read installed models: $e');
      return;
    }

    if (!mounted) return;
    setState(() {
      _installed
        ..clear()
        ..addAll(installed);
      _sizes
        ..clear()
        ..addAll(sizes);
      _unknown = unknown;
      _loading = false;
    });
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _startInstall(ModelSpec spec) {
    final token = ModelInstallCancelToken();
    setState(() {
      _cancelTokens[spec.id] = token;
      _progress[spec.id] =
          const ModelInstallProgress(phase: ModelInstallPhase.downloading);
    });

    _subscriptions[spec.id] = widget.store.install(spec, cancelToken: token).listen(
      (progress) {
        if (!mounted) return;
        setState(() => _progress[spec.id] = progress);
      },
      onError: (Object error) {
        if (!mounted) return;
        // A cancel is the user's own action: return to the not-installed
        // state quietly rather than treating it as a failure.
        if (error is ModelInstallCancelled) return;
        final message = error is ModelInstallException
            ? error.message
            : error is ModelNotInstalledException
                ? error.message
                : error.toString();
        _showMessage(message);
      },
      onDone: () async {
        if (!mounted) return;
        setState(() {
          _progress.remove(spec.id);
          _cancelTokens.remove(spec.id);
          _subscriptions.remove(spec.id);
        });
        await _refresh();
      },
    );
  }

  void _cancelInstall(ModelSpec spec) {
    _cancelTokens[spec.id]?.cancel();
  }

  Future<void> _confirmDelete({
    required String title,
    required VoidCallback onConfirmed,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete $title?'),
        content: const Text(
          'This removes the downloaded model from your device. '
          'You can download it again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) onConfirmed();
  }

  Future<void> _deleteSpec(ModelSpec spec) async {
    try {
      await widget.store.delete(spec);
    } catch (e) {
      _showMessage('Could not delete ${spec.displayName}: $e');
    }
    await _refresh();
  }

  /// Removes an [InstalledModel] the catalog no longer knows about, which has
  /// no [ModelSpec] to delete by.
  Future<void> _deleteUnknown(InstalledModel model) async {
    try {
      await widget.store.deleteById(model.id);
    } catch (e) {
      _showMessage('Could not delete ${model.id}: $e');
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Manage models')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final spec in ModelCatalog.all) ...[
                  _buildModelTile(theme, spec),
                  const SizedBox(height: 12),
                ],
                if (_unknown.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 8),
                    child: Text(
                      'OTHER FILES',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        letterSpacing: 1.2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  for (final model in _unknown) ...[
                    _buildUnknownTile(theme, model),
                    const SizedBox(height: 12),
                  ],
                ],
              ],
            ),
    );
  }

  Widget _buildModelTile(ThemeData theme, ModelSpec spec) {
    final installing = _progress.containsKey(spec.id);
    final installed = _installed[spec.id] ?? false;
    final subtitle =
        '${_kindLabel(spec.kind)} · ${spec.languages.join(', ')}';

    Widget sizeLine;
    if (installing) {
      sizeLine = Text(_progressLabel(_progress[spec.id]!));
    } else if (installed) {
      sizeLine = Text('${_megabytes(_sizes[spec.id] ?? 0)} MB installed');
    } else {
      sizeLine = Text('Download ${_megabytes(spec.archiveBytes)} MB · '
          '${_megabytes(spec.installedBytes)} MB on disk');
    }

    Widget? trailing;
    if (installing) {
      trailing = TextButton(
        onPressed: () => _cancelInstall(spec),
        child: const Text('Cancel'),
      );
    } else if (installed) {
      trailing = IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Delete',
        onPressed: () => _confirmDelete(
          title: spec.displayName,
          onConfirmed: () => _deleteSpec(spec),
        ),
      );
    } else {
      trailing = ElevatedButton(
        onPressed: () => _startInstall(spec),
        child: const Text('Download'),
      );
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        spec.displayName,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: theme.colorScheme.onSurface.withOpacity(0.6),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                trailing,
              ],
            ),
            const SizedBox(height: 8),
            if (installing) ...[
              LinearProgressIndicator(value: _progress[spec.id]!.fraction),
              const SizedBox(height: 6),
            ],
            sizeLine,
          ],
        ),
      ),
    );
  }

  Widget _buildUnknownTile(ThemeData theme, InstalledModel model) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        title: Text(model.id),
        subtitle: Text('${_megabytes(model.bytes)} MB · unrecognised'),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete',
          onPressed: () => _confirmDelete(
            title: model.id,
            onConfirmed: () => _deleteUnknown(model),
          ),
        ),
      ),
    );
  }

  String _kindLabel(ModelKind kind) {
    switch (kind) {
      case ModelKind.streamingZipformer:
        return 'Streaming';
      case ModelKind.whisper:
        return 'Whisper';
      case ModelKind.senseVoice:
        return 'SenseVoice';
      case ModelKind.vad:
        return 'VAD';
    }
  }

  String _progressLabel(ModelInstallProgress progress) {
    switch (progress.phase) {
      case ModelInstallPhase.downloading:
        final total = progress.totalBytes;
        if (total != null && total > 0) {
          return '${_megabytes(progress.receivedBytes)} / '
              '${_megabytes(total)} MB (${((progress.fraction ?? 0) * 100).round()}%)';
        }
        return '${_megabytes(progress.receivedBytes)} MB downloaded';
      case ModelInstallPhase.extracting:
        return 'Extracting…';
      case ModelInstallPhase.verifying:
        return 'Verifying…';
      case ModelInstallPhase.done:
        return 'Done';
    }
  }
}

String _megabytes(int bytes) => (bytes / (1024 * 1024)).round().toString();
