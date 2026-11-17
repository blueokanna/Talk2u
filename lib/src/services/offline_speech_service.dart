import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:talk2u/src/l10n/app_strings.dart';
import 'package:talk2u/src/lexicon/speech_cue_lexicon.dart';
import 'package:talk2u/src/services/call_session.dart';
import 'package:talk2u/src/services/moss_tts_service.dart';
import 'package:talk2u/src/services/sherpa_speech_service.dart';
import 'package:talk2u/src/services/speech_text_normalizer.dart';
import 'package:talk2u/src/services/turn_taking.dart';

export 'package:talk2u/src/services/speech_text_normalizer.dart'
    show SpeechPlan, SpeechStageDirection;

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

  SpeechAnimationCue copyWith({String? cue, int? start, int? end}) =>
      SpeechAnimationCue(
        cue: cue ?? this.cue,
        start: start ?? this.start,
        end: end ?? this.end,
        priority: priority,
      );
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
    final strings = AppStrings.current;
    final language = locale.toLowerCase().startsWith('zh')
        ? strings.languageChinese
        : locale;
    final genderLabel = switch (gender) {
      'male' => strings.genderMale,
      'female' => strings.genderFemale,
      _ => strings.genderOther,
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
  final bool ttsHardwareVerified;
  final bool sttHardwareVerified;
  final String ttsProvider;
  final String sttProvider;
  final List<SpeechVoice> ttsVoices;

  const SpeechCapabilities({
    this.offlineTts = false,
    this.offlineStt = false,
    this.sttModelDownload = false,
    this.audioAmplitude = false,
    this.ttsVoice = '',
    this.ttsLocale = '',
    this.sttLocale = '',
    this.ttsHardwareVerified = false,
    this.sttHardwareVerified = false,
    this.ttsProvider = '',
    this.sttProvider = '',
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
        ttsHardwareVerified: value['ttsHardwareVerified'] == true,
        sttHardwareVerified: value['sttHardwareVerified'] == true,
        ttsProvider: value['ttsProvider'] as String? ?? '',
        sttProvider: value['sttProvider'] as String? ?? '',
        ttsVoices: (value['ttsVoices'] as List? ?? const [])
            .whereType<Map>()
            .map(SpeechVoice.fromMap)
            .where((voice) => voice.name.isNotEmpty)
            .toList(growable: false),
      );
}

class OfflineSpeechService extends ChangeNotifier
    with WidgetsBindingObserver
    implements CallSpeechPort, StreamingCallSpeechPort {
  OfflineSpeechService._() {
    WidgetsBinding.instance.addObserver(this);
    MossTtsService.instance.addListener(_handleMossState);
    SherpaSpeechService.instance.addListener(_handleSherpaState);
    _sherpaRecognitionSubscription = SherpaSpeechService
        .instance
        .recognitionResults
        .listen(_handleSherpaRecognition);
  }

  static final instance = OfflineSpeechService._();

  StreamSubscription<String>? _sherpaRecognitionSubscription;
  Future<void>? _startListeningOperation;
  Future<void>? _stopListeningOperation;
  final _recognitionController = StreamController<String>.broadcast();
  @override
  double amplitude = 0;
  @override
  bool generating = false;
  @override
  bool speaking = false;
  @override
  bool listening = false;
  String recognizedText = '';
  String animationCue = 'neutral';
  List<SpeechAnimationCue> animationCues = const [];
  int animationCueRevision = 0;
  String speechEmotion = SpeechTextNormalizer.neutralEmotion;
  int? sttModelDownloadProgress;
  bool sttModelDownloadScheduled = false;
  String? lastError;
  int _activeAnimationCueIndex = -1;
  int _spokenTextLength = 0;
  DateTime? _lastAnimationCueChangedAt;
  int _latestSpeechPosition = 0;
  final _selfEcho = SelfEchoTranscriptFilter();
  _OfflineStreamingReply? _activeStreamingReply;

  Stream<String> get recognitionResults => _recognitionController.stream;

  @override
  Stream<String> get transcripts => _recognitionController.stream;

  @override
  Stream<double> get frameEnergies =>
      SherpaSpeechService.instance.frameEnergies;

  @override
  bool get echoCancellationVerified =>
      SherpaSpeechService.instance.echoCancellationVerified;

  @override
  String get captureSource => SherpaSpeechService.instance.captureSource;
  SpeechCapabilities get capabilities {
    final moss = MossTtsService.instance;
    final sherpa = SherpaSpeechService.instance;
    return SpeechCapabilities(
      offlineTts: moss.ready && moss.hardwareRuntimeAvailable,
      offlineStt: sherpa.asrReady,
      sttModelDownload: false,
      audioAmplitude: moss.ready && moss.hardwareRuntimeAvailable,
      ttsVoice: moss.ready ? moss.selectedVoice.displayLabel : '',
      ttsLocale: moss.ready ? moss.selectedVoice.locale : '',
      sttLocale: sherpa.asrReady ? 'zh-CN / en-US' : '',
      ttsHardwareVerified: moss.hardwareAccelerationVerified,
      sttHardwareVerified: sherpa.hardwareAccelerationVerified,
      ttsProvider: moss.activeProvider,
      sttProvider: sherpa.asrReady ? SherpaSpeechService.activeProvider : '',
    );
  }

  @override
  Future<void> initialize() async {
    await MossTtsService.instance.initialize();
    await SherpaSpeechService.instance.initialize();
    notifyListeners();
  }

  @override
  Future<void> speak(String text) => _speak(text, toCompletion: false);

  Future<void> _speak(String text, {required bool toCompletion}) async {
    _stopAnimationTimeline();
    final plan = prepareSpeech(text);
    if (plan.spokenText.isEmpty) {
      speechEmotion = SpeechTextNormalizer.neutralEmotion;
      animationCues = const [];
      animationCue = 'neutral';
      animationCueRevision++;
      notifyListeners();
      return;
    }
    _spokenTextLength = plan.spokenText.length;
    speechEmotion = plan.emotion;
    _selfEcho.rememberSpoken(plan.spokenText);
    animationCues = inferAnimationCues(text);
    animationCue = 'neutral';
    _activeAnimationCueIndex = -1;
    animationCueRevision++;
    lastError = null;
    notifyListeners();
    final moss = MossTtsService.instance;
    try {
      // MOSS owns initialization and validates its hardware deployment. A
      // released runtime may be loaded again, and cancellation covers loading.
      if (toCompletion) {
        await moss.speakToCompletion(plan.spokenText);
      } else {
        await moss.speak(plan.spokenText);
      }
    } catch (error) {
      lastError = error.toString();
      notifyListeners();
      rethrow;
    }
  }

  @override
  Future<void> speakToCompletion(String text) =>
      _speak(text, toCompletion: true);

  @override
  StreamingReplySpeech beginStreamingSpeech() {
    final previous = _activeStreamingReply;
    // Detach, do not cancel: the new reply's `speakStream` call supersedes the
    // old MOSS operation. Calling stop here would race with that new operation
    // and could cut the first sentence of the replacement reply.
    previous?.detach();
    final reply = _OfflineStreamingReply(this);
    _activeStreamingReply = reply;
    return reply;
  }

  void _releaseStreamingReply(_OfflineStreamingReply reply) {
    if (identical(_activeStreamingReply, reply)) {
      _activeStreamingReply = null;
    }
  }

  void _beginStreamingPlan() {
    _stopAnimationTimeline();
    lastError = null;
    _spokenTextLength = 0;
    speechEmotion = SpeechTextNormalizer.neutralEmotion;
    animationCues = const [];
    animationCue = 'neutral';
    _activeAnimationCueIndex = -1;
    animationCueRevision++;
    notifyListeners();
  }

  void _applyStreamingPlan(String fullReply) {
    final plan = prepareSpeech(fullReply);
    if (plan.spokenText.isEmpty) return;
    _spokenTextLength = plan.spokenText.length;
    speechEmotion = plan.emotion;
    _selfEcho.rememberSpoken(plan.spokenText);
    animationCues = inferAnimationCues(fullReply);
    animationCue = 'neutral';
    _activeAnimationCueIndex = -1;
    animationCueRevision++;
    notifyListeners();
  }

  Future<void> _speakStream(Stream<String> text) async {
    try {
      await MossTtsService.instance.speakStream(text, toCompletion: true);
    } catch (error) {
      lastError = error.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _stopStreamingSpeech() async {
    _stopAnimationTimeline();
    await MossTtsService.instance.stopSpeaking();
    generating = false;
    speaking = false;
    speechEmotion = SpeechTextNormalizer.neutralEmotion;
    animationCue = 'neutral';
    animationCueRevision++;
    notifyListeners();
  }

  @override
  Future<void> stopSpeaking() async {
    final active = _activeStreamingReply;
    _activeStreamingReply = null;
    if (active != null) {
      await active.cancel();
    } else {
      await _stopStreamingSpeech();
    }
  }

  @override
  Future<void> startListening() {
    final activeStart = _startListeningOperation;
    if (activeStart != null) return activeStart;
    if (listening || _stopListeningOperation != null) return Future.value();
    if (!SherpaSpeechService.instance.asrReady) {
      throw StateError(AppStrings.current.senseVoiceInstallFirst);
    }
    listening = true;
    lastError = null;
    notifyListeners();
    final operation = _startListeningOnce();
    _startListeningOperation = operation;
    return operation.whenComplete(() {
      if (identical(_startListeningOperation, operation)) {
        _startListeningOperation = null;
      }
    });
  }

  Future<void> _startListeningOnce() async {
    try {
      if (!listening) return;
      await SherpaSpeechService.instance.startListening();
      // Sherpa may still be recognizing and decline to reopen. Do not leave
      // the facade reporting an open microphone that does not exist.
      listening = SherpaSpeechService.instance.listening;
      notifyListeners();
    } catch (error) {
      listening = false;
      lastError = error.toString();
      notifyListeners();
      rethrow;
    }
  }

  @override
  Future<void> stopListening() {
    final activeStop = _stopListeningOperation;
    if (activeStop != null) return activeStop;
    final pendingStart = _startListeningOperation;
    if (!listening && pendingStart == null) return Future.value();
    listening = false;
    notifyListeners();
    final operation = _stopListeningOnce(pendingStart);
    _stopListeningOperation = operation;
    return operation.whenComplete(() {
      if (identical(_stopListeningOperation, operation)) {
        _stopListeningOperation = null;
      }
    });
  }

  Future<void> _stopListeningOnce(Future<void>? pendingStart) async {
    if (pendingStart != null) {
      try {
        await pendingStart;
      } catch (_) {
        return;
      }
    }
    await SherpaSpeechService.instance.stopListening();
  }

  Future<void> downloadOfflineSttModel() async {
    await SherpaSpeechService.instance.downloadAsr();
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

  /// Removes emoji and control characters from a recognition transcript, which
  /// some SenseVoice decoders emit as stray symbols on silence or noise.
  static String sanitizeTranscript(String text) =>
      SpeechTextNormalizer.cleanTranscript(text);

  void clearRecognizedText() {
    if (recognizedText.isEmpty) return;
    recognizedText = '';
    notifyListeners();
  }

  /// True when the recognizer most likely transcribed the agent's own playback
  /// rather than the user.
  @override
  bool isSelfEcho(String transcript) => _selfEcho.isSelfEcho(transcript);

  @visibleForTesting
  static SpeechPlan prepareSpeech(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const SpeechPlan(spokenText: '', stageDirections: []);
    }
    final withoutSpeaker = trimmed.replaceFirst(
      RegExp(r'^[^\n：:]{1,16}[：:]\s*(?=[（(【\[*])'),
      '',
    );
    return SpeechTextNormalizer.prepare(
      withoutSpeaker.trim().isEmpty ? trimmed : withoutSpeaker,
    );
  }

  @visibleForTesting
  static List<SpeechAnimationCue> inferAnimationCues(String text) {
    final plan = prepareSpeech(text);
    final result = _inferAnimationCuesPlain(plan.spokenText).toList();
    final groupedDirections = <int, List<String>>{};
    for (final direction in plan.stageDirections) {
      groupedDirections
          .putIfAbsent(direction.spokenOffset, () => <String>[])
          .add(direction.text);
    }
    for (final entry in groupedDirections.entries) {
      final cue = _inferAnimationCuePlain(entry.value.join(' '));
      if (cue == 'neutral' || cue == 'talking' || cue == 'talkingSoft') {
        continue;
      }
      result.removeWhere((existing) => existing.start == entry.key);
      result.add(
        SpeechAnimationCue(
          cue: cue,
          start: entry.key,
          end: (entry.key + 1).clamp(0, plan.spokenText.length).toInt(),
          priority: -1,
        ),
      );
    }
    result.sort((left, right) {
      final position = left.start.compareTo(right.start);
      return position != 0 ? position : right.priority.compareTo(left.priority);
    });
    return List.unmodifiable(result);
  }

  static List<SpeechAnimationCue> _inferAnimationCuesPlain(String text) {
    final value = text.toLowerCase();
    const patterns = plainSpeechCuePatterns;
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
    final cueOccurrences = <String, int>{};
    for (final match in selected) {
      final occurrence = cueOccurrences[match.cue] ?? 0;
      cueOccurrences[match.cue] = occurrence + 1;
      final varied = match.copyWith(cue: _variantCue(match.cue, occurrence));
      final recentlyRepeated =
          result.isNotEmpty &&
          _cueFamily(result.last.cue) == _cueFamily(varied.cue) &&
          match.start - result.last.start < 6;
      if (!recentlyRepeated) result.add(varied);
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

  static String _inferAnimationCuePlain(String text) {
    final cues = _inferAnimationCuesPlain(text);
    if (cues.isEmpty) return 'neutral';
    return cues.reduce((left, right) {
      if (left.priority != right.priority) {
        return left.priority < right.priority ? left : right;
      }
      return left.start <= right.start ? left : right;
    }).cue;
  }

  /// Emotion cues rotate through a small family of equivalent performances so
  /// a long reply does not replay the same motion on every sentence. The first
  /// occurrence always uses the canonical name, which keeps the mapping
  /// predictable for models that only define the base cue.
  static const _cueVariants = <String, List<String>>{
    'happy': ['happy', 'happySoft', 'excited'],
    'sad': ['sad', 'sadSoft', 'sigh'],
    'angry': ['angry', 'angrySoft'],
    'surprise': ['surprise', 'surpriseSoft'],
    'shy': ['shy', 'shySoft'],
    'thinking': ['thinking', 'thinkingSoft'],
  };

  static String _variantCue(String cue, int occurrence) {
    final variants = _cueVariants[cue];
    if (variants == null || variants.isEmpty) return cue;
    return variants[occurrence % variants.length];
  }

  static String _cueFamily(String cue) => switch (cue) {
    'happySoft' || 'excited' => 'happy',
    'sadSoft' || 'sigh' => 'sad',
    'angrySoft' => 'angry',
    'surpriseSoft' => 'surprise',
    'shySoft' => 'shy',
    'thinkingSoft' => 'thinking',
    _ => cue,
  };

  static List<_SpeechTextSegment> _speechTextSegments(String text) {
    const strong = sentenceBreakCharacters;
    const soft = clauseBreakCharacters;
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
    if (questionMarks.split('').any(value.contains) ||
        thinkingCueTerms.any(value.contains)) {
      return 'thinking';
    }
    if (emphasisCueTerms.any(value.contains) ||
        exclamationMarks.split('').any(value.contains)) {
      return 'emphasis';
    }
    if (dramaticCueTerms.any(value.contains)) {
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

  void _stopAnimationTimeline() {
    _latestSpeechPosition = 0;
    _lastAnimationCueChangedAt = null;
  }

  void _handleSherpaRecognition(String text) {
    recognizedText = text;
    _recognitionController.add(text);
    notifyListeners();
  }

  void _handleSherpaState() {
    listening = SherpaSpeechService.instance.listening;
    lastError = SherpaSpeechService.instance.lastError;
    notifyListeners();
  }

  void _handleMossState() {
    final wasSpeaking = speaking;
    final moss = MossTtsService.instance;
    generating = moss.generating;
    speaking = moss.speaking;
    amplitude = speaking ? moss.playbackAmplitude : 0;
    if (speaking) {
      _activateAnimationCue(
        (moss.playbackProgress * _spokenTextLength).floor(),
        force: !wasSpeaking && _activeAnimationCueIndex < 0,
      );
    } else if (!speaking && wasSpeaking) {
      amplitude = 0;
      if (!generating) {
        _stopAnimationTimeline();
        _activeAnimationCueIndex = -1;
        speechEmotion = SpeechTextNormalizer.neutralEmotion;
        animationCue = 'neutral';
        animationCueRevision++;
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
    _sherpaRecognitionSubscription?.cancel();
    _recognitionController.close();
    super.dispose();
  }
}

/// One reply's text pipe into [MossTtsService.speakStream].
///
/// The controller is intentionally single-subscription: MOSS is the only
/// consumer and the order of model deltas must be exact. Starting the speech
/// future lazily on [append] avoids initialising the TTS runtime for an empty
/// reply (for example a reply made only of emoji or a stage direction).
class _OfflineStreamingReply implements StreamingReplySpeech {
  _OfflineStreamingReply(this._owner);

  final OfflineSpeechService _owner;
  final StreamController<String> _text = StreamController<String>();
  Future<void>? _speech;
  bool _started = false;
  bool _closed = false;

  @override
  void append(String text) {
    if (_closed || text.isEmpty) return;
    if (!_started) {
      _started = true;
      _owner._beginStreamingPlan();
      _speech = _owner._speakStream(_text.stream);
    }
    _text.add(text);
  }

  @override
  Future<void> finish(String fullReply) async {
    if (_closed) {
      final speech = _speech;
      if (speech != null) await speech;
      _owner._releaseStreamingReply(this);
      return;
    }
    _closed = true;
    _owner._applyStreamingPlan(fullReply);
    await _text.close();
    if (!_started) {
      _owner._releaseStreamingReply(this);
      return;
    }
    try {
      await _speech;
    } finally {
      _owner._releaseStreamingReply(this);
    }
  }

  /// Abandons this sink without touching the shared MOSS operation.
  ///
  /// Used when a replacement reply is about to start; the replacement's own
  /// `speakStream` increments the MOSS operation and cancels the old audio.
  void detach() {
    _closed = true;
    if (!_text.isClosed) unawaited(_text.close());
    final speech = _speech;
    if (speech != null) {
      unawaited(speech.catchError((Object _) {}));
    }
    _owner._releaseStreamingReply(this);
  }

  @override
  Future<void> cancel() async {
    _closed = true;
    if (!_text.isClosed) await _text.close();
    // Stop playback before awaiting the speech future: otherwise cancellation
    // would wait for every already-queued chunk to play first. This path also
    // runs when generation has finished (the text controller is already
    // closed) but the queued audio is still playing.
    await _owner._stopStreamingSpeech();
    final speech = _speech;
    if (speech != null) {
      try {
        await speech;
      } on Object catch (_) {
        // A cancelled utterance is expected to unwind with an error.
      }
    }
    _owner._releaseStreamingReply(this);
  }
}
