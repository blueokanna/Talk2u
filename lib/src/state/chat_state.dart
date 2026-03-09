import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:talk2u/src/models/character.dart';
import 'package:talk2u/src/rust/api/chat_api.dart' as rust_api;
import 'package:talk2u/src/rust/api/data_models.dart';

@visibleForTesting
typedef TestStreamSetup = void Function(Stream<ChatStreamEvent>, String);

class ChatState extends ChangeNotifier {
  String? _currentConversationId;
  bool _enableThinking = true;
  bool _isStreaming = false;
  String _currentStreamingContent = '';
  String _currentThinkingContent = '';
  List<Message> _messages = [];
  String? _errorMessage;
  String? _lastFailedContent;
  List<ConversationSummary> _conversations = [];
  StreamSubscription<ChatStreamEvent>? _streamSubscription;

  // 流式超时安全机制
  Timer? _streamTimeoutTimer;

  // FRB 竞态防护：可取消的重试定时器
  Timer? _retryDoneTimer;

  // 角色关联
  Map<String, String> _conversationCharacterMap = {};
  Character? _currentCharacter;

  // 模型选择
  String _selectedModel = 'glm-4.7';
  static const String chatModel = 'glm-4.7';
  static const String thinkingModel = 'glm-4-air';
  static const String flashModel = 'glm-4.7-flash';

  // 对话风格
  DialogueStyle _dialogueStyle = DialogueStyle.mixed;

  // 流式显示节流控制
  Timer? _streamThrottleTimer;
  bool _streamDirty = false;

  // Done 事件追踪：防止 FRB 流关闭与 Done 事件的竞态条件
  bool _doneEventReceived = false;

  // Getters
  String? get currentConversationId => _currentConversationId;
  bool get enableThinking => _enableThinking;
  bool get isStreaming => _isStreaming;
  String get currentStreamingContent => _currentStreamingContent;
  String get currentThinkingContent => _currentThinkingContent;
  List<Message> get messages => List.unmodifiable(_messages);
  String? get errorMessage => _errorMessage;
  String? get lastFailedContent => _lastFailedContent;
  List<ConversationSummary> get conversations =>
      List.unmodifiable(_conversations);
  Character? get currentCharacter => _currentCharacter;
  String get selectedModel => _selectedModel;
  DialogueStyle get dialogueStyle => _dialogueStyle;

  /// 获取展示用的消息列表（过滤掉 system 消息）
  List<Message> get displayMessages =>
      _messages.where((m) => m.role != MessageRole.system).toList();

  Future<void> initialize() async {
    try {
      final settings = await rust_api.getSettings();
      _enableThinking = settings.enableThinkingByDefault;
      _selectedModel = settings.chatModel;
      await CharacterStore.instance.load();
      await _loadConversationCharacterMap();
      await refreshConversationList();
    } catch (e) {
      debugPrint('Failed to initialize: $e');
    }
  }

  // ── 模型选择 ──

  void setSelectedModel(String model) {
    _selectedModel = model;
    // glm-4-air 自动开启思考
    if (model == thinkingModel) {
      _enableThinking = true;
    } else if (model == flashModel) {
      // flash 模型不支持思考
      _enableThinking = false;
    }
    // glm-4.7 保持用户当前的思考偏好不变
    notifyListeners();
  }

  // ── 对话风格 ──

  void setDialogueStyle(DialogueStyle style) {
    _dialogueStyle = style;
    if (_currentConversationId != null) {
      rust_api.setDialogueStyle(
        conversationId: _currentConversationId!,
        style: style,
      );
    }
    notifyListeners();
  }

  // ── 角色-对话映射持久化 ──

  Future<String> get _mapFilePath async {
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/conversation_character_map.json';
  }

  Future<void> _loadConversationCharacterMap() async {
    try {
      final path = await _mapFilePath;
      final file = File(path);
      if (await file.exists()) {
        final content = await file.readAsString();
        final map = jsonDecode(content) as Map<String, dynamic>;
        _conversationCharacterMap = map.cast<String, String>();
      }
    } catch (e) {
      debugPrint('Failed to load conversation-character map: $e');
    }
  }

  Future<void> _saveConversationCharacterMap() async {
    try {
      final path = await _mapFilePath;
      await File(path).writeAsString(jsonEncode(_conversationCharacterMap));
    } catch (e) {
      debugPrint('Failed to save conversation-character map: $e');
    }
  }

  // ── 对话管理 ──

  Future<void> refreshConversationList() async {
    try {
      _conversations = await rust_api.getConversationList();
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to load conversations: $e');
    }
  }

