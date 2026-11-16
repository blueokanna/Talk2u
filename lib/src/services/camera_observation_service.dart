import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A location in a front-camera view rotated to the display and mirrored.
/// Coordinates range from 0 (left/top) to 1 (right/bottom).
@immutable
class CameraFacePosition {
  const CameraFacePosition({required this.centerX, required this.centerY});

  final double centerX;
  final double centerY;

  static CameraFacePosition? _parse(Object? value) {
    if (value is! Map) return null;
    final x = value['centerX'];
    final y = value['centerY'];
    if (x is! num || y is! num || !x.isFinite || !y.isFinite) return null;
    return CameraFacePosition(
      centerX: x.toDouble().clamp(0.0, 1.0),
      centerY: y.toDouble().clamp(0.0, 1.0),
    );
  }
}

/// Hardware face detection is fallible: photographs and screens can trigger it.
/// This data never establishes identity, a real person, or liveness.
@immutable
class CameraObservationState {
  const CameraObservationState({
    required this.status,
    this.reason,
    this.faceCount = 0,
    this.primaryFace,
    this.timestampMillis = 0,
    this.sequence = 0,
  });

  final String status;
  final String? reason;
  final int faceCount;
  final CameraFacePosition? primaryFace;

  /// Android elapsed realtime, not a wall-clock timestamp.
  final int timestampMillis;

  /// Orders native events and method replies within one Activity instance.
  final int sequence;

  bool get isObserving => status == 'observing';
  bool get isStarting =>
      status == 'starting' || status == 'requestingPermission';
  bool get faceDetected => isObserving && faceCount > 0;
  bool get livenessVerified => false;

  factory CameraObservationState.fromMap(Map<dynamic, dynamic> value) {
    const statuses = {
      'idle',
      'requestingPermission',
      'starting',
      'observing',
      'stopped',
      'permissionDenied',
      'unsupported',
      'error',
    };
    final rawStatus = value['status'];
    final status = statuses.contains(rawStatus) ? rawStatus as String : 'error';
    final rawCount = value['faceCount'];
    final count = rawCount is num && rawCount.isFinite && rawCount > 0
        ? rawCount.toInt()
        : 0;
    final rawTime = value['timestampMillis'];
    final rawSequence = value['sequence'];
    return CameraObservationState(
      status: status,
      reason: value['reason']?.toString(),
      faceCount: status == 'observing' ? count : 0,
      primaryFace: status == 'observing' && count > 0
          ? CameraFacePosition._parse(value['primaryFace'])
          : null,
      timestampMillis: rawTime is num && rawTime.isFinite ? rawTime.toInt() : 0,
      sequence: rawSequence is num && rawSequence.isFinite
          ? rawSequence.toInt()
          : 0,
    );
  }
}

/// Own one instance per screen. Call [start] only after a user's explicit action;
/// subscribing to [states] does not open the camera or request permission.
/// Android stops on Activity pause, and resuming never automatically starts it.
class CameraObservationService {
  CameraObservationService({
    MethodChannel channel = const MethodChannel('talk2u/camera_observation'),
    EventChannel eventChannel = const EventChannel(
      'talk2u/camera_observation/events',
    ),
    @visibleForTesting bool? platformSupported,
  }) : _channel = channel,
       _eventChannel = eventChannel,
       _platformSupported =
           platformSupported ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final MethodChannel _channel;
  final EventChannel _eventChannel;
  final bool _platformSupported;
  final _states = StreamController<CameraObservationState>.broadcast();
  StreamSubscription<dynamic>? _subscription;
  Future<CameraObservationState>? _starting;
  bool _disposed = false;
  bool _acceptObservations = false;
  int _generation = 0;
  int _lastNativeSequence = 0;
  CameraObservationState _latest = const CameraObservationState(status: 'idle');

  Stream<CameraObservationState> get states => _states.stream;
  CameraObservationState get latest => _latest;

  Future<CameraObservationState> start() {
    if (_disposed) {
      return Future.value(
        const CameraObservationState(status: 'error', reason: 'disposed'),
      );
    }
    if (!_platformSupported) {
      _publish(
        const CameraObservationState(
          status: 'unsupported',
          reason: 'android_only',
        ),
      );
      return Future.value(_latest);
    }
    final pending = _starting;
    if (pending != null) return pending;
    _acceptObservations = true;
    _listen();
    final generation = ++_generation;
    final future = _invoke('start', generation);
    _starting = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_starting, future)) _starting = null;
      }),
    );
    return future;
  }

  Future<CameraObservationState> stop() async {
    if (_disposed) return _latest;
    _acceptObservations = false;
    _starting = null;
    final generation = ++_generation;
    // Immediately remove stale face positions from the UI.
    _publish(const CameraObservationState(status: 'stopped', reason: 'user'));
    if (!_platformSupported) return _latest;
    return _invoke('stop', generation);
  }

  void _listen() {
    _subscription ??= _eventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (_disposed || event is! Map) return;
        final state = CameraObservationState.fromMap(event);
        if (!_acceptObservations && (state.isObserving || state.isStarting)) {
          return;
        }
        if (state.sequence > 0 && state.sequence < _lastNativeSequence) return;
        _publish(state);
      },
      onError: (Object error) {
        if (_disposed) return;
        _acceptObservations = false;
        _publish(
          CameraObservationState(
            status: error is MissingPluginException ? 'unsupported' : 'error',
            reason: 'camera_event_stream_unavailable',
          ),
        );
        // A detached/broken event stream must not leave a camera running.
        unawaited(_stopNativeQuietly());
      },
    );
  }

  Future<CameraObservationState> _invoke(String method, int generation) async {
    CameraObservationState state;
    try {
      final value = await _channel.invokeMapMethod<dynamic, dynamic>(method);
      state = value == null
          ? const CameraObservationState(
              status: 'error',
              reason: 'empty_platform_response',
            )
          : CameraObservationState.fromMap(value);
    } on MissingPluginException {
      state = const CameraObservationState(
        status: 'unsupported',
        reason: 'camera_plugin_unavailable',
      );
    } on PlatformException catch (error) {
      state = CameraObservationState(status: 'error', reason: error.code);
    }
    if (!_disposed && generation == _generation) {
      if (method == 'start' && !_acceptObservations) return _latest;
      // Events can arrive before the method reply. Do not revive a stopped
      // session, or overwrite a newer observation with a starting snapshot.
      if ((state.sequence > 0 && state.sequence < _lastNativeSequence) ||
          (state.timestampMillis > 0 &&
              state.timestampMillis < _latest.timestampMillis)) {
        return _latest;
      }
      if (!(state.isStarting && _latest.isObserving)) _publish(state);
    }
    return _latest;
  }

  void _publish(CameraObservationState state) {
    if (_disposed) return;
    if (state.sequence > 0) _lastNativeSequence = state.sequence;
    _latest = state;
    _states.add(state);
  }

  Future<void> _stopNativeQuietly() async {
    if (!_platformSupported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // No camera implementation exists on this engine.
    } on PlatformException {
      // Native lifecycle teardown independently closes the camera.
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _acceptObservations = false;
    ++_generation;
    _latest = const CameraObservationState(
      status: 'stopped',
      reason: 'disposed',
    );
    await _stopNativeQuietly();
    await _subscription?.cancel();
    _subscription = null;
    await _states.close();
  }
}
