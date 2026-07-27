import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
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

class OfflineLlmFailure implements Exception {
  final String code;
  final String message;
  final Object? details;

  const OfflineLlmFailure(this.code, this.message, [this.details]);

  @override
  String toString() => message;
}

class OfflineLlmService extends ChangeNotifier {
  OfflineLlmService._();

  static final instance = OfflineLlmService._();

  static const modelName = 'Qwen3-4B-Instruct-2507';
  static const modelId = 'Qwen/Qwen3-4B-Instruct-2507';
  static const modelLicense = 'Apache-2.0';
  static const modelSize = 0;
  static const contextSize = 8192;
  static const maxOutputTokens = 768;
  static const _runtimeChannel = MethodChannel('talk2u/llm_runtime');
  static const _directoryName = 'qwen3-4b-instruct-2507-genie';
  static const _manifestName = 'talk2u-genie-manifest.json';
  static const _maximumEntries = 4096;
  static const _maximumExpandedBytes = 12 * 1024 * 1024 * 1024;

  bool initialized = false;
  bool modelReady = false;
  bool downloading = false;
  bool loadingModel = false;
  bool generating = false;
  int downloadedBytes = 0;
  int totalDownloadBytes = 0;
  String? lastError;
  String? fallbackNotice;
  Map<String, dynamic> runtimeCapabilities = const {};

  Future<void>? _initializing;
  String? _modelPath;
  bool _runtimeLoaded = false;
  bool _stopRequested = false;

  bool get supported => defaultTargetPlatform == TargetPlatform.android;
  bool get usingCpuFallback =>
      runtimeCapabilities['activeBackend']?.toString() == 'cpu';
  String? get activeBackend => runtimeCapabilities['activeBackend']?.toString();
  bool get hardwareAccelerationVerified =>
      runtimeCapabilities['activeBackendVerified'] == true &&
      activeBackend == 'qnn-htp';

  String get accelerationDescription {
    final backend = activeBackend;
    final verified = runtimeCapabilities['activeBackendVerified'] == true;
    final failures = runtimeCapabilities['fallbackFailures'];
    final htpFailed = failures is List && failures.isNotEmpty;
    return switch (backend) {
      'qnn-htp' when verified => 'Qualcomm QNN HTP/NPU',
      'qnn-htp' => 'QNN HTP 已加载，等待首轮执行验证',
      'cpu' when htpFailed => 'Snapdragon CPU（QNN HTP 加载失败）',
      'cpu' => 'Snapdragon CPU（部署包不含 HTP 工件）',
      _ => '等待验证 HTP/CPU 后端',
    };
  }

  String? get modelPath => _modelPath;
  double get downloadProgress => totalDownloadBytes <= 0
      ? 0
      : (downloadedBytes / totalDownloadBytes).clamp(0, 1);

