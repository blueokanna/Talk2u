import 'package:flutter/material.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/theme/app_shapes.dart';

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
                  // Material 3 Expressive gives an empty state one large shape
                  // instead of a bare glyph; the container carries the colour
                  // role, the icon stays on-surface.
                  Container(
                    width: 88,
                    height: 88,
                    decoration: ShapeDecoration(
                      color: theme.colorScheme.primaryContainer,
                      shape: AppShapes.surface,
                    ),
                    child: Icon(
                      Icons.chat_bubble_outline_rounded,
                      size: 40,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    strings.startNewConversation,
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    strings.startNewConversationHint,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
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
