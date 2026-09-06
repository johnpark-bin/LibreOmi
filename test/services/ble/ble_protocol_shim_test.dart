import 'package:flutter_test/flutter_test.dart';
// Deliberately imports the deprecated path, not device/omi_gatt.dart: this
// test exists only to prove the re-export shim still resolves for callers
// that have not been repointed yet. It is deleted together with the shim in
// LO-31.
import 'package:libreomi/services/ble/ble_protocol.dart';

void main() {
  test('ble_protocol.dart re-exports the omi_gatt symbols', () {
    expect(codecFromId(20), BleAudioCodec.opus);
    expect(normalizeUuid('180f'), '0000180f-0000-1000-8000-00805f9b34fb');
    expect(isMtuSufficient(minimumUsableMtu), isTrue);
    expect(parseButtonEvent(const [2, 0, 0, 0]), ButtonEvent.doubleTap);
  });
}
