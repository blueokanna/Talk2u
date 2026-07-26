import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fcllama/fllama.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

@immutable
class OfflineChatMessage {
  final String role;
  final String content;

  const OfflineChatMessage({required this.role, required this.content});
}

class OfflineGenerationCancelled implements Exception {
  const OfflineGenerationCancelled();

  @override
  String toString() => '端侧生成已停止';
}

class OfflineLlmService extends ChangeNotifier {
  OfflineLlmService._();

  static final instance = OfflineLlmService._();

  static const modelName = 'Qwen2.5 3B Instruct Q4_K_M';
  static const modelLicense = 'Qwen Research';
  static const modelFileName = 'qwen2.5-3b-instruct-q4_k_m.gguf';
  static const modelSize = 2104932768;
  static const modelSha256 =
      '626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d';
  static const modelUrl =
      'https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/'
      'qwen2.5-3b-instruct-q4_k_m.gguf?download=true';
  static const contextSize = 8192;
  static const maxOutputTokens = 768;
  static const _runtimeChannel = MethodChannel('talk2u/llm_runtime');

  bool initialized = false;
  bool modelReady = false;
  bool downloading = false;
  bool loadingModel = false;
  bool generating = false;
  int downloadedBytes = 0;
  int totalDownloadBytes = modelSize;
  String? lastError;
  Map<String, dynamic> runtimeCapabilities = const {};

  Future<void>? _initializing;
  String? _modelPath;
  double? _contextId;
  bool _stopRequested = false;
  HttpClientRequest? _downloadRequest;
  bool _cancelRequested = false;

  bool get supported =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  String get accelerationDescription {
    if (defaultTargetPlatform == TargetPlatform.iOS) return 'Apple Metal GPU';
    if (defaultTargetPlatform != TargetPlatform.android) return '不可用';
    final backend = runtimeCapabilities['activeBackend']?.toString();
    final profile = runtimeCapabilities['targetProfile']?.toString();
    if (backend == null || backend.isEmpty) return 'CPU/NEON';
    return profile == null || profile.isEmpty ? backend : '$backend · $profile';
  }

  String? get modelPath => _modelPath;
  double get downloadProgress => totalDownloadBytes <= 0
      ? 0
      : (downloadedBytes / totalDownloadBytes).clamp(0, 1);

