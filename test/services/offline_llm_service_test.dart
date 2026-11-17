import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/services/offline_llm_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('passes structured chat messages to the native template API', () {
    const message = OfflineChatMessage(role: 'user', content: '你好');

    expect(message.toMap(), {'role': 'user', 'content': '你好'});
  });

  test('does not label a loaded accelerator as verified before generation', () {
    final service = OfflineLlmService.instance;
    final previous = service.runtimeCapabilities;
    addTearDown(() => service.runtimeCapabilities = previous);

    service.runtimeCapabilities = const {
      'activeBackend': 'geniex-qairt-npu',
      'activeBackendVerified': false,
    };
    expect(
      service.accelerationDescription,
      'Accelerator loaded; verified after the first completed reply',
    );
    expect(service.hardwareAccelerationVerified, isFalse);

    service.runtimeCapabilities = const {
      'activeBackend': 'geniex-qairt-npu',
      'activeBackendVerified': true,
    };
    expect(service.accelerationDescription, 'Qualcomm QNN HTP/NPU (verified)');
    expect(service.hardwareAccelerationVerified, isTrue);
  });

  test('treats the llama.cpp OpenCL backend as hardware acceleration', () {
    final service = OfflineLlmService.instance;
    final previous = service.runtimeCapabilities;
    addTearDown(() => service.runtimeCapabilities = previous);

    service.runtimeCapabilities = const {
      'activeBackend': 'geniex-llamacpp-gpu',
      'activeBackendVerified': true,
    };
    expect(service.hardwareAccelerationVerified, isTrue);
    expect(
      service.accelerationDescription,
      'Adreno GPU via llama.cpp OpenCL (verified)',
    );

    service.runtimeCapabilities = const {
      'activeBackend': 'geniex-llamacpp-cpu',
      'activeBackendVerified': true,
    };
    expect(service.hardwareAccelerationVerified, isFalse);
    expect(
      service.accelerationDescription,
      'CPU — no accelerator for this artifact',
    );
  });

  test('never labels an unexpected backend as hardware accelerated', () {
    final service = OfflineLlmService.instance;
    final previous = service.runtimeCapabilities;
    addTearDown(() => service.runtimeCapabilities = previous);

    service.runtimeCapabilities = const {
      'activeBackend': 'unexpected-cpu',
      'activeBackendVerified': true,
    };

    expect(service.hardwareAccelerationVerified, isFalse);
    expect(
      service.accelerationDescription,
      'GenieX QAIRT/NPU model is not installed',
    );
  });

  test('parses the accelerator report without inventing availability', () {
    final service = OfflineLlmService.instance;
    final previous = service.runtimeCapabilities;
    addTearDown(() => service.runtimeCapabilities = previous);

    service.runtimeCapabilities = const {
      'accelerators': [
        {
          'id': 'npu',
          'backendId': 'geniex-qairt-npu',
          'available': true,
          'detail': 'SM8850 HTP/v81',
          'usability': 'import a QAIRT bundle',
          'requires': 'qairt-bundle',
        },
        {
          'id': 'gpu',
          'backendId': 'geniex-llamacpp-gpu',
          'available': false,
          'detail': 'no OpenCL driver is exposed',
          'usability': 'no OpenCL driver is exposed',
          'requires': 'gguf',
        },
      ],
    };

    expect(service.accelerators, hasLength(2));
    expect(service.accelerator('npu')?.available, isTrue);
    expect(service.accelerator('gpu')?.available, isFalse);
    expect(service.accelerator('cpu'), isNull);
  });

  group('artifact import', () {
    const channel = MethodChannel('talk2u/llm_runtime');
    final service = OfflineLlmService.instance;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<MethodCall> calls;
    Future<Object?> Function(MethodCall)? intercept;

    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      calls = [];
      intercept = null;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        final handler = intercept;
        if (handler != null) return handler(call);
        return switch (call.method) {
          'capabilities' => {'modelReady': false, 'modelBytes': 0},
          'deleteModel' => null,
          _ => null,
        };
      });
      await service.deleteModel();
      service.initialized = false;
      await service.initialize();
      calls.clear();
    });

    tearDown(() async {
      intercept = null;
      await service.deleteModel();
      service.initialized = false;
      service.runtimeCapabilities = const {};
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    test('installs a QAIRT bundle and keeps the artifact identity', () async {
      intercept = (call) async {
        if (call.method == 'importQairtBundle') {
          return {
            'modelReady': true,
            'modelBytes': 2684354560,
            'artifact': {
              'kind': 'qairt-bundle',
              'runtime': 'qairt',
              'path':
                  '/data/user/0/com.blue.talk2u/no_backup/models/on-device-llm/qairt',
              'bytes': 2684354560,
              'declaredName': 'qwen3_4b_abliterated',
            },
            'activeBackend': null,
            'activeBackendVerified': false,
          };
        }
        return null;
      };

      await service.importArtifact(OfflineModelArtifact.qairtBundle);

      expect(service.modelReady, isTrue);
      expect(service.artifactKind, 'qairt-bundle');
      expect(service.artifactName, 'qwen3_4b_abliterated');
      expect(service.importing, isFalse);
      expect(calls.map((call) => call.method), contains('importQairtBundle'));
    });

    test('reports a cancelled import without raising the busy flag', () async {
      intercept = (call) async {
        if (call.method == 'importGguf') {
          throw PlatformException(
            code: 'qwen3_import_cancelled',
            message: 'No model file was selected',
          );
        }
        return null;
      };

      await expectLater(
        service.importArtifact(OfflineModelArtifact.gguf),
        throwsA(isA<OfflineLlmFailure>()),
      );
      expect(service.importing, isFalse);
      expect(service.lastErrorCode, 'qwen3_import_cancelled');
      expect(service.modelReady, isFalse);
    });

    test('imports the preset selected by the caller', () async {
      intercept = (call) async {
        if (call.method == 'importGguf') {
          return {
            'modelReady': true,
            'modelBytes': 1073741824,
            'artifact': {'kind': 'gguf', 'modelId': 'base'},
          };
        }
        return null;
      };

      await service.importArtifact(
        OfflineModelArtifact.gguf,
        preset: OfflineModelPreset.base,
      );

      final call = calls.firstWhere((call) => call.method == 'importGguf');
      expect((call.arguments as Map)['modelId'], 'base');
      expect(service.installedPreset?.id, 'base');
      expect(service.installedPreset?.hasHubBundle, isTrue);
    });

    test(
      'reads the GGUF quantization metadata from the native artifact',
      () async {
        intercept = (call) async {
          if (call.method == 'importGguf') {
            return {
              'modelReady': true,
              'modelBytes': 2684354560,
              'artifact': {
                'kind': 'gguf',
                'modelId': 'base',
                'quantization': 'Q4_0',
                'npuClean': true,
              },
            };
          }
          return null;
        };

        await service.importArtifact(
          OfflineModelArtifact.gguf,
          preset: OfflineModelPreset.base,
        );

        expect(service.artifactKind, 'gguf');
        expect(service.artifactQuantization, 'Q4_0');
        expect(service.artifactNpuClean, isTrue);
      },
    );

    test('ignores a second import while one is running', () async {
      final started = Completer<void>();
      final finish = Completer<Object?>();
      intercept = (call) async {
        if (call.method == 'importQairtBundle') {
          started.complete();
          return finish.future;
        }
        return null;
      };

      final first = service.importArtifact(OfflineModelArtifact.qairtBundle);
      await started.future;
      expect(service.importing, isTrue);
      // The second call is a no-op, so the guard cannot start a parallel copy.
      await service.importArtifact(OfflineModelArtifact.gguf);
      finish.complete({'modelReady': true, 'modelBytes': 1});
      await first;
      expect(
        calls.where(
          (call) =>
              call.method == 'importQairtBundle' || call.method == 'importGguf',
        ),
        hasLength(1),
      );
    });
  });

  group('generation cancellation races', () {
    const channel = MethodChannel('talk2u/llm_runtime');
    const readyState = {
      'modelReady': true,
      'activeBackend': 'geniex-qairt-npu',
      'activeBackendVerified': true,
    };
    const messages = [OfflineChatMessage(role: 'user', content: '你好')];
    final service = OfflineLlmService.instance;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<MethodCall> calls;
    Future<Object?> Function(MethodCall)? intercept;

    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      calls = [];
      intercept = null;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        final handler = intercept;
        if (handler != null) return handler(call);
        return switch (call.method) {
          'capabilities' || 'load' => readyState,
          'generate' => '下一轮回复',
          _ => null,
        };
      });
      await service.deleteModel();
      service.initialized = false;
      await service.initialize();
      calls.clear();
    });

    tearDown(() async {
      intercept = null;
      await service.deleteModel();
      service.initialized = false;
      service.runtimeCapabilities = const {};
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    test(
      'stop during loading prevents native generation and allows retry',
      () async {
        final loadStarted = Completer<void>();
        final loadResult = Completer<Object?>();
        final stopCalled = Completer<void>();
        intercept = (call) async {
          if (call.method == 'load') {
            loadStarted.complete();
            return loadResult.future;
          }
          if (call.method == 'stop') stopCalled.complete();
          return null;
        };
        final texts = <String>[];
        var generationSettled = false;
        final generation = service
            .generate(messages, onText: texts.add)
            .then<void>(
              (_) => fail('Cancelled generation must not succeed'),
              onError: (Object error) {
                expect(error, isA<OfflineGenerationCancelled>());
                generationSettled = true;
              },
            );
        await loadStarted.future;
        var stopSettled = false;
        final stopping = service.stopGeneration().then(
          (_) => stopSettled = true,
        );
        await stopCalled.future;
        await Future<void>.delayed(Duration.zero);
        expect(stopSettled, isFalse);
        expect(service.generating, isTrue);

        loadResult.complete(readyState);
        await stopping;
        expect(generationSettled, isTrue);
        expect(service.generating, isFalse);
        expect(service.loadingModel, isFalse);
        expect(service.lastError, isNull);
        expect(texts, isEmpty);
        expect(calls.where((call) => call.method == 'generate'), isEmpty);
        await generation;

        intercept = null;
        expect(await service.generate(messages), '下一轮回复');
      },
    );

    test('stop waits for native generation to settle before retry', () async {
      final generateStarted = Completer<void>();
      final generateResult = Completer<Object?>();
      final stopCalled = Completer<void>();
      intercept = (call) async {
        if (call.method == 'load' || call.method == 'capabilities') {
          return readyState;
        }
        if (call.method == 'generate') {
          generateStarted.complete();
          return generateResult.future;
        }
        if (call.method == 'stop') stopCalled.complete();
        return null;
      };
      final texts = <String>[];
      final generation = expectLater(
        service.generate(messages, onText: texts.add),
        throwsA(isA<OfflineGenerationCancelled>()),
      );
      await generateStarted.future;
      var stopSettled = false;
      final stopping = service.stopGeneration().then((_) => stopSettled = true);
      await stopCalled.future;
      await Future<void>.delayed(Duration.zero);
      expect(stopSettled, isFalse);
      expect(service.generating, isTrue);

      generateResult.complete('已取消的回复');
      await stopping;
      expect(service.generating, isFalse);
      expect(service.lastError, isNull);
      expect(texts, isEmpty);
      await generation;

      intercept = null;
      expect(await service.generate(messages), '下一轮回复');
    });

    test('stop during capabilities refresh suppresses final text', () async {
      final refreshStarted = Completer<void>();
      final refreshResult = Completer<Object?>();
      final stopCalled = Completer<void>();
      intercept = (call) async {
        if (call.method == 'load') return readyState;
        if (call.method == 'generate') return '已取消的回复';
        if (call.method == 'capabilities') {
          refreshStarted.complete();
          return refreshResult.future;
        }
        if (call.method == 'stop') stopCalled.complete();
        return null;
      };
      final texts = <String>[];
      final generation = expectLater(
        service.generate(messages, onText: texts.add),
        throwsA(isA<OfflineGenerationCancelled>()),
      );
      await refreshStarted.future;
      var stopSettled = false;
      final stopping = service.stopGeneration().then((_) => stopSettled = true);
      await stopCalled.future;
      await Future<void>.delayed(Duration.zero);
      expect(stopSettled, isFalse);

      refreshResult.complete(readyState);
      await stopping;
      expect(service.generating, isFalse);
      expect(service.lastError, isNull);
      expect(texts, isEmpty);
      await generation;

      intercept = null;
      expect(await service.generate(messages), '下一轮回复');
    });

    test('native cancellation error preserves the loaded runtime', () async {
      final generateStarted = Completer<void>();
      final generateResult = Completer<Object?>();
      final stopCalled = Completer<void>();
      intercept = (call) async {
        if (call.method == 'load') return readyState;
        if (call.method == 'generate') {
          generateStarted.complete();
          return generateResult.future;
        }
        if (call.method == 'stop') stopCalled.complete();
        return null;
      };
      final texts = <String>[];
      final generation = expectLater(
        service.generate(messages, onText: texts.add),
        throwsA(isA<OfflineGenerationCancelled>()),
      );
      await generateStarted.future;
      var stopSettled = false;
      final stopping = service.stopGeneration().then((_) => stopSettled = true);
      await stopCalled.future;
      await Future<void>.delayed(Duration.zero);
      expect(stopSettled, isFalse);

      generateResult.completeError(
        PlatformException(code: 'qwen3_generate_failed', message: 'Cancelled'),
      );
      await stopping;
      expect(service.generating, isFalse);
      expect(service.lastError, isNull);
      expect(texts, isEmpty);
      await generation;

      calls.clear();
      intercept = null;
      expect(await service.generate(messages), '下一轮回复');
      expect(calls.where((call) => call.method == 'load'), isEmpty);
    });

    test('failed native stop still waits for generation cleanup', () async {
      final generateStarted = Completer<void>();
      final generateResult = Completer<Object?>();
      final stopCalled = Completer<void>();
      intercept = (call) async {
        if (call.method == 'load') return readyState;
        if (call.method == 'generate') {
          generateStarted.complete();
          return generateResult.future;
        }
        if (call.method == 'stop') {
          stopCalled.complete();
          throw PlatformException(code: 'stop_failed');
        }
        return null;
      };
      final generation = expectLater(
        service.generate(messages),
        throwsA(isA<OfflineGenerationCancelled>()),
      );
      await generateStarted.future;
      var stopSettled = false;
      final stopping = expectLater(
        service.stopGeneration(),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'stop_failed'),
        ),
      ).then((_) => stopSettled = true);
      await stopCalled.future;
      await Future<void>.delayed(Duration.zero);
      expect(stopSettled, isFalse);

      generateResult.complete('已取消的回复');
      await stopping;
      expect(service.generating, isFalse);
      await generation;

      intercept = null;
      expect(await service.generate(messages), '下一轮回复');
    });
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

  group('preset catalogue', () {
    final service = OfflineLlmService.instance;

    tearDown(() => service.runtimeCapabilities = const {});

    test('falls back to both built-in Qwen3-4B-Instruct-2507 identities', () {
      service
        ..runtimeCapabilities = const {}
        ..installedPreset = null;
      expect(service.presets.map((preset) => preset.id), [
        'base',
        'abliterated',
      ]);
      expect(service.presets.first.displayName, 'Qwen3-4B-Instruct-2507');
      expect(service.displayName, 'Qwen3-4B-Instruct-2507');
      expect(service.presets.first.hasHubBundle, isTrue);
      expect(service.presets.last.hasHubBundle, isFalse);
    });

    test('uses the native preset report when the runtime answers', () {
      service.runtimeCapabilities = const {
        'presets': [
          {
            'id': 'abliterated',
            'displayName': 'Huihui-Qwen3-4B-Instruct-2507-abliterated',
            'family': 'Qwen3-4B-Instruct-2507',
            'huggingFaceRepo':
                'huihui-ai/Huihui-Qwen3-4B-Instruct-2507-abliterated',
            'baseModel': 'Qwen/Qwen3-4B-Instruct-2507',
            'license': 'Apache-2.0',
            'hubModel': null,
          },
          {
            'id': 'base',
            'displayName': 'Qwen3-4B-Instruct-2507',
            'family': 'Qwen3-4B-Instruct-2507',
            'huggingFaceRepo': 'Qwen/Qwen3-4B-Instruct-2507',
            'baseModel': 'Qwen/Qwen3-4B-Instruct-2507',
            'license': 'Apache-2.0',
            'hubModel': 'ai-hub-models/Qwen3-4B-Instruct-2507',
          },
        ],
      };

      expect(service.presets, hasLength(2));
      expect(service.defaultHubPreset.id, 'base');
      expect(service.presetById('abliterated')?.isUpstream, isFalse);
      expect(service.presetById('base')?.hubModel, isNotNull);
      expect(service.presetById('unknown'), isNull);
    });

    test('drops malformed native entries instead of inventing ids', () {
      service.runtimeCapabilities = const {
        'presets': [
          {'displayName': 'no id'},
          {'id': 'base', 'displayName': 'Qwen3-4B-Instruct-2507'},
          'not-a-map',
        ],
      };

      expect(service.presets.map((preset) => preset.id), ['base']);
    });

    test('surfaces the reasons the NPU candidate was rejected', () {
      service.runtimeCapabilities = const {
        'rejectedAccelerators': [
          'NPU: libggml-htp-v81.so is not packaged',
          ' ',
          'llama-npu: HTP backend is not registered',
        ],
      };

      expect(service.rejectedAccelerators, [
        'NPU: libggml-htp-v81.so is not packaged',
        'llama-npu: HTP backend is not registered',
      ]);
    });
  });
}
