import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:talk2u/src/l10n/app_strings.dart';
import 'package:talk2u/src/lexicon/moss_voice_catalog.dart';
import 'package:talk2u/src/lexicon/speech_cue_lexicon.dart';
import 'package:talk2u/src/services/speech_stream.dart';
import 'package:talk2u/src/services/speech_text_normalizer.dart';

export 'package:talk2u/src/lexicon/moss_voice_catalog.dart' show MossVoice;

/// Setup stages surfaced by the settings card. User-visible text lives in ARB;
/// services only report the stage.
enum MossOperation {
  idle,
  initializingRuntime,
  runtimeReady,
  chooseDirectory,
  chooseZip,
  importing,
  imported,
  importedAndInitialized,
}

@immutable
class _MossAudio {
  final File file;
  final List<double> amplitudeEnvelope;

  const _MossAudio(this.file, this.amplitudeEnvelope);
}

class _MossCancelled implements Exception {
  const _MossCancelled();
}

/// Internal sentinel: the streaming text source has produced every chunk.
class _MossStreamEnd implements Exception {
  const _MossStreamEnd();
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
  MossTtsService._({
    AudioPlayer? player,
    MethodChannel? channel,
    bool? platformSupported,
    Future<Directory> Function()? temporaryDirectory,
    Future<Directory> Function()? supportDirectory,
  }) : _player = player ?? AudioPlayer(),
       _channel = channel ?? const MethodChannel('talk2u/moss_tts'),
       _platformSupported = platformSupported,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory {
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
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  /// Handles the one native callback the MOSS channel sends.
  ///
  /// The SAF picker returns *inside* the blocking `importModel`/`importModelZip`
  /// call, so Dart cannot observe when the user actually picked a package. The
  /// native side announces the transition; without it the card keeps saying
  /// "choose a file" for the whole import.
  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'importStarted') return;
    if (operation == MossOperation.importing) return;
    operation = MossOperation.importing;
    lastError = null;
    lastErrorCode = null;
    notifyListeners();
  }

  @visibleForTesting
  factory MossTtsService.forTesting({
    required AudioPlayer player,
    required MethodChannel channel,
    required Future<Directory> Function() directory,
  }) => MossTtsService._(
    player: player,
    channel: channel,
    platformSupported: true,
    temporaryDirectory: directory,
    supportDirectory: directory,
  );

  static final instance = MossTtsService._();
  static const engineName = 'MOSS-TTS-Nano ONNX';
  static const engineLicense = 'Apache-2.0';
  static const modelName = 'MOSS-TTS-Nano 100M ONNX';
  static const amplitudeFrameMilliseconds = 20;

  /// Nominal size of a full deployment package. Only a hint for the UI: the
  /// installed size is measured by the native importer and replaces it.
  static const estimatedModelBytes = 717414286;
  final MethodChannel _channel;
  final bool? _platformSupported;
  final Future<Directory> Function() _temporaryDirectory;
  final Future<Directory> Function() _supportDirectory;
  static const _rootName = 'moss-tts-nano';
  static const _preferencesName = 'preferences.json';

  static const voices = mossVoiceCatalog;

  final AudioPlayer _player;
  StreamSubscription<void>? _completeSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  Completer<void>? _playbackCompleter;
  Completer<void>? _startupCompleter;
  Completer<void>? _speechDoneCompleter;
  Timer? _lipSyncTimer;
  final Stopwatch _playbackClock = Stopwatch();
  Duration _playbackDuration = Duration.zero;
  Duration _positionAnchor = Duration.zero;
  List<double> _amplitudeEnvelope = const [];
  File? _currentOutput;
  final Map<File, int> _pendingOutputs = {};
  Future<void>? _nativeInitializationFuture;
  Future<void>? _stopFuture;
  StreamSubscription<String>? _speechTextSubscription;
  StreamController<String>? _speechBlocks;
  StreamIterator<String>? _speechBlockIterator;
  SpeechStreamSegmenter? _speechSegmenter;
  bool _speechTextClosed = false;
  Future<void> _playerOperation = Future.value();
  bool _disposed = false;
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
  int totalDownloadBytes = 0;
  double playbackAmplitude = 0;
  double playbackProgress = 0;
  MossOperation operation = MossOperation.idle;
  String? lastError;

  /// Stable failure code; the settings card localizes it via ARB.
  String? lastErrorCode;
  List<String> runtimeProviders = const [];
  String activeProvider = 'UNVERIFIED';
  bool _providerMeasured = false;
  Future<void>? _initializationFuture;

  bool get supported => _platformSupported ?? (!kIsWeb && Platform.isAndroid);

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  double get downloadProgress => totalDownloadBytes <= 0
      ? 0
      : (downloadedBytes / totalDownloadBytes).clamp(0, 1);
  String get voiceId => _voiceId;
  bool get providerMeasured => _providerMeasured;
  bool get hardwareAccelerationVerified =>
      _providerMeasured && _isQnnProvider(activeProvider);
  bool get hardwareRuntimeAvailable =>
      runtimeReady && runtimeProviders.isNotEmpty;

  String get accelerationLabel {
    if (hardwareAccelerationVerified && activeProvider.contains('ORT_CPU')) {
      return 'Qualcomm QNN HTP + ORT CPU';
    }
    if (hardwareAccelerationVerified) return 'Qualcomm QNN HTP';
    if (runtimeInitialized) return AppStrings.current.mossAccelInitialized;
    if (initializing) return AppStrings.current.mossAccelInitializing;
    if (runtimeProviders.contains('QNN_HTP')) {
      return AppStrings.current.mossAccelCandidate;
    }
    return AppStrings.current.mossRuntimeUnavailable;
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
    final support = await _supportDirectory();
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
    if (initialized) return;
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
      // Startup probes availability only. Load QNN contexts on first speech.
      await _cleanupAudioCache();
      lastError = runtimeReady
          ? null
          : AppStrings.current.mossRuntimeUnavailable;
      lastErrorCode = runtimeReady ? null : 'moss_runtime_unavailable';
    } catch (error) {
      runtimeInitialized = false;
      lastError = AppStrings.current.mossRuntimeInitFailed('$error');
      lastErrorCode = 'moss_initialization_failed';
    } finally {
      initializing = false;
      initialized = true;
      notifyListeners();
    }
  }

  Future<void> _initializeNativeRuntime() async {
    if (runtimeInitialized) return;
    final pending = _nativeInitializationFuture;
    if (pending != null) return pending;
    final future = _initializeNativeRuntimeOnce();
    _nativeInitializationFuture = future;
    try {
      await future;
    } finally {
      if (identical(_nativeInitializationFuture, future)) {
        _nativeInitializationFuture = null;
      }
    }
  }

  Future<void> _initializeNativeRuntimeOnce() async {
    initializing = true;
    operation = MossOperation.initializingRuntime;
    notifyListeners();
    try {
      final state = await _channel.invokeMapMethod<dynamic, dynamic>(
        'initialize',
      );
      runtimeInitialized = state?['initialized'] == true;
      if (!runtimeInitialized) {
        throw StateError(
          state?['error']?.toString() ?? AppStrings.current.mossRuntimeNotReady,
        );
      }
      operation = MossOperation.runtimeReady;
    } finally {
      initializing = false;
      notifyListeners();
    }
  }

  Future<void> importModel() async {
    await initialize();
    if (!supported) {
      throw UnsupportedError(AppStrings.current.mossImportAndroidOnly);
    }
    if (!runtimeReady) {
      throw StateError(AppStrings.current.mossRuntimeUnavailable);
    }
    if (downloading) return;
    downloading = true;
    operation = MossOperation.chooseDirectory;
    lastError = null;
    lastErrorCode = null;
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
      operation = runtimeInitialized
          ? MossOperation.importedAndInitialized
          : ready
          ? MossOperation.imported
          : MossOperation.idle;
    } on PlatformException catch (error) {
      if (error.code != 'moss_import_cancelled') {
        lastError = error.message ?? error.code;
        lastErrorCode = error.code;
        rethrow;
      }
    } finally {
      downloading = false;
      notifyListeners();
    }
  }

  /// Import MOSS model from a ZIP archive (moss-qnn-v81-streaming.zip).
  Future<void> importModelFromZip() async {
    await initialize();
    if (!supported) {
      throw UnsupportedError(AppStrings.current.mossZipImportAndroidOnly);
    }
    if (!runtimeReady) {
      throw StateError(AppStrings.current.mossRuntimeUnavailable);
    }
    if (downloading) return;
    downloading = true;
    operation = MossOperation.chooseZip;
    lastError = null;
    lastErrorCode = null;
    notifyListeners();
    try {
      final model = await _channel.invokeMapMethod<dynamic, dynamic>(
        'importModelZip',
      );
      ready = model != null;
      runtimeInitialized = model?['initialized'] == true;
      if (model?['bytes'] is num) {
        downloadedBytes = (model!['bytes'] as num).toInt();
        totalDownloadBytes = downloadedBytes;
      }
      operation = runtimeInitialized
          ? MossOperation.importedAndInitialized
          : ready
          ? MossOperation.imported
          : MossOperation.idle;
    } on PlatformException catch (error) {
      if (error.code != 'moss_import_cancelled') {
        lastError = error.message ?? error.code;
        lastErrorCode = error.code;
        rethrow;
      }
    } finally {
      downloading = false;
      notifyListeners();
    }
  }

  Future<void> downloadModel() => importModel();

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

  Future<void> speak(String text) => _speak(text, toCompletion: false);

  /// Captures this utterance's completion before startup can be superseded.
  Future<void> speakToCompletion(String text) =>
      _speak(text, toCompletion: true);

  Future<void> _speak(String text, {required bool toCompletion}) async {
    final normalized = SpeechTextNormalizer.clean(text);
    // Empty / stage-direction-only input must not load a large model.
    if (normalized.isEmpty || _disposed) return;
    final operation = ++_operation;
    await _stopCurrentSpeech();
    if (operation != _operation || _disposed) return;
    await initialize();
    if (operation != _operation || _disposed) return;
    if (!ready) throw StateError(AppStrings.current.mossImportFirst);
    if (!runtimeInitialized) await _initializeNativeRuntime();
    if (operation != _operation || _disposed) return;
    final startup = Completer<void>();
    _startupCompleter = startup;
    final completion = Completer<void>();
    _speechDoneCompleter = completion;
    generating = true;
    playbackAmplitude = 0;
    playbackProgress = 0;
    _playbackDuration = Duration.zero;
    _amplitudeEnvelope = const [];
    lastError = null;
    lastErrorCode = null;
    notifyListeners();
    unawaited(_runSpeech(normalized, operation, startup, completion));
    await startup.future;
    if (toCompletion) await completion.future;
  }

  /// Speaks a reply while it is still being generated.
  ///
  /// [textDeltas] carries raw model text. The first sentence is synthesised as
  /// soon as its terminator arrives; later sentences are synthesised during
  /// playback. If playback catches up before a sentence is complete, the
  /// segmenter releases the clause up to the last comma instead of leaving a
  /// silent gap. The stream is closed by the producer, not by this method.
  Future<void> speakStream(
    Stream<String> textDeltas, {
    bool toCompletion = false,
  }) async {
    if (_disposed) return;
    final operation = ++_operation;
    await _stopCurrentSpeech();
    if (operation != _operation || _disposed) return;
    await initialize();
    if (operation != _operation || _disposed) return;
    if (!ready) throw StateError(AppStrings.current.mossImportFirst);
    if (!runtimeInitialized) await _initializeNativeRuntime();
    if (operation != _operation || _disposed) return;
    final startup = Completer<void>();
    _startupCompleter = startup;
    final completion = Completer<void>();
    _speechDoneCompleter = completion;
    generating = true;
    playbackAmplitude = 0;
    playbackProgress = 0;
    _segmentProgressStart = 0;
    _segmentProgressEnd = 1;
    _playbackDuration = Duration.zero;
    _amplitudeEnvelope = const [];
    lastError = null;
    lastErrorCode = null;
    notifyListeners();
    unawaited(_runSpeechStream(textDeltas, operation, startup, completion));
    await startup.future;
    if (toCompletion) await completion.future;
  }

  /// Resolves when the current utterance has finished playing (or was
  /// cancelled). [speak] deliberately resolves earlier, at first audio, so the
  /// caller can react to playback starting.
  Future<void> get speechCompletion =>
      _speechDoneCompleter?.future ?? Future<void>.value();

  Future<void> _runSpeechStream(
    Stream<String> textDeltas,
    int operation,
    Completer<void> startup,
    Completer<void> completion,
  ) async {
    final segmenter = SpeechStreamSegmenter();
    final blocks = StreamController<String>();
    final iterator = StreamIterator<String>(blocks.stream);
    _speechSegmenter = segmenter;
    _speechBlocks = blocks;
    _speechBlockIterator = iterator;
    _speechTextClosed = false;

    void emitSegments(Iterable<String> segments) {
      for (final segment in segments) {
        for (final chunk in splitMossText(segment, maxCharacters: 48)) {
          if (!blocks.isClosed) blocks.add(chunk);
        }
      }
    }

    final subscription = textDeltas.listen(
      (delta) {
        if (operation != _operation) return;
        emitSegments(segmenter.add(delta));
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!blocks.isClosed) blocks.addError(error, stackTrace);
      },
      onDone: () {
        _speechTextClosed = true;
        emitSegments(segmenter.flush());
        if (!blocks.isClosed) unawaited(blocks.close());
      },
    );
    _speechTextSubscription = subscription;

    try {
      if (!await iterator.moveNext()) {
        if (!startup.isCompleted) startup.complete();
        return;
      }
      var index = 0;
      var current = await _synthesizeChunk(
        iterator.current,
        operation,
        index++,
      );
      while (true) {
        if (operation != _operation) throw const _MossCancelled();
        final pendingNext = _MossPendingAudio(
          _nextStreamAudio(iterator, operation, index++),
        );
        generating = true;
        // Start a clause synthesis while the current sentence is still playing
        // when generation is slower than playback. Waiting until playback ends
        // would leave a gap the size of one native synthesis call.
        Timer? clauseTimer;
        if (!_speechTextClosed) {
          clauseTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
            if (operation != _operation || _speechTextClosed) return;
            final clause = segmenter.takeClause();
            if (clause != null) emitSegments(<String>[clause]);
          });
        }
        try {
          await _playAudio(current, operation, startup);
        } finally {
          clauseTimer?.cancel();
        }
        await _deleteAudio(current.file);
        if (operation != _operation) throw const _MossCancelled();
        // Playback is done. If the timer did not fire (very short sentence) and
        // a clause is still pending, release it now.
        if (!_speechTextClosed && segmenter.hasPending) {
          final clause = segmenter.takeClause();
          if (clause != null) emitSegments(<String>[clause]);
        }
        final outcome = await pendingNext.future;
        if (operation != _operation) throw const _MossCancelled();
        if (outcome.error is _MossStreamEnd) break;
        if (outcome.error != null) {
          Error.throwWithStackTrace(
            outcome.error!,
            outcome.stackTrace ?? StackTrace.current,
          );
        }
        current = outcome.audio!;
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
      lastErrorCode = error.code;
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
      lastErrorCode = 'moss_synthesis_failed';
      notifyListeners();
      if (!startup.isCompleted) startup.completeError(error, stackTrace);
    } finally {
      await subscription.cancel();
      await iterator.cancel();
      if (identical(_speechTextSubscription, subscription)) {
        _speechTextSubscription = null;
      }
      if (identical(_speechBlocks, blocks)) _speechBlocks = null;
      if (identical(_speechBlockIterator, iterator)) {
        _speechBlockIterator = null;
      }
      if (identical(_speechSegmenter, segmenter)) _speechSegmenter = null;
      if (!blocks.isClosed) await blocks.close();
      if (identical(_startupCompleter, startup)) _startupCompleter = null;
      if (identical(_speechDoneCompleter, completion)) {
        _speechDoneCompleter = null;
      }
      if (!completion.isCompleted) completion.complete();
      if (operation == _operation) {
        generating = false;
        speaking = false;
        playbackAmplitude = 0;
        _stopLipSyncClock();
        notifyListeners();
        if (operation == _operation && lastError != null) {
          _operation++;
          try {
            await _stopCurrentSpeech();
          } on Object catch (_) {
            // Preserve the original synthesis/playback failure.
          }
        }
      }
      await _deletePendingOutputs(operation: operation);
    }
  }

  /// Waits for the next text chunk, then synthesises it.
  ///
  /// Throws [_MossStreamEnd] after the producer closes the stream; wrapped in
  /// [_MossPendingAudio] so an early synthesis failure is attached to a handler
  /// while the previous chunk is still playing.
  Future<_MossAudio> _nextStreamAudio(
    StreamIterator<String> iterator,
    int operation,
    int index,
  ) async {
    if (!await iterator.moveNext()) throw const _MossStreamEnd();
    if (operation != _operation) throw const _MossCancelled();
    return _synthesizeChunk(iterator.current, operation, index);
  }

  Future<void> _runSpeech(
    String text,
    int operation,
    Completer<void> startup,
    Completer<void> completion,
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
        if (operation != _operation) throw const _MossCancelled();
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
      lastErrorCode = error.code;
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
      lastErrorCode = 'moss_synthesis_failed';
      notifyListeners();
      if (!startup.isCompleted) startup.completeError(error, stackTrace);
    } finally {
      if (identical(_startupCompleter, startup)) _startupCompleter = null;
      if (identical(_speechDoneCompleter, completion)) {
        _speechDoneCompleter = null;
      }
      if (!completion.isCompleted) completion.complete();
      if (operation == _operation) {
        generating = false;
        speaking = false;
        playbackAmplitude = 0;
        _stopLipSyncClock();
        notifyListeners();
        if (operation == _operation && lastError != null) {
          // Playback failure can leave the prefetched next chunk running.
          // Invalidate it before cancelling so it cannot publish orphan audio.
          _operation++;
          try {
            await _stopCurrentSpeech();
          } on Object catch (_) {
            // Preserve the original synthesis/playback failure.
          }
        }
      }
      await _deletePendingOutputs(operation: operation);
    }
  }

  Future<_MossAudio> _synthesizeChunk(
    String text,
    int operation,
    int index,
  ) async {
    if (operation != _operation) throw const _MossCancelled();
    final cache = await _temporaryDirectory();
    if (operation != _operation) throw const _MossCancelled();
    var output = File(
      '${cache.path}${Platform.pathSeparator}talk2u-moss-$operation-$index-'
      '${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    _pendingOutputs[output] = operation;
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
        throw StateError(AppStrings.current.mossProviderMissing);
      }
      activeProvider = provider;
      _providerMeasured = true;
      final outputPath = response?['path'] as String?;
      if (outputPath == null) {
        throw StateError(AppStrings.current.mossNoAudio);
      }
      final generatedOutput = File(outputPath);
      if (generatedOutput.path != output.path) {
        _pendingOutputs.remove(output);
        output = generatedOutput;
        _pendingOutputs[output] = operation;
      }
      if (!await isPlayableMossWav(output)) {
        throw StateError(AppStrings.current.mossAudioInvalid);
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
    final playback = Completer<void>();
    _playbackCompleter = playback;
    await _queuePlayer(() async {
      if (operation != _operation) throw const _MossCancelled();
      await _player.play(DeviceFileSource(audio.file.path));
    });
    if (operation != _operation) throw const _MossCancelled();
    speaking = true;
    playbackAmplitude = 0;
    playbackProgress = _segmentProgressStart;
    _startLipSyncClock();
    notifyListeners();
    if (!startup.isCompleted) startup.complete();
    await playback.future;
    if (operation != _operation) throw const _MossCancelled();
    if (identical(_playbackCompleter, playback)) _playbackCompleter = null;
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

  Future<void> _queuePlayer(Future<void> Function() action) {
    final next = _playerOperation.then((_) => action());
    _playerOperation = next.catchError((Object _) {});
    return next;
  }

  Future<void> stopSpeaking() {
    _operation++;
    return _stopCurrentSpeech();
  }

  Future<void> _stopCurrentSpeech() {
    final pending = _stopFuture;
    if (pending != null) return pending;
    final future = _stopCurrentSpeechOnce();
    _stopFuture = future;
    return future.whenComplete(() {
      if (identical(_stopFuture, future)) _stopFuture = null;
    });
  }

  Future<void> _stopCurrentSpeechOnce() async {
    final outputs = _pendingOutputs.keys.toList(growable: false);
    // Cancel the text side before the audio side: an unawaited producer must
    // not enqueue a chunk after cancellation has completed.
    final textSubscription = _speechTextSubscription;
    _speechTextSubscription = null;
    final blockIterator = _speechBlockIterator;
    _speechBlockIterator = null;
    final blocks = _speechBlocks;
    _speechBlocks = null;
    _speechSegmenter = null;
    _speechTextClosed = true;
    await textSubscription?.cancel();
    await blockIterator?.cancel();
    if (blocks != null && !blocks.isClosed) {
      unawaited(blocks.close());
    }
    final startup = _startupCompleter;
    _startupCompleter = null;
    if (startup != null && !startup.isCompleted) startup.complete();
    final playback = _playbackCompleter;
    _playbackCompleter = null;
    if (playback != null && !playback.isCompleted) playback.complete();
    final completion = _speechDoneCompleter;
    _speechDoneCompleter = null;
    if (completion != null && !completion.isCompleted) completion.complete();
    _stopLipSyncClock();
    if (supported) {
      try {
        await _channel.invokeMethod<void>('cancel');
      } on PlatformException {
        lastError = null;
      }
    }
    await _queuePlayer(_player.stop);
    generating = false;
    speaking = false;
    playbackAmplitude = 0;
    playbackProgress = 0;
    _amplitudeEnvelope = const [];
    for (final output in outputs) {
      await _deleteAudio(output);
    }
    notifyListeners();
  }

  Future<void> deleteModel() async {
    if (downloading) throw StateError(AppStrings.current.mossImportBusyWait);
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

  /// Deletes synthesised WAV files that nothing is playing.
  ///
  /// Called from Android memory pressure. The file owned by the current playback
  /// is left alone, and nothing here touches the installed deployment package.
  Future<void> trimAudioCache() async {
    if (_disposed || speaking) return;
    await _cleanupAudioCache();
    notifyListeners();
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

  Future<void> _deletePendingOutputs({required int operation}) async {
    final outputs = _pendingOutputs.entries
        .where((entry) => entry.value == operation)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final output in outputs) {
      await _deleteAudio(output);
    }
  }

  Future<void> _cleanupAudioCache() async {
    final cache = await _temporaryDirectory();
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
    _disposed = true;
    _operation++;
    final completion = _speechDoneCompleter;
    if (completion != null && !completion.isCompleted) completion.complete();
    _stopLipSyncClock();
    final startup = _startupCompleter;
    if (startup != null && !startup.isCompleted) startup.complete();
    final playback = _playbackCompleter;
    if (playback != null && !playback.isCompleted) playback.complete();
    unawaited(_speechTextSubscription?.cancel());
    unawaited(_speechBlockIterator?.cancel());
    final blocks = _speechBlocks;
    _speechBlocks = null;
    if (blocks != null && !blocks.isClosed) unawaited(blocks.close());
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
  const strong = mossSentenceBreakCharacters;
  const soft = mossClauseBreakCharacters;
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
      throw FormatException(AppStrings.current.mossWavInvalid);
    }
    final header = input.readSync(12);
    if (header.length != 12 ||
        ascii.decode(header.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
        ascii.decode(header.sublist(8, 12), allowInvalid: true) != 'WAVE') {
      throw FormatException(AppStrings.current.mossWavInvalid);
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
          throw FormatException(AppStrings.current.mossWavNotPcm);
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
      throw FormatException(AppStrings.current.mossWavPcmInvalid);
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
        throw FormatException(AppStrings.current.mossWavPcmTruncated);
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
