import 'package:flutter/material.dart';
import 'package:talk2u/src/rust/api/data_models.dart';
import 'package:talk2u/src/state/chat_state.dart';
import 'package:talk2u/src/widgets/chat_empty_state.dart';
import 'package:talk2u/src/widgets/chat_transcript_widgets.dart';
import 'package:talk2u/src/widgets/message_bubble.dart';

/// Transcript: completed messages, the streaming reply and the empty state.
///
/// Owns no scroll policy; the page keeps the [ScrollController] so auto-follow
/// and the jump-to-bottom FAB stay in one place.
class ChatMessageArea extends StatelessWidget {
  const ChatMessageArea({
    super.key,
    required this.chatState,
    required this.scrollController,
    required this.onChooseCharacter,
  });

  final ChatState chatState;
  final ScrollController scrollController;
  final VoidCallback onChooseCharacter;

  @override
  Widget build(BuildContext context) {
    final visibleMessages = chatState.displayMessages;
    if (visibleMessages.isEmpty && !chatState.isStreaming) {
      return ChatEmptyState(onChooseCharacter: onChooseCharacter);
    }
    final itemCount = visibleMessages.length + (chatState.isStreaming ? 1 : 0);
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.only(top: 16, bottom: 16),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index < visibleMessages.length) {
          final message = visibleMessages[index];
          return AnimatedMessageItem(
            key: ValueKey(message.id.isEmpty ? 'msg-$index' : message.id),
            child: _MessageBubbleFor(message: message, chatState: chatState),
          );
        }
        return _StreamingBubble(chatState: chatState);
      },
    );
  }
}

class _MessageBubbleFor extends StatelessWidget {
  const _MessageBubbleFor({required this.message, required this.chatState});

  final Message message;
  final ChatState chatState;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == MessageRole.user;
    final hasId = message.id.isNotEmpty;
    return MessageBubble(
      content: message.content,
      thinkingContent: message.thinkingContent,
      isUser: isUser,
      model: message.model,
      timestamp: message.timestamp.toInt(),
      messageId: message.id,
      onDelete: hasId ? () => chatState.deleteMessage(message.id) : null,
      onRegenerate: !isUser && hasId
          ? () => chatState.regenerateResponse(message.id)
          : null,
      onEdit: isUser && hasId
          ? (content) => chatState.editAndResend(message.id, content)
          : null,
      onRollback: isUser && hasId
          ? () => chatState.rollbackToMessage(message.id)
          : null,
    );
  }
}

class _StreamingBubble extends StatelessWidget {
  const _StreamingBubble({required this.chatState});

  final ChatState chatState;

  @override
  Widget build(BuildContext context) {
    final content = chatState.currentStreamingContent;
    if (content.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [TypingDots()]),
      );
    }
    final thinking = chatState.currentThinkingContent;
    return MessageBubble(
      content: content,
      thinkingContent: thinking.isEmpty ? null : thinking,
      isUser: false,
      model: chatState.selectedModel,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isStreaming: true,
    );
  }
}
