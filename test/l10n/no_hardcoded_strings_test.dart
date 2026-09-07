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
          final text = literal.group(1)!;
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

/// Single-quoted Dart string literals, ignoring any that contain an escape or
/// an interpolation — those are matched imprecisely by a regex, and an
/// interpolated string that reaches the user is caught by the reviewer
/// instead.
final RegExp _literals = RegExp(r"'([^'\$\\\n]{4,})'");

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

/// English prose heuristic: starts with a capital letter, and is either
/// several words or a single capitalised word long enough to be a label.
bool _looksLikeProse(String text) {
  if (!RegExp(r'^[A-Z]').hasMatch(text)) return false;
  // Identifiers and constants: `CONNECTED`, `snake_case`, `some.path`,
  // `Some/Path`, `A-B-C`.
  if (RegExp(r'^[A-Z0-9_]+$').hasMatch(text)) return false;
  if (RegExp(r'[_/.]').hasMatch(text)) return false;
  return RegExp(r'^[A-Za-z][A-Za-z0-9 ,;:!?()%&+\x27-]*$').hasMatch(text);
}

bool _isAllowed(String text) => _allowedLiterals.contains(text);

/// Literals that are not prose a reader parses, so they stay in the source.
///
/// Keep this list short and each entry justified — it is the only escape
/// hatch, and a long one would defeat the check.
const Set<String> _allowedLiterals = <String>{
  // Product and vendor names.
  'LibreOmi',
  'LibreOmi Backup',
  'Deepgram',
  'Nova-2',
  'Nova-3',
  'English',
};

Iterable<File> _pageFiles() => Directory('lib/pages')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

String _relative(File file) => file.path.replaceFirst('${Directory.current.path}/', '');
