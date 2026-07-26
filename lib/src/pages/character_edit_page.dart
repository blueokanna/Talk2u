import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:talk2u/src/models/character.dart';
import 'package:talk2u/src/services/live2d_model_importer.dart';

class CharacterEditPage extends StatefulWidget {
  final Character? character;

  const CharacterEditPage({super.key, this.character});

  @override
  State<CharacterEditPage> createState() => _CharacterEditPageState();
}

class _CharacterEditPageState extends State<CharacterEditPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _settingController = TextEditingController();
  final _greetingController = TextEditingController();
  final _dialogueExampleController = TextEditingController();
  final _userNameController = TextEditingController();
  final _userSettingController = TextEditingController();
  final _tagController = TextEditingController();
  final _live2dModelController = TextEditingController();

  CharacterGender _gender = CharacterGender.other;
  List<String> _tags = [];
  bool _isSaving = false;
  bool _isImportingLive2d = false;

  bool get _isEditing => widget.character != null;

  @override
  void initState() {
    super.initState();
    if (widget.character != null) {
      final c = widget.character!;
      _nameController.text = c.name;
      _descriptionController.text = c.description;
      _settingController.text = c.setting;
      _greetingController.text = c.greeting;
      _dialogueExampleController.text = c.dialogueExample;
      _userNameController.text = c.userName;
      _userSettingController.text = c.userSetting;
      _live2dModelController.text = c.live2dModelPath;
      _gender = c.gender;
      _tags = List.from(c.tags);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _settingController.dispose();
    _greetingController.dispose();
    _dialogueExampleController.dispose();
    _userNameController.dispose();
    _userSettingController.dispose();
    _tagController.dispose();
    _live2dModelController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final character = Character(
        id:
            widget.character?.id ??
            DateTime.now().microsecondsSinceEpoch.toRadixString(36),
        name: _nameController.text.trim(),
        gender: _gender,
        description: _descriptionController.text.trim(),
        setting: _settingController.text.trim(),
        greeting: _greetingController.text.trim(),
        dialogueExample: _dialogueExampleController.text.trim(),
        userName: _userNameController.text.trim(),
        userSetting: _userSettingController.text.trim(),
        tags: _tags,
        live2dModelPath: _live2dModelController.text.trim(),
        createdAt: widget.character?.createdAt ?? now,
        updatedAt: now,
      );

      await CharacterStore.instance.save(character);

      if (mounted) {
        Navigator.pop(context, character);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _addTag() {
    final tag = _tagController.text.trim();
    if (tag.isNotEmpty && !_tags.contains(tag)) {
      setState(() {
        _tags.add(tag);
        _tagController.clear();
      });
    }
  }

  void _removeTag(String tag) {
    setState(() => _tags.remove(tag));
  }

  Future<void> _pickLive2dModel() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    setState(() => _isImportingLive2d = true);
    try {
      final modelPaths = await Live2dModelImporter.importArchiveModels(path);
      if (!mounted) return;
      final modelPath = await _selectImportedModel(modelPaths);
      if (modelPath == null || !mounted) return;
      setState(() => _live2dModelController.text = modelPath);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Live2D 模型已导入，共发现 ${modelPaths.length} 个模型')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Live2D 模型导入失败: $error')));
    } finally {
      if (mounted) setState(() => _isImportingLive2d = false);
    }
  }

  Future<String?> _selectImportedModel(List<String> modelPaths) async {
    if (modelPaths.length == 1) return modelPaths.first;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('选择 Live2D 模型'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 360),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: modelPaths.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, index) {
              final path = modelPaths[index];
              final name = path.replaceAll('\\', '/').split('/').last;
              return ListTile(
                leading: const Icon(Icons.view_in_ar_outlined),
                title: Text(name),
                subtitle: Text(
                  path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(dialogContext, path),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<void> _installBundledMao() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('使用虹色 Mao 示例模型'),
        content: const Text(
          '该模型由 Live2D Inc. 提供，使用前必须同意 Cubism 示例模型使用授权要求。'
          '仓库中的 model/mao/ReadMe.txt 包含来源与许可说明。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('我已阅读并同意'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() => _isImportingLive2d = true);
    try {
      final modelPath = await Live2dModelImporter.installBundledMao();
      if (!mounted) return;
      setState(() => _live2dModelController.text = modelPath);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Cubism 5 Mao 模型已安装')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('内置模型安装失败: $error')));
    } finally {
      if (mounted) setState(() => _isImportingLive2d = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑角色' : '创建角色'),
        centerTitle: true,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _buildSectionCard(
              theme,
              children: [
                _buildFieldLabel(theme, '姓名', required: true),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _nameController,
                  maxLength: 10,
                  decoration: _inputDecoration('输入AI昵称'),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? '请输入角色名称' : null,
                ),
                const SizedBox(height: 16),
                _buildFieldLabel(theme, '性别', required: true),
                const SizedBox(height: 8),
                _buildGenderSelector(theme),
              ],
            ),
            const SizedBox(height: 16),
            _buildSectionCard(
              theme,
              children: [
                _buildFieldLabel(theme, '角色设定', required: true),
                const SizedBox(height: 4),
                Text(
                  '填写AI角色设定信息，会影响对话效果；可以描述背景、角色性格、身份、与你的关系等。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _settingController,
                  maxLength: 1200,
                  maxLines: 6,
                  minLines: 4,
                  decoration: _inputDecoration('描述角色的性格、身份、背景等'),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? '请输入角色设定' : null,
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildSectionCard(
              theme,
              children: [
                _buildFieldLabel(theme, '角色简介'),
                const SizedBox(height: 4),
                Text(
                  '介绍你的AI角色，不影响对话效果；一个有趣的简介能够增加聊天的兴趣',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _descriptionController,
                  maxLength: 1000,
                  maxLines: 5,
                  minLines: 3,
                  decoration: _inputDecoration('介绍你的AI角色'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildSectionCard(
              theme,
              children: [
                _buildFieldLabel(theme, '角色开场白'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _greetingController,
                  maxLength: 200,
                  maxLines: 4,
                  minLines: 2,
                  decoration: _inputDecoration('请输入角色开场白'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildSectionCard(
              theme,
              children: [
                _buildFieldLabel(theme, '对话风格示例'),
                const SizedBox(height: 4),
                Text(
                  '请填写体现AI角色说话风格、说话语气的对话文本。\n如：不许看别人，乖乖在我身边，哪都不许去。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _dialogueExampleController,
                  maxLength: 100,
                  maxLines: 3,
                  minLines: 2,
                  decoration: _inputDecoration('体现角色说话风格的示例'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildSectionCard(
              theme,
              children: [
                _buildFieldLabel(theme, '用户名称'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _userNameController,
                  maxLength: 10,
                  decoration: _inputDecoration('AI对你的称呼'),
                ),
                const SizedBox(height: 16),
                _buildFieldLabel(theme, '用户聊天人设'),
                const SizedBox(height: 4),
                Text(
                  'AI眼中你扮演的身份，可以描述角色性格、身份、经历等',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _userSettingController,
                  maxLength: 500,
                  maxLines: 4,
                  minLines: 2,
                  decoration: _inputDecoration('描述你在对话中的身份'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildSectionCard(
              theme,
              children: [
                _buildFieldLabel(theme, 'Live2D 模型'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _live2dModelController,
                  readOnly: true,
                  decoration: _inputDecoration('未导入 Live2D ZIP 模型包').copyWith(
                    prefixIcon: const Icon(Icons.view_in_ar_outlined),
                    suffixIcon: _isImportingLive2d
                        ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : IconButton(
                            tooltip: '导入 Live2D ZIP 模型包',
                            icon: const Icon(Icons.folder_open_outlined),
                            onPressed: _pickLive2dModel,
                          ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _isImportingLive2d ? null : _installBundledMao,
                    icon: const Icon(Icons.download_for_offline_outlined),
                    label: const Text('安装内置 Cubism 5 Mao 模型'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildSectionCard(
              theme,
              children: [
                _buildFieldLabel(theme, '标签'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ..._tags.map(
                      (tag) => Chip(
                        label: Text(tag),
                        onDeleted: () => _removeTag(tag),
                        deleteIconColor: theme.colorScheme.error,
                        side: BorderSide(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 18),
                      label: const Text('添加标签'),
                      onPressed: () => _showAddTagDialog(theme),
                      side: BorderSide(
                        color: theme.colorScheme.outlineVariant,
                        style: BorderStyle.solid,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: _isSaving ? null : _save,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
              child: _isSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('确认'),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionCard(ThemeData theme, {required List<Widget> children}) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }

  Widget _buildFieldLabel(
    ThemeData theme,
    String label, {
    bool required = false,
  }) {
    return Row(
      children: [
        if (required)
          Text(
            '* ',
            style: TextStyle(
              color: theme.colorScheme.error,
              fontWeight: FontWeight.w600,
            ),
          ),
        Text(
          label,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildGenderSelector(ThemeData theme) {
    return Row(
      children: CharacterGender.values.map((g) {
        final label = switch (g) {
          CharacterGender.male => '男性',
          CharacterGender.female => '女性',
          CharacterGender.other => '其他',
        };
        final isSelected = _gender == g;
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: Text(label),
            selected: isSelected,
            onSelected: (_) => setState(() => _gender = g),
            selectedColor: theme.colorScheme.primaryContainer,
            side: BorderSide(
              color: isSelected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
          ),
        );
      }).toList(),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    );
  }

  void _showAddTagDialog(ThemeData theme) {
    _tagController.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加标签'),
        content: TextField(
          controller: _tagController,
          autofocus: true,
          decoration: _inputDecoration('输入标签名称'),
          onSubmitted: (_) {
            _addTag();
            Navigator.pop(ctx);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              _addTag();
              Navigator.pop(ctx);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }
}
