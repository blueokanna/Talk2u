import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:talk2u/src/services/sherpa_speech_service.dart';

@immutable
class SpeechAnimationCue {
  final String cue;
  final int start;
  final int end;
  final int priority;

  const SpeechAnimationCue({
    required this.cue,
    required this.start,
    required this.end,
    required this.priority,
  });
}

class _CuePattern {
  final String cue;
  final int priority;
  final List<String> terms;

  const _CuePattern(this.cue, this.priority, this.terms);
}

class SpeechCapabilities {
  final bool offlineTts;
  final bool offlineStt;
  final bool sttModelDownload;
  final bool audioAmplitude;
  final String ttsVoice;
  final String ttsLocale;
  final String sttLocale;

  const SpeechCapabilities({
    this.offlineTts = false,
    this.offlineStt = false,
    this.sttModelDownload = false,
    this.audioAmplitude = false,
    this.ttsVoice = '',
    this.ttsLocale = '',
    this.sttLocale = '',
  });

  factory SpeechCapabilities.fromMap(Map<dynamic, dynamic> value) =>
      SpeechCapabilities(
        offlineTts: value['offlineTts'] == true,
        offlineStt: value['offlineStt'] == true,
        sttModelDownload: value['sttModelDownload'] == true,
        audioAmplitude: value['audioAmplitude'] == true,
        ttsVoice: value['ttsVoice'] as String? ?? '',
        ttsLocale: value['ttsLocale'] as String? ?? '',
        sttLocale: value['sttLocale'] as String? ?? '',
      );
}

class OfflineSpeechService extends ChangeNotifier with WidgetsBindingObserver {
  OfflineSpeechService._() {
    WidgetsBinding.instance.addObserver(this);
    SherpaSpeechService.instance.addListener(_handleSherpaState);
    _sherpaRecognitionSubscription = SherpaSpeechService
        .instance
        .recognitionResults
        .listen(_handleSherpaRecognition);
    _subscription = _events.receiveBroadcastStream().listen(
      _handleEvent,
      onError: (Object error) {
        lastError = error.toString();
        notifyListeners();
      },
    );
  }

  static final instance = OfflineSpeechService._();
  static const _methods = MethodChannel('talk2u/speech');
  static const _events = EventChannel('talk2u/speech_events');

  StreamSubscription<dynamic>? _subscription;
  StreamSubscription<String>? _sherpaRecognitionSubscription;
  final _recognitionController = StreamController<String>.broadcast();
  SpeechCapabilities _systemCapabilities = const SpeechCapabilities();
  double amplitude = 0;
  bool speaking = false;
  bool listening = false;
  String recognizedText = '';
  String animationCue = 'neutral';
  List<SpeechAnimationCue> animationCues = const [];
  int animationCueRevision = 0;
  int? sttModelDownloadProgress;
  bool sttModelDownloadScheduled = false;
  String? lastError;
  int _activeAnimationCueIndex = -1;
  bool _usingSherpaTts = false;
  bool _usingSherpaStt = false;
  int _spokenTextLength = 0;

  Stream<String> get recognitionResults => _recognitionController.stream;
  SpeechCapabilities get systemCapabilities => _systemCapabilities;
  SpeechCapabilities get capabilities {
    final sherpa = SherpaSpeechService.instance;
    return SpeechCapabilities(
      offlineTts: _systemCapabilities.offlineTts || sherpa.ttsReady,
      offlineStt: _systemCapabilities.offlineStt || sherpa.asrReady,
      sttModelDownload: _systemCapabilities.sttModelDownload,
      audioAmplitude: _systemCapabilities.audioAmplitude || sherpa.ttsReady,
      ttsVoice: _systemCapabilities.offlineTts
          ? _systemCapabilities.ttsVoice
          : sherpa.ttsReady
          ? SherpaSpeechService.ttsModelName
          : '',
      ttsLocale: _systemCapabilities.offlineTts
          ? _systemCapabilities.ttsLocale
          : sherpa.ttsReady
          ? 'zh-CN / en-US'
          : '',
      sttLocale: _systemCapabilities.offlineStt
          ? _systemCapabilities.sttLocale
          : sherpa.asrReady
          ? 'zh / en / yue / ja / ko'
          : '',
    );
  }

  Future<void> initialize() async {
    await SherpaSpeechService.instance.initialize();
    if (defaultTargetPlatform != TargetPlatform.android) {
      notifyListeners();
      return;
    }
    try {
      final value = await _methods.invokeMapMethod<dynamic, dynamic>(
        'refreshCapabilities',
      );
      _systemCapabilities = SpeechCapabilities.fromMap(value ?? const {});
      notifyListeners();
    } on PlatformException catch (error) {
      lastError = error.message;
      notifyListeners();
    }
  }

