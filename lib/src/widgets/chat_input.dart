import 'package:flutter/material.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';

/// The composer at the bottom of the chat.
///
/// It is a Material 3 surface, not a decorated [Container]: the divider, the
/// filled text field and the send action all come from the theme, so the input
/// matches every other field in the app and the send button keeps its Material
/// ink and tap target.
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
    _controller.addListener(_handleTextChanged);
  }

  void _handleTextChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText != _hasText) {
      setState(() => _hasText = hasText);
    }
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
    _controller
      ..removeListener(_handleTextChanged)
      ..dispose();
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
    final strings = AppLocalizations.of(context);

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: widget.voiceEnabled
                        ? strings.offlineVoiceInput
                        : strings.offlineVoiceUnavailable,
                    onPressed:
                        widget.voiceEnabled &&
                            (!widget.isStreaming ||
                                widget.allowVoiceDuringStreaming)
                        ? widget.onVoiceInput
                        : null,
                    icon: Icon(
                      widget.isListening ? Icons.mic : Icons.mic_none_outlined,
                      color: widget.isListening
                          ? theme.colorScheme.error
                          : null,
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      maxLines: widget.maxLines,
                      minLines: 1,
                      textInputAction: TextInputAction.newline,
                      onSubmitted: (_) => _handleSend(),
                      style: theme.textTheme.bodyMedium,
                      decoration: InputDecoration(
                        hintText: widget.isStreaming
                            ? strings.aiResponding
                            : strings.messageHint,
                        filled: true,
                        fillColor: theme.colorScheme.surfaceContainerHighest,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    tooltip: widget.isStreaming
                        ? strings.stopGenerating
                        : strings.send,
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
          ],
        ),
      ),
    );
  }
}
