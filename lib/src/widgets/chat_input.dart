import 'package:flutter/material.dart';

class ChatInput extends StatefulWidget {
  final bool isStreaming;
  final ValueChanged<String> onSend;

  const ChatInput({super.key, required this.isStreaming, required this.onSend});

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput>
    with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasText = false;
  late AnimationController _sendButtonController;
  late Animation<double> _sendButtonScale;

  @override
  void initState() {
    super.initState();
    _sendButtonController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _sendButtonScale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _sendButtonController, curve: Curves.easeOutBack),
    );
    _controller.addListener(() {
      final hasText = _controller.text.trim().isNotEmpty;
      if (hasText != _hasText) {
        setState(() => _hasText = hasText);
        if (hasText) {
          _sendButtonController.forward();
        } else {
          _sendButtonController.reverse();
        }
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _sendButtonController.dispose();
    super.dispose();
  }

  void _handleSend() {
    final text = _controller.text.trim();
    if (text.isEmpty || widget.isStreaming) return;
    widget.onSend(text);
    _controller.clear();
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                enabled: !widget.isStreaming,
                maxLines: 5,
                minLines: 1,
                textInputAction: TextInputAction.newline,
                onSubmitted: (_) => _handleSend(),
                decoration: InputDecoration(
                  hintText: widget.isStreaming ? 'AI 正在回复...' : '输入消息...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  isDense: true,
                ),
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: 6),
            ScaleTransition(
              scale: _sendButtonScale,
              child: IconButton.filled(
                onPressed: _hasText && !widget.isStreaming ? _handleSend : null,
                icon: const Icon(Icons.arrow_upward_rounded, size: 22),
                style: IconButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.onPrimary,
                  fixedSize: const Size(40, 40),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
