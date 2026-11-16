import 'package:flutter/foundation.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/l10n/app_strings.dart';

/// A voice shipped with the MOSS-TTS-Nano deployment package.
///
/// The `label` is the voice's product name and is intentionally not translated:
/// it identifies a concrete speaker inside the model, exactly like a person's
/// name. Only the gender suffix in [displayLabel] is localized.
@immutable
class MossVoice {
  const MossVoice({
    required this.id,
    required this.label,
    required this.locale,
    required this.gender,
  });

  final String id;
  final String label;
  final String locale;
  final String gender;

  String get displayLabel =>
      '$label · ${genderLabel(AppStrings.current, gender)}';

  @override
  bool operator ==(Object other) =>
      other is MossVoice && other.id == id && other.locale == locale;

  @override
  int get hashCode => Object.hash(id, locale);
}

/// Localized gender word used as the voice suffix.
String genderLabel(AppLocalizations strings, String gender) => switch (gender) {
  'male' => strings.genderMale,
  'female' => strings.genderFemale,
  _ => strings.genderOther,
};

/// Built-in MOSS-TTS-Nano catalog, ordered Chinese, English, Japanese.
const mossVoiceCatalog = <MossVoice>[
  MossVoice(id: 'Junhao', label: '君豪', locale: 'zh-CN', gender: 'male'),
  MossVoice(id: 'Zhiming', label: '志明·京味', locale: 'zh-CN', gender: 'male'),
  MossVoice(id: 'Weiguo', label: '卫国·说书', locale: 'zh-CN', gender: 'male'),
  MossVoice(id: 'Xiaoyu', label: '小雨', locale: 'zh-CN', gender: 'female'),
  MossVoice(id: 'Yuewen', label: '悦雯·机车', locale: 'zh-CN', gender: 'female'),
  MossVoice(id: 'Lingyu', label: '凌语·深夜电台', locale: 'zh-CN', gender: 'female'),
  MossVoice(id: 'Trump', label: 'Trump', locale: 'en-US', gender: 'male'),
  MossVoice(id: 'Ava', label: 'Ava', locale: 'en-US', gender: 'female'),
  MossVoice(id: 'Bella', label: 'Bella', locale: 'en-US', gender: 'female'),
  MossVoice(id: 'Adam', label: 'Adam', locale: 'en-US', gender: 'male'),
  MossVoice(id: 'Nathan', label: 'Nathan', locale: 'en-US', gender: 'male'),
  MossVoice(id: 'Soyo', label: 'Soyo', locale: 'ja-JP', gender: 'female'),
  MossVoice(id: 'Saki', label: 'Saki', locale: 'ja-JP', gender: 'female'),
  MossVoice(id: 'Mortis', label: 'Mortis', locale: 'ja-JP', gender: 'female'),
  MossVoice(id: 'Umiri', label: 'Umiri', locale: 'ja-JP', gender: 'female'),
  MossVoice(id: 'Mei', label: 'Mei', locale: 'ja-JP', gender: 'female'),
  MossVoice(id: 'Anon', label: 'Anon', locale: 'ja-JP', gender: 'female'),
  MossVoice(id: 'Arisa', label: 'Arisa', locale: 'ja-JP', gender: 'female'),
];
