import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:talk2u/src/l10n/app_strings.dart';

/// One chat turn handed to the on-device model.
@immutable
class OfflineChatMessage {
  const OfflineChatMessage({required this.role, required this.content});

  final String role;
  final String content;

  Map<String, String> toMap() => {'role': role, 'content': content};
}

/// One Qwen3-4B-Instruct-2507 identity this build serves.
///
/// The two checkpoints share the ChatML template, the 4096-token context and
/// the output cap. They differ in weights and in how they can be installed:
/// [abliterated] has no published QAIRT bundle, so it is import-only, while
/// [base] is the upstream checkpoint whose Qualcomm bundle can be pulled from
/// the AI Hub catalog.
///
/// The identities are data, not an enum, because the native runtime reports the
/// authoritative list in `capabilities['presets']` (including the hub key and the
/// license). Hard-coding the ids in Dart would let the UI advertise a model the
/// installed GenieX build cannot load, which is exactly the failure this class
/// exists to prevent.
@immutable
class OfflineModelPreset {
  const OfflineModelPreset({
    required this.id,
    required this.displayName,
    required this.family,
    required this.repo,
    required this.baseModel,
    required this.license,
    this.hubModel,
  });

  /// Parses one entry of the native preset report. Missing optional fields are
  /// kept empty rather than invented.
  static OfflineModelPreset? tryParse(Object? value) {
    if (value is! Map) return null;
    final id = value['id']?.toString();
    if (id == null || id.isEmpty) return null;
    return OfflineModelPreset(
      id: id,
      displayName: value['displayName']?.toString() ?? id,
      family: value['family']?.toString() ?? '',
      repo: value['huggingFaceRepo']?.toString() ?? '',
      baseModel: value['baseModel']?.toString() ?? '',
      license: value['license']?.toString() ?? '',
      hubModel: value['hubModel']?.toString(),
    );
  }

  /// The abliterated derivative. Import only: no public compiled bundle exists.
  static const abliterated = OfflineModelPreset(
    id: 'abliterated',
    displayName: 'Huihui-Qwen3-4B-Instruct-2507-abliterated',
    family: 'Qwen3-4B-Instruct-2507',
    repo: 'huihui-ai/Huihui-Qwen3-4B-Instruct-2507-abliterated',
    baseModel: 'Qwen/Qwen3-4B-Instruct-2507',
    license: 'Apache-2.0',
  );

  /// The upstream checkpoint with Qualcomm's published QAIRT bundle.
  static const base = OfflineModelPreset(
    id: 'base',
    displayName: 'Qwen3-4B-Instruct-2507',
    family: 'Qwen3-4B-Instruct-2507',
    repo: 'Qwen/Qwen3-4B-Instruct-2507',
    baseModel: 'Qwen/Qwen3-4B-Instruct-2507',
    license: 'Apache-2.0',
    hubModel: 'ai-hub-models/Qwen3-4B-Instruct-2507',
  );

  /// Fallback list used before the native runtime answers.
  static const builtIn = [abliterated, base];

  final String id;
  final String displayName;

  /// Checkpoint family both presets derive from.
  final String family;
  final String repo;
  final String baseModel;
  final String license;

  /// GenieX AI Hub catalog key; null when no compiled bundle is published.
  final String? hubModel;

  bool get hasHubBundle => hubModel != null && hubModel!.isNotEmpty;

  /// True for the upstream checkpoint, false for the abliterated derivative.
  bool get isUpstream => id == base.id;
}

/// Artifact formats the on-device runtime can execute.
///
/// The abliterated weights are published as safetensors, which no mobile runtime
/// executes directly, so a compiled artifact has to be installed:
///
/// * [qairtBundle] — QAIRT context binaries produced for the target SoC,
///   executed on the Hexagon NPU by the QAIRT plugin;
/// * [gguf] — a llama.cpp checkpoint of the same weights. GenieX ships the
///   ggml-hexagon backend, so a GGUF runs on the **Hexagon NPU** too; the GPU
///   (OpenCL) and CPU paths are the fallbacks when the HTP backend is not
///   available for the device.
enum OfflineModelArtifact {
  qairtBundle('importQairtBundle'),
  gguf('importGguf');

  const OfflineModelArtifact(this.channelMethod);

  /// Native method that opens the file picker and installs the artifact.
  final String channelMethod;
}

/// One accelerator the native runtime reports, with the reason it is or is not
/// usable for the installed artifact.
@immutable
class OfflineAccelerator {
  const OfflineAccelerator({
    required this.id,
    required this.backendId,
    required this.accelerator,
    required this.available,
    required this.detail,
    required this.usability,
    required this.requires,
  });

