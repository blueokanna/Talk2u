import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/services/camera_observation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('talk2u/camera_observation');
  const eventName = 'talk2u/camera_observation/events';
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late CameraObservationService service;
  late List<String> calls;

  Future<void> emit(Map<String, Object?> event) async {
    final delivered = Completer<void>();
    await messenger.handlePlatformMessage(
      eventName,
      codec.encodeSuccessEnvelope(event),
      (_) {
        delivered.complete();
      },
    );
    await delivered.future;
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call.method);
      return {'status': call.method == 'start' ? 'starting' : 'stopped'};
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel(eventName),
      (_) async => null,
    );
    service = CameraObservationService(platformSupported: true);
  });

  tearDown(() async {
    await service.dispose();
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(const MethodChannel(eventName), null);
  });

  test('subscribing does not open a camera or request permission', () async {
    final subscription = service.states.listen((_) {});
    await Future<void>.delayed(Duration.zero);
    expect(calls, isEmpty);
    expect(service.latest.status, 'idle');
    await subscription.cancel();
  });

  test('decodes face presence and position without claiming liveness', () {
    final state = CameraObservationState.fromMap({
      'status': 'observing',
      'faceCount': 1,
      'primaryFace': {'centerX': 0.25, 'centerY': 0.75},
      'livenessVerified': true,
    });
    expect(state.faceDetected, isTrue);
    expect(state.primaryFace?.centerX, 0.25);
    expect(state.primaryFace?.centerY, 0.75);
    expect(state.livenessVerified, isFalse);
    final stopped = CameraObservationState.fromMap({
      'status': 'stopped',
      'faceCount': 1,
      'primaryFace': {'centerX': 0.25, 'centerY': 0.75},
    });
    expect(stopped.faceDetected, isFalse);
    expect(stopped.primaryFace, isNull);
  });

  test('rejects nonfinite coordinates and unknown status', () {
    final state = CameraObservationState.fromMap({
      'status': 'observing',
      'faceCount': 1,
      'primaryFace': {'centerX': double.nan, 'centerY': 0.5},
    });
    expect(state.primaryFace, isNull);
    expect(
      CameraObservationState.fromMap({'status': 'realPerson'}).status,
      'error',
    );
  });

  test(
    'coalesces concurrent starts and ignores a late start after stop',
    () async {
      final pending = Completer<Map<String, Object?>>();
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call.method);
        if (call.method == 'start') return pending.future;
        return {'status': 'stopped'};
      });
      final first = service.start();
      final second = service.start();
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((call) => call == 'start').length, 1);
      await service.stop();
      pending.complete({'status': 'observing', 'faceCount': 1});
      await Future.wait([first, second]);
      expect(service.latest.status, 'stopped');
      expect(service.latest.faceDetected, isFalse);
      await emit({'status': 'observing', 'faceCount': 1});
      expect(service.latest.status, 'stopped');
    },
  );

  test('permission denial and unsupported are explicit states', () async {
    await service.start();
    await emit({
      'status': 'permissionDenied',
      'reason': 'camera_permission_denied',
    });
    expect(service.latest.status, 'permissionDenied');
    expect(service.latest.faceDetected, isFalse);
    await emit({
      'status': 'unsupported',
      'reason': 'front_camera_hardware_face_detection_unavailable',
    });
    expect(service.latest.status, 'unsupported');
    expect(service.latest.reason, contains('hardware_face_detection'));
  });

  test('background stop clears face position and does not restart', () async {
    await service.start();
    await emit({
      'status': 'observing',
      'faceCount': 1,
      'primaryFace': {'centerX': 0.3, 'centerY': 0.4},
    });
    expect(service.latest.faceDetected, isTrue);
    await emit({'status': 'stopped', 'reason': 'background', 'sequence': 3});
    expect(service.latest.faceDetected, isFalse);
    expect(service.latest.primaryFace, isNull);
    await emit({'status': 'observing', 'faceCount': 1, 'sequence': 2});
    expect(service.latest.status, 'stopped');
    expect(calls, ['start']);
  });

  test('newer observation follows the previous stopped snapshot', () async {
    await service.start();
    await emit({'status': 'stopped', 'reason': 'background', 'sequence': 3});
    await service.start();
    await emit({'status': 'stopped', 'reason': 'background', 'sequence': 3});
    await emit({'status': 'starting', 'sequence': 4});
    await emit({'status': 'observing', 'faceCount': 1, 'sequence': 5});
    expect(service.latest.faceDetected, isTrue);
  });

  test('late method reply cannot overwrite a newer background event', () async {
    final pending = Completer<Map<String, Object?>>();
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'start') return pending.future;
      return {'status': 'stopped'};
    });
    final starting = service.start();
    await Future<void>.delayed(Duration.zero);
    await emit({'status': 'stopped', 'reason': 'background', 'sequence': 3});
    pending.complete({'status': 'starting', 'sequence': 2});
    await starting;
    expect(service.latest.status, 'stopped');
  });

  test('missing native plugin reports unsupported', () async {
    messenger.setMockMethodCallHandler(
      methods,
      (_) async => throw MissingPluginException(),
    );
    expect((await service.start()).status, 'unsupported');
  });

  test('non Android platform never invokes native camera', () async {
    final unsupported = CameraObservationService(platformSupported: false);
    expect((await unsupported.start()).status, 'unsupported');
    await unsupported.dispose();
    expect(calls, isEmpty);
  });

  test('dispose stops once and rejects further start', () async {
    await service.start();
    await service.dispose();
    await service.dispose();
    expect(calls, ['start', 'stop']);
    expect((await service.start()).reason, 'disposed');
  });
}
