import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
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
  static const _preferencesName = 'preferences.json';

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

  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<void>? _completeSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  Completer<void>? _playbackCompleter;
  Completer<void>? _startupCompleter;
  Timer? _lipSyncTimer;
  final Stopwatch _playbackClock = Stopwatch();
  Duration _playbackDuration = Duration.zero;
  Duration _positionAnchor = Duration.zero;
  List<double> _amplitudeEnvelope = const [];
  File? _currentOutput;
  final Set<File> _pendingOutputs = {};
  double _segmentProgressStart = 0;
  double _segmentProgressEnd = 1;
  int _operation = 0;
  String _voiceId = voices.first.id;

  bool initialized = false;
  bool runtimeReady = false;
  bool runtimeInitialized = false;
  bool initializing = false;
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
  List<String> runtimeProviders = const [];
  String activeProvider = 'UNVERIFIED';
  bool _providerMeasured = false;
  Future<void>? _initializationFuture;

  bool get supported => !kIsWeb && Platform.isAndroid;
  double get downloadProgress => totalDownloadBytes <= 0
      ? 0
      : (downloadedBytes / totalDownloadBytes).clamp(0, 1);
  String get voiceId => _voiceId;
  bool get providerMeasured => _providerMeasured;
  bool get hardwareAccelerationVerified =>
      _providerMeasured && _isQnnProvider(activeProvider);
  bool get hardwareRuntimeAvailable =>
      runtimeReady && runtimeInitialized && runtimeProviders.isNotEmpty;

  String get accelerationLabel {
    if (hardwareAccelerationVerified && activeProvider.contains('ORT_CPU')) {
      return 'Qualcomm QNN HTP + ORT CPU';
    }
    if (hardwareAccelerationVerified) return 'Qualcomm QNN HTP';
    if (runtimeInitialized) return 'Qualcomm QNN HTP + ORT CPU · 已初始化';
    if (initializing) return 'QNN HTP 正在初始化';
    if (runtimeProviders.contains('QNN_HTP')) return 'QNN HTP 候选 · 尚未执行验证';
    return 'QNN HTP 不可用';
  }

  static bool _isQnnProvider(String provider) {
    final value = provider.trim().toUpperCase();
    return value.contains('QNN_HTP') || value.contains('QNN_GPU');
  }

  MossVoice get selectedVoice => voices.firstWhere(
    (voice) => voice.id == _voiceId,
    orElse: () => voices.first,
  );

  Future<Directory> _rootDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}${Platform.pathSeparator}$_rootName');
  }

  Future<File> _preferencesFile() async => File(
    '${(await _rootDirectory()).path}${Platform.pathSeparator}$_preferencesName',
  );

  Future<void> initialize() async {
    if (!supported) {
      initialized = true;
      return;
    }
    if (runtimeInitialized || (initialized && !ready)) return;
    final pending = _initializationFuture;
    if (pending != null) return pending;
    final future = _initializeInternal();
    _initializationFuture = future;
    try {
      await future;
    } finally {
      if (identical(_initializationFuture, future)) {
        _initializationFuture = null;
      }
    }
  }

  Future<void> _initializeInternal() async {
    try {
      runtimeReady = await _channel.invokeMethod<bool>('probe') == true;
      runtimeProviders = runtimeReady
          ? (await _channel.invokeListMethod<String>('providers') ?? const [])
          : const [];
      await _loadPreferences();
      final model = await _channel.invokeMapMethod<dynamic, dynamic>(
        'modelInfo',
      );
      ready = model != null;
      if (model?['bytes'] is num) {
        downloadedBytes = (model!['bytes'] as num).toInt();
        totalDownloadBytes = downloadedBytes;
      }
      if (ready && runtimeReady) await _initializeNativeRuntime();
      await _cleanupAudioCache();
      lastError = runtimeReady ? null : 'Qualcomm QNN HTP 运行时不可用';
    } catch (error) {
      runtimeInitialized = false;
      lastError = '无法自动初始化 MOSS QNN 运行时: $error';
    } finally {
      initializing = false;
      initialized = true;
      notifyListeners();
    }
  }

  Future<void> _initializeNativeRuntime() async {
    if (runtimeInitialized || initializing) return;
    initializing = true;
    operationLabel = '正在初始化 QNN HTP 上下文';
    notifyListeners();
    try {
      final state = await _channel.invokeMapMethod<dynamic, dynamic>(
        'initialize',
      );
      runtimeInitialized = state?['initialized'] == true;
      if (!runtimeInitialized) {
        throw StateError(
          state?['error']?.toString() ?? 'Native MOSS runtime 未就绪',
        );
      }
      operationLabel = 'MOSS QNN HTP 已初始化';
    } finally {
      initializing = false;
      notifyListeners();
    }
  }

  Future<void> importModel() async {
    await initialize();
    if (!supported) throw UnsupportedError('MOSS QNN 模型导入仅支持 Android');
    if (!runtimeReady) throw StateError('Qualcomm QNN HTP 运行时不可用');
    if (downloading) return;
    downloading = true;
    operationLabel = '请选择包含 moss-qnn-deployment.json 的目录';
    lastError = null;
    notifyListeners();
    try {
      final model = await _channel.invokeMapMethod<dynamic, dynamic>(
        'importModel',
      );
      ready = model != null;
      runtimeInitialized = model?['initialized'] == true;
      if (model?['bytes'] is num) {
        downloadedBytes = (model!['bytes'] as num).toInt();
        totalDownloadBytes = downloadedBytes;
      }
      operationLabel = runtimeInitialized
          ? 'MOSS QNN HTP 模型已导入并初始化'
          : ready
          ? 'MOSS QNN HTP 模型已导入'
          : '';
    } on PlatformException catch (error) {
      if (error.code != 'moss_import_cancelled') {
        lastError = error.message ?? error.code;
        rethrow;
      }
    } finally {
      downloading = false;
      notifyListeners();
    }
  }

  Future<void> downloadModel() => importModel();

  void pauseDownload() {
    operationLabel = '模型导入完成前请勿关闭应用';
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
    if (!ready) throw StateError('请先导入 MOSS QNN HTP v81 部署包');
    if (!runtimeInitialized) await _initializeNativeRuntime();
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
      final chunks = splitMossText(text, maxCharacters: 48);
      if (operation != _operation) throw const _MossCancelled();
      final weights = chunks
          .map((chunk) => chunk.runes.length)
          .toList(growable: false);
      final totalWeight = weights.fold<int>(0, (total, value) => total + value);
      var completedWeight = 0;
      var pending = _MossPendingAudio(
        _synthesizeChunk(chunks.first, operation, 0),
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
            _synthesizeChunk(chunks[nextIndex], operation, nextIndex),
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
    String text,
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
      final response = await _channel
          .invokeMapMethod<dynamic, dynamic>('synthesize', {
            'outputPath': output.path,
            'text': text,
            'voice': _voiceId,
            'maxFrames': 375,
            'seed': DateTime.now().microsecondsSinceEpoch + index,
          });
      if (operation != _operation) throw const _MossCancelled();
      final provider = response?['provider'] as String?;
      if (provider == null || provider.isEmpty) {
        throw StateError('MOSS-TTS-Nano 未返回有效的执行 provider');
      }
      activeProvider = provider;
      _providerMeasured = true;
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
    if (downloading) throw StateError('请等待当前模型导入结束');
    await stopSpeaking();
    if (supported) {
      await _channel.invokeMethod<void>('deleteModel');
    }
    ready = false;
    runtimeInitialized = false;
    initializing = false;
    downloadedBytes = 0;
    notifyListeners();
  }

  Future<void> releaseRuntime() async {
    await stopSpeaking();
    if (supported) {
      await _channel.invokeMethod<void>('release');
    }
    runtimeInitialized = false;
    notifyListeners();
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