  Future<void> createNewConversation() async {
    try {
      final conv = await rust_api.createConversation();
      _currentConversationId = conv.id;
      _messages = [];
      _currentStreamingContent = '';
      _currentThinkingContent = '';
      _errorMessage = null;
      _currentCharacter = null;
      await refreshConversationList();
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to create conversation: $e');
    }
  }

  /// 创建与角色关联的新对话
  Future<void> startCharacterChat(Character character) async {
    try {
      final conv = await rust_api.createConversation();
      _currentConversationId = conv.id;
      _messages = [];
      _currentStreamingContent = '';
      _currentThinkingContent = '';
      _errorMessage = null;
      _currentCharacter = character;

      // 保存角色关联
      _conversationCharacterMap[conv.id] = character.id;
      await _saveConversationCharacterMap();

      // 注入系统提示词
      final systemPrompt = character.buildSystemPrompt();
      await rust_api.addSystemMessage(
        conversationId: conv.id,
        content: systemPrompt,
      );

      // 注入角色开场白
      if (character.greeting.isNotEmpty) {
        await rust_api.addAssistantMessage(
          conversationId: conv.id,
          content: character.greeting,
        );
      }

      // 重新加载对话以获取完整消息列表
      await loadConversation(conv.id);
      await refreshConversationList();
    } catch (e) {
      debugPrint('Failed to start character chat: $e');
    }
  }

  Future<void> loadConversation(String id, {bool preserveError = false}) async {
    try {
      final conv = await rust_api.getConversation(id: id);
      if (conv != null) {
        _currentConversationId = conv.id;
        _messages = conv.messages;
        // 仅在非 preserveError 模式下清除错误
        // 流式完成后的 loadConversation 应保留错误信息
        if (!preserveError) {
          _errorMessage = null;
        }
        _currentStreamingContent = '';
        _currentThinkingContent = '';
        _dialogueStyle = conv.dialogueStyle;

        // 恢复角色关联
        final characterId = _conversationCharacterMap[id];
        if (characterId != null) {
          _currentCharacter = CharacterStore.instance.getById(characterId);
        } else {
          _currentCharacter = null;
        }

        notifyListeners();
      }
    } catch (e) {
      debugPrint('Failed to load conversation: $e');
    }
  }

  Future<void> deleteConversation(String id) async {
    try {
      await rust_api.deleteConversation(id: id);
      if (_currentConversationId == id) {
        _currentConversationId = null;
        _messages = [];
        _currentCharacter = null;
      }
      _conversationCharacterMap.remove(id);
      await _saveConversationCharacterMap();
      await refreshConversationList();
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to delete conversation: $e');
    }
  }

  Future<void> deleteMessage(String messageId) async {
    if (_currentConversationId == null) return;
    try {
      await rust_api.deleteMessage(
        conversationId: _currentConversationId!,
        messageId: messageId,
      );
      _messages = List.from(_messages)..removeWhere((m) => m.id == messageId);
      notifyListeners();
      await refreshConversationList();
    } catch (e) {
      debugPrint('Failed to delete message: $e');
    }
  }

  /// 编辑用户消息内容
  Future<void> editMessage(String messageId, String newContent) async {
    if (_currentConversationId == null) return;
    if (newContent.trim().isEmpty) return;
    try {
      final success = await rust_api.editMessage(
        conversationId: _currentConversationId!,
        messageId: messageId,
        newContent: newContent,
      );
      if (success) {
        await loadConversation(_currentConversationId!);
        await refreshConversationList();
      }
    } catch (e) {
      debugPrint('Failed to edit message: $e');
    }
  }

  /// 回溯到某条用户消息：删除该消息及之后的所有消息，
  /// 同时清除相关的记忆摘要
  Future<void> rollbackToMessage(String messageId) async {
    if (_currentConversationId == null) return;
    try {
      final deletedIds = await rust_api.rollbackToMessage(
        conversationId: _currentConversationId!,
        messageId: messageId,
      );
      if (deletedIds.isNotEmpty) {
        await loadConversation(_currentConversationId!);
        await refreshConversationList();
      }
    } catch (e) {
      debugPrint('Failed to rollback to message: $e');
    }
  }

