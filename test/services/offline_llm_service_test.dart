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
      expect(
        service.accelerationDescription,
        contains('awaiting first-run verification'),
      );

      service.runtimeCapabilities = const {
        'activeBackend': 'geniex-qairt-npu',
        'activeBackendVerified': true,
      };
      expect(
        service.accelerationDescription,
        'Qualcomm QNN HTP/NPU (verified)',
      );
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
    expect(
      service.accelerationDescription,
      'GenieX QAIRT/NPU model is not installed',
    );
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
}
