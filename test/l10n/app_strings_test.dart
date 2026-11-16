import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/l10n/app_strings.dart';

void main() {
  tearDown(AppStrings.reset);

  test('defaults to English before the app configures a locale', () {
    expect(AppStrings.locale, const Locale('en'));
    expect(
      AppStrings.current.micPermissionDenied,
      'Microphone permission was not granted',
    );
  });

  test('follows an explicit locale', () {
    AppStrings.configure(const Locale('zh'));
    expect(AppStrings.current.micPermissionDenied, '麦克风权限未授予');
    AppStrings.configure(const Locale('en'));
    expect(
      AppStrings.current.micPermissionDenied,
      'Microphone permission was not granted',
    );
  });

  test('resolves the system locale when the user follows it', () {
    AppStrings.configure(null, systemLocale: const Locale('zh', 'CN'));
    expect(AppStrings.locale, const Locale('zh'));
    AppStrings.configure(null, systemLocale: const Locale('de', 'DE'));
    expect(AppStrings.locale, const Locale('en'));
  });

  test('parameterised messages interpolate', () {
    AppStrings.configure(const Locale('en'));
    expect(
      AppStrings.current.micStopFailed('EIO'),
      'Unable to stop microphone recording: EIO',
    );
  });
}
