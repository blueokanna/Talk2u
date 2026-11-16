import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/services/moss_tts_service.dart';
import 'package:talk2u/src/widgets/settings/on_device_models_section.dart';

final _cjk = RegExp(r'[\u4e00-\u9fff]');

void main() {
  test('every MOSS stage is localized and English stays Latin', () async {
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    final zh = await AppLocalizations.delegate.load(const Locale('zh'));
    for (final operation in MossOperation.values) {
      final english = mossOperationText(en, operation);
      final chinese = mossOperationText(zh, operation);
      if (operation == MossOperation.idle) {
        expect(english, isEmpty);
        expect(chinese, isEmpty);
        continue;
      }
      expect(
        english,
        isNotEmpty,
        reason: 'missing English text for $operation',
      );
      expect(
        _cjk.hasMatch(english),
        isFalse,
        reason: 'English status for $operation leaked CJK: $english',
      );
      expect(
        chinese,
        isNotEmpty,
        reason: 'missing Chinese text for $operation',
      );
    }
  });
}
