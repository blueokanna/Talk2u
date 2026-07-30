import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/services/offline_llm_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('passes structured chat messages to the native template API', () {
    const message = OfflineChatMessage(role: 'user', content: '你好');

    expect(message.toMap(), {'role': 'user', 'content': '你好'});
  });

  test(
    'does not label a loaded QAIRT backend as verified before generation',
    () {
      final service = OfflineLlmService.instance;
      final previous = service.runtimeCapabilities;
      addTearDown(() => service.runtimeCapabilities = previous);

      service.runtimeCapabilities = const {
        'activeBackend': 'geniex-qairt-npu',
        'activeBackendVerified': false,
      };
      expect(service.accelerationDescription, contains('等待首轮执行验证'));

      service.runtimeCapabilities = const {
        'activeBackend': 'geniex-qairt-npu',
        'activeBackendVerified': true,
      };
      expect(service.accelerationDescription, 'Qualcomm QNN HTP/NPU（已验证）');
    },
  );

  test('never labels an unexpected backend as hardware accelerated', () {
    final service = OfflineLlmService.instance;
    final previous = service.runtimeCapabilities;
    addTearDown(() => service.runtimeCapabilities = previous);

    service.runtimeCapabilities = const {
      'activeBackend': 'unexpected-cpu',
      'activeBackendVerified': true,
    };

    expect(service.hardwareAccelerationVerified, isFalse);
    expect(service.accelerationDescription, 'GenieX QAIRT/NPU 模型尚未安装');
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
