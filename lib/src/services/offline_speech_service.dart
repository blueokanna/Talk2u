import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:talk2u/src/services/moss_tts_service.dart';
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

@immutable
class SpeechVoice {
  final String name;
  final String locale;
  final String gender;

  const SpeechVoice({
    required this.name,
    required this.locale,
    required this.gender,
  });

  factory SpeechVoice.fromMap(Map<dynamic, dynamic> value) => SpeechVoice(
    name: value['name'] as String? ?? '',
    locale: value['locale'] as String? ?? '',
    gender: value['gender'] as String? ?? 'unknown',
  );

  String get displayLabel {
    final language = locale.toLowerCase().startsWith('zh') ? '中文' : locale;
    final genderLabel = switch (gender) {
      'male' => '男声',
      'female' => '女声',
      _ => '通用',
    };
    return '$name · $language · $genderLabel';
  }
}

class _SpeechTextSegment {
  final int start;
  final int end;

  const _SpeechTextSegment(this.start, this.end);
}

class SpeechCapabilities {
  final bool offlineTts;
  final bool offlineStt;
  final bool sttModelDownload;
  final bool audioAmplitude;
  final String ttsVoice;
  final String ttsLocale;
  final String sttLocale;
  final List<SpeechVoice> ttsVoices;

  const SpeechCapabilities({
    this.offlineTts = false,
    this.offlineStt = false,
    this.sttModelDownload = false,
    this.audioAmplitude = false,
    this.ttsVoice = '',
    this.ttsLocale = '',
    this.sttLocale = '',
    this.ttsVoices = const [],
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
        ttsVoices: (value['ttsVoices'] as List? ?? const [])
            .whereType<Map>()
            .map(SpeechVoice.fromMap)
            .where((voice) => voice.name.isNotEmpty)
            .toList(growable: false),
      );
}

class OfflineSpeechService extends ChangeNotifier with WidgetsBindingObserver {
  OfflineSpeechService._() {
    WidgetsBinding.instance.addObserver(this);
    MossTtsService.instance.addListener(_handleMossState);
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
  bool generating = false;
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
  bool _usingMossTts = false;
  bool _usingSherpaStt = false;
  int _spokenTextLength = 0;
  String _spokenText = '';
  Timer? _animationTimelineTimer;
  DateTime? _speechStartedAt;
  DateTime? _lastAnimationCueChangedAt;
  int _latestSpeechPosition = 0;

  Stream<String> get recognitionResults => _recognitionController.stream;
  SpeechCapabilities get systemCapabilities => _systemCapabilities;
  SpeechCapabilities get capabilities {
    final sherpa = SherpaSpeechService.instance;
    final moss = MossTtsService.instance;
    return SpeechCapabilities(
      offlineTts: _systemCapabilities.offlineTts || moss.ready,
      offlineStt: _systemCapabilities.offlineStt || sherpa.asrReady,
      sttModelDownload: _systemCapabilities.sttModelDownload,
      audioAmplitude: _systemCapabilities.audioAmplitude || moss.ready,
      ttsVoice: moss.ready
          ? moss.selectedVoice.displayLabel
          : _systemCapabilities.ttsVoice,
      ttsLocale: moss.ready
          ? moss.selectedVoice.locale
          : _systemCapabilities.ttsLocale,
      sttLocale: _systemCapabilities.offlineStt
          ? _systemCapabilities.sttLocale
          : sherpa.asrReady
          ? 'zh / en / yue / ja / ko'
          : '',
      ttsVoices: _systemCapabilities.ttsVoices,
    );
  }

  Future<void> initialize() async {
    await MossTtsService.instance.initialize();
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
    _stopAnimationTimeline();
    _spokenTextLength = text.length;
    _spokenText = text;
    animationCues = inferAnimationCues(text);
    animationCue = 'neutral';
    _activeAnimationCueIndex = -1;
    animationCueRevision++;
    lastError = null;
    notifyListeners();
    if (MossTtsService.instance.ready) {
      try {
        _usingMossTts = true;
        await MossTtsService.instance.speak(text);
        return;
      } catch (error) {
        if (defaultTargetPlatform != TargetPlatform.android ||
            !_systemCapabilities.offlineTts) {
          lastError = error.toString();
          notifyListeners();
          rethrow;
        }
      }
    }
    if (defaultTargetPlatform != TargetPlatform.android ||
        !_systemCapabilities.offlineTts) {
      throw StateError('未检测到可用的端侧 TTS 语音模型');
    }
    try {
      _usingMossTts = false;
      await _methods.invokeMethod<void>('speak', {'text': text});
    } on PlatformException catch (error) {
      lastError = error.message ?? error.code;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> stopSpeaking() async {
    _stopAnimationTimeline();
    if (_usingMossTts) {
      await MossTtsService.instance.stopSpeaking();
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      await _methods.invokeMethod<void>('stopSpeaking');
    }
    generating = false;
    notifyListeners();
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

  Future<void> selectTtsVoice(String name) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError('系统离线音色选择仅适用于 Android');
    }
    lastError = null;
    try {
      final value = await _methods.invokeMapMethod<dynamic, dynamic>(
        'selectTtsVoice',
        {'name': name},
      );
      _systemCapabilities = SpeechCapabilities.fromMap(value ?? const {});
      notifyListeners();
    } on PlatformException catch (error) {
      lastError = error.message ?? error.code;
      notifyListeners();
      rethrow;
    }
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
      _CuePattern('wave', 0, ['挥手', '招手', '挥了挥', 'wave', '再见', '拜拜']),
      _CuePattern('hug', 0, ['抱住', '抱抱', '拥抱', '相拥', 'hug']),
      _CuePattern('nod', 0, ['点头', '颔首', '答应', '赞同', '明白', 'nod', '嗯嗯']),
      _CuePattern('emphasis', 1, [
        '必须',
        '一定',
        '注意',
        '重点',
        '关键',
        '终于',
        '立刻',
        '绝不能',
        'important',
      ]),
      _CuePattern('thinking', 1, ['为什么', '怎么会', '想一想', '思考', '疑惑', 'question']),
      _CuePattern('dramatic', 1, [
        '危险',
        '紧张',
        '恐惧',
        '黑暗',
        '追逐',
        '战斗',
        '危机',
        '屏住呼吸',
        'suspense',
      ]),
      _CuePattern('angry', 1, [
        '生气',
        '愤怒',
        '恼火',
        '气愤',
        '咬牙',
        '争吵',
        '怒吼',
        '讨厌',
        'angry',
      ]),
      _CuePattern('sad', 1, [
        '难过',
        '伤心',
        '悲伤',
        '哭泣',
        '眼泪',
        '失落',
        '孤独',
        '遗憾',
        '沉重',
        'sad',
      ]),
      _CuePattern('shy', 1, ['害羞', '脸红', '不好意思', '低下头', '小声说', 'shy']),
      _CuePattern('surprise', 1, [
        '惊讶',
        '震惊',
        '突然',
        '猛地',
        '意外',
        '居然',
        '竟然',
        '真的吗',
        'surprise',
      ]),
      _CuePattern('happy', 1, [
        '开心',
        '高兴',
        '喜悦',
        '兴奋',
        '幸福',
        '温暖',
        '轻松',
        '欢呼',
        '哈哈',
        '微笑',
        '笑了',
        '太好了',
        'happy',
      ]),
      _CuePattern('greeting', 1, ['你好', '嗨', '哈喽', '欢迎', '👋', 'hello', 'hi ']),
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
    final segments = _speechTextSegments(text);
    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index];
      final earlyMatchIndex = result.indexWhere(
        (cue) =>
            cue.start >= segment.start &&
            cue.start < segment.end &&
            cue.start - segment.start <= 12,
      );
      if (earlyMatchIndex >= 0) {
        final early = result[earlyMatchIndex];
        if (early.start > segment.start) {
          result[earlyMatchIndex] = SpeechAnimationCue(
            cue: early.cue,
            start: segment.start,
            end: early.end,
            priority: early.priority,
          );
        }
        continue;
      }
      final segmentText = value.substring(segment.start, segment.end);
      result.add(
        SpeechAnimationCue(
          cue: _contextualAnimationCue(segmentText, index),
          start: segment.start,
          end: segment.end,
          priority: 2,
        ),
      );
    }
    result.sort((left, right) {
      final position = left.start.compareTo(right.start);
      return position != 0 ? position : left.priority.compareTo(right.priority);
    });
    return List.unmodifiable(result);
  }

