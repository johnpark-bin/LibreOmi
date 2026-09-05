import 'package:flutter_test/flutter_test.dart';

import 'package:libreomi/platform/battery_optimization.dart';

/// Scripts the platform answers and records every call, so tests can assert
/// both "what was asked" and "what came back" without a plugin channel.
class FakeBatteryOptimizationGateway implements BatteryOptimizationGateway {
  FakeBatteryOptimizationGateway({
    this.ignoring,
    this.requestResult,
    this.manufacturerName,
  });

  final bool? ignoring;
  final bool? requestResult;
  final String? manufacturerName;

  int isIgnoringCalls = 0;
  int requestCalls = 0;

  @override
  Future<bool?> isIgnoring() async {
    isIgnoringCalls++;
    return ignoring;
  }

  @override
  Future<bool?> requestIgnore() async {
    requestCalls++;
    return requestResult;
  }

  @override
  Future<String?> manufacturer() async => manufacturerName;
}

void main() {
  group('oemGuidanceFor', () {
    test('samsung maps to the Samsung page', () {
      expect(oemGuidanceFor('samsung').url, 'https://dontkillmyapp.com/samsung');
    });

    test('matching ignores case and surrounding whitespace', () {
      expect(oemGuidanceFor('  SAMSUNG ').vendor, 'Samsung');
    });

    test('Redmi and POCO fold into the Xiaomi page', () {
      expect(oemGuidanceFor('Redmi').url, 'https://dontkillmyapp.com/xiaomi');
      expect(oemGuidanceFor('POCO').url, 'https://dontkillmyapp.com/xiaomi');
      expect(oemGuidanceFor('Xiaomi').url, 'https://dontkillmyapp.com/xiaomi');
    });

    test('HONOR folds into the Huawei page, which has no page of its own', () {
      expect(oemGuidanceFor('HONOR').url, 'https://dontkillmyapp.com/huawei');
      expect(oemGuidanceFor('HUAWEI').url, 'https://dontkillmyapp.com/huawei');
    });

    test('realme has its own page and does not fall into OPPO', () {
      expect(oemGuidanceFor('realme').url, 'https://dontkillmyapp.com/realme');
      expect(oemGuidanceFor('OPPO').url, 'https://dontkillmyapp.com/oppo');
    });

    test('OnePlus, vivo and Google map to their own pages', () {
      expect(oemGuidanceFor('OnePlus').url, 'https://dontkillmyapp.com/oneplus');
      expect(oemGuidanceFor('vivo').url, 'https://dontkillmyapp.com/vivo');
      expect(oemGuidanceFor('Google').url, 'https://dontkillmyapp.com/google');
    });

    test('an unknown vendor falls back to the generic page', () {
      expect(oemGuidanceFor('Fairphone'), same(genericGuidance));
      expect(genericGuidance.url, 'https://dontkillmyapp.com/general');
    });

    test('null and empty manufacturers fall back to the generic page', () {
      expect(oemGuidanceFor(null), same(genericGuidance));
      expect(oemGuidanceFor(''), same(genericGuidance));
      expect(oemGuidanceFor('   '), same(genericGuidance));
    });

    test('every entry has a dontkillmyapp URL and at least one step', () {
      const vendors = <String?>[
        'samsung',
        'xiaomi',
        'redmi',
        'poco',
        'honor',
        'huawei',
        'oneplus',
        'realme',
        'oppo',
        'vivo',
        'google',
        null,
      ];
      for (final vendor in vendors) {
        final guidance = oemGuidanceFor(vendor);
        expect(guidance.url, startsWith('https://dontkillmyapp.com/'),
            reason: 'vendor: $vendor');
        expect(guidance.steps, isNotEmpty, reason: 'vendor: $vendor');
        expect(guidance.vendor, isNotEmpty, reason: 'vendor: $vendor');
      }
    });
  });

  group('BatteryOptimization.shouldPrompt', () {
    test('prompts when Android is still optimising and it was never shown',
        () async {
      final gateway = FakeBatteryOptimizationGateway(ignoring: false);

      final shouldPrompt = await BatteryOptimization(gateway)
          .shouldPrompt(promptShown: false);

      expect(shouldPrompt, isTrue);
    });

    test('does not prompt once the flag has been recorded', () async {
      final gateway = FakeBatteryOptimizationGateway(ignoring: false);

      final shouldPrompt = await BatteryOptimization(gateway)
          .shouldPrompt(promptShown: true);

      expect(shouldPrompt, isFalse);
      expect(gateway.isIgnoringCalls, 0,
          reason: 'the flag alone settles it; no platform call needed');
    });

    test('does not prompt when the app is already exempt', () async {
      final gateway = FakeBatteryOptimizationGateway(ignoring: true);

      final shouldPrompt = await BatteryOptimization(gateway)
          .shouldPrompt(promptShown: false);

      expect(shouldPrompt, isFalse);
    });

    test('does not prompt off Android', () async {
      final gateway = FakeBatteryOptimizationGateway(ignoring: null);

      final shouldPrompt = await BatteryOptimization(gateway)
          .shouldPrompt(promptShown: false);

      expect(shouldPrompt, isFalse);
    });
  });

  group('BatteryOptimization.request', () {
    test('an accepted dialog reports ignoring', () async {
      final gateway = FakeBatteryOptimizationGateway(requestResult: true);

      final outcome = await BatteryOptimization(gateway).request();

      expect(outcome, BatteryOptimizationOutcome.ignoring);
      expect(gateway.requestCalls, 1);
    });

    test('a refused dialog reports denied', () async {
      final gateway = FakeBatteryOptimizationGateway(requestResult: false);

      final outcome = await BatteryOptimization(gateway).request();

      expect(outcome, BatteryOptimizationOutcome.denied);
    });

    test('off Android it reports unsupported', () async {
      final gateway = FakeBatteryOptimizationGateway(requestResult: null);

      final outcome = await BatteryOptimization(gateway).request();

      expect(outcome, BatteryOptimizationOutcome.unsupported);
    });
  });

  group('BatteryOptimization.guidance', () {
    test('resolves the guidance for the reported manufacturer', () async {
      final gateway =
          FakeBatteryOptimizationGateway(manufacturerName: 'samsung');

      final guidance = await BatteryOptimization(gateway).guidance();

      expect(guidance.vendor, 'Samsung');
    });

    test('falls back to the generic entry off Android', () async {
      final gateway = FakeBatteryOptimizationGateway(manufacturerName: null);

      final guidance = await BatteryOptimization(gateway).guidance();

      expect(guidance, same(genericGuidance));
    });
  });

  group('BatteryOptimizationPrompt.claim', () {
    /// Builds a prompt over an in-memory "shown" flag, so the test asserts
    /// the same read/write ordering `home_page.dart` relies on.
    ({BatteryOptimizationPrompt prompt, List<bool> writes}) buildPrompt({
      required bool ignoring,
      required bool alreadyShown,
    }) {
      var shown = alreadyShown;
      final writes = <bool>[];
      return (
        prompt: BatteryOptimizationPrompt(
          optimization: BatteryOptimization(
            FakeBatteryOptimizationGateway(ignoring: ignoring),
          ),
          readShown: () => shown,
          writeShown: (value) {
            shown = value;
            writes.add(value);
          },
        ),
        writes: writes,
      );
    }

    test('claims once and records the flag before returning true', () async {
      final built = buildPrompt(ignoring: false, alreadyShown: false);

      final claimed = await built.prompt.claim();

      expect(claimed, isTrue);
      expect(built.writes, [true],
          reason: 'the flag must be written before the dialog is shown');
    });

    test('a second claim after the first is refused', () async {
      final built = buildPrompt(ignoring: false, alreadyShown: false);

      expect(await built.prompt.claim(), isTrue);
      expect(await built.prompt.claim(), isFalse);
      expect(built.writes, [true]);
    });

    test('two concurrent claims only let one through', () async {
      final built = buildPrompt(ignoring: false, alreadyShown: false);

      // Both start before either has finished its platform round-trip: this
      // is the double-tap on "Start listening" that used to stack dialogs.
      final results = await Future.wait(<Future<bool>>[
        built.prompt.claim(),
        built.prompt.claim(),
      ]);

      expect(results.where((claimed) => claimed).length, 1);
      expect(built.writes, [true]);
    });

    test('never claims when the flag was already recorded', () async {
      final built = buildPrompt(ignoring: false, alreadyShown: true);

      expect(await built.prompt.claim(), isFalse);
      expect(built.writes, isEmpty);
    });

    test('never claims when the app is already exempt', () async {
      final built = buildPrompt(ignoring: true, alreadyShown: false);

      expect(await built.prompt.claim(), isFalse);
      expect(built.writes, isEmpty,
          reason: 'an exempt app has nothing to be prompted about');
    });
  });

  group('BatteryOptimization.isIgnoring', () {
    test('forwards the gateway answer, including null off Android', () async {
      expect(
        await BatteryOptimization(
          FakeBatteryOptimizationGateway(ignoring: true),
        ).isIgnoring(),
        isTrue,
      );
      expect(
        await BatteryOptimization(
          FakeBatteryOptimizationGateway(ignoring: null),
        ).isIgnoring(),
        isNull,
      );
    });
  });
}
