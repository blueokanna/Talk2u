import 'package:flutter/material.dart';

class ChatInput extends StatefulWidget {
  final bool isStreaming;
  final ValueChanged<String> onSend;
  final VoidCallback? onStop;
  final VoidCallback? onVoiceInput;
  final bool isListening;
  final bool voiceEnabled;
  final bool allowVoiceDuringStreaming;
  final String dictatedText;
  final int maxLines;

  const ChatInput({
    super.key,
    required this.isStreaming,
    required this.onSend,
    this.onStop,
    this.onVoiceInput,
    this.isListening = false,
    this.voiceEnabled = false,
    this.allowVoiceDuringStreaming = false,
    this.dictatedText = '',
    this.maxLines = 5,
  }) : assert(maxLines > 0);

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final hasText = _controller.text.trim().isNotEmpty;
      if (hasText != _hasText) {
        setState(() => _hasText = hasText);
      }
    });
  }

  @override
  void didUpdateWidget(covariant ChatInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.dictatedText.isNotEmpty &&
        widget.dictatedText != oldWidget.dictatedText) {
      _controller.value = TextEditingValue(
        text: widget.dictatedText,
        selection: TextSelection.collapsed(offset: widget.dictatedText.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
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
            IconButton(
              tooltip: widget.voiceEnabled ? '离线语音输入' : '设备无离线识别引擎',
              onPressed:
                  widget.voiceEnabled &&
                      (!widget.isStreaming || widget.allowVoiceDuringStreaming)
                  ? widget.onVoiceInput
                  : null,
              icon: Icon(
                widget.isListening ? Icons.mic : Icons.mic_none_outlined,
                color: widget.isListening ? theme.colorScheme.error : null,
              ),
            ),
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                enabled: !widget.isStreaming,
                maxLines: widget.maxLines,
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
            IconButton.filled(
              tooltip: widget.isStreaming ? '停止生成' : '发送',
              onPressed: widget.isStreaming
                  ? widget.onStop
                  : (_hasText ? _handleSend : null),
              icon: Icon(
                widget.isStreaming
                    ? Icons.stop_rounded
                    : Icons.arrow_upward_rounded,
                size: 22,
              ),
              style: IconButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
                fixedSize: const Size(40, 40),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
