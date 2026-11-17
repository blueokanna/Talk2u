import 'package:flutter/material.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/rust/api/data_models.dart';
import 'package:talk2u/src/theme/app_shapes.dart';

/// Conversation drawer: header, new-conversation action and the saved threads.
///
/// Every surface uses a named shape from [AppShapes]: the selected row, the
/// dismiss background and the swipe action all share one silhouette, so a
/// swipe reveals a shape that already matches the row instead of a generic
/// rounded rectangle.
class ConversationListPage extends StatelessWidget {
  final VoidCallback? onNewConversation;
  final ValueChanged<String>? onSelectConversation;
  final ValueChanged<String>? onDeleteConversation;
  final List<ConversationSummary> conversations;
  final String? currentConversationId;

  const ConversationListPage({
    super.key,
    this.onNewConversation,
    this.onSelectConversation,
    this.onDeleteConversation,
    this.conversations = const [],
    this.currentConversationId,
  });

  String _formatTime(int timestamp, AppLocalizations strings) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inMinutes < 1) return strings.justNow;
    if (diff.inHours < 1) return strings.minutesAgo(diff.inMinutes);
    if (diff.inDays < 1) {
      return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
    if (diff.inDays < 7) return strings.daysAgo(diff.inDays);
    return '${date.month}/${date.day}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = AppLocalizations.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
          child: Row(
            children: [
              Icon(
                Icons.chat_rounded,
                color: theme.colorScheme.primary,
                size: 24,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  strings.conversations,
                  style: theme.textTheme.titleLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: onNewConversation,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(strings.newConversation),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: conversations.isEmpty
              ? _buildEmptyState(theme, strings)
              : _buildConversationList(theme, strings),
        ),
      ],
    );
  }

  Widget _buildEmptyState(ThemeData theme, AppLocalizations strings) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: ShapeDecoration(
                color: theme.colorScheme.secondaryContainer,
                shape: AppShapes.field,
              ),
              child: Icon(
                Icons.chat_bubble_outline_rounded,
                size: 32,
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: 16),
            Text(strings.noConversations, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              strings.startConversationHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversationList(ThemeData theme, AppLocalizations strings) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: conversations.length,
      itemBuilder: (context, index) {
        final conversation = conversations[index];
        final title = conversation.title.isEmpty
            ? strings.untitledConversation
            : conversation.title;
        final isSelected = conversation.id == currentConversationId;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Dismissible(
            key: Key(conversation.id),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              decoration: ShapeDecoration(
                color: theme.colorScheme.error,
                shape: AppShapes.field,
              ),
              child: Icon(
                Icons.delete_rounded,
                color: theme.colorScheme.onError,
              ),
            ),
            confirmDismiss: (_) async {
              final result = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(strings.deleteConversation),
                  content: Text(strings.deleteConversationConfirm),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(strings.cancel),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                        foregroundColor: theme.colorScheme.onError,
                      ),
                      child: Text(strings.delete),
                    ),
                  ],
                ),
              );
              if (result == true) {
                onDeleteConversation?.call(conversation.id);
              }
              return result ?? false;
            },
            child: Material(
              color: isSelected
                  ? theme.colorScheme.secondaryContainer
                  : Colors.transparent,
              shape: AppShapes.field,
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => onSelectConversation?.call(conversation.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: isSelected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                              ),
                            ),
                            if (conversation.lastMessagePreview.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                conversation.lastMessagePreview,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _formatTime(conversation.updatedAt.toInt(), strings),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
