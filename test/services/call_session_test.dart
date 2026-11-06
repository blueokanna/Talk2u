import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/services/call_session.dart';

class _FakePort implements CallSpeechPort {
  _FakePort({this.echoCancellationVerified = false});

  @override
  final bool echoCancellationVerified;

  final transcriptController = StreamController<String>.broadcast();
  final energyController = StreamController<double>.broadcast();
  final spoken = <String>[];
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
  String get captureSource => echoCancellationVerified ? 'VOICE_COMMUNICATION' : 'record';

  @override
  Stream<String> get transcripts => transcriptController.stream;

  @override
  Stream<double> get frameEnergies => energyController.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> startListening() async {
    listening = true;
  }

  @override
  Future<void> stopListening() async {
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
    final active = playback;
    speaking = false;
    amplitude = 0;
    if (active != null && !active.isCompleted) active.complete();
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

  test('transcript while listening is dispatched and enters thinking', () async {
    build(withAec: false);
    await session.start();

    port.transcriptController.add('帮我看一下明天的天气');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(sent, ['帮我看一下明天的天气']);
    expect(session.phase, CallPhase.thinking);
  });

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
