import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/l10n/provider_names.dart';
import 'package:talk2u/src/state/chat_state.dart';
import 'package:talk2u/src/rust/api/data_models.dart';
import 'package:talk2u/src/widgets/chat_input.dart';
import 'package:talk2u/src/pages/conversation_list_page.dart';
import 'package:talk2u/src/pages/character_list_page.dart';
import 'package:talk2u/src/pages/settings_page.dart';
import 'package:talk2u/src/services/call_session.dart';
import 'package:talk2u/src/services/camera_observation_service.dart';
import 'package:talk2u/src/rendering/motion_policy.dart';
import 'package:talk2u/src/services/offline_speech_service.dart';
import 'package:talk2u/src/services/live2d_model_importer.dart';
import 'package:talk2u/src/services/normal_speech.dart';
import 'package:talk2u/src/settings/ui_preferences.dart';
import 'package:talk2u/src/theme/app_motion.dart';
import 'package:talk2u/src/theme/app_shapes.dart';
import 'package:talk2u/src/widgets/fluid_switcher.dart';
import 'package:talk2u/src/widgets/live2d_avatar.dart';
import 'package:talk2u/src/widgets/chat_execution_status.dart';
import 'package:talk2u/src/widgets/camera_observation_banner.dart';
import 'package:talk2u/src/widgets/chat_message_area.dart';
import 'package:talk2u/src/widgets/chat_error_banner.dart';
import 'package:talk2u/src/widgets/chat_options_sheet.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

/// First visible glyph of a name, or `?` when the profile has none. Imported
/// characters are not required to carry a name, and `.characters.first` on an
/// empty string throws, so every avatar goes through this helper.
String _characterInitial(String name) {
  final trimmed = name.trim();
  return trimmed.isEmpty ? '?' : trimmed.characters.first;
}

class _ChatPageState extends State<ChatPage> with TickerProviderStateMixin {
  final _scrollController = ScrollController();
  StreamSubscription<ChatStreamEvent>? _responseEventSubscription;
  late final NormalReplySpeech _normalSpeech = NormalReplySpeech(
    create: OfflineSpeechService.instance.beginStreamingSpeech,
    autoRead: () =>
        mounted &&
        (_uiPreferences?.autoReadReplies ?? true) &&
        OfflineSpeechService.instance.capabilities.offlineTts,
  );

