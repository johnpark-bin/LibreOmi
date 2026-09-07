import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/pages/battery_guidance_page.dart';
import 'package:libreomi/platform/battery_optimization.dart';

import '../support/localized_app.dart';

/// Scripts `Build.MANUFACTURER` so the page's real async resolve path runs
/// without a plugin channel. [failing] makes the lookup throw, which is the
/// case that used to leave the page spinning forever.
class _FakeGateway implements BatteryOptimizationGateway {
  _FakeGateway({this.manufacturerName, this.failing = false});

  final String? manufacturerName;
  final bool failing;

  @override
  Future<bool?> isIgnoring() async => false;

  @override
  Future<bool?> requestIgnore() async => false;

  @override
  Future<String?> manufacturer() async {
    if (failing) {
      throw StateError('device_info_plus unavailable');
    }
    return manufacturerName;
  }
}

void main() {
  const guidance = OemGuidance(
    vendor: 'Samsung',
    steps: <String>[
      'Open Settings > Battery > Background usage limits.',
      'Remove LibreOmi from "Sleeping apps" and "Deep sleeping apps".',
      'Add LibreOmi to "Never sleeping apps".',
    ],
    url: 'https://dontkillmyapp.com/samsung',
  );

  /// Pumps the page over a scripted manufacturer and settles the resolve.
  Future<void> pumpPage(
    WidgetTester tester, {
    String? manufacturerName,
    bool failing = false,
  }) async {
    await tester.pumpWidget(
      LocalizedApp(
        home: BatteryGuidancePage(
          batteryOptimizationOverride: BatteryOptimization(
            _FakeGateway(
              manufacturerName: manufacturerName,
              failing: failing,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders vendor name, steps, and url for supplied guidance', (
    tester,
  ) async {
    await pumpPage(tester, manufacturerName: 'samsung');

    expect(find.text('Samsung'), findsOneWidget);
    for (final step in guidance.steps) {
      expect(find.text(step), findsOneWidget);
    }
    expect(find.text(guidance.url), findsOneWidget);
  });

  testWidgets('tapping Copy link copies the url and shows confirmation', (
    tester,
  ) async {
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await pumpPage(tester, manufacturerName: 'samsung');

    await tester.tap(find.text('Copy link'));
    await tester.pump();

    expect(copiedText, guidance.url);
    expect(find.text('Link copied to clipboard'), findsOneWidget);
  });

  testWidgets('an unrecognised vendor renders genericGuidance', (tester) async {
    await pumpPage(tester, manufacturerName: 'Fairphone');

    expect(find.text(genericGuidance.vendor), findsOneWidget);
    for (final step in genericGuidance.steps) {
      expect(find.text(step), findsOneWidget);
    }
    expect(find.text(genericGuidance.url), findsOneWidget);
  });

  testWidgets('shows a spinner until the manufacturer lookup resolves', (
    tester,
  ) async {
    await tester.pumpWidget(
      LocalizedApp(
        home: BatteryGuidancePage(
          batteryOptimizationOverride: BatteryOptimization(
            _FakeGateway(manufacturerName: 'samsung'),
          ),
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Samsung'), findsOneWidget);
  });

  testWidgets('a failed lookup falls back to genericGuidance, not a spinner', (
    tester,
  ) async {
    await pumpPage(tester, failing: true);

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text(genericGuidance.vendor), findsOneWidget);
    expect(find.text(genericGuidance.url), findsOneWidget);
  });
}
