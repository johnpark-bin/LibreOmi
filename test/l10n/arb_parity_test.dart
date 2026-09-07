import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the two ARB files against drifting apart (LO-62).
///
/// gen-l10n silently falls back to the English template for a key the Korean
/// file is missing, so a forgotten translation ships as an English string in
/// a Korean UI and nothing fails. These tests are what turns that into a red
/// build.
void main() {
  late Map<String, dynamic> en;
  late Map<String, dynamic> ko;

  setUpAll(() {
    en = _readArb('lib/l10n/app_en.arb');
    ko = _readArb('lib/l10n/app_ko.arb');
  });

  test('en and ko declare exactly the same message keys', () {
    final enKeys = _messageKeys(en);
    final koKeys = _messageKeys(ko);

    expect(
      koKeys.difference(enKeys),
      isEmpty,
      reason: 'app_ko.arb has keys app_en.arb does not declare',
    );
    expect(
      enKeys.difference(koKeys),
      isEmpty,
      reason: 'app_en.arb has keys app_ko.arb has not translated',
    );
  });

  test('every message uses the same placeholders in both files', () {
    for (final key in _messageKeys(en)) {
      expect(
        _placeholders(ko[key] as String),
        equals(_placeholders(en[key] as String)),
        reason: 'placeholders differ between en and ko for "$key"',
      );
    }
  });

  test('every English message carries a description for translators', () {
    for (final key in _messageKeys(en)) {
      final meta = en['@$key'];
      expect(
        meta,
        isA<Map<String, dynamic>>(),
        reason: '"$key" has no @$key metadata block in app_en.arb',
      );
      expect(
        (meta as Map<String, dynamic>)['description'],
        isA<String>(),
        reason: '"$key" has no description in app_en.arb',
      );
    }
  });

  test('no message is left untranslated in ko', () {
    // A Korean value identical to the English one is almost always a
    // copy-paste that was never translated. The exceptions are the language
    // names, which are written in their own language in every locale.
    const sameInBothLanguages = {
      'settings_language_english',
      'settings_language_korean',
      // The local-STT language picker's own segment labels: language names,
      // written in their own language in every locale, same as the two above.
      'settings_transcription_sttLanguageEnglish',
      'settings_transcription_sttLanguageKorean',
      // A pure `{message}: {error}` template: `message` is itself a
      // localized string supplied by the caller, and `error` is raw
      // exception text, so there is no natural-language content left to
      // translate — the colon separator is the same in both locales.
      'home_permission_errorTemplate',
      // "LLM" is an acronym left untranslated in Korean UI copy, same as
      // "BLE" or "API" (docs/08 Korean style).
      'settings_llm_header',
      // A bare `S{speaker}` speaker tag (e.g. "S1"): no natural-language
      // content to translate.
      'home_connected_speakerLabel',
    };
    for (final key in _messageKeys(en)) {
      if (sameInBothLanguages.contains(key)) continue;
      expect(
        ko[key],
        isNot(equals(en[key])),
        reason: '"$key" is identical in app_ko.arb and app_en.arb',
      );
    }
  });
}

Map<String, dynamic> _readArb(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: 'missing ARB file: $path');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

/// The translatable keys: everything that is not `@@locale` or an `@key`
/// metadata block.
Set<String> _messageKeys(Map<String, dynamic> arb) =>
    arb.keys.where((k) => !k.startsWith('@')).toSet();

/// Placeholder names used in an ICU message, e.g. `{count}`.
Set<String> _placeholders(String message) => RegExp(r'\{(\w+)\}')
    .allMatches(message)
    .map((m) => m.group(1)!)
    .toSet();
