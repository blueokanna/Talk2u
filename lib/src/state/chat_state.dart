import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:talk2u/src/models/character.dart';
import 'package:talk2u/src/rust/api/chat_api.dart' as rust_api;
import 'package:talk2u/src/rust/api/data_models.dart';

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

  // 流式超时保护：如果长时间没有收到任何数据，自动恢复
  Timer? _streamTimeoutTimer;
  // 多模型管线（蒸馏→推理→辅助→对话）可能需要多次 HTTP 请求，
  // 每次最多 180s，加上重试最多 3 次 = 单阶段最长 ~540s。
  // 设为 600s 确保不会误杀正常的长管线执行。
  static const Duration _streamTimeout = Duration(seconds: 600);

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
      // flash 模型支持思考，保持用户当前偏好
    }
    // glm-4.7 支持思考（官方确认），保持用户当前的思考偏好不变
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

  Future<void> loadConversation(String id) async {
    try {
      final conv = await rust_api.getConversation(id: id);
      if (conv != null) {
        _currentConversationId = conv.id;
        _messages = conv.messages;
        _errorMessage = null;
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

      // 使用 regenerateResponse API，不会重新添加用户消息
      _errorMessage = null;
      startStreaming();

      debugPrint(
        '[ChatState] 重新生成: model=$_selectedModel, thinking=$_enableThinking',
      );
      final stream = rust_api.regenerateResponse(
        conversationId: conversationId,
        model: _selectedModel,
        enableThinking: _enableThinking,
      );

      _streamSubscription?.cancel();
      _streamSubscription = stream.listen(
        (event) {
          event.when(
            contentDelta: (delta) => appendStreamingContent(delta),
            thinkingDelta: (delta) => appendThinkingContent(delta),
            done: () {
              debugPrint(
                '[ChatState] 重新生成完成: content_len=${_currentStreamingContent.length}',
              );
              endStreaming();
              loadConversation(conversationId).then((_) {
                refreshConversationList();
                _checkAndTriggerMemorySummarize(conversationId);
              });
            },
            error: (msg) {
              debugPrint('[ChatState] 重新生成错误: $msg');
              _errorMessage = msg;
              if (_currentStreamingContent.isEmpty &&
                  _currentThinkingContent.isEmpty) {
                notifyListeners();
              }
            },
          );
        },
        onError: (e) {
          debugPrint('[ChatState] 重新生成流错误: $e');
          if (_isStreaming) endStreaming();
          setError(e.toString());
        },
        onDone: () {
          debugPrint('[ChatState] 重新生成流关闭: isStreaming=$_isStreaming');
          if (_isStreaming) {
            endStreaming();
            loadConversation(conversationId).then((_) {
              final hasNewAssistantMsg =
                  _messages.isNotEmpty &&
                  _messages.last.role == MessageRole.assistant;
              if (!hasNewAssistantMsg && _errorMessage == null) {
                _errorMessage = 'AI 响应中断，请重试。';
              }
              refreshConversationList();
              notifyListeners();
            });
          }
        },
      );
    } catch (e) {
      debugPrint('[ChatState] regenerateResponse 异常: $e');
      if (_isStreaming) endStreaming();
      _errorMessage = '重新生成失败: $e';
      notifyListeners();
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
    // flash 模型支持思考（官方确认），无需切换
    notifyListeners();
  }

  void startStreaming() {
    _isStreaming = true;
    _currentStreamingContent = '';
    _currentThinkingContent = '';
    _errorMessage = null;
    _streamDirty = false;
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
    // 启动超时保护：如果长时间没有数据，自动恢复
    _resetStreamTimeout();
    notifyListeners();
  }

  void appendStreamingContent(String delta) {
    _currentStreamingContent += delta;
    _streamDirty = true;
    _resetStreamTimeout(); // 收到数据，重置超时
  }

  void appendThinkingContent(String delta) {
    _currentThinkingContent += delta;
    _streamDirty = true;
    _resetStreamTimeout(); // 收到数据，重置超时
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

  /// 重置流式超时计时器
  /// 每次收到数据时调用，如果超时未收到数据则自动恢复
  void _resetStreamTimeout() {
    _streamTimeoutTimer?.cancel();
    _streamTimeoutTimer = Timer(_streamTimeout, () {
      if (_isStreaming) {
        debugPrint('[ChatState] 流式响应超时（${_streamTimeout.inSeconds}s 无数据），自动恢复');
        endStreaming();
        if (_currentConversationId != null) {
          loadConversation(_currentConversationId!).then((_) {
            // 检查 Rust 端是否已保存了回复
            final hasNewAssistantMsg =
                _messages.isNotEmpty &&
                _messages.last.role == MessageRole.assistant;
            if (!hasNewAssistantMsg) {
              _errorMessage = 'AI 响应超时，请重试。如果问题持续，尝试缩短对话或切换模型。';
            }
            notifyListeners();
          });
        } else {
          _errorMessage = 'AI 响应超时，请重试。';
          notifyListeners();
        }
      }
    });
  }

  Future<void> sendMessage(String content) async {
    if (content.trim().isEmpty || _isStreaming) return;

    if (_currentConversationId == null) {
      await createNewConversation();
    }

    final conversationId = _currentConversationId;
    if (conversationId == null) return;

    // 清除之前的错误
    _errorMessage = null;
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
      debugPrint(
        '[ChatState] 发送消息: model=$_selectedModel, thinking=$_enableThinking, len=${content.length}',
      );
      final stream = rust_api.sendMessage(
        conversationId: conversationId,
        content: content,
        model: _selectedModel,
        enableThinking: _enableThinking,
      );

      _streamSubscription?.cancel();
      _streamSubscription = stream.listen(
        (event) {
          event.when(
            contentDelta: (delta) => appendStreamingContent(delta),
            thinkingDelta: (delta) => appendThinkingContent(delta),
            done: () {
              debugPrint(
                '[ChatState] 流式完成: content_len=${_currentStreamingContent.length}',
              );
              endStreaming();
              loadConversation(conversationId).then((_) {
                refreshConversationList();
                _checkAndTriggerMemorySummarize(conversationId);
              });
            },
            error: (msg) {
              debugPrint('[ChatState] 流式错误: $msg');
              // 记录错误，但不立即结束流式状态
              // Done 事件或 onDone 回调会负责结束
              _errorMessage = msg;
              // 如果没有任何内容且没有在等待后续事件，立即通知 UI 显示错误
              if (_currentStreamingContent.isEmpty &&
                  _currentThinkingContent.isEmpty) {
                notifyListeners();
              }
            },
          );
        },
        onError: (e) {
          debugPrint('[ChatState] 流监听错误: $e');
          // 流本身出错（不是业务错误），必须恢复
          if (_isStreaming) endStreaming();
          loadConversation(conversationId).then((_) {
            _errorMessage = '连接异常: $e';
            notifyListeners();
          });
        },
        onDone: () {
          // 流关闭 = Rust 函数已返回，无论如何都必须结束流式状态
          debugPrint(
            '[ChatState] 流关闭: isStreaming=$_isStreaming, content_len=${_currentStreamingContent.length}',
          );
          if (_isStreaming) {
            endStreaming();
            // 始终重新加载对话：Rust 可能已经保存了消息，但 Done 事件
            // 因 flutter_rust_bridge 流关闭竞态而丢失
            loadConversation(conversationId).then((_) {
              // 检查对话中是否已有新的 AI 回复（Rust 端已持久化）
              final hasNewAssistantMsg =
                  _messages.isNotEmpty &&
                  _messages.last.role == MessageRole.assistant;
              if (!hasNewAssistantMsg && _errorMessage == null) {
                _errorMessage = 'AI 响应中断，请重试。';
              }
              refreshConversationList();
              notifyListeners();
            });
          }
        },
      );
    } catch (e) {
      debugPrint('[ChatState] sendMessage 异常: $e');
      endStreaming();
      loadConversation(conversationId).then((_) {
        _errorMessage = '发送失败: $e';
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
    _streamTimeoutTimer?.cancel();
    _streamTimeoutTimer = null;
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

    _errorMessage = null;
    _lastFailedContent = null;
    startStreaming();

    try {
      debugPrint(
        '[ChatState] 重试: model=$_selectedModel, thinking=$_enableThinking',
      );
      final stream = rust_api.regenerateResponse(
        conversationId: conversationId,
        model: _selectedModel,
        enableThinking: _enableThinking,
      );

      _streamSubscription?.cancel();
      _streamSubscription = stream.listen(
        (event) {
          event.when(
            contentDelta: (delta) => appendStreamingContent(delta),
            thinkingDelta: (delta) => appendThinkingContent(delta),
            done: () {
              debugPrint(
                '[ChatState] 重试完成: content_len=${_currentStreamingContent.length}',
              );
              endStreaming();
              loadConversation(conversationId).then((_) {
                refreshConversationList();
                _checkAndTriggerMemorySummarize(conversationId);
              });
            },
            error: (msg) {
              debugPrint('[ChatState] 重试错误: $msg');
              _errorMessage = msg;
              if (_currentStreamingContent.isEmpty &&
                  _currentThinkingContent.isEmpty) {
                notifyListeners();
              }
            },
          );
        },
        onError: (e) {
          debugPrint('[ChatState] 重试流错误: $e');
          if (_isStreaming) endStreaming();
          setError(e.toString());
        },
        onDone: () {
          debugPrint('[ChatState] 重试流关闭: isStreaming=$_isStreaming');
          if (_isStreaming) {
            endStreaming();
            loadConversation(conversationId).then((_) {
              final hasNewAssistantMsg =
                  _messages.isNotEmpty &&
                  _messages.last.role == MessageRole.assistant;
              if (!hasNewAssistantMsg && _errorMessage == null) {
                _errorMessage = 'AI 响应中断，请重试。';
              }
              refreshConversationList();
              notifyListeners();
            });
          }
        },
      );
    } catch (e) {
      debugPrint('[ChatState] retryLastMessage 异常: $e');
      setError(e.toString());
    }
  }

  @override
  void dispose() {
    _streamSubscription?.cancel();
    _streamThrottleTimer?.cancel();
    _streamTimeoutTimer?.cancel();
    super.dispose();
  }
}
