import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/l10n/service_error_text.dart';

final _cjk = RegExp(r'[\u4e00-\u9fff]');

void main() {
  test('known service codes are localized without CJK in English', () async {
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    final zh = await AppLocalizations.delegate.load(const Locale('zh'));
    for (final code in [
      'qwen3_capabilities_failed',
      'qwen3_download_failed',
      'qwen3_download_cancelled',
      'qwen3_load_failed',
      'qwen3_generate_failed',
      'moss_runtime_unavailable',
      'moss_initialization_failed',
      'moss_model_missing',
      'moss_synthesis_failed',
      'moss_import_failed',
      'moss_import_busy',
      'moss_cancelled',
      'moss_delete_failed',
      'sensevoice_capabilities_failed',
      'sensevoice_recognition_failed',
      'sensevoice_download_failed',
      'sensevoice_recording_failed',
      'sherpa_import_failed',
      'sherpa_import_cancelled',
      'moss_package_incomplete',
      'activity_destroyed',
      'live2d_import_failed',
      'invalid_archive',
      'invalid_moss_request',
      'invalid_moss_output_path',
      'invalid_sensevoice_path',
      'invalid_sensevoice_audio',
      'invalid_qwen3_messages',
      'invalid_qwen3_generation',
    ]) {
      final english = serviceErrorText(en, code: code, fallback: 'detail');
      final chinese = serviceErrorText(zh, code: code, fallback: 'detail');
      expect(english, isNotEmpty, reason: 'missing English for $code');
      expect(
        _cjk.hasMatch(english),
        isFalse,
        reason: 'English text for $code leaked CJK: $english',
      );
      expect(chinese, isNotEmpty, reason: 'missing Chinese for $code');
    }
  });

  test('unknown codes fall back to the native detail', () async {
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    expect(
      serviceErrorText(en, code: 'native_unknown', fallback: 'native detail'),
      'native detail',
    );
    expect(serviceErrorText(en, fallback: ''), en.unknownError);
    expect(serviceErrorText(en), en.unknownError);
  });
}
