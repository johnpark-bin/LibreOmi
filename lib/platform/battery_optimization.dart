/// Pure-Dart battery-optimisation model, importable from `flutter test`
/// without touching any plugin channel. See
/// `docs/04-android-platform-notes.md` §3 and §11 for the intent this facade
/// wraps and the OEM killers the guidance table exists for.
library;

/// The result of asking Android to exempt the app from battery optimisation.
enum BatteryOptimizationOutcome {
  /// The app is on the Doze whitelist, either because the user just accepted
  /// the system dialog or because it already was.
  ignoring,

  /// The user dismissed or refused the system dialog.
  denied,

  /// There is nothing to request: not running on Android.
  unsupported,
}

/// The platform surface [BatteryOptimization] needs. Implemented for real by
/// `PluginBatteryOptimizationGateway` (see
/// `lib/platform/battery_optimization_gateway.dart`) and faked in tests so
/// this file never has to import a plugin.
abstract class BatteryOptimizationGateway {
  /// Whether the app is currently exempt from battery optimisation, or `null`
  /// when not running on Android (where the concept does not exist).
  Future<bool?> isIgnoring();

  /// Fires `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` and reports whether the app
  /// is exempt afterwards. Returns `null` when not running on Android.
  Future<bool?> requestIgnore();

  /// `Build.MANUFACTURER`, or `null` when not running on Android.
  Future<String?> manufacturer();
}

/// Vendor-specific instructions for keeping a foreground service alive, plus
/// the dontkillmyapp.com page that documents them.
class OemGuidance {
  const OemGuidance({
    required this.vendor,
    required this.steps,
    required this.url,
  });

  /// Display name of the vendor this entry covers.
  final String vendor;

  /// Short, ordered steps the user follows in the vendor's own settings app.
  final List<String> steps;

  /// The dontkillmyapp.com page with the full, maintained write-up.
  final String url;
}

/// The facade the app calls to keep the BLE session alive through Doze.
///
/// Battery optimisation is an Android-only concept, so every method reports
/// [BatteryOptimizationOutcome.unsupported] (or `null`) when
/// [BatteryOptimizationGateway] says the app is not on Android.
class BatteryOptimization {
  BatteryOptimization(this.gateway);

  final BatteryOptimizationGateway gateway;

  /// Whether the app is already exempt, or `null` when not on Android.
  Future<bool?> isIgnoring() => gateway.isIgnoring();

  /// Shows the system exemption dialog and reports what came back.
  Future<BatteryOptimizationOutcome> request() async {
    final ignoring = await gateway.requestIgnore();
    if (ignoring == null) {
      return BatteryOptimizationOutcome.unsupported;
    }
    return ignoring
        ? BatteryOptimizationOutcome.ignoring
        : BatteryOptimizationOutcome.denied;
  }

  /// Whether the one-time explanation dialog should be shown before starting
  /// a session. It is shown only on Android, only while the app is still
  /// being optimised, and only until [promptShown] has been recorded — so a
  /// user who refused once is never nagged again and has to come back through
  /// the settings page.
  Future<bool> shouldPrompt({required bool promptShown}) async {
    if (promptShown) {
      return false;
    }
    final ignoring = await gateway.isIgnoring();
    if (ignoring == null) {
      return false;
    }
    return !ignoring;
  }

  /// The guidance entry for the device this is running on.
  Future<OemGuidance> guidance() async =>
      oemGuidanceFor(await gateway.manufacturer());
}

/// Decides whether the one-time explanation dialog may be shown, and records
/// that decision atomically so it can never be shown twice.
///
/// The "shown" flag lives in `SettingsService`, but this class only knows it
/// through [readShown] / [writeShown] so the whole decision is unit-testable
/// without `shared_preferences`.
///
/// Two guards make "exactly once" hold:
/// * [writeShown] is called *before* [claim] returns true, so the caller can
///   never show a dialog without the flag already being recorded.
/// * `_inFlight` is set synchronously, before the first `await`, so two
///   session starts in quick succession cannot both read a stale `false`
///   during the platform round-trip and stack two dialogs.
class BatteryOptimizationPrompt {
  BatteryOptimizationPrompt({
    required this.optimization,
    required this.readShown,
    required this.writeShown,
  });

  final BatteryOptimization optimization;
  final bool Function() readShown;
  final void Function(bool value) writeShown;

  bool _inFlight = false;

  /// Whether the caller should show the explanation dialog now. Returns true
  /// at most once per install, and never twice concurrently.
  Future<bool> claim() async {
    if (_inFlight) {
      return false;
    }
    _inFlight = true;
    try {
      final shouldPrompt = await optimization.shouldPrompt(
        promptShown: readShown(),
      );
      if (!shouldPrompt) {
        return false;
      }
      // Recorded before the dialog is shown, whatever the user then picks:
      // declining must not earn a second automatic prompt. The settings page
      // is the way back in.
      writeShown(true);
      return true;
    } finally {
      _inFlight = false;
    }
  }
}