  static List<_SpeechTextSegment> _speechTextSegments(String text) {
    const strong = '。！？；\n!?;.';
    const soft = '，、,：:';
    final result = <_SpeechTextSegment>[];
    var start = 0;
    for (var index = 0; index < text.length; index++) {
      final character = text[index];
      final strongBoundary = strong.contains(character);
      final softBoundary = soft.contains(character) && index - start >= 44;
      if (!strongBoundary && !softBoundary) continue;
      var end = index + 1;
      while (end < text.length && text[end].trim().isEmpty) {
        end++;
      }
      if (end > start) result.add(_SpeechTextSegment(start, end));
      start = end;
    }
    if (start < text.length) result.add(_SpeechTextSegment(start, text.length));
    if (result.isEmpty && text.isNotEmpty) {
      result.add(_SpeechTextSegment(0, text.length));
    }
    return result;
  }

  static String _contextualAnimationCue(String text, int index) {
    final value = text.toLowerCase();
    if ('？?'.split('').any(value.contains) ||
        const [
          '为什么',
          '怎么',
          '是否',
          '想一想',
          '思考',
          '疑惑',
          'question',
        ].any(value.contains)) {
      return 'thinking';
    }
    if (const [
          '必须',
          '一定',
          '注意',
          '重点',
          '关键',
          '终于',
          '立刻',
          '绝不能',
          'important',
        ].any(value.contains) ||
        value.contains('！') ||
        value.contains('!')) {
      return 'emphasis';
    }
    if (const [
      '从前',
      '那天',
      '夜里',
      '这时',
      '后来',
      '与此同时',
      '紧接着',
      '危机',
      '战斗',
      '故事',
      'suddenly',
    ].any(value.contains)) {
      return 'dramatic';
    }
    return index.isEven ? 'talking' : 'talkingSoft';
  }

