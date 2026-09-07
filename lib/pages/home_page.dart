/// Home page - device connection and live transcription
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/l10n.dart';
import '../platform/battery_optimization.dart';
import '../platform/battery_optimization_gateway.dart';
import '../platform/permission_gateway.dart';
import '../platform/permissions.dart';
import '../device/device_manager.dart';
import '../device/omi_device.dart';
import '../controllers/device_controller.dart';
import '../controllers/session_controller.dart';
import '../services/settings_service.dart';
import 'battery_guidance_page.dart';
import 'permissions_rationale_page.dart';
import 'settings_page.dart';
import 'conversations_page.dart';
import 'memories_page.dart';
import 'tasks_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          DeviceTab(onNavigateToSettings: () => setState(() => _currentIndex = 4)),
          const ConversationsPage(),
          const MemoriesPage(),
          const TasksPage(),
          const SettingsPage(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Colors.white.withOpacity(0.05))),
        ),
        child: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          backgroundColor: const Color(0xFF0A0A0A),
          currentIndex: _currentIndex,
          onTap: (index) => setState(() => _currentIndex = index),
          selectedItemColor: const Color(0xFF6C5CE7),
          unselectedItemColor: Colors.grey.withOpacity(0.5),
          showUnselectedLabels: true,
          selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
          unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 12),
          elevation: 0,
          items: [
            BottomNavigationBarItem(
              icon: const Icon(Icons.mic_none_outlined),
              activeIcon: const Icon(Icons.mic),
              label: l10n.home_nav_liveLabel,
            ),
            BottomNavigationBarItem(
              icon: const Icon(Icons.history_outlined),
              activeIcon: const Icon(Icons.history),
              label: l10n.home_nav_historyLabel,
            ),
            BottomNavigationBarItem(
              icon: const Icon(Icons.psychology_outlined),
              activeIcon: const Icon(Icons.psychology),
              label: l10n.home_nav_memoriesLabel,
            ),
            BottomNavigationBarItem(
              icon: const Icon(Icons.check_circle_outline),
              activeIcon: const Icon(Icons.check_circle),
              label: l10n.home_nav_tasksLabel,
            ),
            BottomNavigationBarItem(
              icon: const Icon(Icons.settings_outlined),
              activeIcon: const Icon(Icons.settings),
              label: l10n.home_nav_settingsLabel,
            ),
          ],
        ),
      ),
    );
  }
}

class DeviceTab extends StatefulWidget {
  final VoidCallback? onNavigateToSettings;
  
  const DeviceTab({super.key, this.onNavigateToSettings});

  @override
  State<DeviceTab> createState() => _DeviceTabState();
}

class _DeviceTabState extends State<DeviceTab> {
  bool _isScanning = false;
  bool _isUserConnecting = false; // Track user-initiated connection
  List<DiscoveredDevice> _devices = [];

