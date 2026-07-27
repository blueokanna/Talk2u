import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:talk2u/src/state/chat_state.dart';
import 'package:talk2u/src/rust/api/data_models.dart';
import 'package:talk2u/src/widgets/message_bubble.dart';
import 'package:talk2u/src/widgets/chat_input.dart';
import 'package:talk2u/src/pages/conversation_list_page.dart';
import 'package:talk2u/src/pages/character_list_page.dart';
import 'package:talk2u/src/pages/settings_page.dart';
import 'package:talk2u/src/services/offline_speech_service.dart';
import 'package:talk2u/src/services/live2d_model_importer.dart';
import 'package:talk2u/src/services/moss_tts_service.dart';
import 'package:talk2u/src/services/offline_llm_service.dart';
import 'package:talk2u/src/widgets/live2d_avatar.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with TickerProviderStateMixin {
  final _scrollController = ScrollController();
  late AnimationController _fabController;
  bool _showScrollToBottom = false;
  bool _showTranscript = false;
  bool _isImportingLive2d = false;
  String? _modelOverridePath;
  String? _modelOverrideCharacterId;
  ChatState? _chatState;
  int _handledResponseRevision = 0;
  StreamSubscription<String>? _callRecognitionSubscription;
  bool _callMode = false;
  bool _callAwaitingResponse = false;
  bool _callWaitingForSpeech = false;
  bool _callSpeechStarted = false;
  bool _callTransitioning = false;
  bool _callRestartScheduled = false;
  int _callGeneration = 0;

  @override
  void initState() {
    super.initState();
    _fabController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _scrollController.addListener(_onScroll);
    final speech = OfflineSpeechService.instance;
    speech.addListener(_handleCallSpeechState);
    _callRecognitionSubscription = speech.recognitionResults.listen(
      _handleCallRecognition,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatState>().initialize();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final chatState = context.read<ChatState>();
    if (identical(_chatState, chatState)) return;
    _chatState?.removeListener(_handleChatStateChanged);
    _chatState = chatState;
    _handledResponseRevision = chatState.completedResponseRevision;
    chatState.addListener(_handleChatStateChanged);
  }

  void _handleChatStateChanged() {
    final chatState = _chatState;
    if (chatState == null) return;
    if (_callMode &&
        _callAwaitingResponse &&
        !chatState.isStreaming &&
        chatState.errorMessage != null) {
      _callAwaitingResponse = false;
      unawaited(_resumeCallListening(_callGeneration));
    }
    if (chatState.completedResponseRevision <= _handledResponseRevision) {
      return;
    }
    _handledResponseRevision = chatState.completedResponseRevision;
    for (final message in chatState.messages.reversed) {
      if (message.role == MessageRole.assistant &&
          message.content.trim().isNotEmpty) {
        if (_callMode) {
          _callAwaitingResponse = false;
          _callWaitingForSpeech = true;
          _callSpeechStarted = false;
          final generation = _callGeneration;
          unawaited(
            _speakReply(
              message.content,
            ).whenComplete(() => _handleCallSpeechInvocation(generation)),
          );
        } else {
          unawaited(_speakReply(message.content));
        }
        return;
      }
    }
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

  bool _isUserNearBottom() {
    if (!_scrollController.hasClients) return true;
    final pos = _scrollController.position;
    return pos.maxScrollExtent - pos.pixels < 150;
  }

  @override
  void dispose() {
    _callMode = false;
    _callGeneration++;
    final speech = OfflineSpeechService.instance;
    if (speech.listening) unawaited(speech.stopListening());
    if (speech.speaking || speech.generating) {
      unawaited(speech.stopSpeaking());
    }
    OfflineSpeechService.instance.removeListener(_handleCallSpeechState);
    unawaited(_callRecognitionSubscription?.cancel());
    _chatState?.removeListener(_handleChatStateChanged);
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
    unawaited(OfflineSpeechService.instance.stopSpeaking());
    final chatState = context.read<ChatState>();
    chatState.sendMessage(content);
    _scrollToBottom();
  }

  void _handleRetry() {
    unawaited(OfflineSpeechService.instance.stopSpeaking());
    final chatState = context.read<ChatState>();
    chatState.retryLastMessage();
    _scrollToBottom();
  }

  Future<void> _toggleListening() async {
    final speech = OfflineSpeechService.instance;
    try {
      if (speech.listening) {
        await speech.stopListening();
      } else {
        if (_callMode) {
          final chatState = _chatState;
          if (chatState?.isStreaming == true) await chatState!.stopGeneration();
          if (speech.speaking || speech.generating) {
            _callWaitingForSpeech = false;
            _callSpeechStarted = false;
            await speech.stopSpeaking();
          }
        }
        await speech.startListening();
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('离线语音识别不可用: $error')));
    }
  }

  Future<void> _toggleCallMode() async {
    if (_callTransitioning) return;
    _callTransitioning = true;
    try {
      if (_callMode) {
        await _stopCallMode();
        return;
      }
      final speech = OfflineSpeechService.instance;
      await speech.initialize();
      if (!speech.capabilities.offlineStt || !speech.capabilities.offlineTts) {
        throw StateError('持续通话需要可用的端侧语音识别和语音合成');
      }
      await speech.stopSpeaking();
      if (speech.listening) await speech.stopListening();
      _callGeneration++;
      _callAwaitingResponse = false;
      _callWaitingForSpeech = false;
      _callSpeechStarted = false;
      if (mounted) setState(() => _callMode = true);
      await _resumeCallListening(_callGeneration);
    } catch (error) {
      if (!mounted) return;
      setState(() => _callMode = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法开始持续通话: $error')));
    } finally {
      _callTransitioning = false;
    }
  }

  Future<void> _stopCallMode() async {
    _callGeneration++;
    _callAwaitingResponse = false;
    _callWaitingForSpeech = false;
    _callSpeechStarted = false;
    if (mounted) setState(() => _callMode = false);
    final speech = OfflineSpeechService.instance;
    if (speech.listening) await speech.stopListening();
    if (speech.speaking || speech.generating) await speech.stopSpeaking();
  }

  void _handleCallRecognition(String text) {
    if (!_callMode || _callAwaitingResponse || text.trim().isEmpty) return;
    final generation = _callGeneration;
    _callAwaitingResponse = true;
    _callWaitingForSpeech = false;
    _callSpeechStarted = false;
    unawaited(_sendCallTurn(text.trim(), generation));
  }

  Future<void> _sendCallTurn(String text, int generation) async {
    try {
      final chatState = _chatState;
      if (chatState == null || !_callMode || generation != _callGeneration) {
        _callAwaitingResponse = false;
        return;
      }
      if (chatState.isStreaming) await chatState.stopGeneration();
      await chatState.sendMessage(text);
      if (!_callMode || generation != _callGeneration) return;
      if (!chatState.isStreaming && chatState.errorMessage != null) {
        _callAwaitingResponse = false;
        await _resumeCallListening(generation);
      }
    } catch (error) {
      _callAwaitingResponse = false;
      if (!_callMode || generation != _callGeneration) return;
      await _resumeCallListening(generation);
    }
  }

  void _handleCallSpeechState() {
    if (!_callMode || !_callWaitingForSpeech) return;
    final speech = OfflineSpeechService.instance;
    if (speech.speaking) _callSpeechStarted = true;
    if (_callSpeechStarted && !speech.speaking && !speech.generating) {
      _callWaitingForSpeech = false;
      _callSpeechStarted = false;
      unawaited(_resumeCallListening(_callGeneration));
      return;
    }
    if (!_callAwaitingResponse &&
        !_callWaitingForSpeech &&
        !speech.listening &&
        !_callRestartScheduled) {
      _callRestartScheduled = true;
      final generation = _callGeneration;
      Future<void>.delayed(const Duration(milliseconds: 900), () async {
        _callRestartScheduled = false;
        await _resumeCallListening(generation);
      });
    }
  }

  void _handleCallSpeechInvocation(int generation) {
    if (!_callMode || generation != _callGeneration || !_callWaitingForSpeech) {
      return;
    }
    final speech = OfflineSpeechService.instance;
    if (!speech.speaking && !speech.generating && !_callSpeechStarted) {
      _callWaitingForSpeech = false;
      unawaited(_resumeCallListening(generation));
    }
  }

  Future<void> _resumeCallListening(int generation) async {
    if (!_callMode ||
        generation != _callGeneration ||
        _callAwaitingResponse ||
        _callWaitingForSpeech) {
      return;
    }
    final speech = OfflineSpeechService.instance;
    if (speech.listening) return;
    try {
      await speech.startListening();
    } catch (error) {
      if (!_callMode || generation != _callGeneration || !mounted) return;
      setState(() => _callMode = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('持续通话已停止: $error')));
    }
  }

  Future<void> _speakLastReply(ChatState state) async {
    final speech = OfflineSpeechService.instance;
    if (speech.speaking || speech.generating) {
      await speech.stopSpeaking();
      return;
    }
    String? reply;
    for (final message in state.messages.reversed) {
      if (message.role == MessageRole.assistant) {
        reply = message.content;
        break;
      }
    }
    if (reply == null || reply.trim().isEmpty) return;
    await _speakReply(reply);
  }

  Future<void> _speakReply(String reply) async {
    try {
      final speech = OfflineSpeechService.instance;
      if (!speech.capabilities.offlineTts) await speech.initialize();
      if (!speech.capabilities.offlineTts) {
        throw StateError('未检测到可用的端侧 TTS 语音包');
      }
      if (speech.speaking || speech.generating) await speech.stopSpeaking();
      await speech.speak(reply);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('离线语音合成不可用: $error')));
    }
  }

  Future<void> _importLive2dModel() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    final archivePath = result?.files.single.path;
    if (archivePath == null || !mounted) return;
    setState(() => _isImportingLive2d = true);
    try {
      final modelPaths = await Live2dModelImporter.importArchiveModels(
        archivePath,
      );
      if (!mounted) return;
      final modelPath = await _selectImportedModel(modelPaths);
      if (modelPath == null || !mounted) return;
      final chatState = context.read<ChatState>();
      final characterId = chatState.currentCharacter?.id;
      await chatState.setCurrentCharacterLive2dModelPath(modelPath);
      if (!mounted) return;
      setState(() {
        _modelOverridePath = modelPath;
        _modelOverrideCharacterId = characterId;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Live2D 模型已切换，共发现 ${modelPaths.length} 个模型')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Live2D 模型导入失败: $error')));
    } finally {
      if (mounted) setState(() => _isImportingLive2d = false);
    }
  }

  Future<String?> _selectImportedModel(List<String> modelPaths) async {
    if (modelPaths.length == 1) return modelPaths.first;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('选择 Live2D 模型'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 360),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: modelPaths.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, index) {
              final path = modelPaths[index];
              final name = path.replaceAll('\\', '/').split('/').last;
              return ListTile(
                leading: const Icon(Icons.view_in_ar_outlined),
                title: Text(name),
                subtitle: Text(
                  path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(dialogContext, path),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  void _openCharacterList() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CharacterListPage(
          onSelectAssistant: () {
            Navigator.pop(context);
            context.read<ChatState>().createNewConversation();
          },
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

                    if (chatState.currentCharacter != null) ...[
                      _buildOptionSection(
                        theme,
                        icon: Icons.person_rounded,
                        title: chatState.currentCharacter!.name,
                        subtitle: chatState.currentCharacter!.description,
                      ),
                      const Divider(height: 24),
                    ],

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

                    Text(
                      '平台与模型',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: chatState.selectedProviderId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'API 平台',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.hub_outlined),
                      ),
                      items: chatState.providers
                          .map(
                            (provider) => DropdownMenuItem(
                              value: provider.id,
                              child: Text(
                                provider.isConfigured
                                    ? provider.name
                                    : '${provider.name}（未配置）',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: chatState.isStreaming
                          ? null
                          : (value) {
                              if (value == null) return;
                              chatState.setSelectedProvider(value);
                              setSheetState(() {});
                            },
                    ),
                    const SizedBox(height: 12),
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
                            chatState.selectedProvider?.chatModel ?? '未配置',
                            '对话模型',
                            chatState.selectedProvider?.chatModel ?? '',
                            false,
                          ),
                          if (chatState.selectedProvider?.supportsThinking ==
                              true)
                            _buildModelOption(
                              theme,
                              chatState.selectedProvider!.thinkingModel!,
                              '推理模型，自动启用推理管线',
                              chatState.selectedProvider!.thinkingModel!,
                              true,
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
          Consumer<ChatState>(
            builder: (context, state, _) => AnimatedBuilder(
              animation: OfflineSpeechService.instance,
              builder: (context, _) {
                final speech = OfflineSpeechService.instance;
                return IconButton(
                  tooltip: speech.capabilities.offlineTts
                      ? (speech.speaking || speech.generating
                            ? '停止朗读'
                            : '离线朗读上一条回复')
                      : '设备无离线 TTS 语音包',
                  onPressed: speech.capabilities.offlineTts
                      ? () => _speakLastReply(state)
                      : null,
                  icon: Icon(
                    speech.speaking || speech.generating
                        ? Icons.stop_circle_outlined
                        : Icons.volume_up_outlined,
                  ),
                );
              },
            ),
          ),
          Consumer<ChatState>(
            builder: (context, state, _) {
              final isThinking = state.enableThinking;
              return IconButton(
                icon: Icon(
                  isThinking ? Icons.psychology : Icons.psychology_outlined,
                  color: isThinking ? theme.colorScheme.primary : null,
                ),
                tooltip:
                    '${state.selectedProvider?.name ?? '未配置'} · ${state.selectedModel}',
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
                        chatState.clearError();
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
                    onTap: () async {
                      Navigator.pop(context);
                      await Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SettingsPage()),
                      );
                      await chatState.reloadProviderSettings();
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
          if (chatState.isStreaming && _isUserNearBottom()) {
            _scrollToBottom();
          }

          final characterId = chatState.currentCharacter?.id;
          final overridePath = _modelOverrideCharacterId == characterId
              ? _modelOverridePath
              : null;
          final configuredPath =
              overridePath?.trim() ??
              chatState.currentCharacter?.live2dModelPath.trim() ??
              '';
          final modelPath = configuredPath.isEmpty
              ? Live2dModelPaths.bundledMao
              : configuredPath;
          final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
          return Column(
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Live2dAvatar(
                      key: ValueKey(modelPath),
                      modelPath: modelPath,
                    ),
                    Positioned(
                      left: 12,
                      top: 12,
                      child: SafeArea(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton.filledTonal(
                              tooltip: _showTranscript ? '隐藏对话' : '查看对话',
                              onPressed: () => setState(
                                () => _showTranscript = !_showTranscript,
                              ),
                              icon: Icon(
                                _showTranscript
                                    ? Icons.visibility_off_outlined
                                    : Icons.forum_outlined,
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton.filledTonal(
                              tooltip: '导入 Live2D ZIP 模型',
                              onPressed: _isImportingLive2d
                                  ? null
                                  : _importLive2dModel,
                              icon: _isImportingLive2d
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.folder_open_outlined),
                            ),
                            const SizedBox(width: 8),
                            IconButton.filled(
                              tooltip: _callMode ? '结束持续通话' : '开始持续通话',
                              onPressed: _callTransitioning
                                  ? null
                                  : _toggleCallMode,
                              icon: Icon(
                                _callMode
                                    ? Icons.call_end_outlined
                                    : Icons.call_outlined,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_showTranscript)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final factor = keyboardVisible ? 0.46 : 0.58;
                            final minimum = keyboardVisible ? 104.0 : 180.0;
                            final scaledHeight = constraints.maxHeight * factor;
                            final targetHeight = scaledHeight < minimum
                                ? minimum
                                : scaledHeight;
                            final panelHeight = targetHeight
                                .clamp(0.0, constraints.maxHeight)
                                .toDouble();
                            return SizedBox(
                              width: double.infinity,
                              height: panelHeight,
                              child: _buildTranscriptPanel(chatState),
                            );
                          },
                        ),
                      ),
                    if (_showScrollToBottom && _showTranscript)
                      Positioned(
                        right: 16,
                        bottom: 12,
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
                ),
              ),
              _buildExecutionStatus(chatState),
              if (chatState.errorMessage != null)
                keyboardVisible
                    ? ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 112),
                        child: SingleChildScrollView(
                          child: _buildErrorBanner(chatState),
                        ),
                      )
                    : _buildErrorBanner(chatState),
              AnimatedBuilder(
                animation: OfflineSpeechService.instance,
                builder: (context, _) {
                  final speech = OfflineSpeechService.instance;
                  return ChatInput(
                    isStreaming: chatState.isStreaming,
                    onSend: _handleSend,
                    onStop: () {
                      unawaited(OfflineSpeechService.instance.stopSpeaking());
                      unawaited(chatState.stopGeneration());
                    },
                    onVoiceInput: _toggleListening,
                    isListening: speech.listening,
                    voiceEnabled: speech.capabilities.offlineStt,
                    allowVoiceDuringStreaming: _callMode,
                    dictatedText: speech.recognizedText,
                    maxLines: keyboardVisible ? 3 : 5,
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildExecutionStatus(ChatState chatState) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        OfflineLlmService.instance,
        MossTtsService.instance,
      ]),
      builder: (context, _) {
        final llm = OfflineLlmService.instance;
        final moss = MossTtsService.instance;
        final colors = Theme.of(context).colorScheme;
        final items = <({IconData icon, String label, Color color})>[];

        if (chatState.usesAndroidOfflineProvider) {
          items.add((
            icon: llm.hardwareAccelerationVerified
                ? Icons.memory
                : llm.usingCpuFallback
                ? Icons.developer_board_outlined
                : Icons.pending_outlined,
            label: 'LLM · ${llm.accelerationDescription}',
            color: llm.hardwareAccelerationVerified
                ? colors.primary
                : llm.usingCpuFallback
                ? colors.tertiary
                : colors.onSurfaceVariant,
          ));
        }
        if (moss.ready) {
          final cpuFallback =
              moss.providerMeasured && moss.activeProvider == 'CPU';
          items.add((
            icon: moss.hardwareAccelerationVerified
                ? Icons.graphic_eq
                : cpuFallback
                ? Icons.volume_up_outlined
                : Icons.pending_outlined,
            label: 'TTS · ${moss.accelerationLabel}',
            color: moss.hardwareAccelerationVerified
                ? colors.primary
                : cpuFallback
                ? colors.tertiary
                : colors.onSurfaceVariant,
          ));
        }
        if (items.isEmpty) return const SizedBox.shrink();

        final itemWidth = (MediaQuery.sizeOf(context).width - 24)
            .clamp(0.0, 420.0)
            .toDouble();
        return ColoredBox(
          color: colors.surfaceContainerLow,
          child: SafeArea(
            top: false,
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Wrap(
                spacing: 16,
                runSpacing: 6,
                children: items
                    .map(
                      (item) => SizedBox(
                        width: itemWidth,
                        child: Row(
                          children: [
                            Icon(item.icon, size: 16, color: item.color),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                item.label,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(color: item.color),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTranscriptPanel(ChatState chatState) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surface.withValues(alpha: 0.94),
      child: Column(
        children: [
          SizedBox(
            height: 44,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Expanded(child: Text('对话', style: theme.textTheme.titleSmall)),
                IconButton(
                  tooltip: '隐藏对话',
                  onPressed: () => setState(() => _showTranscript = false),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildMessageArea(chatState)),
        ],
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
                    textAlign: TextAlign.center,
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
            ),
          ),
        );
      },
    );
  }

  Widget _buildErrorBanner(ChatState chatState) {
    final theme = Theme.of(context);
    final errorMsg = chatState.errorMessage ?? '';
    final isDetailedError =
        errorMsg.contains('API') ||
        errorMsg.contains('token') ||
        errorMsg.contains('超时') ||
        errorMsg.contains('连接') ||
        errorMsg.contains('status') ||
        errorMsg.contains('尝试') ||
        errorMsg.contains('网络');
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: theme.colorScheme.error,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        errorMsg,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                        maxLines: isDetailedError ? 8 : 4,
                        overflow: TextOverflow.ellipsis,
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
                if (chatState.currentConversationId != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton.icon(
                          onPressed: _handleRetry,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('重试'),
                          style: TextButton.styleFrom(
                            foregroundColor: theme.colorScheme.error,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStreamingBubble(ChatState chatState) {
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
