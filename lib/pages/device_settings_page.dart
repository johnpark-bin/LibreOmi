import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../controllers/device_controller.dart';
import '../controllers/session_controller.dart';
import '../device/omi_device.dart';
import '../l10n/l10n.dart';

class DeviceSettingsPage extends StatefulWidget {
  const DeviceSettingsPage({super.key});

  @override
  State<DeviceSettingsPage> createState() => _DeviceSettingsPageState();
}

class _DeviceSettingsPageState extends State<DeviceSettingsPage> {
  // State
  double _dimRatio = 100.0;
  bool _isDimRatioLoaded = false;
  
  double _micGain = 5.0; // Default to typical normal
  bool _isMicGainLoaded = false;

  // New State
  int? _batteryLevel;

  Timer? _debounce;
  Timer? _micGainDebounce;

  @override
  void initState() {
    super.initState();
    _loadInitialSettings();
  }

  Future<void> _loadInitialSettings() async {
    // Give time for connection to stabilize if just opened
    await Future.delayed(const Duration(milliseconds: 200));
    
    if (!mounted) return;
    
    // Get initial values from the connected device
    final device = context.read<DeviceController>().device;

    // Force read immediately instead of relying on cached values if any
    // Actually, getMicGain reads from characteristic.

    // Load Gain
    final gain = await device?.readMicGain();

    // Load Dimming
    final dim = await device?.readLedDim();

    // Load Battery
    final batt = await device?.readBatteryLevel();
    
    if (mounted) {
      setState(() {
        if (gain != null) {
          _micGain = (gain > 8 ? 8 : gain).toDouble();
          _isMicGainLoaded = true;
        }
        if (dim != null) {
          _dimRatio = dim.toDouble();
          _isDimRatioLoaded = true;
        }
        _batteryLevel = batt;
      });
    }
  }
  
  void _updateDimRatio(double value) {
    context.read<DeviceController>().device?.writeLedDim(value.toInt());
  }

  void _updateMicGain(double value) {
    context.read<DeviceController>().device?.writeMicGain(value.toInt());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _micGainDebounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final device = Provider.of<DeviceController>(context);
    final session = Provider.of<SessionController>(context);
    final isConnected = device.deviceState == DeviceConnectionState.connected;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.deviceSettings_title),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
            if (isConnected) ...[
              Text(
                l10n.deviceSettings_customizationHeader,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),

              // Dimming
              Text(l10n.deviceSettings_dimmingLabel, style: const TextStyle(fontSize: 16)),
              Slider(
                value: _dimRatio,
                min: 0,
                max: 100,
                divisions: 100,
                label: '${_dimRatio.round()}%',
                onChanged: (val) {
                  setState(() => _dimRatio = val);
                  if (_debounce?.isActive ?? false) _debounce!.cancel();
                  _debounce = Timer(const Duration(milliseconds: 200), () => _updateDimRatio(val));
                },
              ),

              const SizedBox(height: 24),

              _buildSectionHeader(theme, l10n.deviceSettings_deviceInfoHeader),
             Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _buildInfoRow(l10n.deviceSettings_batteryLevelLabel, '${_batteryLevel ?? "--"}%'),
                    // Device Info was requested to be removed previously,
                    // but Battery is useful.
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),
            _buildSectionHeader(theme, l10n.deviceSettings_microphoneGainHeader),
              _buildMicGainCard(theme, l10n),

              const SizedBox(height: 32),

              // Audio Test
              Text(
                l10n.deviceSettings_debugHeader,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Card(
               child: ListTile(
                 title: Text(l10n.deviceSettings_testMicAudioTitle),
                 subtitle: Text(l10n.deviceSettings_testMicAudioSubtitle),
                 trailing: session.isTestingAudio
                   ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                   : const Icon(Icons.mic),
                 onTap: session.isTestingAudio ? null : () {
                   session.startAudioTest();
                 },
               ),
              ),

              const SizedBox(height: 40),

              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () async {
                    await device.disconnectDevice();
                    Navigator.pop(context);
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: Text(l10n.deviceSettings_disconnectButton),
                ),
              ),
            ],
            if (!isConnected)
              Center(child: Text(l10n.deviceSettings_notConnectedLabel)),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
    );
  }



  Widget _buildMicGainCard(ThemeData theme, AppLocalizations l10n) {
    final currentLevel = _micGain.round();

    // Labels mapping
    String getLabel(int level) {
         if (level == 0) return l10n.deviceSettings_micGainMuteLabel;
         if (level == 6) return '+20dB';
         // ... simplified for now
         return l10n.deviceSettings_micGainLevelLabel(level);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
           crossAxisAlignment: CrossAxisAlignment.start,
           children: [
             Row(
               mainAxisAlignment: MainAxisAlignment.spaceBetween,
               children: [
                 Text(l10n.deviceSettings_micGainCardTitle, style: const TextStyle(fontWeight: FontWeight.bold)),
                 Text('${getLabel(currentLevel)}${currentLevel == 6 ? " (${l10n.deviceSettings_presetHigh})" : ""}'),
               ],
             ),
             const SizedBox(height: 8),
             Text(l10n.deviceSettings_micGainDescription, style: const TextStyle(fontSize: 12, color: Colors.grey)),
             const SizedBox(height: 16),

             Slider(
               value: _micGain,
               min: 0,
               max: 8,
               divisions: 8,
               label: getLabel(currentLevel),
               onChanged: (val) {
                 setState(() => _micGain = val);
                 if (_micGainDebounce?.isActive ?? false) _micGainDebounce!.cancel();
                 _micGainDebounce = Timer(const Duration(milliseconds: 200), () => _updateMicGain(val));
               },
             ),

             Padding(
               padding: const EdgeInsets.symmetric(horizontal: 10),
               child: Row(
                 mainAxisAlignment: MainAxisAlignment.spaceBetween,
                 children: [
                   Text(l10n.deviceSettings_micGainMuteLabel, style: const TextStyle(fontSize: 10)),
                   const Text('+6dB', style: TextStyle(fontSize: 10)),
                   Text(l10n.deviceSettings_micGainMaxLabel, style: const TextStyle(fontSize: 10)),
                 ],
               ),
             ),

             const SizedBox(height: 16),
             Row(
               children: [
                 _presetBtn(l10n.deviceSettings_presetQuiet, 2),
                 const SizedBox(width: 8),
                 _presetBtn(l10n.deviceSettings_presetNormal, 4),
                 const SizedBox(width: 8),
                 _presetBtn(l10n.deviceSettings_presetHigh, 6),
               ],
             ),
           ],
        ),
      ),
    );
  }

  Widget _presetBtn(String label, double level) {
    final isSelected = _micGain == level;
    return Expanded(
      child: GestureDetector(
        onTap: () {
           setState(() => _micGain = level);
           _updateMicGain(level);
        },
        child: Container(
           padding: const EdgeInsets.symmetric(vertical: 8),
           decoration: BoxDecoration(
             border: Border.all(color: isSelected ? Colors.white : Colors.grey),
             borderRadius: BorderRadius.circular(8),
             color: isSelected ? Colors.white.withOpacity(0.1) : null,
           ),
           alignment: Alignment.center,
           child: Text(label, style: TextStyle(color: isSelected ? Colors.white : Colors.grey)),
        ),
      ),
    );
  }
}
