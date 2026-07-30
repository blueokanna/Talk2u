import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class OfflineChatMessage {
  final String role;
  final String content;

  const OfflineChatMessage({required this.role, required this.content});

  Map<String, String> toMap() => {'role': role, 'content': content};
}

class OfflineGenerationCancelled implements Exception {
  const OfflineGenerationCancelled();

  @override
  String toString() => '端侧生成已停止';
}

class OfflineLlmFailure implements Exception {
  final String code;
  final String message;
  final Object? details;

  const OfflineLlmFailure(this.code, this.message, [this.details]);

  @override
  String toString() => message;
}

class OfflineLlmService extends ChangeNotifier {
  OfflineLlmService._() {
    _runtimeChannel.setMethodCallHandler(_handleRuntimeMethodCall);
  }

  static final instance = OfflineLlmService._();

  static const modelName = 'Qwen3-4B-Instruct-2507';
  static const modelId = 'ai-hub-models/Qwen3-4B-Instruct-2507';
  static const modelLicense = 'Apache-2.0';
  static const contextSize = 4096;
  static const maxOutputTokens = 256;
  static const _runtimeChannel = MethodChannel('talk2u/llm_runtime');

  bool initialized = false;
  bool modelReady = false;
  bool downloading = false;
  bool loadingModel = false;
  bool generating = false;
  int downloadedBytes = 0;
  int totalDownloadBytes = 0;
  String? lastError;
  Map<String, dynamic> runtimeCapabilities = const {};

  Future<void>? _initializing;
  bool _runtimeLoaded = false;
  bool _stopRequested = false;
  int _nextGenerationId = 0;
  int? _activeGenerationId;
  String _lastStreamedText = '';
  ValueChanged<String>? _activeTextCallback;

  bool get supported => defaultTargetPlatform == TargetPlatform.android;
  String? get activeBackend => runtimeCapabilities['activeBackend']?.toString();
  bool get hardwareAccelerationVerified =>
      runtimeCapabilities['activeBackendVerified'] == true &&
      activeBackend == 'geniex-qairt-npu';

  String get accelerationDescription {
    final verified = runtimeCapabilities['activeBackendVerified'] == true;
    return switch (activeBackend) {
      'geniex-qairt-npu' when verified => 'Qualcomm QNN HTP/NPU（已验证）',
      'geniex-qairt-npu' => 'Qualcomm QNN HTP/NPU 已加载，等待首轮执行验证',
      _ when modelReady => 'GenieX QAIRT/NPU 尚未加载',
      _ => 'GenieX QAIRT/NPU 模型尚未安装',
    };
  }

  double get downloadProgress => totalDownloadBytes <= 0
      ? 0
      : (downloadedBytes / totalDownloadBytes).clamp(0, 1);

