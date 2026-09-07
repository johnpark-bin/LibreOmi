import 'package:flutter/material.dart';
import 'package:libreomi/l10n/l10n.dart';
import 'package:libreomi/l10n/locale_controller.dart';
import 'package:provider/provider.dart';

/// The `MaterialApp` page tests wrap a page in (LO-62).
///
/// Mirrors the localisation wiring `lib/main.dart` does: the delegates, the
/// supported locales, a [LocaleController] for the language picker, and the
/// `localeResolutionCallback` that keeps `L10n.current` in step with what is
/// on screen. Pages read their strings through `L10n.of(context)`, which
/// throws without those delegates, so a bare `MaterialApp` is no longer
/// enough to host one.
class LocalizedApp extends StatefulWidget {
  const LocalizedApp({
    super.key,
    required this.home,
    this.locale = const Locale('en'),
    this.routes = const <String, WidgetBuilder>{},
  });

  final Widget home;

  /// The locale to render in. Tests that assert on English copy leave this
  /// at the default; the Korean rendering tests pass `Locale('ko')`.
  final Locale locale;

  final Map<String, WidgetBuilder> routes;

  @override
  State<LocalizedApp> createState() => _LocalizedAppState();
}

class _LocalizedAppState extends State<LocalizedApp> {
  late final LocaleController _controller = LocaleController()
    ..appLocale = widget.locale;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<LocaleController>.value(
      value: _controller,
      child: Consumer<LocaleController>(
        builder: (context, locale, _) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale.appLocale,
          localeResolutionCallback: (candidate, supported) {
            final resolved = L10n.resolve(candidate);
            L10n.locale = resolved;
            return resolved;
          },
          routes: widget.routes,
          home: widget.home,
        ),
      ),
    );
  }
}
