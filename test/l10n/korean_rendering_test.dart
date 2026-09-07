import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreomi/l10n/l10n.dart';
import 'package:libreomi/l10n/locale_controller.dart';
import 'package:libreomi/pages/battery_guidance_page.dart';
import 'package:libreomi/platform/battery_optimization.dart';
import 'package:provider/provider.dart';

import '../support/localized_app.dart';

/// End-to-end checks that the Korean translation actually reaches the screen
/// and the context-free call sites (LO-62).
///
/// The ARB parity test proves the two files agree; these prove the wiring
/// between a locale and a rendered string, which is the part that would still
/// be broken if a delegate or the resolution callback were dropped.
void main() {
  testWidgets('a page renders Korean copy under a ko locale', (tester) async {
    await tester.pumpWidget(
      LocalizedApp(
        locale: const Locale('ko'),
        home: BatteryGuidancePage(
          batteryOptimizationOverride: BatteryOptimization(_StubGateway()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('ko'));
    expect(find.text(l10n.batteryGuidance_title), findsOneWidget);
    // The same page under English must not show the Korean title, which is
    // what makes the assertion above about the locale rather than about the
    // string happening to exist.
    expect(
      find.text(lookupAppLocalizations(const Locale('en')).batteryGuidance_title),
      findsNothing,
    );
  });

  testWidgets('L10n.current follows the locale the UI resolved to', (
    tester,
  ) async {
    // What the notification service and the controllers read: they have no
    // BuildContext, so they depend on `MaterialApp.localeResolutionCallback`
    // having recorded the rendered locale.
    await tester.pumpWidget(
      const LocalizedApp(
        locale: Locale('ko'),
        home: _TitleProbe(),
      ),
    );
    await tester.pumpAndSettle();

    expect(L10n.locale.languageCode, 'ko');
    expect(
      L10n.current.notification_taskDueBody,
      lookupAppLocalizations(const Locale('ko')).notification_taskDueBody,
    );

    // Switch through the controller, the way the settings page does, so the
    // static follows a real language change rather than a fresh app.
    tester
        .element(find.byType(_TitleProbe))
        .read<LocaleController>()
        .appLocale = const Locale('en');
    await tester.pumpAndSettle();

    expect(L10n.locale.languageCode, 'en');
    expect(
      L10n.current.notification_taskDueBody,
      lookupAppLocalizations(const Locale('en')).notification_taskDueBody,
    );
  });

  testWidgets('switching the language setting re-renders without a restart', (
    tester,
  ) async {
    await tester.pumpWidget(
      const LocalizedApp(home: _TitleProbe()),
    );
    await tester.pumpAndSettle();

    final en = lookupAppLocalizations(const Locale('en'));
    final ko = lookupAppLocalizations(const Locale('ko'));
    expect(find.text(en.settings_title), findsOneWidget);

    // Exactly what the settings page's language radio does.
    final controller = tester
        .element(find.byType(_TitleProbe))
        .read<LocaleController>();
    controller.appLocale = const Locale('ko');
    await tester.pumpAndSettle();

    expect(find.text(ko.settings_title), findsOneWidget);
    expect(find.text(en.settings_title), findsNothing);
  });

  test('an unsupported locale resolves to English rather than throwing', () {
    // `lookupAppLocalizations` throws on a locale it does not know, so
    // `L10n.resolve` is what stands between a phone set to, say, Japanese and
    // a crash on the first frame.
    expect(L10n.resolve(const Locale('ja')).languageCode, 'en');
    expect(L10n.resolve(null).languageCode, 'en');
    // A country variant still finds its language.
    expect(L10n.resolve(const Locale('ko', 'KR')).languageCode, 'ko');
  });
}

/// Renders one localised string, so the test can watch it change language.
class _TitleProbe extends StatelessWidget {
  const _TitleProbe();

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Text(L10n.of(context).settings_title));
}

/// Reports a device that is not exempt, which is the branch that renders the
/// page's guidance text rather than a spinner or an error.
class _StubGateway implements BatteryOptimizationGateway {
  @override
  Future<bool?> isIgnoring() async => false;

  @override
  Future<bool?> requestIgnore() async => false;

  @override
  Future<String?> manufacturer() async => 'samsung';
}
