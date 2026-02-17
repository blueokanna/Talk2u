import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:talk2u/src/models/character.dart';
import 'package:talk2u/src/pages/character_edit_page.dart';

class CharacterListPage extends StatefulWidget {
  final ValueChanged<Character>? onSelectCharacter;

  const CharacterListPage({super.key, this.onSelectCharacter});

  @override
  State<CharacterListPage> createState() => _CharacterListPageState();
}

class _CharacterListPageState extends State<CharacterListPage> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadCharacters();
  }

  Future<void> _loadCharacters() async {
    await CharacterStore.instance.load();
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _createCharacter() async {
    final result = await Navigator.push<Character>(
      context,
      MaterialPageRoute(builder: (_) => const CharacterEditPage()),
    );
    if (result != null && mounted) {
      setState(() {});
    }
  }

  Future<void> _editCharacter(Character character) async {
    final result = await Navigator.push<Character>(
      context,
      MaterialPageRoute(
        builder: (_) => CharacterEditPage(character: character),
      ),
    );
    if (result != null && mounted) {
      setState(() {});
    }
  }

  Future<void> _deleteCharacter(Character character) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除角色'),
        content: Text('确定要删除"${character.name}"吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await CharacterStore.instance.delete(character.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _importCharacter() async {
    final count = await CharacterStore.instance.importFromPicker();
    if (!mounted) return;
    if (count > 0) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('成功导入 $count 个角色'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('导入失败，请检查文件格式'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    }
  }

  Future<void> _exportCharacter(Character character) async {
    try {
      final path = await CharacterStore.instance.exportCharacter(character);
      if (!mounted) return;
      await Share.shareXFiles([XFile(path)], text: '角色配置：${character.name}');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('导出失败: $e'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    }
  }

  Future<void> _exportAllCharacters() async {
    if (CharacterStore.instance.characters.isEmpty) return;
    try {
      final path = await CharacterStore.instance.exportAllCharacters();
      if (!mounted) return;
      await Share.shareXFiles([XFile(path)], text: '全部角色配置');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('导出失败: $e'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的角色'),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'import',
                child: Row(
                  children: [
                    Icon(Icons.file_download_rounded, size: 20),
                    SizedBox(width: 12),
                    Text('导入角色'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'export_all',
                child: Row(
                  children: [
                    Icon(Icons.file_upload_rounded, size: 20),
                    SizedBox(width: 12),
                    Text('导出全部'),
                  ],
                ),
              ),
            ],
            onSelected: (value) {
              if (value == 'import') _importCharacter();
              if (value == 'export_all') _exportAllCharacters();
            },
          ),
          IconButton(
            icon: const Icon(Icons.add_rounded),
            tooltip: '创建角色',
            onPressed: _createCharacter,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : CharacterStore.instance.characters.isEmpty
          ? _buildEmptyState(theme)
          : _buildCharacterGrid(theme),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.person_add_rounded,
            size: 64,
            color: theme.colorScheme.outline.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            '还没有角色',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '创建一个AI角色开始角色扮演聊天',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _createCharacter,
            icon: const Icon(Icons.add_rounded),
            label: const Text('创建角色'),
          ),
        ],
      ),
    );
  }

  Widget _buildCharacterGrid(ThemeData theme) {
    final characters = CharacterStore.instance.characters;
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: characters.length,
      itemBuilder: (context, index) {
        final character = characters[index];
        return _CharacterCard(
          character: character,
          onTap: () => widget.onSelectCharacter?.call(character),
          onEdit: () => _editCharacter(character),
          onDelete: () => _deleteCharacter(character),
          onExport: (c) => _exportCharacter(c),
        );
      },
    );
  }
}

class _CharacterCard extends StatelessWidget {
  final Character character;
  final VoidCallback? onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final ValueChanged<Character>? onExport;

  const _CharacterCard({
    required this.character,
    this.onTap,
    this.onEdit,
    this.onDelete,
    this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final genderIcon = switch (character.gender) {
      CharacterGender.male => Icons.male_rounded,
      CharacterGender.female => Icons.female_rounded,
      CharacterGender.other => Icons.transgender_rounded,
    };
    final genderColor = switch (character.gender) {
      CharacterGender.male => Colors.blue,
      CharacterGender.female => Colors.pink,
      CharacterGender.other => theme.colorScheme.outline,
    };

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Text(
                      character.name.isNotEmpty
                          ? character.name.characters.first
                          : '?',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                character.name,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Icon(genderIcon, size: 18, color: genderColor),
                          ],
                        ),
                        if (character.description.isNotEmpty)
                          Text(
                            character.description,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: Icon(
                      Icons.more_vert_rounded,
                      color: theme.colorScheme.outline,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'edit',
                        child: Row(
                          children: [
                            Icon(Icons.edit_rounded, size: 20),
                            SizedBox(width: 12),
                            Text('编辑'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'export',
                        child: Row(
                          children: [
                            Icon(Icons.file_upload_rounded, size: 20),
                            SizedBox(width: 12),
                            Text('导出'),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(
                              Icons.delete_rounded,
                              size: 20,
                              color: theme.colorScheme.error,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              '删除',
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ],
                        ),
                      ),
                    ],
                    onSelected: (value) {
                      if (value == 'edit') onEdit?.call();
                      if (value == 'export') onExport?.call(character);
                      if (value == 'delete') onDelete?.call();
                    },
                  ),
                ],
              ),
              if (character.tags.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: character.tags
                      .map(
                        (tag) => Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer
                                .withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            tag,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
              if (character.greeting.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    character.greeting,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
