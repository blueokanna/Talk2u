import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

enum AppColorTheme {
  teal(Color(0xFF006A6A)),
  blue(Color(0xFF005AC1)),
  green(Color(0xFF386A20)),
  rose(Color(0xFF9C4146));

  const AppColorTheme(this.seed);
  final Color seed;
}

enum AppLanguage { system, zh, en }

class UiPreferences extends ChangeNotifier {
  UiPreferences._(this._file);

  final File _file;
  ThemeMode themeMode = ThemeMode.system;
  AppColorTheme colorTheme = AppColorTheme.teal;
  AppLanguage language = AppLanguage.system;

  Locale? get locale => switch (language) {
    AppLanguage.system => null,
    AppLanguage.zh => const Locale('zh'),
    AppLanguage.en => const Locale('en'),
  };

  static Future<UiPreferences> load() async {
    final directory = await getApplicationSupportDirectory();
    final preferences = UiPreferences._(
      File('${directory.path}${Platform.pathSeparator}ui-preferences.json'),
    );
    await preferences._read();
    return preferences;
  }

  Future<void> setThemeMode(ThemeMode value) async {
    if (themeMode == value) return;
    themeMode = value;
    notifyListeners();
    await _write();
  }

  Future<void> setColorTheme(AppColorTheme value) async {
    if (colorTheme == value) return;
    colorTheme = value;
    notifyListeners();
    await _write();
  }

  Future<void> setLanguage(AppLanguage value) async {
    if (language == value) return;
    language = value;
    notifyListeners();
    await _write();
  }

  Future<void> _read() async {
    if (!await _file.exists()) return;
    try {
      final value = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      themeMode = ThemeMode.values.firstWhere(
        (item) => item.name == value['themeMode'],
        orElse: () => ThemeMode.system,
      );
      colorTheme = AppColorTheme.values.firstWhere(
        (item) => item.name == value['colorTheme'],
        orElse: () => AppColorTheme.teal,
      );
      language = AppLanguage.values.firstWhere(
        (item) => item.name == value['language'],
        orElse: () => AppLanguage.system,
      );
    } on Object {
      themeMode = ThemeMode.system;
      colorTheme = AppColorTheme.teal;
      language = AppLanguage.system;
    }
  }

  Future<void> _write() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'themeMode': themeMode.name,
        'colorTheme': colorTheme.name,
        'language': language.name,
      }),
      flush: true,
    );
  }
}
