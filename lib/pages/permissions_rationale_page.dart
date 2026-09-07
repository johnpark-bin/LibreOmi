/// The Play Console "prominent disclosure" screen: what LibreOmi collects,
/// where it goes, where it is stored, and the current status of every
/// permission the app can use. See `docs/06-roadmap.md` LO-64 and
/// `lib/platform/permissions.dart` / `lib/platform/battery_optimization.dart`
/// for the facades this page reads from.
///
/// This page never requests a permission — it only reads current status and
/// can open system settings. Requesting stays with the point-of-use flows
/// (see `AppPermissions.ensure*`); this screen exists purely to explain and
/// disclose.
library;

import 'package:flutter/material.dart';

import '../platform/battery_optimization.dart';
import '../platform/battery_optimization_gateway.dart';
import '../platform/permission_gateway.dart';
import '../platform/permissions.dart';
import '../services/settings_service.dart';

/// A single permission row's status, independent of how many underlying
/// `AppPermission`s were combined to produce it.
enum _RowStatus {
  granted,
  notGranted,
  permanentlyDenied,
  notRequired,
  notApplicable,
  unknown,
}

class PermissionsRationalePage extends StatefulWidget {
  const PermissionsRationalePage({
    super.key,
    this.isFirstRun = false,
    this.permissionsOverride,
    this.batteryOptimizationOverride,
    this.onContinue,
  });

  /// Shown as the first-run gate: adds a Continue button and hides the back
  /// arrow. Set by `main.dart`'s first-launch routing (a separate unit).
  final bool isFirstRun;

  /// Injected for widget tests so they never touch a plugin channel.
  /// Defaults to the app-wide instance.
  final AppPermissions? permissionsOverride;

  /// Injected for widget tests so they never touch a plugin channel.
  /// Defaults to the app-wide instance.
  final BatteryOptimization? batteryOptimizationOverride;

  /// Called after Continue records that the rationale has been shown. This
  /// page never navigates itself (and never imports `home_page.dart`) so the
  /// first-run routing stays entirely in `main.dart`.
  final VoidCallback? onContinue;

  @override
  State<PermissionsRationalePage> createState() =>
      _PermissionsRationalePageState();
}

class _PermissionsRationalePageState extends State<PermissionsRationalePage> {
  bool _loaded = false;
  int? _sdkInt;
  Map<AppPermission, PermissionOutcome> _statuses =
      <AppPermission, PermissionOutcome>{};
  bool _notificationIsRuntime = false;
  bool? _batteryIgnoring;
  bool _batteryLoadFailed = false;