  /// Preferences are provided by the app shell. Widget tests mount the chat
  /// page without that provider, so a missing preference must not crash TTS.
  UiPreferences? get _uiPreferences {
    try {
      return context.read<UiPreferences>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  // Unbounded on purpose: the Expressive spring overshoots slightly, and a
  // bounded controller would clip that overshoot and turn the spring into a
  // plateau. The build clamps the painted scale instead.
  late final AnimationController _fabController = AnimationController.unbounded(
    vsync: this,
  );
  bool _fabHiding = false;
  bool _showScrollToBottom = false;
  bool _showTranscript = false;
  bool _isImportingLive2d = false;
  String? _modelOverridePath;
  String? _modelOverrideCharacterId;
  ChatState? _chatState;
  int _handledResponseRevision = 0;
  CallSession? _callSession;
  CallPhase? _lastAvatarCallPhase;
  bool _lastStreamingState = false;
  bool _autoFollow = true;
  bool _autoScrollScheduled = false;
  final _avatarController = Live2dAvatarController();
  final _camera = CameraObservationService();
  final _cameraState = ValueNotifier(
    const CameraObservationState(status: 'idle'),
  );
  StreamSubscription<CameraObservationState>? _cameraSubscription;
  bool _routeVisible = true;
  ModalRoute<dynamic>? _route;
  Animation<double>? _routeSecondary;
  String? _observedConversationId;

  void _handleCameraState(CameraObservationState state) {
    if (!mounted) return;
    _cameraState.value = state;
    final face = state.primaryFace;
    if (state.isObserving && face != null) {
      _avatarController.lookAt(face.centerX * 2 - 1, face.centerY * 2 - 1);
    } else {
      _avatarController.clearGaze();
    }
  }

  Future<void> _toggleCameraObservation() async {
    final state = _camera.latest;
    if (state.isObserving || state.isStarting) {
      await _camera.stop();
      return;
    }
    final strings = AppLocalizations.of(context);
    final enabled = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.cameraObservationStart),
        content: Text(strings.cameraObservationDescription),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.cameraObservationEnable),
          ),
        ],
      ),
    );
    if (enabled != true || !mounted) return;
    await _camera.start();
  }

  @override
  void initState() {
    super.initState();
    _cameraSubscription = _camera.states.listen(_handleCameraState);
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatState>().initialize();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(_route, route)) {
      _routeSecondary?.removeListener(_handleRouteAnimation);
      _route = route;
      _routeSecondary = route?.secondaryAnimation;
      _routeSecondary?.addListener(_handleRouteAnimation);
    }
    final routeVisible =
        _route == null || _route!.isCurrent || _isCoveredByPopup;
    if (!routeVisible && _routeVisible) unawaited(_camera.stop());
    _routeVisible = routeVisible;
    final chatState = context.read<ChatState>();
    if (identical(_chatState, chatState)) return;
    _chatState?.removeListener(_handleChatStateChanged);
    _chatState = chatState;
    _observedConversationId = chatState.currentConversationId;
    _handledResponseRevision = chatState.completedResponseRevision;
    chatState.addListener(_handleChatStateChanged);
    _responseEventSubscription?.cancel();
    _responseEventSubscription = chatState.responseEvents.listen(
      _handleResponseEvent,
    );
    _callSession ??= CallSession(
      port: OfflineSpeechService.instance,
      onSend: chatState.sendMessage,
      onStopGeneration: chatState.stopGeneration,
    )..addListener(_handleCallPhaseChanged);
  }

  void _handleCallPhaseChanged() {
    final session = _callSession;
    if (session == null) return;
    if (_lastAvatarCallPhase != session.phase) {
      _lastAvatarCallPhase = session.phase;
      _avatarController.perform(switch (session.phase) {
        CallPhase.listening => 'listening',
        CallPhase.thinking => 'thinking',
        CallPhase.speaking => 'talking',
        CallPhase.idle || CallPhase.halted => 'calm',
      });
    }
    if (!mounted) return;
    setState(() {});
    final error = session.lastError;
    if (session.phase == CallPhase.halted && error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).continuousCallStopped(error),
          ),
        ),
      );
    }
  }

  void _handleResponseEvent(ChatStreamEvent event) {
    final session = _callSession;
    if (session != null && session.active) {
      event.when(
        contentDelta: (delta) {
          if (delta.isNotEmpty) session.onResponseDelta(delta);
        },
        thinkingDelta: (_) {},
        retryReset: () => unawaited(session.onResponseReset()),
        generationCancelled: () => unawaited(session.onResponseReset()),
        done: () => unawaited(
          session.onResponseStreamDone(
            _chatState?.currentStreamingContent ?? '',
          ),
        ),
        error: (_) => session.onResponseFailed(),
      );
      return;
    }
    event.when(
      contentDelta: _appendNormalSpeech,
      thinkingDelta: (_) {},
      retryReset: () => unawaited(_cancelNormalSpeech()),
      generationCancelled: () => unawaited(_cancelNormalSpeech()),
      done: () => unawaited(
        _finishNormalSpeech(_chatState?.currentStreamingContent ?? ''),
      ),
      error: (_) => unawaited(_cancelNormalSpeech()),
    );
  }

  /// Normal chat keeps the same sentence pipeline as call mode, but without a
  /// microphone lifecycle. Auto-read starts on the first delta; the speaker
  /// button can also start it manually from the partial text.
  void _appendNormalSpeech(String delta) => _normalSpeech.append(delta);

  Future<void> _finishNormalSpeech(String fullReply) async {
    try {
      await _normalSpeech.finish(fullReply);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).offlineTtsUnavailable('$error'),
          ),
        ),
      );
    }
  }

  Future<void> _cancelNormalSpeech() async {
    try {
      await _normalSpeech.cancel();
    } on Object catch (_) {
      // A cancelled reply has no audio left to preserve.
    }
  }

  void _handleChatStateChanged() {
    final chatState = _chatState;
    if (chatState == null) return;
    if (_observedConversationId != chatState.currentConversationId) {
      final previousId = _observedConversationId;
      _observedConversationId = chatState.currentConversationId;
      _handledResponseRevision = chatState.completedResponseRevision;
      // Creating the first conversation during a call is normal. Switching
      // an existing conversation must not carry its microphone turn forward.
      if (previousId != null) {
        unawaited(_cancelNormalSpeech());
        unawaited(_callSession?.stop());
        unawaited(_camera.stop());
      }
    }

    if (chatState.isStreaming != _lastStreamingState) {
      _lastStreamingState = chatState.isStreaming;
      if (chatState.isStreaming) {
        _avatarController.perform('thinking');
      } else if (!OfflineSpeechService.instance.speaking &&
          !OfflineSpeechService.instance.generating) {
        _avatarController.perform('calm');
      }
    }
    if (chatState.isStreaming && _autoFollow) {
      _scheduleAutoScroll();
    }
    final session = _callSession;
    if (session == null || !session.active) return;
    if (chatState.errorMessage != null &&
        !chatState.isStreaming &&
        (session.phase == CallPhase.thinking ||
            session.phase == CallPhase.speaking)) {
      session.onResponseFailed();
    }
    if (chatState.completedResponseRevision <= _handledResponseRevision) {
      return;
    }
    _handledResponseRevision = chatState.completedResponseRevision;
    for (final message in chatState.messages.reversed) {
      if (message.role == MessageRole.assistant &&
          message.content.trim().isNotEmpty) {
        unawaited(session.onResponseCompleted(message.content));
        return;
      }
    }
    session.onResponseFailed();
  }

  void _scheduleAutoScroll() {
    if (_autoScrollScheduled) return;
    _autoScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoScrollScheduled = false;
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final isNearBottom = _isUserNearBottom();
    _autoFollow = isNearBottom;
    if (!isNearBottom && !_showScrollToBottom) {
      _setFabVisible(true);
    } else if (isNearBottom && _showScrollToBottom) {
      _setFabVisible(false);
    }
  }

  /// Shows or hides the jump-to-bottom action with the Expressive spring.
  ///
  /// The hide path keeps the button mounted until the spring settles; removing
  /// it immediately would make the exit invisible.
  void _setFabVisible(bool visible) {
    final animate = AppMotionPolicy.of(context).animate;
    if (visible) {
      _fabHiding = false;
      setState(() => _showScrollToBottom = true);
      if (animate) {
        AppMotion.springTo(_fabController, 1);
      } else {
        _fabController.value = 1;
      }
      return;
    }
    if (_fabHiding) return;
    _fabHiding = true;
    if (!animate) {
      _fabController.value = 0;
      _fabHiding = false;
      setState(() => _showScrollToBottom = false);
      return;
    }
    AppMotion.springTo(_fabController, 0).whenComplete(() {
      _fabHiding = false;
      if (mounted) setState(() => _showScrollToBottom = false);
    });
  }

  bool _isUserNearBottom() {
    if (!_scrollController.hasClients) return true;
    final pos = _scrollController.position;
    return pos.maxScrollExtent - pos.pixels < 150;
  }

  @override
  void dispose() {
    _routeSecondary?.removeListener(_handleRouteAnimation);
    unawaited(_responseEventSubscription?.cancel());
    _responseEventSubscription = null;
    unawaited(_cancelNormalSpeech());
    unawaited(_cameraSubscription?.cancel());
    unawaited(_camera.dispose());
    _cameraState.dispose();
    final session = _callSession;
    _callSession = null;
    if (session != null) {
      session.removeListener(_handleCallPhaseChanged);
      unawaited(session.stop());
      session.dispose();
    }
    _chatState?.removeListener(_handleChatStateChanged);
    _scrollController.dispose();
    _fabController.dispose();
    _avatarController.dispose();
    super.dispose();
  }

  void _scrollToBottom({bool animate = true}) {
    _autoFollow = true;
    if (!_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      if (animate) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: AppMotion.swap,
          curve: AppMotion.emphasizedDecelerate,
        );
      } else {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _handleSend(String content) {
    unawaited(_cancelNormalSpeech());
    unawaited(OfflineSpeechService.instance.stopSpeaking());
    context.read<ChatState>().sendMessage(content);
    _autoFollow = true;
    _scrollToBottom();
  }

  void _handleRetry() {
    unawaited(_cancelNormalSpeech());
    unawaited(OfflineSpeechService.instance.stopSpeaking());
    context.read<ChatState>().retryLastMessage();
    _autoFollow = true;
    _scrollToBottom();
  }

  Future<void> _toggleListening() async {
    final strings = AppLocalizations.of(context);
    final speech = OfflineSpeechService.instance;
    final session = _callSession;
    if (session != null && session.active) {
      await session.toggleMicrophone();
      return;
    }
    try {
      if (speech.listening) {
        await speech.stopListening();
        _avatarController.perform('calm');
        return;
      }
      if (speech.speaking || speech.generating) await speech.stopSpeaking();
      await speech.startListening();
      _avatarController.perform('listening');
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.offlineSttUnavailable('$error'))),
      );
    }
  }

  Future<void> _toggleCall() async {
    final strings = AppLocalizations.of(context);
    final session = _callSession;
    if (session == null) return;
    if (session.active) {
      await session.stop();
      return;
    }
    final speech = OfflineSpeechService.instance;
    try {
      await speech.initialize();
      if (!speech.capabilities.offlineStt || !speech.capabilities.offlineTts) {
        throw StateError(strings.continuousCallRequiresSpeech);
      }
      await _cancelNormalSpeech();
      if (speech.speaking || speech.generating) await speech.stopSpeaking();
      if (speech.listening) await speech.stopListening();
      await _chatState?.stopGeneration();
      await session.start();
      if (session.phase == CallPhase.halted) {
        throw StateError(session.lastError ?? 'call session failed');
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.continuousCallStartFailed('$error'))),
      );
    }
  }

  Future<void> _interruptAssistant() async {
    final session = _callSession;
    if (session != null && session.active) {
      await session.interrupt();
      return;
    }
    final speech = OfflineSpeechService.instance;
    await _cancelNormalSpeech();
    if (speech.speaking || speech.generating) await speech.stopSpeaking();
    if (_chatState?.isStreaming == true) await _chatState!.stopGeneration();
    _avatarController.perform('calm');
  }

  void _handleAvatarTap() {
    final speech = OfflineSpeechService.instance;
    if (speech.speaking ||
        speech.generating ||
        _chatState?.isStreaming == true) {
      unawaited(_interruptAssistant());
      return;
    }
    _avatarController.perform('listening');
    Future<void>.delayed(const Duration(milliseconds: 1200), () {
      if (!mounted || speech.speaking || speech.listening) return;
      _avatarController.perform('calm');
    });
  }

  Future<void> _speakLastReply(ChatState state) async {
    final speech = OfflineSpeechService.instance;
    if (_normalSpeech.active || speech.speaking || speech.generating) {
      await _cancelNormalSpeech();
      if (speech.speaking || speech.generating) await speech.stopSpeaking();
      return;
    }
    if (state.isStreaming) {
      final strings = AppLocalizations.of(context);
      try {
        if (!speech.capabilities.offlineTts) await speech.initialize();
        if (!speech.capabilities.offlineTts) {
          throw StateError(strings.noOfflineTtsVoice);
        }
        _normalSpeech.startManual(state.currentStreamingContent);
      } on Object catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.offlineTtsUnavailable('$error'))),
        );
      }
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
    final strings = AppLocalizations.of(context);
    try {
      final speech = OfflineSpeechService.instance;
      if (!speech.capabilities.offlineTts) await speech.initialize();
      if (!speech.capabilities.offlineTts) {
        throw StateError(strings.noOfflineTtsVoice);
      }
      if (speech.speaking || speech.generating) await speech.stopSpeaking();
      await speech.speak(reply);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.offlineTtsUnavailable('$error'))),
      );
    }
  }

  Future<void> _importLive2dModel() async {
    final strings = AppLocalizations.of(context);
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    final archivePath = file?.path;
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
        SnackBar(
          content: Text(strings.live2dModelsImported(modelPaths.length)),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.live2dModelImportFailed('$error'))),
      );
    } finally {
      if (mounted) setState(() => _isImportingLive2d = false);
    }
  }

  Future<String?> _selectImportedModel(List<String> modelPaths) async {
    if (modelPaths.length == 1) return modelPaths.first;
    final strings = AppLocalizations.of(context);
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.chooseLive2dModel),
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
            child: Text(strings.cancel),
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
            unawaited(OfflineSpeechService.instance.stopSpeaking());
            context.read<ChatState>().createNewConversation();
          },
          onSelectCharacter: (character) {
            Navigator.pop(context);
            unawaited(OfflineSpeechService.instance.stopSpeaking());
            context.read<ChatState>().startCharacterChat(character);
          },
        ),
      ),
    );
  }

  void _showChatOptions() {
    final chatState = context.read<ChatState>();
    unawaited(
      showChatOptionsSheet(
        context,
        chatState: chatState,
        onRestartStory: _confirmRestartStory,
        preferences: _uiPreferences,
      ),
    );
  }

  void _confirmRestartStory() {
    final strings = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.restartStory),
        content: Text(strings.restartStoryConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.read<ChatState>().restartStory();
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(strings.restart),
          ),
        ],
      ),
    );
  }

  void _handleRouteAnimation() {
    if (!mounted) return;
    final visible = _route == null || _route!.isCurrent || _isCoveredByPopup;
    if (visible == _routeVisible) return;
    if (!visible) unawaited(_camera.stop());
    setState(() => _routeVisible = visible);
  }

  /// A dialog or bottom sheet does not animate the page below it. Keeping the
  /// Live2D view mounted under a popup is what lets the diagnostics dialog show
  /// a live frame counter; a full page route animates `secondaryAnimation` and
  /// is treated as a real cover.
  bool get _isCoveredByPopup => _routeSecondary?.value == 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = AppLocalizations.of(context);

    return Scaffold(
      // The Live2D platform view is opaque, so the chat route has no aurora
      // behind it. An explicit surface keeps the app bar, the status bar and the
      // area revealed during a route transition from falling through to the
      // window background.
      backgroundColor: theme.colorScheme.surface,
      resizeToAvoidBottomInset: false,
      onDrawerChanged: (isOpened) {
        if (isOpened) FocusManager.instance.primaryFocus?.unfocus();
      },
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
                        _characterInitial(state.currentCharacter!.name),
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
        actions: [
          Consumer<ChatState>(
            builder: (context, state, _) => AnimatedBuilder(
              animation: OfflineSpeechService.instance,
              builder: (context, _) {
                final speech = OfflineSpeechService.instance;
                return IconButton(
                  tooltip: speech.capabilities.offlineTts
                      ? (speech.speaking || speech.generating
                            ? strings.stopReading
                            : strings.readLastReply)
                      : strings.noOfflineTtsPack,
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
                    '${state.selectedProvider == null ? strings.notConfigured : providerDisplayName(state.selectedProvider!, strings)} · ${state.selectedModel}',
                onPressed: () {
                  state.setEnableThinking(!state.enableThinking);
                },
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.person_rounded),
            tooltip: strings.characterList,
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
                        unawaited(OfflineSpeechService.instance.stopSpeaking());
                        chatState.createNewConversation();
                      },
                      onSelectConversation: (id) {
                        Navigator.pop(context);
                        unawaited(OfflineSpeechService.instance.stopSpeaking());
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
                    title: Text(strings.settings),
                    subtitle: Text(strings.settingsSubtitle),
                    onTap: () async {
                      Navigator.pop(context);
                      FocusManager.instance.primaryFocus?.unfocus();
                      await Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SettingsPage()),
                      );
                      if (mounted) await chatState.reloadProviderSettings();
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
          final session = _callSession;
          final callActive = session?.active ?? false;
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
          final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
          return Stack(
            fit: StackFit.expand,
            children: [
              TickerMode(
                enabled: _routeVisible,
                child: Offstage(
                  // A pushed route must not keep painting the Live2D platform
                  // view through a translucent page. Offstage stops the platform
                  // view from being painted as soon as the chat route stops being
                  // current, so the settings transition shows the aurora and not
                  // a frozen avatar under the new page.
                  offstage: !_routeVisible,
                  child: RepaintBoundary(
                    child: Live2dAvatar(
                      key: ValueKey(modelPath),
                      modelPath: modelPath,
                      controller: _avatarController,
                      onTap: _handleAvatarTap,
                    ),
                  ),
                ),
              ),
              AnimatedPadding(
                duration: AppMotion.of(context, AppMotion.swap),
                curve: AppMotion.emphasizedDecelerate,
                padding: EdgeInsets.only(bottom: keyboardInset),
                child: Column(
                  children: [
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Positioned(
                            left: 12,
                            top: 12,
                            child: SafeArea(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton.filledTonal(
                                    tooltip: _showTranscript
                                        ? strings.hideConversation
                                        : strings.showConversation,
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
                                    tooltip: strings.importLive2dModel,
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
                                        : const Icon(
                                            Icons.folder_open_outlined,
                                          ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton.filled(
                                    tooltip: callActive
                                        ? strings.endContinuousCall
                                        : strings.startContinuousCall,
                                    onPressed: _toggleCall,
                                    icon: Icon(
                                      callActive
                                          ? Icons.call_end_outlined
                                          : Icons.call_outlined,
                                    ),
                                  ),
                                  if (Theme.of(context).platform ==
                                      TargetPlatform.android) ...[
                                    const SizedBox(width: 8),
                                    ValueListenableBuilder<
                                      CameraObservationState
                                    >(
                                      valueListenable: _cameraState,
                                      builder: (context, state, _) =>
                                          IconButton.filledTonal(
                                            tooltip:
                                                state.isObserving ||
                                                    state.isStarting
                                                ? strings.cameraObservationStop
                                                : strings
                                                      .cameraObservationStart,
                                            onPressed: _toggleCameraObservation,
                                            icon: Icon(
                                              state.isObserving ||
                                                      state.isStarting
                                                  ? Icons.videocam_off_outlined
                                                  : Icons.videocam_outlined,
                                            ),
                                          ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          FluidSwitcher(
                            axis: Axis.vertical,
                            child: !_showTranscript
                                ? const SizedBox.shrink(key: ValueKey('hidden'))
                                : Align(
                                    key: const ValueKey('transcript'),
                                    alignment: Alignment.bottomCenter,
                                    child: LayoutBuilder(
                                      builder: (context, constraints) {
                                        final factor = keyboardVisible
                                            ? 0.46
                                            : 0.58;
                                        final minimum = keyboardVisible
                                            ? 104.0
                                            : 180.0;
                                        final scaledHeight =
                                            constraints.maxHeight * factor;
                                        final targetHeight =
                                            scaledHeight < minimum
                                            ? minimum
                                            : scaledHeight;
                                        final panelHeight = targetHeight
                                            .clamp(0.0, constraints.maxHeight)
                                            .toDouble();
                                        return SizedBox(
                                          width: double.infinity,
                                          height: panelHeight,
                                          child: _buildTranscriptPanel(
                                            chatState,
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                          ),
                          if (_showScrollToBottom && _showTranscript)
                            Positioned(
                              right: 16,
                              bottom: 12,
                              child: AnimatedBuilder(
                                animation: _fabController,
                                child: FloatingActionButton.small(
                                  onPressed: () => _scrollToBottom(),
                                  child: const Icon(Icons.keyboard_arrow_down),
                                ),
                                builder: (context, child) => Transform.scale(
                                  scale: _fabController.value.clamp(0.0, 1.06),
                                  child: child,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    ValueListenableBuilder<CameraObservationState>(
                      valueListenable: _cameraState,
                      builder: (context, state, _) => FluidSwitcher(
                        axis: Axis.vertical,
                        child: CameraObservationBanner(
                          key: ValueKey(
                            'camera-${state.status}-${state.faceDetected}',
                          ),
                          state: state,
                          onClose: () => unawaited(_camera.stop()),
                        ),
                      ),
                    ),
                    ChatExecutionStatus(
                      chatState: chatState,
                      session: _callSession,
                    ),
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
                            unawaited(
                              OfflineSpeechService.instance.stopSpeaking(),
                            );
                            unawaited(chatState.stopGeneration());
                          },
                          onVoiceInput: _toggleListening,
                          isListening: speech.listening,
                          voiceEnabled: speech.capabilities.offlineStt,
                          allowVoiceDuringStreaming: callActive,
                          dictatedText: callActive ? '' : speech.recognizedText,
                          maxLines: keyboardVisible ? 3 : 5,
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTranscriptPanel(ChatState chatState) {
    final theme = Theme.of(context);
    final strings = AppLocalizations.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      shape: AppShapes.sheet,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          SizedBox(
            height: 48,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    strings.conversation,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: strings.hideConversation,
                  onPressed: () => setState(() => _showTranscript = false),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ChatMessageArea(
              chatState: chatState,
              scrollController: _scrollController,
              onChooseCharacter: _openCharacterList,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(ChatState chatState) => ChatErrorBanner(
    message: chatState.errorMessage ?? '',
    canRetry: chatState.currentConversationId != null,
    onRetry: _handleRetry,
    onDismiss: chatState.clearError,
  );
}
