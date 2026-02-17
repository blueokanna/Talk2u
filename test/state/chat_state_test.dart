import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/state/chat_state.dart';

void main() {
  late ChatState state;

  setUp(() {
    state = ChatState();
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
}
