import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

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
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _isEditing = false;
  bool _showThinking = false;
  late TextEditingController _editController;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController(text: widget.content);
  }

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
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      details.globalPosition & const Size(1, 1),
      Offset.zero & overlay.size,
    );

    final items = <PopupMenuEntry<String>>[
      PopupMenuItem(
        value: 'copy',
        child: Row(
          children: [
            Icon(
              Icons.copy_rounded,
              size: 20,
              color: theme.colorScheme.onSurface,
            ),
            const SizedBox(width: 12),
            const Text('复制'),
          ],
        ),
      ),
    ];

    if (widget.isUser && widget.onEdit != null) {
      items.add(
        PopupMenuItem(
          value: 'edit',
          child: Row(
            children: [
              Icon(
                Icons.edit_rounded,
                size: 20,
                color: theme.colorScheme.onSurface,
              ),
              const SizedBox(width: 12),
              const Text('编辑并重发'),
            ],
          ),
        ),
      );
    }

    if (widget.isUser && widget.onRollback != null) {
      items.add(
        PopupMenuItem(
          value: 'rollback',
          child: Row(
            children: [
              Icon(
                Icons.undo_rounded,
                size: 20,
                color: theme.colorScheme.tertiary,
              ),
              const SizedBox(width: 12),
              Text('回溯', style: TextStyle(color: theme.colorScheme.tertiary)),
            ],
          ),
        ),
      );
    }

    if (!widget.isUser && widget.onRegenerate != null) {
      items.add(
        PopupMenuItem(
          value: 'regenerate',
          child: Row(
            children: [
              Icon(
                Icons.refresh_rounded,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Text('重新生成', style: TextStyle(color: theme.colorScheme.primary)),
            ],
          ),
        ),
      );
    }

    if (widget.onDelete != null) {
      items.add(
        PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(
                Icons.delete_outline_rounded,
                size: 20,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 12),
              Text('删除', style: TextStyle(color: theme.colorScheme.error)),
            ],
          ),
        ),
      );
    }

    showMenu<String>(
      context: context,
      position: position,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 3,
      items: items,
    ).then((value) {
      if (!context.mounted) return;
      switch (value) {
        case 'copy':
          Clipboard.setData(ClipboardData(text: widget.content));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('已复制到剪贴板'),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              duration: const Duration(seconds: 1),
            ),
          );
          break;
        case 'edit':
          _startEditing();
          break;
        case 'rollback':
          _confirmRollback(context);
          break;
        case 'regenerate':
          widget.onRegenerate?.call();
          break;
        case 'delete':
          _confirmDelete(context);
          break;
      }
    });
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          Icons.delete_outline_rounded,
          color: Theme.of(ctx).colorScheme.error,
        ),
        title: const Text('删除消息'),
        content: const Text('确定要删除这条消息吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onDelete?.call();
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  void _confirmRollback(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          Icons.undo_rounded,
          color: Theme.of(ctx).colorScheme.tertiary,
        ),
        title: const Text('回溯对话'),
        content: const Text('将删除这条消息及之后的所有对话记录，相关记忆也会被清除。确定要回溯吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onRollback?.call();
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.tertiary,
            ),
            child: const Text('回溯'),
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

    final actions = <Widget>[];

    // 复制按钮 - 始终显示
    actions.add(
      _ActionChip(
        icon: Icons.copy_rounded,
        label: '复制',
        onPressed: () {
          Clipboard.setData(ClipboardData(text: widget.content));
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('已复制到剪贴板'),
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                duration: const Duration(seconds: 1),
              ),
            );
          }
        },
        color: theme.colorScheme.outline,
      ),
    );

    if (!widget.isUser && widget.onRegenerate != null) {
      actions.add(
        _ActionChip(
          icon: Icons.refresh_rounded,
          label: '重写',
          onPressed: widget.onRegenerate!,
          color: theme.colorScheme.primary,
        ),
      );
    }

    if (widget.isUser && widget.onEdit != null) {
      actions.add(
        _ActionChip(
          icon: Icons.edit_rounded,
          label: '编辑',
          onPressed: _startEditing,
          color: theme.colorScheme.secondary,
        ),
      );
    }

    if (widget.isUser && widget.onRollback != null) {
      actions.add(
        _ActionChip(
          icon: Icons.undo_rounded,
          label: '回溯',
          onPressed: () => _confirmRollback(context),
          color: theme.colorScheme.tertiary,
        ),
      );
    }

    if (widget.onDelete != null) {
      actions.add(
        _ActionChip(
          icon: Icons.delete_outline_rounded,
          label: '删除',
          onPressed: () => _confirmDelete(context),
          color: theme.colorScheme.error,
        ),
      );
    }

    if (actions.isEmpty) return const SizedBox.shrink();

    // 始终显示操作栏，不依赖 hover/tap 切换
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(spacing: 6, runSpacing: 4, children: actions),
    );
  }

  Widget _buildThinkingSection(ThemeData theme) {
    if (widget.thinkingContent == null || widget.thinkingContent!.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: () => setState(() => _showThinking = !_showThinking),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: theme.colorScheme.tertiaryContainer,
              width: 1,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.psychology_rounded,
                    size: 16,
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '思考过程',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onTertiaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: _showThinking ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.expand_more_rounded,
                      size: 18,
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                  ),
                ],
              ),
              AnimatedCrossFade(
                firstChild: const SizedBox.shrink(),
                secondChild: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    widget.thinkingContent!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onTertiaryContainer.withValues(
                        alpha: 0.8,
                      ),
                      height: 1.5,
                    ),
                  ),
                ),
                crossFadeState: _showThinking
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 250),
                sizeCurve: Curves.easeOutCubic,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEditingView(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.5),
          width: 1.5,
        ),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _editController,
            autofocus: true,
            maxLines: null,
            minLines: 1,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface,
            ),
            decoration: InputDecoration(
              hintText: '编辑消息...',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: theme.colorScheme.surface,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 10,
              ),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _cancelEditing,
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.outline,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _submitEdit,
                icon: const Icon(Icons.send_rounded, size: 16),
                label: const Text('发送'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatTime(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = widget.isUser;

    final bubbleColor = isUser
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final textColor = isUser
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;

    final bubbleRadius = BorderRadius.only(
      topLeft: const Radius.circular(22),
      topRight: const Radius.circular(22),
      bottomLeft: Radius.circular(isUser ? 22 : 6),
      bottomRight: Radius.circular(isUser ? 6 : 22),
    );

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
            // 思考过程（仅 AI 消息）
            if (!isUser) _buildThinkingSection(theme),

            // 编辑视图 或 消息气泡
            if (_isEditing)
              _buildEditingView(theme)
            else
              Container(
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: bubbleRadius,
                ),
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
                        widget.isStreaming ? '正在输入...' : '（空回复）',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: textColor.withValues(alpha: 0.5),
                          fontStyle: FontStyle.italic,
                          height: 1.5,
                        ),
                      )
                    : MarkdownBody(
                        data: widget.content,
                        selectable: true,
                        styleSheet: MarkdownStyleSheet(
                          p: theme.textTheme.bodyMedium?.copyWith(
                            color: textColor,
                            height: 1.5,
                          ),
                          code: theme.textTheme.bodySmall?.copyWith(
                            color: textColor,
                            backgroundColor: textColor.withValues(alpha: 0.08),
                            fontFamily: 'monospace',
                          ),
                          codeblockDecoration: BoxDecoration(
                            color: textColor.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          blockquoteDecoration: BoxDecoration(
                            border: Border(
                              left: BorderSide(
                                color: textColor.withValues(alpha: 0.3),
                                width: 3,
                              ),
                            ),
                          ),
                          h1: theme.textTheme.titleLarge?.copyWith(
                            color: textColor,
                          ),
                          h2: theme.textTheme.titleMedium?.copyWith(
                            color: textColor,
                          ),
                          h3: theme.textTheme.titleSmall?.copyWith(
                            color: textColor,
                          ),
                          listBullet: theme.textTheme.bodyMedium?.copyWith(
                            color: textColor,
                          ),
                          a: TextStyle(
                            color: isUser
                                ? theme.colorScheme.inversePrimary
                                : theme.colorScheme.primary,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
              ),

            // 时间 + 操作栏
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatTime(widget.timestamp),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline.withValues(alpha: 0.6),
                      fontSize: 10,
                    ),
                  ),
                  if (widget.isStreaming) ...[
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // 操作按钮栏 - 始终显示
            _buildActionBar(theme),
          ],
        ),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color color;

  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withValues(alpha: 0.3), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: color,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
