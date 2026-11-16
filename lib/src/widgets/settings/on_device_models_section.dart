import 'package:flutter/material.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/l10n/service_error_text.dart';
import 'package:talk2u/src/services/moss_tts_service.dart';
import 'package:talk2u/src/services/offline_llm_service.dart';
import 'package:talk2u/src/services/sherpa_speech_service.dart';

/// On-device model management: Qwen QAIRT, SenseVoice, MOSS-TTS.
///
/// Extracted from the settings page so that page owns navigation and form
/// state, while each model card owns its own service listenable and actions.
class OnDeviceModelsSection extends StatelessWidget {
  const OnDeviceModelsSection({
    super.key,
    required this.onDownloadQwen,
    required this.onCancelQwenDownload,
    required this.onDeleteQwen,
    required this.onImportSenseVoiceZip,
    required this.onDownloadSenseVoice,
    required this.onDeleteMoss,
    required this.onImportMossZip,
    required this.onImportMossDir,
    required this.onSelectMossVoice,
    required this.onPreviewMossVoice,
  });

  final VoidCallback onDownloadQwen;
  final VoidCallback onCancelQwenDownload;
  final VoidCallback onDeleteQwen;
  final VoidCallback onImportSenseVoiceZip;
  final VoidCallback onDownloadSenseVoice;
  final VoidCallback onDeleteMoss;
  final VoidCallback onImportMossZip;
  final VoidCallback onImportMossDir;
  final ValueChanged<String?> onSelectMossVoice;
  final VoidCallback onPreviewMossVoice;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (OfflineLlmService.instance.supported) ...[
          Text(
            strings.deviceAi,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          _QwenModelCard(
            onDownload: onDownloadQwen,
            onCancelDownload: onCancelQwenDownload,
            onDelete: onDeleteQwen,
          ),
          const SizedBox(height: 24),
        ],
        if (SherpaSpeechService.instance.supported) ...[
          Text(
            strings.offlineRecognition,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          _SenseVoiceModelCard(
            onImportZip: onImportSenseVoiceZip,
            onDownload: onDownloadSenseVoice,
          ),
          const SizedBox(height: 24),
        ],
        if (MossTtsService.instance.supported) ...[
          Text(
            strings.mossSpeech,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          _MossModelCard(
            onDelete: onDeleteMoss,
            onImportZip: onImportMossZip,
            onImportDir: onImportMossDir,
            onSelectVoice: onSelectMossVoice,
            onPreview: onPreviewMossVoice,
          ),
          const SizedBox(height: 24),
        ],
      ],
    );
  }
}

class _QwenModelCard extends StatelessWidget {
  const _QwenModelCard({
    required this.onDownload,
    required this.onCancelDownload,
    required this.onDelete,
  });

