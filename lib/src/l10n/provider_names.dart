import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/models/provider_profile.dart';

/// Display name of a provider profile.
///
/// Built-in profiles keep a stable machine-readable [ProviderProfile.name] so a
/// persisted preference never freezes one language into storage; the label the
/// user reads comes from the ARB files. User-created profiles keep their name.
String providerDisplayName(ProviderProfile profile, AppLocalizations strings) =>
    profile.id == ProviderProfile.androidOfflineId
    ? strings.offlineProviderName
    : profile.name;