  /// 编辑用户消息并重新发送（回溯到该消息，然后发送新内容）
  Future<void> editAndResend(String messageId, String newContent) async {
    if (_currentConversationId == null || _isStreaming) return;
    if (newContent.trim().isEmpty) return;
    final conversationId = _currentConversationId!;
    try {
      // 先回溯删除该消息及之后的所有消息
      await rust_api.rollbackToMessage(
        conversationId: conversationId,
        messageId: messageId,
      );
      // 重新加载对话
      await loadConversation(conversationId);
      // 发送新内容（会自动添加用户消息并请求 AI 回复）
      await sendMessage(newContent);
    } catch (e) {
      debugPrint('Failed to edit and resend: $e');
      // 确保即使出错也能恢复到正确状态
      if (_isStreaming) {
        endStreaming();
      }
      await loadConversation(conversationId);
      _errorMessage = '编辑重发失败: $e';
      notifyListeners();
    }
  }

  /// 重新生成AI回复：只删除该AI回复，然后重新请求AI生成
  Future<void> regenerateResponse(String assistantMessageId) async {
    if (_currentConversationId == null || _isStreaming) return;
    try {
      // 找到该AI消息在列表中的位置
      final msgIndex = _messages.indexWhere((m) => m.id == assistantMessageId);
      if (msgIndex < 0) return;

      // 只删除这条AI消息及之后的所有消息（保留用户消息）
      // rollbackToMessage 会删除目标消息及之后的所有消息
      await rust_api.rollbackToMessage(
        conversationId: _currentConversationId!,
        messageId: assistantMessageId,
      );

      // 重新加载对话（此时用户消息还在，AI消息已删除）
      await loadConversation(_currentConversationId!);

      final conversationId = _currentConversationId!;

      // 【关键修复】取消旧的流式订阅，防止僵尸回调
      _cancelExistingSubscription();

      // 使用 regenerateResponse API，不会重新添加用户消息
      startStreaming();

      final stream = rust_api.regenerateResponse(
        conversationId: conversationId,
        model: _selectedModel,
        enableThinking: _enableThinking,
      );

      _listenToChatStream(stream, conversationId);
    } catch (e) {
      debugPrint('Failed to regenerate response: $e');
      if (_isStreaming) endStreaming();
    }
  }

  // ── 重启剧情 ──

  Future<void> restartStory() async {
    if (_currentConversationId == null) return;
    try {
      final success = await rust_api.restartStory(
        conversationId: _currentConversationId!,
      );
      if (success) {
        await loadConversation(_currentConversationId!);
        await refreshConversationList();
      }
    } catch (e) {
      debugPrint('Failed to restart story: $e');
    }
  }

  // ── 流式聊天 ──

  void setEnableThinking(bool enabled) {
    _enableThinking = enabled;
    // 关闭思考时：如果当前选的是推理模型，切回对话模型
    if (!enabled && _selectedModel == thinkingModel) {
      _selectedModel = chatModel;
    }
    // 开启思考时：如果当前选的是 flash 模型（不支持思考），切回对话模型
    if (enabled && _selectedModel == flashModel) {
      _selectedModel = chatModel;
    }
    notifyListeners();
  }

  /// 取消旧的流式订阅，防止僵尸回调干扰新的流式会话
  void _cancelExistingSubscription() {
    _streamSubscription?.cancel();
    _streamSubscription = null;
  }

  void startStreaming() {
    _isStreaming = true;
    _currentStreamingContent = '';
    _currentThinkingContent = '';
    _errorMessage = null;
    _streamDirty = false;
    _doneEventReceived = false;
    // 启动节流定时器：每 30ms 刷新一次 UI，实现逐字显示效果
    _streamThrottleTimer?.cancel();
    _streamThrottleTimer = Timer.periodic(const Duration(milliseconds: 30), (
      _,
    ) {
      if (_streamDirty) {
        _streamDirty = false;
        notifyListeners();
      }
    });
    notifyListeners();
  }

  void appendStreamingContent(String delta) {
    _currentStreamingContent += delta;
    _streamDirty = true;
    // 不直接 notifyListeners，由节流定时器统一刷新
  }

  void appendThinkingContent(String delta) {
    _currentThinkingContent += delta;
    _streamDirty = true;
  }

  void endStreaming() {
    _isStreaming = false;
    _streamThrottleTimer?.cancel();
    _streamThrottleTimer = null;
    _streamTimeoutTimer?.cancel();
    _streamTimeoutTimer = null;
    // 最后一次刷新，确保所有累积的流式内容都显示出来
    if (_streamDirty) {
      _streamDirty = false;
    }
    notifyListeners();
  }

  // ═══════════════════════════════════════════
  //  统一流式监听器（消除 3 处重复代码）
  // ═══════════════════════════════════════════

