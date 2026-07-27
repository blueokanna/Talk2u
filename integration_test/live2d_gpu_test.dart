import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:talk2u/src/services/moss_tts_service.dart';
import 'package:talk2u/src/widgets/live2d_avatar.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android renders Cubism model on a verified hardware backend', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Live2dAvatar(
            modelPath:
                'file:///android_asset/flutter_assets/model/mao/runtime/'
                'mao_pro.model3.json',
          ),
        ),
      ),
    );

    final diagnosticsButton = find.byTooltip('Live2D 运行诊断');
    for (var second = 0; second < 45; second++) {
      await tester.pump(const Duration(seconds: 1));
      if (diagnosticsButton.evaluate().isNotEmpty) break;
    }
    expect(
      diagnosticsButton,
      findsOneWidget,
      reason: 'Live2D did not reach ready state within 45 seconds',
    );

    await tester.tap(diagnosticsButton);
    for (var attempt = 0; attempt < 10; attempt++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.text('Live2D 运行诊断').evaluate().isNotEmpty) break;
    }
    expect(find.text('Live2D 运行诊断'), findsOneWidget);

    final values = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    debugPrint('Talk2U Live2D diagnostics: $values');

    expect(
      values.any((value) => value == 'webgl2' || value == 'webgl1'),
      isTrue,
    );
    expect(
      values.any((value) => value.toLowerCase().contains('swiftshader')),
      isFalse,
      reason: 'Live2D fell back to a software WebGL renderer',
    );
    expect(
      values.any((value) => value.toLowerCase().contains('adreno')),
      isTrue,
      reason: 'Hardware GPU name was not reported',
    );
    expect(
      values.any((value) => value.startsWith('通过 1.')),
      isTrue,
      reason: 'Vulkan native preflight did not pass',
    );
    expect(
      values.any((value) => value.startsWith('通过 ES ')),
      isTrue,
      reason: 'OpenGL ES native fallback preflight did not pass',
    );
  });

  testWidgets('SM8850 runtime reports the Qwen3 Genie backend contract', (
    tester,
  ) async {
    const channel = MethodChannel('talk2u/llm_runtime');
    final capabilities = await channel.invokeMapMethod<Object?, Object?>(
      'capabilities',
    );

    expect(capabilities, isNotNull);
    expect(capabilities!['schemaVersion'], 2);
    expect(capabilities['targetProfile'], 'sm8850-v81');
    expect(capabilities['modelId'], 'Qwen/Qwen3-4B-Instruct-2507');
    expect(capabilities['modelFormat'], 'genie-deployment');
    expect(capabilities['activeBackend'], isNull);
    expect(capabilities['activeBackendVerified'], isFalse);
    expect(capabilities['contextSize'], 8192);

    final device = Map<Object?, Object?>.from(capabilities['device']! as Map);
    expect(device['model'], 'PLK110');
    expect(device['socModel'], 'SM8850');
    expect(device['abis'], contains('arm64-v8a'));

    final backends = (capabilities['backends']! as List)
        .cast<Map<Object?, Object?>>();
    final qnn = backends.singleWhere((backend) => backend['id'] == 'qnn-htp');
    final cpu = backends.singleWhere((backend) => backend['id'] == 'cpu');
    expect(qnn['priority'], 0);
    expect(qnn['requiresValidatedContext'], isTrue);
    expect(cpu['priority'], 1);
    expect(cpu['composerModelSupported'], isTrue);
  });

  testWidgets('Android offline TTS emits a real PCM amplitude envelope', (
    tester,
  ) async {
    const methods = MethodChannel('talk2u/speech');
    const events = EventChannel('talk2u/speech_events');
    final capabilities = await methods.invokeMapMethod<Object?, Object?>(
      'capabilities',
    );
    expect(capabilities?['offlineTts'], isTrue);
    expect(capabilities?['audioAmplitude'], isTrue);

    var peakAmplitude = 0.0;
    final speechDone = Completer<void>();
    final subscription = events.receiveBroadcastStream().listen((raw) {
      if (raw is! Map) return;
      if (raw['type'] == 'amplitude' && raw['value'] is num) {
        final amplitude = (raw['value'] as num).toDouble();
        if (amplitude > peakAmplitude) peakAmplitude = amplitude;
      } else if (raw['type'] == 'speechDone' && !speechDone.isCompleted) {
        speechDone.complete();
      }
    }, onError: speechDone.completeError);

    try {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await methods.invokeMethod<void>('speak', {
        'text': '你好，这是一段用于验证真实语音唇动的离线测试。',
      });
      await speechDone.future.timeout(const Duration(seconds: 20));
      expect(
        peakAmplitude,
        greaterThan(0.01),
        reason: 'Android TTS did not expose non-silent PCM audio frames',
      );
    } finally {
      await methods.invokeMethod<void>('stopSpeaking');
      await subscription.cancel();
    }
  });

  testWidgets('SM8850 MOSS synthesizes and plays a verified WAV', (
    tester,
  ) async {
    final moss = MossTtsService.instance;
    await moss.initialize();
    expect(moss.runtimeReady, isTrue);
    if (!moss.ready) {
      debugPrint('Talk2U MOSS diagnostics: skipped because model is absent');
      return;
    }

    var sawPlayback = false;
    var peakAmplitude = 0.0;
    void observePlayback() {
      sawPlayback = sawPlayback || moss.speaking;
      if (moss.playbackAmplitude > peakAmplitude) {
        peakAmplitude = moss.playbackAmplitude;
      }
    }

    moss.addListener(observePlayback);
    try {
      await moss.speak('你好，这是高通端侧语音播放验证。');
      for (var attempt = 0; attempt < 240; attempt++) {
        await tester.pump(const Duration(milliseconds: 500));
        observePlayback();
        if (!moss.generating && !moss.speaking) break;
      }

      expect(moss.lastError, isNull);
      expect(moss.generating, isFalse, reason: 'MOSS synthesis timed out');
      expect(moss.speaking, isFalse, reason: 'MOSS playback timed out');
      expect(sawPlayback, isTrue);
      expect(peakAmplitude, greaterThan(0.01));
      debugPrint(
        'Talk2U MOSS diagnostics: provider=${moss.activeProvider}, '
        'acceleration=${moss.accelerationLabel}, peak=$peakAmplitude',
      );
      expect(moss.activeProvider, anyOf('NNAPI_ACCELERATOR', 'CPU'));
      if (moss.activeProvider == 'CPU') {
        expect(moss.accelerationLabel, contains('CPU/NEON 回退'));
      }
    } finally {
      moss.removeListener(observePlayback);
      await moss.stopSpeaking();
    }
  });
}
