import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../services/settings_service.dart';
import 'l10n.dart';

/// Holds the app's display-language preference and rebuilds `MaterialApp`
/// when it changes (LO-62).
///
/// [appLocale] is `null` for "follow system", which is the default and what
/// the roadmap's acceptance criterion asks for; a non-null value is the
/// user's manual override and is persisted through
/// [SettingsService.appLocaleTag].
class LocaleController extends ChangeNotifier {
  LocaleController() : _appLocale = _read();

  Locale? _appLocale;

  /// The user's manual choice, or `null` to follow the system language.
  Locale? get appLocale => _appLocale;

  set appLocale(Locale? value) {
    final normalised = value == null ? null : L10n.resolve(value);
    if (normalised?.languageCode == _appLocale?.languageCode) return;
    _appLocale = normalised;
    _persist(normalised);
    notifyListeners();
  }

  /// Writes the preference through, tolerating an uninitialised or broken
  /// settings store: failing to persist the choice must not stop the UI from
  /// switching language for this session.
  static void _persist(Locale? locale) {
    try {
      SettingsService.appLocaleTag = locale?.languageCode;
    } catch (e) {
      debugPrint('LocaleController: could not persist the language choice: $e');
    }
  }

  /// Reads the stored preference, tolerating an uninitialised settings store
  /// so a widget test can build the app without `SettingsService.init()`.
  static Locale? _read() {
    try {
      final tag = SettingsService.appLocaleTag;
      return tag == null ? null : L10n.resolve(Locale(tag));
    } catch (_) {
      return null;
    }
  }
}