  /// 监听 Rust FFI 返回的 ChatStreamEvent 流。
  /// 统一处理 contentDelta / thinkingDelta / done / error / onDone 竞态。
  /// [conversationId] 用于防止切换对话后的陈旧回调。
  void _listenToChatStream(
    Stream<ChatStreamEvent> stream,
    String conversationId,
  ) {
    _streamSubscription = stream.listen(
      (event) {
        // 陈旧会话守卫：用户已切换到其他对话，忽略旧流事件
        if (_currentConversationId != conversationId) return;

        try {
          event.when(
            contentDelta: (delta) => appendStreamingContent(delta),
            thinkingDelta: (delta) => appendThinkingContent(delta),
            done: () {
              _doneEventReceived = true;
              final activeError = _errorMessage;
              endStreaming();
              // 陈旧守卫：endStreaming 之后再检查一次
              if (_currentConversationId != conversationId) return;
              loadConversation(conversationId, preserveError: true).then((_) {
                if (activeError != null && _errorMessage == null) {
                  _errorMessage = activeError;
                }
                refreshConversationList();
                if (_errorMessage == null) {
                  _checkAndTriggerMemorySummarize(conversationId);
                }
                notifyListeners();
              });
            },
            error: (msg) {
              if (msg == '__RETRY_RESET__') {
                _currentStreamingContent = '';
                _currentThinkingContent = '';
                _streamDirty = true;
                return;
              }
              _errorMessage = msg;
              debugPrint('[ChatState] Stream error event: $msg');
              notifyListeners();
            },
          );
        } catch (e) {
          debugPrint('[ChatState] Error processing stream event: $e');
          if (_isStreaming) endStreaming();
          _errorMessage = e.toString();
          if (_currentConversationId == conversationId) {
            loadConversation(conversationId, preserveError: true).then((_) {
              notifyListeners();
            });
          } else {
            notifyListeners();
          }
        }
      },
      onError: (e) {
        debugPrint('[ChatState] Stream error: $e');
        // 陈旧会话守卫：先检查是否仍是当前对话
        if (_currentConversationId != conversationId) return;
        if (_isStreaming) endStreaming();
        _errorMessage = e.toString();
        loadConversation(conversationId, preserveError: true).then((_) {
          notifyListeners();
        });
      },
      onDone: () {
        // Done 事件已通过 event handler 处理，无需兜底
        if (!_isStreaming || _doneEventReceived) return;

        // ═══ FRB 竞态防护（递增间隔多次重试）═══
        // flutter_rust_bridge 的流关闭信号可能先于最后一个 Done 数据事件到达。
        // 给 Dart 事件循环多个宽限窗口来处理尚在队列中的 Done 事件。
        final activeError = _errorMessage;
        _retryDoneCheck(conversationId, activeError, 0);
      },
    );
  }

  /// FRB 竞态防护：递增间隔检查 Done 事件是否已到达。
  /// 总窗口约 2 秒（300 + 700 + 1000ms），比单次 500ms 更可靠。
  void _retryDoneCheck(
    String conversationId,
    String? activeError,
    int attempt,
  ) {
    const delays = [300, 700, 1000]; // 累计 300 → 1000 → 2000ms

    if (attempt >= delays.length) {
      // 所有重试耗尽，做最终判定
      if (_doneEventReceived || !_isStreaming) return;
      if (_currentConversationId != conversationId) return;

      debugPrint(
        '[ChatState] Stream closed without Done after 2s grace (conv=$conversationId)',
      );
      endStreaming();
      loadConversation(conversationId, preserveError: true).then((_) async {
        final hasAssistantResponse =
            _messages.isNotEmpty &&
            _messages.last.role == MessageRole.assistant;

        if (hasAssistantResponse) {
          if (activeError != null && _errorMessage == null) {
            _errorMessage = activeError;
          }
          refreshConversationList();
          if (_errorMessage == null) {
            _checkAndTriggerMemorySummarize(conversationId);
          }
          notifyListeners();
          return;
        }

        final partialContent = _currentStreamingContent.trim();
        if (partialContent.isNotEmpty) {
          final persisted = await _persistPartialAssistantReply(
            conversationId,
            partialContent,
          );
          if (persisted) {
            _errorMessage = null;
            notifyListeners();
            return;
          }
        }

        if (activeError != null && _errorMessage == null) {
          _errorMessage = activeError;
        }
        _errorMessage ??= 'AI 响应中断，请点击重试';
        notifyListeners();
      });
      return;
    }

    _retryDoneTimer?.cancel();
    _retryDoneTimer = Timer(Duration(milliseconds: delays[attempt]), () {
      if (_doneEventReceived || !_isStreaming) return;
      if (_currentConversationId != conversationId) return;
      _retryDoneCheck(conversationId, activeError, attempt + 1);
    });
  }

