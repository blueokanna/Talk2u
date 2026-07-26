import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:audioplayers/audioplayers.dart';
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
  final bool archive;

  const _SpeechAsset({
    required this.fileName,
    required this.url,
    required this.size,
    required this.sha256,
    this.archive = false,
  });

  List<String> get downloadUrls => [
    url,
    'https://ghfast.top/$url',
    'https://gh-proxy.com/$url',
  ];
}

class SherpaSpeechService extends ChangeNotifier {
  SherpaSpeechService._() {
    _playerCompleteSubscription = _player.onPlayerComplete.listen((_) {
      speaking = false;
      playbackAmplitude = 0;
      playbackProgress = 1;
      notifyListeners();
    });
    _playerDurationSubscription = _player.onDurationChanged.listen((duration) {
      _playbackDuration = duration;
    });
    _playerPositionSubscription = _player.onPositionChanged.listen((position) {
      final frame = position.inMilliseconds ~/ amplitudeFrameMilliseconds;
      final nextAmplitude = frame >= 0 && frame < _amplitudeEnvelope.length
          ? _amplitudeEnvelope[frame]
          : 0.0;
      final durationMs = _playbackDuration.inMilliseconds;
      playbackProgress = durationMs <= 0
          ? 0
          : (position.inMilliseconds / durationMs).clamp(0, 1);
      playbackAmplitude = nextAmplitude;
      notifyListeners();
    });
  }

  static final instance = SherpaSpeechService._();

  static const engineName = 'sherpa-onnx 端侧语音';
  static const engineLicense = 'Apache-2.0';
  static const asrModelName = 'SenseVoice 2025 INT8';
  static const ttsModelName = 'Matcha 中英双语';
  static const amplitudeFrameMilliseconds = 20;

  static const _asrDirectoryName =
      'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09';
  static const _ttsDirectoryName = 'matcha-icefall-zh-en';
  static const _vocoderFileName = 'vocos-16khz-univ.onnx';

  static const _asrAsset = _SpeechAsset(
    fileName: '$_asrDirectoryName.tar.bz2',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
        '$_asrDirectoryName.tar.bz2',
    size: 165783878,
    sha256: '7305f7905bfcf77fa0b39388a313f3da35c68d971661a65475b56fb2162c8e63',
    archive: true,
  );

  static const _ttsAsset = _SpeechAsset(
    fileName: '$_ttsDirectoryName.tar.bz2',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/'
        '$_ttsDirectoryName.tar.bz2',
    size: 79033838,
    sha256: '271b804af570400d3bcdcb53bf6e53cc9f75180ee763b9f13eb5eaf2b0d086ef',
    archive: true,
  );

  static const _vocoderAsset = _SpeechAsset(
    fileName: _vocoderFileName,
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
        'vocoder-models/$_vocoderFileName',
    size: 53882848,
    sha256: 'b599142a1fb8ff03de3e84ac35ff537c619e56f4267a6fe894851a42844acf9e',
  );

  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  final StreamController<String> _recognitionController =
      StreamController<String>.broadcast();
  StreamSubscription<void>? _playerCompleteSubscription;
  StreamSubscription<Duration>? _playerDurationSubscription;
  StreamSubscription<Duration>? _playerPositionSubscription;
  StreamSubscription<Uint8List>? _recordingSubscription;
  Timer? _recordingTimeout;
  BytesBuilder? _recordedAudio;
  HttpClientRequest? _downloadRequest;
  bool _cancelRequested = false;

  bool initialized = false;
  bool asrReady = false;
  bool ttsReady = false;
  bool downloading = false;
  bool extracting = false;
  bool listening = false;
  bool recognizing = false;
  bool speaking = false;
  double playbackAmplitude = 0;
  double playbackProgress = 0;
  Duration _playbackDuration = Duration.zero;
  List<double> _amplitudeEnvelope = const [];
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

  Future<Directory> _ttsDirectory() async => Directory(
    '${(await _rootDirectory()).path}${Platform.pathSeparator}$_ttsDirectoryName',
  );

  Future<File> _vocoderFile() async => File(
    '${(await _rootDirectory()).path}${Platform.pathSeparator}$_vocoderFileName',
  );

