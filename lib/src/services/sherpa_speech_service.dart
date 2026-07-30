import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

@immutable
class SenseVoiceRecognition {
  final String text;
  final String language;
  final String emotion;
  final String event;

  const SenseVoiceRecognition({
    required this.text,
    required this.language,
    required this.emotion,
    required this.event,
  });

  factory SenseVoiceRecognition.fromMap(Map<dynamic, dynamic> value) =>
      SenseVoiceRecognition(
        text: value['text']?.toString().trim() ?? '',
        language: value['language']?.toString() ?? '',
        emotion: value['emotion']?.toString() ?? '',
        event: value['event']?.toString() ?? '',
      );
}

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

class _SenseVoicePackage {
  final String soc;
  final String directoryName;
  final _SpeechAsset asset;

  const _SenseVoicePackage({
    required this.soc,
    required this.directoryName,
    required this.asset,
  });
}

class SherpaSpeechService extends ChangeNotifier {
  SherpaSpeechService._();

  static final instance = SherpaSpeechService._();
  static const activeProvider = 'QNN_HTP (SM8750/SM8850 v81)';
  static const engineName = 'sherpa-onnx 端侧识别';
  static const engineLicense = 'Apache-2.0';
  static const asrModelName = 'SenseVoice 2024-07-17 INT8 (SM8750/SM8850 QNN)';
  static const _sampleRate = 16000;
  static const _maxAudioSeconds = 10;
  static const _maxPcmBytes = _sampleRate * _maxAudioSeconds * 2;
  static const _manifestName = 'talk2u-sensevoice-manifest.json';
  static const _runtimeChannel = MethodChannel('talk2u/sensevoice_qnn');
  static const _senseVoicePackages = <String, _SenseVoicePackage>{
    'SM8750': _SenseVoicePackage(
      soc: 'SM8750',
      directoryName:
          'sherpa-onnx-qnn-SM8750-binary-10-seconds-sense-voice-zh-en-ja-ko-yue-2024-07-17-int8',
      asset: _SpeechAsset(
        fileName:
            'sherpa-onnx-qnn-SM8750-binary-10-seconds-sense-voice-zh-en-ja-ko-yue-2024-07-17-int8.tar.bz2',
        url:
            'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models-qnn-binary/'
            'sherpa-onnx-qnn-SM8750-binary-10-seconds-sense-voice-zh-en-ja-ko-yue-2024-07-17-int8.tar.bz2',
        size: 161983327,
        sha256:
            '1e9cbe0498c335b00c9c0f63dc683be7ed2b6cf0c5673df1f5c7715d6909936e',
      ),
    ),
    'SM8850': _SenseVoicePackage(
      soc: 'SM8850',
      directoryName:
          'sherpa-onnx-qnn-SM8850-binary-10-seconds-sense-voice-zh-en-ja-ko-yue-2024-07-17-int8',
      asset: _SpeechAsset(
        fileName:
            'sherpa-onnx-qnn-SM8850-binary-10-seconds-sense-voice-zh-en-ja-ko-yue-2024-07-17-int8.tar.bz2',
        url:
            'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models-qnn-binary/'
            'sherpa-onnx-qnn-SM8850-binary-10-seconds-sense-voice-zh-en-ja-ko-yue-2024-07-17-int8.tar.bz2',
        size: 162023574,
        sha256:
            'ecbc1ffba39f8e23582b79a199d12e8455425a22ef7b6b18c535ce25fcff2d64',
      ),
    ),
  };

  final AudioRecorder _recorder = AudioRecorder();
  final StreamController<String> _recognitionController =
      StreamController<String>.broadcast();
  final StreamController<SenseVoiceRecognition> _recognitionDetailsController =
      StreamController<SenseVoiceRecognition>.broadcast();
  StreamSubscription<Uint8List>? _recordingSubscription;
  Timer? _recordingTimeout;
  Future<void>? _startOperation;
  Future<String?>? _stopOperation;
  BytesBuilder? _recordedAudio;
  HttpClientRequest? _downloadRequest;
  bool _runtimeLoaded = false;
  String? _deviceSoc;
  bool _cancelRequested = false;
  bool _speechDetected = false;
  bool _vadStopping = false;
  bool _recordingStarted = false;
  int _voicedMilliseconds = 0;
  int _silenceMilliseconds = 0;
  double _noiseFloor = 0.004;

  bool initialized = false;
  bool asrReady = false;
  bool downloading = false;
  bool extracting = false;
  bool listening = false;
  bool recognizing = false;
  bool hardwareAccelerationVerified = false;
  int downloadedBytes = 0;
  int totalDownloadBytes = 0;
  String operationLabel = '';
  String? lastError;
  SenseVoiceRecognition? lastRecognition;

