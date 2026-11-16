import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/services/moss_tts_service.dart';

class _Player extends Fake implements AudioPlayer {
  final completed = StreamController<void>.broadcast();
  final played = <String>[];
  Completer<void>? playGate;
  int stops = 0;
  @override
  Stream<void> get onPlayerComplete => completed.stream;
  @override
  Stream<Duration> get onDurationChanged => const Stream.empty();
  @override
  Stream<Duration> get onPositionChanged => const Stream.empty();
  @override
  Future<void> play(
    Source source, {
    double? volume,
    double? balance,
    AudioContext? ctx,
    Duration? position,
    PlayerMode? mode,
  }) async {
    played.add((source as DeviceFileSource).path);
    await playGate?.future;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    await completed.close();
  }
}

Future<void> _until(bool Function() predicate) async {
  for (var attempt = 0; attempt < 2000; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Asynchronous condition did not settle');
}

Future<void> _writeWav(String path) async {
  final bytes = Uint8List(44 + 960);
  final data = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  data.setUint32(4, bytes.length - 8, Endian.little);
  bytes.setRange(8, 12, 'WAVE'.codeUnits);
  bytes.setRange(12, 16, 'fmt '.codeUnits);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 24000, Endian.little);
  data.setUint32(28, 48000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, 'data'.codeUnits);
  data.setUint32(40, 960, Endian.little);
  await File(path).writeAsBytes(bytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/moss-lifecycle');
  late Directory directory;
  late _Player player;
  late MossTtsService service;
  late List<String> calls;
  Future<Object?> Function(MethodCall)? intercept;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('moss-lifecycle-');
    player = _Player();
    calls = [];
    intercept = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          final replacement = intercept;
          if (replacement != null) {
            final result = await replacement(call);
            if (result != null) return result;
          }
          switch (call.method) {
            case 'probe':
              return true;
            case 'providers':
              return ['QNN_HTP'];
            case 'modelInfo':
              return {'bytes': 100};
            case 'initialize':
              return {'initialized': true};
            case 'synthesize':
              final path = (call.arguments as Map)['outputPath'] as String;
              await _writeWav(path);
              return {'path': path, 'provider': 'QNN_HTP'};
            default:
              return null;
          }
        });
    service = MossTtsService.forTesting(
      player: player,
      channel: channel,
      directory: () async => directory,
    );
  });

  tearDown(() async {
    await service.stopSpeaking();
    service.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  test('startup only probes and empty speech never loads a model', () async {
    await service.speak('   ');
    expect(calls, isEmpty);
    await service.initialize();
    expect(calls, isNot(contains('initialize')));
    expect(service.hardwareRuntimeAvailable, isTrue);
    expect(service.runtimeInitialized, isFalse);
  });

  test('cancel during model initialization cannot start synthesis', () async {
    final loading = Completer<Object?>();
    intercept = (call) async =>
        call.method == 'initialize' ? loading.future : null;
    final speech = service.speak('一段会在加载期间取消的语音');
    await _until(() => calls.contains('initialize'));
    await service.stopSpeaking();
    loading.complete({'initialized': true});
    await speech;
    expect(calls, isNot(contains('synthesize')));
    expect(player.played, isEmpty);
  });

  test(
    'concurrent speech shares native load and only latest synthesizes',
    () async {
      final loading = Completer<Object?>();
      intercept = (call) async =>
          call.method == 'initialize' ? loading.future : null;
      final first = service.speak('第一段');
      await _until(() => calls.contains('initialize'));
      final second = service.speak('第二段');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      loading.complete({'initialized': true});
      await Future.wait([first, second]);
      expect(calls.where((value) => value == 'initialize'), hasLength(1));
      expect(calls.where((value) => value == 'synthesize'), hasLength(1));
      expect(player.played, hasLength(1));
    },
  );

  test(
    'cancel resolves utterance completion without waiting for native run',
    () async {
      final synthesis = Completer<Object?>();
      intercept = (call) async =>
          call.method == 'synthesize' ? synthesis.future : null;
      final speech = service.speakToCompletion('等待推理');
      await _until(() => calls.contains('synthesize'));
      await service.stopSpeaking();
      await speech;
      synthesis.completeError(PlatformException(code: 'moss_cancelled'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(service.speaking, isFalse);
      expect(service.generating, isFalse);
    },
  );

  test('old synthesis cleanup cannot remove current playback file', () async {
    final oldSynthesis = Completer<Object?>();
    String? oldPath;
    intercept = (call) async {
      if (call.method == 'synthesize' && oldPath == null) {
        oldPath = (call.arguments as Map)['outputPath'] as String;
        return oldSynthesis.future;
      }
      return null;
    };
    final first = service.speak('旧语音');
    await _until(() => oldPath != null);
    await service.speak('新语音');
    await first;
    final currentPath = player.played.single;
    await _writeWav(oldPath!);
    oldSynthesis.complete({'path': oldPath, 'provider': 'QNN_HTP'});
    await _until(() => !File(oldPath!).existsSync());
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(File(currentPath).existsSync(), isTrue);
    expect(service.speaking, isTrue);
  });

  test('stop waits for pending play then leaves no active speech', () async {
    player.playGate = Completer<void>();
    final speech = service.speakToCompletion('播放器还在打开文件');
    await _until(() => player.played.isNotEmpty);
    final stopping = service.stopSpeaking();
    player.playGate!.complete();
    await Future.wait([speech, stopping]);
    expect(service.speaking, isFalse);
    expect(service.playbackAmplitude, 0);
    expect(player.stops, 2); // Initial replacement stop plus explicit stop.
  });

  test('completion waits for this utterance playback event', () async {
    var done = false;
    final speech = service.speakToCompletion('完整播放').then((_) => done = true);
    await _until(() => service.speaking);
    expect(done, isFalse);
    player.completed.add(null);
    await speech;
    expect(done, isTrue);
  });
}
