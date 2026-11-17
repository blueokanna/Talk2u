import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/theme/app_motion.dart';
import 'package:talk2u/src/theme/app_shapes.dart';
import 'package:talk2u/src/widgets/thinking_section.dart';

/// One transcript message.
///
/// The bubble is a [Material] with a superellipse tail rather than a decorated
/// [Container]: the Material gives it the correct ink, elevation and clipping
/// for free, and the shape comes from [AppShapes] so both senders use the same
/// geometry with the tail on their own side.
///
/// Rendering rules that matter for performance:
///
/// * streaming text is plain [SelectableText] — re-parsing the Markdown AST on
///   every token delta is quadratic for long replies;
/// * a completed message builds [MarkdownBody] once and caches it keyed by
///   content, theme identity and text scaler, so a parent rebuild is free;
/// * the reasoning panel is [ThinkingSection], which owns its own expansion
///   controller instead of rebuilding this state on every frame.
class MessageBubble extends StatefulWidget {
  final String content;
  final String? thinkingContent;
  final bool isUser;
  final String model;
  final int timestamp;
  final String? messageId;
  final VoidCallback? onDelete;
  final VoidCallback? onRegenerate;
  final ValueChanged<String>? onEdit;
  final VoidCallback? onRollback;
  final bool isStreaming;

