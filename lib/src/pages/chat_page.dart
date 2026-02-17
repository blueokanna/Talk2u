import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:talk2u/src/state/chat_state.dart';
import 'package:talk2u/src/rust/api/data_models.dart';
import 'package:talk2u/src/widgets/message_bubble.dart';
import 'package:talk2u/src/widgets/chat_input.dart';
import 'package:talk2u/src/pages/conversation_list_page.dart';
import 'package:talk2u/src/pages/character_list_page.dart';
import 'package:talk2u/src/pages/settings_page.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with TickerProviderStateMixin {
  final _scrollController = ScrollController();
  late AnimationController _fabController;
  bool _showScrollToBottom = false;

  @override
  void initState() {
    super.initState();
    _fabController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatState>().initialize();
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final isNearBottom = _isUserNearBottom();
    if (!isNearBottom && !_showScrollToBottom) {
      setState(() => _showScrollToBottom = true);
      _fabController.forward();
    } else if (isNearBottom && _showScrollToBottom) {
      _fabController.reverse().then((_) {
        if (mounted) setState(() => _showScrollToBottom = false);
      });
    }
  }

  /// 判断用户是否在列表底部附近（150px 阈值）
  bool _isUserNearBottom() {
    if (!_scrollController.hasClients) return true;
    final pos = _scrollController.position;
    return pos.maxScrollExtent - pos.pixels < 150;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _fabController.dispose();
    super.dispose();
  }

  void _scrollToBottom({bool animate = true}) {
    if (!_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      if (animate) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _handleSend(String content) {
    final chatState = context.read<ChatState>();
    chatState.sendMessage(content);
    _scrollToBottom();
  }

  void _handleRetry() {
    final chatState = context.read<ChatState>();
    chatState.retryLastMessage();
    _scrollToBottom();
  }

  void _openCharacterList() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CharacterListPage(
          onSelectCharacter: (character) {
            Navigator.pop(context);
            context.read<ChatState>().startCharacterChat(character);
          },
        ),
      ),
    );
  }

  void _showChatOptions() {
    final chatState = context.read<ChatState>();
    final theme = Theme.of(context);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 标题栏
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // 角色信息
                    if (chatState.currentCharacter != null) ...[
                      _buildOptionSection(
                        theme,
                        icon: Icons.person_rounded,
                        title: chatState.currentCharacter!.name,
                        subtitle: chatState.currentCharacter!.description,
                      ),
                      const Divider(height: 24),
                    ],

                    // 重启剧情
                    if (chatState.currentConversationId != null)
                      ListTile(
                        leading: Icon(
                          Icons.refresh_rounded,
                          color: theme.colorScheme.primary,
                        ),
                        title: const Text('重启'),
                        subtitle: const Text('清除对话记录，保留角色设定和开场白'),
                        contentPadding: EdgeInsets.zero,
                        onTap: () {
                          Navigator.pop(ctx);
                          _confirmRestartStory();
                        },
                      ),

                    const Divider(height: 24),

                    // 对话风格选择
                    Text(
                      '对话风格',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        _buildStyleChip(
                          theme,
                          '自由',
                          DialogueStyle.free,
                          chatState.dialogueStyle,
                          (style) {
                            chatState.setDialogueStyle(style);
                            setSheetState(() {});
                          },
                        ),
                        _buildStyleChip(
                          theme,
                          '纯对话',
                          DialogueStyle.sayOnly,
                          chatState.dialogueStyle,
                          (style) {
                            chatState.setDialogueStyle(style);
                            setSheetState(() {});
                          },
                        ),
                        _buildStyleChip(
                          theme,
                          '纯动作',
                          DialogueStyle.doOnly,
                          chatState.dialogueStyle,
                          (style) {
                            chatState.setDialogueStyle(style);
                            setSheetState(() {});
                          },
                        ),
                        _buildStyleChip(
                          theme,
                          '混合（自动识别）',
                          DialogueStyle.mixed,
                          chatState.dialogueStyle,
                          (style) {
                            chatState.setDialogueStyle(style);
                            setSheetState(() {});
                          },
                        ),
                      ],
                    ),

                    const Divider(height: 24),

                    // 模型选择
                    Text(
                      '模型选择',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    RadioGroup<String>(
                      groupValue: chatState.selectedModel,
                      onChanged: (String? value) {
                        if (value != null) {
                          chatState.setSelectedModel(value);
                          setSheetState(() {});
                        }
                      },
                      child: Column(
                        children: [
                          _buildModelOption(
                            theme,
                            'GLM-4.7',
                            '对话模型，响应快速',
                            'glm-4.7',
                            false,
                          ),
                          _buildModelOption(
                            theme,
                            'GLM-4-Air',
                            '深度推理，自动开启思考',
                            'glm-4-air',
                            true,
                          ),
                          _buildModelOption(
                            theme,
                            'GLM-4.7-Flash',
                            '快速响应，轻量对话',
                            'glm-4.7-flash',
                            false,
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 8),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildOptionSection(
    ThemeData theme, {
    required IconData icon,
    required String title,
    String? subtitle,
  }) {
    return Row(
      children: [
        CircleAvatar(
          radius: 20,
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Text(
            title.characters.first,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (subtitle != null && subtitle.isNotEmpty)
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStyleChip(
    ThemeData theme,
    String label,
    DialogueStyle style,
    DialogueStyle current,
    ValueChanged<DialogueStyle> onSelected,
  ) {
    final isSelected = style == current;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => onSelected(style),
      selectedColor: theme.colorScheme.primaryContainer,
      side: BorderSide(
        color: isSelected
            ? theme.colorScheme.primary
            : theme.colorScheme.outlineVariant,
      ),
    );
  }

  Widget _buildModelOption(
    ThemeData theme,
    String name,
    String description,
    String modelId,
    bool supportsThinking,
  ) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Radio<String>(value: modelId),
      title: Row(
        children: [
          Text(name),
          if (supportsThinking) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '思考',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        description,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
    );
  }

  void _confirmRestartStory() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重启剧情'),
        content: const Text('确定要重启剧情吗？所有对话记录将被清除，但角色设定和开场白会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.read<ChatState>().restartStory();
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('重启'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Consumer<ChatState>(
          builder: (context, state, _) {
            if (state.currentCharacter != null) {
              return GestureDetector(
                onTap: _showChatOptions,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: theme.colorScheme.primaryContainer,
                      child: Text(
                        state.currentCharacter!.name.characters.first,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        state.currentCharacter!.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      Icons.arrow_drop_down,
                      size: 20,
                      color: theme.colorScheme.outline,
                    ),
                  ],
                ),
              );
            }
            if (state.currentConversationId == null) {
              return const Text('Talk2U');
            }
            final conv = state.conversations.where(
              (c) => c.id == state.currentConversationId,
            );
            final title = conv.isNotEmpty && conv.first.title.isNotEmpty
                ? conv.first.title
                : 'Talk2U';
            return Text(title, maxLines: 1, overflow: TextOverflow.ellipsis);
          },
        ),
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 1,
        actions: [
          // 模型指示器
          Consumer<ChatState>(
            builder: (context, state, _) {
              final isThinking = state.selectedModel == ChatState.thinkingModel;
              final isFlash = state.selectedModel == ChatState.flashModel;
              return IconButton(
                icon: Icon(
                  isThinking
                      ? Icons.psychology
                      : isFlash
                      ? Icons.flash_on_rounded
                      : Icons.psychology_outlined,
                  color: isThinking
                      ? theme.colorScheme.primary
                      : isFlash
                      ? Colors.amber
                      : null,
                ),
                tooltip: isThinking
                    ? 'GLM-4-Air 深度推理'
                    : isFlash
                    ? 'GLM-4.7-Flash 快速'
                    : 'GLM-4.7 对话',
                onPressed: () {
                  state.setEnableThinking(!state.enableThinking);
                },
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.person_rounded),
            tooltip: '角色列表',
            onPressed: _openCharacterList,
          ),
          // 更多选项
          IconButton(
            icon: const Icon(Icons.more_vert_rounded),
            onPressed: _showChatOptions,
          ),
        ],
      ),
      drawer: Consumer<ChatState>(
        builder: (context, chatState, _) {
          return Drawer(
            child: SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: ConversationListPage(
                      conversations: chatState.conversations,
                      currentConversationId: chatState.currentConversationId,
                      onNewConversation: () {
                        Navigator.pop(context);
                        chatState.createNewConversation();
                      },
                      onSelectConversation: (id) {
                        Navigator.pop(context);
                        chatState.loadConversation(id);
                      },
                      onDeleteConversation: (id) {
                        chatState.deleteConversation(id);
                      },
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: Icon(
                      Icons.settings_rounded,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    title: const Text('设置'),
                    subtitle: const Text('API 密钥、模型配置'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SettingsPage()),
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
      body: Consumer<ChatState>(
        builder: (context, chatState, _) {
          // 流式生成时，只在用户本来就在底部附近时才自动滚动
          // 如果用户主动往上翻看历史消息，不打断
          if (chatState.isStreaming && _isUserNearBottom()) {
            _scrollToBottom();
          }

          return Stack(
            children: [
              Column(
                children: [
                  Expanded(child: _buildMessageArea(chatState)),
                  if (chatState.errorMessage != null)
                    _buildErrorBanner(chatState),
                  ChatInput(
                    isStreaming: chatState.isStreaming,
                    onSend: _handleSend,
                  ),
                ],
              ),
              if (_showScrollToBottom)
                Positioned(
                  right: 16,
                  bottom: 80,
                  child: ScaleTransition(
                    scale: _fabController,
                    child: FloatingActionButton.small(
                      onPressed: () => _scrollToBottom(),
                      elevation: 2,
                      child: const Icon(Icons.keyboard_arrow_down),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMessageArea(ChatState chatState) {
    final visibleMessages = chatState.displayMessages;
    final hasContent = visibleMessages.isNotEmpty || chatState.isStreaming;

    if (!hasContent) {
      return _buildEmptyState();
    }

    final itemCount = visibleMessages.length + (chatState.isStreaming ? 1 : 0);

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(top: 16, bottom: 16),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index < visibleMessages.length) {
          return _AnimatedMessageItem(
            key: ValueKey(
              visibleMessages[index].id.isEmpty
                  ? 'msg-$index'
                  : visibleMessages[index].id,
            ),
            child: _buildMessageBubble(visibleMessages[index]),
          );
        }
        return _buildStreamingBubble(chatState);
      },
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    return Center(
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
            '开始新的对话',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '输入消息开始聊天，或选择一个角色',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.tonalIcon(
            onPressed: _openCharacterList,
            icon: const Icon(Icons.person_add_rounded),
            label: const Text('选择角色'),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(ChatState chatState) {
    final theme = Theme.of(context);
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Material(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(
                  Icons.error_outline,
                  color: theme.colorScheme.error,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    chatState.errorMessage ?? '',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (chatState.errorMessage != null &&
                    chatState.currentConversationId != null)
                  TextButton.icon(
                    onPressed: _handleRetry,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重试'),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => context.read<ChatState>().clearError(),
                  color: theme.colorScheme.onErrorContainer,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStreamingBubble(ChatState chatState) {
    // 流式阶段：始终显示气泡，内容为空时显示打字指示器
    final hasContent = chatState.currentStreamingContent.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasContent)
          MessageBubble(
            content: chatState.currentStreamingContent,
            isUser: false,
            model: chatState.selectedModel,
            timestamp: DateTime.now().millisecondsSinceEpoch,
            isStreaming: true,
          ),
        if (!hasContent) _buildTypingIndicator(),
      ],
    );
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(mainAxisSize: MainAxisSize.min, children: [_TypingDots()]),
    );
  }

  Widget _buildMessageBubble(Message msg) {
    final isUser = msg.role == MessageRole.user;
    final chatState = context.read<ChatState>();
    return MessageBubble(
      content: msg.content,
      thinkingContent: msg.thinkingContent,
      isUser: isUser,
      model: msg.model,
      timestamp: msg.timestamp.toInt(),
      messageId: msg.id,
      onDelete: msg.id.isNotEmpty
          ? () => chatState.deleteMessage(msg.id)
          : null,
      onRegenerate: !isUser && msg.id.isNotEmpty
          ? () => chatState.regenerateResponse(msg.id)
          : null,
      onEdit: isUser && msg.id.isNotEmpty
          ? (newContent) => chatState.editAndResend(msg.id, newContent)
          : null,
      onRollback: isUser && msg.id.isNotEmpty
          ? () => chatState.rollbackToMessage(msg.id)
          : null,
    );
  }
}

/// Animated wrapper for message items entering the list
class _AnimatedMessageItem extends StatefulWidget {
  final Widget child;
  const _AnimatedMessageItem({super.key, required this.child});

  @override
  State<_AnimatedMessageItem> createState() => _AnimatedMessageItemState();
}

class _AnimatedMessageItemState extends State<_AnimatedMessageItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.15),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(position: _slideAnimation, child: widget.child),
    );
  }
}

/// Animated typing dots indicator
class _TypingDots extends StatefulWidget {
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              final delay = i * 0.2;
              final t = (_controller.value - delay).clamp(0.0, 1.0);
              final scale = 0.5 + 0.5 * (1 - (2 * t - 1).abs());
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Transform.scale(
                  scale: scale,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(
                        alpha: 0.4 + 0.6 * scale,
                      ),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
