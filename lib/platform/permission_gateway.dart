import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import 'permissions.dart';

/// The real [PermissionGateway], backed by `permission_handler` and
/// `device_info_plus`.
///
/// Like `battery_optimization_gateway.dart` and `background_runner_factory.dart`,
/// this file is allowed to branch on `Platform.isAndroid` (see `AGENTS.md`):
/// the platform split lives in `platform/` so `device/`, `audio/`,
/// `transcription/` and `intelligence/` never need it.
class PluginPermissionGateway implements PermissionGateway {
  int? _cachedSdkInt;

  @override
  Future<int?> androidSdkInt() async {
    if (!Platform.isAndroid) {
      return null;
    }
    final cached = _cachedSdkInt;
    if (cached != null) {
      return cached;
    }
    final info = await DeviceInfoPlugin().androidInfo;
    final sdkInt = info.version.sdkInt;
    _cachedSdkInt = sdkInt;
    return sdkInt;
  }

  @override
  Future<Map<AppPermission, PermissionOutcome>> request(
    List<AppPermission> permissions,
  ) async {
    if (permissions.isEmpty) {
      return <AppPermission, PermissionOutcome>{};
    }
    final pluginPermissions = <ph.Permission, AppPermission>{
      for (final permission in permissions) _toPlugin(permission): permission,
    };
    final statuses = await pluginPermissions.keys.toList().request();
    return <AppPermission, PermissionOutcome>{
      for (final entry in statuses.entries)
        pluginPermissions[entry.key]!: _toOutcome(entry.value),
    };
  }

  @override
  Future<bool> openSettings() => ph.openAppSettings();

  ph.Permission _toPlugin(AppPermission permission) {
    switch (permission) {
      case AppPermission.bluetoothScan:
        return ph.Permission.bluetoothScan;
      case AppPermission.bluetoothConnect:
        return ph.Permission.bluetoothConnect;
      case AppPermission.fineLocation:
        // ACCESS_FINE_LOCATION on Android; `locationWhenInUse` and
        // `location` resolve to the same manifest permissions on this
        // platform, but `locationWhenInUse` best matches the foreground-only
        // BLE scan use case (no background/"always" location is requested).
        return ph.Permission.locationWhenInUse;
      case AppPermission.notification:
        return ph.Permission.notification;
      case AppPermission.microphone:
        return ph.Permission.microphone;
    }
  }

  PermissionOutcome _toOutcome(ph.PermissionStatus status) {
    switch (status) {
      case ph.PermissionStatus.granted:
      case ph.PermissionStatus.limited:
      case ph.PermissionStatus.provisional:
        return PermissionOutcome.granted;
      case ph.PermissionStatus.permanentlyDenied:
      case ph.PermissionStatus.restricted:
        return PermissionOutcome.permanentlyDenied;
      case ph.PermissionStatus.denied:
        return PermissionOutcome.denied;
    }
  }
}

/// App-wide [AppPermissions] backed by the real plugins. The gateway caches
/// the Android API level per instance, so sharing one instance keeps the
/// `device_info_plus` lookup to a single call per process.
final AppPermissions appPermissions = AppPermissions(PluginPermissionGateway());
