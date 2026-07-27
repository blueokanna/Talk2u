import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

class _SpeechAsset {
  final String fileName;
  final String url;
  final int size;
  final String sha256;

  const _SpeechAsset({
    required this.fileName,
    required this.url,
    required this.size,
    required this.sha256,
  });

  List<String> get downloadUrls => [
    url,
    'https://ghfast.top/$url',
    'https://gh-proxy.com/$url',
  ];
}

class SherpaSpeechService extends ChangeNotifier {
  SherpaSpeechService._();

  static final instance = SherpaSpeechService._();
  static const engineName = 'sherpa-onnx 端侧识别';
  static const engineLicense = 'Apache-2.0';
  static const asrModelName = 'SenseVoice 2025 INT8';
  static const asrArchiveBytes = 165783878;
  static const _asrDirectoryName =
      'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09';
  static const _asrAsset = _SpeechAsset(
    fileName: '$_asrDirectoryName.tar.bz2',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
        '$_asrDirectoryName.tar.bz2',
    size: asrArchiveBytes,
    sha256: '7305f7905bfcf77fa0b39388a313f3da35c68d971661a65475b56fb2162c8e63',
  );

  final AudioRecorder _recorder = AudioRecorder();
  final StreamController<String> _recognitionController =
      StreamController<String>.broadcast();
  StreamSubscription<Uint8List>? _recordingSubscription;
  Timer? _recordingTimeout;
  BytesBuilder? _recordedAudio;
  HttpClientRequest? _downloadRequest;
  Future<_SenseVoiceWorker>? _asrWorkerFuture;
  bool _cancelRequested = false;
  bool _speechDetected = false;
  bool _vadStopping = false;
  int _voicedMilliseconds = 0;
  int _silenceMilliseconds = 0;
  double _noiseFloor = 0.004;

  bool initialized = false;
  bool asrReady = false;
  bool downloading = false;
  bool extracting = false;
  bool listening = false;
  bool recognizing = false;
  int downloadedBytes = 0;
  int totalDownloadBytes = 0;
  String operationLabel = '';
  String? lastError;

  bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isWindows || Platform.isLinux);
  double get downloadProgress => totalDownloadBytes <= 0
      ? 0
      : (downloadedBytes / totalDownloadBytes).clamp(0, 1);
  Stream<String> get recognitionResults => _recognitionController.stream;

  Future<Directory> _rootDirectory() async {
    final support = await getApplicationSupportDirectory();
    final root = Directory(
      '${support.path}${Platform.pathSeparator}sherpa-speech',
    );
    if (!await root.exists()) await root.create(recursive: true);
    return root;
  }

  Future<Directory> _asrDirectory() async => Directory(
    '${(await _rootDirectory()).path}${Platform.pathSeparator}$_asrDirectoryName',
  );

  Future<void> initialize() async {
    if (initialized || !supported) {
      initialized = true;
      return;
    }
    try {
      asrReady = await _validateAsr();
      await _deleteRemovedTtsAssets();
      lastError = null;
    } catch (error) {
      lastError = '无法检查 sherpa-onnx 识别模型: $error';
    } finally {
      initialized = true;
      notifyListeners();
    }
  }

  Future<bool> _validateAsr() async {
    final directory = await _asrDirectory();
    return await File(
          '${directory.path}${Platform.pathSeparator}model.int8.onnx',
        ).exists() &&
        await File(
          '${directory.path}${Platform.pathSeparator}tokens.txt',
        ).exists();
  }

  Future<void> _deleteRemovedTtsAssets() async {
    final root = await _rootDirectory();
    final targets = <FileSystemEntity>[
      Directory(
        '${root.path}${Platform.pathSeparator}kokoro-int8-multi-lang-v1_1',
      ),
      File(
        '${root.path}${Platform.pathSeparator}kokoro-int8-multi-lang-v1_1.tar.bz2',
      ),
      File(
        '${root.path}${Platform.pathSeparator}kokoro-int8-multi-lang-v1_1.tar.bz2.part',
      ),
      File('${root.path}${Platform.pathSeparator}tts-preferences.json'),
      Directory('${root.path}${Platform.pathSeparator}matcha-icefall-zh-en'),
      File('${root.path}${Platform.pathSeparator}vocos-16khz-univ.onnx'),
    ];
    for (final target in targets) {
      if (await target.exists()) await target.delete(recursive: true);
    }
  }

  Future<void> downloadAsr() async {
    if (!supported) throw UnsupportedError('当前平台不支持 sherpa-onnx 语音识别');
    if (downloading || extracting) return;
    await _downloadAndInstallArchive(
      _asrAsset,
      expectedDirectoryName: _asrDirectoryName,
      label: '正在下载 SenseVoice',
    );
    if (_cancelRequested) return;
    asrReady = await _validateAsr();
    if (!asrReady) throw const FormatException('SenseVoice 模型文件不完整');
    notifyListeners();
  }

  Future<File> _downloadAsset(
    _SpeechAsset asset, {
    required String label,
  }) async {
    final root = await _rootDirectory();
    final destination = File(
      '${root.path}${Platform.pathSeparator}${asset.fileName}',
    );
    final partial = File('${destination.path}.part');
    downloading = true;
    _cancelRequested = false;
    downloadedBytes = 0;
    totalDownloadBytes = asset.size;
    operationLabel = label;
    lastError = null;
    notifyListeners();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    IOSink? sink;
    try {
      Object? lastFailure;
      for (
        var sourceIndex = 0;
        sourceIndex < asset.downloadUrls.length;
        sourceIndex++
      ) {
        try {
          var existingBytes = await partial.exists()
              ? await partial.length()
              : 0;
          if (existingBytes > asset.size) {
            await partial.delete();
            existingBytes = 0;
          }
          if (existingBytes == asset.size) {
            final digest = await sha256.bind(partial.openRead()).first;
            if (digest.toString() == asset.sha256) {
              if (await destination.exists()) await destination.delete();
              return partial.rename(destination.path);
            }
            await partial.delete();
            existingBytes = 0;
          }
          downloadedBytes = existingBytes;
          operationLabel = sourceIndex == 0
              ? label
              : '$label（备用源 $sourceIndex）';
          notifyListeners();
          final request = await client
              .getUrl(Uri.parse(asset.downloadUrls[sourceIndex]))
              .timeout(const Duration(seconds: 20));
          _downloadRequest = request;
          request.headers.set(HttpHeaders.userAgentHeader, 'Talk2U/1.0');
          if (existingBytes > 0) {
            request.headers.set(
              HttpHeaders.rangeHeader,
              'bytes=$existingBytes-',
            );
          }
          final response = await request.close().timeout(
            const Duration(seconds: 30),
          );
          var append = false;
          if (existingBytes > 0 &&
              response.statusCode == HttpStatus.partialContent) {
            final contentRange = response.headers.value(
              HttpHeaders.contentRangeHeader,
            );
            if (contentRange == null ||
                !contentRange.startsWith('bytes $existingBytes-')) {
              await response.drain<void>();
              throw const HttpException('语音模型断点续传范围无效');
            }
            append = true;
          } else if (response.statusCode == HttpStatus.ok) {
            if (existingBytes > 0 && await partial.exists()) {
              await partial.delete();
            }
            downloadedBytes = 0;
          } else {
            await response.drain<void>();
            throw HttpException('语音模型下载返回 HTTP ${response.statusCode}');
          }
          sink = partial.openWrite(
            mode: append ? FileMode.append : FileMode.write,
          );
          var lastNotification = DateTime.now();
          await for (final chunk in response.timeout(
            const Duration(seconds: 30),
          )) {
            sink.add(chunk);
            downloadedBytes += chunk.length;
            final now = DateTime.now();
            if (now.difference(lastNotification).inMilliseconds >= 200) {
              lastNotification = now;
              notifyListeners();
            }
          }
          await sink.flush();
          await sink.close();
          sink = null;
          if (await partial.length() != asset.size) {
            throw const HttpException('语音模型连接提前结束，等待断点续传');
          }
          final digest = await sha256.bind(partial.openRead()).first;
          if (digest.toString() != asset.sha256) {
            await partial.delete();
            throw const FormatException('语音模型 SHA-256 校验失败');
          }
          if (await destination.exists()) await destination.delete();
          return partial.rename(destination.path);
        } catch (error) {
          lastFailure = error;
          await sink?.close();
          sink = null;
          _downloadRequest = null;
          if (await partial.exists() && await partial.length() > asset.size) {
            await partial.delete();
          }
          if (_cancelRequested) {
            if (await partial.exists()) await partial.delete();
            throw const _SpeechDownloadCancelled();
          }
        }
      }
      if (lastFailure != null) {
        Error.throwWithStackTrace(lastFailure, StackTrace.current);
      }
      throw const HttpException('语音模型下载源均不可用');
    } catch (error) {
      lastError = _cancelRequested ? null : error.toString();
      if (_cancelRequested && await partial.exists()) await partial.delete();
      if (!_cancelRequested) rethrow;
      throw const _SpeechDownloadCancelled();
    } finally {
      await sink?.close();
      _downloadRequest = null;
      client.close(force: true);
      downloading = false;
      notifyListeners();
    }
  }

  Future<void> _downloadAndInstallArchive(
    _SpeechAsset asset, {
    required String expectedDirectoryName,
    required String label,
  }) async {
    try {
      final archive = await _downloadAsset(asset, label: label);
      final root = await _rootDirectory();
      final staging = Directory(
        '${root.path}${Platform.pathSeparator}.$expectedDirectoryName-installing',
      );
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create(recursive: true);
      extracting = true;
      operationLabel = '正在安装语音识别模型';
      notifyListeners();
      try {
        await Isolate.run(() => extractFileToDisk(archive.path, staging.path));
        final extracted = Directory(
          '${staging.path}${Platform.pathSeparator}$expectedDirectoryName',
        );
        if (!await extracted.exists()) {
          throw const FormatException('语音识别模型归档目录无效');
        }
        final destination = Directory(
          '${root.path}${Platform.pathSeparator}$expectedDirectoryName',
        );
        if (await destination.exists()) {
          await destination.delete(recursive: true);
        }
        await extracted.rename(destination.path);
      } finally {
        extracting = false;
        if (await staging.exists()) await staging.delete(recursive: true);
        if (await archive.exists()) await archive.delete();
        notifyListeners();
      }
    } on _SpeechDownloadCancelled {
      return;
    }
  }

  void cancelDownload() {
    _cancelRequested = true;
    _downloadRequest?.abort(const HttpException('用户取消语音识别模型下载'));
  }

  Future<void> deleteAsr() async {
    if (listening || recognizing) throw StateError('请先停止语音识别');
    await _closeAsrWorker();
    final directory = await _asrDirectory();
    if (await directory.exists()) await directory.delete(recursive: true);
    asrReady = false;
    notifyListeners();
  }

  Future<void> startListening() async {
    await initialize();
    if (!asrReady) throw StateError('请先下载 SenseVoice 离线识别模型');
    if (listening || recognizing) return;
    if (!await _recorder.hasPermission()) throw StateError('麦克风权限未授予');
    _recordedAudio = BytesBuilder(copy: false);
    _speechDetected = false;
    _vadStopping = false;
    _voicedMilliseconds = 0;
    _silenceMilliseconds = 0;
    _noiseFloor = 0.004;
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    _recordingSubscription = stream.listen(
      (chunk) {
        _recordedAudio?.add(chunk);
        _updateVoiceActivity(chunk);
      },
      onError: (Object error) {
        lastError = error.toString();
        listening = false;
        notifyListeners();
      },
    );
    listening = true;
    lastError = null;
    _recordingTimeout = Timer(
      const Duration(seconds: 60),
      () => unawaited(stopListening()),
    );
    notifyListeners();
  }

  void _updateVoiceActivity(Uint8List chunk) {
    final sampleCount = chunk.length ~/ 2;
    if (sampleCount == 0 || _vadStopping) return;
    final data = ByteData.sublistView(chunk, 0, sampleCount * 2);
    var energy = 0.0;
    for (var index = 0; index < sampleCount; index++) {
      final sample = data.getInt16(index * 2, Endian.little) / 32768.0;
      energy += sample * sample;
    }
    final rms = math.sqrt(energy / sampleCount);
    final duration = (sampleCount * 1000 / 16000)
        .round()
        .clamp(1, 1000)
        .toInt();
    final threshold = math.max(0.012, _noiseFloor * 3.2);
    if (!_speechDetected && rms < threshold) {
      _noiseFloor = (_noiseFloor * 0.96 + rms * 0.04)
          .clamp(0.001, 0.02)
          .toDouble();
    }
    if (rms >= threshold) {
      _voicedMilliseconds += duration;
      _silenceMilliseconds = 0;
      if (_voicedMilliseconds >= 120) _speechDetected = true;
      return;
    }
    if (!_speechDetected) {
      _voicedMilliseconds = 0;
      return;
    }
    _silenceMilliseconds += duration;
    if (_silenceMilliseconds >= 850) {
      _vadStopping = true;
      unawaited(stopListening());
    }
  }

  Future<String?> stopListening() async {
    if (!listening) return null;
    _recordingTimeout?.cancel();
    _recordingTimeout = null;
    await _recorder.stop();
    await _recordingSubscription?.cancel();
    _recordingSubscription = null;
    listening = false;
    _vadStopping = false;
    final bytes = _recordedAudio?.takeBytes() ?? Uint8List(0);
    _recordedAudio = null;
    if (bytes.isEmpty) {
      notifyListeners();
      return null;
    }
    recognizing = true;
    notifyListeners();
    try {
      late final String text;
      try {
        text = await (await _asrWorker()).recognize(bytes);
      } catch (_) {
        await _closeAsrWorker();
        rethrow;
      }
      if (text.isNotEmpty) _recognitionController.add(text);
      return text;
    } catch (error) {
      lastError = error.toString();
      rethrow;
    } finally {
      recognizing = false;
      notifyListeners();
    }
  }

  Future<_SenseVoiceWorker> _asrWorker() async {
    final existing = _asrWorkerFuture;
    if (existing != null) return existing;
    final directory = await _asrDirectory();
    final future = _SenseVoiceWorker.start(
      '${directory.path}${Platform.pathSeparator}model.int8.onnx',
      '${directory.path}${Platform.pathSeparator}tokens.txt',
    );
    _asrWorkerFuture = future;
    try {
      return await future;
    } catch (_) {
      if (identical(_asrWorkerFuture, future)) _asrWorkerFuture = null;
      rethrow;
    }
  }

  Future<void> _closeAsrWorker() async {
    final future = _asrWorkerFuture;
    _asrWorkerFuture = null;
    if (future == null) return;
    try {
      await (await future).close();
    } catch (_) {}
  }

  @override
  void dispose() {
    _recordingTimeout?.cancel();
    _recordingSubscription?.cancel();
    unawaited(_closeAsrWorker());
    _recognitionController.close();
    _recorder.dispose();
    super.dispose();
  }
}