  bool get supported => !kIsWeb && Platform.isAndroid;
  double get downloadProgress => totalDownloadBytes <= 0
      ? 0
      : (downloadedBytes / totalDownloadBytes).clamp(0, 1);
  Stream<String> get recognitionResults => _recognitionController.stream;
  Stream<SenseVoiceRecognition> get recognitionDetails =>
      _recognitionDetailsController.stream;

  Future<Directory> _rootDirectory() async {
    final support = await getApplicationSupportDirectory();
    final root = Directory(
      '${support.path}${Platform.pathSeparator}sherpa-speech',
    );
    if (!await root.exists()) await root.create(recursive: true);
    return root;
  }

  _SenseVoicePackage get _asrPackage {
    final value = _senseVoicePackages[_deviceSoc];
    if (value == null) {
      throw UnsupportedError(
        'SenseVoice QNN requires SM8750 or SM8850 HTP v81; '
        'detected ${_deviceSoc ?? 'unknown SoC'}',
      );
    }
    return value;
  }

  Future<Directory> _asrDirectory() async => Directory(
    '${(await _rootDirectory()).path}${Platform.pathSeparator}'
    '${_asrPackage.directoryName}',
  );

  Future<void> initialize() async {
    if (initialized || !supported) {
      initialized = true;
      return;
    }
    try {
      final capabilities = await _runtimeChannel
          .invokeMapMethod<Object?, Object?>('capabilities');
      _deviceSoc = capabilities?['soc']?.toString().trim().toUpperCase();
      _asrPackage;
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
    final package = _asrPackage;
    final directory = await _asrDirectory();
    final model = File('${directory.path}${Platform.pathSeparator}model.bin');
    final tokens = File('${directory.path}${Platform.pathSeparator}tokens.txt');
    final manifest = File(
      '${directory.path}${Platform.pathSeparator}$_manifestName',
    );
    if (!await model.exists() ||
        !await tokens.exists() ||
        !await manifest.exists()) {
      return false;
    }
    final value = jsonDecode(await manifest.readAsString());
    return value is Map<String, dynamic> &&
        value['schemaVersion'] == 1 &&
        value['packageId'] == package.directoryName &&
        value['archiveSha256'] == package.asset.sha256 &&
        value['targetSoc'] == package.soc &&
        value['htpArchitecture'] == 'v81' &&
        value['modelBytes'] == await model.length() &&
        value['tokensBytes'] == await tokens.length();
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
    final package = _asrPackage;
    await _downloadAndInstallArchive(
      package.asset,
      expectedDirectoryName: package.directoryName,
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
        final model = File(
          '${extracted.path}${Platform.pathSeparator}model.bin',
        );
        final tokens = File(
          '${extracted.path}${Platform.pathSeparator}tokens.txt',
        );
        if (!await model.exists() || !await tokens.exists()) {
          throw const FormatException('SenseVoice QNN context 文件不完整');
        }
        final package = _asrPackage;
        await File(
          '${extracted.path}${Platform.pathSeparator}$_manifestName',
        ).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'schemaVersion': 1,
            'packageId': package.directoryName,
            'archiveSha256': package.asset.sha256,
            'targetSoc': package.soc,
            'htpArchitecture': 'v81',
            'maxAudioSeconds': 10,
            'modelBytes': await model.length(),
            'tokensBytes': await tokens.length(),
          }),
          flush: true,
        );
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
    await _releaseRuntime();
    final directory = await _asrDirectory();
    if (await directory.exists()) await directory.delete(recursive: true);
    asrReady = false;
    notifyListeners();
  }

  Future<void> startListening() {
    final activeStart = _startOperation;
    if (activeStart != null) return activeStart;
    if (listening || recognizing || _stopOperation != null) {
      return Future.value();
    }
    listening = true;
    lastError = null;
    notifyListeners();
    final operation = _startListeningOnce();
    _startOperation = operation;
    return operation.whenComplete(() {
      if (identical(_startOperation, operation)) _startOperation = null;
    });
  }

  Future<void> _startListeningOnce() async {
    try {
      await initialize();
      if (!asrReady) throw StateError('请先下载 SenseVoice 离线识别模型');
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
          sampleRate: _sampleRate,
          numChannels: 1,
        ),
      );
      _recordingStarted = true;
      _recordingSubscription = stream.listen(
        (chunk) {
          final recorded = _recordedAudio;
          if (recorded == null || _vadStopping) return;
          final remaining = _maxPcmBytes - recorded.length;
          if (remaining <= 0) {
            _vadStopping = true;
            _stopListeningInBackground();
            return;
          }
          final acceptedLength = math.min(chunk.length, remaining) & ~1;
          if (acceptedLength > 0) {
            final accepted = acceptedLength == chunk.length
                ? chunk
                : Uint8List.sublistView(chunk, 0, acceptedLength);
            recorded.add(accepted);
            _updateVoiceActivity(accepted);
          }
          if (recorded.length >= _maxPcmBytes && !_vadStopping) {
            _vadStopping = true;
            _stopListeningInBackground();
          }
        },
        onError: (Object error) {
          lastError = error.toString();
          if (listening) {
            unawaited(stopListening().catchError((_) => null));
          } else {
            notifyListeners();
          }
        },
        cancelOnError: true,
      );
      if (listening) {
        _recordingTimeout = Timer(
          const Duration(seconds: _maxAudioSeconds),
          _stopListeningInBackground,
        );
      }
    } catch (error) {
      listening = false;
      _vadStopping = false;
      _recordedAudio = null;
      lastError = error.toString();
      notifyListeners();
      rethrow;
    }
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
    final duration = (sampleCount * 1000 / _sampleRate)
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
      _stopListeningInBackground();
    }
  }

  void _stopListeningInBackground() {
    unawaited(
      stopListening().catchError((Object error) {
        lastError = error.toString();
        notifyListeners();
        return null;
      }),
    );
  }

  Future<String?> stopListening() {
    final activeStop = _stopOperation;
    if (activeStop != null) return activeStop;
    if (!listening) return Future.value(null);
    listening = false;
    _vadStopping = true;
    _recordingTimeout?.cancel();
    _recordingTimeout = null;
    notifyListeners();
    final operation = _stopListeningOnce(_startOperation);
    _stopOperation = operation;
    return operation.whenComplete(() {
      if (identical(_stopOperation, operation)) _stopOperation = null;
    });
  }

  Future<String?> _stopListeningOnce(Future<void>? pendingStart) async {
    if (pendingStart != null) {
      try {
        await pendingStart;
      } catch (_) {
        return null;
      }
    }
    Object? recorderError;
    try {
      if (_recordingStarted) await _recorder.stop();
    } catch (error) {
      recorderError = error;
    } finally {
      _recordingStarted = false;
      await _recordingSubscription?.cancel();
      _recordingSubscription = null;
      _vadStopping = false;
    }
    final recordedBytes = _recordedAudio?.takeBytes() ?? Uint8List(0);
    _recordedAudio = null;
    if (recorderError != null) {
      lastError = recorderError.toString();
      notifyListeners();
      throw StateError('停止麦克风录音失败：$recorderError');
    }
    if (recordedBytes.isEmpty) {
      notifyListeners();
      return null;
    }
    final bytes = recordedBytes.length <= _maxPcmBytes
        ? recordedBytes
        : Uint8List.sublistView(recordedBytes, 0, _maxPcmBytes);
    recognizing = true;
    notifyListeners();
    try {
      final directory = await _asrDirectory();
      if (!_runtimeLoaded) {
        await _runtimeChannel.invokeMethod<void>('load', {
          'modelRoot': directory.path,
        });
        _runtimeLoaded = true;
      }
      final value = await _runtimeChannel.invokeMapMethod<dynamic, dynamic>(
        'recognize',
        {'modelRoot': directory.path, 'pcm16le': bytes},
      );
      if (value == null) throw StateError('SenseVoice QNN 未返回识别结果');
      final recognition = SenseVoiceRecognition.fromMap(value);
      hardwareAccelerationVerified =
          value['hardwareAccelerated'] == true &&
          value['provider'] == 'QNN_HTP';
      if (!hardwareAccelerationVerified) {
        throw StateError('SenseVoice 未能验证 QNN HTP 执行，拒绝 CPU 回退结果');
      }
      lastRecognition = recognition;
      _recognitionDetailsController.add(recognition);
      if (recognition.text.isNotEmpty) {
        _recognitionController.add(recognition.text);
      }
      return recognition.text;
    } catch (error) {
      hardwareAccelerationVerified = false;
      lastError = error.toString();
      rethrow;
    } finally {
      await _releaseRuntime();
      recognizing = false;
      notifyListeners();
    }
  }

  Future<void> _releaseRuntime() async {
    if (!_runtimeLoaded) return;
    _runtimeLoaded = false;
    try {
      await _runtimeChannel.invokeMethod<void>('release');
    } catch (_) {}
  }

  @override
  void dispose() {
    _recordingTimeout?.cancel();
    if (_recordingStarted) unawaited(_recorder.stop());
    _recordingSubscription?.cancel();
    unawaited(_releaseRuntime());
    _recognitionController.close();
    _recognitionDetailsController.close();
    _recorder.dispose();
    super.dispose();
  }
}

class _SpeechDownloadCancelled implements Exception {
  const _SpeechDownloadCancelled();
}
