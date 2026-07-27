import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/services/offline_llm_service.dart';

void main() {
  group('OfflineLlmService Qwen chat formatting', () {
    test('uses the Qwen3 chat template and opens an assistant turn', () {
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

  test('does not label a loaded QNN backend as verified before generation', () {
    final service = OfflineLlmService.instance;
    final previous = service.runtimeCapabilities;
    addTearDown(() => service.runtimeCapabilities = previous);

    service.runtimeCapabilities = const {
      'activeBackend': 'qnn-htp',
      'activeBackendVerified': false,
    };
    expect(service.accelerationDescription, contains('等待首轮执行验证'));

    service.runtimeCapabilities = const {
      'activeBackend': 'qnn-htp',
      'activeBackendVerified': true,
    };
    expect(service.accelerationDescription, 'Qualcomm QNN HTP/NPU');
  });

  test('reports CPU fallback as unavailable hardware acceleration', () {
    final service = OfflineLlmService.instance;
    final previous = service.runtimeCapabilities;
    addTearDown(() => service.runtimeCapabilities = previous);

    service.runtimeCapabilities = const {
      'activeBackend': 'cpu',
      'activeBackendVerified': true,
    };

    expect(service.usingCpuFallback, isTrue);
    expect(service.hardwareAccelerationVerified, isFalse);
    expect(service.accelerationDescription, contains('CPU'));
    expect(service.accelerationDescription, contains('部署包不含 HTP 工件'));
  });

  test('reports an attempted HTP backend failure separately', () {
    final service = OfflineLlmService.instance;
    final previous = service.runtimeCapabilities;
    addTearDown(() => service.runtimeCapabilities = previous);

    service.runtimeCapabilities = const {
      'activeBackend': 'cpu',
      'activeBackendVerified': true,
      'fallbackFailures': ['qnn-htp: context rejected'],
    };

    expect(service.accelerationDescription, contains('QNN HTP 加载失败'));
  });

  test('offline failures display a useful message without platform nulls', () {
    const failure = OfflineLlmFailure(
      'qwen3_generate_failed',
      'Qwen3 端侧生成失败：会话已失效',
      {'retryable': true},
    );

    expect(failure.toString(), 'Qwen3 端侧生成失败：会话已失效');
    expect(failure.toString(), isNot(contains('null')));
  });
}
