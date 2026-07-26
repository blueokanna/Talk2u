import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:dart_sentencepiece_tokenizer/dart_sentencepiece_tokenizer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

@immutable
class MossVoice {
  final String id;
  final String label;
  final String locale;
  final String gender;

  const MossVoice({
    required this.id,
    required this.label,
    required this.locale,
    required this.gender,
  });

  String get displayLabel {
    final genderLabel = gender == 'male' ? '男声' : '女声';
    return '$label · $genderLabel';
  }
}

class _MossAsset {
  final String repository;
  final String revision;
  final String directory;
  final String fileName;
  final int size;
  final String sha256;

  const _MossAsset({
    required this.repository,
    required this.revision,
    required this.directory,
    required this.fileName,
    required this.size,
    required this.sha256,
  });

  List<String> get urls => [
    'https://huggingface.co/$repository/resolve/$revision/$fileName',
    'https://hf-mirror.com/$repository/resolve/$revision/$fileName',
  ];
}

class _MossAudio {
  final File file;
  final List<double> amplitudeEnvelope;

  const _MossAudio(this.file, this.amplitudeEnvelope);
}

class _MossCancelled implements Exception {
  const _MossCancelled();
}

class _MossSynthesisOutcome {
  final _MossAudio? audio;
  final Object? error;
  final StackTrace? stackTrace;

  const _MossSynthesisOutcome.audio(this.audio)
    : error = null,
      stackTrace = null;

  const _MossSynthesisOutcome.error(this.error, this.stackTrace) : audio = null;
}

class _MossPendingAudio {
  late final Future<_MossSynthesisOutcome> future;
  bool completed = false;

  _MossPendingAudio(Future<_MossAudio> source) {
    future = source
        .then(
          (audio) => _MossSynthesisOutcome.audio(audio),
          onError: (Object error, StackTrace stackTrace) =>
              _MossSynthesisOutcome.error(error, stackTrace),
        )
        .whenComplete(() => completed = true);
  }
}

class MossTtsService extends ChangeNotifier {
  MossTtsService._() {
    _completeSubscription = _player.onPlayerComplete.listen((_) {
      final completer = _playbackCompleter;
      if (completer != null && !completer.isCompleted) completer.complete();
    });
    _durationSubscription = _player.onDurationChanged.listen((duration) {
      _playbackDuration = duration;
    });
    _positionSubscription = _player.onPositionChanged.listen((position) {
      _positionAnchor = position;
      _playbackClock.reset();
      if (!_playbackClock.isRunning) _playbackClock.start();
      _updateLipSync();
    });
  }

  static final instance = MossTtsService._();
  static const engineName = 'MOSS-TTS-Nano ONNX';
  static const engineLicense = 'Apache-2.0';
  static const modelName = 'MOSS-TTS-Nano 100M ONNX';
  static const amplitudeFrameMilliseconds = 20;
  static const modelBytes = 717414286;
  static const _channel = MethodChannel('talk2u/moss_tts');
  static const _rootName = 'moss-tts-nano';
  static const _ttsDirectoryName = 'MOSS-TTS-Nano-100M-ONNX';
  static const _codecDirectoryName = 'MOSS-Audio-Tokenizer-Nano-ONNX';
  static const _markerName = '.installed.json';
  static const _preferencesName = 'preferences.json';
  static const _ttsRevision = 'f52645cb467506d8e18e746ddd59482685b74e58';
  static const _codecRevision = 'ceff0d0749bfb3fa2d61149794ec6feef0d1e1ae';

  static const voices = <MossVoice>[
    MossVoice(id: 'Junhao', label: '君豪', locale: 'zh-CN', gender: 'male'),
    MossVoice(id: 'Zhiming', label: '志明·京味', locale: 'zh-CN', gender: 'male'),
    MossVoice(id: 'Weiguo', label: '卫国·说书', locale: 'zh-CN', gender: 'male'),
    MossVoice(id: 'Xiaoyu', label: '小雨', locale: 'zh-CN', gender: 'female'),
    MossVoice(id: 'Yuewen', label: '悦雯·机车', locale: 'zh-CN', gender: 'female'),
    MossVoice(
      id: 'Lingyu',
      label: '凌语·深夜电台',
      locale: 'zh-CN',
      gender: 'female',
    ),
    MossVoice(id: 'Trump', label: 'Trump', locale: 'en-US', gender: 'male'),
    MossVoice(id: 'Ava', label: 'Ava', locale: 'en-US', gender: 'female'),
    MossVoice(id: 'Bella', label: 'Bella', locale: 'en-US', gender: 'female'),
    MossVoice(id: 'Adam', label: 'Adam', locale: 'en-US', gender: 'male'),
    MossVoice(id: 'Nathan', label: 'Nathan', locale: 'en-US', gender: 'male'),
    MossVoice(id: 'Soyo', label: 'Soyo', locale: 'ja-JP', gender: 'female'),
    MossVoice(id: 'Saki', label: 'Saki', locale: 'ja-JP', gender: 'female'),
    MossVoice(id: 'Mortis', label: 'Mortis', locale: 'ja-JP', gender: 'female'),
    MossVoice(id: 'Umiri', label: 'Umiri', locale: 'ja-JP', gender: 'female'),
    MossVoice(id: 'Mei', label: 'Mei', locale: 'ja-JP', gender: 'female'),
    MossVoice(id: 'Anon', label: 'Anon', locale: 'ja-JP', gender: 'female'),
    MossVoice(id: 'Arisa', label: 'Arisa', locale: 'ja-JP', gender: 'female'),
  ];

