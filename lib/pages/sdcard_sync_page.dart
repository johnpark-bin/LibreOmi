/// SD Card Sync Page
/// Allows users to sync audio data from Omi device's SD card
///
/// This page is a thin view over [SdCardController]: it holds only the
/// presentational pulse animation and the confirmation dialogs the
/// controller deliberately does not show. All sync/processing/file state
/// lives in the controller (LO-52).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../controllers/device_controller.dart';
import '../controllers/sdcard_controller.dart';
import '../device/omi_device.dart';
import '../services/sdcard_sync_service.dart' show SyncedAudioFile;
import 'conversations_page.dart';

class SdCardSyncPage extends StatefulWidget {
  const SdCardSyncPage({super.key});

  @override
  State<SdCardSyncPage> createState() => _SdCardSyncPageState();
}

class _SdCardSyncPageState extends State<SdCardSyncPage> with TickerProviderStateMixin {
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    // Load pending + synced files once the first frame is up. The
    // controller is app-scoped, so results from an earlier visit are
    // dropped first -- otherwise every card ever produced would still be
    // here.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = context.read<SdCardController>();
      controller.clearFinishedResults();
      controller.load();
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _startSync(SdCardController controller) async {
    final filePath = await controller.startSync();
    if (!mounted) return;
    if (filePath != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Audio synced! Tap the file to process it.'),
          backgroundColor: Colors.green,
          action: SnackBarAction(
            label: 'Process Now',
            textColor: Colors.white,
            onPressed: () => controller.processFile(filePath),
          ),
        ),
      );
    } else if (controller.syncError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(controller.syncError!),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _deleteFile(SdCardController controller, SyncedAudioFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete File'),
        content: Text('Delete "${file.fileName}"?\n\nThis cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    final success = await controller.deleteFile(file.filePath);
    if (!mounted) return;
    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File deleted')),
      );
    }
  }

  Future<void> _deleteAllFiles(SdCardController controller) async {
    if (controller.syncedFiles.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete All Files'),
        content: Text('Delete all ${controller.syncedFiles.length} synced files?\n\nThis cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    final deleted = await controller.deleteAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Deleted $deleted files')),
    );
  }

  Future<void> _clearDeviceStorage(SdCardController controller) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Device Storage'),
        content: const Text(
          'Clear all data from your Omi device\'s SD card?\n\n'
          'This will delete all unsynced recordings on the device. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Clear Storage'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    final success = await controller.clearDeviceStorage();
    if (!mounted) return;
    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Device storage cleared'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SD Card Sync'),
        backgroundColor: Colors.transparent,
      ),
      body: Consumer<SdCardController>(
        builder: (context, controller, child) {
          if (!controller.hasStorage) {
            return _buildNoSupportView();
          }

          return _buildSyncView(controller);
        },
      ),
    );
  }

  Widget _buildNoSupportView() {
    final deviceController = context.read<DeviceController>();
    final isConnected = deviceController.deviceState == DeviceConnectionState.connected;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.sd_card_alert,
                size: 64,
                color: Colors.orange,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              isConnected ? 'SD Card Not Supported' : 'Device Not Connected',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              isConnected
                  ? 'Your Omi device doesn\'t have SD card storage.\n\nThis feature requires an Omi DevKit 2 or newer with SD card hardware and firmware v2.0+.'
                  : 'Connect to your Omi device first to check for SD card storage.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                color: Colors.grey.shade400,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 32),
            if (!isConnected)
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.bluetooth),
                label: const Text('Connect Device'),
              )
            else
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Go Back'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSyncView(SdCardController controller) {
    // Keyed off the process states rather than the file listing: a finished
    // import deletes its own `.bin`, so the file it produced a transcript
    // for is no longer in `syncedFiles` by the time its card is shown.
    final results = controller.processing.entries
        .where((entry) => entry.value.status != FileProcessStatus.idle)
        .toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Status Card
          _buildStatusCard(controller),

          const SizedBox(height: 24),

          // Progress Indicator (when syncing)
          if (controller.syncing || controller.clearing)
            _buildProgressCard(controller),

          // Pending Data Card (from device)
          if (controller.pending != null && !controller.syncing && !controller.clearing)
            _buildPendingDataCard(controller),

          // No Data on Device Card
          if (controller.pending == null && !controller.checking && !controller.syncing && !controller.clearing)
            _buildNoDataCard(controller),

          const SizedBox(height: 24),

          // Local Synced Files Section
          if (controller.syncedFiles.isNotEmpty && !controller.syncing)
            _buildSyncedFilesSection(controller),

          // Transcript / process result cards
          for (final result in results) ...[
            const SizedBox(height: 16),
            _buildFileResultCard(controller, result.key, result.value),
          ],

          const SizedBox(height: 24),

          // Device Actions
          if (controller.hasStorage && !controller.syncing && !controller.clearing)
            _buildDeviceActionsSection(controller),

          const SizedBox(height: 24),

          // Info Section
          _buildInfoSection(),
        ],
      ),
    );
  }

  Widget _buildStatusCard(SdCardController controller) {
    Color statusColor;
    IconData statusIcon;

    if (controller.syncing) {
      statusColor = const Color(0xFF6C5CE7);
      statusIcon = Icons.sync;
    } else if (controller.isProcessing) {
      statusColor = Colors.amber;
      statusIcon = Icons.memory;
    } else if (controller.pending != null) {
      statusColor = Colors.green;
      statusIcon = Icons.sd_card;
    } else {
      statusColor = Colors.grey;
      statusIcon = Icons.check_circle;
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: statusColor.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(
                    controller.syncing ? 0.2 + (_pulseController.value * 0.3) : 0.2,
                  ),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  statusIcon,
                  color: statusColor,
                  size: 28,
                ),
              );
            },
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  controller.syncing ? 'Syncing...' :
                  controller.isProcessing ? 'Processing...' :
                  controller.pending != null ? 'Data Available' : 'All Synced',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: statusColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  controller.status,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade400,
                  ),
                ),
              ],
            ),
          ),
          if (controller.checking)
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }

  Widget _buildProgressCard(SdCardController controller) {
    String statusText;
    Color progressColor;
    bool showCancel = false;

    if (controller.clearing) {
      statusText = 'Clearing device storage...';
      progressColor = Colors.red;
    } else {
      statusText = 'Syncing from SD card...';
      progressColor = const Color(0xFF6C5CE7);
      showCancel = true;
    }

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        children: [
          // Circular Progress
          SizedBox(
            width: 160,
            height: 160,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 160,
                  height: 160,
                  child: CircularProgressIndicator(
                    value: controller.clearing ? null : controller.syncProgress,
                    strokeWidth: 10,
                    backgroundColor: Colors.grey.shade800,
                    valueColor: AlwaysStoppedAnimation<Color>(progressColor),
                  ),
                ),
                if (!controller.clearing)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${(controller.syncProgress * 100).toInt()}%',
                        style: const TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (controller.syncEtaSeconds != null)
                        Text(
                          _formatEta(controller.syncEtaSeconds!),
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade400,
                          ),
                        ),
                    ],
                  )
                else
                  Icon(
                    Icons.delete_forever,
                    size: 48,
                    color: progressColor,
                  ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          Text(
            statusText,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),

          const SizedBox(height: 16),

          if (showCancel && controller.syncing)
            TextButton.icon(
              onPressed: controller.cancelSync,
              icon: const Icon(Icons.cancel, color: Colors.red),
              label: const Text('Cancel', style: TextStyle(color: Colors.red)),
            ),
        ],
      ),
    );
  }

  Widget _buildPendingDataCard(SdCardController controller) {
    final pending = controller.pending!;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF6C5CE7).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.audiotrack,
                  color: Color(0xFF6C5CE7),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Audio Recording',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${pending.durationFormatted} • ${pending.sizeFormatted}',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade400,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          ElevatedButton.icon(
            onPressed: () => _startSync(controller),
            icon: const Icon(Icons.download),
            label: const Text('Sync & Process'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 56),
              backgroundColor: const Color(0xFF6C5CE7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoDataCard(SdCardController controller) {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.check_circle_outline,
              size: 48,
              color: Colors.green,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'All Caught Up!',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'No pending audio on your Omi\'s SD card',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade400,
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: controller.refreshPending,
            icon: const Icon(Icons.refresh),
            label: const Text('Check Again'),
          ),
        ],
      ),
    );
  }

  Widget _buildFileResultCard(
    SdCardController controller,
    String filePath,
    FileProcessState state,
  ) {
    switch (state.status) {
      case FileProcessStatus.idle:
        return const SizedBox.shrink();
      case FileProcessStatus.transcribing:
        return _buildInProgressCard('Transcribing ${_fileNameOf(filePath)}...');
      case FileProcessStatus.summarizing:
        return _buildInProgressCard('Saved — waiting for the summary...');
      case FileProcessStatus.failed:
        return _buildFailedCard(
          controller,
          filePath,
          state.error ?? 'Unknown error',
        );
      case FileProcessStatus.done:
        return _buildTranscriptCard(state);
    }
  }

  String _fileNameOf(String filePath) => filePath.split('/').last;

  Widget _buildInProgressCard(String message) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 16),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }

  Widget _buildFailedCard(
    SdCardController controller,
    String filePath,
    String error,
  ) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.red.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, color: Colors.red.shade300),
              const SizedBox(width: 12),
              const Text(
                'Transcription failed',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            error,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => controller.processFile(filePath),
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildTranscriptCard(FileProcessState state) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.text_snippet, color: Color(0xFFA29BFE)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  state.conversationTitle ?? 'Transcript',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 20),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: state.transcript ?? ''));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Transcript copied')),
                  );
                },
              ),
            ],
          ),
          if (state.summaryPending) ...[
            const SizedBox(height: 4),
            Text(
              'Summary pending',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
            ),
          ],
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              state.transcript ?? '',
              style: const TextStyle(
                fontSize: 14,
                height: 1.6,
              ),
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ConversationsPage()),
              );
            },
            icon: const Icon(Icons.history),
            label: const Text('View in History'),
          ),
        ],
      ),
    );
  }

  Widget _buildSyncedFilesSection(SdCardController controller) {
    final files = controller.syncedFiles;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00b894).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.folder, color: Color(0xFF00b894), size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Synced Files',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${files.length} file${files.length == 1 ? '' : 's'} • '
                        '${_formatBytes(controller.storageUsageBytes)} on your phone',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade400,
                        ),
                      ),
                    ],
                  ),
                ),
                if (files.length > 1)
                  TextButton(
                    onPressed: () => _deleteAllFiles(controller),
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                    child: const Text('Delete All'),
                  ),
              ],
            ),
          ),

          const Divider(height: 1),

          // File list
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: files.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final file = files[index];
              final isBusy = controller.processStateOf(file.filePath).isBusy;

              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6C5CE7).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: isBusy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.audiotrack, color: Color(0xFF6C5CE7), size: 20),
                ),
                title: Text(
                  file.durationFormatted,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  '${file.sizeFormatted} • ${file.dateFormatted}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade400,
                  ),
                ),
                trailing: isBusy
                    ? null
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Process button
                          IconButton(
                            onPressed: () => controller.processFile(file.filePath),
                            icon: const Icon(Icons.play_arrow, color: Color(0xFF00b894)),
                            tooltip: 'Process & Transcribe',
                          ),
                          // Delete button
                          IconButton(
                            onPressed: () => _deleteFile(controller, file),
                            icon: Icon(Icons.delete_outline, color: Colors.red.shade300),
                            tooltip: 'Delete',
                          ),
                        ],
                      ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceActionsSection(SdCardController controller) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.red.withOpacity(0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber, color: Colors.red.shade300, size: 20),
              const SizedBox(width: 8),
              Text(
                'Device Storage',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.red.shade300,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Clear all unsynced data from your Omi device. Use this if you want to start fresh without syncing.',
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade400,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => _clearDeviceStorage(controller),
            icon: const Icon(Icons.delete_forever),
            label: const Text('Clear Device Storage'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.red,
              side: BorderSide(color: Colors.red.shade300),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoSection() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.blue.withOpacity(0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, color: Colors.blue.shade300, size: 20),
              const SizedBox(width: 8),
              Text(
                'About SD Card Sync',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.blue.shade300,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'When your Omi device records audio while disconnected from your phone, '
            'it stores the data on its SD card. Use this feature to:\n\n'
            '• Download offline recordings\n'
            '• Transcribe and save to your history\n'
            '• Clear storage for new recordings',
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade400,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  String _formatEta(int seconds) {
    if (seconds < 60) {
      return '${seconds}s remaining';
    }
    final mins = seconds ~/ 60;
    final secs = seconds % 60;
    return '${mins}m ${secs}s remaining';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
