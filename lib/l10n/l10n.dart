import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

export 'app_localizations.dart' show AppLocalizations, lookupAppLocalizations;

/// Access to the app's translations, both inside and outside the widget tree.
///
/// Pages use [of], which is `AppLocalizations.of(context)` under a shorter
/// name. Code that has no `BuildContext` — the notification service, the
/// controllers' user-facing error strings, anything running from a
/// foreground-service or BLE-button callback — uses [current], which reads
/// the locale [locale] was last set to.
///
/// [locale] is written from `MaterialApp.localeResolutionCallback`, so it
/// always holds the locale the UI is actually rendering in: the user's manual
/// choice when there is one, the resolved system locale otherwise. Passing a
/// `BuildContext` down into `session/` and `platform/` instead would change
/// signatures far outside this issue's scope, and those call sites often run
/// with no attached element at all.
class L10n {
  L10n._();

  static Locale _locale = const Locale('en');

  /// The locale the UI is currently rendering in. Never unsupported: writes
  /// go through [resolve].
  static Locale get locale => _locale;

  static set locale(Locale value) => _locale = resolve(value);

  /// Translations for [locale]. Safe to call before the first frame: the
  /// default is the English template.
  static AppLocalizations get current => lookupAppLocalizations(_locale);

  /// Translations for [context]'s locale.
  static AppLocalizations of(BuildContext context) =>
      AppLocalizations.of(context);

  /// The supported locale that best matches [candidate], falling back to
  /// English.
  ///
  /// Matches on language code only: `ko_KR` and a bare `ko` both resolve to
  /// the Korean translation, and [lookupAppLocalizations] — which throws on
  /// an unsupported locale — is therefore only ever handed a locale it knows.
  static Locale resolve(Locale? candidate) {
    if (candidate != null) {
      for (final supported in AppLocalizations.supportedLocales) {
        if (supported.languageCode == candidate.languageCode) return supported;
      }
    }
    return const Locale('en');
  }
}
