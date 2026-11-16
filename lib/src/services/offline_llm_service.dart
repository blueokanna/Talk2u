import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:talk2u/src/l10n/app_strings.dart';

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
  String toString() => AppStrings.current.offlineGenerationStopped;
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
  static const maxOutputTokens = 1024;
  static const _runtimeChannel = MethodChannel('talk2u/llm_runtime');

  bool initialized = false;
  bool modelReady = false;
  bool downloading = false;
  bool loadingModel = false;
  bool generating = false;
  int downloadedBytes = 0;
  int totalDownloadBytes = 0;

  /// Smoothed bytes per second while a hub pull is running; 0 when unknown.
  double downloadBytesPerSecond = 0;
  DateTime? _lastSpeedSampleAt;
  int _lastSpeedSampleBytes = 0;
  String? lastError;

  /// Stable code for the current failure; settings maps it to localized text
  /// instead of rendering the raw (often native-language) message.
  String? lastErrorCode;
  Map<String, dynamic> runtimeCapabilities = const {};

  void _setLastError(String? code, String? message) {
    lastErrorCode = code;
    lastError = message;
  }

  Future<void>? _initializing;
  bool _runtimeLoaded = false;
  bool _stopRequested = false;
  Completer<void>? _generationDone;
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
      'geniex-qairt-npu' when verified => AppStrings.current.qnnAccelVerified,
      'geniex-qairt-npu' => AppStrings.current.qnnAccelLoadedPending,
      _ when modelReady => AppStrings.current.geniexNotLoaded,
      _ => AppStrings.current.geniexNotInstalled,
    };
  }

  double get downloadProgress => totalDownloadBytes <= 0
      ? 0
      : (downloadedBytes / totalDownloadBytes).clamp(0, 1);

  /// Remaining transfer time at the current smoothed rate, or null when the
  /// total size or rate is still unknown.
  Duration? get downloadEta {
    final total = totalDownloadBytes;
    final speed = downloadBytesPerSecond;
    if (!downloading || total <= 0 || speed <= 0) return null;
    final remaining = total - downloadedBytes;
    if (remaining <= 0) return Duration.zero;
    return Duration(seconds: (remaining / speed).ceil());
  }

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
      _setLastError(null, null);
    } catch (error) {
      modelReady = false;
      _setLastError(
        'qwen3_capabilities_failed',
        AppStrings.current.qwenCapabilitiesCheckFailed(modelName, '$error'),
      );
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
      _sampleDownloadSpeed();
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

  /// Smoothed transfer rate over real time, so a slow hub is visible instead of
  /// looking like a frozen percentage. Samples arrive far more often than 250 ms.
  void _sampleDownloadSpeed() {
    final now = DateTime.now();
    final last = _lastSpeedSampleAt;
    if (last == null) {
      _lastSpeedSampleAt = now;
      _lastSpeedSampleBytes = downloadedBytes;
      return;
    }
    final elapsed = now.difference(last);
    if (elapsed < const Duration(milliseconds: 250)) return;
    final deltaBytes = downloadedBytes - _lastSpeedSampleBytes;
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    _lastSpeedSampleAt = now;
    _lastSpeedSampleBytes = downloadedBytes;
    if (deltaBytes < 0 || seconds <= 0) return;
    final instant = deltaBytes / seconds;
    downloadBytesPerSecond = downloadBytesPerSecond <= 0
        ? instant
        : downloadBytesPerSecond * 0.7 + instant * 0.3;
  }

  void _resetDownloadTelemetry() {
    downloadBytesPerSecond = 0;
    _lastSpeedSampleAt = null;
    _lastSpeedSampleBytes = 0;
  }

  Future<void> downloadModel() async {
    if (!supported) {
      throw UnsupportedError(AppStrings.current.qwenAndroidOnly(modelName));
    }
    if (downloading) return;
    await initialize();
    if (modelReady) return;
    downloading = true;
    downloadedBytes = 0;
    totalDownloadBytes = 0;
    _setLastError(null, null);
    _resetDownloadTelemetry();
    notifyListeners();
    try {
      final status = await _runtimeChannel.invokeMapMethod<Object?, Object?>(
        'download',
      );
      if (status == null || status['modelReady'] != true) {
        throw StateError(AppStrings.current.qwenDownloadedNotDetected);
      }
      _mergeRuntimeState(status);
      modelReady = true;
      final bytes = status['modelBytes'];
      if (bytes is num && bytes > 0) {
        downloadedBytes = bytes.toInt();
        totalDownloadBytes = bytes.toInt();
      }
    } on PlatformException catch (error) {
      final raw = error.message ?? error.code;
      final cancelled = raw.toLowerCase().contains('cancel');
      // The SDK keeps partial files and resumes on the next pull, so a paused or
      // failed attempt never costs the bytes already transferred.
      lastError = cancelled
          ? AppStrings.current.qwenDownloadPausedDetail
          : AppStrings.current.qwenDownloadFailedDetail(raw);
      lastErrorCode = cancelled
          ? 'qwen3_download_cancelled'
          : 'qwen3_download_failed';
      _resetDownloadTelemetry();
      throw OfflineLlmFailure(
        error.code,
        cancelled
            ? AppStrings.current.qwenDownloadPaused
            : AppStrings.current.qwenDownloadFailedDetail(raw),
        error.details,
      );
    } catch (error) {
      _setLastError('qwen3_download_failed', error.toString());
      _resetDownloadTelemetry();
      rethrow;
    } finally {
      downloading = false;
      _resetDownloadTelemetry();
      notifyListeners();
    }
  }

  Future<void> cancelDownload() async {
    if (!downloading) return;
    await _runtimeChannel.invokeMethod<void>('cancelDownload');
  }

  Future<void> deleteModel() async {
    if (generating) throw StateError(AppStrings.current.waitForCurrentReply);
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
    _setLastError(null, null);
    notifyListeners();
  }

  Future<void> _ensureRuntime() async {
    if (_runtimeLoaded) return;
    await initialize();
    if (!modelReady) {
      throw StateError(AppStrings.current.qwenDownloadFirst(modelName));
    }
    loadingModel = true;
    _setLastError(null, null);
    notifyListeners();
    try {
      final result = await _runtimeChannel.invokeMapMethod<Object?, Object?>(
        'load',
      );
      if (result == null) {
        throw StateError(AppStrings.current.geniexLoadResultMissing);
      }
      _mergeRuntimeState(result);
      if (activeBackend != 'geniex-qairt-npu') {
        throw StateError(AppStrings.current.qwenBackendRejected);
      }
      _runtimeLoaded = true;
    } on PlatformException catch (error) {
      _setLastError('qwen3_load_failed', error.message ?? error.code);
      throw OfflineLlmFailure(
        error.code,
        AppStrings.current.qwenLoadFailedDetail(error.message ?? error.code),
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
    if (generating) throw StateError(AppStrings.current.offlineModelBusy);
    final normalized = messages
        .where((message) => message.content.trim().isNotEmpty)
        .toList(growable: false);
    if (normalized.isEmpty) throw ArgumentError.value(messages, 'messages');
    final generationDone = Completer<void>();
    _generationDone = generationDone;
    generating = true;
    _stopRequested = false;
    final generationId = ++_nextGenerationId;
    _activeGenerationId = generationId;
    _activeTextCallback = onText;
    _lastStreamedText = '';
    _setLastError(null, null);
    notifyListeners();
    try {
      await _ensureRuntime();
      if (_stopRequested) throw const OfflineGenerationCancelled();
      try {
        final result = await _runtimeChannel.invokeMethod<String>('generate', {
          'messages': normalized.map((message) => message.toMap()).toList(),
          'maxTokens': maxOutputTokens,
          'generationId': generationId,
        });
        if (_stopRequested) throw const OfflineGenerationCancelled();
        await _loadRuntimeCapabilities();
        if (_stopRequested) throw const OfflineGenerationCancelled();
        final text = (result ?? '').trim();
        if (text.isEmpty) {
          throw StateError(AppStrings.current.qwenEmptyResponse);
        }
        if (_lastStreamedText.trim() != text) onText?.call(text);
        return text;
      } on PlatformException catch (error) {
        if (_stopRequested) throw const OfflineGenerationCancelled();
        _runtimeLoaded = false;
        throw OfflineLlmFailure(
          error.code,
          AppStrings.current.qwenGenerateFailedDetail(
            error.message ?? error.code,
          ),
          error.details,
        );
      }
    } catch (error) {
      if (error is! OfflineGenerationCancelled) {
        _setLastError('qwen3_generate_failed', error.toString());
      }
      rethrow;
    } finally {
      _stopRequested = false;
      if (_activeGenerationId == generationId) {
        _activeGenerationId = null;
        _activeTextCallback = null;
        _lastStreamedText = '';
      }
      generating = false;
      _generationDone = null;
      try {
        notifyListeners();
      } finally {
        generationDone.complete();
      }
    }
  }

  Future<void> stopGeneration() async {
    final generationDone = _generationDone;
    if (generationDone == null) return;
    _stopRequested = true;
    try {
      await _runtimeChannel.invokeMethod<void>('stop');
    } finally {
      // A native stop acknowledgement can arrive before generate unwinds.
      await generationDone.future;
    }
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
