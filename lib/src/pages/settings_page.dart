import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:talk2u/src/models/provider_profile.dart';
import 'package:talk2u/src/rust/api/chat_api.dart' as rust_api;
import 'package:talk2u/src/rust/api/data_models.dart';
import 'package:talk2u/src/services/offline_llm_service.dart';
import 'package:talk2u/src/services/offline_speech_service.dart';
import 'package:talk2u/src/services/moss_tts_service.dart';
import 'package:talk2u/src/services/sherpa_speech_service.dart';

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
      final providers = ProviderProfile.decodeList(settings.providersJson);
      if (OfflineLlmService.instance.supported &&
          !providers.any(
            (provider) => provider.id == ProviderProfile.androidOfflineId,
          )) {
        providers.add(ProviderProfile.androidOffline);
      }
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
      _showMessage('加载设置失败: $error', isError: true);
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
      if (!saved) throw StateError('设置文件写入失败');
      if (mounted) _showMessage('${provider.name} 配置已保存');
    } catch (error) {
      if (mounted) _showMessage('保存失败: $error', isError: true);
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
      if (mounted) _showMessage('连接测试失败: $error', isError: true);
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

  Future<void> _openSpeechSetup(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) _showMessage('无法打开系统语音设置: $error', isError: true);
    }
  }

  Future<void> _downloadSpeechModel() async {
    try {
      await OfflineSpeechService.instance.downloadOfflineSttModel();
      if (mounted) _showMessage('已提交中文端侧识别模型下载');
    } catch (error) {
      if (mounted) _showMessage('无法下载端侧识别模型: $error', isError: true);
    }
  }

  Future<void> _downloadOfflineModel() async {
    try {
      await OfflineLlmService.instance.downloadModel();
      if (!mounted) return;
      _showMessage('端侧 AI 模型已下载并校验完成');
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
      if (mounted) _showMessage('端侧 AI 模型下载失败: $error', isError: true);
    }
  }

  Future<void> _deleteOfflineModel() async {
    try {
      await OfflineLlmService.instance.deleteModel();
      if (mounted) _showMessage('已删除端侧 AI 模型');
    } catch (error) {
      if (mounted) _showMessage('无法删除端侧 AI 模型: $error', isError: true);
    }
  }

  Future<void> _downloadSherpaAsr() async {
    try {
      await SherpaSpeechService.instance.downloadAsr();
      await OfflineSpeechService.instance.initialize();
      if (mounted) _showMessage('SenseVoice 离线识别模型已安装');
    } catch (error) {
      if (mounted) _showMessage('SenseVoice 下载失败: $error', isError: true);
    }
  }

  Future<void> _downloadMossTts() async {
    try {
      await MossTtsService.instance.downloadModel();
      await OfflineSpeechService.instance.initialize();
      if (mounted) _showMessage('MOSS-TTS-Nano 端侧模型已安装');
    } catch (error) {
      if (mounted) _showMessage('MOSS-TTS-Nano 下载失败: $error', isError: true);
    }
  }

  Future<void> _deleteMossTts() async {
    try {
      await MossTtsService.instance.deleteModel();
      await OfflineSpeechService.instance.initialize();
      if (mounted) _showMessage('已删除 MOSS-TTS-Nano 端侧模型');
    } catch (error) {
      if (mounted) _showMessage('无法删除 MOSS-TTS-Nano: $error', isError: true);
    }
  }

  Future<void> _selectMossVoice(String? voiceId) async {
    if (voiceId == null) return;
    try {
      await MossTtsService.instance.selectVoice(voiceId);
      if (mounted) _showMessage('已切换 MOSS 内置克隆音色');
    } catch (error) {
      if (mounted) _showMessage('无法切换 MOSS 音色: $error', isError: true);
    }
  }

  Future<void> _previewMossVoice() async {
    try {
      await MossTtsService.instance.speak('你好，很高兴认识你。今天想聊些什么？我会认真听，也会自然地回应你。');
    } catch (error) {
      if (mounted) _showMessage('MOSS-TTS-Nano 试听失败: $error', isError: true);
    }
  }

  Future<void> _selectSystemTtsVoice(String? name) async {
    if (name == null || name.isEmpty) return;
    try {
      await OfflineSpeechService.instance.selectTtsVoice(name);
      if (mounted) _showMessage('已切换离线音色');
    } catch (error) {
      if (mounted) _showMessage('无法切换离线音色: $error', isError: true);
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
    return Scaffold(
      appBar: AppBar(title: const Text('模型与接口')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            DropdownButtonFormField<String>(
              initialValue: _selectedId,
              decoration: const InputDecoration(
                labelText: '平台',
                prefixIcon: Icon(Icons.hub_outlined),
                border: OutlineInputBorder(),
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
                    tooltip: _obscureKey ? '显示密钥' : '隐藏密钥',
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
                    ? '请输入 API Key'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _urlController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '调用 URL',
                  prefixIcon: Icon(Icons.link_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (_selected.isLocal) return null;
                  final uri = Uri.tryParse(value?.trim() ?? '');
                  if (uri == null ||
                      !uri.hasAuthority ||
                      (uri.scheme != 'http' && uri.scheme != 'https')) {
                    return '请输入完整的 HTTP(S) URL';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _chatModelController,
                decoration: const InputDecoration(
                  labelText: '对话模型 ID',
                  prefixIcon: Icon(Icons.smart_toy_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    value?.trim().isEmpty == true ? '请输入模型 ID' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _thinkingModelController,
                decoration: const InputDecoration(
                  labelText: '推理模型 ID（可选）',
                  prefixIcon: Icon(Icons.psychology_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _maxOutputTokensController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '最大输出 Token',
                  prefixIcon: Icon(Icons.data_array_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  final parsed = int.tryParse(value?.trim() ?? '');
                  if (parsed == null || parsed < 1 || parsed > 131072) {
                    return '请输入 1 到 131072 之间的整数';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('默认启用推理管线'),
                subtitle: const Text('仅在当前平台配置了推理模型时生效'),
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
                        ? '已就绪 · ${OfflineLlmService.instance.accelerationDescription}'
                        : '无需 API；下载并校验模型后完全离线运行',
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
              label: const Text('保存配置'),
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
                label: const Text('测试连接'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ],
            const SizedBox(height: 32),
            if (OfflineLlmService.instance.supported) ...[
              Text('设备端侧 AI', style: Theme.of(context).textTheme.titleMedium),
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
                              ? '正在载入模型...'
                              : llm.modelReady
                              ? '已就绪 · ${OfflineLlmService.modelLicense} · '
                                    '${llm.accelerationDescription}'
                              : '${_formatBytes(OfflineLlmService.modelSize)} · '
                                    '${OfflineLlmService.modelLicense} · llama.cpp',
                        ),
                        trailing: llm.downloading
                            ? IconButton(
                                tooltip: '取消下载',
                                onPressed: llm.cancelDownload,
                                icon: const Icon(Icons.stop_circle_outlined),
                              )
                            : llm.modelReady
                            ? PopupMenuButton<String>(
                                tooltip: '管理端侧模型',
                                onSelected: (value) {
                                  if (value == 'delete') {
                                    _deleteOfflineModel();
                                  }
                                },
                                itemBuilder: (context) => const [
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('删除模型'),
                                  ),
                                ],
                              )
                            : IconButton(
                                tooltip: '下载端侧 AI 模型',
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
              Text('跨平台端侧语音', style: Theme.of(context).textTheme.titleMedium),
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
                              ? '已就绪 · 多语言识别 · 完全离线'
                              : '约 158.1 MB · 中英日韩粤语',
                        ),
                        trailing: sherpa.downloading
                            ? IconButton(
                                tooltip: '取消下载',
                                onPressed: sherpa.cancelDownload,
                                icon: const Icon(Icons.stop_circle_outlined),
                              )
                            : sherpa.asrReady
                            ? IconButton(
                                tooltip: '删除 SenseVoice',
                                onPressed: sherpa.deleteAsr,
                                icon: const Icon(Icons.delete_outline),
                              )
                            : IconButton(
                                tooltip: '下载 SenseVoice',
                                onPressed: _downloadSherpaAsr,
                                icon: const Icon(Icons.download_outlined),
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
              Text('MOSS 端侧语音', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              AnimatedBuilder(
                animation: MossTtsService.instance,
                builder: (context, _) {
                  final moss = MossTtsService.instance;
                  return Column(
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          moss.ready
                              ? Icons.record_voice_over_outlined
                              : Icons.download_for_offline_outlined,
                        ),
                        title: const Text(MossTtsService.modelName),
                        subtitle: Text(
                          moss.downloading
                              ? '${moss.operationLabel}\n'
                                    '${_formatBytes(moss.downloadedBytes)} / '
                                    '${_formatBytes(moss.totalDownloadBytes)}'
                              : moss.generating
                              ? '正在进行端侧语音推理'
                              : moss.ready
                              ? '已就绪 · ${moss.accelerationLabel} · 48 kHz · 中文/英文/日文'
                              : '${_formatBytes(MossTtsService.modelBytes)} · ${moss.accelerationLabel}',
                        ),
                        trailing: moss.downloading
                            ? IconButton(
                                tooltip: '暂停下载',
                                onPressed: moss.pauseDownload,
                                icon: const Icon(Icons.pause_circle_outline),
                              )
                            : moss.ready
                            ? IconButton(
                                tooltip: '删除 MOSS-TTS-Nano',
                                onPressed: _deleteMossTts,
                                icon: const Icon(Icons.delete_outline),
                              )
                            : IconButton(
                                tooltip: '下载 MOSS-TTS-Nano',
                                onPressed: _downloadMossTts,
                                icon: const Icon(Icons.download_outlined),
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
                                  decoration: const InputDecoration(
                                    labelText: 'MOSS 内置克隆音色',
                                    prefixIcon: Icon(Icons.record_voice_over),
                                    border: OutlineInputBorder(),
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
                                    ? '停止试听'
                                    : '试听当前音色',
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
                      if (moss.downloading)
                        LinearProgressIndicator(value: moss.downloadProgress),
                      if (moss.generating) const LinearProgressIndicator(),
                      if (moss.lastError != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          moss.lastError!,
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
            if (defaultTargetPlatform == TargetPlatform.android) ...[
              Text(
                'Android 系统端侧语音',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              AnimatedBuilder(
                animation: OfflineSpeechService.instance,
                builder: (context, _) {
                  final speech = OfflineSpeechService.instance;
                  final capabilities = speech.systemCapabilities;
                  return Column(
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          capabilities.offlineTts
                              ? Icons.record_voice_over
                              : Icons.download_for_offline_outlined,
                        ),
                        title: const Text('离线 TTS'),
                        subtitle: Text(
                          capabilities.offlineTts
                              ? '${capabilities.ttsLocale} · ${capabilities.ttsVoice}'
                              : '未检测到离线语音包',
                        ),
                        trailing: IconButton(
                          tooltip: '安装或管理离线 TTS 数据',
                          icon: const Icon(Icons.settings_voice_outlined),
                          onPressed: () =>
                              _openSpeechSetup(speech.installOfflineTtsData),
                        ),
                      ),
                      if (capabilities.offlineTts &&
                          capabilities.ttsVoices.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: DropdownButtonFormField<String>(
                            key: ValueKey(capabilities.ttsVoice),
                            initialValue:
                                capabilities.ttsVoices.any(
                                  (voice) =>
                                      voice.name == capabilities.ttsVoice,
                                )
                                ? capabilities.ttsVoice
                                : capabilities.ttsVoices.first.name,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: '离线朗读音色',
                              prefixIcon: Icon(
                                Icons.spatial_audio_off_outlined,
                              ),
                              border: OutlineInputBorder(),
                            ),
                            items: capabilities.ttsVoices
                                .map(
                                  (voice) => DropdownMenuItem(
                                    value: voice.name,
                                    child: Text(
                                      voice.displayLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(growable: false),
                            onChanged: _selectSystemTtsVoice,
                          ),
                        ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          capabilities.offlineStt
                              ? Icons.mic
                              : Icons.mic_off_outlined,
                        ),
                        title: const Text('离线语音识别'),
                        subtitle: Text(
                          speech.sttModelDownloadProgress != null &&
                                  speech.sttModelDownloadProgress! < 100
                              ? '中文模型下载 ${speech.sttModelDownloadProgress}%'
                              : speech.sttModelDownloadScheduled
                              ? '中文模型已加入系统下载队列'
                              : capabilities.offlineStt
                              ? '${capabilities.sttLocale} · 端侧识别器可用'
                              : '未检测到系统端侧识别器',
                        ),
                        trailing: IconButton(
                          tooltip: capabilities.sttModelDownload
                              ? '下载中文端侧识别模型'
                              : '打开系统语音输入设置',
                          icon: Icon(
                            capabilities.sttModelDownload
                                ? Icons.download_for_offline_outlined
                                : Icons.tune_outlined,
                          ),
                          onPressed: capabilities.sttModelDownload
                              ? _downloadSpeechModel
                              : () => _openSpeechSetup(
                                  speech.openVoiceInputSettings,
                                ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