  static const _assets = <_MossAsset>[
    _MossAsset(
      repository: 'OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX',
      revision: _ttsRevision,
      directory: _ttsDirectoryName,
      fileName: 'browser_poc_manifest.json',
      size: 503354,
      sha256:
          '097d80e993dc29f0bae427590b4f77084a161cb578b50d82c29f455d5faa9eee',
    ),
    _MossAsset(
      repository: 'OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX',
      revision: _ttsRevision,
      directory: _ttsDirectoryName,
      fileName: 'tts_browser_onnx_meta.json',
      size: 4487,
      sha256:
          '3edf25232dcd0af3d061c837e9a968a39e2f8592e06777d740503c4f2244f95c',
    ),
    _MossAsset(
      repository: 'OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX',
      revision: _ttsRevision,
      directory: _ttsDirectoryName,
      fileName: 'tokenizer.model',
      size: 470897,
      sha256:
          'c353ee1479b536bf414c1b247f5542b6607fb8ae91320e5af1781fee200fddff',
    ),
    _MossAsset(
      repository: 'OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX',
      revision: _ttsRevision,
      directory: _ttsDirectoryName,
      fileName: 'moss_tts_prefill.onnx',
      size: 283305,
      sha256:
          'd56126dcd0574c2f15d98fc6b35eda68d0386b5bd9c5e38e28548d6f2ea8f3db',
    ),
    _MossAsset(
      repository: 'OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX',
      revision: _ttsRevision,
      directory: _ttsDirectoryName,
      fileName: 'moss_tts_decode_step.onnx',
      size: 291483,
      sha256:
          '698cbc2fc1c2feca16e5895614ed52bbb32ded10f236c076f477b2e69abf32d8',
    ),
    _MossAsset(
      repository: 'OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX',
      revision: _ttsRevision,
      directory: _ttsDirectoryName,
      fileName: 'moss_tts_local_fixed_sampled_frame.onnx',
      size: 471262,
      sha256:
          '40cdb00efc171c450cf91468e01429caa41b0252222cd308e978f58fe354afa8',
    ),
    _MossAsset(
      repository: 'OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX',
      revision: _ttsRevision,
      directory: _ttsDirectoryName,
      fileName: 'moss_tts_global_shared.data',
      size: 440813568,
      sha256:
          'bce8312c3df6a44545302cae229b61054fe0672e0b252ba59cba47adeed831dc',
    ),
    _MossAsset(
      repository: 'OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX',
      revision: _ttsRevision,
      directory: _ttsDirectoryName,
      fileName: 'moss_tts_local_shared.data',
      size: 229678080,
      sha256:
          'bae7782032c0fb12490ab42afe009f87ae6c75a0f0596fc7b5c08e4d5ee93916',
    ),
    _MossAsset(
      repository: 'OpenMOSS-Team/MOSS-Audio-Tokenizer-Nano-ONNX',
      revision: _codecRevision,
      directory: _codecDirectoryName,
      fileName: 'codec_browser_onnx_meta.json',
      size: 17036,
      sha256:
          '3e291c883bb7d11ff2fe8e964e3e495519760358859f35c951254c7741592731',
    ),
    _MossAsset(
      repository: 'OpenMOSS-Team/MOSS-Audio-Tokenizer-Nano-ONNX',
      revision: _codecRevision,
      directory: _codecDirectoryName,
      fileName: 'moss_audio_tokenizer_decode_full.onnx',
      size: 681902,
      sha256:
          '0fbbafe3fd4afa2a019af5c5ced204af6e2d1db044fa40f021525d2aee95b4ac',
    ),
    _MossAsset(
      repository: 'OpenMOSS-Team/MOSS-Audio-Tokenizer-Nano-ONNX',
      revision: _codecRevision,
      directory: _codecDirectoryName,
      fileName: 'moss_audio_tokenizer_decode_shared.data',
      size: 44198912,
      sha256:
          'e69d52e0f4e84ca27850557ee54face46632d3a5a16c89bd246c7c408466dcad',
    ),
  ];

  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<void>? _completeSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  Completer<void>? _playbackCompleter;
  Completer<void>? _startupCompleter;
  Timer? _lipSyncTimer;
  final Stopwatch _playbackClock = Stopwatch();
  HttpClientRequest? _downloadRequest;
  Duration _playbackDuration = Duration.zero;
  Duration _positionAnchor = Duration.zero;
  List<double> _amplitudeEnvelope = const [];
  File? _currentOutput;
  final Set<File> _pendingOutputs = {};
  double _segmentProgressStart = 0;
  double _segmentProgressEnd = 1;
  bool _cancelDownload = false;
  int _operation = 0;
  String _voiceId = voices.first.id;

