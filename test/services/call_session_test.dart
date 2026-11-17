import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/services/call_session.dart';

class _FakeStreamingSpeech implements StreamingReplySpeech {
  _FakeStreamingSpeech(this.port);

  final _FakePort port;

  @override
  void append(String text) => port.streamed.add(text);

  @override
  Future<void> finish(String fullReply) async {
    port.streamFinishes++;
    port.finishedReply = fullReply;
    port.speaking = false;
  }

  @override
  Future<void> cancel() async {
    port.streamCancels++;
    port.speaking = false;
  }
}

class _FakePort implements CallSpeechPort, StreamingCallSpeechPort {
  _FakePort({this.echoCancellationVerified = false});

  @override
  bool echoCancellationVerified;
  bool enableAecOnStart = false;
  Completer<void>? initialization;
  Completer<void>? captureStart;
  Completer<void>? captureStop;
  int captureStarts = 0;
  int speakingStops = 0;

  final transcriptController = StreamController<String>.broadcast();
  final energyController = StreamController<double>.broadcast();
  final spoken = <String>[];
  final streamed = <String>[];
  int streamFinishes = 0;
  int streamCancels = 0;
  String? finishedReply;
  Completer<void>? playback;

  @override
  bool listening = false;

  @override
  bool speaking = false;

  @override
  bool generating = false;

  @override
  double amplitude = 0;

  @override
  String get captureSource =>
      echoCancellationVerified ? 'VOICE_COMMUNICATION' : 'record';

  @override
  Stream<String> get transcripts => transcriptController.stream;

  @override
  Stream<double> get frameEnergies => energyController.stream;

  @override
  Future<void> initialize() async {
    await initialization?.future;
  }

  @override
  Future<void> startListening() async {
    captureStarts++;
    await captureStart?.future;
    if (enableAecOnStart) echoCancellationVerified = true;
    listening = true;
  }

  @override
  Future<void> stopListening() async {
    await captureStop?.future;
    listening = false;
  }

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    speaking = true;
    amplitude = 1;
    playback = Completer<void>();
    await playback!.future;
    speaking = false;
    amplitude = 0;
  }

  @override
  Future<void> speakToCompletion(String text) async {
    await speak(text);
    await playback!.future;
  }

  @override
  Future<void> stopSpeaking() async {
    speakingStops++;
    final active = playback;
    speaking = false;
    amplitude = 0;
    if (active != null && !active.isCompleted) active.complete();
  }

  @override
  StreamingReplySpeech beginStreamingSpeech() {
    speaking = true;
    return _FakeStreamingSpeech(this);
  }

  @override
  bool isSelfEcho(String transcript) => false;

  Future<void> close() async {
    await transcriptController.close();
    await energyController.close();
  }
}

