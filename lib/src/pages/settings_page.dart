import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/l10n/provider_names.dart';
import 'package:talk2u/src/models/provider_profile.dart';
import 'package:talk2u/src/rust/api/chat_api.dart' as rust_api;
import 'package:talk2u/src/rust/api/data_models.dart';
import 'package:talk2u/src/services/offline_llm_service.dart';
import 'package:talk2u/src/services/offline_speech_service.dart';
import 'package:talk2u/src/services/moss_tts_service.dart';
import 'package:talk2u/src/services/sherpa_speech_service.dart';
import 'package:talk2u/src/settings/ui_preferences.dart';
import 'package:talk2u/src/theme/app_shapes.dart';
import 'package:talk2u/src/widgets/aurora_backdrop.dart';
import 'package:talk2u/src/widgets/settings/on_device_models_section.dart';

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

  /// Installs one compiled artifact of [preset].
  ///
  /// A QAIRT bundle and a GGUF both reach the Hexagon NPU: the bundle through
  /// the QAIRT plugin, the GGUF through llama.cpp's ggml-hexagon backend. The
  /// native side validates the artifact before replacing the installed one.
  Future<void> _importOfflineModel(
    OfflineModelPreset preset,
    OfflineModelArtifact artifact,
  ) async {
    await _runOfflineInstall(
      () => OfflineLlmService.instance.importArtifact(artifact, preset: preset),
    );
  }

  /// Downloads Qualcomm's QAIRT bundle for the upstream checkpoint.
  ///
  /// This is the path the app always had for `Qwen3-4B-Instruct-2507`; the
  /// abliterated derivative has no published bundle, so it stays import-only.
  Future<void> _downloadOfflineModelFromHub(OfflineModelPreset preset) async {
    await _runOfflineInstall(
      () => OfflineLlmService.instance.downloadFromHub(preset: preset),
    );
  }

  Future<void> _runOfflineInstall(Future<void> Function() install) async {
    try {
      await install();
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

  Future<void> _cancelOfflineModelImport() async {
    try {
      await OfflineLlmService.instance.cancelImport();
    } catch (error) {
      if (mounted) {
        _showMessage(
          AppLocalizations.of(context).pauseDownloadFailed('$error'),
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
      return const AuroraBackdrop(
        child: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    final strings = AppLocalizations.of(context);
    final preferences = context.watch<UiPreferences>();
    final colors = Theme.of(context).colorScheme;
    return AuroraBackdrop(
      child: Scaffold(
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
              DropdownMenu<AppColorTheme>(
                // DropdownMenu keeps its own text controller, so rebuild it when
                // the preference changes elsewhere (the system theme sheet, a
                // restored session) to keep the closed field truthful.
                key: ValueKey(preferences.colorTheme),
                initialSelection: preferences.colorTheme,
                expandedInsets: EdgeInsets.zero,
                selectOnly: true,
                requestFocusOnTap: false,
                enableSearch: false,
                label: Text(strings.colorScheme),
                leadingIcon: const Icon(Icons.palette_outlined),
                menuStyle: const MenuStyle(
                  shape: WidgetStatePropertyAll(AppShapes.overlay),
                ),
                dropdownMenuEntries: AppColorTheme.values
                    .map(
                      (item) => DropdownMenuEntry<AppColorTheme>(
                        value: item,
                        label: switch (item) {
                          AppColorTheme.teal => strings.colorTeal,
                          AppColorTheme.blue => strings.colorBlue,
                          AppColorTheme.green => strings.colorGreen,
                          AppColorTheme.rose => strings.colorRose,
                        },
                        leadingIcon: Container(
                          width: 18,
                          height: 18,
                          decoration: ShapeDecoration(
                            color: item.seed,
                            shape: const CircleBorder(),
                          ),
                        ),
                      ),
                    )
                    .toList(growable: false),
                onSelected: (value) {
                  if (value != null) preferences.setColorTheme(value);
                },
              ),
              const SizedBox(height: 12),
              DropdownMenu<AppLanguage>(
                key: ValueKey(preferences.language),
                initialSelection: preferences.language,
                expandedInsets: EdgeInsets.zero,
                selectOnly: true,
                requestFocusOnTap: false,
                enableSearch: false,
                label: Text(strings.language),
                leadingIcon: const Icon(Icons.language_outlined),
                menuStyle: const MenuStyle(
                  shape: WidgetStatePropertyAll(AppShapes.overlay),
                ),
                dropdownMenuEntries: [
                  DropdownMenuEntry<AppLanguage>(
                    value: AppLanguage.system,
                    label: strings.languageSystem,
                  ),
                  DropdownMenuEntry<AppLanguage>(
                    value: AppLanguage.zh,
                    label: strings.languageChinese,
                  ),
                  DropdownMenuEntry<AppLanguage>(
                    value: AppLanguage.en,
                    label: strings.languageEnglish,
                  ),
                ],
                onSelected: (value) {
                  if (value != null) preferences.setLanguage(value);
                },
              ),
              const SizedBox(height: 32),
              DropdownMenu<String>(
                key: ValueKey(_selectedId),
                initialSelection: _selectedId,
                expandedInsets: EdgeInsets.zero,
                selectOnly: true,
                requestFocusOnTap: false,
                enableSearch: false,
                label: Text(strings.platform),
                leadingIcon: const Icon(Icons.hub_outlined),
                menuStyle: const MenuStyle(
                  shape: WidgetStatePropertyAll(AppShapes.overlay),
                ),
                dropdownMenuEntries: _providers
                    .map(
                      (provider) => DropdownMenuEntry<String>(
                        value: provider.id,
                        label: providerDisplayName(provider, strings),
                        leadingIcon: Icon(
                          provider.isConfigured
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          size: 16,
                          color: provider.isConfigured
                              ? colors.primary
                              : colors.outline,
                        ),
                      ),
                    )
                    .toList(growable: false),
                onSelected: _selectProvider,
              ),
              const SizedBox(height: 20),
              if (!_selected.isLocal) ...[
                TextFormField(
                  controller: _keyController,
                  obscureText: _obscureKey,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    prefixIcon: const Icon(Icons.key_outlined),
                    suffixIcon: IconButton(
                      tooltip: _obscureKey
                          ? strings.showSecret
                          : strings.hideSecret,
                      icon: Icon(
                        _obscureKey
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () =>
                          setState(() => _obscureKey = !_obscureKey),
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
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _maxOutputTokensController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: strings.maxOutputTokens,
                    prefixIcon: const Icon(Icons.data_array_outlined),
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
                    title: Text(OfflineLlmService.instance.displayName),
                    subtitle: Text(
                      OfflineLlmService.instance.modelReady
                          ? strings.qwenReady(
                              OfflineLlmService
                                  .instance
                                  .accelerationDescription,
                            )
                          : strings.qwenInstallHint,
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _saving || _testingConnection ? null : _save,
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(strings.saveConfiguration),
                ),
              ),
              if (!_selected.isLocal) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
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
                  ),
                ),
              ],
              const SizedBox(height: 32),
              OnDeviceModelsSection(
                onDownloadQwenHub: _downloadOfflineModelFromHub,
                onInstallQwenArtifact: _importOfflineModel,
                onCancelQwenImport: _cancelOfflineModelImport,
                onDeleteQwen: _deleteOfflineModel,
                onImportSenseVoiceZip: _importSherpaZip,
                onDownloadSenseVoice: _downloadSherpaAsr,
                onDeleteMoss: _deleteMossTts,
                onImportMossZip: _importMossZip,
                onImportMossDir: _downloadMossTts,
                onSelectMossVoice: _selectMossVoice,
                onPreviewMossVoice: _previewMossVoice,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
