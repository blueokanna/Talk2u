import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/models/character.dart';
import 'package:talk2u/src/pages/character_edit_page.dart';
import 'package:talk2u/src/theme/app_shapes.dart';
import 'package:talk2u/src/widgets/aurora_backdrop.dart';

/// Character library: the plain assistant entry and every saved persona.
///
/// Cards, chips and the shared greeting surface all take their geometry from
/// [AppShapes] and their colours from the Material 3 scheme. No raw `Colors.*`
/// value appears here: the gender accent uses the primary/tertiary/secondary
/// roles so it survives a light/dark switch and an expressive seed change.
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
    if (result != null && mounted) setState(() {});
  }

  Future<void> _editCharacter(Character character) async {
    final result = await Navigator.push<Character>(
      context,
      MaterialPageRoute(
        builder: (_) => CharacterEditPage(character: character),
      ),
    );
    if (result != null && mounted) setState(() {});
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
              foregroundColor: Theme.of(ctx).colorScheme.onError,
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
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          count > 0
              ? strings.charactersImported(count)
              : strings.characterImportFailed,
        ),
      ),
    );
  }

  Future<void> _exportCharacter(Character character) async {
    final strings = AppLocalizations.of(context);
    try {
      final path = await CharacterStore.instance.exportCharacter(character);
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path)],
          text: strings.shareCharacter(character.name),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.exportFailed('$error'))));
    }
  }

  Future<void> _exportAllCharacters() async {
    if (CharacterStore.instance.characters.isEmpty) return;
    final strings = AppLocalizations.of(context);
    try {
      final path = await CharacterStore.instance.exportAllCharacters();
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], text: strings.shareAllCharacters),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.exportFailed('$error'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);

    return AuroraBackdrop(
      child: Scaffold(
        appBar: AppBar(
          title: Text(strings.charactersTitle),
          actions: [
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'import',
                  child: _MenuRow(
                    icon: Icons.file_download_rounded,
                    label: strings.importCharacters,
                  ),
                ),
                PopupMenuItem(
                  value: 'export_all',
                  child: _MenuRow(
                    icon: Icons.file_upload_rounded,
                    label: strings.exportAll,
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
            : _buildCharacterList(strings),
      ),
    );
  }

  Widget _buildCharacterList(AppLocalizations strings) {
    final characters = CharacterStore.instance.characters;
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: characters.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.primaryContainer,
                  foregroundColor: Theme.of(
                    context,
                  ).colorScheme.onPrimaryContainer,
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
            ),
          );
        }
        final character = characters[index - 1];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _CharacterCard(
            character: character,
            onTap: () => widget.onSelectCharacter?.call(character),
            onEdit: () => _editCharacter(character),
            onDelete: () => _deleteCharacter(character),
            onExport: (c) => _exportCharacter(c),
          ),
        );
      },
    );
  }
}

/// One popup-menu row: leading icon plus label.
///
/// A Material 3 menu item is a single 48 dp row. Nesting a [ListTile] inside a
/// [PopupMenuItem] doubles the padding and pushes the menu past the spec, so the
/// row is composed directly instead.
class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final effective = color ?? Theme.of(context).colorScheme.onSurface;
    return Row(
      children: [
        Icon(icon, size: 20, color: effective),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: effective)),
      ],
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
    final colors = theme.colorScheme;
    final genderIcon = switch (character.gender) {
      CharacterGender.male => Icons.male_rounded,
      CharacterGender.female => Icons.female_rounded,
      CharacterGender.other => Icons.transgender_rounded,
    };
    final genderColor = switch (character.gender) {
      CharacterGender.male => colors.primary,
      CharacterGender.female => colors.tertiary,
      CharacterGender.other => colors.secondary,
    };

    return Card(
      child: InkWell(
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
                    backgroundColor: colors.primaryContainer,
                    child: Text(
                      character.name.isNotEmpty
                          ? character.name.characters.first
                          : '?',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: colors.onPrimaryContainer,
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
                                style: theme.textTheme.titleMedium,
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
                              color: colors.onSurfaceVariant,
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
                      color: colors.onSurfaceVariant,
                    ),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'edit',
                        child: _MenuRow(
                          icon: Icons.edit_rounded,
                          label: strings.edit,
                        ),
                      ),
                      PopupMenuItem(
                        value: 'export',
                        child: _MenuRow(
                          icon: Icons.file_upload_rounded,
                          label: strings.export,
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: _MenuRow(
                          icon: Icons.delete_rounded,
                          label: strings.delete,
                          color: colors.error,
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
                          decoration: ShapeDecoration(
                            color: colors.secondaryContainer,
                            shape: AppShapes.badge,
                          ),
                          child: Text(
                            tag,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colors.onSecondaryContainer,
                            ),
                          ),
                        ),
                      )
                      .toList(growable: false),
                ),
              ],
              if (character.greeting.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: ShapeDecoration(
                    color: colors.surfaceContainerHighest,
                    shape: AppShapes.field,
                  ),
                  child: Text(
                    character.greeting,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
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