  Future<Directory> _modelDirectory() async {
    final root = await getApplicationSupportDirectory();
    final directory = Directory('${root.path}${Platform.pathSeparator}models');
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  Future<File> _modelFile() async {
    final directory = await _modelDirectory();
    return File('${directory.path}${Platform.pathSeparator}$modelFileName');
  }

  Future<void> initialize() {
    if (initialized) return Future.value();
    final existing = _initializing;
    if (existing != null) return existing;
    final future = _initializeOnce();
    _initializing = future;
    return future.whenComplete(() {
      if (identical(_initializing, future)) _initializing = null;
    });
  }

  Future<void> _initializeOnce() async {
    if (!supported) {
      initialized = true;
      return;
    }
    try {
      await _loadRuntimeCapabilities();
      final file = await _modelFile();
      modelReady = await _isValidModel(file);
      _modelPath = modelReady ? file.path : null;
      lastError = null;
    } catch (error) {
      modelReady = false;
      lastError = '无法检查端侧模型: $error';
    } finally {
      initialized = true;
      notifyListeners();
    }
  }

  Future<void> _loadRuntimeCapabilities() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final value = await _runtimeChannel.invokeMapMethod<Object?, Object?>(
        'capabilities',
      );
      if (value != null) {
        runtimeCapabilities = value.map(
          (key, item) => MapEntry(key.toString(), item),
        );
      }
    } on MissingPluginException {
      runtimeCapabilities = const {
        'activeBackend': 'cpu-neon',
        'activeBackendVerified': true,
        'targetProfile': 'generic-arm64',
      };
    } on PlatformException catch (error) {
      debugPrint('Unable to query Android LLM runtime: $error');
    }
  }

  Future<bool> _hasValidHeaderAndSize(File file) async {
    if (!await file.exists() || await file.length() != modelSize) return false;
    final reader = await file.open();
    try {
      final header = await reader.read(4);
      return listEquals(header, const [0x47, 0x47, 0x55, 0x46]);
    } finally {
      await reader.close();
    }
  }

  Future<bool> _isValidModel(File file) async {
    if (!await _hasValidHeaderAndSize(file)) return false;
    return (await sha256.bind(file.openRead()).first).toString() == modelSha256;
  }

  Future<void> downloadModel() async {
    if (!supported) throw UnsupportedError('端侧 LLM 当前仅支持 Android 和 iOS');
    if (downloading) return;
    downloading = true;
    totalDownloadBytes = modelSize;
    lastError = null;
    _cancelRequested = false;

    final destination = await _modelFile();
    final partial = File('${destination.path}.part');
    var resumeFrom = await partial.exists() ? await partial.length() : 0;
    if (resumeFrom > modelSize) {
      await partial.delete();
      resumeFrom = 0;
    }
    downloadedBytes = resumeFrom;
    notifyListeners();

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    IOSink? sink;
    var discardPartial = false;
    try {
      final request = await client.getUrl(Uri.parse(modelUrl));
      _downloadRequest = request;
      request.headers.set(HttpHeaders.userAgentHeader, 'Talk2U/1.0');
      if (resumeFrom > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$resumeFrom-');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        throw HttpException('模型下载返回 HTTP ${response.statusCode}');
      }

      final contentRange = response.headers.value(
        HttpHeaders.contentRangeHeader,
      );
      final canResume =
          resumeFrom > 0 &&
          response.statusCode == HttpStatus.partialContent &&
          (contentRange?.startsWith('bytes $resumeFrom-') ?? false);
      if (!canResume) {
        resumeFrom = 0;
        downloadedBytes = 0;
      }
      sink = partial.openWrite(
        mode: canResume ? FileMode.append : FileMode.write,
      );
      var lastNotification = DateTime.now();
      await for (final chunk in response) {
        if (_cancelRequested) throw const HttpException('用户取消模型下载');
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

      if (await partial.length() != modelSize) {
        if (await partial.length() > modelSize) discardPartial = true;
        throw const FormatException('模型文件大小校验失败');
      }
      final digest = await sha256.bind(partial.openRead()).first;
      if (digest.toString() != modelSha256) {
        discardPartial = true;
        throw const FormatException('模型 SHA-256 校验失败');
      }
      if (await destination.exists()) await destination.delete();
      await partial.rename(destination.path);
      modelReady = await _hasValidHeaderAndSize(destination);
      if (!modelReady) throw const FormatException('模型不是有效的 GGUF 文件');
      _modelPath = destination.path;
      downloadedBytes = modelSize;
    } catch (error) {
      lastError = _cancelRequested ? null : error.toString();
      modelReady = false;
      _modelPath = null;
      if (discardPartial && await partial.exists()) await partial.delete();
      if (!_cancelRequested) rethrow;
    } finally {
      await sink?.close();
      _downloadRequest = null;
      client.close(force: true);
      downloading = false;
      notifyListeners();
    }
  }

  void cancelDownload() {
    _cancelRequested = true;
    _downloadRequest?.abort(const HttpException('用户取消模型下载'));
  }

  Future<void> deleteModel() async {
    if (generating) throw StateError('请先等待当前端侧回复完成');
    final contextId = _contextId;
    if (contextId != null) {
      await FCllama.instance()!.releaseContext(contextId);
      _contextId = null;
    }
    final file = await _modelFile();
    if (await file.exists()) await file.delete();
    final partial = File('${file.path}.part');
    if (await partial.exists()) await partial.delete();
    modelReady = false;
    downloadedBytes = 0;
    _modelPath = null;
    lastError = null;
    notifyListeners();
  }

  Future<double> _ensureContext() async {
    final existing = _contextId;
    if (existing != null) return existing;
    await initialize();
    final path = _modelPath;
    if (!modelReady || path == null) {
      throw StateError('请先在设置中下载 $modelName');
    }

    loadingModel = true;
    lastError = null;
    notifyListeners();
    try {
      final context = await FCllama.instance()!.initContext(
        path,
        nCtx: contextSize,
        nBatch: 256,
        nThreads: 0,
        nGpuLayers: defaultTargetPlatform == TargetPlatform.iOS ? 99 : 0,
        useMlock: false,
        useMmap: true,
        emitLoadProgress: true,
      );
      final rawId = context?['contextId'];
      final contextId = rawId is num
          ? rawId.toDouble()
          : double.tryParse(rawId?.toString() ?? '');
      if (contextId == null || contextId <= 0) {
        throw StateError(context?['reason']?.toString() ?? 'llama.cpp 初始化失败');
      }
      _contextId = contextId;
      return contextId;
    } catch (error) {
      lastError = error.toString();
      rethrow;
    } finally {
      loadingModel = false;
      notifyListeners();
    }
  }

  Future<String> generate(
    List<OfflineChatMessage> messages, {
    ValueChanged<String>? onText,
  }) async {
    if (generating) throw StateError('端侧模型正在生成上一条回复');
    final contextId = await _ensureContext();
    generating = true;
    _stopRequested = false;
    lastError = null;
    notifyListeners();

    final buffer = StringBuffer();
    StreamSubscription<Map<Object?, dynamic>>? subscription;
    try {
      subscription = FCllama.instance()!.onTokenStream?.listen((event) {
        if (event['function'] != 'completion') return;
        final result = event['result'];
        if (result is! Map) return;
        final token = result['token']?.toString() ?? '';
        if (token.isEmpty) return;
        buffer.write(token);
        onText?.call(buffer.toString());
      });
      final prompt = formatQwenChatPrompt(messages);
      final result = await FCllama.instance()!.completion(
        contextId,
        prompt: prompt,
        temperature: 0.7,
        nPredict: maxOutputTokens,
        penaltyRepeat: 1.1,
        topK: 40,
        topP: 0.9,
        minP: 0.05,
        stop: const ['<|im_end|>', '<|endoftext|>'],
        emitRealtimeCompletion: true,
      );
      if (_stopRequested) throw const OfflineGenerationCancelled();
      var text = buffer.toString().trim();
      if (text.isEmpty) {
        text = (result?['text'] ?? result?['content'] ?? '').toString().trim();
      }
      if (text.isEmpty) throw StateError('端侧模型没有返回文本');
      return text;
    } catch (error) {
      if (error is! OfflineGenerationCancelled) {
        lastError = error.toString();
      }
      rethrow;
    } finally {
      await subscription?.cancel();
      _stopRequested = false;
      generating = false;
      notifyListeners();
    }
  }

  @visibleForTesting
  static String formatQwenChatPrompt(List<OfflineChatMessage> messages) {
    final output = StringBuffer();
    for (final message in messages) {
      final content = message.content.trim();
      if (content.isEmpty) continue;
      final role = switch (message.role) {
        'system' => 'system',
        'assistant' => 'assistant',
        _ => 'user',
      };
      output
        ..write('<|im_start|>')
        ..write(role)
        ..write('\n')
        ..write(content)
        ..write('<|im_end|>\n');
    }
    output.write('<|im_start|>assistant\n');
    return output.toString();
  }

  Future<void> stopGeneration() async {
    final contextId = _contextId;
    if (contextId != null && generating) {
      _stopRequested = true;
      await FCllama.instance()!.stopCompletion(contextId: contextId);
    }
  }

  @override
  void dispose() {
    final contextId = _contextId;
    if (contextId != null) {
      unawaited(FCllama.instance()!.releaseContext(contextId));
    }
    super.dispose();
  }
}
