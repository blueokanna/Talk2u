import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// User-visible text belongs in `lib/l10n/*.arb`, so no Dart file outside the
/// dedicated data modules may contain Chinese text.
///
/// Two directories are exempt by design and are the only place where non-English
/// data is allowed:
/// - `lib/src/lexicon` holds language resources matched against user speech and
///   replies (emotion cues, animation cues, voice names).
/// - `lib/src/prompts` holds model-facing prompt templates.
/// Generated code is exempt as well: `lib/src/rust` mirrors Rust doc comments and
/// `lib/l10n/generated` is produced from the ARB files.
const _dataRoots = <String>['lib/src/lexicon/', 'lib/src/prompts/'];
const _generatedRoots = <String>['lib/src/rust/', 'lib/l10n/generated/'];

final _cjk = RegExp(r'[\u4e00-\u9fff]');

void main() {
  test('no hardcoded CJK outside the language-data modules', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll('\\', '/');
      if (_dataRoots.any(path.startsWith) ||
          _generatedRoots.any(path.startsWith)) {
        continue;
      }
      final lines = entity.readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        if (lines[index].trimLeft().startsWith('//')) continue;
        if (_cjk.hasMatch(lines[index])) offenders.add('$path:${index + 1}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Move user-visible text into the ARB files and language data into '
          'lib/src/lexicon.',
    );
  });

  test('every ARB translation exists in both languages', () {
    final en = _arbKeys('lib/l10n/app_en.arb');
    final zh = _arbKeys('lib/l10n/app_zh.arb');
    expect(
      en.difference(zh),
      isEmpty,
      reason: 'These keys are missing from app_zh.arb',
    );
    expect(
      zh.difference(en),
      isEmpty,
      reason: 'These keys are missing from app_en.arb',
    );
  });
}

Set<String> _arbKeys(String path) {
  final source = File(path).readAsStringSync();
  return RegExp(
    r'^\s*"([^"@]+)":',
    multiLine: true,
  ).allMatches(source).map((match) => match.group(1)!).toSet();
}
