import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:talk2u/src/models/character.dart';
import 'package:talk2u/src/models/provider_profile.dart';
import 'package:talk2u/src/rust/api/chat_api.dart' as rust_api;
import 'package:talk2u/src/rust/api/data_models.dart';
import 'package:talk2u/src/services/offline_llm_service.dart';

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

  Timer? _retryDoneTimer;

  Map<String, String> _conversationCharacterMap = {};
  Character? _currentCharacter;

  String _selectedModel = 'glm-4.7';
  static const String chatModel = 'glm-4.7';
  static const String thinkingModel = 'glm-4-air';
  static const String flashModel = 'glm-4.7-flash';
  List<ProviderProfile> _providers = [];
  String _selectedProviderId = 'zhipu';

  DialogueStyle _dialogueStyle = DialogueStyle.mixed;

  Timer? _streamThrottleTimer;
  bool _streamDirty = false;

  bool _doneEventReceived = false;
  bool _generationWasCancelled = false;
  int _completedResponseRevision = 0;

  String? get currentConversationId => _currentConversationId;
  bool get enableThinking => _enableThinking;
  bool get isStreaming => _isStreaming;
  String get currentStreamingContent => _currentStreamingContent;
  String get currentThinkingContent => _currentThinkingContent;
  List<Message> get messages => List.unmodifiable(_messages);
  String? get errorMessage => _errorMessage;
  String? get lastFailedContent => _lastFailedContent;
  int get completedResponseRevision => _completedResponseRevision;
  List<ConversationSummary> get conversations =>
      List.unmodifiable(_conversations);
  Character? get currentCharacter => _currentCharacter;
  String get selectedModel => _selectedModel;
  List<ProviderProfile> get providers => List.unmodifiable(_providers);
  String get selectedProviderId => _selectedProviderId;
  ProviderProfile? get selectedProvider {
    for (final provider in _providers) {
      if (provider.id == _selectedProviderId) return provider;
    }
    return null;
  }

  bool get usesAndroidOfflineProvider =>
      _selectedProviderId == ProviderProfile.androidOfflineId;

  DialogueStyle get dialogueStyle => _dialogueStyle;

  List<Message> get displayMessages =>
      _messages.where((m) => m.role != MessageRole.system).toList();

  Future<void> initialize() async {
    try {
      final settings = await rust_api.getSettings();
      _applyProviderSettings(settings);
      await OfflineLlmService.instance.initialize();
      if (OfflineLlmService.instance.modelReady &&
          !_providers.any(
            (provider) => !provider.isLocal && provider.isConfigured,
          )) {
        final offline = _providers.where((provider) => provider.isLocal);
        if (offline.isNotEmpty) {
          _selectedProviderId = offline.first.id;
          _selectedModel = offline.first.chatModel;
          _enableThinking = false;
          await _persistSelectedProvider(offline.first);
        }
      }
      await CharacterStore.instance.load();
      await _loadConversationCharacterMap();
      await refreshConversationList();
    } catch (e) {
      debugPrint('Failed to initialize: $e');
    }
  }

  void _applyProviderSettings(AppSettings settings) {
    _providers = ProviderProfile.withRuntimeDefaults(
      ProviderProfile.decodeList(settings.providersJson),
      includeAndroidOffline: OfflineLlmService.instance.supported,
    );
    final legacyZhipuKey = settings.apiKey?.trim();
    if (legacyZhipuKey?.isNotEmpty == true) {
      final zhipuIndex = _providers.indexWhere(
        (provider) => provider.id == 'zhipu',
      );
      if (zhipuIndex >= 0 &&
          _providers[zhipuIndex].apiKey?.trim().isNotEmpty != true) {
        _providers[zhipuIndex] = _providers[zhipuIndex].copyWith(
          apiKey: legacyZhipuKey,
        );
      }
    }
    _selectedProviderId =
        _providers.any((provider) => provider.id == settings.selectedProvider)
        ? settings.selectedProvider
        : _providers.first.id;
    _selectedModel = selectedProvider?.chatModel ?? settings.chatModel;
    _enableThinking =
        settings.enableThinkingByDefault &&
        (selectedProvider?.supportsThinking ?? false);
  }

  Future<void> reloadProviderSettings() async {
    try {
      _applyProviderSettings(await rust_api.getSettings());
      notifyListeners();
    } catch (error) {
      debugPrint('Failed to reload provider settings: $error');
    }
  }

  Future<void> setSelectedProvider(String providerId) async {
    if (_selectedProviderId == providerId || _isStreaming) return;
    final provider = _providers.firstWhere((item) => item.id == providerId);
    _selectedProviderId = providerId;
    _selectedModel = provider.chatModel;
    _enableThinking = provider.supportsThinking && _enableThinking;
    notifyListeners();

    await _persistSelectedProvider(provider);
  }

  Future<void> _persistSelectedProvider(ProviderProfile provider) async {
    try {
      final old = await rust_api.getSettings();
      await rust_api.saveSettings(
        settings: AppSettings(
          apiKey: old.apiKey,
          defaultModel: provider.chatModel,
          enableThinkingByDefault: old.enableThinkingByDefault,
          chatModel: provider.chatModel,
          thinkingModel: provider.thinkingModel ?? '',
          selectedProvider: provider.id,
          providersJson: ProviderProfile.encodeList(_providers),
        ),
      );
    } catch (error) {
      debugPrint('Failed to persist selected provider: $error');
    }
  }

  void setSelectedModel(String model) {
    _selectedModel = model;
    if (model == selectedProvider?.thinkingModel) {
      _enableThinking = true;
    }
    notifyListeners();
  }

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

  Future<void> startCharacterChat(Character character) async {
    try {
      final conv = await rust_api.createConversation();
      _currentConversationId = conv.id;
      _messages = [];
      _currentStreamingContent = '';
      _currentThinkingContent = '';
      _errorMessage = null;
      _currentCharacter = character;

      _conversationCharacterMap[conv.id] = character.id;
      await _saveConversationCharacterMap();

      final systemPrompt = character.buildSystemPrompt();
      await rust_api.addSystemMessage(
        conversationId: conv.id,
        content: systemPrompt,
      );

      if (character.greeting.isNotEmpty) {
        await rust_api.addAssistantMessage(
          conversationId: conv.id,
          content: character.greeting,
        );
      }

      await loadConversation(conv.id);
      await refreshConversationList();
    } catch (e) {
      debugPrint('Failed to start character chat: $e');
    }
  }

  Future<void> setCurrentCharacterLive2dModelPath(String modelPath) async {
    final character = _currentCharacter;
    if (character == null) return;
    final updated = character.copyWith(
      live2dModelPath: modelPath,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await CharacterStore.instance.save(updated);
    if (_currentCharacter?.id != updated.id) return;
    _currentCharacter = updated;
    notifyListeners();
  }

  Future<void> loadConversation(String id, {bool preserveError = false}) async {
    try {
      final conv = await rust_api.getConversation(id: id);
      if (conv != null) {
        _currentConversationId = conv.id;
        _messages = conv.messages;
        if (!preserveError) {
          _errorMessage = null;
        }
        _currentStreamingContent = '';
        _currentThinkingContent = '';
        _dialogueStyle = conv.dialogueStyle;

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

  Future<void> editAndResend(String messageId, String newContent) async {
    if (_currentConversationId == null || _isStreaming) return;
    if (newContent.trim().isEmpty) return;
    final conversationId = _currentConversationId!;
    try {
      await rust_api.rollbackToMessage(
        conversationId: conversationId,
        messageId: messageId,
      );
      await loadConversation(conversationId);
      await sendMessage(newContent);
    } catch (e) {
      debugPrint('Failed to edit and resend: $e');
      if (_isStreaming) {
        endStreaming();
      }
      await loadConversation(conversationId);
      _errorMessage = '编辑重发失败: $e';
      notifyListeners();
    }
  }

  Future<void> regenerateResponse(String assistantMessageId) async {
    if (_currentConversationId == null || _isStreaming) return;
    try {
      final msgIndex = _messages.indexWhere((m) => m.id == assistantMessageId);
      if (msgIndex < 0) return;

      await rust_api.rollbackToMessage(
        conversationId: _currentConversationId!,
        messageId: assistantMessageId,
      );

      await loadConversation(_currentConversationId!);

      final conversationId = _currentConversationId!;

      _cancelExistingSubscription();

      startStreaming();

      if (usesAndroidOfflineProvider) {
        await _generateOfflineAssistant(conversationId);
        return;
      }

      final stream = rust_api.regenerateResponse(
        conversationId: conversationId,
        providerId: _selectedProviderId,
        model: _selectedModel,
        enableThinking: _enableThinking,
      );

      _listenToChatStream(stream, conversationId);
    } catch (e) {
      debugPrint('Failed to regenerate response: $e');
      if (_isStreaming) endStreaming();
    }
  }

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

  void setEnableThinking(bool enabled) {
    _enableThinking =
        enabled &&
        (_providers.isEmpty || (selectedProvider?.supportsThinking ?? false));
    notifyListeners();
  }

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
    _generationWasCancelled = false;
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
  }

  void _replaceStreamingContent(String content) {
    _currentStreamingContent = content;
    _streamDirty = true;
  }

  void appendThinkingContent(String delta) {
    _currentThinkingContent += delta;
    _streamDirty = true;
  }

  void endStreaming() {
    _isStreaming = false;
    _streamThrottleTimer?.cancel();
    _streamThrottleTimer = null;
    if (_streamDirty) {
      _streamDirty = false;
    }
    notifyListeners();
  }

  void _listenToChatStream(
    Stream<ChatStreamEvent> stream,
    String conversationId,
  ) {
    _streamSubscription = stream.listen(
      (event) {
        if (_currentConversationId != conversationId) return;

        try {
          event.when(
            contentDelta: (delta) => appendStreamingContent(delta),
            thinkingDelta: (delta) => appendThinkingContent(delta),
            done: () {
              _doneEventReceived = true;
              final wasCancelled = _generationWasCancelled;
              final activeError = _errorMessage;
              endStreaming();
              if (_currentConversationId != conversationId) return;
              loadConversation(conversationId, preserveError: true).then((_) {
                if (activeError != null && _errorMessage == null) {
                  _errorMessage = activeError;
                }
                refreshConversationList();
                if (_errorMessage == null && !wasCancelled) {
                  _completedResponseRevision++;
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
              if (msg == '__GENERATION_CANCELLED__') {
                _generationWasCancelled = true;
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
        if (_currentConversationId != conversationId) return;
        if (_isStreaming) endStreaming();
        _errorMessage = e.toString();
        loadConversation(conversationId, preserveError: true).then((_) {
          notifyListeners();
        });
      },
      onDone: () {
        if (!_isStreaming || _doneEventReceived) return;

        final activeError = _errorMessage;
        _retryDoneCheck(conversationId, activeError, 0);
      },
    );
  }

  void _retryDoneCheck(
    String conversationId,
    String? activeError,
    int attempt,
  ) {
    const delays = [300, 700, 1000];

    if (attempt >= delays.length) {
      if (_doneEventReceived || !_isStreaming) return;
      if (_currentConversationId != conversationId) return;

      debugPrint(
        '[ChatState] Stream closed without Done after 2s grace (conv=$conversationId)',
      );
      endStreaming();
      loadConversation(conversationId, preserveError: true).then((_) {
        if (activeError != null && _errorMessage == null) {
          _errorMessage = activeError;
        }
        final hasAssistantResponse =
            _messages.isNotEmpty &&
            _messages.last.role == MessageRole.assistant;
        if (hasAssistantResponse) {
          refreshConversationList();
          if (_errorMessage == null) {
            _completedResponseRevision++;
            _checkAndTriggerMemorySummarize(conversationId);
          }
        } else {
          _errorMessage ??= 'AI 响应中断，请点击重试';
        }
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

  Future<void> sendMessage(String content) async {
    if (content.trim().isEmpty || _isStreaming) return;

    _cancelExistingSubscription();

    _errorMessage = null;
    _lastFailedContent = null;

    if (!await _ensureSelectedProviderReady()) return;

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
      if (usesAndroidOfflineProvider) {
        final saved = await rust_api.addUserMessage(
          conversationId: conversationId,
          content: content,
          model: _selectedModel,
        );
        if (!saved) throw StateError('无法保存用户消息');
        await _generateOfflineAssistant(conversationId);
        return;
      }

      final stream = rust_api.sendMessage(
        conversationId: conversationId,
        content: content,
        providerId: _selectedProviderId,
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

  Future<bool> _ensureSelectedProviderReady() async {
    final provider = selectedProvider;
    if (provider != null && !provider.isLocal && provider.isConfigured) {
      return true;
    }

    await OfflineLlmService.instance.initialize();
    if (OfflineLlmService.instance.modelReady) {
      ProviderProfile? offline;
      for (final candidate in _providers) {
        if (candidate.isLocal) {
          offline = candidate;
          break;
        }
      }
      if (offline != null) {
        _selectedProviderId = offline.id;
        _selectedModel = offline.chatModel;
        _enableThinking = false;
        await _persistSelectedProvider(offline);
        notifyListeners();
        return true;
      }
    }

    _errorMessage = provider?.isLocal == true
        ? '请先在“模型与接口”中安装 Qwen3-4B-Instruct-2507 QAIRT/NPU 模型'
        : '${provider?.name ?? '当前在线平台'}尚未配置 API Key；'
              '也未检测到已就绪的 Qwen3-4B-Instruct-2507 QAIRT/NPU 模型';
    notifyListeners();
    return false;
  }

  List<OfflineChatMessage> _buildOfflinePrompt() {
    const contentBudget = 5000;
    var remaining = contentBudget;
    final systemMessages = _messages
        .where((message) => message.role == MessageRole.system)
        .map(
          (message) =>
              OfflineChatMessage(role: 'system', content: message.content),
        )
        .toList(growable: false);

    final recent = <OfflineChatMessage>[];
    for (final message in _messages.reversed) {
      if (message.role == MessageRole.system ||
          message.content.trim().isEmpty) {
        continue;
      }
      if (remaining <= 0 && recent.isNotEmpty) break;
      final content = message.content.length <= remaining
          ? message.content
          : message.content.substring(message.content.length - remaining);
      recent.add(
        OfflineChatMessage(
          role: message.role == MessageRole.assistant ? 'assistant' : 'user',
          content: content,
        ),
      );
      remaining -= content.length;
    }

    return [...systemMessages, ...recent.reversed];
  }

  Future<void> _generateOfflineAssistant(String conversationId) async {
    try {
      final response = await OfflineLlmService.instance.generate(
        _buildOfflinePrompt(),
        onText: (text) {
          if (_currentConversationId == conversationId && _isStreaming) {
            _replaceStreamingContent(text);
          }
        },
      );
      final saved = await rust_api.addAssistantMessageWithModel(
        conversationId: conversationId,
        content: response,
        model: _selectedModel,
      );
      if (!saved) throw StateError('无法保存端侧 AI 回复');

      if (_currentConversationId == conversationId) {
        _replaceStreamingContent(response);
        endStreaming();
        await loadConversation(conversationId);
        _completedResponseRevision++;
        await refreshConversationList();
      }
    } catch (error) {
      if (error is OfflineGenerationCancelled) {
        if (_currentConversationId == conversationId) {
          _generationWasCancelled = true;
          endStreaming();
          await loadConversation(conversationId, preserveError: true);
        }
        return;
      }
      debugPrint('[ChatState] Offline generation failed: $error');
      if (_currentConversationId == conversationId) {
        endStreaming();
        await loadConversation(conversationId, preserveError: true);
        _errorMessage = '端侧 AI 生成失败: $error';
        notifyListeners();
      }
    }
  }

  void _checkAndTriggerMemorySummarize(String conversationId) async {
    try {
      final shouldSummarize = await rust_api.shouldSummarizeMemory(
        conversationId: conversationId,
      );
      if (shouldSummarize) {
        debugPrint('Triggering memory summarization for $conversationId');
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

  Future<void> retryLastMessage() async {
    if (_currentConversationId == null || _isStreaming) return;
    final conversationId = _currentConversationId!;

    _cancelExistingSubscription();

    _errorMessage = null;
    _lastFailedContent = null;
    startStreaming();

    try {
      if (usesAndroidOfflineProvider) {
        await _generateOfflineAssistant(conversationId);
        return;
      }

      final stream = rust_api.regenerateResponse(
        conversationId: conversationId,
        providerId: _selectedProviderId,
        model: _selectedModel,
        enableThinking: _enableThinking,
      );

      _listenToChatStream(stream, conversationId);
    } catch (e) {
      setError(e.toString());
    }
  }

  Future<void> stopGeneration() async {
    if (!_isStreaming) return;
    final conversationId = _currentConversationId;
    if (conversationId == null) return;

    _generationWasCancelled = true;
    try {
      if (usesAndroidOfflineProvider) {
        await OfflineLlmService.instance.stopGeneration();
      } else {
        await rust_api.cancelGeneration(conversationId: conversationId);
      }
    } catch (error) {
      debugPrint('[ChatState] Failed to stop generation: $error');
      _errorMessage = '停止生成失败: $error';
    } finally {
      if (_currentConversationId == conversationId && _isStreaming) {
        endStreaming();
      }
    }
  }

  @override
  void dispose() {
    _cancelExistingSubscription();
    _streamThrottleTimer?.cancel();
    _retryDoneTimer?.cancel();
    super.dispose();
  }

  @visibleForTesting
  void listenToChatStreamForTest(
    Stream<ChatStreamEvent> stream,
    String conversationId,
  ) {
    _currentConversationId = conversationId;
    _listenToChatStream(stream, conversationId);
  }

  @visibleForTesting
  void setCurrentConversationIdForTest(String? id) {
    _currentConversationId = id;
  }
}