  final VoidCallback onDownload;
  final VoidCallback onCancelDownload;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return AnimatedBuilder(
      animation: OfflineLlmService.instance,
      builder: (context, _) {
        final llm = OfflineLlmService.instance;
        final progress = (llm.downloadProgress * 100).round();
        final rate = llm.downloadBytesPerSecond;
        final eta = llm.downloadEta;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                llm.modelReady
                    ? Icons.offline_bolt_outlined
                    : Icons.download_for_offline_outlined,
              ),
              title: const Text(OfflineLlmService.modelName),
              subtitle: Text(
                llm.downloading
                    ? '${_formatBytes(llm.downloadedBytes)} / '
                          '${_formatBytes(llm.totalDownloadBytes)} ($progress%)'
                          '${rate > 0 ? " · ${_formatBytes(rate.round())}/s" : ""}'
                          '${eta != null ? " · ${_formatEta(eta)}" : ""}'
                    : llm.loadingModel
                    ? strings.loadingModel
                    : llm.modelReady
                    ? strings.qwenModelReady(
                        OfflineLlmService.modelLicense,
                        llm.accelerationDescription,
                      )
                    : strings.qwenModelPackage(OfflineLlmService.modelLicense),
              ),
              trailing: llm.downloading
                  ? IconButton(
                      tooltip: strings.cancelDownload,
                      onPressed: onCancelDownload,
                      icon: const Icon(Icons.pause_circle_outline),
                    )
                  : llm.modelReady
                  ? PopupMenuButton<String>(
                      tooltip: strings.manageModel,
                      onSelected: (value) {
                        if (value == 'delete') onDelete();
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(strings.deleteModel),
                        ),
                      ],
                    )
                  : IconButton(
                      tooltip: strings.installQwen,
                      onPressed: onDownload,
                      icon: const Icon(Icons.download_outlined),
                    ),
            ),
            if (llm.downloading)
              LinearProgressIndicator(value: llm.downloadProgress),
            if (llm.lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                serviceErrorText(
                  strings,
                  code: llm.lastErrorCode,
                  fallback: llm.lastError,
                ),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _SenseVoiceModelCard extends StatelessWidget {
  const _SenseVoiceModelCard({
    required this.onImportZip,
    required this.onDownload,
  });

  final VoidCallback onImportZip;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return AnimatedBuilder(
      animation: SherpaSpeechService.instance,
      builder: (context, _) {
        final sherpa = SherpaSpeechService.instance;
        return Column(
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                sherpa.asrReady
                    ? Icons.mic_outlined
                    : Icons.download_for_offline_outlined,
              ),
              title: const Text(SherpaSpeechService.asrModelName),
              subtitle: Text(
                sherpa.downloading && sherpa.asrDownloading
                    ? '${_formatBytes(sherpa.downloadedBytes)} / '
                          '${_formatBytes(sherpa.totalDownloadBytes)}'
                    : sherpa.asrReady
                    ? '${strings.senseVoiceReady}\n'
                          '${strings.senseVoiceQnnUnsupported}'
                    : strings.senseVoiceSize,
              ),
              trailing: sherpa.downloading
                  ? IconButton(
                      tooltip: strings.cancelDownload,
                      onPressed: sherpa.cancelDownload,
                      icon: const Icon(Icons.stop_circle_outlined),
                    )
                  : sherpa.asrReady
                  ? IconButton(
                      tooltip: strings.deleteSenseVoice,
                      onPressed: sherpa.deleteAsr,
                      icon: const Icon(Icons.delete_outline),
                    )
                  : PopupMenuButton<String>(
                      tooltip: strings.downloadSenseVoice,
                      onSelected: (value) {
                        if (value == 'zip') {
                          onImportZip();
                        } else if (value == 'download') {
                          onDownload();
                        }
                      },
                      icon: const Icon(Icons.download_outlined),
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: 'zip',
                          child: Text(strings.importSherpaZip),
                        ),
                        PopupMenuItem(
                          value: 'download',
                          child: Text(strings.downloadFromInternet),
                        ),
                      ],
                    ),
            ),
            if (sherpa.downloading)
              LinearProgressIndicator(value: sherpa.downloadProgress),
            if (sherpa.extracting) const LinearProgressIndicator(),
            if (sherpa.lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                serviceErrorText(
                  strings,
                  code: sherpa.lastErrorCode,
                  fallback: sherpa.lastError,
                ),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _MossModelCard extends StatelessWidget {
  const _MossModelCard({
    required this.onDelete,
    required this.onImportZip,
    required this.onImportDir,
    required this.onSelectVoice,
    required this.onPreview,
  });

  final VoidCallback onDelete;
  final VoidCallback onImportZip;
  final VoidCallback onImportDir;
  final ValueChanged<String?> onSelectVoice;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return AnimatedBuilder(
      animation: MossTtsService.instance,
      builder: (context, _) {
        final moss = MossTtsService.instance;
        final busy = moss.downloading || moss.initializing;
        final status = moss.downloading
            ? moss.totalDownloadBytes > 0
                  ? '${mossOperationText(strings, moss.operation)}\n'
                        '${_formatBytes(moss.downloadedBytes)} / '
                        '${_formatBytes(moss.totalDownloadBytes)}'
                  : mossOperationText(strings, moss.operation)
            : moss.initializing
            ? strings.mossInitializing
            : moss.generating
            ? strings.mossGenerating
            : moss.ready
            ? '${_formatBytes(moss.downloadedBytes)} · '
                  '${moss.accelerationLabel}'
            : strings.mossPackageMissing(
                _formatBytes(MossTtsService.estimatedModelBytes),
              );
        final previewing = moss.generating || moss.speaking;
        return Column(
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: Icon(
                  busy
                      ? Icons.memory_outlined
                      : moss.ready
                      ? Icons.record_voice_over_outlined
                      : Icons.folder_open_outlined,
                  key: ValueKey((busy, moss.ready)),
                ),
              ),
              title: const Text(MossTtsService.modelName),
              subtitle: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(status, key: ValueKey(status)),
              ),
              trailing: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: busy
                    ? const SizedBox.square(
                        key: ValueKey('moss-busy'),
                        dimension: 48,
                        child: Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : moss.ready
                    ? IconButton(
                        key: const ValueKey('moss-delete'),
                        tooltip: strings.deleteMoss,
                        onPressed: onDelete,
                        icon: const Icon(Icons.delete_outline),
                      )
                    : PopupMenuButton<String>(
                        key: const ValueKey('moss-import'),
                        tooltip: strings.importMoss,
                        onSelected: (value) {
                          if (value == 'zip') {
                            onImportZip();
                          } else if (value == 'dir') {
                            onImportDir();
                          }
                        },
                        icon: const Icon(Icons.folder_open_outlined),
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'zip',
                            child: Text(strings.importMossZip),
                          ),
                          PopupMenuItem(
                            value: 'dir',
                            child: Text(strings.importMossDir),
                          ),
                        ],
                      ),
              ),
            ),
            if (moss.ready)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: ValueKey(moss.voiceId),
                        initialValue: moss.voiceId,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: strings.mossVoice,
                          prefixIcon: const Icon(Icons.record_voice_over),
                          border: const OutlineInputBorder(),
                        ),
                        items: MossTtsService.voices
                            .map(
                              (voice) => DropdownMenuItem(
                                value: voice.id,
                                child: Text(
                                  voice.displayLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(growable: false),
                        onChanged: previewing ? null : onSelectVoice,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: previewing
                          ? strings.stopPreview
                          : strings.previewVoice,
                      onPressed: previewing ? moss.stopSpeaking : onPreview,
                      icon: Icon(
                        previewing ? Icons.stop : Icons.volume_up_outlined,
                      ),
                    ),
                  ],
                ),
              ),
            AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOutCubic,
              child: busy || moss.generating
                  ? LinearProgressIndicator(
                      key: ValueKey(
                        moss.downloading ? 'moss-import' : 'moss-work',
                      ),
                      value: moss.downloading ? moss.downloadProgress : null,
                    )
                  : const SizedBox.shrink(),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: moss.lastError == null
                  ? const SizedBox.shrink()
                  : Padding(
                      key: ValueKey(moss.lastError),
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        serviceErrorText(
                          strings,
                          code: moss.lastErrorCode,
                          fallback: moss.lastError,
                        ),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

String mossOperationText(AppLocalizations strings, MossOperation operation) {
  return switch (operation) {
    MossOperation.idle => '',
    MossOperation.initializingRuntime => strings.mossInitializing,
    MossOperation.runtimeReady => strings.mossRuntimeReady,
    MossOperation.chooseDirectory => strings.mossChooseDirectory,
    MossOperation.chooseZip => strings.mossChooseZip,
    MossOperation.importing => strings.mossImporting,
    MossOperation.imported => strings.mossImported,
    MossOperation.importedAndInitialized => strings.mossImportedInitialized,
  };
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}

String _formatEta(Duration duration) {
  if (duration.inHours > 0) {
    return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
  }
  if (duration.inMinutes > 0) {
    return '${duration.inMinutes}m ${duration.inSeconds.remainder(60)}s';
  }
  return '${duration.inSeconds}s';
}
