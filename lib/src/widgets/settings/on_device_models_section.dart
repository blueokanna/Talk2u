import 'package:flutter/material.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/l10n/service_error_text.dart';
import 'package:talk2u/src/services/moss_tts_service.dart';
import 'package:talk2u/src/services/offline_llm_service.dart';
import 'package:talk2u/src/services/sherpa_speech_service.dart';
import 'package:talk2u/src/theme/app_motion.dart';
import 'package:talk2u/src/theme/app_shapes.dart';

/// On-device model management: Qwen3-4B presets, SenseVoice, MOSS-TTS.
///
/// Extracted from the settings page so that page owns navigation and form
/// state, while each model card owns its own service listenable and actions.
///
/// The Qwen card deliberately lists **both** Qwen3-4B-Instruct-2507 identities
/// the runtime reports. The upstream checkpoint is the one Qualcomm publishes a
/// QAIRT bundle for; the abliterated derivative has no published bundle and is
/// import-only. Showing a single "the model" row hid the upstream checkpoint
/// from the UI, which made the AI Hub download look like it installed the
/// abliterated weights. Each row now states exactly which identity it installs
/// and which artifacts it accepts.
class OnDeviceModelsSection extends StatelessWidget {
  const OnDeviceModelsSection({
    super.key,
    required this.onDownloadQwenHub,
    required this.onInstallQwenArtifact,
    required this.onCancelQwenImport,
    required this.onDeleteQwen,
    required this.onImportSenseVoiceZip,
    required this.onDownloadSenseVoice,
    required this.onDeleteMoss,
    required this.onImportMossZip,
    required this.onImportMossDir,
    required this.onSelectMossVoice,
    required this.onPreviewMossVoice,
  });