class _SpeechDownloadCancelled implements Exception {
  const _SpeechDownloadCancelled();
}

class _SenseVoiceWorker {
  final Isolate _isolate;
  final SendPort _commands;
  bool _closed = false;

  _SenseVoiceWorker(this._isolate, this._commands);

  static Future<_SenseVoiceWorker> start(String model, String tokens) async {
    final ready = ReceivePort();
    final errors = ReceivePort();
    final isolate = await Isolate.spawn<List<Object>>(
      _senseVoiceWorkerMain,
      <Object>[ready.sendPort, model, tokens],
      errorsAreFatal: true,
      onError: errors.sendPort,
      debugName: 'talk2u-sensevoice',
    );
    try {
      final value = await Future.any<dynamic>([ready.first, errors.first]);
      if (value is SendPort) return _SenseVoiceWorker(isolate, value);
      throw StateError('SenseVoice 识别器初始化失败: $value');
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    } finally {
      ready.close();
      errors.close();
    }
  }

  Future<String> recognize(Uint8List pcm) async {
    if (_closed) throw StateError('SenseVoice 识别器已关闭');
    final response = ReceivePort();
    _commands.send(<Object>[
      'recognize',
      TransferableTypedData.fromList(<Uint8List>[pcm]),
      response.sendPort,
    ]);
    try {
      final value = await response.first.timeout(const Duration(seconds: 90));
      if (value is List && value.length == 2 && value.first == 'ok') {
        return value[1] as String;
      }
      final message = value is List && value.length > 1 ? value[1] : value;
      throw StateError('SenseVoice 识别失败: $message');
    } finally {
      response.close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final response = ReceivePort();
    _commands.send(<Object>['close', response.sendPort]);
    try {
      await response.first.timeout(const Duration(seconds: 3));
    } finally {
      response.close();
      _isolate.kill(priority: Isolate.immediate);
    }
  }
}

void _senseVoiceWorkerMain(List<Object> arguments) {
  final ready = arguments[0] as SendPort;
  final model = arguments[1] as String;
  final tokens = arguments[2] as String;
  sherpa.initBindings();
  final recognizer = sherpa.OfflineRecognizer(
    sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        senseVoice: sherpa.OfflineSenseVoiceModelConfig(
          model: model,
          language: 'auto',
          useInverseTextNormalization: true,
        ),
        tokens: tokens,
        numThreads: 2,
        debug: false,
      ),
    ),
  );
  final commands = ReceivePort();
  ready.send(commands.sendPort);
  commands.listen((dynamic message) {
    if (message is! List || message.isEmpty) return;
    if (message.first == 'close') {
      recognizer.free();
      (message[1] as SendPort).send(true);
      commands.close();
      return;
    }
    if (message.first != 'recognize' || message.length != 3) return;
    final response = message[2] as SendPort;
    try {
      final pcm = (message[1] as TransferableTypedData)
          .materialize()
          .asUint8List();
      response.send(<Object>['ok', _recognizeSenseVoice(pcm, recognizer)]);
    } catch (error) {
      response.send(<Object>['error', error.toString()]);
    }
  });
}

String _recognizeSenseVoice(
  Uint8List pcm,
  sherpa.OfflineRecognizer recognizer,
) {
  final samples = Float32List(pcm.length ~/ 2);
  final data = ByteData.sublistView(pcm);
  for (var index = 0; index < samples.length; index++) {
    samples[index] = data.getInt16(index * 2, Endian.little) / 32768.0;
  }
  final stream = recognizer.createStream();
  try {
    stream.acceptWaveform(samples: samples, sampleRate: 16000);
    recognizer.decode(stream);
    return recognizer
        .getResult(stream)
        .text
        .replaceAll(RegExp(r'<\|[^>]+\|>'), '')
        .trim();
  } finally {
    stream.free();
  }
}
