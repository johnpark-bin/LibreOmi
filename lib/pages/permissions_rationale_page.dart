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

import '../l10n/l10n.dart';
import '../platform/battery_optimization.dart';
import '../platform/battery_optimization_gateway.dart' show batteryOptimization;
import '../platform/exact_alarm.dart';
import '../platform/exact_alarm_gateway.dart' show exactAlarm;
import '../platform/permission_gateway.dart' show appPermissions;
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
    this.exactAlarmOverride,
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

  /// Injected for widget tests so they never touch a plugin channel.
  /// Defaults to the app-wide instance.
  final ExactAlarm? exactAlarmOverride;

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
  bool _statusLoadFailed = false;
  bool? _batteryIgnoring;
  bool _batteryLoadFailed = false;
  ExactAlarmStatus? _exactAlarmStatus;

  AppPermissions get _permissions =>
      widget.permissionsOverride ?? appPermissions;
  BatteryOptimization get _battery =>
      widget.batteryOptimizationOverride ?? batteryOptimization;
  ExactAlarm get _exactAlarm => widget.exactAlarmOverride ?? exactAlarm;

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
    bool statusLoadFailed = false;
    bool? batteryIgnoring;
    bool batteryLoadFailed = false;
    ExactAlarmStatus? exactAlarmStatus;
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
      statusLoadFailed = true;
      debugPrint('permissions rationale: status load failed: $e');
    }
    try {
      batteryIgnoring = await _battery.isIgnoring();
    } catch (e) {
      batteryLoadFailed = true;
      debugPrint('permissions rationale: battery status load failed: $e');
    }
    try {
      exactAlarmStatus = await _exactAlarm.status();
    } catch (e) {
      // Left null, which the row renders as unknown.
      debugPrint('permissions rationale: exact-alarm status load failed: $e');
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _sdkInt = sdkInt;
      _statuses = statuses;
      _notificationIsRuntime = notificationIsRuntime;
      _statusLoadFailed = statusLoadFailed;
      _batteryIgnoring = batteryIgnoring;
      _batteryLoadFailed = batteryLoadFailed;
      _exactAlarmStatus = exactAlarmStatus;
      _loaded = true;
    });
  }

  void _continue() {
    // `main.dart` shows this screen when the settings store could not be read
    // at all, and the setter throws in exactly that case. Recording the flag
    // is best-effort; leaving the user stuck on the disclosure with no way
    // forward is not.
    try {
      SettingsService.rationaleShown = true;
    } catch (e) {
      debugPrint('permissions rationale: could not record that it was shown: $e');
    }
    widget.onContinue?.call();
  }

  Future<void> _openSettings() => _permissions.openAppSettings();

  /// Exact alarms have their own system screen ("Alarms & reminders"), which
  /// the app-settings page does not lead to on every OEM skin.
  Future<void> _openAlarmSettings() async {
    final status = await _exactAlarm.openSettings();
    if (!mounted) {
      return;
    }
    setState(() => _exactAlarmStatus = status);
  }

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
    final l10n = L10n.of(context);
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
    // A failed load leaves the API level unknown, and "not required on this
    // Android version" would then be a claim rather than a fact.
    final _RowStatus notificationStatus;
    if (_statusLoadFailed) {
      notificationStatus = _RowStatus.unknown;
    } else if (_notificationIsRuntime) {
      notificationStatus = _aggregate(<AppPermission>[
        AppPermission.notification,
      ]);
    } else {
      notificationStatus = _RowStatus.notRequired;
    }

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

    final _RowStatus exactAlarmStatus;
    switch (_exactAlarmStatus) {
      case null:
        exactAlarmStatus = _RowStatus.unknown;
      case ExactAlarmStatus.granted:
        exactAlarmStatus = _RowStatus.granted;
      case ExactAlarmStatus.denied:
        exactAlarmStatus = _RowStatus.notGranted;
      case ExactAlarmStatus.unsupported:
        exactAlarmStatus = _RowStatus.notApplicable;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.common_permissionsPrivacyLabel),
        automaticallyImplyLeading: !widget.isFirstRun,
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _RationaleView(
              isFirstRun: widget.isFirstRun,
              bleLegacy: bleLegacy,
              bleStatus: bleStatus,
              microphoneStatus: microphoneStatus,
              notificationStatus: notificationStatus,
              batteryStatus: batteryStatus,
              exactAlarmStatus: exactAlarmStatus,
              onOpenSettings: _openSettings,
              onOpenAlarmSettings: _openAlarmSettings,
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
    required this.notificationStatus,
    required this.batteryStatus,
    required this.exactAlarmStatus,
    required this.onOpenSettings,
    required this.onOpenAlarmSettings,
    required this.onContinue,
  });

  final bool isFirstRun;
  final bool bleLegacy;
  final _RowStatus bleStatus;
  final _RowStatus microphoneStatus;
  final _RowStatus notificationStatus;
  final _RowStatus batteryStatus;
  final _RowStatus exactAlarmStatus;
  final Future<void> Function() onOpenSettings;
  final Future<void> Function() onOpenAlarmSettings;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final bodyStyle = TextStyle(
      color: theme.colorScheme.onSurface.withOpacity(0.7),
    );

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _buildSectionHeader(context, l10n.permissionsRationale_collectsHeader),
        Text(
          l10n.permissionsRationale_collectsBody,
          style: bodyStyle,
        ),
        const SizedBox(height: 20),
        _buildSectionHeader(context, l10n.permissionsRationale_whereGoesHeader),
        Text(
          l10n.permissionsRationale_whereGoesBody,
          style: bodyStyle,
        ),
        const SizedBox(height: 20),
        _buildSectionHeader(context, l10n.permissionsRationale_whereStoredHeader),
        Text(
          l10n.permissionsRationale_whereStoredBody,
          style: bodyStyle,
        ),
        const SizedBox(height: 20),
        _buildSectionHeader(context, l10n.permissionsRationale_yourControlHeader),
        Text(
          l10n.permissionsRationale_yourControlBody,
          style: bodyStyle,
        ),
        const SizedBox(height: 24),
        _buildSectionHeader(context, l10n.permissionsRationale_permissionsHeader),
        _PermissionRow(
          title: bleLegacy
              ? l10n.permissionsRationale_bluetoothTitleLegacy
              : l10n.permissionsRationale_bluetoothTitle,
          description: bleLegacy
              ? l10n.permissionsRationale_bluetoothDescriptionLegacy
              : l10n.permissionsRationale_bluetoothDescription,
          status: bleStatus,
          onOpenSettings: onOpenSettings,
        ),
        _PermissionRow(
          title: l10n.permissionsRationale_microphoneTitle,
          description: l10n.permissionsRationale_microphoneDescription,
          status: microphoneStatus,
          onOpenSettings: onOpenSettings,
        ),
        _PermissionRow(
          title: l10n.permissionsRationale_notificationsTitle,
          description: l10n.permissionsRationale_notificationsDescription,
          status: notificationStatus,
          onOpenSettings: notificationStatus == _RowStatus.notRequired
              ? null
              : onOpenSettings,
        ),
        _PermissionRow(
          title: l10n.permissionsRationale_foregroundServiceTitle,
          description: l10n.permissionsRationale_foregroundServiceDescription,
          status: null,
          fixedChipText: l10n.permissionsRationale_foregroundServiceChip,
          onOpenSettings: null,
        ),
        _PermissionRow(
          title: l10n.permissionsRationale_exactAlarmsTitle,
          description: l10n.permissionsRationale_exactAlarmsDescription,
          status: exactAlarmStatus,
          onOpenSettings: exactAlarmStatus == _RowStatus.notApplicable
              ? null
              : onOpenAlarmSettings,
        ),
        _PermissionRow(
          title: l10n.permissionsRationale_batteryTitle,
          description: l10n.permissionsRationale_batteryDescription,
          status: batteryStatus,
          onOpenSettings: batteryStatus == _RowStatus.notApplicable
              ? null
              : onOpenSettings,
        ),
        const SizedBox(height: 20),
        Text(
          l10n.permissionsRationale_closingNote,
          style: bodyStyle.copyWith(fontStyle: FontStyle.italic),
        ),
        if (isFirstRun) ...[
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: onContinue,
            child: Text(l10n.permissionsRationale_continueButton),
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

  String _chipText(AppLocalizations l10n) {
    if (fixedChipText != null) {
      return fixedChipText!;
    }
    switch (status!) {
      case _RowStatus.granted:
        return l10n.permissionsRationale_chipGranted;
      case _RowStatus.notGranted:
        return l10n.permissionsRationale_chipNotGranted;
      case _RowStatus.permanentlyDenied:
        return l10n.permissionsRationale_chipDeniedOpenSettings;
      case _RowStatus.notRequired:
        return l10n.permissionsRationale_chipNotRequired;
      case _RowStatus.notApplicable:
        return l10n.permissionsRationale_chipNotApplicable;
      case _RowStatus.unknown:
        return l10n.permissionsRationale_chipUnknown;
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
    final l10n = L10n.of(context);
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
                    _chipText(l10n),
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
                  child: Text(l10n.permissionsRationale_openSettingsButton),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