  Future<bool> _persistPartialAssistantReply(
    String conversationId,
    String content,
  ) async {
    try {
      final saved = await rust_api.addAssistantMessage(
        conversationId: conversationId,
        content: content,
      );
      if (!saved) return false;
      await loadConversation(conversationId, preserveError: true);
      await refreshConversationList();
      _checkAndTriggerMemorySummarize(conversationId);
      return true;
    } catch (e) {
      debugPrint('[ChatState] Failed to persist partial assistant reply: $e');
      return false;
    }
  }

  Future<void> sendMessage(String content) async {
    if (content.trim().isEmpty || _isStreaming) return;

    // 【关键修复】取消旧的流式订阅，防止旧流的 onDone 回调
    // 在新流运行时触发 endStreaming()，导致新流被意外终止
    _cancelExistingSubscription();

    // 新消息开始时清除之前的错误状态
    _errorMessage = null;
    _lastFailedContent = null;

    if (_currentConversationId == null) {
      await createNewConversation();
    }

    final conversationId = _currentConversationId;
    if (conversationId == null) return;

    startStreaming();

    _messages = List.from(_messages)
      ..add(
        Message(
          id: '',
          role: MessageRole.user,
          content: content,
          model: _selectedModel,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          messageType: MessageType.say,
        ),
      );
    notifyListeners();

    try {
      final stream = rust_api.sendMessage(
        conversationId: conversationId,
        content: content,
        model: _selectedModel,
        enableThinking: _enableThinking,
      );

      _listenToChatStream(stream, conversationId);
    } catch (e) {
      debugPrint('[ChatState] Failed to create stream: $e');
      endStreaming();
      loadConversation(conversationId).then((_) {
        _errorMessage = e.toString();
        notifyListeners();
      });
    }
  }

  /// 检查并异步触发记忆总结
  void _checkAndTriggerMemorySummarize(String conversationId) async {
    try {
      final shouldSummarize = await rust_api.shouldSummarizeMemory(
        conversationId: conversationId,
      );
      if (shouldSummarize) {
        debugPrint('Triggering memory summarization for $conversationId');
        // 异步触发，不阻塞 UI
        final stream = rust_api.triggerMemorySummarize(
          conversationId: conversationId,
        );
        stream.listen(
          (_) {},
          onDone: () {
            debugPrint('Memory summarization completed');
          },
          onError: (e) {
            debugPrint('Memory summarization error: $e');
          },
        );
      }
    } catch (e) {
      debugPrint('Failed to check memory summarization: $e');
    }
  }

  // ── 错误处理 ──

  void setError(String message, {String? failedContent}) {
    _errorMessage = message;
    _isStreaming = false;
    _streamThrottleTimer?.cancel();
    _streamThrottleTimer = null;
    if (failedContent != null) {
      _lastFailedContent = failedContent;
    }
    notifyListeners();
  }

  void clearError() {
    _errorMessage = null;
    _lastFailedContent = null;
    notifyListeners();
  }

  /// 重试上次失败的消息：不重新添加用户消息，直接请求 AI 重新生成
  Future<void> retryLastMessage() async {
    if (_currentConversationId == null || _isStreaming) return;
    final conversationId = _currentConversationId!;

    // 【关键修复】取消旧的流式订阅
    _cancelExistingSubscription();

    _errorMessage = null;
    _lastFailedContent = null;
    startStreaming();

    try {
      final stream = rust_api.regenerateResponse(
        conversationId: conversationId,
        model: _selectedModel,
        enableThinking: _enableThinking,
      );

      _listenToChatStream(stream, conversationId);
    } catch (e) {
      setError(e.toString());
    }
  }

  @override
  void dispose() {
    _cancelExistingSubscription();
    _streamThrottleTimer?.cancel();
    _streamTimeoutTimer?.cancel();
    _retryDoneTimer?.cancel();
    super.dispose();
  }

  // ── 测试辅助 ──

  /// 仅供测试使用：设置当前对话 ID 并监听流
  @visibleForTesting
  void listenToChatStreamForTest(
    Stream<ChatStreamEvent> stream,
    String conversationId,
  ) {
    _currentConversationId = conversationId;
    _listenToChatStream(stream, conversationId);
  }

  /// 仅供测试使用：设置当前对话 ID
  @visibleForTesting
  void setCurrentConversationIdForTest(String? id) {
    _currentConversationId = id;
  }
}