  final ValueChanged<OfflineModelPreset> onDownloadQwenHub;
  final void Function(OfflineModelPreset preset, OfflineModelArtifact artifact)
  onInstallQwenArtifact;
  final VoidCallback onCancelQwenImport;
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
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (OfflineLlmService.instance.supported) ...[
          Text(strings.deviceAi, style: textTheme.titleMedium),
          const SizedBox(height: 12),
          _QwenModelCard(
            onDownloadHub: onDownloadQwenHub,
            onInstallArtifact: onInstallQwenArtifact,
            onCancelImport: onCancelQwenImport,
            onDelete: onDeleteQwen,
          ),
          const SizedBox(height: 24),
        ],
        if (SherpaSpeechService.instance.supported) ...[
          Text(strings.offlineRecognition, style: textTheme.titleMedium),
          const SizedBox(height: 12),
          _SenseVoiceModelCard(
            onImportZip: onImportSenseVoiceZip,
            onDownload: onDownloadSenseVoice,
          ),
          const SizedBox(height: 24),
        ],
        if (MossTtsService.instance.supported) ...[
          Text(strings.mossSpeech, style: textTheme.titleMedium),
          const SizedBox(height: 12),
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

/// Card shell shared by the three model sections.
class _ModelCard extends StatelessWidget {
  const _ModelCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

class _ModelHeader extends StatelessWidget {
  const _ModelHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: ShapeDecoration(
            color: theme.colorScheme.primaryContainer,
            shape: AppShapes.field,
          ),
          child: Icon(icon, color: theme.colorScheme.onPrimaryContainer),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class _QwenModelCard extends StatelessWidget {
  const _QwenModelCard({
    required this.onDownloadHub,
    required this.onInstallArtifact,
    required this.onCancelImport,
    required this.onDelete,
  });

  final ValueChanged<OfflineModelPreset> onDownloadHub;
  final void Function(OfflineModelPreset preset, OfflineModelArtifact artifact)
  onInstallArtifact;
  final VoidCallback onCancelImport;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: OfflineLlmService.instance,
      builder: (context, _) {
        final llm = OfflineLlmService.instance;
        final presets = llm.presets;
        final installed = llm.installedPreset;
        final progress = (llm.importProgress * 100).round();
        final rate = llm.importBytesPerSecond;
        final eta = llm.importEta;
        final status = llm.importing
            ? '${_formatBytes(llm.importedBytes)} / '
                  '${_formatBytes(llm.totalImportBytes)} ($progress%)'
                  '${rate > 0 ? " · ${_formatBytes(rate.round())}/s" : ""}'
                  '${eta != null ? " · ${_formatEta(eta)}" : ""}'
            : llm.loadingModel
            ? strings.loadingModel
            : llm.modelReady
            ? strings.qwenModelReady(
                installed?.license ?? OfflineLlmService.modelLicense,
                llm.accelerationDescription,
              )
            : strings.qwenInstallHint;
        return _ModelCard(
          children: [
            _ModelHeader(
              icon: llm.modelReady
                  ? Icons.offline_bolt_outlined
                  : Icons.download_for_offline_outlined,
              title: installed?.displayName ?? strings.installQwen,
              subtitle: status,
              trailing: llm.importing
                  ? IconButton(
                      tooltip: strings.cancelDownload,
                      onPressed: onCancelImport,
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
                  : null,
            ),
            if (llm.importing) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: llm.importProgress),
            ],
            if (llm.modelReady) ...[
              const SizedBox(height: 8),
              _DetailRow(icon: Icons.memory, label: _acceleratorSummary(llm)),
              if (llm.artifactKind == 'gguf')
                _DetailRow(
                  icon: Icons.straighten,
                  // The importer admits Q4_0/Q8_0 only, so a GGUF that reaches
                  // this row has every tensor on the HTP.
                  label: 'GGUF ${llm.artifactQuantization ?? "unknown"} · HTP',
                ),
              if (llm.usingCpu && llm.rejectedAccelerators.isNotEmpty)
                _DetailRow(
                  icon: Icons.warning_amber_outlined,
                  label: llm.rejectedAccelerators.first,
                ),
            ],
            const SizedBox(height: 12),
            for (var index = 0; index < presets.length; index++) ...[
              _PresetRow(
                preset: presets[index],
                installed: installed?.id == presets[index].id,
                busy: llm.importing || llm.loadingModel,
                onDownloadHub: () => onDownloadHub(presets[index]),
                onImport: (artifact) =>
                    onInstallArtifact(presets[index], artifact),
              ),
              if (index < presets.length - 1) const Divider(height: 20),
            ],
            if (llm.lastError != null) ...[
              const SizedBox(height: 12),
              Text(
                serviceErrorText(
                  strings,
                  code: llm.lastErrorCode,
                  fallback: llm.lastError,
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _PresetRow extends StatelessWidget {
  const _PresetRow({
    required this.preset,
    required this.installed,
    required this.busy,
    required this.onDownloadHub,
    required this.onImport,
  });

  final OfflineModelPreset preset;
  final bool installed;
  final bool busy;
  final VoidCallback onDownloadHub;
  final ValueChanged<OfflineModelArtifact> onImport;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                preset.displayName,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                preset.hasHubBundle
                    ? strings.qwenPresetHub
                    : strings.qwenPresetImportOnly,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (installed)
          Chip(
            avatar: Icon(
              Icons.check_circle,
              size: 16,
              color: theme.colorScheme.onSecondaryContainer,
            ),
            label: Text(strings.qwenPresetInstalled),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          )
        else
          MenuAnchor(
            menuChildren: [
              if (preset.hasHubBundle)
                MenuItemButton(
                  leadingIcon: const Icon(Icons.cloud_download_outlined),
                  onPressed: busy ? null : onDownloadHub,
                  child: Text(strings.downloadFromInternet),
                ),
              MenuItemButton(
                leadingIcon: const Icon(Icons.folder_zip_outlined),
                onPressed: busy
                    ? null
                    : () => onImport(OfflineModelArtifact.qairtBundle),
                child: Text(strings.importQwenBundle),
              ),
              MenuItemButton(
                leadingIcon: const Icon(Icons.memory_outlined),
                onPressed: busy
                    ? null
                    : () => onImport(OfflineModelArtifact.gguf),
                child: Text(strings.importQwenGguf),
              ),
            ],
            builder: (context, controller, _) => IconButton(
              tooltip: strings.installQwen,
              onPressed: busy
                  ? null
                  : () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
              icon: const Icon(Icons.download_outlined),
            ),
          ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
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
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: SherpaSpeechService.instance,
      builder: (context, _) {
        final sherpa = SherpaSpeechService.instance;
        final status = sherpa.downloading && sherpa.asrDownloading
            ? '${_formatBytes(sherpa.downloadedBytes)} / '
                  '${_formatBytes(sherpa.totalDownloadBytes)}'
            : sherpa.asrReady
            ? '${strings.senseVoiceReady}\n${strings.senseVoiceQnnUnsupported}'
            : strings.senseVoiceSize;
        return _ModelCard(
          children: [
            _ModelHeader(
              icon: sherpa.asrReady
                  ? Icons.mic_outlined
                  : Icons.download_for_offline_outlined,
              title: SherpaSpeechService.asrModelName,
              subtitle: status,
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
            if (sherpa.downloading) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: sherpa.downloadProgress),
            ],
            if (sherpa.extracting) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (sherpa.lastError != null) ...[
              const SizedBox(height: 12),
              Text(
                serviceErrorText(
                  strings,
                  code: sherpa.lastErrorCode,
                  fallback: sherpa.lastError,
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
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
    final theme = Theme.of(context);
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
        return _ModelCard(
          children: [
            _ModelHeader(
              icon: busy
                  ? Icons.memory_outlined
                  : moss.ready
                  ? Icons.record_voice_over_outlined
                  : Icons.folder_open_outlined,
              title: MossTtsService.modelName,
              subtitle: status,
              trailing: busy
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : moss.ready
                  ? IconButton(
                      tooltip: strings.deleteMoss,
                      onPressed: onDelete,
                      icon: const Icon(Icons.delete_outline),
                    )
                  : PopupMenuButton<String>(
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
            if (moss.ready) ...[
              const Divider(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: DropdownMenu<String>(
                      key: ValueKey(moss.voiceId),
                      initialSelection: moss.voiceId,
                      enabled: !previewing,
                      expandedInsets: EdgeInsets.zero,
                      selectOnly: true,
                      requestFocusOnTap: false,
                      enableSearch: false,
                      label: Text(strings.mossVoice),
                      leadingIcon: const Icon(Icons.record_voice_over_outlined),
                      menuStyle: const MenuStyle(
                        shape: WidgetStatePropertyAll(AppShapes.overlay),
                      ),
                      dropdownMenuEntries: MossTtsService.voices
                          .map(
                            (voice) => DropdownMenuEntry<String>(
                              value: voice.id,
                              label: voice.displayLabel,
                            ),
                          )
                          .toList(growable: false),
                      onSelected: previewing ? null : onSelectVoice,
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
            ],
            AnimatedSize(
              duration: AppMotion.of(context, AppMotion.resize),
              curve: AppMotion.standardDecelerate,
              child: busy || moss.generating
                  ? Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(
                        value: moss.downloading ? moss.downloadProgress : null,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            if (moss.lastError != null) ...[
              const SizedBox(height: 12),
              Text(
                serviceErrorText(
                  strings,
                  code: moss.lastErrorCode,
                  fallback: moss.lastError,
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// One line naming the accelerators that can run the installed artifact.
///
/// The list comes from the native probe, so a device without an OpenCL driver or
/// without the HTP backend says so instead of advertising an accelerator it
/// cannot use.
String _acceleratorSummary(OfflineLlmService llm) {
  final usable = llm.accelerators
      .where((accelerator) => accelerator.available)
      .map((accelerator) => accelerator.accelerator.toUpperCase())
      .toSet()
      .toList(growable: false);
  if (usable.isEmpty) return '';
  return usable.join(' · ');
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