  AppPermissions get _permissions =>
      widget.permissionsOverride ?? appPermissions;
  BatteryOptimization get _battery =>
      widget.batteryOptimizationOverride ?? batteryOptimization;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    int? sdkInt;
    Map<AppPermission, PermissionOutcome> statuses =
        <AppPermission, PermissionOutcome>{};
    bool notificationIsRuntime = false;
    bool? batteryIgnoring;
    bool batteryLoadFailed = false;
    try {
      sdkInt = await _permissions.gateway.androidSdkInt();
      final ble = sdkInt == null || sdkInt >= 31
          ? <AppPermission>[
              AppPermission.bluetoothScan,
              AppPermission.bluetoothConnect,
            ]
          : <AppPermission>[AppPermission.fineLocation];
      notificationIsRuntime = sdkInt == null || sdkInt >= 33;
      final toCheck = <AppPermission>[
        ...ble,
        AppPermission.microphone,
        if (notificationIsRuntime) AppPermission.notification,
      ];
      statuses = await _permissions.currentStatuses(toCheck);
    } catch (e) {
      // Never leave the page spinning on a plugin failure: every runtime
      // status renders as unknown instead (mirrors battery_guidance_page.dart's
      // fallback-on-failure behaviour).
      debugPrint('permissions rationale: status load failed: $e');
    }
    try {
      batteryIgnoring = await _battery.isIgnoring();
    } catch (e) {
      batteryLoadFailed = true;
      debugPrint('permissions rationale: battery status load failed: $e');
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _sdkInt = sdkInt;
      _statuses = statuses;
      _notificationIsRuntime = notificationIsRuntime;
      _batteryIgnoring = batteryIgnoring;
      _batteryLoadFailed = batteryLoadFailed;
      _loaded = true;
    });
  }

  Future<void> _continue() async {
    SettingsService.rationaleShown = true;
    widget.onContinue?.call();
  }

  Future<void> _openSettings() => _permissions.openAppSettings();

  /// "Worst wins" over the given permissions' statuses: permanentlyDenied >
  /// denied > granted. A permission missing from [_statuses] (i.e. the load
  /// failed before it was fetched) counts as unknown, which itself wins over
  /// everything else so a partial failure never reads as falsely reassuring.
  _RowStatus _aggregate(List<AppPermission> permissions) {
    if (!_loaded) {
      return _RowStatus.unknown;
    }
    if (permissions.any((p) => !_statuses.containsKey(p))) {
      return _RowStatus.unknown;
    }
    final outcomes = permissions.map((p) => _statuses[p]!).toList();
    if (outcomes.contains(PermissionOutcome.permanentlyDenied)) {
      return _RowStatus.permanentlyDenied;
    }
    if (outcomes.contains(PermissionOutcome.denied)) {
      return _RowStatus.notGranted;
    }
    return _RowStatus.granted;
  }

  @override
  Widget build(BuildContext context) {
    final sdkInt = _sdkInt;
    final bleLegacy = sdkInt != null && sdkInt < 31;
    final bleStatus = _aggregate(
      bleLegacy
          ? <AppPermission>[AppPermission.fineLocation]
          : <AppPermission>[
              AppPermission.bluetoothScan,
              AppPermission.bluetoothConnect,
            ],
    );
    final microphoneStatus = _aggregate(<AppPermission>[
      AppPermission.microphone,
    ]);
    final notificationStatus = _notificationIsRuntime
        ? _aggregate(<AppPermission>[AppPermission.notification])
        : _RowStatus.notRequired;

    final _RowStatus batteryStatus;
    if (!_loaded || _batteryLoadFailed) {
      batteryStatus = _RowStatus.unknown;
    } else if (_batteryIgnoring == null) {
      batteryStatus = _RowStatus.notApplicable;
    } else if (_batteryIgnoring == true) {
      batteryStatus = _RowStatus.granted;
    } else {
      batteryStatus = _RowStatus.notGranted;
    }

    final showAppBar = !widget.isFirstRun || widget.isFirstRun;
    return Scaffold(
      appBar: showAppBar
          ? AppBar(
              title: const Text('Permissions & privacy'),
              automaticallyImplyLeading: !widget.isFirstRun,
            )
          : null,
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _RationaleView(
              isFirstRun: widget.isFirstRun,
              bleLegacy: bleLegacy,
              bleStatus: bleStatus,
              microphoneStatus: microphoneStatus,
              notificationIsRuntime: _notificationIsRuntime,
              notificationStatus: notificationStatus,
              batteryStatus: batteryStatus,
              onOpenSettings: _openSettings,
              onContinue: _continue,
            ),
    );
  }
}

class _RationaleView extends StatelessWidget {
  const _RationaleView({
    required this.isFirstRun,
    required this.bleLegacy,
    required this.bleStatus,
    required this.microphoneStatus,
    required this.notificationIsRuntime,
    required this.notificationStatus,
    required this.batteryStatus,
    required this.onOpenSettings,
    required this.onContinue,
  });