  Future<void> speak(String text) async {
    _spokenTextLength = text.length;
    animationCues = inferAnimationCues(text);
    animationCue = 'neutral';
    _activeAnimationCueIndex = -1;
    animationCueRevision++;
    lastError = null;
    notifyListeners();
    try {
      if (defaultTargetPlatform == TargetPlatform.android &&
          _systemCapabilities.offlineTts) {
        _usingSherpaTts = false;
        await _methods.invokeMethod<void>('speak', {'text': text});
      } else {
        _usingSherpaTts = true;
        await SherpaSpeechService.instance.speak(text);
      }
    } on PlatformException catch (error) {
      if (SherpaSpeechService.instance.ttsReady) {
        _usingSherpaTts = true;
        await SherpaSpeechService.instance.speak(text);
      } else {
        lastError = error.message ?? error.code;
        notifyListeners();
        rethrow;
      }
    }
  }

  Future<void> stopSpeaking() async {
    if (_usingSherpaTts) {
      await SherpaSpeechService.instance.stopSpeaking();
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      await _methods.invokeMethod<void>('stopSpeaking');
    }
  }

  Future<void> startListening() async {
    if (defaultTargetPlatform == TargetPlatform.android &&
        _systemCapabilities.offlineStt) {
      _usingSherpaStt = false;
      try {
        await _methods.invokeMethod<void>('startListening');
        return;
      } on PlatformException {
        if (!SherpaSpeechService.instance.asrReady) rethrow;
      }
    }
    _usingSherpaStt = true;
    await SherpaSpeechService.instance.startListening();
  }

  Future<void> stopListening() async {
    if (_usingSherpaStt) {
      await SherpaSpeechService.instance.stopListening();
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      await _methods.invokeMethod<void>('stopListening');
    }
  }

