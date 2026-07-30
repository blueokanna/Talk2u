import 'package:flutter/material.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/rust/api/data_models.dart';

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
              Text(
                strings.conversations,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              FilledButton.tonalIcon(
                onPressed: onNewConversation,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(strings.newConversation),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 36),
                ),
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline_rounded,
            size: 56,
            color: theme.colorScheme.outline.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            strings.noConversations,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            strings.startConversationHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConversationList(ThemeData theme, AppLocalizations strings) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: conversations.length,
      itemBuilder: (context, index) {
        final conv = conversations[index];
        final title = conv.title.isEmpty ? strings.untitledConversation : conv.title;
        final isSelected = conv.id == currentConversationId;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          child: Dismissible(
            key: Key(conv.id),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              decoration: BoxDecoration(
                color: theme.colorScheme.error,
                borderRadius: BorderRadius.circular(12),
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
                      ),
                      child: Text(strings.delete),
                    ),
                  ],
                ),
              );
              if (result == true) {
                onDeleteConversation?.call(conv.id);
              }
              return result ?? false;
            },
            child: Material(
              color: isSelected
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => onSelectConversation?.call(conv.id),
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
                            if (conv.lastMessagePreview.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                conv.lastMessagePreview,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.outline,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _formatTime(conv.updatedAt.toInt(), strings),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.outline.withValues(
                            alpha: 0.7,
                          ),
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
