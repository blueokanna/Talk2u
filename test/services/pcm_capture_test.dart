import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/services/pcm_capture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/pcm-capture');
  const frames = MethodChannel('talk2u/full_duplex_frames');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> commands;
  Completer<void>? starting;
  bool failStart = false;
  late FullDuplexPcmCapture capture;

  setUp(() {
    commands = [];
    starting = null;
    failStart = false;
    messenger.setMockMethodCallHandler(frames, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      commands.add(call.method);
      if (call.method == 'start') {
        await starting?.future;
        if (failStart) throw PlatformException(code: 'start_failed');
        return {'supported': true, 'echoCancelerEnabled': true};
      }
      return null;
    });
    capture = FullDuplexPcmCapture(channel: channel);
  });

  tearDown(() async {
    await capture.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(frames, null);
  });

  test('stop followed by dispose does not stop a later capture', () async {
    await capture.start();
    await capture.stop();
    await capture.dispose();
    expect(commands, ['start', 'stop']);
  });

  test(
    'concurrent starts share capture and stop waits for pending start',
    () async {
      starting = Completer<void>();
      final first = capture.start();
      final second = capture.start();
      final stop = capture.stop();
      starting!.complete();
      await Future.wait([first, second, stop]);
      expect(commands, ['start', 'stop']);
    },
  );

  test('failed startup can be retried without a stale subscription', () async {
    failStart = true;
    await expectLater(capture.start(), throwsA(isA<PlatformException>()));
    failStart = false;
    expect((await capture.start()).hardwareEchoCancellation, isTrue);
    await capture.stop();
    expect(commands, ['start', 'start', 'stop']);
  });

  test(
    'capture event errors reach the speech recognizer subscription',
    () async {
      final error = Completer<Object>();
      final subscription = capture.frames.listen(
        (_) {},
        onError: (Object value) {
          error.complete(value);
        },
      );
      await capture.start();
      await messenger.handlePlatformMessage(
        'talk2u/full_duplex_frames',
        const StandardMethodCodec().encodeErrorEnvelope(code: 'capture_failed'),
        (_) {},
      );
      expect(await error.future, isA<PlatformException>());
      await subscription.cancel();
    },
  );
}
