import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/services/call_session.dart';
import 'package:talk2u/src/services/normal_speech.dart';

class _FakeSpeech implements StreamingReplySpeech {
  final appended = <String>[];
  int starts = 0;
  String? finishedWith;
  bool cancelled = false;
  int finishCalls = 0;
  Completer<void>? finishGate;

  @override
  void append(String text) => appended.add(text);

  @override
  Future<void> finish(String fullReply) async {
    finishCalls++;
    finishedWith = fullReply;
    await finishGate?.future;
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
  }
}

void main() {
  test('auto-read starts on the first delta and keeps one sink', () async {
    final speech = _FakeSpeech();
    var creates = 0;
    final controller = NormalReplySpeech(
      create: () {
        creates++;
        return speech;
      },
      autoRead: () => true,
    );

    controller.append('第一句。');
    controller.append('第二句。');
    expect(creates, 1);
    expect(speech.appended, ['第一句。', '第二句。']);

    await controller.finish('第一句。第二句。');
    expect(speech.finishedWith, '第一句。第二句。');
    expect(speech.finishCalls, 1);
    expect(controller.active, isFalse);
  });

  test('auto-read disabled ignores deltas until the speaker button', () {
    final speech = _FakeSpeech();
    var creates = 0;
    final controller = NormalReplySpeech(
      create: () {
        creates++;
        return speech;
      },
      autoRead: () => false,
    );

    controller.append('不会自动朗读。');
    expect(creates, 0);

    controller.startManual('已经生成一半');
    controller.append('，后半句。');
    expect(creates, 1);
    expect(speech.appended, ['已经生成一半', '，后半句。']);
  });

  test('cancel still stops a reply whose final playback is draining', () async {
    final speech = _FakeSpeech()..finishGate = Completer<void>();
    final controller = NormalReplySpeech(
      create: () => speech,
      autoRead: () => true,
    );
    controller.append('最后一句。');
    final finishing = controller.finish('最后一句。');
    await Future<void>.delayed(Duration.zero);
    expect(controller.active, isTrue);

    await controller.cancel();
    expect(speech.cancelled, isTrue);
    expect(controller.active, isFalse);
    speech.finishGate!.complete();
    await finishing;
  });

  test('cancel clears the handle and can be repeated', () async {
    final speech = _FakeSpeech();
    final controller = NormalReplySpeech(
      create: () => speech,
      autoRead: () => true,
    );
    controller.append('会被停止。');
    await controller.cancel();
    expect(speech.cancelled, isTrue);
    expect(controller.active, isFalse);
    await controller.cancel();
  });
}