  Future<void> initialize() async {
    if (initialized || !supported) {
      initialized = true;
      return;
    }
    try {
      asrReady = await _validateAsr();
      ttsReady = await _validateTts();
      lastError = null;
    } catch (error) {
      lastError = '无法检查 sherpa-onnx 语音模型: $error';
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

  Future<bool> _validateTts() async {
    final directory = await _ttsDirectory();
    return await File(
          '${directory.path}${Platform.pathSeparator}model-steps-3.onnx',
        ).exists() &&
        await File(
          '${directory.path}${Platform.pathSeparator}tokens.txt',
        ).exists() &&
        await File(
          '${directory.path}${Platform.pathSeparator}lexicon.txt',
        ).exists() &&
        await (await _vocoderFile()).exists();
  }

  Future<void> downloadAsr() async {
    if (!supported) throw UnsupportedError('当前平台不支持 sherpa-onnx 语音');
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

  Future<void> downloadTts() async {
    if (!supported) throw UnsupportedError('当前平台不支持 sherpa-onnx 语音');
    if (downloading || extracting) return;
    await _downloadAndInstallArchive(
      _ttsAsset,
      expectedDirectoryName: _ttsDirectoryName,
      label: '正在下载 Matcha',
    );
    if (_cancelRequested) return;
    try {
      await _downloadAsset(_vocoderAsset, label: '正在下载 Matcha 声码器');
    } on _SpeechDownloadCancelled {
      return;
    }
    ttsReady = await _validateTts();
    if (!ttsReady) throw const FormatException('Matcha 模型文件不完整');
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
              existingBytes = 0;
              downloadedBytes = 0;
            }
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
      operationLabel = '正在安装语音模型';
      notifyListeners();
      try {
        await Isolate.run(() => extractFileToDisk(archive.path, staging.path));
        final extracted = Directory(
          '${staging.path}${Platform.pathSeparator}$expectedDirectoryName',
        );
        if (!await extracted.exists()) {
          throw const FormatException('语音模型归档目录无效');
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
    _downloadRequest?.abort(const HttpException('用户取消语音模型下载'));
  }

  Future<void> deleteAsr() async {
    if (listening || recognizing) throw StateError('请先停止语音识别');
    final directory = await _asrDirectory();
    if (await directory.exists()) await directory.delete(recursive: true);
    asrReady = false;
    notifyListeners();
  }

  Future<void> deleteTts() async {
    if (speaking) await stopSpeaking();
    final directory = await _ttsDirectory();
    final vocoder = await _vocoderFile();
    if (await directory.exists()) await directory.delete(recursive: true);
    if (await vocoder.exists()) await vocoder.delete();
    ttsReady = false;
    notifyListeners();
  }

  Future<void> startListening() async {
    await initialize();
    if (!asrReady) throw StateError('请先下载 SenseVoice 离线识别模型');
    if (listening || recognizing) return;
    if (!await _recorder.hasPermission()) {
      throw StateError('麦克风权限未授予');
    }
    _recordedAudio = BytesBuilder(copy: false);
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    _recordingSubscription = stream.listen(
      (chunk) => _recordedAudio?.add(chunk),
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

  Future<String?> stopListening() async {
    if (!listening) return null;
    _recordingTimeout?.cancel();
    _recordingTimeout = null;
    await _recorder.stop();
    await _recordingSubscription?.cancel();
    _recordingSubscription = null;
    listening = false;
    final bytes = _recordedAudio?.takeBytes() ?? Uint8List(0);
    _recordedAudio = null;
    if (bytes.isEmpty) {
      notifyListeners();
      return null;
    }

    recognizing = true;
    notifyListeners();
    try {
      final directory = await _asrDirectory();
      final text = await Isolate.run(
        () => _recognizeSenseVoice(
          bytes,
          '${directory.path}${Platform.pathSeparator}model.int8.onnx',
          '${directory.path}${Platform.pathSeparator}tokens.txt',
        ),
      );
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

  Future<void> speak(String text) async {
    await initialize();
    if (!ttsReady) throw StateError('请先下载 Matcha 离线语音模型');
    if (text.trim().isEmpty) return;
    final directory = await _ttsDirectory();
    final vocoder = await _vocoderFile();
    final cache = await getTemporaryDirectory();
    final output = File(
      '${cache.path}${Platform.pathSeparator}talk2u-sherpa-tts.wav',
    );
    speaking = false;
    playbackAmplitude = 0;
    playbackProgress = 0;
    _playbackDuration = Duration.zero;
    lastError = null;
    notifyListeners();
    try {
      _amplitudeEnvelope = await Isolate.run(
        () => _generateMatcha(text, directory.path, vocoder.path, output.path),
      );
      speaking = true;
      notifyListeners();
      await _player.play(DeviceFileSource(output.path));
    } catch (error) {
      speaking = false;
      lastError = error.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> stopSpeaking() async {
    await _player.stop();
    speaking = false;
    playbackAmplitude = 0;
    playbackProgress = 0;
    _amplitudeEnvelope = const [];
    notifyListeners();
  }

  @override
  void dispose() {
    _recordingTimeout?.cancel();
    _recordingSubscription?.cancel();
    _playerCompleteSubscription?.cancel();
    _playerDurationSubscription?.cancel();
    _playerPositionSubscription?.cancel();
    _recognitionController.close();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }
}

class _SpeechDownloadCancelled implements Exception {
  const _SpeechDownloadCancelled();
}

String _recognizeSenseVoice(Uint8List pcm, String model, String tokens) {
  sherpa.initBindings();
  final samples = Float32List(pcm.length ~/ 2);
  final data = ByteData.sublistView(pcm);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
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
    recognizer.free();
  }
}

List<double> _generateMatcha(
  String text,
  String modelDirectory,
  String vocoder,
  String output,
) {
  sherpa.initBindings();
  String file(String name) => '$modelDirectory${Platform.pathSeparator}$name';
  final tts = sherpa.OfflineTts(
    sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        matcha: sherpa.OfflineTtsMatchaModelConfig(
          acousticModel: file('model-steps-3.onnx'),
          vocoder: vocoder,
          lexicon: file('lexicon.txt'),
          tokens: file('tokens.txt'),
          dataDir: file('espeak-ng-data'),
        ),
        numThreads: 2,
        debug: false,
      ),
      ruleFsts:
          [file('phone-zh.fst'), file('date-zh.fst'), file('number-zh.fst')]
              .map(File.new)
              .where((item) => item.existsSync())
              .map((item) => item.path)
              .join(','),
      maxNumSenetences: 1,
    ),
  );
  try {
    final audio = tts.generate(text: text, sid: 0, speed: 1.0);
    if (audio.samples.isEmpty || audio.sampleRate <= 0) {
      throw StateError('Matcha 没有生成音频');
    }
    if (!sherpa.writeWave(
      filename: output,
      samples: audio.samples,
      sampleRate: audio.sampleRate,
    )) {
      throw FileSystemException('无法写入离线 TTS 音频', output);
    }
    return buildPcmAmplitudeEnvelope(
      audio.samples,
      audio.sampleRate,
      frameMilliseconds: SherpaSpeechService.amplitudeFrameMilliseconds,
    );
  } finally {
    tts.free();
  }
}

@visibleForTesting
List<double> buildPcmAmplitudeEnvelope(
  Float32List samples,
  int sampleRate, {
  int frameMilliseconds = 20,
}) {
  if (samples.isEmpty || sampleRate <= 0 || frameMilliseconds <= 0) {
    return const [];
  }
  final frameSamples = math.max(1, sampleRate * frameMilliseconds ~/ 1000);
  final output = <double>[];
  for (var start = 0; start < samples.length; start += frameSamples) {
    final end = math.min(start + frameSamples, samples.length);
    var sumSquares = 0.0;
    for (var index = start; index < end; index++) {
      final sample = samples[index].clamp(-1.0, 1.0).toDouble();
      sumSquares += sample * sample;
    }
    final rms = math.sqrt(sumSquares / (end - start));
    output.add(
      ((rms - 0.015).clamp(0.0, 1.0) * 4.5).clamp(0.0, 1.0).toDouble(),
    );
  }
  return List.unmodifiable(output);
}