  final bool isFirstRun;
  final bool bleLegacy;
  final _RowStatus bleStatus;
  final _RowStatus microphoneStatus;
  final bool notificationIsRuntime;
  final _RowStatus notificationStatus;
  final _RowStatus batteryStatus;
  final Future<void> Function() onOpenSettings;
  final Future<void> Function() onContinue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bodyStyle = TextStyle(
      color: theme.colorScheme.onSurface.withOpacity(0.7),
    );

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _buildSectionHeader(context, 'What LibreOmi collects'),
        Text(
          'Audio captured from your Omi wearable or your phone\'s microphone '
          'while a capture is running, and the transcripts, conversations, '
          'memories and tasks derived from it.',
          style: bodyStyle,
        ),
        const SizedBox(height: 20),
        _buildSectionHeader(context, 'Where it goes'),
        Text(
          'There is no LibreOmi server and no account. Speech is transcribed '
          'either entirely on your phone (on-device model) or, if you enter a '
          'Deepgram API key, by sending audio to Deepgram. Conversation text is '
          'sent to the LLM endpoint you configure only when you supply a key '
          'for it. With no keys entered, nothing leaves the phone.',
          style: bodyStyle,
        ),
        const SizedBox(height: 20),
        _buildSectionHeader(context, 'Where it is stored'),
        Text(
          'In a SQLite database in the app\'s private storage, with downloaded '
          'speech models in a directory excluded from Android\'s auto-backup. '
          'API keys are held in the Android keystore, not in the database, '
          'and are excluded from backup.',
          style: bodyStyle,
        ),
        const SizedBox(height: 20),
        _buildSectionHeader(context, 'Your control'),
        Text(
          'Settings → Data → Export All Data writes everything as JSON; '
          'Import from Backup restores it. Deleting the app, or clearing its '
          'data in Android settings, removes everything on the device.',
          style: bodyStyle,
        ),
        const SizedBox(height: 24),
        _buildSectionHeader(context, 'Permissions'),
        _PermissionRow(
          title: bleLegacy ? 'Bluetooth (location permission)' : 'Bluetooth',
          description: bleLegacy
              ? 'Finds and connects to your Omi wearable. LibreOmi scans only '
                    'for Omi devices and never uses Bluetooth to determine your '
                    'location. Android 11 and older require the location '
                    'permission for any Bluetooth scan; LibreOmi does not read '
                    'your location.'
              : 'Finds and connects to your Omi wearable. LibreOmi scans only '
                    'for Omi devices and never uses Bluetooth to determine your '
                    'location.',
          status: bleStatus,
          onOpenSettings: onOpenSettings,
        ),
        _PermissionRow(
          title: 'Microphone',
          description:
              'Records audio only while you have started a capture with the '
              'phone microphone as the source. Nothing is recorded when the '
              'app is idle.',
          status: microphoneStatus,
          onOpenSettings: onOpenSettings,
        ),
        _PermissionRow(
          title: 'Notifications',
          description:
              'Shows the ongoing capture notification Android requires for '
              'background recording, and alerts when a conversation is saved.',
          status: notificationStatus,
          onOpenSettings: notificationIsRuntime ? onOpenSettings : null,
        ),
        _PermissionRow(
          title: 'Foreground service',
          description:
              'Keeps capture and transcription running while the screen is '
              'off. Android grants this from the manifest and never asks.',
          status: null,
          fixedChipText: 'Declared in the manifest',
          onOpenSettings: null,
        ),
        _PermissionRow(
          title: 'Battery optimisation exemption',
          description:
              'Optional. Without it some phones stop LibreOmi\'s background '
              'capture after a few minutes.',
          status: batteryStatus,
          onOpenSettings: batteryStatus == _RowStatus.notApplicable
              ? null
              : onOpenSettings,
        ),
        const SizedBox(height: 20),
        Text(
          'This page never asks for a permission — each one is requested at '
          'the moment the feature that needs it is first used.',
          style: bodyStyle.copyWith(fontStyle: FontStyle.italic),
        ),
        if (isFirstRun) ...[
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: onContinue,
            child: const Text('Continue'),
          ),
        ],
      ],
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
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
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.title,
    required this.description,
    required this.status,
    required this.onOpenSettings,
    this.fixedChipText,
  });

  final String title;
  final String description;

  /// Null when this row has no runtime status at all (foreground service),
  /// in which case [fixedChipText] supplies the chip text instead.
  final _RowStatus? status;
  final String? fixedChipText;
  final Future<void> Function()? onOpenSettings;

  String _chipText() {
    if (fixedChipText != null) {
      return fixedChipText!;
    }
    switch (status!) {
      case _RowStatus.granted:
        return 'Granted';
      case _RowStatus.notGranted:
        return 'Not granted';
      case _RowStatus.permanentlyDenied:
        return 'Denied — open settings';
      case _RowStatus.notRequired:
        return 'Not required on this Android version';
      case _RowStatus.notApplicable:
        return 'Not applicable';
      case _RowStatus.unknown:
        return 'Unknown';
    }
  }

  Color _chipColor(BuildContext context) {
    final theme = Theme.of(context);
    if (fixedChipText != null) {
      return theme.colorScheme.onSurface.withOpacity(0.6);
    }
    switch (status!) {
      case _RowStatus.granted:
        return Colors.greenAccent.shade400;
      case _RowStatus.notGranted:
        return Colors.orangeAccent.shade200;
      case _RowStatus.permanentlyDenied:
        return Colors.redAccent.shade200;
      case _RowStatus.notRequired:
      case _RowStatus.notApplicable:
        return theme.colorScheme.onSurface.withOpacity(0.6);
      case _RowStatus.unknown:
        return theme.colorScheme.onSurface.withOpacity(0.6);
    }
  }

  bool get _showOpenSettings {
    if (onOpenSettings == null) {
      return false;
    }
    if (fixedChipText != null) {
      return false;
    }
    return status == _RowStatus.notGranted ||
        status == _RowStatus.permanentlyDenied;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: _chipColor(context).withOpacity(0.18),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _chipText(),
                    style: TextStyle(
                      color: _chipColor(context),
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              description,
              style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.7),
              ),
            ),
            if (_showOpenSettings) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: onOpenSettings,
                  child: const Text('Open settings'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