  void _activateAnimationCue(int textPosition, {bool force = false}) {
    _latestSpeechPosition = textPosition > _latestSpeechPosition
        ? textPosition
        : _latestSpeechPosition;
    var selectedIndex = -1;
    for (var index = 0; index < animationCues.length; index++) {
      if (animationCues[index].start > textPosition) break;
      selectedIndex = index;
    }
    if (selectedIndex < 0 && _activeAnimationCueIndex >= 0) return;
    if (!force && selectedIndex == _activeAnimationCueIndex) return;
    final now = DateTime.now();
    if (!force &&
        _lastAnimationCueChangedAt != null &&
        now.difference(_lastAnimationCueChangedAt!) <
            const Duration(milliseconds: 1600)) {
      return;
    }
    _activeAnimationCueIndex = selectedIndex;
    animationCue = selectedIndex >= 0
        ? animationCues[selectedIndex].cue
        : 'neutral';
    animationCueRevision++;
    _lastAnimationCueChangedAt = now;
  }

  void _startAnimationTimeline() {
    _stopAnimationTimeline();
    _speechStartedAt = DateTime.now();
    _latestSpeechPosition = 0;
    _lastAnimationCueChangedAt = null;
    _activateAnimationCue(0, force: true);
    if (animationCues.length < 2 || _spokenText.isEmpty) return;
    final estimatedDuration = _estimatedSpeechDuration(_spokenText);
    _animationTimelineTimer = Timer.periodic(
      const Duration(milliseconds: 120),
      (timer) {
        if (!speaking || _speechStartedAt == null) {
          timer.cancel();
          return;
        }
        final elapsed = DateTime.now().difference(_speechStartedAt!);
        final progress = (elapsed.inMilliseconds / estimatedDuration).clamp(
          0.0,
          1.0,
        );
        final estimatedPosition = (progress * _spokenTextLength).floor();
        _activateAnimationCue(
          estimatedPosition > _latestSpeechPosition
              ? estimatedPosition
              : _latestSpeechPosition,
        );
      },
    );
  }

  int _estimatedSpeechDuration(String text) {
    var milliseconds = 0;
    for (final rune in text.runes) {
      if ('。！？；，、.!?;,\n'.runes.contains(rune)) {
        milliseconds += 180;
      } else if (String.fromCharCode(rune).trim().isEmpty) {
        milliseconds += 35;
      } else if (rune >= 0x3400 && rune <= 0x9fff) {
        milliseconds += 125;
      } else {
        milliseconds += 65;
      }
    }
    return milliseconds.clamp(900, 600000).toInt();
  }

  void _stopAnimationTimeline() {
    _animationTimelineTimer?.cancel();
    _animationTimelineTimer = null;
    _speechStartedAt = null;
    _latestSpeechPosition = 0;
    _lastAnimationCueChangedAt = null;
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
        _startAnimationTimeline();
      case 'speechDone':
        _stopAnimationTimeline();
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
        _stopAnimationTimeline();
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
    if (_usingSherpaStt) {
      listening = SherpaSpeechService.instance.listening;
      lastError = SherpaSpeechService.instance.lastError;
    }
    notifyListeners();
  }

  void _handleMossState() {
    if (!_usingMossTts) {
      notifyListeners();
      return;
    }
    final wasSpeaking = speaking;
    final moss = MossTtsService.instance;
    generating = moss.generating;
    speaking = moss.speaking;
    amplitude = speaking ? moss.playbackAmplitude : 0;
    if (speaking) {
      _animationTimelineTimer?.cancel();
      _animationTimelineTimer = null;
      _speechStartedAt = null;
      _activateAnimationCue(
        (moss.playbackProgress * _spokenTextLength).floor(),
        force: !wasSpeaking && _activeAnimationCueIndex < 0,
      );
    } else if (!speaking && wasSpeaking) {
      amplitude = 0;
      if (!generating) {
        _stopAnimationTimeline();
        _activeAnimationCueIndex = -1;
      }
    }
    if (moss.lastError != null) lastError = moss.lastError;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopAnimationTimeline();
    WidgetsBinding.instance.removeObserver(this);
    MossTtsService.instance.removeListener(_handleMossState);
    SherpaSpeechService.instance.removeListener(_handleSherpaState);
    _subscription?.cancel();
    _sherpaRecognitionSubscription?.cancel();
    _recognitionController.close();
    super.dispose();
  }
}
