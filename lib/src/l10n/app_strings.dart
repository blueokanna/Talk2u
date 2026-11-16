import 'package:flutter/widgets.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';

/// Process-wide access to the generated strings for code that has no
/// `BuildContext`.
///
/// Widgets keep using `AppLocalizations.of(context)`: it rebuilds on locale
/// changes and stays scoped to the widget tree. Singletons such as the model,
/// speech and avatar services outlive the tree and are also used from isolates
/// and tests, so they read [current] instead of hardcoding a display language.
///
/// The resolver is deliberately synchronous — `lookupAppLocalizations` is a
/// plain switch — so error paths never turn asynchronous just to format text.
abstract final class AppStrings {
  static Locale _locale = const Locale('en');
  static AppLocalizations? _resolved;

  /// Locale currently used for context-free strings.
  static Locale get locale => _locale;

  /// Localized strings for the configured locale.
  static AppLocalizations get current =>
      _resolved ??= lookupAppLocalizations(_locale);

  /// Records the app locale.
  ///
  /// [locale] is null when the user follows the system language; [systemLocale]
  /// is then reduced to the best supported match. Unknown languages fall back to
  /// English, which is also the default before [configure] runs, so services
  /// created during startup or in tests never emit an untranslated string.
  static void configure(Locale? locale, {Locale? systemLocale}) {
    final next = _resolve(locale ?? systemLocale);
    if (next == _locale && _resolved != null) return;
    _locale = next;
    _resolved = null;
  }

  static Locale _resolve(Locale? locale) {
    if (locale == null) return const Locale('en');
    for (final supported in AppLocalizations.supportedLocales) {
      if (supported.languageCode == locale.languageCode) return supported;
    }
    return const Locale('en');
  }

  /// Test hook that forces a language without touching platform channels.
  @visibleForTesting
  static void reset() {
    _locale = const Locale('en');
    _resolved = null;
  }
}