  Future<void> initialize() {
    if (initialized) return Future.value();
    final current = _initializing;
    if (current != null) return current;
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
      modelReady = runtimeCapabilities['modelReady'] == true;
      final bytes = runtimeCapabilities['modelBytes'];
      if (bytes is num && bytes > 0) {
        downloadedBytes = bytes.toInt();
        totalDownloadBytes = bytes.toInt();
      }
      lastError = null;
    } catch (error) {
      modelReady = false;
      lastError = '无法检查 $modelName QAIRT/NPU 模型：$error';
    } finally {
      initialized = true;
      notifyListeners();
    }
  }

  Future<void> _loadRuntimeCapabilities() async {
    try {
      final value = await _runtimeChannel.invokeMapMethod<Object?, Object?>(
        'capabilities',
      );
      if (value != null) _mergeRuntimeState(value);
    } on MissingPluginException {
      runtimeCapabilities = const {'activeBackend': null};
    } on PlatformException catch (error) {
      throw OfflineLlmFailure(
        error.code,
        error.message ?? error.code,
        error.details,
      );
    }
  }

  Future<void> _handleRuntimeMethodCall(MethodCall call) async {
    final arguments = call.arguments;
    if (arguments is! Map) return;
    if (call.method == 'downloadProgress') {
      final downloaded = arguments['downloadedBytes'];
      final total = arguments['totalBytes'];
      if (downloaded is num) downloadedBytes = downloaded.toInt();
      if (total is num) totalDownloadBytes = total.toInt();
      notifyListeners();
      return;
    }
    if (call.method != 'token') return;
    final generationId = arguments['generationId'];
    final text = arguments['text'];
    if (generationId != _activeGenerationId ||
        text is! String ||
        _stopRequested) {
      return;
    }
    _lastStreamedText = text;
    _activeTextCallback?.call(text);
  }

  Future<void> downloadModel() async {
    if (!supported) {
      throw UnsupportedError('$modelName QAIRT/NPU 模型当前仅支持 Android');
    }
    if (downloading) return;
    await initialize();
    if (modelReady) return;
    downloading = true;
    downloadedBytes = 0;
    totalDownloadBytes = 0;
    lastError = null;
    notifyListeners();
    try {
      final status = await _runtimeChannel.invokeMapMethod<Object?, Object?>(
        'download',
      );
      if (status == null || status['modelReady'] != true) {
        throw StateError('GenieX 下载完成后未检测到 Qwen3 QAIRT/NPU 模型');
      }
      _mergeRuntimeState(status);
      modelReady = true;
      final bytes = status['modelBytes'];
      if (bytes is num && bytes > 0) {
        downloadedBytes = bytes.toInt();
        totalDownloadBytes = bytes.toInt();
      }
    } on PlatformException catch (error) {
      lastError = error.message ?? error.code;
      throw OfflineLlmFailure(
        error.code,
        'Qwen3 QAIRT/NPU 模型下载失败：${error.message ?? error.code}',
        error.details,
      );
    } catch (error) {
      lastError = error.toString();
      rethrow;
    } finally {
      downloading = false;
      notifyListeners();
    }
  }

  Future<void> cancelDownload() async {
    if (!downloading) return;
    await _runtimeChannel.invokeMethod<void>('cancelDownload');
  }

  Future<void> deleteModel() async {
    if (generating) throw StateError('请先等待当前端侧回复完成');
    await _runtimeChannel.invokeMethod<void>('deleteModel');
    _runtimeLoaded = false;
    modelReady = false;
    downloadedBytes = 0;
    totalDownloadBytes = 0;
    runtimeCapabilities = {
      ...runtimeCapabilities,
      'activeBackend': null,
      'activeBackendVerified': false,
      'modelReady': false,
      'modelBytes': 0,
    };
    lastError = null;
    notifyListeners();
  }

  Future<void> _ensureRuntime() async {
    if (_runtimeLoaded) return;
    await initialize();
    if (!modelReady) throw StateError('请先下载 $modelName QAIRT/NPU 模型');
    loadingModel = true;
    lastError = null;
    notifyListeners();
    try {
      final result = await _runtimeChannel.invokeMapMethod<Object?, Object?>(
        'load',
      );
      if (result == null) throw StateError('GenieX 没有返回模型加载结果');
      _mergeRuntimeState(result);
      if (activeBackend != 'geniex-qairt-npu') {
        throw StateError('拒绝非 QAIRT/NPU 的 Qwen3 执行后端');
      }
      _runtimeLoaded = true;
    } on PlatformException catch (error) {
      lastError = error.message ?? error.code;
      throw OfflineLlmFailure(
        error.code,
        'Qwen3 QAIRT/NPU 模型加载失败：${error.message ?? error.code}',
        error.details,
      );
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
    final normalized = messages
        .where((message) => message.content.trim().isNotEmpty)
        .toList(growable: false);
    if (normalized.isEmpty) throw ArgumentError.value(messages, 'messages');
    generating = true;
    _stopRequested = false;
    final generationId = ++_nextGenerationId;
    _activeGenerationId = generationId;
    _activeTextCallback = onText;
    _lastStreamedText = '';
    lastError = null;
    notifyListeners();
    try {
      await _ensureRuntime();
      try {
        final result = await _runtimeChannel.invokeMethod<String>('generate', {
          'messages': normalized.map((message) => message.toMap()).toList(),
          'maxTokens': maxOutputTokens,
          'generationId': generationId,
        });
        if (_stopRequested) throw const OfflineGenerationCancelled();
        await _loadRuntimeCapabilities();
        final text = (result ?? '').trim();
        if (text.isEmpty) throw StateError('Qwen3 QAIRT/NPU 没有返回文本');
        if (_lastStreamedText.trim() != text) onText?.call(text);
        return text;
      } on PlatformException catch (error) {
        _runtimeLoaded = false;
        throw OfflineLlmFailure(
          error.code,
          'Qwen3 QAIRT/NPU 端侧生成失败：${error.message ?? error.code}',
          error.details,
        );
      }
    } catch (error) {
      if (error is! OfflineGenerationCancelled) lastError = error.toString();
      rethrow;
    } finally {
      _stopRequested = false;
      if (_activeGenerationId == generationId) {
        _activeGenerationId = null;
        _activeTextCallback = null;
        _lastStreamedText = '';
      }
      generating = false;
      notifyListeners();
    }
  }

  Future<void> stopGeneration() async {
    if (!generating) return;
    _stopRequested = true;
    await _runtimeChannel.invokeMethod<void>('stop');
  }

  void _mergeRuntimeState(Map<Object?, Object?> value) {
    runtimeCapabilities = {
      ...runtimeCapabilities,
      ...value.map((key, item) => MapEntry(key.toString(), item)),
    };
    if (value.containsKey('modelReady')) {
      modelReady = value['modelReady'] == true;
    }
  }

  @override
  void dispose() {
    if (_runtimeLoaded) {
      unawaited(_runtimeChannel.invokeMethod<void>('release'));
    }
    super.dispose();
  }
}