  Future<void> installOfflineTtsData() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError('离线 TTS 数据安装入口仅适用于 Android');
    }
    await _methods.invokeMethod<void>('installOfflineTtsData');
  }

  Future<void> openVoiceInputSettings() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError('离线语音识别设置入口仅适用于 Android');
    }
    await _methods.invokeMethod<void>('openVoiceInputSettings');
  }

  Future<void> downloadOfflineSttModel() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError('端侧语音识别模型下载仅适用于 Android');
    }
    sttModelDownloadProgress = null;
    sttModelDownloadScheduled = true;
    lastError = null;
    notifyListeners();
    try {
      await _methods.invokeMethod<String>('downloadOfflineSttModel');
    } on PlatformException catch (error) {
      sttModelDownloadScheduled = false;
      lastError = error.message ?? error.code;
      notifyListeners();
      rethrow;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(initialize());
  }

  @visibleForTesting
  static String inferAnimationCue(String text) {
    final cues = inferAnimationCues(text);
    if (cues.isEmpty) return 'neutral';
    return cues.reduce((left, right) {
      if (left.priority != right.priority) {
        return left.priority < right.priority ? left : right;
      }
      return left.start <= right.start ? left : right;
    }).cue;
  }

  @visibleForTesting
  static List<SpeechAnimationCue> inferAnimationCues(String text) {
    final value = text.toLowerCase();
    const patterns = <_CuePattern>[
      _CuePattern('wave', 0, ['挥手', '招手', 'wave', '再见', '拜拜']),
      _CuePattern('hug', 0, ['抱住', '抱抱', '拥抱', 'hug']),
      _CuePattern('nod', 0, ['点头', 'nod', '嗯嗯']),
      _CuePattern('angry', 1, ['生气', '愤怒', '气死', '讨厌', 'angry']),
      _CuePattern('sad', 1, ['难过', '伤心', '哭泣', '遗憾', 'sad']),
      _CuePattern('shy', 1, ['害羞', '脸红', '不好意思', 'shy']),
      _CuePattern('surprise', 1, ['惊讶', '震惊', '居然', '真的吗', 'surprise']),
      _CuePattern('happy', 1, ['开心', '高兴', '哈哈', '微笑', '太好了', 'happy']),
      _CuePattern('greeting', 1, ['你好', '嗨', '欢迎', 'hello', 'hi ']),
    ];
    final matches = <SpeechAnimationCue>[];
    for (final pattern in patterns) {
      for (final term in pattern.terms) {
        var offset = 0;
        while (offset < value.length) {
          final start = value.indexOf(term, offset);
          if (start < 0) break;
          matches.add(
            SpeechAnimationCue(
              cue: pattern.cue,
              start: start,
              end: start + term.length,
              priority: pattern.priority,
            ),
          );
          offset = start + term.length;
        }
      }
    }
    matches.sort((left, right) {
      final priorityOrder = left.priority.compareTo(right.priority);
      if (priorityOrder != 0) return priorityOrder;
      final lengthOrder = (right.end - right.start).compareTo(
        left.end - left.start,
      );
      if (lengthOrder != 0) return lengthOrder;
      return left.start.compareTo(right.start);
    });

    final selected = <SpeechAnimationCue>[];
    for (final match in matches) {
      final overlaps = selected.any(
        (existing) => match.start < existing.end && match.end > existing.start,
      );
      if (!overlaps) selected.add(match);
    }
    selected.sort((left, right) => left.start.compareTo(right.start));

    final result = <SpeechAnimationCue>[];
    for (final match in selected) {
      final recentlyRepeated =
          result.isNotEmpty &&
          result.last.cue == match.cue &&
          match.start - result.last.start < 6;
      if (!recentlyRepeated) result.add(match);
    }
    return List.unmodifiable(result);
  }

  void _activateAnimationCue(int textPosition, {bool force = false}) {
    var selectedIndex = -1;
    for (var index = 0; index < animationCues.length; index++) {
      if (animationCues[index].start > textPosition) break;
      selectedIndex = index;
    }
    if (!force && selectedIndex == _activeAnimationCueIndex) return;
    _activeAnimationCueIndex = selectedIndex;
    animationCue = selectedIndex >= 0
        ? animationCues[selectedIndex].cue
        : 'neutral';
    animationCueRevision++;
  }

  void _handleEvent(dynamic raw) {
    if (raw is! Map) return;
    switch (raw['type']) {
      case 'capabilities':
        if (raw['value'] is Map) {
          _systemCapabilities = SpeechCapabilities.fromMap(raw['value'] as Map);
        }
      case 'speechStart':
        speaking = true;
        _activateAnimationCue(0, force: true);
      case 'speechDone':
        speaking = false;
        amplitude = 0;
        _activeAnimationCueIndex = -1;
      case 'speechRange':
        _activateAnimationCue((raw['start'] as num?)?.toInt() ?? 0);
      case 'amplitude':
        amplitude = (raw['value'] as num?)?.toDouble().clamp(0, 1) ?? 0;
      case 'listening':
        listening = true;
      case 'listeningEnd':
        listening = false;
      case 'recognitionResult':
        final text = raw['text'] as String?;
        if (text != null) {
          recognizedText = text;
          _recognitionController.add(text);
        }
      case 'error':
        lastError = raw['message'] as String?;
        speaking = false;
        amplitude = 0;
        _activeAnimationCueIndex = -1;
      case 'recognitionError':
        lastError = raw['message'] as String? ?? '离线语音识别错误: ${raw['code']}';
        listening = false;
      case 'sttModelDownloadScheduled':
        sttModelDownloadScheduled = true;
      case 'sttModelDownloadProgress':
        sttModelDownloadScheduled = true;
        sttModelDownloadProgress = (raw['value'] as num?)?.toInt();
      case 'sttModelDownloadDone':
        sttModelDownloadScheduled = false;
        sttModelDownloadProgress = 100;
        unawaited(initialize());
      case 'sttModelDownloadError':
        sttModelDownloadScheduled = false;
        lastError = '端侧语音识别模型下载失败: ${raw['code']}';
    }
    notifyListeners();
  }

  void _handleSherpaRecognition(String text) {
    recognizedText = text;
    _recognitionController.add(text);
    notifyListeners();
  }

  void _handleSherpaState() {
    if (_usingSherpaTts) {
      final wasSpeaking = speaking;
      final sherpa = SherpaSpeechService.instance;
      speaking = sherpa.speaking;
      amplitude = speaking ? sherpa.playbackAmplitude : 0;
      if (speaking && !wasSpeaking) {
        _activateAnimationCue(0, force: true);
      } else if (speaking) {
        _activateAnimationCue(
          (sherpa.playbackProgress * _spokenTextLength).floor(),
        );
      } else if (!speaking && wasSpeaking) {
        amplitude = 0;
        _activeAnimationCueIndex = -1;
      }
    }
    if (_usingSherpaStt) {
      listening = SherpaSpeechService.instance.listening;
      lastError = SherpaSpeechService.instance.lastError;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SherpaSpeechService.instance.removeListener(_handleSherpaState);
    _subscription?.cancel();
    _sherpaRecognitionSubscription?.cancel();
    _recognitionController.close();
    super.dispose();
  }
}