void main() {
  late _FakePort port;
  late CallSession session;
  final sent = <String>[];
  var stopCalls = 0;

  setUp(() {
    sent.clear();
    stopCalls = 0;
  });

  CallSession build({required bool withAec}) {
    port = _FakePort(echoCancellationVerified: withAec);
    session = CallSession(
      port: port,
      onSend: (text) async => sent.add(text),
      onStopGeneration: () async => stopCalls++,
      settleDelay: Duration.zero,
    );
    return session;
  }

  tearDown(() async {
    session.dispose();
    await port.close();
  });

  test('stop during initialization cannot resurrect the call', () async {
    build(withAec: false);
    port.initialization = Completer<void>();
    final starting = session.start();
    final stopping = session.stop();
    port.initialization!.complete();
    await Future.wait([starting, stopping]);
    expect(session.phase, CallPhase.idle);
    expect(port.captureStarts, 0);
    expect(port.listening, isFalse);
    expect(stopCalls, 1);
  });

  test('concurrent starts open capture once', () async {
    build(withAec: false);
    port.initialization = Completer<void>();
    final first = session.start();
    final second = session.start();
    port.initialization!.complete();
    await Future.wait([first, second]);
    expect(port.captureStarts, 1);
  });

  test('stop while microphone opens closes late capture', () async {
    build(withAec: false);
    port.captureStart = Completer<void>();
    final starting = session.start();
    await Future<void>.delayed(Duration.zero);
    final stopping = session.stop();
    port.captureStart!.complete();
    await Future.wait([starting, stopping]);
    expect(session.phase, CallPhase.idle);
    expect(port.listening, isFalse);
  });

  test('AEC granted at capture startup enables interruption', () async {
    build(withAec: false);
    port.enableAecOnStart = true;
    await session.start();
    final speaking = session.onResponseCompleted('正在播放的一段内容');
    await Future<void>.delayed(Duration.zero);
    for (var i = 0; i < 20; i++) {
      port.energyController.add(0.45);
    }
    await Future<void>.delayed(Duration.zero);
    await speaking;
    expect(session.bargeInCount, 1);
    expect(port.speakingStops, 1);
  });

  test('full duplex accepts another transcript after playback', () async {
    build(withAec: true);
    await session.start();
    port.transcriptController.add('第一句话');
    await Future<void>.delayed(Duration.zero);
    final speaking = session.onResponseCompleted('这是第一轮回复');
    await Future<void>.delayed(Duration.zero);
    await port.stopSpeaking();
    await speaking;
    expect(session.isBusy, isFalse);
    port.transcriptController.add('第二句话');
    await Future<void>.delayed(Duration.zero);
    expect(sent, ['第一句话', '第二句话']);
  });

  test('timeout covers a send future that never completes', () async {
    port = _FakePort();
    final send = Completer<void>();
    session = CallSession(
      port: port,
      onSend: (_) => send.future,
      onStopGeneration: () async => stopCalls++,
      maximumTurnMilliseconds: 20,
    );
    await session.start();
    port.transcriptController.add('开始生成');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(stopCalls, 1);
    expect(session.phase, CallPhase.listening);
    send.complete();
  });

  test('capture reopens after VAD produces no transcript', () async {
    build(withAec: false);
    await session.start();
    port.listening = false;
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(port.listening, isTrue);
    expect(port.captureStarts, 2);
  });

  test('late response after interrupt is ignored', () async {
    build(withAec: true);
    await session.start();
    await session.interrupt();
    await session.onResponseCompleted('过期回复');
    expect(port.spoken, isEmpty);
  });

  test('stop during half duplex mic teardown prevents playback', () async {
    build(withAec: false);
    await session.start();
    port.captureStop = Completer<void>();
    final reply = session.onResponseCompleted('已经取消的语音');
    final stopping = session.stop();
    port.captureStop!.complete();
    await Future.wait([reply, stopping]);
    expect(port.spoken, isEmpty);
    expect(session.phase, CallPhase.idle);
  });

  test('first generated sentence starts TTS before completion', () async {
    build(withAec: false);
    await session.start();
    port.transcriptController.add('说点什么');
    await Future<void>.delayed(Duration.zero);
    expect(session.phase, CallPhase.thinking);

    session.onResponseDelta('第一句已经完成。');
    await Future<void>.delayed(Duration.zero);
    expect(session.phase, CallPhase.speaking);
    expect(port.streamed, ['第一句已经完成。']);
    expect(port.listening, isFalse);
    expect(port.spoken, isEmpty);

    session.onResponseDelta('第二句还在生成。');
    await session.onResponseCompleted('第一句已经完成。第二句还在生成。');
    expect(port.finishedReply, '第一句已经完成。第二句还在生成。');
    expect(port.streamFinishes, 1);
    expect(session.phase, CallPhase.listening);
  });

  test('streaming speech is cancelled when the turn is interrupted', () async {
    build(withAec: false);
    await session.start();
    port.transcriptController.add('开始');
    await Future<void>.delayed(Duration.zero);
    session.onResponseDelta('一句话。');
    await session.interrupt();
    expect(port.streamCancels, 1);
    expect(session.phase, CallPhase.listening);
  });

  test('half-duplex closes the microphone while speaking', () async {
    build(withAec: false);
    await session.start();
    expect(port.listening, isTrue);

    final speaking = session.onResponseCompleted('你好，我在这里。');
    await Future<void>.delayed(Duration.zero);
    expect(port.speaking, isTrue);
    expect(port.listening, isFalse);

    await port.stopSpeaking();
    await speaking;
    expect(session.phase, CallPhase.listening);
    expect(port.listening, isTrue);
  });

  test('full duplex keeps the microphone open during playback', () async {
    build(withAec: true);
    await session.start();

    final speaking = session.onResponseCompleted('我刚刚说到一半。');
    await Future<void>.delayed(Duration.zero);

    expect(port.speaking, isTrue);
    expect(port.listening, isTrue);

    await port.stopSpeaking();
    await speaking;
  });

  test('sustained energy over playback interrupts the agent', () async {
    build(withAec: true);
    await session.start();
    final speaking = session.onResponseCompleted('这一段很长，会被打断。');
    await Future<void>.delayed(Duration.zero);

    for (var frame = 0; frame < 20; frame++) {
      port.energyController.add(0.45);
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(port.speaking, isFalse);
    expect(session.bargeInCount, greaterThan(0));
    await speaking;
  });

  test('loud playback leakage alone does not interrupt', () async {
    build(withAec: true);
    await session.start();
    final speaking = session.onResponseCompleted('声音很大的播放内容。');
    await Future<void>.delayed(Duration.zero);

    for (var frame = 0; frame < 40; frame++) {
      port.energyController.add(0.30);
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    expect(port.speaking, isTrue);
    expect(session.bargeInCount, 0);
    await port.stopSpeaking();
    await speaking;
  });

  test(
    'transcript while listening is dispatched and enters thinking',
    () async {
      build(withAec: false);
      await session.start();

      port.transcriptController.add('帮我看一下明天的天气');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(sent, ['帮我看一下明天的天气']);
      expect(session.phase, CallPhase.thinking);
    },
  );

  test('the interrupting sentence becomes the next turn', () async {
    build(withAec: true);
    await session.start();
    final speaking = session.onResponseCompleted('我正在说话。');
    await Future<void>.delayed(Duration.zero);

    port.transcriptController.add('等一下，先别说了');
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(port.speaking, isFalse);
    expect(sent, ['等一下，先别说了']);
    expect(session.phase, CallPhase.thinking);
    await speaking;
  });

  test('stalled generation is interrupted by the turn timeout', () async {
    port = _FakePort();
    session = CallSession(
      port: port,
      onSend: (_) async {},
      onStopGeneration: () async => stopCalls++,
      settleDelay: Duration.zero,
      maximumTurnMilliseconds: 40,
    );
    await session.start();

    port.transcriptController.add('在吗');
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(stopCalls, 1);
    expect(session.phase, CallPhase.listening);
  });
}
