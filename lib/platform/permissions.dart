/// Pure-Dart runtime permission model, importable from `flutter test` without
/// touching any plugin channel. See `docs/04-android-platform-notes.md` §3
/// for the permission matrix this facade implements.
library;

/// A permission the app may need to request at runtime.
enum AppPermission {
  bluetoothScan,
  bluetoothConnect,
  fineLocation,
  notification,
  microphone,
}

/// The result of requesting one permission.
enum PermissionOutcome {
  granted,
  denied,
  permanentlyDenied,
}

/// The platform surface [AppPermissions] needs. Implemented for real by
/// `PluginPermissionGateway` (see `lib/platform/permission_gateway.dart`) and
/// faked in tests so this file never has to import a plugin.
abstract class PermissionGateway {
  /// The Android API level, or `null` when not running on Android.
  Future<int?> androidSdkInt();

  /// Requests the given permissions and reports an outcome for each.
  Future<Map<AppPermission, PermissionOutcome>> request(
    List<AppPermission> permissions,
  );

  /// Reports the current outcome of each permission **without requesting
  /// anything**. Used by the permissions rationale screen, which only ever
  /// displays state (LO-64); requesting stays with the point-of-use flows.
  Future<Map<AppPermission, PermissionOutcome>> statuses(
    List<AppPermission> permissions,
  );

  /// Opens the app's system settings page, e.g. to let the user grant a
  /// permission they previously denied permanently. Returns whether the
  /// settings page could be opened.
  Future<bool> openSettings();
}

/// The facade the app calls to request runtime permissions.
///
/// This models Android's runtime-permission system only. On iOS, permission
/// prompts are triggered by the plugins that need them (e.g. `record` asks
/// for microphone access the first time it is used), so every method here
/// returns [PermissionOutcome.granted] without requesting anything when
/// [PermissionGateway.androidSdkInt] reports `null` (i.e. not on Android).
class AppPermissions {
  AppPermissions(this.gateway);

  final PermissionGateway gateway;

  /// Requests `POST_NOTIFICATIONS`. Only required from API 33 (Android 13)
  /// onward; on older Android (and on iOS) this is a no-op that returns
  /// granted.
  Future<PermissionOutcome> ensureNotifications() async {
    final sdkInt = await gateway.androidSdkInt();
    if (sdkInt == null || sdkInt < 33) {
      return PermissionOutcome.granted;
    }
    return _requestAndAggregate(<AppPermission>[AppPermission.notification]);
  }

  /// Requests the permissions BLE scanning needs. On API 31+ that is
  /// `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT`; on API 30 and below it is
  /// `ACCESS_FINE_LOCATION` instead. Never requests both sets.
  Future<PermissionOutcome> ensureBleScan() async {
    final sdkInt = await gateway.androidSdkInt();
    if (sdkInt == null) {
      return PermissionOutcome.granted;
    }
    final permissions = sdkInt >= 31
        ? <AppPermission>[
            AppPermission.bluetoothScan,
            AppPermission.bluetoothConnect,
          ]
        : <AppPermission>[AppPermission.fineLocation];
    return _requestAndAggregate(permissions);
  }

  /// Requests `RECORD_AUDIO` on Android, at any API level.
  Future<PermissionOutcome> ensureMicrophone() async {
    final sdkInt = await gateway.androidSdkInt();
    if (sdkInt == null) {
      return PermissionOutcome.granted;
    }
    return _requestAndAggregate(<AppPermission>[AppPermission.microphone]);
  }

  /// The current outcome of each permission the app can request at runtime,
  /// as the platform sees it right now. Requests nothing, so it is safe to
  /// call from `build`-time state loading.
  ///
  /// On a platform without runtime permissions (iOS, and the unit-test host)
  /// [PermissionGateway.androidSdkInt] reports `null` and every permission is
  /// reported as [PermissionOutcome.granted], matching what the `ensure*`
  /// methods do there.
  Future<Map<AppPermission, PermissionOutcome>> currentStatuses(
    List<AppPermission> permissions,
  ) async {
    if (permissions.isEmpty) {
      return <AppPermission, PermissionOutcome>{};
    }
    final sdkInt = await gateway.androidSdkInt();
    if (sdkInt == null) {
      return <AppPermission, PermissionOutcome>{
        for (final permission in permissions) permission:
            PermissionOutcome.granted,
      };
    }
    final results = await gateway.statuses(permissions);
    return <AppPermission, PermissionOutcome>{
      for (final permission in permissions) permission:
          results[permission] ?? PermissionOutcome.denied,
    };
  }

  /// Opens the app's system settings page.
  Future<bool> openAppSettings() => gateway.openSettings();

  Future<PermissionOutcome> _requestAndAggregate(
    List<AppPermission> permissions,
  ) async {
    final results = await gateway.request(permissions);
    return _aggregate(permissions, results);
  }

  /// Combines the per-permission outcomes of a multi-permission request into
  /// one: any [PermissionOutcome.permanentlyDenied] wins, otherwise any
  /// [PermissionOutcome.denied] wins, otherwise it's
  /// [PermissionOutcome.granted]. A missing entry counts as denied.
  PermissionOutcome _aggregate(
    List<AppPermission> permissions,
    Map<AppPermission, PermissionOutcome> results,
  ) {
    final outcomes = permissions
        .map((p) => results[p] ?? PermissionOutcome.denied)
        .toList(growable: false);
    if (outcomes.contains(PermissionOutcome.permanentlyDenied)) {
      return PermissionOutcome.permanentlyDenied;
    }
    if (outcomes.contains(PermissionOutcome.denied)) {
      return PermissionOutcome.denied;
    }
    return PermissionOutcome.granted;
  }
}
