import 'package:talk2u/l10n/generated/app_localizations.dart';

/// Maps stable service error codes to localized text.
///
/// Raw native messages are kept as a fallback for unknown codes, but every code
/// we emit ourselves must be translated. English UI therefore never leaks our
/// own Chinese error strings; unknown native detail is still shown verbatim.
String serviceErrorText(
  AppLocalizations strings, {
  String? code,
  String? fallback,
}) {
  final mapped = switch (code) {
    'qwen3_capabilities_failed' => strings.qwenCapabilitiesFailed,
    'qwen3_import_failed' ||
    'qwen3_import_picker_failed' => strings.qwenImportFailed,
    'qwen3_import_cancelled' => strings.qwenImportCancelled,
    'qwen3_import_busy' => strings.offlineModelBusy,
    'qwen3_load_failed' => strings.qwenLoadFailed,
    'qwen3_generate_failed' => strings.qwenGenerateFailed,
    'moss_runtime_unavailable' ||
    'moss_provider_probe_failed' => strings.mossErrorRuntime,
    'moss_initialization_failed' => strings.mossErrorInit,
    'moss_model_missing' => strings.mossErrorModelMissing,
    'moss_synthesis_failed' => strings.mossErrorSynthesis,
    'moss_import_failed' ||
    'moss_import_picker_failed' => strings.mossErrorImport,
    'moss_package_incomplete' =>
      fallback == null || fallback.trim().isEmpty
          ? strings.mossErrorImport
          : strings.mossPackageIncomplete(fallback.trim()),
    'moss_import_busy' => strings.mossErrorImportBusy,
    'activity_destroyed' => strings.mossImportClosed,
    'moss_cancelled' || 'moss_import_cancelled' => strings.mossCancelled,
    'moss_delete_failed' => strings.mossErrorDelete,
    'sensevoice_capabilities_failed' => strings.senseVoiceErrorCheck,
    'sensevoice_load_failed' ||
    'sensevoice_recognition_failed' => strings.senseVoiceErrorRecognition,
    'sensevoice_download_failed' => strings.senseVoiceErrorDownload,
    'sensevoice_recording_failed' => strings.senseVoiceErrorRecording,
    'sherpa_import_failed' ||
    'sherpa_import_busy' ||
    'sherpa_import_picker_failed' => strings.senseVoiceErrorImport,
    'sherpa_import_cancelled' => strings.senseVoiceCancelled,
    'live2d_import_failed' => strings.live2dImportFailed,
    'invalid_archive' ||
    'invalid_moss_request' ||
    'invalid_moss_output_path' ||
    'invalid_sensevoice_path' ||
    'invalid_sensevoice_audio' ||
    'invalid_qwen3_messages' ||
    'invalid_qwen3_generation' => strings.requestRejected,
    _ => null,
  };
  if (mapped != null) return mapped;
  final detail = fallback?.trim() ?? '';
  return detail.isEmpty ? strings.unknownError : detail;
}
