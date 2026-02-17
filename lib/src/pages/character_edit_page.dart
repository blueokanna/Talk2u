import 'package:flutter/material.dart';
import 'package:talk2u/src/models/character.dart';

class CharacterEditPage extends StatefulWidget {
  final Character? character; // null = 创建新角色

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

  CharacterGender _gender = CharacterGender.other;
  List<String> _tags = [];
  bool _isSaving = false;

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
