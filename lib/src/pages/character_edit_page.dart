import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
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
    final strings = AppLocalizations.of(context);

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
        ).showSnackBar(
          SnackBar(content: Text(strings.characterSaveFailed('$e'))),
        );
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
    final strings = AppLocalizations.of(context);
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
        SnackBar(content: Text(strings.live2dModelsImported(modelPaths.length))),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        SnackBar(content: Text(strings.live2dModelImportFailed('$error'))),
      );
    } finally {
      if (mounted) setState(() => _isImportingLive2d = false);
    }
  }

  Future<String?> _selectImportedModel(List<String> modelPaths) async {
    if (modelPaths.length == 1) return modelPaths.first;
    final strings = AppLocalizations.of(context);
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.chooseLive2dModel),
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
            child: Text(strings.cancel),
          ),
        ],
      ),
    );
  }

  Future<void> _installBundledMao() async {
    final strings = AppLocalizations.of(context);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.maoLicenseTitle),
        content: Text(strings.maoLicenseDescription),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(strings.licenseAccepted),
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
      ).showSnackBar(SnackBar(content: Text(strings.maoInstalled)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        SnackBar(content: Text(strings.maoInstallFailed('$error'))),
      );
    } finally {
      if (mounted) setState(() => _isImportingLive2d = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isEditing ? strings.editCharacter : strings.createCharacter,
        ),
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
                _buildFieldLabel(theme, strings.characterName, required: true),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _nameController,
                  maxLength: 10,
                  decoration: _inputDecoration(strings.characterNameHint),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? strings.characterNameRequired
                      : null,
                ),
                const SizedBox(height: 16),
                _buildFieldLabel(theme, strings.gender, required: true),
                const SizedBox(height: 8),
                _buildGenderSelector(theme),
              ],
            ),
            const SizedBox(height: 16),
            _buildSectionCard(
              theme,
              children: [
                _buildFieldLabel(
                  theme,
                  strings.characterSetting,
                  required: true,
                ),
                const SizedBox(height: 4),
                Text(
                  strings.characterSettingHelp,
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
                  decoration: _inputDecoration(strings.characterSettingHint),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? strings.characterSettingRequired
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildSectionCard(
              theme,
              children: [
                _buildFieldLabel(theme, strings.characterDescription),
                const SizedBox(height: 4),
                Text(
                  strings.characterDescriptionHelp,
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
                  decoration: _inputDecoration(strings.characterDescriptionHint),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildSectionCard(
              theme,
              children: [
                _buildFieldLabel(theme, strings.characterGreeting),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _greetingController,
                  maxLength: 200,
                  maxLines: 4,
                  minLines: 2,
                  decoration: _inputDecoration(strings.characterGreetingHint),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildSectionCard(
              theme,
              children: [
                _buildFieldLabel(theme, strings.dialogueStyleExample),
                const SizedBox(height: 4),
                Text(
                  strings.dialogueStyleHelp,
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
                  decoration: _inputDecoration(strings.dialogueStyleHint),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildSectionCard(
              theme,
              children: [
                _buildFieldLabel(theme, strings.userName),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _userNameController,
                  maxLength: 10,
                  decoration: _inputDecoration(strings.userNameHint),
                ),
                const SizedBox(height: 16),
                _buildFieldLabel(theme, strings.userPersona),
                const SizedBox(height: 4),
                Text(
                  strings.userPersonaHelp,
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
                  decoration: _inputDecoration(strings.userPersonaHint),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildSectionCard(
              theme,
              children: [
                _buildFieldLabel(theme, strings.live2dModel),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _live2dModelController,
                  readOnly: true,
                  decoration: _inputDecoration(strings.noLive2dModel).copyWith(
                    prefixIcon: const Icon(Icons.view_in_ar_outlined),
                    suffixIcon: _isImportingLive2d
                        ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : IconButton(
                            tooltip: strings.importLive2dModel,
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
                    label: Text(strings.installMaoModel),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildSectionCard(
              theme,
              children: [
                _buildFieldLabel(theme, strings.tags),
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
                      label: Text(strings.addTag),
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
                  : Text(strings.confirm),
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
    final strings = AppLocalizations.of(context);
    return Row(
      children: CharacterGender.values.map((g) {
        final label = switch (g) {
          CharacterGender.male => strings.genderMale,
          CharacterGender.female => strings.genderFemale,
          CharacterGender.other => strings.genderOther,
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
    final strings = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.addTag),
        content: TextField(
          controller: _tagController,
          autofocus: true,
          decoration: _inputDecoration(strings.tagNameHint),
          onSubmitted: (_) {
            _addTag();
            Navigator.pop(ctx);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () {
              _addTag();
              Navigator.pop(ctx);
            },
            child: Text(strings.addTag),
          ),
        ],
      ),
    );
  }
}
