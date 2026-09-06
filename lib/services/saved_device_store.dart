/// `SettingsService`-backed [SavedDeviceStore] for `DeviceManager`.
///
/// `device/` must not depend on `services/settings_service.dart`
/// (`docs/03-architecture.md` §1 dependency rule), so the concrete store that
/// reads and writes the saved-device preferences lives here and is injected
/// into `DeviceManager`.
library;

import '../device/device_manager.dart';
import 'settings_service.dart';

class SettingsSavedDeviceStore implements SavedDeviceStore {
  const SettingsSavedDeviceStore();

  @override
  String get savedDeviceId => SettingsService.savedDeviceId;

  @override
  set savedDeviceId(String value) => SettingsService.savedDeviceId = value;

  @override
  String get savedDeviceName => SettingsService.savedDeviceName;

  @override
  set savedDeviceName(String value) => SettingsService.savedDeviceName = value;
}
