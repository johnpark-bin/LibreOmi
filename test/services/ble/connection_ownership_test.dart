import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/services/ble/connection_ownership.dart';

void main() {
  group('teardownActionFor', () {
    test('resets the service when the failed attempt still owns it', () {
      expect(
        teardownActionFor(serviceOwnerId: 'AA:BB', failedDeviceId: 'AA:BB'),
        TeardownAction.resetService,
      );
    });

    test('resets the service when nobody owns it', () {
      // A connect that threw before claiming the service: the state is still
      // `connecting` and no connection-state listener exists, so skipping the
      // reset here would strand the app in `connecting` forever.
      expect(
        teardownActionFor(serviceOwnerId: null, failedDeviceId: 'AA:BB'),
        TeardownAction.resetService,
      );
    });

    test('releases only its own link when another device owns the service', () {
      expect(
        teardownActionFor(serviceOwnerId: 'CC:DD', failedDeviceId: 'AA:BB'),
        TeardownAction.releaseLinkOnly,
      );
    });
  });
}