  bool initialized = false;
  bool runtimeReady = false;
  bool ready = false;
  bool downloading = false;
  bool generating = false;
  bool speaking = false;
  int downloadedBytes = 0;
  int totalDownloadBytes = modelBytes;
  double playbackAmplitude = 0;
  double playbackProgress = 0;
  String operationLabel = '';
  String? lastError;
  List<String> runtimeProviders = const ['CPU'];
  String activeProvider = 'CPU';
  bool _providerMeasured = false;

  bool get supported => !kIsWeb && Platform.isAndroid;
  double get downloadProgress => totalDownloadBytes <= 0
      ? 0
      : (downloadedBytes / totalDownloadBytes).clamp(0, 1);
  String get voiceId => _voiceId;
  String get accelerationLabel {
    if (activeProvider == 'QNN') return 'Qualcomm QNN HTP NPU';
    if (activeProvider == 'NNAPI') return 'NNAPI GPU/NPU';
    if (_providerMeasured && runtimeProviders.contains('NNAPI')) {
      return 'NNAPI 可用 · 本次 CPU/NEON 回退';
    }
    if (runtimeProviders.contains('NNAPI')) {
      return 'NNAPI GPU/NPU 优先 · CPU/NEON 回退';
    }
    return 'ARM64 CPU/NEON';
  }

  MossVoice get selectedVoice => voices.firstWhere(
    (voice) => voice.id == _voiceId,
    orElse: () => voices.first,
  );