  factory OfflineAccelerator.fromMap(Map<Object?, Object?> value) {
    return OfflineAccelerator(
      id: value['id']?.toString() ?? '',
      backendId: value['backendId']?.toString() ?? '',
      accelerator: value['accelerator']?.toString() ?? '',
      available: value['available'] == true,
      detail: value['detail']?.toString() ?? '',
      usability: value['usability']?.toString() ?? '',
      requires: value['requires']?.toString() ?? '',
    );
  }

  final String id;
  final String backendId;

  /// `npu`, `gpu` or `cpu`: the bucket the settings card groups by.
  final String accelerator;
  final bool available;
  final String detail;
  final String usability;

  /// Artifact kind this accelerator needs.
  final String requires;
}

/// Thrown when the user (or the Activity lifecycle) stops an import.
class OfflineGenerationCancelled implements Exception {
  const OfflineGenerationCancelled();

  @override
  String toString() => AppStrings.current.offlineGenerationStopped;
}

/// A typed failure from the native on-device runtime.
class OfflineLlmFailure implements Exception {
  const OfflineLlmFailure(this.code, this.message, [this.details]);

  final String code;
  final String message;
  final Object? details;

  @override
  String toString() => message;
}

/// Owns the single on-device language model.
///
/// The runtime is hardware-driven, so this service never guesses what a device
/// can do: [accelerators], [activeBackend] and [hardwareAccelerationVerified] are
/// filled from the native report, and the UI shows the reason an accelerator is
/// unusable instead of a marketing claim.
class OfflineLlmService extends ChangeNotifier {
  OfflineLlmService._() {
    _runtimeChannel.setMethodCallHandler(_handleRuntimeMethodCall);
  }

  static final instance = OfflineLlmService._();

  /// Family name used in diagnostics before the native preset report arrives.
  ///
  /// The upstream checkpoint is the identity the app shipped with, so it stays
  /// the default label; the installed preset replaces it as soon as the runtime
  /// reports one.
  static const modelName = 'Qwen3-4B-Instruct-2507';

  /// License inherited from the base model.
  static const modelLicense = 'Apache-2.0';

  static const contextSize = 4096;

  /// Upper bound for one reply, not a fixed reservation.
  ///
  /// The actual budget is `context - prompt - safety margin` (see
  /// [ChatState]); a short turn can therefore use the full 3072 tokens while a
  /// long history still leaves room for at least 512 output tokens.
  static const maxOutputTokens = 3072;

  /// Backends that actually execute outside the CPU.
  ///
  /// `geniex-llamacpp-npu` is the ggml-hexagon path: a GGUF offloaded to the
  /// Hexagon NPU through the llama.cpp plugin.
  static const acceleratedBackends = {
    'geniex-qairt-npu',
    'geniex-llamacpp-npu',
    'geniex-llamacpp-gpu',
  };

  static const acceleratorIds = ['auto', 'npu', 'gpu', 'cpu'];

  static const _runtimeChannel = MethodChannel('talk2u/llm_runtime');

  bool initialized = false;
  bool modelReady = false;
  bool importing = false;
  bool loadingModel = false;
  bool generating = false;

  /// Preset that is installed right now, when one is.
  OfflineModelPreset? installedPreset;

  /// Stable kind of the installed artifact (`qairt-bundle` or `gguf`).
  String? artifactKind;
  String? artifactPath;
  String? artifactName;

  /// GGUF `general.file_type` label (for example `Q4_0`), null for QAIRT.
  String? artifactQuantization;

  /// True when the GGUF quantization is one GenieX documents as HTP-clean.
  ///
  /// The native importer rejects any other quantization, so this is a record of
  /// what was installed rather than a reason to open a CPU-fallback session.
  bool? artifactNpuClean;

  int importedBytes = 0;
  int totalImportBytes = 0;

  /// Smoothed bytes per second while an import runs; 0 when unknown.
  double importBytesPerSecond = 0;
  DateTime? _lastSpeedSampleAt;
  int _lastSpeedSampleBytes = 0;

  String? lastError;

  /// Stable code for the current failure; the settings page maps it to localized
  /// text instead of rendering a raw native message.
  String? lastErrorCode;

  Map<String, dynamic> runtimeCapabilities = const {};

