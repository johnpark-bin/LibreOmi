/// Settings page for API keys and app configuration
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../data/export_import.dart';
import '../controllers/device_controller.dart';
import '../controllers/library_controller.dart';
import '../device/omi_device.dart';
import '../services/llm_endpoint.dart';
import '../services/openai_service.dart';
import '../services/settings_service.dart';
import '../transcription/model_catalog.dart';
import '../platform/battery_optimization.dart';
import '../platform/battery_optimization_gateway.dart';
import '../platform/exact_alarm.dart';
import '../platform/exact_alarm_gateway.dart';
import 'battery_guidance_page.dart';
import 'permissions_rationale_page.dart';
import 'device_settings_page.dart';
import 'models_page.dart';
import 'stats_page.dart';
import 'sdcard_sync_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    this.batteryOptimizationOverride,
    this.exactAlarmOverride,
  });

  /// Injected for widget tests so they never touch a plugin channel.
  /// Defaults to the app-wide instance.
  final BatteryOptimization? batteryOptimizationOverride;

  /// Injected for widget tests so they never touch a plugin channel.
  /// Defaults to the app-wide instance.
  final ExactAlarm? exactAlarmOverride;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _deepgramController = TextEditingController();
  final _openaiController = TextEditingController();
  final _llmBaseUrlController = TextEditingController();
  final _newModelController = TextEditingController();
  final _newPricedModelController = TextEditingController();
  bool _obscureDeepgram = true;
  bool _obscureOpenai = true;

  bool _testingLlmConnection = false;
  LlmConnectionResult? _llmConnectionResult;

  late final BatteryOptimization _batteryOptimization;
  bool? _isIgnoringBatteryOptimization;
  bool _checkingBatteryOptimization = true;
  bool _batteryStatusCheckFailed = false;
  bool _requestingBatteryExemption = false;

  late final ExactAlarm _exactAlarm;
  ExactAlarmStatus? _exactAlarmStatus;
  bool _checkingExactAlarm = true;

  @override
  void initState() {
    super.initState();
    _deepgramController.text = SettingsService.deepgramApiKey;
    _openaiController.text = SettingsService.openaiApiKey;
    _llmBaseUrlController.text = SettingsService.llmBaseUrl;
    _batteryOptimization =
        widget.batteryOptimizationOverride ?? batteryOptimization;
    _refreshBatteryOptimizationStatus(notify: false);
    _exactAlarm = widget.exactAlarmOverride ?? exactAlarm;
    _refreshExactAlarmStatus();
  }

  Future<void> _refreshExactAlarmStatus() async {
    ExactAlarmStatus status;
    try {
      status = await _exactAlarm.status();
    } catch (e) {
      // A denied status is safe here: the switch still works and the user
      // can retry, whereas leaving the row stuck on "Checking…" would not.
      debugPrint('exact alarm: status check failed: $e');
      status = ExactAlarmStatus.denied;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _exactAlarmStatus = status;
      _checkingExactAlarm = false;
    });
  }

  Future<void> _refreshBatteryOptimizationStatus({bool notify = true}) async {
    // The first call comes from initState, before the first build, where a
    // setState would be redundant; later calls need one.
    if (notify) {
      setState(() => _checkingBatteryOptimization = true);
    } else {
      _checkingBatteryOptimization = true;
    }
    bool? ignoring;
    var failed = false;
    try {
      ignoring = await _batteryOptimization.isIgnoring();
    } catch (e) {
      // Say the check failed rather than leaving the row stuck on "Checking…"
      // forever — and keep the request row available so there is a way to
      // retry, which reporting it as "not applicable" would take away.
      debugPrint('battery optimisation: status check failed: $e');
      failed = true;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _isIgnoringBatteryOptimization = ignoring;
      _batteryStatusCheckFailed = failed;
      _checkingBatteryOptimization = false;
    });
  }

  Future<void> _requestBatteryExemption() async {
    setState(() => _requestingBatteryExemption = true);
    final BatteryOptimizationOutcome outcome;
    try {
      outcome = await _batteryOptimization.request();
    } catch (e) {
      debugPrint('battery optimisation: request failed: $e');
      if (!mounted) {
        return;
      }
      setState(() => _requestingBatteryExemption = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open the battery optimisation dialog.'),
        ),
      );
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => _requestingBatteryExemption = false);
    final message = switch (outcome) {
      BatteryOptimizationOutcome.ignoring =>
        'LibreOmi is now exempt from battery optimisation.',
      BatteryOptimizationOutcome.denied =>
        'Exemption request was declined.',
      BatteryOptimizationOutcome.unsupported =>
        'Not applicable on this platform.',
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
    await _refreshBatteryOptimizationStatus();
  }

  String _exactAlarmSubtitle() {
    if (_checkingExactAlarm) {
      return 'Checking permission…';
    }
    if (SettingsService.exactTaskReminders &&
        _exactAlarmStatus == ExactAlarmStatus.denied) {
      return 'Needs the Alarms & reminders permission — tap to grant it';
    }
    return 'Deliver reminders at the exact due time; needs the Alarms & '
        'reminders permission';
  }

  Future<void> _onExactTaskRemindersChanged(bool value) async {
    if (!value) {
      setState(() => SettingsService.exactTaskReminders = false);
      return;
    }
    if (_exactAlarmStatus != ExactAlarmStatus.denied) {
      // Already granted, or the platform has no such permission to ask for
      // (unsupported) — nothing left to negotiate.
      setState(() => SettingsService.exactTaskReminders = true);
      return;
    }
    final openSettings = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Allow exact alarms'),
        content: const Text(
          'Android needs the "Alarms & reminders" permission to deliver '
          'task reminders at the exact due time. Without it, reminders may '
          'arrive a few minutes late.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
    if (openSettings != true) {
      return;
    }
    ExactAlarmStatus status;
    try {
      status = await _exactAlarm.openSettings();
    } catch (e) {
      debugPrint('exact alarm: open settings failed: $e');
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open the Alarms & reminders settings.'),
        ),
      );
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _exactAlarmStatus = status;
      SettingsService.exactTaskReminders = status == ExactAlarmStatus.granted;
    });
    if (status != ExactAlarmStatus.granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Reminders will stay inexact until the permission '
              'is granted.'),
        ),
      );
    }
  }

  @override
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Saved Device Section
          _buildSectionHeader('Connected Device'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Consumer<DeviceController>(
              builder: (context, provider, _) {
                final savedName = SettingsService.savedDeviceName;
                final isConnected = provider.deviceState == DeviceConnectionState.connected;
                
                if (savedName.isEmpty) {
                  return ListTile(
                    contentPadding: const EdgeInsets.all(20),
                    leading: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.bluetooth_disabled, color: theme.colorScheme.onSurface.withOpacity(0.5)),
                    ),
                    title: const Text('No device saved'),
                    subtitle: const Text('Connect to a device to get started'),
                  );
                }
                
                return Column(
                  children: [
                    ListTile(
                      onTap: isConnected ? () {
                         Navigator.push(
                           context, 
                           MaterialPageRoute(builder: (_) => const DeviceSettingsPage())
                         );
                      } : null,
                      contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                      leading: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isConnected ? const Color(0xFF6C5CE7).withOpacity(0.2) : theme.colorScheme.surface,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                          color: isConnected ? const Color(0xFF6C5CE7) : theme.colorScheme.onSurface.withOpacity(0.5),
                        ),
                      ),
                      title: Text(savedName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      subtitle: Text(isConnected ? 'Connected • Tap to Configure' : 'Saved Device', 
                        style: TextStyle(color: isConnected ? const Color(0xFF6C5CE7) : null)),
                      trailing: isConnected ? Icon(Icons.arrow_forward_ios, size: 16, color: theme.colorScheme.onSurface.withOpacity(0.5)) : null,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () async {
                                await provider.forgetDevice();
                                setState(() {});
                              },
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(color: theme.colorScheme.onSurface.withOpacity(0.2)),
                                foregroundColor: theme.colorScheme.onSurface,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                              child: const Text('Forget'),
                            ),
                          ),
                          if (!isConnected) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: () {
                                  provider.scanAndConnectToSavedDevice();
                                },
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                ),
                                child: const Text('Connect'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 32),

          // Transcription Mode Section
          _buildSectionHeader('Transcription Engine'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                _buildRadioTile(
                  title: 'Cloud (Deepgram)',
                  subtitle: 'Best quality, requires API key',
                  value: 'cloud',
                  groupValue: SettingsService.transcriptionMode,
                  icon: Icons.cloud_outlined,
                  onChanged: (value) => setState(() => SettingsService.transcriptionMode = value!),
                ),
                Divider(height: 1, color: theme.dividerColor.withOpacity(0.1)),

                _buildRadioTile(
                  // The stored value is still 'whisper' — renaming it would
                  // need a preference migration for a string no user sees —
                  // but the mode now covers every offline model, so the label
                  // names the path rather than one of the models on it.
                  title: 'Local (offline model)',
                  subtitle: 'Whisper or SenseVoice, high accuracy',
                  value: 'whisper',
                  groupValue: SettingsService.transcriptionMode,
                  icon: Icons.record_voice_over_outlined,
                  onChanged: (value) => setState(() => SettingsService.transcriptionMode = value!),
                ),

                // Offline model selector. Built from ModelCatalog.offlineModels
                // rather than a literal list, so adding a model to the catalog
                // adds it here too (LO-71).
                if (SettingsService.useWhisper)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(56, 0, 16, 16),
                    child: DropdownButtonFormField<String>(
                      value: SettingsService.offlineSttModelId,
                      dropdownColor: const Color(0xFF2D2D2D),
                      decoration: const InputDecoration(
                        labelText: 'Model',
                      ),
                      icon: Icon(Icons.arrow_drop_down,
                          color: theme.colorScheme.onSurface.withOpacity(0.5)),
                      items: [
                        for (final spec in ModelCatalog.offlineModels)
                          DropdownMenuItem(
                            value: spec.id,
                            child: Text(
                              '${spec.displayName} '
                              '(${_installedMegabytes(spec)} MB)',
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() =>
                              SettingsService.offlineSttModelId = value);
                        }
                      },
                    ),
                  ),
                
                Divider(height: 1, color: theme.dividerColor.withOpacity(0.1)),

                _buildRadioTile(
                  title: 'Local (Sherpa-ONNX)',
                  subtitle: 'Real-time streaming ASR',
                  value: 'sherpa',
                  groupValue: SettingsService.transcriptionMode,
                  icon: Icons.bolt_outlined,
                  onChanged: (value) => setState(() => SettingsService.transcriptionMode = value!),
                ),

                // A local mode does nothing until its model is on disk, and
                // a silent no-transcript session is worse than a reminder.
                // Phrased so it stays true after the model is installed:
                // checking that here would mean an async store lookup in a
                // synchronous build, for a line the user reads once.
                if (SettingsService.transcriptionMode == 'whisper' ||
                    SettingsService.transcriptionMode == 'sherpa') ...[
                  Divider(height: 1, color: theme.dividerColor.withOpacity(0.1)),
                  Padding(
                    // Follows a divider rather than a tile, so unlike the
                    // Whisper size row above this one needs its own top inset.
                    padding: const EdgeInsets.fromLTRB(56, 12, 16, 4),
                    child: Row(
                      children: [
                        Text('Language:', style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.7))),
                        const SizedBox(width: 12),
                        Expanded(
                          child: SegmentedButton<String>(
                            segments: const [
                              ButtonSegment(value: 'en', label: Text('English')),
                              ButtonSegment(value: 'ko', label: Text('한국어')),
                            ],
                            selected: {SettingsService.localSttLanguage},
                            onSelectionChanged: (values) => setState(() => SettingsService.localSttLanguage = values.first),
                            style: ButtonStyle(
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(56, 12, 16, 12),
                    child: Text(
                      'Local modes transcribe on the phone and need their '
                      'model downloaded first — see Manage models below. '
                      'Korean needs its own streaming model downloaded '
                      '(~399 MB); SenseVoice covers Korean, English, '
                      'Chinese, Japanese and Cantonese in one offline model.',
                      style: TextStyle(
                        color: theme.colorScheme.onSurface.withOpacity(0.6),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],

                Divider(height: 1, color: theme.dividerColor.withOpacity(0.1)),
                ListTile(
                  leading: Icon(Icons.storage_outlined,
                      color: theme.colorScheme.onSurface.withOpacity(0.7)),
                  title: const Text('Manage models',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    'Download or remove on-device speech models',
                    style: TextStyle(
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                      fontSize: 13,
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => ModelsPage()),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),



          // Deepgram API Key
          if (SettingsService.useDeepgram) ...[
            _buildSectionHeader('Deepgram API Key'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _deepgramController,
                      obscureText: _obscureDeepgram,
                      decoration: InputDecoration(
                        hintText: 'Enter API Key',
                        labelText: 'API Key',
                        suffixIcon: IconButton(
                          icon: Icon(_obscureDeepgram ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                          onPressed: () => setState(() => _obscureDeepgram = !_obscureDeepgram),
                        ),
                      ),
                      onChanged: (value) {
                        SettingsService.deepgramApiKey = value;
                        setState(() {});
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Get from console.deepgram.com',
                      style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.5), fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      value: SettingsService.deepgramModel,
                      dropdownColor: const Color(0xFF2D2D2D),
                      decoration: const InputDecoration(
                        labelText: 'Model',
                      ),
                      icon: Icon(Icons.arrow_drop_down, color: theme.colorScheme.onSurface.withOpacity(0.5)),
                      items: const [
                        DropdownMenuItem(value: 'nova-2', child: Text('Nova-2')),
                        DropdownMenuItem(value: 'nova-3', child: Text('Nova-3')),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => SettingsService.deepgramModel = value);
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Streaming model used for live transcription',
                      style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.5), fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],

          // LLM
          _buildSectionHeader('LLM'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _openaiController,
                    obscureText: _obscureOpenai,
                    decoration: InputDecoration(
                      hintText: 'Enter API Key',
                      labelText: 'API Key',
                      suffixIcon: IconButton(
                        icon: Icon(_obscureOpenai ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _obscureOpenai = !_obscureOpenai),
                      ),
                    ),
                    onChanged: (value) {
                      SettingsService.openaiApiKey = value;
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Key for the configured endpoint below. Leave empty for a local '
                    'server such as Ollama that does not require one.',
                    style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.5), fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: presetForBaseUrl(SettingsService.llmBaseUrl).id,
                    dropdownColor: const Color(0xFF2D2D2D),
                    decoration: const InputDecoration(
                      labelText: 'Provider',
                    ),
                    icon: Icon(Icons.arrow_drop_down, color: theme.colorScheme.onSurface.withOpacity(0.5)),
                    items: [
                      for (final preset in llmPresets)
                        DropdownMenuItem(value: preset.id, child: Text(preset.label)),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      final preset = presetById(value);
                      setState(() {
                        if (preset.id != 'custom') {
                          SettingsService.llmBaseUrl = preset.baseUrl;
                          _llmBaseUrlController.text = SettingsService.llmBaseUrl;
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _llmBaseUrlController,
                    decoration: const InputDecoration(
                      hintText: 'e.g. http://localhost:11434/v1',
                      labelText: 'Base URL',
                    ),
                    onChanged: (value) {
                      SettingsService.llmBaseUrl = value;
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'OpenAI-compatible base URL, e.g. http://localhost:11434/v1 for Ollama.',
                    style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.5), fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: _llmModelDropdownValue(),
                    dropdownColor: const Color(0xFF2D2D2D),
                    decoration: const InputDecoration(
                      labelText: 'Model',
                    ),
                    icon: Icon(Icons.arrow_drop_down, color: theme.colorScheme.onSurface.withOpacity(0.5)),
                    items: [
                      for (final model in _llmModelChoices())
                        DropdownMenuItem(value: model, child: Text(model)),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => SettingsService.openaiModel = value);
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _newModelController,
                          decoration: const InputDecoration(
                            hintText: 'Add custom model id',
                            labelText: 'Custom model',
                          ),
                          onSubmitted: (_) => _addCustomModel(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: _addCustomModel,
                        child: const Text('Add'),
                      ),
                    ],
                  ),
                  if (SettingsService.llmCustomModels.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final model in SettingsService.llmCustomModels)
                          Chip(
                            label: Text(model),
                            onDeleted: () => _removeCustomModel(model),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _testingLlmConnection ? null : _testLlmConnection,
                        icon: _testingLlmConnection
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.wifi_tethering),
                        label: const Text('Test connection'),
                      ),
                    ],
                  ),
                  if (_llmConnectionResult != null) ...[
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          _llmConnectionResult!.ok
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          color: _llmConnectionResult!.ok ? Colors.green : Colors.red,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _llmConnectionResult!.message,
                            style: TextStyle(
                              color: _llmConnectionResult!.ok ? Colors.green : Colors.red,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  _buildLlmPricingEditor(theme),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),

          // Notifications section
          _buildSectionHeader('Notifications'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Battery Low (50%)', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('Alert when Omi reaches 50%',
                    style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 13)),
                  value: SettingsService.notifyBatteryLow,
                  onChanged: (value) {
                    setState(() => SettingsService.notifyBatteryLow = value);
                  },
                  activeColor: const Color(0xFF6C5CE7),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('Battery Critical (20%)', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('Alert when Omi reaches 20%',
                    style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 13)),
                  value: SettingsService.notifyBatteryCritical,
                  onChanged: (value) {
                    setState(() => SettingsService.notifyBatteryCritical = value);
                  },
                  activeColor: const Color(0xFF6C5CE7),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('Task Reminders', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('Reminders for scheduled tasks',
                    style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 13)),
                  value: SettingsService.notifyTaskReminders,
                  onChanged: (value) {
                    setState(() => SettingsService.notifyTaskReminders = value);
                  },
                  activeColor: const Color(0xFF6C5CE7),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('Processing Alerts', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('Show "Processing: query" notifications',
                    style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 13)),
                  value: SettingsService.notifyProcessing,
                  onChanged: (value) {
                    setState(() => SettingsService.notifyProcessing = value);
                  },
                  activeColor: const Color(0xFF6C5CE7),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('Exact task reminders', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(_exactAlarmSubtitle(),
                    style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 13)),
                  // Never claim exact delivery the system will not honour:
                  // the switch reads as off while the permission is denied,
                  // even if the stored opt-in is true. `unsupported` (not
                  // Android) is not a denial — there is nothing to grant
                  // there — so the switch still follows the stored value
                  // rather than becoming a control that does nothing.
                  value: SettingsService.exactTaskReminders &&
                      _exactAlarmStatus != ExactAlarmStatus.denied,
                  onChanged: _checkingExactAlarm
                      ? null
                      : (value) => _onExactTaskRemindersChanged(value),
                  activeColor: const Color(0xFF6C5CE7),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // Background reliability section
          _buildSectionHeader('Background reliability'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00b894).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.battery_charging_full,
                      color: Color(0xFF00b894),
                    ),
                  ),
                  title: const Text(
                    'Battery optimisation',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    _batteryOptimizationStatusText(),
                    style: TextStyle(
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                      fontSize: 13,
                    ),
                  ),
                ),
                // Only offered when Android says it is actually optimising,
                // or when the check itself failed and the user deserves a
                // retry. `null` means the platform has no such concept, so
                // the row would do nothing.
                if ((_isIgnoringBatteryOptimization == false ||
                        _batteryStatusCheckFailed) &&
                    !_checkingBatteryOptimization) ...[
                  const Divider(height: 1),
                  ListTile(
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6C5CE7).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.battery_alert,
                        color: Color(0xFF6C5CE7),
                      ),
                    ),
                    title: const Text(
                      'Request exemption',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      'Ask Android to stop restricting LibreOmi in the '
                      'background',
                      style: TextStyle(
                        color: theme.colorScheme.onSurface.withOpacity(0.6),
                        fontSize: 13,
                      ),
                    ),
                    enabled: !_requestingBatteryExemption,
                    onTap: _requestingBatteryExemption
                        ? null
                        : _requestBatteryExemption,
                  ),
                ],
                const Divider(height: 1),
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0984e3).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.help_outline,
                      color: Color(0xFF0984e3),
                    ),
                  ),
                  title: const Text(
                    'Manufacturer guidance',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    'Vendor-specific steps to keep LibreOmi running',
                    style: TextStyle(
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                      fontSize: 13,
                    ),
                  ),
                  trailing: Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: theme.colorScheme.onSurface.withOpacity(0.3),
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const BatteryGuidancePage(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // Data section
          _buildSectionHeader('Data'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00b894).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.download, color: Color(0xFF00b894)),
                  ),
                  title: const Text('Export All Data', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('Save conversations, memories & tasks as JSON',
                    style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 13)),
                  trailing: Icon(Icons.arrow_forward_ios, size: 16, color: theme.colorScheme.onSurface.withOpacity(0.3)),
                  onTap: () => _exportAllData(context),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0984e3).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.upload_file, color: Color(0xFF0984e3)),
                  ),
                  title: const Text('Import from Backup', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('Restore conversations, memories & tasks from a JSON file',
                    style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.6), fontSize: 13)),
                  trailing: Icon(Icons.arrow_forward_ios, size: 16, color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
                  onTap: () => _importAllData(context),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6C5CE7).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.bar_chart, color: Color(0xFF6C5CE7)),
                  ),
                  title: const Text('Statistics', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('View your usage stats',
                    style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 13)),
                  trailing: Icon(Icons.arrow_forward_ios, size: 16, color: theme.colorScheme.onSurface.withOpacity(0.3)),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const StatsPage()),
                  ),
                ),
                const Divider(height: 1),
                Consumer<DeviceController>(
                  builder: (context, provider, _) {
                    return ListTile(
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFe17055).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.sd_card, color: Color(0xFFe17055)),
                      ),
                      title: const Text('SD Card Sync', style: TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        provider.hasStorageSupport 
                            ? 'Sync offline recordings from device'
                            : 'Connect Omi to access',
                        style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 13)),
                      trailing: Icon(Icons.arrow_forward_ios, size: 16, color: theme.colorScheme.onSurface.withOpacity(0.3)),
                      enabled: provider.deviceState == DeviceConnectionState.connected,
                      onTap: provider.deviceState == DeviceConnectionState.connected 
                          ? () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const SdCardSyncPage()),
                            )
                          : null,
                    );
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0984e3).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.cloud_outlined, color: Color(0xFF0984e3)),
                  ),
                  title: const Text('iCloud Backup', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('Sync data across devices',
                    style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 13)),
                  value: SettingsService.icloudBackupEnabled,
                  onChanged: (value) {
                    setState(() => SettingsService.icloudBackupEnabled = value);
                    if (value) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('iCloud backup enabled. Data will sync automatically.')),
                      );
                    }
                  },
                  activeColor: const Color(0xFF0984e3),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // Privacy section (LO-64)
          _buildSectionHeader('Privacy'),
          Card(
            child: ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF6C5CE7).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.privacy_tip_outlined,
                  color: Color(0xFF6C5CE7),
                ),
              ),
              title: const Text(
                'Permissions & privacy',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                'What is collected, where it goes, and each permission\'s '
                'status',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                  fontSize: 13,
                ),
              ),
              trailing: Icon(
                Icons.arrow_forward_ios,
                size: 16,
                color: theme.colorScheme.onSurface.withOpacity(0.3),
              ),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const PermissionsRationalePage(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 32),

          // Developer section
          _buildSectionHeader('Developer'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Capture BLE session', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    'Records a replay fixture (audio, button, battery, storage notifications) '
                    'to the app support directory for use with `flutter test`',
                    style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 13)),
                  value: SettingsService.captureBleSession,
                  onChanged: (value) {
                    setState(() => SettingsService.captureBleSession = value);
                  },
                  activeColor: const Color(0xFF6C5CE7),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // About section
          Center(
            child: Column(
              children: [
                Text('LibreOmi', style: TextStyle(color: theme.colorScheme.onSurface, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('Version 2.1.0 • Self-Hosted', style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.5), fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  String _batteryOptimizationStatusText() {
    if (_checkingBatteryOptimization) {
      return 'Checking…';
    }
    if (_batteryStatusCheckFailed) {
      return 'Could not check battery optimisation';
    }
    return switch (_isIgnoringBatteryOptimization) {
      true => 'Exempt from battery optimisation',
      false => 'Battery optimisation is active',
      null => 'Not applicable on this platform',
    };
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 12),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontWeight: FontWeight.w700, 
          fontSize: 12,
          letterSpacing: 1.2,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  /// Models offered for the configured endpoint: the current preset's
  /// built-in models plus any user-added custom models, de-duplicated.
  List<String> _llmModelChoices() {
    final preset = presetForBaseUrl(SettingsService.llmBaseUrl);
    final seen = <String>{};
    final result = <String>[];
    for (final model in [...preset.models, ...SettingsService.llmCustomModels]) {
      if (seen.add(model)) {
        result.add(model);
      }
    }
    final current = SettingsService.openaiModel;
    if (seen.add(current)) {
      result.add(current);
    }
    return result;
  }

  /// The model dropdown's current value. Always present in
  /// [_llmModelChoices] so `DropdownButtonFormField`'s assert never trips.
  String _llmModelDropdownValue() => SettingsService.openaiModel;

  void _addCustomModel() {
    final id = _newModelController.text.trim();
    if (id.isEmpty) return;
    final existing = SettingsService.llmCustomModels;
    if (existing.contains(id)) {
      _newModelController.clear();
      return;
    }
    setState(() {
      SettingsService.llmCustomModels = [...existing, id];
      _newModelController.clear();
    });
  }

  void _removeCustomModel(String id) {
    setState(() {
      SettingsService.llmCustomModels =
          SettingsService.llmCustomModels.where((m) => m != id).toList();
    });
  }

  Future<void> _testLlmConnection() async {
    setState(() {
      _testingLlmConnection = true;
      _llmConnectionResult = null;
    });
    final service = OpenAIService(
      apiKey: SettingsService.openaiApiKey,
      model: SettingsService.openaiModel,
      baseUrl: SettingsService.llmBaseUrl,
    );
    final result = await service.testConnection();
    if (!mounted) return;
    setState(() {
      _testingLlmConnection = false;
      _llmConnectionResult = result;
    });
  }

  Widget _buildLlmPricingEditor(ThemeData theme) {
    final pricing = SettingsService.llmPricing;
    final entries = pricing.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    // Every write re-reads the stored table instead of closing over the
    // build-time `pricing` snapshot: these handlers fire without a rebuild
    // (editing a price must not steal focus), so a captured snapshot would
    // go stale and a second edit would revert the first.
    void updatePrice(String modelId, {double? input, double? output}) {
      final updated = {
        for (final entry in SettingsService.llmPricing.entries)
          entry.key: Map<String, double>.from(entry.value),
      };
      final row = updated[modelId] ?? {'input': 0.0, 'output': 0.0};
      if (input != null) row['input'] = input;
      if (output != null) row['output'] = output;
      updated[modelId] = row;
      SettingsService.llmPricing = updated;
    }

    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('Pricing (per 1M tokens)', style: TextStyle(fontWeight: FontWeight.w600)),
      children: [
        Text(
          'Models without a price show a cost of "—" on the stats page.',
          style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.5), fontSize: 12),
        ),
        const SizedBox(height: 12),
        for (final entry in entries) ...[
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(entry.key, style: const TextStyle(fontSize: 13)),
              ),
              Expanded(
                flex: 2,
                child: TextFormField(
                  key: ValueKey('llm_price_input_${entry.key}'),
                  initialValue: entry.value['input']?.toString() ?? '0',
                  decoration: const InputDecoration(labelText: 'Input \$'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (value) {
                    final parsed = double.tryParse(value);
                    if (parsed != null) {
                      updatePrice(entry.key, input: parsed);
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextFormField(
                  key: ValueKey('llm_price_output_${entry.key}'),
                  initialValue: entry.value['output']?.toString() ?? '0',
                  decoration: const InputDecoration(labelText: 'Output \$'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (value) {
                    final parsed = double.tryParse(value);
                    if (parsed != null) {
                      updatePrice(entry.key, output: parsed);
                    }
                  },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () {
                  final updated = {
                    for (final e in SettingsService.llmPricing.entries)
                      if (e.key != entry.key) e.key: e.value,
                  };
                  setState(() => SettingsService.llmPricing = updated);
                },
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _newPricedModelController,
                decoration: const InputDecoration(
                  hintText: 'Model id to price',
                  labelText: 'Add priced model',
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () {
                final id = _newPricedModelController.text.trim();
                final current = SettingsService.llmPricing;
                if (id.isEmpty || current.containsKey(id)) return;
                final updated = {
                  for (final entry in current.entries) entry.key: entry.value,
                  id: {'input': 0.0, 'output': 0.0},
                };
                setState(() {
                  SettingsService.llmPricing = updated;
                  _newPricedModelController.clear();
                });
              },
              child: const Text('Add'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => SettingsService.resetLlmPricing()),
            child: const Text('Reset to defaults'),
          ),
        ),
      ],
    );
  }

  Widget _buildRadioTile({
    required String title,
    required String subtitle,
    required String value,
    required String groupValue,
    required IconData icon,
    required ValueChanged<String?> onChanged,
  }) {
    final isSelected = value == groupValue;
    final theme = Theme.of(context);
    
    return RadioListTile<String>(
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 13)),
      value: value,
      groupValue: groupValue,
      onChanged: onChanged,
      secondary: Icon(
        icon,
        color: isSelected ? const Color(0xFF6C5CE7) : theme.colorScheme.onSurface.withOpacity(0.5),
      ),
      activeColor: const Color(0xFF6C5CE7),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    );
  }

  @override
  void dispose() {
    _deepgramController.dispose();
    _openaiController.dispose();
    _llmBaseUrlController.dispose();
    _newModelController.dispose();
    _newPricedModelController.dispose();
    super.dispose();
  }

  Future<void> _exportAllData(BuildContext context) async {
    // Store navigator before async operations
    final navigator = Navigator.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    
    // Get the render box for share positioning (needed on iPad)
    final box = context.findRenderObject() as RenderBox?;
    final sharePosition = box != null 
        ? box.localToGlobal(Offset.zero) & box.size
        : const Rect.fromLTWH(0, 0, 100, 100);
    
    _showBlockingProgress(context, 'Preparing export...');

    try {
      // Get all data
      final data = await context.read<LibraryController>().exportAllData();
      final jsonString = await compute(_encodeExportJson, data);

      // Save to temp file
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/${exportFileName(DateTime.now())}');
      await file.writeAsString(jsonString);

      // Close loading dialog
      navigator.pop();

      // Share the file with proper origin for iPad
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'LibreOmi Backup',
        sharePositionOrigin: sharePosition,
      );
    } catch (e) {
      // Close loading dialog if open
      navigator.pop();

      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  /// Lets the user pick a `.json` backup, confirm what it contains and how to
  /// apply it, then restores it through [LibraryController.importAllData].
  ///
  /// Every branch pops the progress dialog exactly once: the `try` block below
  /// has one success path and two catch paths, none of them reached before the
  /// dialog is showing, and [_showBlockingProgress] blocks the back button so
  /// the dialog cannot already be gone by then.
  Future<void> _importAllData(BuildContext context) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null) return;
    final path = result.files.single.path;
    if (path == null) return;
    if (!context.mounted) return;

    final scaffoldMessenger = ScaffoldMessenger.of(context);

    Map<String, dynamic> document;
    try {
      final contents = await File(path).readAsString();
      final decoded = await compute(_decodeImportJson, contents);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('The file is not a JSON object.');
      }
      document = decoded;
    } catch (e) {
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Could not read backup file: $e')),
      );
      return;
    }

    if (!context.mounted) return;
    final counts = summarize(document);
    final mode = await _confirmImportMode(context, document, counts);
    if (mode == null) return;

    if (!context.mounted) return;
    final navigator = Navigator.of(context);

    _showBlockingProgress(context, 'Restoring backup...');

    try {
      final report = await context
          .read<LibraryController>()
          .importAllData(document, mode: mode);

      // Close loading dialog
      navigator.pop();

      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(
            'Imported ${report.inserted} new, updated ${report.updated}, '
            'skipped ${report.skipped}.',
          ),
          action: report.errors.isEmpty
              ? null
              : SnackBarAction(
                  label: 'Details',
                  onPressed: () => _showSkippedRows(report),
                ),
        ),
      );
    } on ImportFormatException catch (e) {
      // Close loading dialog if open
      navigator.pop();

      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Import failed: ${e.message}')),
      );
    } catch (e) {
      // Close loading dialog if open
      navigator.pop();

      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    }
  }

  /// Confirms what to import and how. Returns `null` when the user cancels
  /// at either the summary dialog or the replace-mode warning.
  Future<ImportMode?> _confirmImportMode(
    BuildContext context,
    Map<String, dynamic> document,
    Map<String, int> counts,
  ) async {
    final exportedAt = document['exported_at'];
    final appVersion = document['app_version'];

    final mode = await showDialog<ImportMode>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restore Backup'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Conversations: ${counts['conversations'] ?? 0}'),
            Text('Memories: ${counts['memories'] ?? 0}'),
            Text('Tasks: ${counts['tasks'] ?? 0}'),
            Text('Chat messages: ${counts['chat_messages'] ?? 0}'),
            if (exportedAt is String) ...[
              const SizedBox(height: 8),
              Text('Exported: $exportedAt'),
            ],
            if (appVersion is String) Text('App version: $appVersion'),
            const SizedBox(height: 12),
            const Text(
              'Merge adds these on top of what you have. Replace deletes '
              'everything currently stored first.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(ImportMode.merge),
            child: const Text('Merge'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(ImportMode.replace),
            child: const Text('Replace'),
          ),
        ],
      ),
    );

    if (mode != ImportMode.replace) return mode;
    if (!context.mounted) return null;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Replace All Data?'),
        content: const Text(
          'This deletes every conversation, memory, task and chat message '
          'currently stored before restoring the file. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete & Replace'),
          ),
        ],
      ),
    );

    return confirmed == true ? ImportMode.replace : null;
  }

  /// A modal spinner the user cannot dismiss — not by tapping the barrier and
  /// not with the system back button, which a bare `barrierDismissible: false`
  /// still allows. Both callers pop it themselves once the work is done, and
  /// that pop must not be able to take the settings page with it.
  void _showBlockingProgress(BuildContext context, String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: Center(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(message),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Shows why rows were skipped. The report describes only the first few, so
  /// say so when there were more than it kept.
  void _showSkippedRows(ImportReport report) {
    if (!mounted) return;
    final hidden = report.skipped - report.errors.length;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${report.skipped} rows skipped'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final error in report.errors) Text(error),
              if (hidden > 0) ...[
                const SizedBox(height: 8),
                Text('...and $hidden more.'),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// On-disk size of [spec] in whole megabytes, for the offline model picker.
///
/// `models_page.dart` formats the same number the same way for its own
/// listing; the two are a line of arithmetic each and are deliberately not
/// shared, because a shared helper would have to live in `transcription/`
/// and that layer has no business formatting UI strings.
String _installedMegabytes(ModelSpec spec) =>
    (spec.installedBytes / (1024 * 1024)).round().toString();

/// Runs off the UI isolate via [compute]; must be top-level or static.
String _encodeExportJson(Map<String, dynamic> data) =>
    const JsonEncoder.withIndent('  ').convert(data);

/// Runs off the UI isolate via [compute]; must be top-level or static.
Object? _decodeImportJson(String contents) => jsonDecode(contents);
