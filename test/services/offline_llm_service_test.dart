import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/services/offline_llm_service.dart';

void main() {
  group('OfflineLlmService Qwen chat formatting', () {
    test('uses the Qwen2.5 template and opens an assistant turn', () {
      final prompt = OfflineLlmService.formatQwenChatPrompt(const [
        OfflineChatMessage(role: 'system', content: 'You are Talk2U.'),
        OfflineChatMessage(role: 'user', content: 'Hello'),
        OfflineChatMessage(role: 'assistant', content: 'Hi'),
        OfflineChatMessage(role: 'user', content: 'Continue'),
      ]);

      expect(
        prompt,
        '<|im_start|>system\nYou are Talk2U.<|im_end|>\n'
        '<|im_start|>user\nHello<|im_end|>\n'
        '<|im_start|>assistant\nHi<|im_end|>\n'
        '<|im_start|>user\nContinue<|im_end|>\n'
        '<|im_start|>assistant\n',
      );
    });

    test('normalizes unknown roles and skips empty messages', () {
      final prompt = OfflineLlmService.formatQwenChatPrompt(const [
        OfflineChatMessage(role: 'tool', content: '  result  '),
        OfflineChatMessage(role: 'user', content: '   '),
      ]);

      expect(
        prompt,
        '<|im_start|>user\nresult<|im_end|>\n'
        '<|im_start|>assistant\n',
      );
    });
  });
}
