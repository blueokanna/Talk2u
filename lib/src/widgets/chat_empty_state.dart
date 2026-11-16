import 'package:flutter/material.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';

/// Empty transcript placeholder shown before the first message.
class ChatEmptyState extends StatelessWidget {
  const ChatEmptyState({super.key, required this.onChooseCharacter});

  final VoidCallback onChooseCharacter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = AppLocalizations.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final minimumHeight = (constraints.maxHeight - 32)
            .clamp(0.0, double.infinity)
            .toDouble();
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minimumHeight),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 64,
                    color: theme.colorScheme.outline.withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    strings.startNewConversation,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    strings.startNewConversationHint,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.outline.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.tonalIcon(
                    onPressed: onChooseCharacter,
                    icon: const Icon(Icons.person_add_rounded),
                    label: Text(strings.chooseCharacter),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
