// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Talk2U';

  @override
  String get settings => 'Settings';

  @override
  String get appearance => 'Appearance';

  @override
  String get themeMode => 'Theme';

  @override
  String get themeSystem => 'System';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get colorScheme => 'Color scheme';

  @override
  String get colorTeal => 'Teal';

  @override
  String get colorBlue => 'Blue';

  @override
  String get colorGreen => 'Green';

  @override
  String get colorRose => 'Rose';

  @override
  String get language => 'Language';

  @override
  String get languageSystem => 'System language';

  @override
  String get languageChinese => 'Simplified Chinese';

  @override
  String get languageEnglish => 'English';

  @override
  String get modelAndApi => 'Models and APIs';

  @override
  String get deviceAi => 'On-device AI';

  @override
  String get offlineRecognition => 'On-device speech recognition';

  @override
  String get mossSpeech => 'MOSS on-device speech';

  @override
  String get startupPreparing => 'Preparing local conversation...';

  @override
  String startupFailed(String error) {
    return 'Startup failed: $error';
  }

  @override
  String get rustCoreTimeout => 'Rust core initialization timed out';

  @override
  String get localDataTimeout => 'Local data initialization timed out';

  @override
  String get retry => 'Retry';

  @override
  String get live2dDiagnostics => 'Live2D performance';

  @override
  String get renderBackend => 'Actual backend';

  @override
  String get gpuDevice => 'GPU device';

  @override
  String get renderedFrames => 'Rendered frames';

  @override
  String get cpuUsage => 'CPU usage';

  @override
  String get gpuUsage => 'GPU usage';

  @override
  String get npuUsage => 'NPU usage';

  @override
  String get processScope => 'app process';

  @override
  String get deviceScope => 'device';

  @override
  String get usageUnavailable => 'Unavailable';

  @override
  String get gpuUsageUnavailable =>
      'Unavailable: the GPU utilization node is not readable by this app';

  @override
  String get npuUsageUnavailable =>
      'Unavailable: Android/QNN does not expose global NPU utilization';

  @override
  String npuRecentWorkload(String value) {
    return '$value% app HTP call duty over the last second';
  }

  @override
  String get close => 'Close';

  @override
  String diagnosticsFailed(String error) {
    return 'Unable to read Live2D performance: $error';
  }

  @override
  String percentValue(String value) {
    return '$value%';
  }

  @override
  String get live2dDiagnosticsTooltip => 'Live2D performance';

  @override
  String get reloadLive2d => 'Reload Live2D';

  @override
  String get currentPlatformUnavailable =>
      'Live2D is unavailable on this platform';

  @override
  String get mossRuntimeUnavailable => 'QNN HTP unavailable';

  @override
  String get senseVoiceQnnUnsupported => 'QNN HTP · ASR / LID / SER / AED';

  @override
  String get platform => 'Provider';

  @override
  String get showSecret => 'Show API key';

  @override
  String get hideSecret => 'Hide API key';

  @override
  String get apiKeyRequired => 'Enter an API key';

  @override
  String get apiUrl => 'API URL';

  @override
  String get validHttpUrlRequired => 'Enter a complete HTTP(S) URL';

  @override
  String get chatModelId => 'Chat model ID';

  @override
  String get modelIdRequired => 'Enter a model ID';

  @override
  String get reasoningModelId => 'Reasoning model ID (optional)';

  @override
  String get maxOutputTokens => 'Maximum output tokens';

  @override
  String get tokenRangeError => 'Enter an integer from 1 to 131072';

  @override
  String get enableReasoningByDefault => 'Enable reasoning by default';

  @override
  String get reasoningRequiresModel =>
      'Only applies when a reasoning model is configured for this provider';

  @override
  String get saveConfiguration => 'Save configuration';

  @override
  String get testConnection => 'Test connection';

  @override
  String get manageModel => 'Manage on-device model';

  @override
  String get deleteModel => 'Delete model';

  @override
  String get installQwen => 'Download Qwen3-4B-Instruct-2507 model';

  @override
  String get cancelDownload => 'Cancel download';

  @override
  String get deleteSenseVoice => 'Delete SenseVoice';

  @override
  String get downloadSenseVoice => 'Download SenseVoice';

  @override
  String get deleteMoss => 'Delete MOSS-TTS-Nano';

  @override
  String get importMoss => 'Import MOSS QNN HTP deployment';

  @override
  String get importMossZip => 'Import from ZIP file';

  @override
  String get importMossDir => 'Import from extracted directory';

  @override
  String get importSherpaZip => 'Import from local ZIP file';

  @override
  String get downloadFromInternet => 'Download from internet';

  @override
  String get mossVoice => 'MOSS built-in cloned voice';

  @override
  String get stopPreview => 'Stop preview';

  @override
  String get previewVoice => 'Preview selected voice';

  @override
  String get mossPreviewText =>
      'Hello, it is good to meet you. What would you like to talk about today? I will listen carefully and respond naturally.';

  @override
  String qwenReady(String acceleration) {
    return 'Ready · $acceleration';
  }

  @override
  String get qwenInstallHint =>
      'No API required; GenieX downloads the chipset-matched QAIRT model bundle';

  @override
  String qwenModelReady(String license, String size) {
    return 'Ready · $license · $size';
  }

  @override
  String qwenModelPackage(String license) {
    return '$license · QAIRT · Qualcomm QNN HTP/NPU';
  }

  @override
  String get loadingModel => 'Loading model...';

  @override
  String get senseVoiceReady => 'Ready · SM8850 QNN HTP · fully offline';

  @override
  String get senseVoiceSize => 'About 154.5 MiB · SenseVoice INT8 · SM8850 QNN';

  @override
  String get mossGenerating => 'Running on-device speech inference';

  @override
  String get mossInitializing => 'Initializing QNN HTP contexts';

  @override
  String mossReady(String acceleration) {
    return 'Ready · $acceleration · 48 kHz · Chinese/English/Japanese';
  }

  @override
  String loadSettingsFailed(String error) {
    return 'Unable to load settings: $error';
  }

  @override
  String get settingsWriteFailed => 'Unable to write the settings file';

  @override
  String providerSaved(String provider) {
    return 'Saved $provider';
  }

  @override
  String saveFailed(String error) {
    return 'Save failed: $error';
  }

  @override
  String connectionTestFailed(String error) {
    return 'Connection test failed: $error';
  }

  @override
  String get qwenInstalled =>
      'Qwen3-4B-Instruct-2507 model installed and verified';

  @override
  String qwenInstallFailed(String error) {
    return 'Qwen3 deployment installation failed: $error';
  }

  @override
  String get offlineModelDeleted => 'On-device AI model deleted';

  @override
  String offlineModelDeleteFailed(String error) {
    return 'Unable to delete the on-device AI model: $error';
  }

  @override
  String get senseVoiceInstalled => 'SenseVoice offline model installed';

  @override
  String senseVoiceInstallFailed(String error) {
    return 'SenseVoice download failed: $error';
  }

  @override
  String get mossImported => 'MOSS QNN HTP deployment imported and verified';

  @override
  String mossImportFailed(String error) {
    return 'MOSS QNN deployment import failed: $error';
  }

  @override
  String get mossDeleted => 'MOSS-TTS-Nano model deleted';

  @override
  String mossDeleteFailed(String error) {
    return 'Unable to delete MOSS-TTS-Nano: $error';
  }

  @override
  String get mossVoiceChanged => 'MOSS voice changed';

  @override
  String mossVoiceChangeFailed(String error) {
    return 'Unable to change the MOSS voice: $error';
  }

  @override
  String mossPreviewFailed(String error) {
    return 'MOSS-TTS-Nano preview failed: $error';
  }

  @override
  String get cancel => 'Cancel';

  @override
  String get delete => 'Delete';

  @override
  String get edit => 'Edit';

  @override
  String get send => 'Send';

  @override
  String get copy => 'Copy';

  @override
  String get copied => 'Copied to clipboard';

  @override
  String get regenerate => 'Regenerate';

  @override
  String get rewrite => 'Rewrite';

  @override
  String get rollback => 'Roll back';

  @override
  String get editAndResend => 'Edit and resend';

  @override
  String get deleteMessage => 'Delete message';

  @override
  String get deleteMessageConfirm => 'Delete this message?';

  @override
  String get rollbackConversation => 'Roll back conversation';

  @override
  String get rollbackConversationConfirm =>
      'This message and every later message will be deleted, along with related memory. Continue?';

  @override
  String get thinking => 'Thinking';

  @override
  String get thinkingProcess => 'Reasoning';

  @override
  String get editMessageHint => 'Edit message...';

  @override
  String get typing => 'Typing...';

  @override
  String get emptyReply => '(empty reply)';

  @override
  String get offlineVoiceInput => 'Offline voice input';

  @override
  String get offlineVoiceUnavailable =>
      'No offline recognition engine is available';

  @override
  String get aiResponding => 'AI is responding...';

  @override
  String get messageHint => 'Type a message...';

  @override
  String get stopGenerating => 'Stop generating';

  @override
  String get conversations => 'Conversations';

  @override
  String get newConversation => 'New';

  @override
  String get noConversations => 'No conversations';

  @override
  String get startConversationHint => 'Create one to start chatting';

  @override
  String get untitledConversation => 'Untitled conversation';

  @override
  String get deleteConversation => 'Delete conversation';

  @override
  String get deleteConversationConfirm =>
      'Delete this conversation? This cannot be undone.';

  @override
  String get justNow => 'Just now';

  @override
  String minutesAgo(int count) {
    return '$count min ago';
  }

  @override
  String daysAgo(int count) {
    return '$count days ago';
  }

  @override
  String get charactersTitle => 'My characters';

  @override
  String get deleteCharacter => 'Delete character';

  @override
  String deleteCharacterConfirm(String name) {
    return 'Delete \"$name\"? This cannot be undone.';
  }

  @override
  String charactersImported(int count) {
    return 'Imported $count characters';
  }

  @override
  String get characterImportFailed => 'Import failed. Check the file format.';

  @override
  String exportFailed(String error) {
    return 'Export failed: $error';
  }

  @override
  String shareCharacter(String name) {
    return 'Character profile: $name';
  }

  @override
  String get shareAllCharacters => 'All character profiles';

  @override
  String get importCharacters => 'Import characters';

  @override
  String get exportAll => 'Export all';

  @override
  String get export => 'Export';

  @override
  String get createCharacter => 'Create character';

  @override
  String get editCharacter => 'Edit character';

  @override
  String get regularAssistant => 'Standard assistant';

  @override
  String get directChat => 'Start chatting without creating a character';

  @override
  String get noCharacterSettings => 'Do not use a character profile';

  @override
  String characterSaveFailed(String error) {
    return 'Unable to save character: $error';
  }

  @override
  String live2dModelsImported(int count) {
    return 'Live2D model imported; found $count models';
  }

  @override
  String live2dModelImportFailed(String error) {
    return 'Unable to import Live2D model: $error';
  }

  @override
  String get chooseLive2dModel => 'Choose a Live2D model';

  @override
  String get maoLicenseTitle => 'Use the bundled Mao sample model';

  @override
  String get maoLicenseDescription =>
      'This model is provided by Live2D Inc. You must accept the Cubism sample-model license before using it. model/Live2d/mao/ReadMe.txt contains its source and license details.';

  @override
  String get licenseAccepted => 'I have read and agree';

  @override
  String get maoInstalled => 'Cubism 5 Mao model installed';

  @override
  String maoInstallFailed(String error) {
    return 'Unable to install the bundled model: $error';
  }

  @override
  String get characterName => 'Name';

  @override
  String get characterNameHint => 'Enter an AI nickname';

  @override
  String get characterNameRequired => 'Enter a character name';

  @override
  String get gender => 'Gender';

  @override
  String get genderMale => 'Male';

  @override
  String get genderFemale => 'Female';

  @override
  String get genderOther => 'Other';

  @override
  String get characterSetting => 'Character profile';

  @override
  String get characterSettingHelp =>
      'Describe the character\'s background, personality, identity, and relationship to you. This affects responses.';

  @override
  String get characterSettingHint =>
      'Describe personality, identity, and background';

  @override
  String get characterSettingRequired => 'Enter a character profile';

  @override
  String get characterDescription => 'Introduction';

  @override
  String get characterDescriptionHelp =>
      'A short introduction shown in the character list. It does not affect responses.';

  @override
  String get characterDescriptionHint => 'Introduce this character';

  @override
  String get characterGreeting => 'Opening message';

  @override
  String get characterGreetingHint => 'Enter an opening message';

  @override
  String get dialogueStyleExample => 'Dialogue style example';

  @override
  String get dialogueStyleHelp =>
      'Provide text that demonstrates how this character speaks.';

  @override
  String get dialogueStyleHint => 'Example of this character\'s speaking style';

  @override
  String get userName => 'User name';

  @override
  String get userNameHint => 'How the AI should address you';

  @override
  String get userPersona => 'User persona';

  @override
  String get userPersonaHelp =>
      'Describe the identity, personality, or history you play in this conversation.';

  @override
  String get userPersonaHint => 'Describe your role in the conversation';

  @override
  String get live2dModel => 'Live2D model';

  @override
  String get noLive2dModel => 'No Live2D ZIP model imported';

  @override
  String get importLive2dModel => 'Import Live2D ZIP model';

  @override
  String get installMaoModel => 'Install bundled Cubism 5 Mao model';

  @override
  String get tags => 'Tags';

  @override
  String get addTag => 'Add tag';

  @override
  String get tagNameHint => 'Enter a tag';

  @override
  String get confirm => 'Confirm';

  @override
  String offlineSttUnavailable(String error) {
    return 'On-device speech recognition unavailable: $error';
  }

  @override
  String get continuousCallRequiresSpeech =>
      'Continuous conversation requires working on-device speech recognition and synthesis';

  @override
  String continuousCallStartFailed(String error) {
    return 'Unable to start continuous conversation: $error';
  }

  @override
  String continuousCallStopped(String error) {
    return 'Continuous conversation stopped: $error';
  }

  @override
  String get noOfflineTtsVoice =>
      'No usable on-device TTS voice pack was found';

  @override
  String offlineTtsUnavailable(String error) {
    return 'On-device speech synthesis unavailable: $error';
  }

  @override
  String get restart => 'Restart';

  @override
  String get restartConversationSubtitle =>
      'Clear messages while keeping the character profile and opening message';

  @override
  String get conversationStyle => 'Conversation style';

  @override
  String get styleFree => 'Free';

  @override
  String get styleDialogue => 'Dialogue only';

  @override
  String get styleAction => 'Action only';

  @override
  String get styleMixed => 'Mixed (automatic)';

  @override
  String get providerAndModel => 'Provider and model';

  @override
  String get apiProvider => 'API provider';

  @override
  String providerNotConfigured(String provider) {
    return '$provider (not configured)';
  }

  @override
  String get notConfigured => 'Not configured';

  @override
  String get chatModel => 'Chat model';

  @override
  String get reasoningModelHint =>
      'Reasoning model; enables the reasoning pipeline automatically';

  @override
  String get restartStory => 'Restart story';

  @override
  String get restartStoryConfirm =>
      'Restart the story? All messages will be cleared, while the character profile and opening message are kept.';

  @override
  String get stopReading => 'Stop reading';

  @override
  String get readLastReply => 'Read the last reply on device';

  @override
  String get noOfflineTtsPack => 'No on-device TTS voice pack';

  @override
  String get characterList => 'Characters';

  @override
  String get settingsSubtitle => 'API keys and model configuration';

  @override
  String get hideConversation => 'Hide conversation';

  @override
  String get showConversation => 'Show conversation';

  @override
  String get endContinuousCall => 'End continuous conversation';

  @override
  String get startContinuousCall => 'Start continuous conversation';

  @override
  String get conversation => 'Conversation';

  @override
  String get startNewConversation => 'Start a new conversation';

  @override
  String get startNewConversationHint => 'Type a message or choose a character';

  @override
  String get chooseCharacter => 'Choose character';

  @override
  String llmRoute(String acceleration) {
    return 'LLM · $acceleration';
  }

  @override
  String ttsRoute(String acceleration) {
    return 'TTS · $acceleration';
  }

  @override
  String live2dScriptFailed(String error) {
    return 'Live2D script error: $error';
  }

  @override
  String live2dRuntimeFailed(String error) {
    return 'Unable to start the Live2D runtime: $error';
  }

  @override
  String get live2dLoadFailed => 'Unable to load Live2D';

  @override
  String get live2dInvalidStatus => 'Live2D returned an invalid status';

  @override
  String get diagnosticsInvalidJson =>
      'Diagnostics result is not a JSON object';
}