  Future<Directory> _rootDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}${Platform.pathSeparator}$_rootName');
  }

  Future<File> _markerFile() async => File(
    '${(await _rootDirectory()).path}${Platform.pathSeparator}$_markerName',
  );

  Future<File> _preferencesFile() async => File(
    '${(await _rootDirectory()).path}${Platform.pathSeparator}$_preferencesName',
  );

  Future<File> _assetFile(_MossAsset asset) async => File(
    '${(await _rootDirectory()).path}${Platform.pathSeparator}${asset.directory}'
    '${Platform.pathSeparator}${asset.fileName}',
  );

  Future<void> initialize() async {
    if (initialized || !supported) {
      initialized = true;
      return;
    }
    try {
      runtimeReady = await _channel.invokeMethod<bool>('probe') == true;
      if (!runtimeReady) {
        throw StateError('MOSS-TTS-Nano ONNX Runtime 无法加载');
      }
      try {
        runtimeProviders =
            await _channel.invokeListMethod<String>('providers') ??
            const ['CPU'];
      } on PlatformException {
        runtimeProviders = const ['CPU'];
      }
      await _loadPreferences();
      ready = await _validateInstalledModel();
      await _cleanupAudioCache();
      await _deleteLegacyKokoro();
      lastError = null;
    } catch (error) {
      lastError = '无法检查 MOSS-TTS-Nano 模型: $error';
    } finally {
      initialized = true;
      notifyListeners();
    }
  }

  Future<bool> _validateInstalledModel() async {
    final marker = await _markerFile();
    if (!await marker.exists()) return false;
    try {
      final value = jsonDecode(await marker.readAsString());
      if (value is! Map ||
          value['ttsRevision'] != _ttsRevision ||
          value['codecRevision'] != _codecRevision) {
        return false;
      }
      for (final asset in _assets) {
        final file = await _assetFile(asset);
        if (!await file.exists() || await file.length() != asset.size) {
          return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> downloadModel() async {
    await initialize();
    if (!supported) throw UnsupportedError('当前平台暂不支持 MOSS-TTS-Nano 端侧 ONNX');
    if (!runtimeReady) throw StateError('MOSS-TTS-Nano ONNX Runtime 无法加载');
    if (downloading) return;
    _cancelDownload = false;
    downloading = true;
    downloadedBytes = 0;
    totalDownloadBytes = modelBytes;
    operationLabel = '正在检查 MOSS-TTS-Nano';
    lastError = null;
    notifyListeners();
    try {
      final validAssets = <_MossAsset>{};
      var reusableBytes = 0;
      var partialBytes = 0;
      for (final asset in _assets) {
        final file = await _assetFile(asset);
        if (await file.exists() && await file.length() == asset.size) {
          if (await fileSha256(file.path) == asset.sha256) {
            validAssets.add(asset);
            reusableBytes += asset.size;
          } else {
            await file.delete();
          }
        }
        final partial = File('${file.path}.part');
        if (!validAssets.contains(asset) && await partial.exists()) {
          partialBytes += math.min(await partial.length(), asset.size);
        }
      }
      downloadedBytes = reusableBytes;
      notifyListeners();
      final available =
          await _channel.invokeMethod<int>('availableStorageBytes') ?? 0;
      final required = modelBytes - reusableBytes - partialBytes + 268435456;
      if (available < required) {
        throw FileSystemException(
          '可用存储空间不足，至少还需要 ${_formatBytes(required)}，当前 ${_formatBytes(available)}',
        );
      }
      for (final asset in _assets) {
        if (_cancelDownload) return;
        if (validAssets.contains(asset)) continue;
        await _downloadAsset(asset);
      }
      final marker = await _markerFile();
      await marker.parent.create(recursive: true);
      await marker.writeAsString(
        jsonEncode({
          'ttsRevision': _ttsRevision,
          'codecRevision': _codecRevision,
          'bytes': modelBytes,
        }),
        flush: true,
      );
      ready = await _validateInstalledModel();
      if (!ready) throw const FormatException('MOSS-TTS-Nano 模型文件不完整');
    } catch (error) {
      if (!_cancelDownload) {
        lastError = error.toString();
        rethrow;
      }
    } finally {
      downloading = false;
      _downloadRequest = null;
      notifyListeners();
    }
  }

  Future<void> _downloadAsset(_MossAsset asset) async {
    final destination = await _assetFile(asset);
    await destination.parent.create(recursive: true);
    final partial = File('${destination.path}.part');
    final completedBefore = downloadedBytes;
    Object? lastFailure;
    for (var sourceIndex = 0; sourceIndex < asset.urls.length; sourceIndex++) {
      if (_cancelDownload) return;
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20);
      IOSink? sink;
      try {
        var existing = await partial.exists() ? await partial.length() : 0;
        if (existing > asset.size) {
          await partial.delete();
          existing = 0;
        }
        if (existing == asset.size) {
          operationLabel = '正在校验 ${asset.fileName}';
          downloadedBytes = completedBefore + existing;
          notifyListeners();
          if (await fileSha256(partial.path) == asset.sha256) {
            if (await destination.exists()) await destination.delete();
            await partial.rename(destination.path);
            return;
          }
          await partial.delete();
          existing = 0;
        }
        downloadedBytes = completedBefore + existing;
        operationLabel = '正在下载 ${asset.fileName}';
        notifyListeners();
        final request = await client
            .getUrl(Uri.parse(asset.urls[sourceIndex]))
            .timeout(const Duration(seconds: 20));
        _downloadRequest = request;
        request.headers.set(HttpHeaders.userAgentHeader, 'Talk2U/1.0');
        if (existing > 0) {
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
        }
        final response = await request.close().timeout(
          const Duration(seconds: 40),
        );
        var append = false;
        if (existing > 0 && response.statusCode == HttpStatus.partialContent) {
          final range = response.headers.value(HttpHeaders.contentRangeHeader);
          if (range == null || !range.startsWith('bytes $existing-')) {
            await response.drain<void>();
            throw const HttpException('MOSS 模型断点续传范围无效');
          }
          append = true;
        } else if (response.statusCode == HttpStatus.ok) {
          if (existing > 0 && await partial.exists()) await partial.delete();
          existing = 0;
        } else {
          await response.drain<void>();
          throw HttpException('MOSS 模型下载返回 HTTP ${response.statusCode}');
        }
        sink = partial.openWrite(
          mode: append ? FileMode.append : FileMode.write,
        );
        var received = existing;
        var lastNotification = DateTime.now();
        await for (final bytes in response.timeout(
          const Duration(seconds: 40),
        )) {
          if (_cancelDownload) {
            request.abort(const HttpException('MOSS 模型下载已暂停'));
            break;
          }
          sink.add(bytes);
          received += bytes.length;
          downloadedBytes = completedBefore + received;
          final now = DateTime.now();
          if (now.difference(lastNotification).inMilliseconds >= 250) {
            lastNotification = now;
            notifyListeners();
          }
        }
        await sink.flush();
        await sink.close();
        sink = null;
        if (_cancelDownload) return;
        if (await partial.length() != asset.size) {
          throw const HttpException('MOSS 模型连接提前结束，可再次点击继续下载');
        }
        operationLabel = '正在校验 ${asset.fileName}';
        notifyListeners();
        if (await fileSha256(partial.path) != asset.sha256) {
          await partial.delete();
          throw const FormatException('MOSS 模型 SHA-256 校验失败');
        }
        if (await destination.exists()) await destination.delete();
        await partial.rename(destination.path);
        downloadedBytes = completedBefore + asset.size;
        notifyListeners();
        return;
      } catch (error) {
        lastFailure = error;
        await sink?.close();
        _downloadRequest = null;
        if (_cancelDownload) return;
      } finally {
        client.close(force: true);
      }
    }
    if (lastFailure != null) {
      Error.throwWithStackTrace(lastFailure, StackTrace.current);
    }
    throw const HttpException('MOSS 模型下载源不可用');
  }

  void pauseDownload() {
    _cancelDownload = true;
    _downloadRequest?.abort(const HttpException('MOSS 模型下载已暂停'));
    operationLabel = 'MOSS-TTS-Nano 下载已暂停';
    notifyListeners();
  }

  Future<void> selectVoice(String voiceId) async {
    if (!voices.any((voice) => voice.id == voiceId)) {
      throw ArgumentError.value(voiceId, 'voiceId');
    }
    await stopSpeaking();
    _voiceId = voiceId;
    final preferences = await _preferencesFile();
    await preferences.parent.create(recursive: true);
    await preferences.writeAsString(
      jsonEncode({'voice': voiceId}),
      flush: true,
    );
    notifyListeners();
  }

  Future<void> _loadPreferences() async {
    try {
      final file = await _preferencesFile();
      if (!await file.exists()) return;
      final value = jsonDecode(await file.readAsString());
      final voice = value is Map ? value['voice'] as String? : null;
      if (voice != null && voices.any((item) => item.id == voice)) {
        _voiceId = voice;
      }
    } catch (_) {
      _voiceId = voices.first.id;
    }
  }

  Future<void> speak(String text) async {
    await initialize();
    if (!ready) throw StateError('请先下载 MOSS-TTS-Nano 端侧模型');
    final normalized = text.trim();
    if (normalized.isEmpty) return;
    await stopSpeaking();
    final operation = ++_operation;
    final startup = Completer<void>();
    _startupCompleter = startup;
    generating = true;
    playbackAmplitude = 0;
    playbackProgress = 0;
    _playbackDuration = Duration.zero;
    _amplitudeEnvelope = const [];
    lastError = null;
    notifyListeners();
    unawaited(_runSpeech(normalized, operation, startup));
    await startup.future;
  }

  Future<void> _runSpeech(
    String text,
    int operation,
    Completer<void> startup,
  ) async {
    try {
      final root = await _rootDirectory();
      final tokenizerPath =
          '${root.path}${Platform.pathSeparator}$_ttsDirectoryName'
          '${Platform.pathSeparator}tokenizer.model';
      final chunks = splitMossText(text, maxCharacters: 48);
      final tokenChunks = await Isolate.run(
        () => tokenizeMossTextChunks(tokenizerPath, chunks),
      );
      if (operation != _operation) throw const _MossCancelled();
      final weights = chunks
          .map((chunk) => chunk.runes.length)
          .toList(growable: false);
      final totalWeight = weights.fold<int>(0, (total, value) => total + value);
      var completedWeight = 0;
      var pending = _MossPendingAudio(
        _synthesizeChunk(root, tokenChunks.first, operation, 0),
      );
      for (var index = 0; index < chunks.length; index++) {
        final outcome = await pending.future;
        if (operation != _operation) throw const _MossCancelled();
        if (outcome.error != null) {
          Error.throwWithStackTrace(
            outcome.error!,
            outcome.stackTrace ?? StackTrace.current,
          );
        }
        final audio = outcome.audio!;
        final nextIndex = index + 1;
        _MossPendingAudio? next;
        if (nextIndex < chunks.length) {
          next = _MossPendingAudio(
            _synthesizeChunk(
              root,
              tokenChunks[nextIndex],
              operation,
              nextIndex,
            ),
          );
          generating = true;
        } else {
          generating = false;
        }
        _segmentProgressStart = totalWeight == 0
            ? 0
            : completedWeight / totalWeight;
        completedWeight += weights[index];
        _segmentProgressEnd = totalWeight == 0
            ? 1
            : completedWeight / totalWeight;
        await _playAudio(audio, operation, startup);
        await _deleteAudio(audio.file);
        if (operation != _operation) throw const _MossCancelled();
        if (next == null) break;
        if (!next.completed) {
          await Future.any<void>([
            next.future.then<void>((_) {}),
            Future<void>.delayed(const Duration(milliseconds: 250)),
          ]);
        }
        if (!next.completed) {
          speaking = false;
          generating = true;
          playbackAmplitude = 0;
          _stopLipSyncClock();
          notifyListeners();
        }
        pending = next;
      }
      if (operation != _operation) throw const _MossCancelled();
      generating = false;
      speaking = false;
      playbackAmplitude = 0;
      playbackProgress = 1;
      _stopLipSyncClock();
      notifyListeners();
    } on PlatformException catch (error) {
      if (operation != _operation || error.code == 'moss_cancelled') {
        if (!startup.isCompleted) startup.complete();
        return;
      }
      generating = false;
      speaking = false;
      lastError = error.message ?? error.code;
      notifyListeners();
      if (!startup.isCompleted) {
        startup.completeError(error, StackTrace.current);
      }
    } on _MossCancelled {
      if (!startup.isCompleted) startup.complete();
    } catch (error, stackTrace) {
      if (operation != _operation) {
        if (!startup.isCompleted) startup.complete();
        return;
      }
      generating = false;
      speaking = false;
      lastError = error.toString();
      notifyListeners();
      if (!startup.isCompleted) startup.completeError(error, stackTrace);
    } finally {
      if (identical(_startupCompleter, startup)) _startupCompleter = null;
      await _deletePendingOutputs();
    }
  }

  Future<_MossAudio> _synthesizeChunk(
    Directory root,
    List<int> tokens,
    int operation,
    int index,
  ) async {
    if (operation != _operation) throw const _MossCancelled();
    final cache = await getTemporaryDirectory();
    var output = File(
      '${cache.path}${Platform.pathSeparator}talk2u-moss-$operation-$index-'
      '${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    _pendingOutputs.add(output);
    try {
      final response = await _channel.invokeMapMethod<dynamic, dynamic>(
        'synthesize',
        {
          'modelRoot': root.path,
          'outputPath': output.path,
          'tokenChunks': [tokens],
          'voice': _voiceId,
          'maxFrames': 375,
          'seed': DateTime.now().microsecondsSinceEpoch + index,
        },
      );
      if (operation != _operation) throw const _MossCancelled();
      final provider = response?['provider'] as String?;
      if (provider != null && provider.isNotEmpty) {
        activeProvider = provider;
        _providerMeasured = true;
      }
      final outputPath = response?['path'] as String?;
      if (outputPath == null) {
        throw StateError('MOSS-TTS-Nano 没有生成可播放音频');
      }
      final generatedOutput = File(outputPath);
      if (generatedOutput.path != output.path) {
        _pendingOutputs.remove(output);
        output = generatedOutput;
        _pendingOutputs.add(output);
      }
      if (!await isPlayableMossWav(output)) {
        throw StateError('MOSS-TTS-Nano 生成的音频文件无效');
      }
      final envelope = await Isolate.run(
        () => buildWavAmplitudeEnvelope(output.path),
      );
      if (operation != _operation) throw const _MossCancelled();
      return _MossAudio(output, envelope);
    } catch (_) {
      await _deleteAudio(output);
      rethrow;
    }
  }

  Future<void> _playAudio(
    _MossAudio audio,
    int operation,
    Completer<void> startup,
  ) async {
    if (operation != _operation) throw const _MossCancelled();
    _currentOutput = audio.file;
    _amplitudeEnvelope = audio.amplitudeEnvelope;
    _playbackDuration = Duration(
      milliseconds: math.max(
        1,
        _amplitudeEnvelope.length * amplitudeFrameMilliseconds,
      ),
    );
    _positionAnchor = Duration.zero;
    _playbackCompleter = Completer<void>();
    await _player.play(DeviceFileSource(audio.file.path));
    if (operation != _operation) throw const _MossCancelled();
    speaking = true;
    playbackAmplitude = 0;
    playbackProgress = _segmentProgressStart;
    _startLipSyncClock();
    notifyListeners();
    if (!startup.isCompleted) startup.complete();
    await _playbackCompleter!.future;
    _stopLipSyncClock();
    playbackAmplitude = 0;
    playbackProgress = _segmentProgressEnd;
    notifyListeners();
  }

  void _startLipSyncClock() {
    _lipSyncTimer?.cancel();
    _playbackClock
      ..reset()
      ..start();
    _lipSyncTimer = Timer.periodic(
      const Duration(milliseconds: 33),
      (_) => _updateLipSync(),
    );
    _updateLipSync();
  }

  void _updateLipSync() {
    if (!speaking || _amplitudeEnvelope.isEmpty) return;
    final elapsed = _positionAnchor + _playbackClock.elapsed;
    final durationMs = math.max(1, _playbackDuration.inMilliseconds);
    final positionMs = elapsed.inMilliseconds.clamp(0, durationMs);
    final localProgress = positionMs / durationMs;
    final frame = math.min(
      _amplitudeEnvelope.length - 1,
      positionMs ~/ amplitudeFrameMilliseconds,
    );
    playbackAmplitude = _amplitudeEnvelope[frame];
    playbackProgress =
        _segmentProgressStart +
        (_segmentProgressEnd - _segmentProgressStart) * localProgress;
    notifyListeners();
  }

  void _stopLipSyncClock() {
    _lipSyncTimer?.cancel();
    _lipSyncTimer = null;
    _playbackClock
      ..stop()
      ..reset();
    _positionAnchor = Duration.zero;
  }

  Future<void> stopSpeaking() async {
    _operation++;
    final startup = _startupCompleter;
    _startupCompleter = null;
    if (startup != null && !startup.isCompleted) startup.complete();
    final playback = _playbackCompleter;
    _playbackCompleter = null;
    if (playback != null && !playback.isCompleted) playback.complete();
    _stopLipSyncClock();
    if (supported) {
      try {
        await _channel.invokeMethod<void>('cancel');
      } on PlatformException {
        lastError = null;
      }
    }
    await _player.stop();
    generating = false;
    speaking = false;
    playbackAmplitude = 0;
    playbackProgress = 0;
    _amplitudeEnvelope = const [];
    await _deletePendingOutputs();
    notifyListeners();
  }

  Future<void> deleteModel() async {
    if (downloading) throw StateError('请先暂停下载并等待当前文件停止写入');
    pauseDownload();
    await stopSpeaking();
    if (supported) {
      await _channel.invokeMethod<void>('release');
    }
    final root = await _rootDirectory();
    if (await root.exists()) await root.delete(recursive: true);
    ready = false;
    downloadedBytes = 0;
    notifyListeners();
  }

  Future<void> releaseRuntime() async {
    await stopSpeaking();
    if (supported) {
      await _channel.invokeMethod<void>('release');
    }
  }

  Future<void> _deleteCurrentOutput() async {
    final output = _currentOutput;
    _currentOutput = null;
    if (output != null && await output.exists()) {
      try {
        await output.delete();
      } on FileSystemException {
        return;
      }
    }
  }

  Future<void> _deleteAudio(File output) async {
    _pendingOutputs.remove(output);
    if (_currentOutput?.path == output.path) _currentOutput = null;
    if (!await output.exists()) return;
    try {
      await output.delete();
    } on FileSystemException {
      return;
    }
  }

  Future<void> _deletePendingOutputs() async {
    await _deleteCurrentOutput();
    final outputs = _pendingOutputs.toList(growable: false);
    _pendingOutputs.clear();
    for (final output in outputs) {
      if (!await output.exists()) continue;
      try {
        await output.delete();
      } on FileSystemException {
        continue;
      }
    }
  }

  Future<void> _cleanupAudioCache() async {
    final cache = await getTemporaryDirectory();
    await for (final entity in cache.list()) {
      if (entity is! File ||
          !entity.uri.pathSegments.last.startsWith('talk2u-moss-')) {
        continue;
      }
      try {
        await entity.delete();
      } on FileSystemException {
        continue;
      }
    }
  }

  Future<void> _deleteLegacyKokoro() async {
    final support = await getApplicationSupportDirectory();
    final legacyRoot = Directory(
      '${support.path}${Platform.pathSeparator}sherpa-speech',
    );
    final targets = <FileSystemEntity>[
      Directory(
        '${legacyRoot.path}${Platform.pathSeparator}kokoro-int8-multi-lang-v1_1',
      ),
      File(
        '${legacyRoot.path}${Platform.pathSeparator}kokoro-int8-multi-lang-v1_1.tar.bz2',
      ),
      File(
        '${legacyRoot.path}${Platform.pathSeparator}kokoro-int8-multi-lang-v1_1.tar.bz2.part',
      ),
      File('${legacyRoot.path}${Platform.pathSeparator}tts-preferences.json'),
    ];
    for (final target in targets) {
      if (await target.exists()) await target.delete(recursive: true);
    }
  }

  @override
  void dispose() {
    _operation++;
    _stopLipSyncClock();
    final startup = _startupCompleter;
    if (startup != null && !startup.isCompleted) startup.complete();
    final playback = _playbackCompleter;
    if (playback != null && !playback.isCompleted) playback.complete();
    _completeSubscription?.cancel();
    _durationSubscription?.cancel();
    _positionSubscription?.cancel();
    _player.dispose();
    super.dispose();
  }
}

@visibleForTesting
List<String> splitMossText(String source, {int maxCharacters = 110}) {
  final text = source.trim();
  if (text.isEmpty) return const [];
  final output = <String>[];
  final buffer = <int>[];
  const strong = '。！？!?\n';
  const soft = '，、；：,;: ';
  void flush() {
    final value = String.fromCharCodes(buffer).trim();
    if (value.isNotEmpty) output.add(value);
    buffer.clear();
  }

  for (final rune in text.runes) {
    buffer.add(rune);
    final character = String.fromCharCode(rune);
    if (strong.contains(character) && buffer.length >= 8) {
      flush();
    } else if (buffer.length >= maxCharacters && soft.contains(character)) {
      flush();
    } else if (buffer.length >= maxCharacters) {
      flush();
    }
  }
  flush();
  return List.unmodifiable(output);
}

@visibleForTesting
Future<bool> isPlayableMossWav(File file) async {
  try {
    if (!await file.exists() || await file.length() <= 44) return false;
    final input = await file.open();
    try {
      final header = await input.read(12);
      return header.length == 12 &&
          ascii.decode(header.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
          ascii.decode(header.sublist(8, 12), allowInvalid: true) == 'WAVE';
    } finally {
      await input.close();
    }
  } on FileSystemException {
    return false;
  }
}

@visibleForTesting
List<List<int>> tokenizeMossTextChunks(String modelPath, List<String> chunks) {
  final tokenizer = SentencePieceTokenizer.fromModelFileSync(
    modelPath,
    config: const SentencePieceConfig(),
  );
  return chunks
      .map(
        (chunk) => tokenizer
            .encode(
              normalizeMossSentencePieceText(chunk),
              addSpecialTokens: false,
            )
            .ids
            .toList(growable: false),
      )
      .toList(growable: false);
}

@visibleForTesting
String normalizeMossSentencePieceText(String text) {
  final output = StringBuffer();
  for (final rune in text.runes) {
    if (rune == 0x3000) {
      output.write(' ');
    } else if (rune >= 0xff01 && rune <= 0xff5e) {
      output.writeCharCode(rune - 0xfee0);
    } else {
      output.writeCharCode(rune);
    }
  }
  return output.toString();
}

@visibleForTesting
Future<String> fileSha256(String path) async {
  return Isolate.run(() async {
    final digest = await sha256.bind(File(path).openRead()).first;
    return digest.toString();
  });
}

@visibleForTesting
List<double> buildWavAmplitudeEnvelope(
  String path, {
  int frameMilliseconds = MossTtsService.amplitudeFrameMilliseconds,
}) {
  final input = File(path).openSync();
  try {
    final fileLength = input.lengthSync();
    if (fileLength < 44) {
      throw const FormatException('MOSS-TTS-Nano 输出 WAV 无效');
    }
    final header = input.readSync(12);
    if (header.length != 12 ||
        ascii.decode(header.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
        ascii.decode(header.sublist(8, 12), allowInvalid: true) != 'WAVE') {
      throw const FormatException('MOSS-TTS-Nano 输出 WAV 无效');
    }
    var offset = 12;
    var sampleRate = 0;
    var channels = 0;
    var bitsPerSample = 0;
    var pcmOffset = -1;
    var pcmLength = 0;
    while (offset + 8 <= fileLength) {
      input.setPositionSync(offset);
      final chunkHeader = input.readSync(8);
      if (chunkHeader.length != 8) break;
      final chunkId = ascii.decode(
        chunkHeader.sublist(0, 4),
        allowInvalid: true,
      );
      final chunkLength = ByteData.sublistView(
        chunkHeader,
      ).getUint32(4, Endian.little);
      final chunkStart = offset + 8;
      if (chunkLength > fileLength - chunkStart) break;
      if (chunkId == 'fmt ' && chunkLength >= 16) {
        input.setPositionSync(chunkStart);
        final format = input.readSync(16);
        if (format.length != 16) break;
        final data = ByteData.sublistView(format);
        if (data.getUint16(0, Endian.little) != 1) {
          throw const FormatException('MOSS WAV 不是 PCM');
        }
        channels = data.getUint16(2, Endian.little);
        sampleRate = data.getUint32(4, Endian.little);
        bitsPerSample = data.getUint16(14, Endian.little);
      } else if (chunkId == 'data') {
        pcmOffset = chunkStart;
        pcmLength = chunkLength;
        break;
      }
      offset = chunkStart + chunkLength + (chunkLength.isOdd ? 1 : 0);
    }
    if (sampleRate <= 0 ||
        channels <= 0 ||
        bitsPerSample != 16 ||
        pcmOffset < 0 ||
        pcmLength <= 0) {
      throw const FormatException('MOSS WAV PCM 参数无效');
    }
    final bytesPerFrame = channels * 2;
    final totalFrames = pcmLength ~/ bytesPerFrame;
    final envelopeFrames = math.max(1, sampleRate * frameMilliseconds ~/ 1000);
    final output = <double>[];
    input.setPositionSync(pcmOffset);
    var remainingFrames = totalFrames;
    while (remainingFrames > 0) {
      final frameCount = math.min(envelopeFrames, remainingFrames);
      final pcm = input.readSync(frameCount * bytesPerFrame);
      if (pcm.length != frameCount * bytesPerFrame) {
        throw const FormatException('MOSS WAV PCM 数据不完整');
      }
      final data = ByteData.sublistView(pcm);
      var sumSquares = 0.0;
      var sampleOffset = 0;
      while (sampleOffset < pcm.length) {
        final sample = data.getInt16(sampleOffset, Endian.little) / 32768.0;
        sumSquares += sample * sample;
        sampleOffset += 2;
      }
      final sampleCount = pcm.length ~/ 2;
      final rms = sampleCount == 0 ? 0.0 : math.sqrt(sumSquares / sampleCount);
      output.add(((rms - 0.01).clamp(0.0, 1.0) * 5.5).clamp(0.0, 1.0));
      remainingFrames -= frameCount;
    }
    return List.unmodifiable(output);
  } finally {
    input.closeSync();
  }
}

String _formatBytes(int bytes) {
  if (bytes >= 1073741824) {
    return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1048576) {
    return '${(bytes / 1048576).toStringAsFixed(0)} MB';
  }
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}
