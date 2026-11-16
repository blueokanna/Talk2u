import 'package:flutter/material.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/l10n/provider_names.dart';
import 'package:talk2u/src/rust/api/data_models.dart';
import 'package:talk2u/src/state/chat_state.dart';

/// Bottom sheet with character context, dialogue style, provider and model.
///
/// It rebuilds from [ChatState] itself, so provider/model/style changes are
/// reflected without a StatefulBuilder. Closing the sheet is the caller's job
/// for destructive actions (restart), while benign selections stay in place.
Future<void> showChatOptionsSheet(
  BuildContext context, {
  required ChatState chatState,
  required VoidCallback onRestartStory,
}) {
  final theme = Theme.of(context);
  final strings = AppLocalizations.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) {
      final maxHeight = MediaQuery.sizeOf(sheetContext).height * 0.85;
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: AnimatedBuilder(
              animation: chatState,
              builder: (context, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (chatState.currentCharacter != null) ...[
                    _OptionSection(
                      title: chatState.currentCharacter!.name,
                      subtitle: chatState.currentCharacter!.description,
                    ),
                    const Divider(height: 24),
                  ],
                  if (chatState.currentConversationId != null)
                    ListTile(
                      leading: Icon(
                        Icons.refresh_rounded,
                        color: theme.colorScheme.primary,
                      ),
                      title: Text(strings.restart),
                      subtitle: Text(strings.restartConversationSubtitle),
                      contentPadding: EdgeInsets.zero,
                      onTap: () {
                        Navigator.pop(sheetContext);
                        onRestartStory();
                      },
                    ),
                  const Divider(height: 24),
                  Text(
                    strings.conversationStyle,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _StyleChip(
                        label: strings.styleFree,
                        style: DialogueStyle.free,
                        current: chatState.dialogueStyle,
                        chatState: chatState,
                      ),
                      _StyleChip(
                        label: strings.styleDialogue,
                        style: DialogueStyle.sayOnly,
                        current: chatState.dialogueStyle,
                        chatState: chatState,
                      ),
                      _StyleChip(
                        label: strings.styleAction,
                        style: DialogueStyle.doOnly,
                        current: chatState.dialogueStyle,
                        chatState: chatState,
                      ),
                      _StyleChip(
                        label: strings.styleMixed,
                        style: DialogueStyle.mixed,
                        current: chatState.dialogueStyle,
                        chatState: chatState,
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  Text(
                    strings.providerAndModel,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: chatState.selectedProviderId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: strings.apiProvider,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.hub_outlined),
                    ),
                    items: chatState.providers
                        .map(
                          (provider) => DropdownMenuItem(
                            value: provider.id,
                            child: Text(
                              provider.isConfigured
                                  ? providerDisplayName(provider, strings)
                                  : strings.providerNotConfigured(
                                      providerDisplayName(provider, strings),
                                    ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: chatState.isStreaming
                        ? null
                        : (value) {
                            if (value == null) return;
                            chatState.setSelectedProvider(value);
                          },
                  ),
                  const SizedBox(height: 12),
                  RadioGroup<String>(
                    groupValue: chatState.selectedModel,
                    onChanged: (value) {
                      if (value != null) chatState.setSelectedModel(value);
                    },
                    child: Column(
                      children: [
                        _ModelOption(
                          name:
                              chatState.selectedProvider?.chatModel ??
                              strings.notConfigured,
                          description: strings.chatModel,
                          modelId: chatState.selectedProvider?.chatModel ?? '',
                          supportsThinking: false,
                        ),
                        if (chatState.selectedProvider?.supportsThinking ==
                            true)
                          _ModelOption(
                            name: chatState.selectedProvider!.thinkingModel!,
                            description: strings.reasoningModelHint,
                            modelId: chatState.selectedProvider!.thinkingModel!,
                            supportsThinking: true,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _OptionSection extends StatelessWidget {
  const _OptionSection({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        CircleAvatar(
          radius: 20,
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Text(
            title.characters.first,
            style: TextStyle(
              fontSize: 18,
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
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StyleChip extends StatelessWidget {
  const _StyleChip({
    required this.label,
    required this.style,
    required this.current,
    required this.chatState,
  });

  final String label;
  final DialogueStyle style;
  final DialogueStyle current;
  final ChatState chatState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = style == current;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => chatState.setDialogueStyle(style),
      selectedColor: theme.colorScheme.primaryContainer,
      checkmarkColor: theme.colorScheme.onPrimaryContainer,
      labelStyle: theme.textTheme.labelLarge?.copyWith(
        color: selected
            ? theme.colorScheme.onPrimaryContainer
            : theme.colorScheme.onSurfaceVariant,
      ),
      side: BorderSide(
        color: selected
            ? theme.colorScheme.primary
            : theme.colorScheme.outlineVariant,
      ),
    );
  }
}

class _ModelOption extends StatelessWidget {
  const _ModelOption({
    required this.name,
    required this.description,
    required this.modelId,
    required this.supportsThinking,
  });

  final String name;
  final String description;
  final String modelId;
  final bool supportsThinking;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = AppLocalizations.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Radio<String>(value: modelId),
      title: Row(
        children: [
          Text(name),
          if (supportsThinking) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                strings.thinking,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        description,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
    );
  }
}