  Future<Directory> _modelDirectory() async {
    final root = await getApplicationSupportDirectory();
    return Directory(p.join(root.path, 'models', _directoryName));
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
      final directory = await _modelDirectory();
      modelReady = await _validateDeployment(directory);
      _modelPath = modelReady ? directory.path : null;
      lastError = null;
    } catch (error) {
      modelReady = false;
      lastError = '无法检查 Qwen3 Genie 部署包: $error';
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
      if (value != null) {
        runtimeCapabilities = value.map(
          (key, item) => MapEntry(key.toString(), item),
        );
      }
    } on MissingPluginException {
      runtimeCapabilities = const {
        'activeBackend': null,
        'genieRuntimePresent': false,
      };
    } on PlatformException catch (error) {
      debugPrint('Unable to query Android Genie runtime: $error');
    }
  }

  Future<void> downloadModel() async {
    if (!supported) {
      throw UnsupportedError('Qwen3 Genie 部署包当前仅支持 Android');
    }
    final selection = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 Qwen3-4B-Instruct-2507 Genie 部署 ZIP',
      type: FileType.custom,
      allowedExtensions: const ['zip'],
      allowMultiple: false,
      withData: false,
    );
    final sourcePath = selection?.files.single.path;
    if (sourcePath == null) return;

    downloading = true;
    lastError = null;
    fallbackNotice = null;
    final source = File(sourcePath);
    totalDownloadBytes = await source.length();
    downloadedBytes = 0;
    notifyListeners();

    final destination = await _modelDirectory();
    final staging = Directory('${destination.path}.installing');
    final backup = Directory('${destination.path}.previous');
    final previousReady = modelReady;
    final previousPath = _modelPath;
    try {
      await Isolate.run(
        () => _installDeploymentArchive(source.path, staging.path),
      );
      if (!await _validateDeployment(staging, verifyHashes: true)) {
        throw const FormatException('部署 ZIP 的清单或 SHA-256 校验失败');
      }
      await _runtimeChannel.invokeMethod<void>('release');
      _runtimeLoaded = false;
      if (await backup.exists()) {
        if (await destination.exists()) {
          await backup.delete(recursive: true);
        } else {
          await backup.rename(destination.path);
        }
      }
      if (await destination.exists()) await destination.rename(backup.path);
      await staging.rename(destination.path);
      modelReady = true;
      _modelPath = destination.path;
      downloadedBytes = totalDownloadBytes;
      if (await backup.exists()) {
        try {
          await backup.delete(recursive: true);
        } catch (error) {
          debugPrint('Unable to remove previous Qwen3 deployment: $error');
        }
      }
    } catch (error) {
      lastError = error.toString();
      if (await staging.exists()) await staging.delete(recursive: true);
      if (!await destination.exists() && await backup.exists()) {
        await backup.rename(destination.path);
      }
      modelReady = previousReady;
      _modelPath = previousPath;
      rethrow;
    } finally {
      downloading = false;
      notifyListeners();
    }
  }

  Future<void> deleteModel() async {
    if (generating) throw StateError('请先等待当前端侧回复完成');
    await _runtimeChannel.invokeMethod<void>('release');
    _runtimeLoaded = false;
    final directory = await _modelDirectory();
    if (await directory.exists()) await directory.delete(recursive: true);
    final staging = Directory('${directory.path}.installing');
    if (await staging.exists()) await staging.delete(recursive: true);
    modelReady = false;
    downloadedBytes = 0;
    totalDownloadBytes = 0;
    _modelPath = null;
    fallbackNotice = null;
    lastError = null;
    notifyListeners();
  }

  Future<void> _ensureRuntime() async {
    if (_runtimeLoaded) return;
    await initialize();
    final path = _modelPath;
    if (!modelReady || path == null) {
      throw StateError('请先安装 $modelName 的 Genie 部署 ZIP');
    }
    loadingModel = true;
    lastError = null;
    notifyListeners();
    try {
      final result = await _runtimeChannel.invokeMapMethod<Object?, Object?>(
        'load',
        {'modelRoot': path},
      );
      if (result == null) throw StateError('Genie 没有返回加载结果');
      runtimeCapabilities = {
        ...runtimeCapabilities,
        ...result.map((key, value) => MapEntry(key.toString(), value)),
      };
      _runtimeLoaded = true;
      if (usingCpuFallback) {
        final failures = runtimeCapabilities['fallbackFailures'];
        fallbackNotice = failures is List && failures.isNotEmpty
            ? 'QNN HTP 加载失败，Qwen3 已回退到 Snapdragon CPU：${failures.join('; ')}'
            : '当前 Genie 部署包仅包含 CPU 模型工件；要使用 NPU，请安装带有已验证 SM8850/V81 qnn-htp 后端的部署包。';
      } else {
        fallbackNotice = null;
      }
    } on PlatformException catch (error) {
      lastError = error.message ?? error.code;
      throw OfflineLlmFailure(
        error.code,
        'Qwen3 端侧模型加载失败：${error.message ?? error.code}',
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
    generating = true;
    _stopRequested = false;
    lastError = null;
    notifyListeners();
    try {
      await _ensureRuntime();
      final arguments = <String, Object>{
        'prompt': formatQwenChatPrompt(messages),
        'maxTokens': maxOutputTokens,
        'modelRoot': _modelPath!,
      };
      try {
        final result = await _runtimeChannel.invokeMethod<String>(
          'generate',
          arguments,
        );
        if (_stopRequested) throw const OfflineGenerationCancelled();
        await _loadRuntimeCapabilities();
        final text = (result ?? '').trim();
        if (text.isEmpty) throw StateError('Qwen3 Genie 没有返回文本');
        onText?.call(text);
        return text;
      } on PlatformException catch (error) {
        _runtimeLoaded = false;
        throw OfflineLlmFailure(
          error.code,
          'Qwen3 端侧生成失败：${error.message ?? error.code}',
          error.details,
        );
      }
    } catch (error) {
      if (error is! OfflineGenerationCancelled) lastError = error.toString();
      rethrow;
    } finally {
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
    if (!generating) return;
    _stopRequested = true;
    await _runtimeChannel.invokeMethod<void>('stop');
  }

  @override
  void dispose() {
    if (_runtimeLoaded) {
      unawaited(_runtimeChannel.invokeMethod<void>('release'));
    }
    super.dispose();
  }

  static Future<bool> _validateDeployment(
    Directory directory, {
    bool verifyHashes = false,
  }) async {
    final manifest = File(p.join(directory.path, _manifestName));
    if (!await manifest.isFile()) return false;
    final decoded = jsonDecode(await manifest.readAsString());
    if (decoded is! Map<String, dynamic> ||
        decoded['schemaVersion'] != 1 ||
        decoded['modelId'] != modelId) {
      return false;
    }
    final backends = decoded['backends'];
    final files = decoded['files'];
    if (backends is! List ||
        files is! List ||
        backends.isEmpty ||
        files.isEmpty) {
      return false;
    }
    final backendIds = backends
        .whereType<Map>()
        .map((item) => item['id'])
        .whereType<String>()
        .toSet();
    if (!backendIds.contains('cpu')) return false;
    for (final raw in files) {
      if (raw is! Map) return false;
      final relative = raw['path'];
      final expectedBytes = raw['bytes'];
      final expectedHash = raw['sha256'];
      if (relative is! String ||
          expectedBytes is! int ||
          expectedHash is! String ||
          !_isSafeRelativePath(relative)) {
        return false;
      }
      final file = File(
        p.joinAll([directory.path, ...p.posix.split(relative)]),
      );
      if (!await file.isFile() || await file.length() != expectedBytes) {
        return false;
      }
      // Imported archives are fully hashed before the atomic install. The
      // installed directory is app-private, so startup only needs inexpensive
      // structural and exact-size checks instead of rehashing multi-GB weights.
      if (verifyHashes) {
        final actual = await sha256.bind(file.openRead()).first;
        if (actual.toString() != expectedHash.toLowerCase()) return false;
      }
    }
    return true;
  }

  static void _installDeploymentArchive(String sourcePath, String outputPath) {
    final output = Directory(outputPath);
    if (output.existsSync()) output.deleteSync(recursive: true);
    output.createSync(recursive: true);
    InputFileStream? input;
    try {
      input = InputFileStream(sourcePath);
      final archive = ZipDecoder().decodeStream(input);
      if (archive.isEmpty || archive.length > _maximumEntries) {
        throw const FormatException('部署 ZIP 为空或条目过多');
      }
      var expandedBytes = 0;
      for (final entry in archive) {
        final relative = entry.name.replaceAll('\\', '/');
        if (!_isSafeRelativePath(relative)) {
          throw FormatException('部署 ZIP 包含越界路径: ${entry.name}');
        }
        expandedBytes += entry.size;
        if (expandedBytes > _maximumExpandedBytes) {
          throw const FormatException('部署 ZIP 解压后超过 12 GiB 限制');
        }
        final destination = p.joinAll([
          output.path,
          ...p.posix.split(relative),
        ]);
        if (entry.isDirectory) {
          Directory(destination).createSync(recursive: true);
        } else if (entry.isFile) {
          Directory(p.dirname(destination)).createSync(recursive: true);
          final stream = OutputFileStream(destination);
          try {
            entry.writeContent(stream);
          } finally {
            stream.closeSync();
          }
        } else {
          throw FormatException('部署 ZIP 包含不支持的链接: ${entry.name}');
        }
      }
    } catch (_) {
      if (output.existsSync()) output.deleteSync(recursive: true);
      rethrow;
    } finally {
      input?.closeSync();
    }
  }

  static bool _isSafeRelativePath(String value) {
    final normalized = p.posix.normalize(value.replaceAll('\\', '/'));
    return normalized.isNotEmpty &&
        normalized != '.' &&
        !p.posix.isAbsolute(normalized) &&
        normalized != '..' &&
        !normalized.startsWith('../') &&
        !RegExp(r'^[A-Za-z]:').hasMatch(normalized);
  }
}

extension on File {
  Future<bool> isFile() async =>
      await exists() && (await stat()).type == FileSystemEntityType.file;
}