/// Maps a `Build.MANUFACTURER` string to the guidance entry for that vendor.
///
/// Matching is case-insensitive and by substring, because vendors ship the
/// name in several shapes (`samsung`, `Xiaomi`, `HUAWEI`). Sub-brands that
/// report their own name (Redmi, POCO, realme) are folded into the parent
/// vendor's page where dontkillmyapp.com has no separate one (Redmi, POCO and
/// Honor have no page of their own; realme does). Anything
/// unrecognised — including stock Android — falls back to [genericGuidance].
OemGuidance oemGuidanceFor(String? manufacturer) {
  final needle = manufacturer?.trim().toLowerCase() ?? '';
  if (needle.isEmpty) {
    return genericGuidance;
  }
  for (final entry in _guidanceByAlias.entries) {
    if (needle.contains(entry.key)) {
      return entry.value;
    }
  }
  return genericGuidance;
}

/// Fallback shown for stock Android and for vendors without an entry.
const OemGuidance genericGuidance = OemGuidance(
  vendor: 'Android',
  steps: <String>[
    'Open Settings > Apps > LibreOmi > Battery.',
    'Set battery usage to "Unrestricted".',
    'If your phone has a task manager, lock or pin LibreOmi so it is not '
        'swiped away.',
  ],
  url: 'https://dontkillmyapp.com/general',
);

const OemGuidance _samsung = OemGuidance(
  vendor: 'Samsung',
  steps: <String>[
    'Open Settings > Battery > Background usage limits.',
    'Remove LibreOmi from "Sleeping apps" and "Deep sleeping apps".',
    'Add LibreOmi to "Never sleeping apps".',
  ],
  url: 'https://dontkillmyapp.com/samsung',
);

const OemGuidance _xiaomi = OemGuidance(
  vendor: 'Xiaomi (Redmi, POCO)',
  steps: <String>[
    'Open Settings > Apps > Manage apps > LibreOmi.',
    'Set "Battery saver" to "No restrictions" and enable "Autostart".',
    'In Recents, pull LibreOmi down and tap the lock icon.',
  ],
  url: 'https://dontkillmyapp.com/xiaomi',
);

const OemGuidance _huawei = OemGuidance(
  vendor: 'Huawei',
  steps: <String>[
    'Open Settings > Battery > App launch.',
    'Turn off "Manage automatically" for LibreOmi.',
    'Enable "Auto-launch", "Secondary launch" and "Run in background".',
  ],
  url: 'https://dontkillmyapp.com/huawei',
);

const OemGuidance _oneplus = OemGuidance(
  vendor: 'OnePlus',
  steps: <String>[
    'Open Settings > Battery > Battery optimization > LibreOmi.',
    'Choose "Don\'t optimize".',
    'In Settings > Battery, turn off "Advanced optimization" / '
        '"Deep optimization".',
  ],
  url: 'https://dontkillmyapp.com/oneplus',
);

const OemGuidance _oppo = OemGuidance(
  vendor: 'OPPO',
  steps: <String>[
    'Open Settings > Battery > App battery management > LibreOmi.',
    'Turn off "Sleep in background" and allow background running.',
    'Enable "Auto-start" in the Phone Manager / Security app.',
  ],
  url: 'https://dontkillmyapp.com/oppo',
);

const OemGuidance _realme = OemGuidance(
  vendor: 'realme',
  steps: <String>[
    'Open Settings > Battery > App battery management > LibreOmi.',
    'Allow "Auto-launch" and background running.',
    'In Recents, tap the lock icon on LibreOmi so it survives "clear all".',
  ],
  url: 'https://dontkillmyapp.com/realme',
);

const OemGuidance _vivo = OemGuidance(
  vendor: 'vivo',
  steps: <String>[
    'Open Settings > Battery > High background power consumption.',
    'Allow LibreOmi to run in the background.',
    'Enable "Auto-start" for LibreOmi in the iManager app.',
  ],
  url: 'https://dontkillmyapp.com/vivo',
);

const OemGuidance _google = OemGuidance(
  vendor: 'Google Pixel',
  steps: <String>[
    'Open Settings > Apps > LibreOmi > Battery.',
    'Set battery usage to "Unrestricted".',
    'Leave "Adaptive Battery" on; the exemption above is enough.',
  ],
  url: 'https://dontkillmyapp.com/google',
);

/// Alias to entry, in match order: more specific sub-brands first so a
/// "honor" device does not fall into the Huawei branch by accident.
const Map<String, OemGuidance> _guidanceByAlias = <String, OemGuidance>{
  'samsung': _samsung,
  'xiaomi': _xiaomi,
  'redmi': _xiaomi,
  'poco': _xiaomi,
  'blackshark': _xiaomi,
  'honor': _huawei,
  'huawei': _huawei,
  'oneplus': _oneplus,
  'realme': _realme,
  'oppo': _oppo,
  'vivo': _vivo,
  'google': _google,
};
