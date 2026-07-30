import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Talk2U'**
  String get appTitle;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @appearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearance;

  /// No description provided for @themeMode.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get themeMode;

  /// No description provided for @themeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @colorScheme.
  ///
  /// In en, this message translates to:
  /// **'Color scheme'**
  String get colorScheme;

  /// No description provided for @colorTeal.
  ///
  /// In en, this message translates to:
  /// **'Teal'**
  String get colorTeal;

  /// No description provided for @colorBlue.
  ///
  /// In en, this message translates to:
  /// **'Blue'**
  String get colorBlue;

  /// No description provided for @colorGreen.
  ///
  /// In en, this message translates to:
  /// **'Green'**
  String get colorGreen;

  /// No description provided for @colorRose.
  ///
  /// In en, this message translates to:
  /// **'Rose'**
  String get colorRose;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'System language'**
  String get languageSystem;

  /// No description provided for @languageChinese.
  ///
  /// In en, this message translates to:
  /// **'Simplified Chinese'**
  String get languageChinese;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @modelAndApi.
  ///
  /// In en, this message translates to:
  /// **'Models and APIs'**
  String get modelAndApi;

  /// No description provided for @deviceAi.
  ///
  /// In en, this message translates to:
  /// **'On-device AI'**
  String get deviceAi;

  /// No description provided for @offlineRecognition.
  ///
  /// In en, this message translates to:
  /// **'On-device speech recognition'**
  String get offlineRecognition;

  /// No description provided for @mossSpeech.
  ///
  /// In en, this message translates to:
  /// **'MOSS on-device speech'**
  String get mossSpeech;

  /// No description provided for @startupPreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing local conversation...'**
  String get startupPreparing;

  /// No description provided for @startupFailed.
  ///
  /// In en, this message translates to:
  /// **'Startup failed: {error}'**
  String startupFailed(String error);

  /// No description provided for @rustCoreTimeout.
  ///
  /// In en, this message translates to:
  /// **'Rust core initialization timed out'**
  String get rustCoreTimeout;

  /// No description provided for @localDataTimeout.
  ///
  /// In en, this message translates to:
  /// **'Local data initialization timed out'**
  String get localDataTimeout;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @live2dDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Live2D performance'**
  String get live2dDiagnostics;

  /// No description provided for @renderBackend.
  ///
  /// In en, this message translates to:
  /// **'Actual backend'**
  String get renderBackend;

  /// No description provided for @gpuDevice.
  ///
  /// In en, this message translates to:
  /// **'GPU device'**
  String get gpuDevice;

  /// No description provided for @renderedFrames.
  ///
  /// In en, this message translates to:
  /// **'Rendered frames'**
  String get renderedFrames;

  /// No description provided for @cpuUsage.
  ///
  /// In en, this message translates to:
  /// **'CPU usage'**
  String get cpuUsage;

  /// No description provided for @gpuUsage.
  ///
  /// In en, this message translates to:
  /// **'GPU usage'**
  String get gpuUsage;

  /// No description provided for @npuUsage.
  ///
  /// In en, this message translates to:
  /// **'NPU usage'**
  String get npuUsage;

  /// No description provided for @processScope.
  ///
  /// In en, this message translates to:
  /// **'app process'**
  String get processScope;

  /// No description provided for @deviceScope.
  ///
  /// In en, this message translates to:
  /// **'device'**
  String get deviceScope;

  /// No description provided for @usageUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get usageUnavailable;

  /// No description provided for @gpuUsageUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable: the GPU utilization node is not readable by this app'**
  String get gpuUsageUnavailable;

  /// No description provided for @npuUsageUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable: Android/QNN does not expose global NPU utilization'**
  String get npuUsageUnavailable;

  /// No description provided for @npuRecentWorkload.
  ///
  /// In en, this message translates to:
  /// **'{value}% app HTP call duty over the last second'**
  String npuRecentWorkload(String value);

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @diagnosticsFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to read Live2D performance: {error}'**
  String diagnosticsFailed(String error);

  /// No description provided for @percentValue.
  ///
  /// In en, this message translates to:
  /// **'{value}%'**
  String percentValue(String value);

  /// No description provided for @live2dDiagnosticsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Live2D performance'**
  String get live2dDiagnosticsTooltip;

  /// No description provided for @reloadLive2d.
  ///
  /// In en, this message translates to:
  /// **'Reload Live2D'**
  String get reloadLive2d;

  /// No description provided for @currentPlatformUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Live2D is unavailable on this platform'**
  String get currentPlatformUnavailable;

  /// No description provided for @mossRuntimeUnavailable.
  ///
  /// In en, this message translates to:
  /// **'QNN HTP unavailable'**
  String get mossRuntimeUnavailable;

  /// No description provided for @senseVoiceQnnUnsupported.
  ///
  /// In en, this message translates to:
  /// **'QNN HTP · ASR / LID / SER / AED'**
  String get senseVoiceQnnUnsupported;

  /// No description provided for @platform.
  ///
  /// In en, this message translates to:
  /// **'Provider'**
  String get platform;

  /// No description provided for @showSecret.
  ///
  /// In en, this message translates to:
  /// **'Show API key'**
  String get showSecret;

  /// No description provided for @hideSecret.
  ///
  /// In en, this message translates to:
  /// **'Hide API key'**
  String get hideSecret;

  /// No description provided for @apiKeyRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter an API key'**
  String get apiKeyRequired;

  /// No description provided for @apiUrl.
  ///
  /// In en, this message translates to:
  /// **'API URL'**
  String get apiUrl;

  /// No description provided for @validHttpUrlRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a complete HTTP(S) URL'**
  String get validHttpUrlRequired;

  /// No description provided for @chatModelId.
  ///
  /// In en, this message translates to:
  /// **'Chat model ID'**
  String get chatModelId;

  /// No description provided for @modelIdRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a model ID'**
  String get modelIdRequired;

  /// No description provided for @reasoningModelId.
  ///
  /// In en, this message translates to:
  /// **'Reasoning model ID (optional)'**
  String get reasoningModelId;

  /// No description provided for @maxOutputTokens.
  ///
  /// In en, this message translates to:
  /// **'Maximum output tokens'**
  String get maxOutputTokens;

  /// No description provided for @tokenRangeError.
  ///
  /// In en, this message translates to:
  /// **'Enter an integer from 1 to 131072'**
  String get tokenRangeError;

  /// No description provided for @enableReasoningByDefault.
  ///
  /// In en, this message translates to:
  /// **'Enable reasoning by default'**
  String get enableReasoningByDefault;

  /// No description provided for @reasoningRequiresModel.
  ///
  /// In en, this message translates to:
  /// **'Only applies when a reasoning model is configured for this provider'**
  String get reasoningRequiresModel;

  /// No description provided for @saveConfiguration.
  ///
  /// In en, this message translates to:
  /// **'Save configuration'**
  String get saveConfiguration;

  /// No description provided for @testConnection.
  ///
  /// In en, this message translates to:
  /// **'Test connection'**
  String get testConnection;

  /// No description provided for @manageModel.
  ///
  /// In en, this message translates to:
  /// **'Manage on-device model'**
  String get manageModel;

  /// No description provided for @deleteModel.
  ///
  /// In en, this message translates to:
  /// **'Delete model'**
  String get deleteModel;

  /// No description provided for @installQwen.
  ///
  /// In en, this message translates to:
  /// **'Download Qwen3-4B-Instruct-2507 model'**
  String get installQwen;

  /// No description provided for @cancelDownload.
  ///
  /// In en, this message translates to:
  /// **'Cancel download'**
  String get cancelDownload;

  /// No description provided for @deleteSenseVoice.
  ///
  /// In en, this message translates to:
  /// **'Delete SenseVoice'**
  String get deleteSenseVoice;

  /// No description provided for @downloadSenseVoice.
  ///
  /// In en, this message translates to:
  /// **'Download SenseVoice'**
  String get downloadSenseVoice;

  /// No description provided for @deleteMoss.
  ///
  /// In en, this message translates to:
  /// **'Delete MOSS-TTS-Nano'**
  String get deleteMoss;

  /// No description provided for @importMoss.
  ///
  /// In en, this message translates to:
  /// **'Import MOSS QNN HTP deployment'**
  String get importMoss;

  /// No description provided for @mossVoice.
  ///
  /// In en, this message translates to:
  /// **'MOSS built-in cloned voice'**
  String get mossVoice;

  /// No description provided for @stopPreview.
  ///
  /// In en, this message translates to:
  /// **'Stop preview'**
  String get stopPreview;

  /// No description provided for @previewVoice.
  ///
  /// In en, this message translates to:
  /// **'Preview selected voice'**
  String get previewVoice;

  /// No description provided for @mossPreviewText.
  ///
  /// In en, this message translates to:
  /// **'Hello, it is good to meet you. What would you like to talk about today? I will listen carefully and respond naturally.'**
  String get mossPreviewText;

  /// No description provided for @qwenReady.
  ///
  /// In en, this message translates to:
  /// **'Ready · {acceleration}'**
  String qwenReady(String acceleration);

  /// No description provided for @qwenInstallHint.
  ///
  /// In en, this message translates to:
  /// **'No API required; GenieX downloads the chipset-matched QAIRT model bundle'**
  String get qwenInstallHint;

  /// No description provided for @qwenModelReady.
  ///
  /// In en, this message translates to:
  /// **'Ready · {license} · {size}'**
  String qwenModelReady(String license, String size);

  /// No description provided for @qwenModelPackage.
  ///
  /// In en, this message translates to:
  /// **'{license} · QAIRT · Qualcomm QNN HTP/NPU'**
  String qwenModelPackage(String license);

  /// No description provided for @loadingModel.
  ///
  /// In en, this message translates to:
  /// **'Loading model...'**
  String get loadingModel;

  /// No description provided for @senseVoiceReady.
  ///
  /// In en, this message translates to:
  /// **'Ready · SM8850 QNN HTP · fully offline'**
  String get senseVoiceReady;

  /// No description provided for @senseVoiceSize.
  ///
  /// In en, this message translates to:
  /// **'About 154.5 MiB · SenseVoice INT8 · SM8850 QNN'**
  String get senseVoiceSize;

  /// No description provided for @mossGenerating.
  ///
  /// In en, this message translates to:
  /// **'Running on-device speech inference'**
  String get mossGenerating;

  /// No description provided for @mossInitializing.
  ///
  /// In en, this message translates to:
  /// **'Initializing QNN HTP contexts'**
  String get mossInitializing;

  /// No description provided for @mossReady.
  ///
  /// In en, this message translates to:
  /// **'Ready · {acceleration} · 48 kHz · Chinese/English/Japanese'**
  String mossReady(String acceleration);

  /// No description provided for @loadSettingsFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to load settings: {error}'**
  String loadSettingsFailed(String error);

  /// No description provided for @settingsWriteFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to write the settings file'**
  String get settingsWriteFailed;

  /// No description provided for @providerSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved {provider}'**
  String providerSaved(String provider);

  /// No description provided for @saveFailed.
  ///
  /// In en, this message translates to:
  /// **'Save failed: {error}'**
  String saveFailed(String error);

  /// No description provided for @connectionTestFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection test failed: {error}'**
  String connectionTestFailed(String error);

  /// No description provided for @qwenInstalled.
  ///
  /// In en, this message translates to:
  /// **'Qwen3-4B-Instruct-2507 model installed and verified'**
  String get qwenInstalled;

  /// No description provided for @qwenInstallFailed.
  ///
  /// In en, this message translates to:
  /// **'Qwen3 deployment installation failed: {error}'**
  String qwenInstallFailed(String error);

  /// No description provided for @offlineModelDeleted.
  ///
  /// In en, this message translates to:
  /// **'On-device AI model deleted'**
  String get offlineModelDeleted;

  /// No description provided for @offlineModelDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to delete the on-device AI model: {error}'**
  String offlineModelDeleteFailed(String error);

  /// No description provided for @senseVoiceInstalled.
  ///
  /// In en, this message translates to:
  /// **'SenseVoice offline model installed'**
  String get senseVoiceInstalled;

  /// No description provided for @senseVoiceInstallFailed.
  ///
  /// In en, this message translates to:
  /// **'SenseVoice download failed: {error}'**
  String senseVoiceInstallFailed(String error);

  /// No description provided for @mossImported.
  ///
  /// In en, this message translates to:
  /// **'MOSS QNN HTP deployment imported and verified'**
  String get mossImported;

  /// No description provided for @mossImportFailed.
  ///
  /// In en, this message translates to:
  /// **'MOSS QNN deployment import failed: {error}'**
  String mossImportFailed(String error);

  /// No description provided for @mossDeleted.
  ///
  /// In en, this message translates to:
  /// **'MOSS-TTS-Nano model deleted'**
  String get mossDeleted;

  /// No description provided for @mossDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to delete MOSS-TTS-Nano: {error}'**
  String mossDeleteFailed(String error);

  /// No description provided for @mossVoiceChanged.
  ///
  /// In en, this message translates to:
  /// **'MOSS voice changed'**
  String get mossVoiceChanged;

  /// No description provided for @mossVoiceChangeFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to change the MOSS voice: {error}'**
  String mossVoiceChangeFailed(String error);

  /// No description provided for @mossPreviewFailed.
  ///
  /// In en, this message translates to:
  /// **'MOSS-TTS-Nano preview failed: {error}'**
  String mossPreviewFailed(String error);

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @send.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get send;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @copied.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get copied;

  /// No description provided for @regenerate.
  ///
  /// In en, this message translates to:
  /// **'Regenerate'**
  String get regenerate;

  /// No description provided for @rewrite.
  ///
  /// In en, this message translates to:
  /// **'Rewrite'**
  String get rewrite;

  /// No description provided for @rollback.
  ///
  /// In en, this message translates to:
  /// **'Roll back'**
  String get rollback;

  /// No description provided for @editAndResend.
  ///
  /// In en, this message translates to:
  /// **'Edit and resend'**
  String get editAndResend;

  /// No description provided for @deleteMessage.
  ///
  /// In en, this message translates to:
  /// **'Delete message'**
  String get deleteMessage;

  /// No description provided for @deleteMessageConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete this message?'**
  String get deleteMessageConfirm;

  /// No description provided for @rollbackConversation.
  ///
  /// In en, this message translates to:
  /// **'Roll back conversation'**
  String get rollbackConversation;

  /// No description provided for @rollbackConversationConfirm.
  ///
  /// In en, this message translates to:
  /// **'This message and every later message will be deleted, along with related memory. Continue?'**
  String get rollbackConversationConfirm;

  /// No description provided for @thinking.
  ///
  /// In en, this message translates to:
  /// **'Thinking'**
  String get thinking;

  /// No description provided for @thinkingProcess.
  ///
  /// In en, this message translates to:
  /// **'Reasoning'**
  String get thinkingProcess;

  /// No description provided for @editMessageHint.
  ///
  /// In en, this message translates to:
  /// **'Edit message...'**
  String get editMessageHint;

  /// No description provided for @typing.
  ///
  /// In en, this message translates to:
  /// **'Typing...'**
  String get typing;

  /// No description provided for @emptyReply.
  ///
  /// In en, this message translates to:
  /// **'(empty reply)'**
  String get emptyReply;

  /// No description provided for @offlineVoiceInput.
  ///
  /// In en, this message translates to:
  /// **'Offline voice input'**
  String get offlineVoiceInput;

  /// No description provided for @offlineVoiceUnavailable.
  ///
  /// In en, this message translates to:
  /// **'No offline recognition engine is available'**
  String get offlineVoiceUnavailable;

  /// No description provided for @aiResponding.
  ///
  /// In en, this message translates to:
  /// **'AI is responding...'**
  String get aiResponding;

  /// No description provided for @messageHint.
  ///
  /// In en, this message translates to:
  /// **'Type a message...'**
  String get messageHint;

  /// No description provided for @stopGenerating.
  ///
  /// In en, this message translates to:
  /// **'Stop generating'**
  String get stopGenerating;

  /// No description provided for @conversations.
  ///
  /// In en, this message translates to:
  /// **'Conversations'**
  String get conversations;

  /// No description provided for @newConversation.
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get newConversation;

  /// No description provided for @noConversations.
  ///
  /// In en, this message translates to:
  /// **'No conversations'**
  String get noConversations;

  /// No description provided for @startConversationHint.
  ///
  /// In en, this message translates to:
  /// **'Create one to start chatting'**
  String get startConversationHint;

  /// No description provided for @untitledConversation.
  ///
  /// In en, this message translates to:
  /// **'Untitled conversation'**
  String get untitledConversation;

  /// No description provided for @deleteConversation.
  ///
  /// In en, this message translates to:
  /// **'Delete conversation'**
  String get deleteConversation;

  /// No description provided for @deleteConversationConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete this conversation? This cannot be undone.'**
  String get deleteConversationConfirm;

  /// No description provided for @justNow.
  ///
  /// In en, this message translates to:
  /// **'Just now'**
  String get justNow;

  /// No description provided for @minutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{count} min ago'**
  String minutesAgo(int count);

  /// No description provided for @daysAgo.
  ///
  /// In en, this message translates to:
  /// **'{count} days ago'**
  String daysAgo(int count);

  /// No description provided for @charactersTitle.
  ///
  /// In en, this message translates to:
  /// **'My characters'**
  String get charactersTitle;

  /// No description provided for @deleteCharacter.
  ///
  /// In en, this message translates to:
  /// **'Delete character'**
  String get deleteCharacter;

  /// No description provided for @deleteCharacterConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"? This cannot be undone.'**
  String deleteCharacterConfirm(String name);

  /// No description provided for @charactersImported.
  ///
  /// In en, this message translates to:
  /// **'Imported {count} characters'**
  String charactersImported(int count);

  /// No description provided for @characterImportFailed.
  ///
  /// In en, this message translates to:
  /// **'Import failed. Check the file format.'**
  String get characterImportFailed;

  /// No description provided for @exportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed: {error}'**
  String exportFailed(String error);

  /// No description provided for @shareCharacter.
  ///
  /// In en, this message translates to:
  /// **'Character profile: {name}'**
  String shareCharacter(String name);

  /// No description provided for @shareAllCharacters.
  ///
  /// In en, this message translates to:
  /// **'All character profiles'**
  String get shareAllCharacters;

  /// No description provided for @importCharacters.
  ///
  /// In en, this message translates to:
  /// **'Import characters'**
  String get importCharacters;

  /// No description provided for @exportAll.
  ///
  /// In en, this message translates to:
  /// **'Export all'**
  String get exportAll;

  /// No description provided for @export.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get export;

  /// No description provided for @createCharacter.
  ///
  /// In en, this message translates to:
  /// **'Create character'**
  String get createCharacter;

  /// No description provided for @editCharacter.
  ///
  /// In en, this message translates to:
  /// **'Edit character'**
  String get editCharacter;

  /// No description provided for @regularAssistant.
  ///
  /// In en, this message translates to:
  /// **'Standard assistant'**
  String get regularAssistant;

  /// No description provided for @directChat.
  ///
  /// In en, this message translates to:
  /// **'Start chatting without creating a character'**
  String get directChat;

  /// No description provided for @noCharacterSettings.
  ///
  /// In en, this message translates to:
  /// **'Do not use a character profile'**
  String get noCharacterSettings;

  /// No description provided for @characterSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to save character: {error}'**
  String characterSaveFailed(String error);

  /// No description provided for @live2dModelsImported.
  ///
  /// In en, this message translates to:
  /// **'Live2D model imported; found {count} models'**
  String live2dModelsImported(int count);

  /// No description provided for @live2dModelImportFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to import Live2D model: {error}'**
  String live2dModelImportFailed(String error);

  /// No description provided for @chooseLive2dModel.
  ///
  /// In en, this message translates to:
  /// **'Choose a Live2D model'**
  String get chooseLive2dModel;

  /// No description provided for @maoLicenseTitle.
  ///
  /// In en, this message translates to:
  /// **'Use the bundled Mao sample model'**
  String get maoLicenseTitle;

  /// No description provided for @maoLicenseDescription.
  ///
  /// In en, this message translates to:
  /// **'This model is provided by Live2D Inc. You must accept the Cubism sample-model license before using it. model/Live2d/mao/ReadMe.txt contains its source and license details.'**
  String get maoLicenseDescription;

  /// No description provided for @licenseAccepted.
  ///
  /// In en, this message translates to:
  /// **'I have read and agree'**
  String get licenseAccepted;

  /// No description provided for @maoInstalled.
  ///
  /// In en, this message translates to:
  /// **'Cubism 5 Mao model installed'**
  String get maoInstalled;

  /// No description provided for @maoInstallFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to install the bundled model: {error}'**
  String maoInstallFailed(String error);

  /// No description provided for @characterName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get characterName;

  /// No description provided for @characterNameHint.
  ///
  /// In en, this message translates to:
  /// **'Enter an AI nickname'**
  String get characterNameHint;

  /// No description provided for @characterNameRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a character name'**
  String get characterNameRequired;

  /// No description provided for @gender.
  ///
  /// In en, this message translates to:
  /// **'Gender'**
  String get gender;

  /// No description provided for @genderMale.
  ///
  /// In en, this message translates to:
  /// **'Male'**
  String get genderMale;

  /// No description provided for @genderFemale.
  ///
  /// In en, this message translates to:
  /// **'Female'**
  String get genderFemale;

  /// No description provided for @genderOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get genderOther;

  /// No description provided for @characterSetting.
  ///
  /// In en, this message translates to:
  /// **'Character profile'**
  String get characterSetting;

  /// No description provided for @characterSettingHelp.
  ///
  /// In en, this message translates to:
  /// **'Describe the character\'s background, personality, identity, and relationship to you. This affects responses.'**
  String get characterSettingHelp;

  /// No description provided for @characterSettingHint.
  ///
  /// In en, this message translates to:
  /// **'Describe personality, identity, and background'**
  String get characterSettingHint;

  /// No description provided for @characterSettingRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a character profile'**
  String get characterSettingRequired;

  /// No description provided for @characterDescription.
  ///
  /// In en, this message translates to:
  /// **'Introduction'**
  String get characterDescription;

  /// No description provided for @characterDescriptionHelp.
  ///
  /// In en, this message translates to:
  /// **'A short introduction shown in the character list. It does not affect responses.'**
  String get characterDescriptionHelp;

  /// No description provided for @characterDescriptionHint.
  ///
  /// In en, this message translates to:
  /// **'Introduce this character'**
  String get characterDescriptionHint;

  /// No description provided for @characterGreeting.
  ///
  /// In en, this message translates to:
  /// **'Opening message'**
  String get characterGreeting;

  /// No description provided for @characterGreetingHint.
  ///
  /// In en, this message translates to:
  /// **'Enter an opening message'**
  String get characterGreetingHint;

  /// No description provided for @dialogueStyleExample.
  ///
  /// In en, this message translates to:
  /// **'Dialogue style example'**
  String get dialogueStyleExample;

  /// No description provided for @dialogueStyleHelp.
  ///
  /// In en, this message translates to:
  /// **'Provide text that demonstrates how this character speaks.'**
  String get dialogueStyleHelp;

  /// No description provided for @dialogueStyleHint.
  ///
  /// In en, this message translates to:
  /// **'Example of this character\'s speaking style'**
  String get dialogueStyleHint;

  /// No description provided for @userName.
  ///
  /// In en, this message translates to:
  /// **'User name'**
  String get userName;

  /// No description provided for @userNameHint.
  ///
  /// In en, this message translates to:
  /// **'How the AI should address you'**
  String get userNameHint;

  /// No description provided for @userPersona.
  ///
  /// In en, this message translates to:
  /// **'User persona'**
  String get userPersona;

  /// No description provided for @userPersonaHelp.
  ///
  /// In en, this message translates to:
  /// **'Describe the identity, personality, or history you play in this conversation.'**
  String get userPersonaHelp;

  /// No description provided for @userPersonaHint.
  ///
  /// In en, this message translates to:
  /// **'Describe your role in the conversation'**
  String get userPersonaHint;

  /// No description provided for @live2dModel.
  ///
  /// In en, this message translates to:
  /// **'Live2D model'**
  String get live2dModel;

  /// No description provided for @noLive2dModel.
  ///
  /// In en, this message translates to:
  /// **'No Live2D ZIP model imported'**
  String get noLive2dModel;

  /// No description provided for @importLive2dModel.
  ///
  /// In en, this message translates to:
  /// **'Import Live2D ZIP model'**
  String get importLive2dModel;

  /// No description provided for @installMaoModel.
  ///
  /// In en, this message translates to:
  /// **'Install bundled Cubism 5 Mao model'**
  String get installMaoModel;

  /// No description provided for @tags.
  ///
  /// In en, this message translates to:
  /// **'Tags'**
  String get tags;

  /// No description provided for @addTag.
  ///
  /// In en, this message translates to:
  /// **'Add tag'**
  String get addTag;

  /// No description provided for @tagNameHint.
  ///
  /// In en, this message translates to:
  /// **'Enter a tag'**
  String get tagNameHint;

  /// No description provided for @confirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// No description provided for @offlineSttUnavailable.
  ///
  /// In en, this message translates to:
  /// **'On-device speech recognition unavailable: {error}'**
  String offlineSttUnavailable(String error);

  /// No description provided for @continuousCallRequiresSpeech.
  ///
  /// In en, this message translates to:
  /// **'Continuous conversation requires working on-device speech recognition and synthesis'**
  String get continuousCallRequiresSpeech;

  /// No description provided for @continuousCallStartFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to start continuous conversation: {error}'**
  String continuousCallStartFailed(String error);

  /// No description provided for @continuousCallStopped.
  ///
  /// In en, this message translates to:
  /// **'Continuous conversation stopped: {error}'**
  String continuousCallStopped(String error);

  /// No description provided for @noOfflineTtsVoice.
  ///
  /// In en, this message translates to:
  /// **'No usable on-device TTS voice pack was found'**
  String get noOfflineTtsVoice;

  /// No description provided for @offlineTtsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'On-device speech synthesis unavailable: {error}'**
  String offlineTtsUnavailable(String error);

  /// No description provided for @restart.
  ///
  /// In en, this message translates to:
  /// **'Restart'**
  String get restart;

  /// No description provided for @restartConversationSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Clear messages while keeping the character profile and opening message'**
  String get restartConversationSubtitle;

  /// No description provided for @conversationStyle.
  ///
  /// In en, this message translates to:
  /// **'Conversation style'**
  String get conversationStyle;

  /// No description provided for @styleFree.
  ///
  /// In en, this message translates to:
  /// **'Free'**
  String get styleFree;

  /// No description provided for @styleDialogue.
  ///
  /// In en, this message translates to:
  /// **'Dialogue only'**
  String get styleDialogue;

  /// No description provided for @styleAction.
  ///
  /// In en, this message translates to:
  /// **'Action only'**
  String get styleAction;

  /// No description provided for @styleMixed.
  ///
  /// In en, this message translates to:
  /// **'Mixed (automatic)'**
  String get styleMixed;

  /// No description provided for @providerAndModel.
  ///
  /// In en, this message translates to:
  /// **'Provider and model'**
  String get providerAndModel;

  /// No description provided for @apiProvider.
  ///
  /// In en, this message translates to:
  /// **'API provider'**
  String get apiProvider;

  /// No description provided for @providerNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'{provider} (not configured)'**
  String providerNotConfigured(String provider);

  /// No description provided for @notConfigured.
  ///
  /// In en, this message translates to:
  /// **'Not configured'**
  String get notConfigured;

  /// No description provided for @chatModel.
  ///
  /// In en, this message translates to:
  /// **'Chat model'**
  String get chatModel;

  /// No description provided for @reasoningModelHint.
  ///
  /// In en, this message translates to:
  /// **'Reasoning model; enables the reasoning pipeline automatically'**
  String get reasoningModelHint;

  /// No description provided for @restartStory.
  ///
  /// In en, this message translates to:
  /// **'Restart story'**
  String get restartStory;

  /// No description provided for @restartStoryConfirm.
  ///
  /// In en, this message translates to:
  /// **'Restart the story? All messages will be cleared, while the character profile and opening message are kept.'**
  String get restartStoryConfirm;

  /// No description provided for @stopReading.
  ///
  /// In en, this message translates to:
  /// **'Stop reading'**
  String get stopReading;

  /// No description provided for @readLastReply.
  ///
  /// In en, this message translates to:
  /// **'Read the last reply on device'**
  String get readLastReply;

  /// No description provided for @noOfflineTtsPack.
  ///
  /// In en, this message translates to:
  /// **'No on-device TTS voice pack'**
  String get noOfflineTtsPack;

  /// No description provided for @characterList.
  ///
  /// In en, this message translates to:
  /// **'Characters'**
  String get characterList;

  /// No description provided for @settingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'API keys and model configuration'**
  String get settingsSubtitle;

  /// No description provided for @hideConversation.
  ///
  /// In en, this message translates to:
  /// **'Hide conversation'**
  String get hideConversation;

  /// No description provided for @showConversation.
  ///
  /// In en, this message translates to:
  /// **'Show conversation'**
  String get showConversation;

  /// No description provided for @endContinuousCall.
  ///
  /// In en, this message translates to:
  /// **'End continuous conversation'**
  String get endContinuousCall;

  /// No description provided for @startContinuousCall.
  ///
  /// In en, this message translates to:
  /// **'Start continuous conversation'**
  String get startContinuousCall;

  /// No description provided for @conversation.
  ///
  /// In en, this message translates to:
  /// **'Conversation'**
  String get conversation;

  /// No description provided for @startNewConversation.
  ///
  /// In en, this message translates to:
  /// **'Start a new conversation'**
  String get startNewConversation;

  /// No description provided for @startNewConversationHint.
  ///
  /// In en, this message translates to:
  /// **'Type a message or choose a character'**
  String get startNewConversationHint;

  /// No description provided for @chooseCharacter.
  ///
  /// In en, this message translates to:
  /// **'Choose character'**
  String get chooseCharacter;

  /// No description provided for @llmRoute.
  ///
  /// In en, this message translates to:
  /// **'LLM · {acceleration}'**
  String llmRoute(String acceleration);

  /// No description provided for @ttsRoute.
  ///
  /// In en, this message translates to:
  /// **'TTS · {acceleration}'**
  String ttsRoute(String acceleration);

  /// No description provided for @live2dScriptFailed.
  ///
  /// In en, this message translates to:
  /// **'Live2D script error: {error}'**
  String live2dScriptFailed(String error);

  /// No description provided for @live2dRuntimeFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to start the Live2D runtime: {error}'**
  String live2dRuntimeFailed(String error);

  /// No description provided for @live2dLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to load Live2D'**
  String get live2dLoadFailed;

  /// No description provided for @live2dInvalidStatus.
  ///
  /// In en, this message translates to:
  /// **'Live2D returned an invalid status'**
  String get live2dInvalidStatus;

  /// No description provided for @diagnosticsInvalidJson.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics result is not a JSON object'**
  String get diagnosticsInvalidJson;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
