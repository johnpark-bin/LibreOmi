import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import 'battery_optimization.dart';

/// The real [BatteryOptimizationGateway], backed by `permission_handler` and
/// `device_info_plus`.
///
/// Like `permission_gateway.dart`, this file is allowed to branch on
/// `Platform.isAndroid` (see `AGENTS.md`): battery optimisation is an Android
/// concept, so the split is contained here and the rest of the app talks to
/// the pure-Dart facade instead.
class PluginBatteryOptimizationGateway implements BatteryOptimizationGateway {
  String? _cachedManufacturer;

  @override
  Future<bool?> isIgnoring() async {
    if (!Platform.isAndroid) {
      return null;
    }
    return ph.Permission.ignoreBatteryOptimizations.isGranted;
  }

  @override
  Future<bool?> requestIgnore() async {
    if (!Platform.isAndroid) {
      return null;
    }
    // `permission_handler` maps this "permission" onto the
    // REQUEST_IGNORE_BATTERY_OPTIMIZATIONS intent, so requesting it shows the
    // system exemption dialog rather than a runtime permission prompt.
    final status = await ph.Permission.ignoreBatteryOptimizations.request();
    return status.isGranted;
  }

  @override
  Future<String?> manufacturer() async {
    if (!Platform.isAndroid) {
      return null;
    }
    final cached = _cachedManufacturer;
    if (cached != null) {
      return cached;
    }
    final info = await DeviceInfoPlugin().androidInfo;
    final manufacturer = info.manufacturer;
    _cachedManufacturer = manufacturer;
    return manufacturer;
  }
}

/// App-wide [BatteryOptimization] backed by the real plugins. The gateway
/// caches `Build.MANUFACTURER` per instance, so sharing one instance keeps
/// the `device_info_plus` lookup to a single call per process.
final BatteryOptimization batteryOptimization = BatteryOptimization(
  PluginBatteryOptimizationGateway(),
);
