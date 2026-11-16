import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/rust/api/data_models.dart';
import 'package:talk2u/src/state/chat_state.dart';

void main() {
  late ChatState state;

  setUp(() {
    state = ChatState();
  });

  tearDown(() {
    state.dispose();
  });

  Conversation conversation(String id) => Conversation(
    id: id,
    title: id,
    messages: const [],
    model: 'test',
    createdAt: 0,
    updatedAt: 0,
    dialogueStyle: DialogueStyle.mixed,
    turnCount: 0,
    memorySummaries: const [],
  );

  group('asynchronous turn ownership', () {
    test('late load cannot replace a newer conversation', () async {
      final oldRead = Completer<Conversation?>();
      state.dispose();
      state = ChatState(
        readConversation: (id) async =>
            id == 'old' ? oldRead.future : conversation(id),
      );
      final pending = state.loadConversation('old');
      expect(await state.loadConversation('new'), isTrue);
      oldRead.complete(conversation('old'));
      expect(await pending, isFalse);
      expect(state.currentConversationId, 'new');
    });

    test('late completed-turn read cannot clear the next stream', () async {
      final completedRead = Completer<Conversation?>();
      state.dispose();
      state = ChatState(readConversation: (_) => completedRead.future);
      final events = StreamController<ChatStreamEvent>();
      state.startStreaming();
      state.listenToChatStreamForTest(events.stream, 'same');
      events.add(const ChatStreamEvent.done());
      await Future<void>.delayed(Duration.zero);
      state.startStreaming();
      state.appendStreamingContent('next turn');
      completedRead.complete(conversation('same'));
      await Future<void>.delayed(Duration.zero);
      expect(state.isStreaming, isTrue);
      expect(state.currentStreamingContent, 'next turn');
      expect(state.completedResponseRevision, 0);
      await events.close();
    });

    test(
      'events after Done are ignored even while the saved turn loads',
      () async {
        final read = Completer<Conversation?>();
        state.dispose();
        state = ChatState(readConversation: (_) => read.future);
        final events = StreamController<ChatStreamEvent>();
        state.startStreaming();
        state.listenToChatStreamForTest(events.stream, 'same');
        events.add(const ChatStreamEvent.contentDelta('final'));
        events.add(const ChatStreamEvent.done());
        events.add(const ChatStreamEvent.contentDelta('late'));
        events.add(const ChatStreamEvent.error('late failure'));
        await Future<void>.delayed(Duration.zero);
        expect(state.currentStreamingContent, 'final');
        expect(state.errorMessage, isNull);
        read.complete(null);
        await events.close();
      },
    );

    test('disposed state rejects an in-flight conversation read', () async {
      final read = Completer<Conversation?>();
      final disposable = ChatState(readConversation: (_) => read.future);
      final pending = disposable.loadConversation('old');
      disposable.dispose();
      read.complete(conversation('old'));
      expect(await pending, isFalse);
    });
  });

  group('ChatState defaults', () {
    test('initial enableThinking is true', () {
      expect(state.enableThinking, true);
    });

    test('initial isStreaming is false', () {
      expect(state.isStreaming, false);
    });

    test('initial currentConversationId is null', () {
      expect(state.currentConversationId, isNull);
    });

    test('initial messages is empty', () {
      expect(state.messages, isEmpty);
    });

    test('initial streaming content is empty', () {
      expect(state.currentStreamingContent, '');
      expect(state.currentThinkingContent, '');
    });

    test('initial currentCharacter is null', () {
      expect(state.currentCharacter, isNull);
    });

    test('initial displayMessages is empty', () {
      expect(state.displayMessages, isEmpty);
    });
  });

  group('enableThinking', () {
    test('setEnableThinking updates value', () {
      state.setEnableThinking(false);
      expect(state.enableThinking, false);
      state.setEnableThinking(true);
      expect(state.enableThinking, true);
    });
  });

  group('streaming lifecycle', () {
    test('startStreaming sets isStreaming and resets content', () {
      state.appendStreamingContent('leftover');
      state.appendThinkingContent('leftover');
      state.startStreaming();

      expect(state.isStreaming, true);
      expect(state.currentStreamingContent, '');
      expect(state.currentThinkingContent, '');
    });

    test('appendStreamingContent accumulates deltas', () {
      state.startStreaming();
      state.appendStreamingContent('Hello');
      state.appendStreamingContent(' World');
      expect(state.currentStreamingContent, 'Hello World');
    });

    test('appendThinkingContent accumulates deltas', () {
      state.startStreaming();
      state.appendThinkingContent('Step 1');
      state.appendThinkingContent(' → Step 2');
      expect(state.currentThinkingContent, 'Step 1 → Step 2');
    });

    test('endStreaming sets isStreaming to false', () {
      state.startStreaming();
      state.endStreaming();
      expect(state.isStreaming, false);
    });
  });

  group('error handling', () {
    test('setError sets error message and stops streaming', () {
      state.startStreaming();
      state.setError('Something went wrong', failedContent: 'test message');
      expect(state.errorMessage, 'Something went wrong');
      expect(state.lastFailedContent, 'test message');
      expect(state.isStreaming, false);
    });

    test('clearError clears error state', () {
      state.setError('error', failedContent: 'content');
      state.clearError();
      expect(state.errorMessage, isNull);
      expect(state.lastFailedContent, isNull);
    });
  });

  group('notifyListeners', () {
    test('setEnableThinking notifies', () {
      var notified = false;
      state.addListener(() => notified = true);
      state.setEnableThinking(false);
      expect(notified, true);
    });

    test('startStreaming notifies', () {
      var notified = false;
      state.addListener(() => notified = true);
      state.startStreaming();
      expect(notified, true);
    });

    test('endStreaming notifies', () {
      var count = 0;
      state.addListener(() => count++);
      state.startStreaming();
      state.endStreaming();
      expect(count, 2);
    });
  });

  group('stream event handling', () {
    test('Done path sets _doneEventReceived and ends streaming', () async {
      final controller = StreamController<ChatStreamEvent>();

      state.startStreaming();
      state.listenToChatStreamForTest(controller.stream, 'conv-1');

      controller.add(const ChatStreamEvent.contentDelta('Hello'));
      controller.add(const ChatStreamEvent.done());
      await Future.delayed(const Duration(milliseconds: 50));

      expect(state.isStreaming, false);
      expect(state.currentStreamingContent, 'Hello');

      await controller.close();
    });

    test('onDone without Done event triggers grace window fallback', () async {
      final controller = StreamController<ChatStreamEvent>();

      state.startStreaming();
      state.listenToChatStreamForTest(controller.stream, 'conv-2');

      controller.add(const ChatStreamEvent.contentDelta('Partial'));
      await controller.close();
      await Future.delayed(const Duration(milliseconds: 2500));

      expect(state.isStreaming, false);
    });

    test(
      'stale conversation ID does not update error/streaming state',
      () async {
        final controller = StreamController<ChatStreamEvent>();

        state.startStreaming();
        state.listenToChatStreamForTest(controller.stream, 'conv-old');

        state.setCurrentConversationIdForTest('conv-new');

        controller.add(const ChatStreamEvent.error('old error'));
        await Future.delayed(const Duration(milliseconds: 50));

        expect(state.errorMessage, isNull);

        await controller.close();
        state.endStreaming();
      },
    );

    test('onError with stale conversation ID is ignored', () async {
      final controller = StreamController<ChatStreamEvent>();

      state.startStreaming();
      state.listenToChatStreamForTest(controller.stream, 'conv-old');

      state.setCurrentConversationIdForTest('conv-new');

      controller.addError('network failure');
      await Future.delayed(const Duration(milliseconds: 50));

      expect(state.errorMessage, isNull);
      expect(state.isStreaming, true);

      await controller.close();
      state.endStreaming();
    });

    test('error event sets _errorMessage and notifies', () async {
      final controller = StreamController<ChatStreamEvent>();
      var notified = false;

      state.startStreaming();
      state.listenToChatStreamForTest(controller.stream, 'conv-3');
      state.addListener(() => notified = true);

      controller.add(const ChatStreamEvent.error('API error'));
      await Future.delayed(const Duration(milliseconds: 50));

      expect(state.errorMessage, 'API error');
      expect(notified, true);

      await controller.close();
      state.endStreaming();
    });

    test('catch block in event handler sets _errorMessage', () async {
      final controller = StreamController<ChatStreamEvent>();

      state.startStreaming();
      state.listenToChatStreamForTest(controller.stream, 'conv-4');

      controller.add(const ChatStreamEvent.contentDelta('Hi'));
      controller.add(const ChatStreamEvent.error('server error'));
      await Future.delayed(const Duration(milliseconds: 50));

      expect(state.errorMessage, 'server error');
      expect(state.currentStreamingContent, 'Hi');

      await controller.close();
      state.endStreaming();
    });

    test(
      '__RETRY_RESET__ clears streaming content without setting error',
      () async {
        final controller = StreamController<ChatStreamEvent>();

        state.startStreaming();
        state.listenToChatStreamForTest(controller.stream, 'conv-5');

        controller.add(const ChatStreamEvent.contentDelta('old content'));
        await Future.delayed(const Duration(milliseconds: 50));
        expect(state.currentStreamingContent, 'old content');

        controller.add(const ChatStreamEvent.error('__RETRY_RESET__'));
        await Future.delayed(const Duration(milliseconds: 50));

        expect(state.currentStreamingContent, '');
        expect(state.currentThinkingContent, '');
        expect(state.errorMessage, isNull);

        await controller.close();
        state.endStreaming();
      },
    );

    test('cancel event does not turn partial text into an error', () async {
      final controller = StreamController<ChatStreamEvent>();

      state.startStreaming();
      state.listenToChatStreamForTest(controller.stream, 'conv-cancel');

      controller.add(const ChatStreamEvent.contentDelta('Partial'));
      controller.add(const ChatStreamEvent.error('__GENERATION_CANCELLED__'));
      controller.add(const ChatStreamEvent.done());
      await Future.delayed(const Duration(milliseconds: 50));

      expect(state.isStreaming, false);
      expect(state.currentStreamingContent, 'Partial');
      expect(state.errorMessage, isNull);

      await controller.close();
    });
  });
}