  /// `auto`, `npu`, `gpu` or `cpu`.
  ///
  /// `auto` means NPU first, then CPU for an on-device GGUF. The GPU path is an
  /// explicit diagnostic choice and is never part of the automatic ladder. If
  /// the NPU session cannot be created, the CPU fallback is opened and the UI
  /// reports the fallback reason instead of pretending the turn ran on the NPU.
  String acceleratorPreference = 'auto';

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

  /// True only for a backend that executes on an accelerator, after a completed
  /// turn proved it: a loaded session alone is not evidence.
  bool get hardwareAccelerationVerified =>
      runtimeCapabilities['activeBackendVerified'] == true &&
      acceleratedBackends.contains(activeBackend);

  bool get usingCpu => activeBackend == 'geniex-llamacpp-cpu';

  String? get preferredAccelerator =>
      runtimeCapabilities['preferredAccelerator']?.toString();

  List<OfflineAccelerator> get accelerators {
    final raw = runtimeCapabilities['accelerators'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map(OfflineAccelerator.fromMap)
        .where((accelerator) => accelerator.id.isNotEmpty)
        .toList(growable: false);
  }

  /// Reasons the NPU candidate was rejected before the current session opened.
  ///
  /// Rendered when the active backend is the CPU fallback, so a downgrade is
  /// visible in the card instead of only in diagnostics.
  List<String> get rejectedAccelerators {
    final raw = runtimeCapabilities['rejectedAccelerators'];
    if (raw is! List) return const [];
    return raw
        .map((value) => value?.toString().trim() ?? '')
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }

  OfflineAccelerator? accelerator(String id) {
    for (final candidate in accelerators) {
      if (candidate.id == id) return candidate;
    }
    return null;
  }

  String get accelerationDescription {
    final verified = runtimeCapabilities['activeBackendVerified'] == true;
    final backend = activeBackend;
    final strings = AppStrings.current;
    // Both NPU engines (QAIRT context binaries and llama.cpp's ggml-hexagon
    // backend) are the same accelerator from the user's point of view.
    if (backend == 'geniex-qairt-npu' || backend == 'geniex-llamacpp-npu') {
      return verified ? strings.qwenAccelNpu : strings.qwenAccelPending;
    }
    if (backend == 'geniex-llamacpp-gpu') {
      return verified ? strings.qwenAccelGpu : strings.qwenAccelPending;
    }
    if (backend == 'geniex-llamacpp-cpu') return strings.qwenAccelCpu;
    return modelReady ? strings.qwenAccelNotLoaded : strings.geniexNotInstalled;
  }

  /// Model name to show when no artifact is installed.
  ///
  /// The upstream checkpoint is preferred over the derivative, because that is
  /// the identity this app shipped with and the only one with a published QAIRT
  /// bundle. An installed artifact always wins.
  String get displayName {
    final installed = installedPreset;
    if (installed != null) return installed.displayName;
    for (final preset in presets) {
      if (preset.isUpstream) return preset.displayName;
    }
    return presets.first.displayName;
  }

  /// Presets the native runtime can install.
  ///
  /// Until `capabilities` has answered, the built-in identities are used; after
  /// that, the native list wins, because it carries the hub key and license the
  /// installed GenieX build actually supports.
  List<OfflineModelPreset> get presets {
    final raw = runtimeCapabilities['presets'];
    if (raw is List) {
      final parsed = raw
          .map(OfflineModelPreset.tryParse)
          .whereType<OfflineModelPreset>()
          .toList(growable: false);
      if (parsed.isNotEmpty) return _upstreamFirst(parsed);
    }
    return _upstreamFirst(OfflineModelPreset.builtIn);
  }

  /// Puts the upstream checkpoint first.
  ///
  /// Native enumeration order is an implementation detail of the Kotlin enum;
  /// the settings card reads this list top-down, and the upstream checkpoint is
  /// the identity the app shipped with and the only one with a published QAIRT
  /// bundle. Ordering it first is a product decision, not a data decision, so it
  /// lives here rather than in the UI.
  List<OfflineModelPreset> _upstreamFirst(List<OfflineModelPreset> source) {
    final index = source.indexWhere((preset) => preset.isUpstream);
    if (index <= 0) return List.unmodifiable(source);
    return List.unmodifiable([
      source[index],
      ...source.where((preset) => !preset.isUpstream),
    ]);
  }

  /// Resolves [id] against the reported presets, then the built-ins.
  OfflineModelPreset? presetById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final preset in presets) {
      if (preset.id == id) return preset;
    }
    for (final preset in OfflineModelPreset.builtIn) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  /// The preset an AI Hub download targets: the upstream checkpoint.
  OfflineModelPreset get defaultHubPreset {
    for (final preset in presets) {
      if (preset.hasHubBundle) return preset;
    }
    return OfflineModelPreset.base;
  }

