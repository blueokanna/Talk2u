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
  String get cameraObservationStart => 'Enable gaze following';

  @override
  String get cameraObservationStop => 'Stop camera observation';

  @override
  String get cameraObservationDescription =>
      'The front camera detects face positions on this device so the character can look toward you. Images are neither saved nor uploaded. Photos may trigger face detection; it cannot verify a real person or liveness. Leaving this screen or putting the app in the background closes the camera.';

  @override
  String get cameraObservationEnable => 'Enable camera';

  @override
  String get cameraObservationStarting => 'Starting camera';

  @override
  String get cameraObservationSearching => 'Camera on · looking for a face';

  @override
  String get cameraObservationDetected => 'Face detected · following gaze';

  @override
  String get cameraObservationDenied =>
      'Camera permission was not granted. Allow it in system settings and try again.';

  @override
  String get cameraObservationUnsupported =>
      'This device does not provide usable front-camera hardware face detection.';

  @override
  String get cameraObservationFailed =>
      'The camera is unavailable. Close other apps using it and try again.';

  @override
  String get cameraObservationRestart =>
      'The camera is off. Tap to start it again.';

  @override
  String get cameraObservationClose => 'Close';

  @override
  String pauseDownloadFailed(String error) {
    return 'Could not pause the download: $error';
  }

  @override
  String get qwenCapabilitiesFailed =>
      'Could not check the Qwen3 QAIRT/NPU model state. Try again.';

  @override
  String get qwenImportFailed =>
      'The on-device model import failed. The previously installed model is unchanged.';

  @override
  String get qwenImportCancelled =>
      'The on-device model import was cancelled. The previously installed model is unchanged.';

  @override
  String get qwenLoadFailed =>
      'The Qwen3 QAIRT/NPU model failed to load. Try again.';

  @override
  String get qwenGenerateFailed =>
      'On-device Qwen3 generation failed. Try again.';

  @override
  String get unknownError => 'The operation failed. Try again.';

  @override
  String get mossErrorRuntime =>
      'The Qualcomm QNN HTP runtime required by MOSS is unavailable.';

  @override
  String get mossErrorInit =>
      'MOSS QNN initialization failed. Try again or re-import the deployment package.';

  @override
  String get mossErrorModelMissing =>
      'The MOSS QNN HTP v81 deployment package is not installed.';

  @override
  String get mossErrorSynthesis => 'MOSS speech synthesis failed. Try again.';

  @override
  String get mossErrorImport =>
      'The MOSS deployment package could not be imported. Check the files and hashes.';

  @override
  String get mossErrorImportBusy =>
      'Another MOSS import is already running. Wait for it to finish.';

  @override
  String get mossCancelled => 'The MOSS operation was cancelled.';

  @override
  String get mossErrorDelete =>
      'The MOSS deployment package could not be deleted. Try again.';

  @override
  String get senseVoiceErrorCheck =>
      'Could not check the SenseVoice model. Try again.';

  @override
  String get senseVoiceErrorRecognition =>
      'SenseVoice recognition failed. Try again or reinstall the model.';

  @override
  String get senseVoiceErrorDownload =>
      'The SenseVoice download was interrupted. Try again; partial data is kept.';

  @override
  String get senseVoiceErrorRecording =>
      'Microphone recording failed. Check the permission and whether another app is using it.';

  @override
  String get senseVoiceErrorImport =>
      'The SenseVoice model could not be imported. Check the ZIP file.';

  @override
  String get senseVoiceCancelled => 'The SenseVoice operation was cancelled.';

  @override
  String get live2dDesktopHostMissing =>
      'The desktop Live2D host is not installed: assets/live2d/index.html and a licensed Cubism Core for Web are missing. Add them as described in the README and rebuild; Android is unaffected.';

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
  String get languageChinese => 'Chinese';

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
  String mossPackageMissing(String size) {
    return 'Not installed · the package is about $size from your model source';
  }

  @override
  String get mossRuntimeReady => 'MOSS QNN HTP initialized';

  @override
  String get mossChooseDirectory =>
      'Choose the directory containing moss-qnn-deployment.json';

  @override
  String get mossChooseZip => 'Choose the moss-qnn-v81-streaming.zip file';

  @override
  String get mossImporting => 'Importing the model';

  @override
  String get mossImportedInitialized =>
      'MOSS QNN HTP model imported and initialized';

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
  String get live2dDiagnosticsAutoRefresh =>
      'Refreshes every second; no need to reopen';

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
  String get installQwen => 'Install on-device model';

  @override
  String get qwenPresetHub => 'Qualcomm AI Hub bundle available';

  @override
  String get qwenPresetImportOnly =>
      'No published bundle; import QAIRT or Q4_0/Q8_0 GGUF';

  @override
  String get qwenPresetInstalled => 'Installed';

  @override
  String get cancelDownload => 'Cancel import';

  @override
  String get importQwenBundle => 'Import QAIRT bundle (NPU)';

  @override
  String get importQwenGguf => 'Import GGUF (NPU)';

  @override
  String get qwenAccelNpu => 'Qualcomm QNN HTP/NPU (verified)';

  @override
  String get qwenAccelGpu => 'Adreno GPU via llama.cpp OpenCL (verified)';

  @override
  String get qwenAccelCpu => 'CPU — no accelerator for this artifact';

  @override
  String get qwenAccelPending =>
      'Accelerator loaded; verified after the first completed reply';

  @override
  String get qwenAccelNotLoaded =>
      'Model installed; the accelerator is not loaded yet';

  @override
  String get qwenImportedNotDetected =>
      'The model was copied but the runtime does not detect it';

  @override
  String get qwenImportCancelledDetail =>
      'Import cancelled. The previously installed model is unchanged.';

  @override
  String qwenImportFailedDetail(String raw) {
    return '$raw\nNothing was replaced.';
  }

  @override
  String qwenGgufQuantizationUnsupported(String quantization) {
    return '$quantization leaves tensors on the CPU. Import a Q4_0 or Q8_0 GGUF instead; the current file was not replaced.';
  }

  @override
  String qwenInstallFirst(String model) {
    return 'Import the $model model first';
  }

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
      'Import a QAIRT bundle, or a GGUF. GGUF runs on the Hexagon NPU first; if the NPU session cannot start, the app falls back to CPU and says so';

  @override
  String qwenModelReady(String license, String size) {
    return 'Ready · $license · $size';
  }

  @override
  String qwenModelPackage(String license) {
    return '$license · abliterated Qwen3-4B · QAIRT (NPU) or GGUF (NPU/GPU)';
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
  String get autoReadReplies => 'Auto-read replies';

  @override
  String get autoReadRepliesSubtitle =>
      'Synthesise each sentence while the reply is still streaming';

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
  String get callFullDuplex => 'Hands-free · hardware AEC (interrupt anytime)';

  @override
  String get callHalfDuplex =>
      'Hands-free · half duplex (mic paused during playback)';

  @override
  String get diagnosticsInvalidJson =>
      'Diagnostics result is not a JSON object';

  @override
  String get micPermissionDenied => 'Microphone permission was not granted';

  @override
  String get currentOnlinePlatform => 'the current online platform';

  @override
  String get offlineProviderName => 'On-device AI';

  @override
  String mossPackageIncomplete(String files) {
    return 'The deployment package is incomplete or damaged. Check: $files';
  }

  @override
  String get live2dImportFailed =>
      'Live2D model import failed. Check the ZIP file.';

  @override
  String get requestRejected => 'The on-device runtime rejected the request.';

  @override
  String get mossImportClosed =>
      'The MOSS import was cancelled because the page was closed.';

  @override
  String get captureReleased => 'Audio capture has been released';

  @override
  String get live2dImportUnsupported =>
      'Importing Live2D ZIP files is not supported on this platform';

  @override
  String get live2dNativeListMissing =>
      'The native layer returned no Live2D model list';

  @override
  String get live2dBuiltinPathMissing =>
      'The native layer returned no bundled Live2D model path';

  @override
  String get live2dZipNotFound => 'ZIP file not found';

  @override
  String live2dZipTooLarge(int limitMb) {
    return 'Live2D ZIP exceeds the $limitMb MB import limit';
  }

  @override
  String get live2dZipEmpty => 'ZIP file is empty or malformed';

  @override
  String get live2dZipTooManyEntries => 'ZIP file contains too many entries';

  @override
  String live2dUnpackedTooLarge(int limitMb) {
    return 'Unpacked model exceeds the $limitMb MB limit';
  }

  @override
  String live2dZipUnsafeEntry(String entry) {
    return 'ZIP contains an out-of-bounds path: $entry';
  }

  @override
  String live2dZipUnsupportedLink(String entry) {
    return 'ZIP contains an unsupported link entry: $entry';
  }

  @override
  String get live2dZipNoModelJson => 'ZIP contains no .model3.json';

  @override
  String live2dZipAbsolutePath(String name) {
    return 'ZIP contains an absolute path: $name';
  }

  @override
  String live2dZipUnsafePath(String name) {
    return 'ZIP contains an unsafe path: $name';
  }

  @override
  String get live2dModelJsonNotObject => 'model3.json is not a JSON object';

  @override
  String get live2dModelJsonVersion =>
      'Only Cubism .model3.json Version 3 is supported';

  @override
  String get live2dModelJsonFileReferences =>
      'model3.json is missing FileReferences';

  @override
  String get live2dModelJsonMoc => 'model3.json has no Moc file reference';

  @override
  String get live2dModelJsonNoTextures =>
      'model3.json has no texture references';

  @override
  String get live2dTextureReferenceInvalid => 'Texture reference is malformed';

  @override
  String live2dMocInvalid(String file) {
    return '$file is not a valid moc3 file';
  }

  @override
  String live2dMocVersionUnsupported(String version) {
    return 'Cubism Core does not support moc3 version $version';
  }

  @override
  String get live2dCdi3Version => 'cdi3.json Version must be 3';

  @override
  String live2dReferenceRemote(String ref) {
    return 'Model references a non-local resource: $ref';
  }

  @override
  String live2dReferenceTraversal(String ref) {
    return 'Model reference escapes the model directory: $ref';
  }

  @override
  String live2dReferenceConflict(String ref) {
    return 'Model resource is missing or has a case conflict: $ref';
  }

  @override
  String live2dReferenceInvalid(String ref) {
    return 'Model reference path is invalid: $ref';
  }

  @override
  String live2dReferenceMissing(String ref) {
    return 'Model resource is missing: $ref';
  }

  @override
  String senseVoiceCheckFailed(String error) {
    return 'Unable to inspect the on-device recognition models: $error';
  }

  @override
  String get senseVoiceUnsupported =>
      'On-device speech recognition is not supported on this platform';

  @override
  String get senseVoiceModelIncomplete =>
      'SenseVoice model files are incomplete';

  @override
  String get senseVoiceImportIncomplete => 'SenseVoice import did not finish';

  @override
  String get voiceDownloadRangeInvalid => 'Voice model resume range is invalid';

  @override
  String voiceDownloadHttp(int status) {
    return 'Voice model download returned HTTP $status';
  }

  @override
  String get voiceDownloadTruncated =>
      'Voice model connection closed early; waiting to resume';

  @override
  String get voiceDownloadChecksumFailed =>
      'Voice model SHA-256 verification failed';

  @override
  String get voiceDownloadSourcesUnavailable =>
      'No voice model download source is reachable';

  @override
  String get voiceArchiveDirInvalid =>
      'Speech model archive directory is invalid';

  @override
  String get senseVoiceContextIncomplete =>
      'SenseVoice QNN context files are incomplete';

  @override
  String get voiceDownloadCancelled => 'Voice model download cancelled';

  @override
  String get speechStopFirst => 'Stop speech recognition first';

  @override
  String get senseVoiceNotInstalled =>
      'Download the SenseVoice offline model first';

  @override
  String get senseVoiceInstallFirst =>
      'Install the SenseVoice on-device recognition model first';

  @override
  String micStopFailed(String error) {
    return 'Unable to stop microphone recording: $error';
  }

  @override
  String get senseVoiceNoResult =>
      'SenseVoice QNN returned no recognition result';

  @override
  String get offlineGenerationStopped => 'On-device generation stopped';

  @override
  String get qnnAccelVerified => 'Qualcomm QNN HTP/NPU (verified)';

  @override
  String get qnnAccelLoadedPending =>
      'Qualcomm QNN HTP/NPU loaded, awaiting first-run verification';

  @override
  String get geniexNotLoaded => 'GenieX QAIRT/NPU not loaded yet';

  @override
  String get geniexNotInstalled => 'GenieX QAIRT/NPU model is not installed';

  @override
  String qwenCapabilitiesCheckFailed(String model, String error) {
    return 'Unable to inspect the $model QAIRT/NPU model: $error';
  }

  @override
  String qwenAndroidOnly(String model) {
    return '$model QAIRT/NPU models are only supported on Android';
  }

  @override
  String get waitForCurrentReply =>
      'Wait for the current on-device reply to finish';

  @override
  String get geniexLoadResultMissing => 'GenieX returned no model load result';

  @override
  String get qwenBackendRejected =>
      'Refusing an on-device execution backend that reported no accelerator';

  @override
  String qwenLoadFailedDetail(String error) {
    return 'Qwen3 on-device model load failed: $error';
  }

  @override
  String get offlineModelBusy =>
      'The on-device model is still generating the previous reply';

  @override
  String get qwenEmptyResponse => 'Qwen3 QAIRT/NPU returned no text';

  @override
  String qwenGenerateFailedDetail(String error) {
    return 'Qwen3 QAIRT/NPU on-device generation failed: $error';
  }

  @override
  String get mossAccelInitialized => 'Qualcomm QNN HTP + ORT CPU · initialized';

  @override
  String get mossAccelInitializing => 'QNN HTP initializing';

  @override
  String get mossAccelCandidate => 'QNN HTP candidate · not yet verified';

  @override
  String mossRuntimeInitFailed(String error) {
    return 'Unable to initialize the MOSS QNN runtime automatically: $error';
  }

  @override
  String get mossRuntimeNotReady => 'The native MOSS runtime is not ready';

  @override
  String get mossImportAndroidOnly =>
      'Importing a MOSS QNN model is only supported on Android';

  @override
  String get mossZipImportAndroidOnly =>
      'Importing a MOSS QNN ZIP is only supported on Android';

  @override
  String get mossImportFirst =>
      'Import a MOSS QNN HTP v81 deployment package first';

  @override
  String get mossProviderMissing =>
      'MOSS-TTS-Nano returned no valid execution provider';

  @override
  String get mossNoAudio => 'MOSS-TTS-Nano produced no playable audio';

  @override
  String get mossAudioInvalid =>
      'The audio produced by MOSS-TTS-Nano is invalid';

  @override
  String get mossImportBusyWait =>
      'Wait for the current model import to finish';

  @override
  String get mossWavInvalid => 'MOSS-TTS-Nano produced an invalid WAV file';

  @override
  String get mossWavNotPcm => 'The MOSS WAV file is not PCM';

  @override
  String get mossWavPcmInvalid => 'The MOSS WAV PCM parameters are invalid';

  @override
  String get mossWavPcmTruncated => 'The MOSS WAV PCM data is incomplete';

  @override
  String editResendFailed(String error) {
    return 'Unable to resend the edited message: $error';
  }

  @override
  String get responseInterrupted =>
      'The AI response was interrupted. Tap retry.';

  @override
  String prepareChatFailed(String error) {
    return 'Unable to prepare the conversation: $error';
  }

  @override
  String get saveUserMessageFailed => 'Unable to save the user message';

  @override
  String get qwenModelMissingHint =>
      'Install the abliterated Qwen3-4B model (QAIRT bundle or GGUF) in Models & API first';

  @override
  String apiKeyMissingHint(String provider) {
    return '$provider has no API key configured, and no ready Qwen3-4B-Instruct-2507 QAIRT/NPU model was detected';
  }

  @override
  String get saveOfflineReplyFailed => 'Unable to save the on-device reply';

  @override
  String offlineGenerateFailed(String error) {
    return 'On-device generation failed: $error';
  }

  @override
  String stopGenerationFailed(String error) {
    return 'Unable to stop generation: $error';
  }
}