  /// Owns the "battery-optimisation prompt already shown" decision. Kept as a
  /// field so its in-flight guard survives across the two session-start paths
  /// below (see `lib/platform/battery_optimization.dart`).
  late final BatteryOptimizationPrompt _batteryPrompt = BatteryOptimizationPrompt(
    optimization: batteryOptimization,
    readShown: () => SettingsService.batteryOptimizationPromptShown,
    writeShown: (value) =>
        SettingsService.batteryOptimizationPromptShown = value,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return Consumer2<DeviceController, SessionController>(
      builder: (context, deviceController, session, child) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('LibreOmi'),
            backgroundColor: Colors.transparent,
            actions: [
              // The way back into the first-run disclosure (LO-64), which is
              // otherwise shown only once. In the app bar rather than in one
              // of the two bodies below, so it stays reachable while a device
              // is connected or a capture is running.
              IconButton(
                icon: const Icon(Icons.privacy_tip_outlined),
                tooltip: l10n.common_permissionsPrivacyLabel,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const PermissionsRationalePage(),
                  ),
                ),
              ),
              if (deviceController.batteryLevel != null)
                Container(
                  margin: const EdgeInsets.only(right: 16),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withOpacity(0.1)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        deviceController.batteryLevel! > 20
                            ? Icons.battery_full
                            : Icons.battery_alert,
                        size: 16,
                        color: deviceController.batteryLevel! > 20 ? Colors.greenAccent : Colors.redAccent,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${deviceController.batteryLevel}%',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          body: _buildBody(deviceController, session),
        );
      },
    );
  }

  Widget _buildBody(DeviceController deviceController, SessionController session) {
    // Show connected view when listening (either Omi or phone mic)
    if (session.isListening || session.isUsingPhoneMic) {
      return _buildConnectedView(deviceController, session);
    }
    
    switch (deviceController.deviceState) {
      case DeviceConnectionState.disconnected:
      case DeviceConnectionState.connecting:
        return _buildDisconnectedView(deviceController, session);
      case DeviceConnectionState.connected:
        return _buildConnectedView(deviceController, session);
    }
  }

  Widget _buildDisconnectedView(
    DeviceController deviceController,
    SessionController session,
  ) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // Header
        const SizedBox(height: 20),
        Center(
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF6C5CE7).withOpacity(0.1),
              border: Border.all(color: const Color(0xFF6C5CE7).withOpacity(0.2)),
            ),
            child: const Icon(Icons.mic, size: 48, color: Color(0xFF6C5CE7)),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          l10n.home_device_startCapturingTitle,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: -0.5),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.home_device_startCapturingSubtitle,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: theme.colorScheme.onSurface.withOpacity(0.6), height: 1.5),
        ),
        const SizedBox(height: 48),

        // API key warning
        if (!SettingsService.hasApiKeys) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.orange.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.home_device_missingApiKeysTitle, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.orange)),
                      const SizedBox(height: 4),
                      Text(l10n.home_device_missingApiKeysSubtitle,
                        style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.7))),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: widget.onNavigateToSettings,
                  child: Text(l10n.home_nav_settingsLabel),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
        
        // Connect to Omi Device
        _buildOmiCard(deviceController),
        
        const SizedBox(height: 16),
        
        // Use Phone Microphone
        _buildActionCard(
          title: l10n.home_device_phoneMicTitle,
          subtitle: l10n.home_device_phoneMicSubtitle,
          icon: Icons.phone_iphone,
          color: const Color(0xFF00b894),
          onTap: SettingsService.hasApiKeys ? () => _startPhoneMicRecording(session) : null,
        ),
      ],
    );
  }
  
  Widget _buildOmiCard(DeviceController deviceController) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    // Only show connecting state for user-initiated connections
    final isConnecting = _isUserConnecting && deviceController.deviceState == DeviceConnectionState.connecting;
    
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isConnecting ? null : _startScan,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
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
                      color: isConnecting 
                          ? Colors.orange.withOpacity(0.1)
                          : const Color(0xFF6C5CE7).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: isConnecting
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.orange,
                            ),
                          )
                        : const Icon(Icons.bluetooth_audio, color: Color(0xFF6C5CE7)),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isConnecting ? l10n.home_device_omiConnectingTitle : l10n.home_device_omiTitle,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isConnecting
                              ? l10n.home_device_omiConnectingSubtitle
                              : l10n.home_device_omiSubtitle,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface.withOpacity(0.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!isConnecting)
                    Icon(Icons.arrow_forward_ios, size: 16, color: theme.colorScheme.onSurface.withOpacity(0.3)),
                ],
              ),
              // Scanning results within the card
              if (_isScanning) ...[
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 12),
                    Text(l10n.home_device_scanningMessage, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13)),
                  ],
                ),
                const SizedBox(height: 12),
                ..._devices.map((device) => Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withOpacity(0.1)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.bluetooth, size: 20, color: Color(0xFF6C5CE7)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(device.name.isNotEmpty ? device.name : l10n.home_device_unknownDeviceName,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                            Text(device.id,
                              style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.5))),
                          ],
                        ),
                      ),
                      ElevatedButton(
                        onPressed: () => _connectToDevice(device, deviceController),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF6C5CE7),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          minimumSize: Size.zero,
                          textStyle: const TextStyle(fontSize: 13),
                        ),
                        child: Text(l10n.home_device_connectButton),
                      ),
                    ],
                  ),
                )),
              ],
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildActionCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    final isEnabled = onTap != null;
    
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withOpacity(0.05)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isEnabled ? color.withOpacity(0.1) : Colors.grey.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: isEnabled ? color : Colors.grey),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(
                      fontSize: 16, 
                      fontWeight: FontWeight.bold,
                      color: isEnabled ? theme.colorScheme.onSurface : Colors.grey,
                    )),
                    const SizedBox(height: 4),
                    Text(subtitle, style: TextStyle(
                      fontSize: 12, 
                      color: theme.colorScheme.onSurface.withOpacity(0.5)
                    )),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_ios, size: 16, color: theme.colorScheme.onSurface.withOpacity(0.3)),
            ],
          ),
        ),
      ),
    );
  }


  Widget _buildConnectedView(
    DeviceController deviceController,
    SessionController session,
  ) {
    final l10n = L10n.of(context);
    return Column(
      children: [
        // Connected Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  session.isUsingPhoneMic ? Icons.phone_iphone : Icons.check, 
                  color: Colors.green, 
                  size: 20,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.isUsingPhoneMic ? l10n.home_connected_phoneMicActiveTitle : l10n.home_connected_connectedTitle,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    Text(
                      session.isUsingPhoneMic ? l10n.home_connected_phoneMicActiveSubtitle : l10n.home_connected_omiReadySubtitle,
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: session.isUsingPhoneMic
                    ? session.stopListening
                    : deviceController.disconnectDevice,
                child: Text(session.isUsingPhoneMic ? l10n.home_connected_stopButton : l10n.home_connected_disconnectButton),
              ),
            ],
          ),
        ),

        // Listening status banner
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: session.isLoadingModel
              ? Colors.orange.withOpacity(0.15)
              : session.isListening 
                  ? Colors.deepPurple.withOpacity(0.15) 
                  : Colors.grey.withOpacity(0.1),
          child: Row(
            children: [
              if (session.isLoadingModel) ...[
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.home_connected_loadingModelTitle,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.orange,
                        ),
                      ),
                      Text(
                        l10n.home_connected_loadingModelSubtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade400,
                        ),
                      ),
                    ],
                  ),
                ),
              ] else if (session.isListening) ...[
                const _PulsingDot(),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.overlay_listening_title,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.deepPurpleAccent,
                        ),
                      ),
                      Text(
                        l10n.home_connected_listeningSubtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade400,
                        ),
                      ),
                    ],
                  ),
                ),
                // Manual save button
                if (session.liveSegments.isNotEmpty)
                  TextButton.icon(
                    onPressed: session.manualSaveConversation,
                    icon: const Icon(Icons.save, size: 18),
                    label: Text(l10n.home_connected_saveNowButton),
                  ),
              ] else ...[
                const Icon(Icons.mic_off, color: Colors.grey),
                const SizedBox(width: 12),
                Expanded(child: Text(l10n.home_connected_notListeningMessage)),
                ElevatedButton(
                  onPressed: SettingsService.hasApiKeys
                      ? () => _startListening(session)
                      : null,
                  child: Text(l10n.home_connected_startButton),
                ),
              ],
            ],
          ),
        ),

        // Toggle button
        Padding(
          padding: const EdgeInsets.all(16),
          child: ElevatedButton.icon(
            onPressed: session.isListening
                ? session.stopListening
                : () => _startListening(session),
            icon: Icon(session.isListening ? Icons.stop : Icons.mic),
            label: Text(session.isListening ? l10n.home_connected_stopListeningButton : l10n.home_connected_startListeningButton),
            style: ElevatedButton.styleFrom(
              backgroundColor: session.isListening ? Colors.red : Colors.deepPurple,
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 60),
            ),
          ),
        ),

        // Live transcript
        if (session.liveSegments.isNotEmpty)
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.withOpacity(0.2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        l10n.home_connected_currentConversationTitle,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        l10n.home_connected_segmentsCount(session.liveSegments.length),
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade400,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.builder(
                      itemCount: session.liveSegments.length,
                      reverse: false,
                      itemBuilder: (context, index) {
                        final segment = session.liveSegments[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: _getSpeakerColor(segment.speakerId),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  l10n.home_connected_speakerLabel(segment.speakerId),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(child: Text(segment.text)),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          )
        else if (session.isListening)
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.mic, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text(
                    l10n.home_connected_waitingForSpeechMessage,
                    style: const TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Color _getSpeakerColor(int speakerId) {
    final colors = [
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
    ];
    return colors[speakerId % colors.length];
  }

  Future<void> _startScan() async {
    final l10n = L10n.of(context);
    // Ask for BLE permission at the point of use (docs/04 §3): BLUETOOTH_SCAN
    // and BLUETOOTH_CONNECT on Android 12+, ACCESS_FINE_LOCATION below that.
    final PermissionOutcome outcome;
    try {
      outcome = await appPermissions.ensureBleScan();
    } catch (e) {
      // permission_handler throws when another request is still in flight or
      // no activity is attached; without this the button would look dead.
      _showPermissionError(l10n.home_permission_bluetoothRequestFailedMessage, e);
      return;
    }
    if (!mounted) return;
    if (outcome != PermissionOutcome.granted) {
      _showPermissionDenied(
        l10n.home_permission_bluetoothDeniedMessage,
        outcome,
      );
      return;
    }

    setState(() {
      _isScanning = true;
      _devices = [];
    });

    final deviceController = context.read<DeviceController>();
    
    await for (final devices in deviceController.scanForDevices()) {
      setState(() => _devices = devices);
    }

    setState(() => _isScanning = false);
  }

  Future<void> _connectToDevice(
    DiscoveredDevice device,
    DeviceController deviceController,
  ) async {
    setState(() => _isUserConnecting = true);
    await deviceController.stopScan();
    setState(() => _isScanning = false);
    
    final success = await deviceController.connectToDevice(device);
    
    if (mounted) {
      setState(() => _isUserConnecting = false);
      if (!success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).home_device_connectFailedMessage)),
        );
      }
    }
  }

  Future<void> _startListening(SessionController session) async {
    await _maybePromptBatteryOptimization();
    if (!mounted) return;
    try {
      await session.startListening();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    }
  }

  Future<void> _startPhoneMicRecording(SessionController session) async {
    final l10n = L10n.of(context);
    // RECORD_AUDIO is only ever needed in phone-mic mode, so it is requested
    // here rather than at launch (docs/04 §3).
    final PermissionOutcome outcome;
    try {
      outcome = await appPermissions.ensureMicrophone();
    } catch (e) {
      _showPermissionError(l10n.home_permission_microphoneRequestFailedMessage, e);
      return;
    }
    if (!mounted) return;
    if (outcome != PermissionOutcome.granted) {
      _showPermissionDenied(
        l10n.home_permission_microphoneDeniedMessage,
        outcome,
      );
      return;
    }

    await _maybePromptBatteryOptimization();
    if (!mounted) return;
    try {
      await session.startListeningWithPhoneMic();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    }
  }

  /// Offers the battery-optimisation exemption once, immediately before the
  /// first session starts (docs/04 §3). Android can suspend the app while the
  /// screen is off, which cuts a recording session short unless the app is
  /// exempt from battery optimisation; this dialog explains that trade-off
  /// and lets the user grant the exemption on the spot. It never blocks or
  /// fails a session start: any platform error is swallowed and the session
  /// proceeds as if the user had declined.
  Future<void> _maybePromptBatteryOptimization() async {
    final bool shouldPrompt;
    try {
      // claim() records the "shown" flag before it returns true and holds an
      // in-flight guard across its await, so two quick session starts cannot
      // stack two dialogs.
      shouldPrompt = await _batteryPrompt.claim();
    } catch (e) {
      debugPrint('battery optimisation: could not decide on prompt: $e');
      return;
    }
    if (!shouldPrompt) return;
    if (!mounted) return;

    final l10n = L10n.of(context);
    final bool continuePressed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10n.home_batteryPrompt_title),
            content: Text(
              l10n.home_batteryPrompt_content,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(l10n.common_notNowButton),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(l10n.home_batteryPrompt_continueButton),
              ),
            ],
          ),
        ) ??
        false;

    if (!mounted) return;

    if (!continuePressed) {
      _offerBatteryGuidance(
        l10n.home_batteryPrompt_declinedMessage,
      );
      return;
    }

    final BatteryOptimizationOutcome outcome;
    try {
      outcome = await _batteryPrompt.optimization.request();
    } catch (e) {
      debugPrint('battery optimisation: request failed: $e');
      return;
    }
    if (!mounted) return;

    if (outcome == BatteryOptimizationOutcome.denied) {
      _offerBatteryGuidance(
        l10n.home_batteryPrompt_stillOnMessage,
      );
    }
  }

  /// Shows a SnackBar offering the manufacturer-specific guidance page for
  /// keeping LibreOmi alive in the background.
  void _offerBatteryGuidance(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(
          label: L10n.of(context).home_batteryPrompt_guidanceAction,
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => const BatteryGuidancePage(),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Reports a permission request that could not even be made.
  void _showPermissionError(String message, Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          L10n.of(context).home_permission_errorTemplate(message, error),
        ),
      ),
    );
  }

  /// Explains a refused permission. Once Android reports it as permanently
  /// denied the system dialog never appears again, so the only way forward is
  /// the app's settings page.
  void _showPermissionDenied(String message, PermissionOutcome outcome) {
    final l10n = L10n.of(context);
    final isPermanent = outcome == PermissionOutcome.permanentlyDenied;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isPermanent
              ? l10n.home_permission_deniedPermanentTemplate(message)
              : message,
        ),
        action: isPermanent
            ? SnackBarAction(
                label: l10n.home_nav_settingsLabel,
                onPressed: () => appPermissions.openAppSettings(),
              )
            : null,
      ),
    );
  }
}

/// Pulsing red dot indicator for active recording
class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.red.withOpacity(0.5 + _controller.value * 0.5),
          ),
        );
      },
    );
  }
}