  double get importProgress => totalImportBytes <= 0
      ? 0
      : (importedBytes / totalImportBytes).clamp(0, 1);

  /// Remaining copy time at the current smoothed rate, or null when the total
  /// size or rate is still unknown.
  Duration? get importEta {
    final total = totalImportBytes;
    final speed = importBytesPerSecond;
    if (!importing || total <= 0 || speed <= 0) return null;
    final remaining = total - importedBytes;
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
      _readArtifact(runtimeCapabilities);
      final bytes = runtimeCapabilities['modelBytes'];
      if (bytes is num && bytes > 0) {
        importedBytes = bytes.toInt();
        totalImportBytes = bytes.toInt();
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
    if (call.method == 'importProgress') {
      final copied = arguments['copiedBytes'];
      final total = arguments['totalBytes'];
      if (copied is num) importedBytes = copied.toInt();
      if (total is num) totalImportBytes = total.toInt();
      _sampleImportSpeed();
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

  /// Smoothed copy rate over real time, so a slow provider is visible instead of
  /// looking like a frozen percentage. Samples arrive at most every 250 ms.
  void _sampleImportSpeed() {
    final now = DateTime.now();
    final last = _lastSpeedSampleAt;
    if (last == null) {
      _lastSpeedSampleAt = now;
      _lastSpeedSampleBytes = importedBytes;
      return;
    }
    final elapsed = now.difference(last);
    if (elapsed < const Duration(milliseconds: 250)) return;
    final deltaBytes = importedBytes - _lastSpeedSampleBytes;
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    _lastSpeedSampleAt = now;
    _lastSpeedSampleBytes = importedBytes;
    if (deltaBytes < 0 || seconds <= 0) return;
    final instant = deltaBytes / seconds;
    importBytesPerSecond = importBytesPerSecond <= 0
        ? instant
        : importBytesPerSecond * 0.7 + instant * 0.3;
  }

  void _resetImportTelemetry() {
    importBytesPerSecond = 0;
    _lastSpeedSampleAt = null;
    _lastSpeedSampleBytes = 0;
  }

  /// Installs [artifact] of [preset] through the native file picker.
  ///
  /// The native side copies into staging, validates, and only then swaps the
  /// artifact into place, so a cancelled or rejected import leaves a previously
  /// working model untouched.
  Future<void> importArtifact(
    OfflineModelArtifact artifact, {
    OfflineModelPreset? preset,
  }) {
    return _install(
      artifact.channelMethod,
      preset ?? OfflineModelPreset.abliterated,
    );
  }

  /// Downloads Qualcomm's published QAIRT bundle for [preset].
  ///
  /// This is the original on-device path: GenieX pulls the chipset-matched
  /// bundle from the AI Hub catalog. Only the upstream checkpoint has an entry
  /// there, so the abliterated preset is rejected by the native side with a
  /// message that says to import a compiled artifact instead. [preset] defaults
  /// to the reported upstream preset, which is exactly the identity the app
  /// keeps for this path.
  Future<void> downloadFromHub({OfflineModelPreset? preset}) {
    return _install('downloadHub', preset ?? defaultHubPreset);
  }

  Future<void> _install(String method, OfflineModelPreset preset) async {
    if (!supported) {
      throw UnsupportedError(
        AppStrings.current.qwenAndroidOnly(preset.displayName),
      );
    }
    if (importing) return;
    await initialize();
    importing = true;
    importedBytes = 0;
    totalImportBytes = 0;
    _setLastError(null, null);
    _resetImportTelemetry();
    notifyListeners();
    try {
      final status = await _runtimeChannel.invokeMapMethod<Object?, Object?>(
        method,
        {'modelId': preset.id},
      );
      if (status == null || status['modelReady'] != true) {
        throw StateError(AppStrings.current.qwenImportedNotDetected);
      }
      _mergeRuntimeState(status);
      _readArtifact(status);
      modelReady = true;
      final bytes = status['modelBytes'];
      if (bytes is num && bytes > 0) {
        importedBytes = bytes.toInt();
        totalImportBytes = bytes.toInt();
      }
      _runtimeLoaded = false;
    } on PlatformException catch (error) {
      final cancelled =
          error.code == 'qwen3_import_cancelled' ||
          error.code == 'activity_destroyed';
      final details = error.details;
      final quantization = details is Map
          ? details['quantization']?.toString()
          : null;
      // The picker also answers a cancelled dialog; that is not an error the
      // user needs to read a stack trace about.
      lastError = cancelled
          ? AppStrings.current.qwenImportCancelledDetail
          : error.code == 'qwen3_gguf_quantization' &&
                quantization != null &&
                quantization.isNotEmpty
          ? AppStrings.current.qwenGgufQuantizationUnsupported(quantization)
          : AppStrings.current.qwenImportFailedDetail(
              error.message ?? error.code,
            );
      lastErrorCode = cancelled
          ? 'qwen3_import_cancelled'
          : error.code == 'qwen3_gguf_quantization'
          ? 'qwen3_gguf_quantization'
          : 'qwen3_import_failed';
      throw OfflineLlmFailure(error.code, lastError!, error.details);
    } catch (error) {
      _setLastError('qwen3_import_failed', error.toString());
      rethrow;
    } finally {
      importing = false;
      _resetImportTelemetry();
      notifyListeners();
    }
  }

  Future<void> cancelImport() async {
    if (!importing) return;
    await _runtimeChannel.invokeMethod<void>('cancelImport');
  }

  Future<void> deleteModel() async {
    if (generating) throw StateError(AppStrings.current.waitForCurrentReply);
    await _runtimeChannel.invokeMethod<void>('deleteModel');
    _runtimeLoaded = false;
    modelReady = false;
    importedBytes = 0;
    totalImportBytes = 0;
    artifactKind = null;
    artifactPath = null;
    artifactName = null;
    artifactQuantization = null;
    artifactNpuClean = null;
    installedPreset = null;
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

  /// Sets the accelerator used by the next session: `auto`, `npu`, `gpu`, `cpu`.
  ///
  /// An unsatisfiable request throws on load instead of silently running
  /// somewhere else, so the UI can tell the user to import the right artifact.
  void setAccelerator(String? value) {
    final next = value ?? 'auto';
    if (!acceleratorIds.contains(next)) {
      throw ArgumentError.value(value, 'accelerator');
    }
    if (acceleratorPreference == next) return;
    acceleratorPreference = next;
    notifyListeners();
  }

  Future<void> _ensureRuntime({String? accelerator}) async {
    if (_runtimeLoaded) return;
    await initialize();
    if (!modelReady) {
      throw StateError(
        AppStrings.current.qwenInstallFirst(
          installedPreset?.displayName ?? displayName,
        ),
      );
    }
    loadingModel = true;
    _setLastError(null, null);
    notifyListeners();
    try {
      final result = await _runtimeChannel.invokeMapMethod<Object?, Object?>(
        'load',
        {'accelerator': accelerator ?? acceleratorPreference},
      );
      if (result == null) {
        throw StateError(AppStrings.current.geniexLoadResultMissing);
      }
      _mergeRuntimeState(result);
      final backend = result['activeBackend'];
      if (backend is! String || backend.isEmpty) {
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
    String? accelerator,
    int? maxTokens,
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
      await _ensureRuntime(accelerator: accelerator);
      if (_stopRequested) throw const OfflineGenerationCancelled();
      try {
        final result = await _runtimeChannel.invokeMethod<String>('generate', {
          'messages': normalized.map((message) => message.toMap()).toList(),
          'maxTokens': (maxTokens ?? maxOutputTokens).clamp(
            256,
            maxOutputTokens,
          ),
          'generationId': generationId,
          'accelerator': accelerator ?? acceleratorPreference,
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
    _readArtifact(value);
  }

  void _readArtifact(Map<Object?, Object?> value) {
    final artifact = value['artifact'];
    if (artifact is! Map) {
      if (value.containsKey('artifact') && artifact == null) {
        installedPreset = null;
        artifactKind = null;
        artifactPath = null;
        artifactName = null;
        artifactQuantization = null;
        artifactNpuClean = null;
      }
      return;
    }
    installedPreset = presetById(artifact['modelId']?.toString());
    artifactKind = artifact['kind']?.toString();
    artifactPath = artifact['path']?.toString();
    artifactName = artifact['declaredName']?.toString();
    artifactQuantization = artifact['quantization']?.toString();
    final npuClean = artifact['npuClean'];
    artifactNpuClean = npuClean is bool ? npuClean : null;
  }

  @override
  void dispose() {
    if (_runtimeLoaded) {
      unawaited(_runtimeChannel.invokeMethod<void>('release'));
    }
    super.dispose();
  }
}