  const MessageBubble({
    super.key,
    required this.content,
    this.thinkingContent,
    required this.isUser,
    required this.model,
    required this.timestamp,
    this.messageId,
    this.onDelete,
    this.onRegenerate,
    this.onEdit,
    this.onRollback,
    this.isStreaming = false,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();

  /// Counts full Markdown render constructions; tests assert that a parent
  /// rebuild with unchanged input reuses the cached widget.
  @visibleForTesting
  static int get markdownBuildCount => _MessageBubbleState._markdownBuildCount;

  @visibleForTesting
  static void resetMarkdownBuildCount() =>
      _MessageBubbleState._markdownBuildCount = 0;
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _isEditing = false;
  late final TextEditingController _editController = TextEditingController(
    text: widget.content,
  );

  @override
  void didUpdateWidget(covariant MessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content && !_isEditing) {
      _editController.text = widget.content;
    }
  }

  @override
  void dispose() {
    _editController.dispose();
    super.dispose();
  }

  void _startEditing() {
    setState(() {
      _isEditing = true;
      _editController.text = widget.content;
    });
  }

  void _cancelEditing() {
    setState(() {
      _isEditing = false;
      _editController.text = widget.content;
    });
  }

  void _submitEdit() {
    final newContent = _editController.text.trim();
    if (newContent.isEmpty || newContent == widget.content) {
      _cancelEditing();
      return;
    }
    setState(() => _isEditing = false);
    widget.onEdit?.call(newContent);
  }

  void _showContextMenu(BuildContext context, TapDownDetails details) {
    final theme = Theme.of(context);
    final strings = AppLocalizations.of(context);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      details.globalPosition & const Size(1, 1),
      Offset.zero & overlay.size,
    );

    final items = <PopupMenuEntry<String>>[];
    void add(String value, IconData icon, String label, {Color? color}) {
      items.add(
        PopupMenuItem(
          value: value,
          child: Row(
            children: [
              Icon(icon, size: 20, color: color ?? theme.colorScheme.onSurface),
              const SizedBox(width: 12),
              Text(label, style: TextStyle(color: color)),
            ],
          ),
        ),
      );
    }

    add('copy', Icons.copy_rounded, strings.copy);
    if (widget.isUser && widget.onEdit != null) {
      add('edit', Icons.edit_rounded, strings.editAndResend);
    }
    if (widget.isUser && widget.onRollback != null) {
      add(
        'rollback',
        Icons.undo_rounded,
        strings.rollback,
        color: theme.colorScheme.tertiary,
      );
    }
    if (!widget.isUser && widget.onRegenerate != null) {
      add(
        'regenerate',
        Icons.refresh_rounded,
        strings.regenerate,
        color: theme.colorScheme.primary,
      );
    }
    if (widget.onDelete != null) {
      add(
        'delete',
        Icons.delete_outline_rounded,
        strings.delete,
        color: theme.colorScheme.error,
      );
    }
    if (items.isEmpty) return;

    showMenu<String>(
      context: context,
      position: position,
      shape: AppShapes.overlay,
      elevation: 3,
      items: items,
    ).then((value) {
      if (!context.mounted) return;
      switch (value) {
        case 'copy':
          _copy(context);
        case 'edit':
          _startEditing();
        case 'rollback':
          _confirmRollback(context);
        case 'regenerate':
          widget.onRegenerate?.call();
        case 'delete':
          _confirmDelete(context);
      }
    });
  }

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: widget.content));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).copied),
        duration: AppMotion.transient,
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    final strings = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          Icons.delete_outline_rounded,
          color: Theme.of(ctx).colorScheme.error,
        ),
        title: Text(strings.deleteMessage),
        content: Text(strings.deleteMessageConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onDelete?.call();
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: Text(strings.delete),
          ),
        ],
      ),
    );
  }

  void _confirmRollback(BuildContext context) {
    final strings = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          Icons.undo_rounded,
          color: Theme.of(ctx).colorScheme.tertiary,
        ),
        title: Text(strings.rollbackConversation),
        content: Text(strings.rollbackConversationConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onRollback?.call();
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.tertiary,
              foregroundColor: Theme.of(ctx).colorScheme.onTertiary,
            ),
            child: Text(strings.rollback),
          ),
        ],
      ),
    );
  }

  Widget _buildActionBar(ThemeData theme) {
    if (widget.isStreaming ||
        widget.messageId == null ||
        widget.messageId!.isEmpty) {
      return const SizedBox.shrink();
    }

    final strings = AppLocalizations.of(context);
    final actions = <Widget>[
      _ActionChip(
        icon: Icons.copy_rounded,
        label: strings.copy,
        onPressed: () => _copy(context),
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ];

    if (!widget.isUser && widget.onRegenerate != null) {
      actions.add(
        _ActionChip(
          icon: Icons.refresh_rounded,
          label: strings.rewrite,
          onPressed: widget.onRegenerate!,
          color: theme.colorScheme.primary,
        ),
      );
    }
    if (widget.isUser && widget.onEdit != null) {
      actions.add(
        _ActionChip(
          icon: Icons.edit_rounded,
          label: strings.edit,
          onPressed: _startEditing,
          color: theme.colorScheme.secondary,
        ),
      );
    }
    if (widget.isUser && widget.onRollback != null) {
      actions.add(
        _ActionChip(
          icon: Icons.undo_rounded,
          label: strings.rollback,
          onPressed: () => _confirmRollback(context),
          color: theme.colorScheme.tertiary,
        ),
      );
    }
    if (widget.onDelete != null) {
      actions.add(
        _ActionChip(
          icon: Icons.delete_outline_rounded,
          label: strings.delete,
          onPressed: () => _confirmDelete(context),
          color: theme.colorScheme.error,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(spacing: 6, runSpacing: 4, children: actions),
    );
  }

  Widget _buildEditingView(ThemeData theme) {
    final strings = AppLocalizations.of(context);
    return Material(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
      shape: AppShapes.field.copyWith(
        side: BorderSide(
          color: theme.colorScheme.primary.withValues(alpha: 0.5),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _editController,
              autofocus: true,
              maxLines: null,
              minLines: 1,
              style: theme.textTheme.bodyMedium,
              decoration: InputDecoration(
                hintText: strings.editMessageHint,
                filled: true,
                fillColor: theme.colorScheme.surface,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _cancelEditing,
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.onSurfaceVariant,
                  ),
                  child: Text(strings.cancel),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _submitEdit,
                  icon: const Icon(Icons.send_rounded, size: 16),
                  label: Text(strings.send),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Widget? _markdownCache;
  String? _markdownContent;
  ThemeData? _markdownTheme;
  TextScaler? _markdownTextScaler;

  /// Counts full Markdown render constructions; exposed through [MessageBubble].
  static int _markdownBuildCount = 0;

  Widget _buildMarkdown(
    BuildContext context,
    ThemeData theme,
    Color textColor,
    bool isUser,
  ) {
    final textScaler = MediaQuery.textScalerOf(context);
    final cached = _markdownCache;
    if (cached != null &&
        _markdownContent == widget.content &&
        identical(_markdownTheme, theme) &&
        _markdownTextScaler == textScaler) {
      return cached;
    }
    _markdownBuildCount++;
    _markdownContent = widget.content;
    _markdownTheme = theme;
    _markdownTextScaler = textScaler;
    final markdown = MarkdownBody(
      data: widget.content,
      selectable: true,
      styleSheet: MarkdownStyleSheet(
        p: theme.textTheme.bodyMedium?.copyWith(color: textColor, height: 1.5),
        code: theme.textTheme.bodySmall?.copyWith(
          color: textColor,
          backgroundColor: textColor.withValues(alpha: 0.08),
          fontFamily: 'monospace',
        ),
        codeblockDecoration: BoxDecoration(
          color: textColor.withValues(alpha: 0.06),
          borderRadius: AppShapes.cornersMedium,
        ),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: textColor.withValues(alpha: 0.3), width: 3),
          ),
        ),
        h1: theme.textTheme.titleLarge?.copyWith(color: textColor),
        h2: theme.textTheme.titleMedium?.copyWith(color: textColor),
        h3: theme.textTheme.titleSmall?.copyWith(color: textColor),
        listBullet: theme.textTheme.bodyMedium?.copyWith(color: textColor),
        a: TextStyle(
          color: isUser
              ? theme.colorScheme.inversePrimary
              : theme.colorScheme.primary,
          decoration: TextDecoration.underline,
        ),
      ),
    );
    _markdownCache = markdown;
    return markdown;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = AppLocalizations.of(context);
    final isUser = widget.isUser;

    final bubbleColor = isUser
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final textColor = isUser
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;

    return GestureDetector(
      onSecondaryTapDown: (details) => _showContextMenu(context, details),
      onLongPressStart: (details) => _showContextMenu(
        context,
        TapDownDetails(globalPosition: details.globalPosition),
      ),
      child: Padding(
        padding: EdgeInsets.only(
          left: isUser ? 48 : 12,
          right: isUser ? 12 : 48,
          top: 4,
          bottom: 4,
        ),
        child: Column(
          crossAxisAlignment: isUser
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            if (!isUser)
              ThinkingSection(
                content: widget.thinkingContent ?? '',
                isStreaming: widget.isStreaming,
              ),
            if (_isEditing)
              _buildEditingView(theme)
            else
              Material(
                color: bubbleColor,
                shape: AppShapes.bubble(mine: isUser),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: isUser
                      ? SelectableText(
                          widget.content,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: textColor,
                            height: 1.5,
                          ),
                        )
                      : widget.content.isEmpty
                      ? Text(
                          widget.isStreaming
                              ? strings.typing
                              : strings.emptyReply,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: textColor.withValues(alpha: 0.5),
                            fontStyle: FontStyle.italic,
                            height: 1.5,
                          ),
                        )
                      // Re-parsing the full Markdown AST on every token delta is
                      // quadratic for long replies. Streaming shows plain text;
                      // the completed message is rendered as Markdown once.
                      : widget.isStreaming
                      ? SelectableText(
                          widget.content,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: textColor,
                            height: 1.5,
                          ),
                        )
                      : _buildMarkdown(context, theme, textColor, isUser),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatTime(widget.timestamp),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (widget.isStreaming) ...[
                    const SizedBox(width: 6),
                    SizedBox.square(
                      dimension: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            _buildActionBar(theme),
          ],
        ),
      ),
    );
  }
}

/// A compact chip for a message action.
///
/// It is a real [ActionChip] rather than a hand-built `InkWell` + `Container`:
/// the Material 3 chip owns its outline, hover/pressed states, tap target and
/// shape from the theme, so the action row stays consistent with every other
/// chip in the app.
class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(icon, size: 16, color: color),
      label: Text(label, style: TextStyle(color: color)),
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    );
  }
}
