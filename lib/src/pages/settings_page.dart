import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/models/provider_profile.dart';
import 'package:talk2u/src/rust/api/chat_api.dart' as rust_api;
import 'package:talk2u/src/rust/api/data_models.dart';
import 'package:talk2u/src/services/offline_llm_service.dart';
import 'package:talk2u/src/services/offline_speech_service.dart';
import 'package:talk2u/src/services/moss_tts_service.dart';
import 'package:talk2u/src/services/sherpa_speech_service.dart';
import 'package:talk2u/src/settings/ui_preferences.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _keyController = TextEditingController();
  final _urlController = TextEditingController();
  final _chatModelController = TextEditingController();
  final _thinkingModelController = TextEditingController();
  final _maxOutputTokensController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  List<ProviderProfile> _providers = [];
  String _selectedId = 'zhipu';
  bool _enableThinking = true;
  bool _obscureKey = true;
  bool _loading = true;
  bool _saving = false;
  bool _testingConnection = false;

  ProviderProfile get _selected =>
      _providers.firstWhere((item) => item.id == _selectedId);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final settings = await rust_api.getSettings();
      await OfflineLlmService.instance.initialize();
      final providers = ProviderProfile.withRuntimeDefaults(
        ProviderProfile.decodeList(settings.providersJson),
        includeAndroidOffline: OfflineLlmService.instance.supported,
      );
      if (settings.apiKey?.isNotEmpty == true) {
        final index = providers.indexWhere((item) => item.id == 'zhipu');
        if (index >= 0 && providers[index].apiKey?.isNotEmpty != true) {
          providers[index] = providers[index].copyWith(apiKey: settings.apiKey);
        }
      }
      var selected =
          providers.any((item) => item.id == settings.selectedProvider)
          ? settings.selectedProvider
          : providers.first.id;
      if (OfflineLlmService.instance.modelReady &&
          !providers.any(
            (provider) => !provider.isLocal && provider.isConfigured,
          )) {
        selected = ProviderProfile.androidOfflineId;
      }
      if (!mounted) return;
      setState(() {
        _providers = providers;
        _selectedId = selected;
        _enableThinking = settings.enableThinkingByDefault;
        _loading = false;
        _loadControllers(_selected);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showMessage(
        AppLocalizations.of(context).loadSettingsFailed('$error'),
        isError: true,
      );
    }
  }

  void _loadControllers(ProviderProfile profile) {
    _keyController.text = profile.apiKey ?? '';
    _urlController.text = profile.apiUrl;
    _chatModelController.text = profile.chatModel;
    _thinkingModelController.text = profile.thinkingModel ?? '';
    _maxOutputTokensController.text = profile.maxOutputTokens.toString();
  }

  void _commitEditors() {
    if (_providers.isEmpty) return;
    if (_selected.isLocal) return;
    final index = _providers.indexWhere((item) => item.id == _selectedId);
    _providers[index] = _providers[index].copyWith(
      apiKey: _keyController.text.trim(),
      apiUrl: _urlController.text.trim(),
      chatModel: _chatModelController.text.trim(),
      thinkingModel: _thinkingModelController.text.trim(),
      clearThinkingModel: _thinkingModelController.text.trim().isEmpty,
      maxOutputTokens:
          int.tryParse(_maxOutputTokensController.text.trim()) ?? 4096,
    );
  }

  void _selectProvider(String? id) {
    if (id == null || id == _selectedId) return;
    _commitEditors();
    setState(() {
      _selectedId = id;
      _loadControllers(_selected);
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    _commitEditors();
    final provider = _selected;
    final strings = AppLocalizations.of(context);
    setState(() => _saving = true);
    try {
      final zhipuProviders = _providers.where((item) => item.id == 'zhipu');
      final settings = AppSettings(
        apiKey: zhipuProviders.isEmpty ? null : zhipuProviders.first.apiKey,
        defaultModel: provider.chatModel,
        enableThinkingByDefault: _enableThinking,
        chatModel: provider.chatModel,
        thinkingModel: provider.thinkingModel ?? '',
        selectedProvider: provider.id,
        providersJson: ProviderProfile.encodeList(_providers),
      );
      final saved = await rust_api.saveSettings(settings: settings);
      if (!saved) {
        throw StateError(strings.settingsWriteFailed);
      }
      if (mounted) {
        _showMessage(strings.providerSaved(provider.name));
      }
    } catch (error) {
      if (mounted) {
        _showMessage(strings.saveFailed('$error'), isError: true);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;
    _commitEditors();
    final provider = _selected;
    if (provider.isLocal) return;

    setState(() => _testingConnection = true);
    try {
      final result = await rust_api.validateApiKey(
        providerId: provider.id,
        apiKey: provider.apiKey ?? '',
        apiUrl: provider.apiUrl,
        model: provider.chatModel,
        protocol: provider.protocol,
        maxOutputTokens: provider.maxOutputTokens,
      );
      if (mounted) _showMessage(result);
    } catch (error) {
      if (mounted) {
        _showMessage(
          AppLocalizations.of(context).connectionTestFailed('$error'),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _testingConnection = false);
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  Future<void> _downloadOfflineModel() async {
    try {
      await OfflineLlmService.instance.downloadModel();
      if (!mounted) return;
      if (!OfflineLlmService.instance.modelReady) return;
      _showMessage(AppLocalizations.of(context).qwenInstalled);
      if (!_providers.any(
        (provider) => !provider.isLocal && provider.isConfigured,
      )) {
        setState(() {
          _selectedId = ProviderProfile.androidOfflineId;
          _loadControllers(_selected);
        });
        await _save();
      }
    } catch (error) {
      if (mounted) {
        _showMessage(
          AppLocalizations.of(context).qwenInstallFailed('$error'),
          isError: true,
        );
      }
    }
  }

  Future<void> _deleteOfflineModel() async {
    try {
      await OfflineLlmService.instance.deleteModel();
      if (mounted) {
        _showMessage(AppLocalizations.of(context).offlineModelDeleted);
      }
    } catch (error) {
      if (mounted) {
        _showMessage(
          AppLocalizations.of(context).offlineModelDeleteFailed('$error'),
          isError: true,
        );
      }
    }
  }

  Future<void> _downloadSherpaAsr() async {
    try {
      await SherpaSpeechService.instance.downloadAsr();
      await OfflineSpeechService.instance.initialize();
      if (mounted) {
        _showMessage(AppLocalizations.of(context).senseVoiceInstalled);
      }
    } catch (error) {
      if (mounted) {
        _showMessage(
          AppLocalizations.of(context).senseVoiceInstallFailed('$error'),
          isError: true,
        );
      }
    }
  }

  Future<void> _importSherpaZip() async {
    try {
      await SherpaSpeechService.instance.importAsrFromZip();
      await OfflineSpeechService.instance.initialize();
      if (mounted) {
        _showMessage(AppLocalizations.of(context).senseVoiceInstalled);
      }
    } catch (error) {
      if (mounted) {
        _showMessage(
          AppLocalizations.of(context).senseVoiceInstallFailed('$error'),
          isError: true,
        );
      }
    }
  }

  Future<void> _downloadMossTts() async {
    try {
      await MossTtsService.instance.importModel();
      await OfflineSpeechService.instance.initialize();
      if (mounted) _showMessage(AppLocalizations.of(context).mossImported);
    } catch (error) {
      if (mounted) {
        _showMessage(
          AppLocalizations.of(context).mossImportFailed('$error'),
          isError: true,
        );
      }
    }
  }

  Future<void> _importMossZip() async {
    try {
      await MossTtsService.instance.importModelFromZip();
      await OfflineSpeechService.instance.initialize();
      if (mounted) _showMessage(AppLocalizations.of(context).mossImported);
    } catch (error) {
      if (mounted) {
        _showMessage(
          AppLocalizations.of(context).mossImportFailed('$error'),
          isError: true,
        );
      }
    }
  }

  Future<void> _deleteMossTts() async {
    try {
      await MossTtsService.instance.deleteModel();
      await OfflineSpeechService.instance.initialize();
      if (mounted) _showMessage(AppLocalizations.of(context).mossDeleted);
    } catch (error) {
      if (mounted) {
        _showMessage(
          AppLocalizations.of(context).mossDeleteFailed('$error'),
          isError: true,
        );
      }
    }
  }

  Future<void> _selectMossVoice(String? voiceId) async {
    if (voiceId == null) return;
    try {
      await MossTtsService.instance.selectVoice(voiceId);
      if (mounted) _showMessage(AppLocalizations.of(context).mossVoiceChanged);
    } catch (error) {
      if (mounted) {
        _showMessage(
          AppLocalizations.of(context).mossVoiceChangeFailed('$error'),
          isError: true,
        );
      }
    }
  }

  Future<void> _previewMossVoice() async {
    try {
      await MossTtsService.instance.speak(
        AppLocalizations.of(context).mossPreviewText,
      );
    } catch (error) {
      if (mounted) {
        _showMessage(
          AppLocalizations.of(context).mossPreviewFailed('$error'),
          isError: true,
        );
      }
    }
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

  @override
  void dispose() {
    _keyController.dispose();
    _urlController.dispose();
    _chatModelController.dispose();
    _thinkingModelController.dispose();
    _maxOutputTokensController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final strings = AppLocalizations.of(context);
    final preferences = context.watch<UiPreferences>();
    return Scaffold(
      appBar: AppBar(title: Text(strings.settings)),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              strings.appearance,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Text(
              strings.themeMode,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            SegmentedButton<ThemeMode>(
              segments: [
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: const Icon(Icons.brightness_auto_outlined),
                  label: Text(strings.themeSystem),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: const Icon(Icons.light_mode_outlined),
                  label: Text(strings.themeLight),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: const Icon(Icons.dark_mode_outlined),
                  label: Text(strings.themeDark),
                ),
              ],
              selected: {preferences.themeMode},
              onSelectionChanged: (value) {
                preferences.setThemeMode(value.single);
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<AppColorTheme>(
              initialValue: preferences.colorTheme,
              decoration: InputDecoration(
                labelText: strings.colorScheme,
                prefixIcon: const Icon(Icons.palette_outlined),
              ),
              items: AppColorTheme.values
                  .map(
                    (item) => DropdownMenuItem(
                      value: item,
                      child: Row(
                        children: [
                          Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              color: item.seed,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(switch (item) {
                            AppColorTheme.teal => strings.colorTeal,
                            AppColorTheme.blue => strings.colorBlue,
                            AppColorTheme.green => strings.colorGreen,
                            AppColorTheme.rose => strings.colorRose,
                          }),
                        ],
                      ),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (value) {
                if (value != null) preferences.setColorTheme(value);
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<AppLanguage>(
              initialValue: preferences.language,
              decoration: InputDecoration(
                labelText: strings.language,
                prefixIcon: const Icon(Icons.language_outlined),
              ),
              items: [
                DropdownMenuItem(
                  value: AppLanguage.system,
                  child: Text(strings.languageSystem),
                ),
                DropdownMenuItem(
                  value: AppLanguage.zh,
                  child: Text(strings.languageChinese),
                ),
                DropdownMenuItem(
                  value: AppLanguage.en,
                  child: Text(strings.languageEnglish),
                ),
              ],
              onChanged: (value) {
                if (value != null) preferences.setLanguage(value);
              },
            ),
            const SizedBox(height: 32),
            DropdownButtonFormField<String>(
              initialValue: _selectedId,
              decoration: InputDecoration(
                labelText: strings.platform,
                prefixIcon: const Icon(Icons.hub_outlined),
                border: const OutlineInputBorder(),
              ),
              items: _providers
                  .map(
                    (provider) => DropdownMenuItem(
                      value: provider.id,
                      child: Row(
                        children: [
                          Icon(
                            provider.isConfigured
                                ? Icons.check_circle
                                : Icons.circle_outlined,
                            size: 16,
                            color: provider.isConfigured
                                ? Colors.green
                                : Theme.of(context).colorScheme.outline,
                          ),
                          const SizedBox(width: 8),
                          Text(provider.name),
                        ],
                      ),
                    ),
                  )
                  .toList(),
              onChanged: _selectProvider,
            ),
            const SizedBox(height: 20),
            if (!_selected.isLocal) ...[
              TextFormField(
                controller: _keyController,
                obscureText: _obscureKey,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  prefixIcon: const Icon(Icons.key_outlined),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: _obscureKey
                        ? strings.showSecret
                        : strings.hideSecret,
                    icon: Icon(
                      _obscureKey
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () => setState(() => _obscureKey = !_obscureKey),
                  ),
                ),
                validator: (value) =>
                    _selected.requiresApiKey && value?.trim().isEmpty == true
                    ? strings.apiKeyRequired
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _urlController,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: strings.apiUrl,
                  prefixIcon: const Icon(Icons.link_outlined),
                  border: const OutlineInputBorder(),
                ),
                validator: (value) {
                  if (_selected.isLocal) return null;
                  final uri = Uri.tryParse(value?.trim() ?? '');
                  if (uri == null ||
                      !uri.hasAuthority ||
                      (uri.scheme != 'http' && uri.scheme != 'https')) {
                    return strings.validHttpUrlRequired;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _chatModelController,
                decoration: InputDecoration(
                  labelText: strings.chatModelId,
                  prefixIcon: const Icon(Icons.smart_toy_outlined),
                  border: const OutlineInputBorder(),
                ),
                validator: (value) => value?.trim().isEmpty == true
                    ? strings.modelIdRequired
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _thinkingModelController,
                decoration: InputDecoration(
                  labelText: strings.reasoningModelId,
                  prefixIcon: const Icon(Icons.psychology_outlined),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _maxOutputTokensController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: strings.maxOutputTokens,
                  prefixIcon: const Icon(Icons.data_array_outlined),
                  border: const OutlineInputBorder(),
                ),
                validator: (value) {
                  final parsed = int.tryParse(value?.trim() ?? '');
                  if (parsed == null || parsed < 1 || parsed > 131072) {
                    return strings.tokenRangeError;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(strings.enableReasoningByDefault),
                subtitle: Text(strings.reasoningRequiresModel),
                value: _enableThinking,
                onChanged: (value) => setState(() => _enableThinking = value),
              ),
            ] else
              Card(
                child: ListTile(
                  leading: const Icon(Icons.offline_bolt_outlined),
                  title: const Text(OfflineLlmService.modelName),
                  subtitle: Text(
                    OfflineLlmService.instance.modelReady
                        ? strings.qwenReady(
                            OfflineLlmService.instance.accelerationDescription,
                          )
                        : strings.qwenInstallHint,
                  ),
                ),
              ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _saving || _testingConnection ? null : _save,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(strings.saveConfiguration),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
            if (!_selected.isLocal) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _saving || _testingConnection
                    ? null
                    : _testConnection,
                icon: _testingConnection
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.network_check_outlined),
                label: Text(strings.testConnection),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ],
            const SizedBox(height: 32),
            if (OfflineLlmService.instance.supported) ...[
              Text(
                strings.deviceAi,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              AnimatedBuilder(
                animation: OfflineLlmService.instance,
                builder: (context, _) {
                  final llm = OfflineLlmService.instance;
                  final progress = (llm.downloadProgress * 100).round();
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
                              : llm.loadingModel
                              ? strings.loadingModel
                              : llm.modelReady
                              ? strings.qwenModelReady(
                                  OfflineLlmService.modelLicense,
                                  llm.accelerationDescription,
                                )
                              : strings.qwenModelPackage(
                                  OfflineLlmService.modelLicense,
                                ),
                        ),
                        trailing: llm.downloading
                            ? const SizedBox.square(
                                dimension: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : llm.modelReady
                            ? PopupMenuButton<String>(
                                tooltip: strings.manageModel,
                                onSelected: (value) {
                                  if (value == 'delete') {
                                    _deleteOfflineModel();
                                  }
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
                                onPressed: _downloadOfflineModel,
                                icon: const Icon(Icons.download_outlined),
                              ),
                      ),
                      if (llm.downloading)
                        LinearProgressIndicator(value: llm.downloadProgress),
                      if (llm.lastError != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          llm.lastError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(height: 24),
            ],
            if (SherpaSpeechService.instance.supported) ...[
              Text(
                strings.offlineRecognition,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              AnimatedBuilder(
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
                          sherpa.downloading &&
                                  sherpa.operationLabel.contains('SenseVoice')
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
                                    _importSherpaZip();
                                  } else if (value == 'download') {
                                    _downloadSherpaAsr();
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
                          sherpa.lastError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(height: 24),
            ],
            if (MossTtsService.instance.supported) ...[
              Text(
                strings.mossSpeech,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              AnimatedBuilder(
                animation: MossTtsService.instance,
                builder: (context, _) {
                  final moss = MossTtsService.instance;
                  final busy = moss.downloading || moss.initializing;
                  final status = moss.downloading
                      ? '${moss.operationLabel}\n'
                            '${_formatBytes(moss.downloadedBytes)} / '
                            '${_formatBytes(moss.totalDownloadBytes)}'
                      : moss.initializing
                      ? strings.mossInitializing
                      : moss.generating
                      ? strings.mossGenerating
                      : moss.ready
                      ? strings.mossReady(moss.accelerationLabel)
                      : '${_formatBytes(MossTtsService.modelBytes)} · '
                            '${moss.accelerationLabel}';
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
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : moss.ready
                              ? IconButton(
                                  key: const ValueKey('moss-delete'),
                                  tooltip: strings.deleteMoss,
                                  onPressed: _deleteMossTts,
                                  icon: const Icon(Icons.delete_outline),
                                )
                              : PopupMenuButton<String>(
                                  key: const ValueKey('moss-import'),
                                  tooltip: strings.importMoss,
                                  onSelected: (value) {
                                    if (value == 'zip') {
                                      _importMossZip();
                                    } else if (value == 'dir') {
                                      _downloadMossTts();
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
                                    prefixIcon: const Icon(
                                      Icons.record_voice_over,
                                    ),
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
                                  onChanged: moss.generating || moss.speaking
                                      ? null
                                      : _selectMossVoice,
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton.filledTonal(
                                tooltip: moss.generating || moss.speaking
                                    ? strings.stopPreview
                                    : strings.previewVoice,
                                onPressed: moss.generating || moss.speaking
                                    ? moss.stopSpeaking
                                    : _previewMossVoice,
                                icon: Icon(
                                  moss.generating || moss.speaking
                                      ? Icons.stop
                                      : Icons.volume_up_outlined,
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
                                  moss.downloading
                                      ? 'moss-import'
                                      : 'moss-work',
                                ),
                                value: moss.downloading
                                    ? moss.downloadProgress
                                    : null,
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
                                  moss.lastError!,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 24),
            ],
          ],
        ),
      ),
    );
  }
}
