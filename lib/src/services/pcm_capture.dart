import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

const _channelName = 'talk2u/full_duplex_audio';
const _framesChannelName = 'talk2u/full_duplex_frames';

@immutable
class AudioCaptureCapabilities {
  const AudioCaptureCapabilities({
    this.available = false,
    this.echoCancellerAvailable = false,
    this.echoCancellerEnabled = false,
    this.noiseSuppressorEnabled = false,
    this.gainControlEnabled = false,
    this.source = '',
    this.lastError,
  });

  final bool available;
  final bool echoCancellerAvailable;
  final bool echoCancellerEnabled;
  final bool noiseSuppressorEnabled;
  final bool gainControlEnabled;
  final String source;
  final String? lastError;

  factory AudioCaptureCapabilities.fromMap(Map<dynamic, dynamic> value) =>
      AudioCaptureCapabilities(
        available: value['supported'] == true,
        echoCancellerAvailable: value['echoCancelerAvailable'] == true,
        echoCancellerEnabled: value['echoCancelerEnabled'] == true,
        noiseSuppressorEnabled: value['noiseSuppressorEnabled'] == true,
        gainControlEnabled: value['gainControlEnabled'] == true,
        source: value['source']?.toString() ?? '',
        lastError: value['lastError']?.toString(),
      );

  bool get hardwareEchoCancellation => available && echoCancellerEnabled;
}

/// A 16 kHz mono PCM16 microphone source.
abstract interface class PcmCapture {
  Stream<Uint8List> get frames;

  AudioCaptureCapabilities get capabilities;

  Future<AudioCaptureCapabilities> start();

  Future<void> stop();

  Future<void> dispose();
}

class RecorderPcmCapture implements PcmCapture {
  RecorderPcmCapture();

  static const sampleRate = 16000;

  final AudioRecorder _recorder = AudioRecorder();
  final _controller = StreamController<Uint8List>.broadcast();
  AudioCaptureCapabilities _capabilities = const AudioCaptureCapabilities();
  StreamSubscription<Uint8List>? _subscription;

  @override
  Stream<Uint8List> get frames => _controller.stream;

  @override
  AudioCaptureCapabilities get capabilities => _capabilities;

  @override
  Future<AudioCaptureCapabilities> start() async {
    if (!await _recorder.hasPermission()) {
      throw StateError('麦克风权限未授予');
    }
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
      ),
    );
    _subscription = stream.listen(
      _controller.add,
      onError: (Object error) => _capabilities = AudioCaptureCapabilities(
        source: 'record',
        lastError: error.toString(),
      ),
      cancelOnError: true,
    );
    _capabilities = const AudioCaptureCapabilities(source: 'record');
    return _capabilities;
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _recorder.stop();
    } on Object catch (_) {
      // The recorder throws when it was already stopped by an error path.
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _controller.close();
    await _recorder.dispose();
  }
}

/// Microphone source with the platform echo canceller attached.
///
/// Uses `VOICE_COMMUNICATION` capture plus `AcousticEchoCanceler`, and reports
/// the effect state the platform actually granted so callers can decide whether
/// acoustic barge-in is safe instead of assuming it.
class FullDuplexPcmCapture implements PcmCapture {
  FullDuplexPcmCapture({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName),
      _frames = const EventChannel(_framesChannelName);

  final MethodChannel _channel;
  final EventChannel _frames;
  final _controller = StreamController<Uint8List>.broadcast();
  StreamSubscription<dynamic>? _subscription;
  AudioCaptureCapabilities _capabilities = const AudioCaptureCapabilities();
  bool _disposed = false;

  @override
  Stream<Uint8List> get frames => _controller.stream;

  @override
  AudioCaptureCapabilities get capabilities => _capabilities;

  static Future<AudioCaptureCapabilities> probe() async {
    try {
      final value = await const MethodChannel(
        _channelName,
      ).invokeMapMethod<dynamic, dynamic>('capabilities');
      if (value == null) return const AudioCaptureCapabilities();
      return AudioCaptureCapabilities.fromMap(value);
    } on PlatformException {
      return const AudioCaptureCapabilities();
    } on MissingPluginException {
      return const AudioCaptureCapabilities();
    }
  }

  @override
  Future<AudioCaptureCapabilities> start() async {
    if (_disposed) throw StateError('full-duplex capture 已释放');
    _subscription ??= _frames.receiveBroadcastStream().listen((event) {
      if (event is Uint8List) {
        _controller.add(event);
      } else if (event is List<int>) {
        _controller.add(Uint8List.fromList(event));
      }
    });
    final value = await _channel.invokeMapMethod<dynamic, dynamic>('start');
    _capabilities = value == null
        ? const AudioCaptureCapabilities()
        : AudioCaptureCapabilities.fromMap(value);
    return _capabilities;
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Already released by the activity lifecycle.
    } on MissingPluginException {
      // Channel unavailable after engine teardown.
    }
    await _subscription?.cancel();
    _subscription = null;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await stop();
    await _controller.close();
  }
}
