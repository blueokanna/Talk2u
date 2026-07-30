import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/models/character.dart';
import 'package:talk2u/src/pages/character_edit_page.dart';

class CharacterListPage extends StatefulWidget {
  final ValueChanged<Character>? onSelectCharacter;
  final VoidCallback? onSelectAssistant;

  const CharacterListPage({
    super.key,
    this.onSelectCharacter,
    this.onSelectAssistant,
  });

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
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.deleteCharacter),
        content: Text(strings.deleteCharacterConfirm(character.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(strings.delete),
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
    final strings = AppLocalizations.of(context);
    final count = await CharacterStore.instance.importFromPicker();
    if (!mounted) return;
    if (count > 0) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(strings.charactersImported(count)),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(strings.characterImportFailed),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    }
  }

  Future<void> _exportCharacter(Character character) async {
    final strings = AppLocalizations.of(context);
    try {
      final path = await CharacterStore.instance.exportCharacter(character);
      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(path)],
        text: strings.shareCharacter(character.name),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(strings.exportFailed('$e')),
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
    final strings = AppLocalizations.of(context);
    try {
      final path = await CharacterStore.instance.exportAllCharacters();
      if (!mounted) return;
      await Share.shareXFiles([XFile(path)], text: strings.shareAllCharacters);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(strings.exportFailed('$e')),
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
    final strings = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.charactersTitle),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'import',
                child: Row(
                  children: [
                    Icon(Icons.file_download_rounded, size: 20),
                    SizedBox(width: 12),
                    Text(strings.importCharacters),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'export_all',
                child: Row(
                  children: [
                    Icon(Icons.file_upload_rounded, size: 20),
                    SizedBox(width: 12),
                    Text(strings.exportAll),
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
            tooltip: strings.createCharacter,
            onPressed: _createCharacter,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildCharacterList(theme, strings),
    );
  }

  Widget _buildCharacterList(ThemeData theme, AppLocalizations strings) {
    final characters = CharacterStore.instance.characters;
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: characters.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                foregroundColor: theme.colorScheme.onPrimaryContainer,
                child: const Icon(Icons.smart_toy_outlined),
              ),
              title: Text(strings.regularAssistant),
              subtitle: Text(
                characters.isEmpty
                    ? strings.directChat
                    : strings.noCharacterSettings,
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: widget.onSelectAssistant,
            ),
          );
        }
        final character = characters[index - 1];
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
    final strings = AppLocalizations.of(context);
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
                      PopupMenuItem(
                        value: 'edit',
                        child: Row(
                          children: [
                            Icon(Icons.edit_rounded, size: 20),
                            SizedBox(width: 12),
                            Text(strings.edit),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'export',
                        child: Row(
                          children: [
                            Icon(Icons.file_upload_rounded, size: 20),
                            SizedBox(width: 12),
                            Text(strings.export),
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
                              strings.delete,
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
