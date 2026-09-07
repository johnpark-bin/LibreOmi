import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Fails when a page grows a user-visible English literal instead of an ARB
/// key (LO-62).
///
/// Dart has no lint for this — `flutter analyze` is happy with
/// `Text('Save')` — so a grep with an explicit allow list is what keeps the
/// Korean UI from quietly regrowing English text one PR at a time. It is
/// deliberately dumb: it reads `lib/pages/**` line by line and flags any
/// single-quoted literal that looks like an English sentence or label.
///
/// When it fails, the fix is almost always to add the string to
/// `lib/l10n/app_en.arb` and `app_ko.arb`. Add to [_allowedLiterals] only for
/// a string a person never reads as prose: a proper noun, an identifier, a
/// unit symbol, a route or asset path.
void main() {
  test('no user-visible English literals are left in lib/pages', () {
    final offenders = <String>[];

    for (final file in _pageFiles()) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (_isExempt(line)) continue;
        for (final literal in _literals.allMatches(line)) {
          final text = literal.group(1) ?? literal.group(2)!;
          if (_isAllowed(text)) continue;
          if (!_looksLikeProse(text)) continue;
          offenders.add(
            '${_relative(file)}:${i + 1}  "$text"',
          );
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These look like user-visible English strings that should come from '
          'lib/l10n/app_en.arb:\n  ${offenders.join('\n  ')}',
    );
  });

  test('the allow list has no entry that no longer appears in lib/pages', () {
    final source = _pageFiles().map((f) => f.readAsStringSync()).join('\n');
    final stale = _allowedLiterals.where((s) => !source.contains(s)).toList();

    expect(
      stale,
      isEmpty,
      reason:
          'These allow-list entries are gone from lib/pages and should be '
          'deleted so the list stays a short, reviewable exception list:\n'
          '  ${stale.join('\n  ')}',
    );
  });
}

/// Dart string literals in either quote style. Escapes are skipped (a regex
/// reads them unreliably); interpolations are not — `'Failed to save $name'`
/// is exactly the kind of string that must not stay in the source, so `$` is
/// allowed inside and stripped before the prose test below.
final RegExp _literals = RegExp(r''''([^'\\\n]{4,})'|"([^"\\\n]{4,})"''');

/// Lines that never carry user-visible copy.
bool _isExempt(String line) {
  final trimmed = line.trimLeft();
  return trimmed.startsWith('//') ||
      trimmed.startsWith('///') ||
      trimmed.startsWith('*') ||
      trimmed.startsWith('import ') ||
      trimmed.startsWith('export ') ||
      // The ARB is reached through `l10n.<key>`, so a line that already does
      // is not hiding a literal; and a `debugPrint` argument is a log line.
      trimmed.startsWith('debugPrint(');
}

/// English prose heuristic: starts with a capital letter and reads as words
/// rather than as an identifier.
///
/// Deliberately does **not** reject a literal just because it contains a full
/// stop — most user-visible copy is a sentence, and rejecting on `.` would
/// blind the check to exactly the strings it exists to catch. Paths and
/// identifiers are excluded by their shape instead: they have no space.
bool _looksLikeProse(String text) {
  // `$name` and `${expr}` are placeholders, not prose; drop them and judge
  // the words around them.
  final prose = text.replaceAll(RegExp(r'\$\{[^}]*\}|\$\w+'), ' ').trim();
  if (!RegExp(r'^[A-Z]').hasMatch(prose)) return false;
  // Constants and identifiers: `CONNECTED`, `Some_Thing`.
  if (RegExp(r'^[A-Z0-9_]+$').hasMatch(prose)) return false;
  if (prose.contains('_')) return false;
  // A single word with no space is a label, a path segment, a MIME type or a
  // proper noun; only multi-word text is treated as prose, and single-word
  // UI labels are caught by review rather than by this heuristic.
  if (!prose.contains(' ')) return false;
  // A path, a URL or a package id: slashes, or a dot with no space after it.
  if (prose.contains('/')) return false;
  if (RegExp(r'\.\w').hasMatch(prose)) return false;
  // Raw string on purpose, so the apostrophes and the ellipsis are the
  // characters themselves; `\u2019` would be four literal characters here.
  return RegExp(
    "^[A-Za-z][A-Za-z0-9 ,.;:!?()%&+'\u2019\u2026-]*\$",
  ).hasMatch(prose);
}

bool _isAllowed(String text) => _allowedLiterals.contains(text);

/// Literals that are not prose a reader parses, so they stay in the source.
///
/// Keep this list short and each entry justified — it is the only escape
/// hatch, and a long one would defeat the check.
const Set<String> _allowedLiterals = <String>{
  // The share-sheet subject: a product name, and the only multi-word literal
  // in `lib/pages` that is not prose. Single-word product names (LibreOmi,
  // Deepgram, Nova-2) need no entry — the heuristic already treats a literal
  // with no space as a label rather than as a sentence.
  'LibreOmi Backup',
};

Iterable<File> _pageFiles() => Directory('lib/pages')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

String _relative(File file) => file.path.replaceFirst('${Directory.current.path}/', '');
