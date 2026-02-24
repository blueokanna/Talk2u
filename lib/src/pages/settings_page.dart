import 'package:flutter/material.dart';
import 'package:talk2u/src/rust/api/chat_api.dart' as rust_api;
import 'package:talk2u/src/rust/api/data_models.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _apiKeyController = TextEditingController();
  bool _enableThinkingByDefault = true;
  bool _obscureApiKey = true;
  bool _isLoading = true;
  String _chatModel = 'glm-4.7';
  String _thinkingModel = 'glm-4-air';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await rust_api.getSettings();
      setState(() {
        _apiKeyController.text = settings.apiKey ?? '';
        _enableThinkingByDefault = settings.enableThinkingByDefault;
        _chatModel = settings.chatModel;
        _thinkingModel = settings.thinkingModel;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载设置失败: $e')));
      }
    }
  }

  Future<void> _saveSettings() async {
    try {
      final apiKey = _apiKeyController.text.trim();

      if (apiKey.isNotEmpty) {
        final isValid = await rust_api.validateApiKey(apiKey: apiKey);
        if (!isValid) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('API 密钥格式无效，应为 user_id.user_secret'),
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            );
          }
          return;
        }
      }

      final settings = AppSettings(
        apiKey: apiKey.isEmpty ? null : apiKey,
        defaultModel: _chatModel,
        enableThinkingByDefault: _enableThinkingByDefault,
        chatModel: _chatModel,
        thinkingModel: _thinkingModel,
      );

      await rust_api.saveSettings(settings: settings);

      if (apiKey.isNotEmpty) {
        await rust_api.setApiKey(apiKey: apiKey);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('设置已保存'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败: $e')));
      }
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('设置')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('设置'), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // API Key section
          _buildApiKeyCard(theme),
          const SizedBox(height: 16),

          // Thinking toggle
          _buildThinkingToggle(theme),
          const SizedBox(height: 16),

          // Model info
          _buildModelInfoCard(theme),
          const SizedBox(height: 32),

          FilledButton.icon(
            onPressed: _saveSettings,
            icon: const Icon(Icons.save_rounded),
            label: const Text('保存设置'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildApiKeyCard(ThemeData theme) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.key_rounded,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text('API 密钥', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiKeyController,
              obscureText: _obscureApiKey,
              decoration: InputDecoration(
                hintText: 'user_id.user_secret',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureApiKey
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () =>
                      setState(() => _obscureApiKey = !_obscureApiKey),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '从 open.bigmodel.cn 获取你的 API 密钥',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThinkingToggle(ThemeData theme) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SwitchListTile(
        title: Row(
          children: [
            Icon(
              Icons.psychology_rounded,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            const Text('默认启用深度思考'),
          ],
        ),
        subtitle: const Padding(
          padding: EdgeInsets.only(left: 28),
          child: Text('开启后使用 GLM-4-Air 模型，AI 会先思考再回答'),
        ),
        value: _enableThinkingByDefault,
        onChanged: (value) => setState(() => _enableThinkingByDefault = value),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  Widget _buildModelInfoCard(ThemeData theme) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.smart_toy_outlined,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text('模型信息', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 12),
            _buildInfoRow(theme, '对话模型', 'GLM-4.7 / GLM-4.7-Flash'),
            _buildInfoRow(theme, '推理模型', 'GLM-4-Air（带思考）'),
            _buildInfoRow(
              theme,
              '总结模型',
              '自动选择（≤100K: GLM-4.7-Flash, >100K: GLM-4-Long）',
            ),
            _buildInfoRow(
              theme,
              '上下文',
              'GLM-4.7: 200K / GLM-4-Air: 128K / GLM-4-Long: 1M',
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(
                  alpha: 0.3,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '记忆系统',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '每8轮对话自动总结，使用 BM25 + 语义检索 + RRF 融合排序。'
                    '压缩代数追踪：核心事实无损保留，边缘信息随压缩次数渐进退化',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          Flexible(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}
