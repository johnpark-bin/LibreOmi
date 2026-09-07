import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:libreomi/main.dart';
import 'package:libreomi/services/secret_store.dart';
import 'package:libreomi/services/settings_service.dart';

/// Covers the first-launch routing decision LO-64 added to `main.dart`. The
/// decision is a pure function on purpose: `LibreOmiApp` itself builds the
/// device manager and every controller, none of which a unit-test host has.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> initSettings({required bool rationaleShown}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'permissions_rationale_shown': rationaleShown,
    });
    await SettingsService.init(secretStore: InMemorySecretStore());
  }

  test('a fresh install opens the permissions & privacy screen', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SettingsService.init(secretStore: InMemorySecretStore());

    expect(shouldShowRationale(), isTrue);
  });

  test('the screen is not shown again once the flag is set', () async {
    await initSettings(rationaleShown: true);

    expect(shouldShowRationale(), isFalse);
  });

  test('clearing the flag brings the screen back', () async {
    await initSettings(rationaleShown: false);

    expect(shouldShowRationale(), isTrue);
  });

  test('setting the flag through SettingsService is what flips it', () async {
    await initSettings(rationaleShown: false);
    expect(shouldShowRationale(), isTrue);

    SettingsService.rationaleShown = true;

    expect(shouldShowRationale(), isFalse);
  });
}
