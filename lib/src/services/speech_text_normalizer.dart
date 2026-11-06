import 'package:flutter/foundation.dart';

/// A silent stage direction extracted from a reply, positioned in the spoken
/// text so the avatar can act while the matching phrase is being played.
@immutable
class SpeechStageDirection {
  final String text;
  final int spokenOffset;

  const SpeechStageDirection({required this.text, required this.spokenOffset});
}

/// The result of turning a rendered assistant reply into speech.
///
/// [spokenText] never contains emoji, Markdown syntax, code, URLs or blank
/// lines: those would either be read out literally by the vocoder or produce
/// unstable prosody. [emotion] is the dominant affect inferred from the reply
/// and is used to sustain a matching Live2D expression while the reply plays.
@immutable
class SpeechPlan {
  final String spokenText;
  final List<SpeechStageDirection> stageDirections;
  final String emotion;

  const SpeechPlan({
    required this.spokenText,
    required this.stageDirections,
    this.emotion = 'neutral',
  });
}

/// Converts chat markup into clean, speakable text.
///
/// The normalizer is intentionally dependency-free and deterministic: every
/// transformation drops presentation syntax instead of paraphrasing, so the
/// spoken content always matches what the user sees.
abstract final class SpeechTextNormalizer {
  static const neutralEmotion = 'neutral';

  static const _emotionCues = <String, List<String>>{
    'happy': [
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
      '太好',
      '喜欢',
      '爱你',
      '想你',
      '安心',
      '舒服',
      '愉快',
      'happy',
      'great',
      'love',
      'nice',
    ],
    'sad': [
      '难过',
      '伤心',
      '悲伤',
      '哭泣',
      '眼泪',
      '失落',
      '孤独',
      '遗憾',
      '沉重',
      '委屈',
      '心碎',
      'sad',
      'sorry',
      'lonely',
      'cry',
    ],
    'angry': [
      '生气',
      '愤怒',
      '恼火',
      '气愤',
      '咬牙',
      '争吵',
      '怒吼',
      '讨厌',
      '烦死',
      'angry',
      'mad',
      'annoyed',
    ],
    'surprise': [
      '惊讶',
      '震惊',
      '意外',
      '居然',
      '竟然',
      '真的吗',
      '没想到',
      '天哪',
      'surprise',
      'wow',
      'really',
    ],
    'shy': ['害羞', '脸红', '不好意思', '低下头', '小声', '腼腆', 'shy', 'blush'],
    'thinking': ['为什么', '怎么会', '想一想', '思考', '疑惑', '犹豫', 'question'],
  };

  static const _stageDirectionKeywords = [
    '笑',
    '哭',
    '叹气',
    '叹息',
    '点头',
    '摇头',
    '挥手',
    '招手',
    '抱',
    '转身',
    '低头',
    '抬头',
    '脸红',
    '害羞',
    '开心',
    '高兴',
    '兴奋',
    '生气',
    '愤怒',
    '难过',
    '悲伤',
    '惊讶',
    '震惊',
    '小声',
    '轻声',
    '低语',
    '耳语',
    '大声',
    '喊',
    '欢呼',
    '沉默',
    '停顿',
    '微笑',
    '苦笑',
    '挑眉',
    '歪头',
    '耸肩',
    '眨眼',
    '撇嘴',
    '鼓掌',
    '拍手',
    '咳嗽',
    '呼吸',
    '心跳',
    '哽咽',
    '颤抖',
    'laugh',
    'smile',
    'cry',
    'sigh',
    'nod',
    'wave',
    'hug',
    'whisper',
    'shout',
    'angry',
    'happy',
    'sad',
    'excited',
    'surprised',
  ];

  /// Clean text without stage-direction bookkeeping.
  ///
  /// Used by services that only need safe plain text (for example the voice
  /// preview in settings) and as the first pass of [prepare].
  static String clean(String source) => prepare(source).spokenText;

  /// Full normalization used before speech synthesis.
  static SpeechPlan prepare(String source) {
    if (source.trim().isEmpty) {
      return const SpeechPlan(spokenText: '', stageDirections: []);
    }

    final emojiEmotions = <String>[];
    var text = source.trim().replaceFirst(
      RegExp(r'^[^\n：:]{1,16}[：:]\s*(?=[（(【\[*])'),
      '',
    );
    text = _stripNonSpokenBlocks(text);
    text = _stripMarkdownDecorations(text);
    text = _replaceLineBreaks(text);
    text = _normalizePunctuation(text);

    final spoken = StringBuffer();
    final directions = <SpeechStageDirection>[];
    const pairs = <String, String>{
      '（': '）',
      '(': ')',
      '【': '】',
      '[': ']',
      '「': '」',
      '『': '』',
    };

    var index = 0;
    while (index < text.length) {
      final rune = _runeAt(text, index);
      final character = String.fromCharCode(rune);
      final width = _runeWidth(rune);

      final closing = pairs[character];
      if (closing != null) {
        final end = text.indexOf(closing, index + width);
        if (end > index + width) {
          final content = text.substring(index + width, end).trim();
          if (_isStageDirection(content)) {
            directions.add(
              SpeechStageDirection(text: content, spokenOffset: spoken.length),
            );
            emojiEmotions.addAll(_emotionsInText(content));
            index = _skipSilentWhitespace(text, end + closing.length);
            continue;
          }
        }
      }

      if (character == '*') {
        final end = text.indexOf('*', index + 1);
        if (end > index + 1) {
          final content = text.substring(index + 1, end).trim();
          if (content.isNotEmpty) {
            directions.add(
              SpeechStageDirection(text: content, spokenOffset: spoken.length),
            );
            emojiEmotions.addAll(_emotionsInText(content));
            index = _skipSilentWhitespace(text, end + 1);
            continue;
          }
        }
        index += 1;
        continue;
      }

      if (_isEmojiRune(rune)) {
        var end = index + width;
        while (end < text.length) {
          final next = _runeAt(text, end);
          if (_isEmojiRune(next) || _isEmojiJoiner(next)) {
            end += _runeWidth(next);
            continue;
          }
          break;
        }
        final emotion = _emotionForRune(rune);
        if (emotion != null) emojiEmotions.add(emotion);
        _writeEmojiPause(spoken, text, end, emotion);
        index = end;
        continue;
      }

      if (_isInvisibleRune(rune)) {
        index += width;
        continue;
      }

      if (character == ' ' || character == '\t') {
        final next = _nextMeaningfulChar(text, index + width);
        if (next != null && '，。！？；：、,.!?;:）】」』'.contains(next)) {
          index += width;
          continue;
        }
        if (spoken.isNotEmpty && !_endsWithSpace(spoken)) spoken.write(' ');
        index += width;
        continue;
      }

      if (character == '\n' || character == '\r') {
        _writeSentenceBreak(spoken);
        index += width;
        continue;
      }

      spoken.write(character);
      index += width;
    }

    var value = spoken.toString().trim();
    value = _tidySpokenText(value);
    final leading = spoken.length - spoken.toString().trimLeft().length;

    final mappedDirections = directions
        .map(
          (direction) => SpeechStageDirection(
            text: direction.text,
            spokenOffset: (direction.spokenOffset - leading)
                .clamp(0, value.length)
                .toInt(),
          ),
        )
        .where((direction) => value.isNotEmpty)
        .toList(growable: false);

    return SpeechPlan(
      spokenText: value,
      stageDirections: mappedDirections,
      emotion: _dominantEmotion(
        '$value ${mappedDirections.map((d) => d.text).join(' ')}',
        emojiEmotions,
      ),
    );
  }

  /// The dominant emotion for a raw reply, without synthesizing a full plan.
  static String emotionOf(String source) => prepare(source).emotion;
  static String cleanTranscript(String source) {
    final buffer = StringBuffer();
    for (final rune in source.runes) {
      if (_isInvisibleRune(rune) || _isEmojiRune(rune)) continue;
      buffer.writeCharCode(rune);
    }
    return buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _stripNonSpokenBlocks(String source) {
    var value = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    value = value.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '');
    value = value.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^)]*\)'),
      (match) => match.group(1) ?? '',
    );
    value = value.replaceAll(RegExp(r'<([^>\s]+@[^>\s]+)>'), '');
    value = value.replaceAll(RegExp(r'\[\^[^\]]*\]'), '');
    value = value.replaceAll(RegExp(r'\[\s*\]|\(\s*\)'), '');

    value = value.replaceAll(
      RegExp(
        r'<(think|thinking|analysis|reasoning|scratchpad)\b[^>]*>[\s\S]*?</\1\s*>',
        caseSensitive: false,
      ),
      '\n',
    );
    value = value.replaceAll(
      RegExp(
        r'<(think|thinking|analysis|reasoning|scratchpad)\b[^>]*>[\s\S]*$',
        caseSensitive: false,
      ),
      '\n',
    );
    value = value.replaceAll(RegExp(r'</?[a-zA-Z][^>]*>'), '');

    value = value.replaceAll(RegExp(r'```[\s\S]*?(```|$)'), '\n');
    value = value.replaceAll(RegExp(r'~~~[\s\S]*?(~~~|$)'), '\n');
    value = value.replaceAll(RegExp(r'`[^`\n]*`'), ' ');
    value = value.replaceAll(
      RegExp(r'https?://\S+', caseSensitive: false),
      ' ',
    );
    value = value.replaceAll(RegExp(r'www\.\S+', caseSensitive: false), ' ');
    value = value.replaceAll(
      RegExp(r'[\w.+-]+@[\w-]+\.[\w.-]+', caseSensitive: false),
      ' ',
    );
    value = value.replaceAll(
      RegExp(r':[a-z0-9_+\-]{2,32}:', caseSensitive: false),
      ' ',
    );
    return value;
  }

  static String _stripMarkdownDecorations(String source) {
    var value = source;

    value = value.replaceAll(
      RegExp(r'^[ \t]{0,3}#{1,6}[ \t]*', multiLine: true),
      '',
    );
    value = value.replaceAll(
      RegExp(r'^[ \t]{0,3}>[ \t]?', multiLine: true),
      '',
    );
    value = value.replaceAll(
      RegExp(r'^[ \t]{0,3}(?:[-*+•]|\d{1,3}[.)])[ \t]+', multiLine: true),
      '',
    );
    value = value.replaceAll(
      RegExp(r'^[ \t]{0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$', multiLine: true),
      '',
    );
    value = value.replaceAll(
      RegExp(r'^[ \t]*\|?[ \t:|-]+\|[ \t:|-]*$', multiLine: true),
      '',
    );
    value = value.replaceAll(RegExp(r'\*\*|__|~~'), '');
    value = value.replaceAll('`', '');
    value = value.replaceAllMapped(
      RegExp(r'\\([\\`*_{}\[\]()#+\-.!|>])'),
      (match) => match.group(1) ?? '',
    );
    value = value.replaceAll('|', '，');
    return value;
  }

  static String _replaceLineBreaks(String source) {
    final lines = source
        .split('\n')
        .map(_normalizeWhitespace)
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) return '';
    final buffer = StringBuffer();
    for (final line in lines) {
      if (buffer.isEmpty) {
        buffer.write(line);
        continue;
      }
      final previous = String.fromCharCode(_lastRune(buffer.toString()));
      if (!'。！？!?…，,、；;：:'.contains(previous)) {
        buffer.write('。');
      }
      buffer.write(line);
    }
    return buffer.toString();
  }

  static String _normalizePunctuation(String source) {
    var value = source;
    value = value.replaceAllMapped(RegExp(r'\.{3,}|…{2,}'), (_) => '……');
    value = value.replaceAll(RegExp(r'([。])\1+'), r'$1');
    value = value.replaceAll(RegExp(r'([，,])\1+'), r'$1');
    value = value.replaceAll(RegExp(r'([、])\1+'), r'$1');
    value = value.replaceAll(RegExp(r'([！!])\1+'), r'$1');
    value = value.replaceAll(RegExp(r'([？?])\1+'), r'$1');
    value = value.replaceAll(RegExp(r'([；;])\1+'), r'$1');
    value = value.replaceAll(RegExp(r'([：:])\1+'), r'$1');
    value = value.replaceAll(RegExp(r'[ \t]+'), ' ');
    value = value.replaceAll(RegExp(r'\s+([，。！？；：、,.!?;:）】」』])'), r'$1');
    value = value.replaceAll(RegExp(r'([（【「『])\s+'), r'$1');
    return value.trim();
  }

  static void _writeEmojiPause(
    StringBuffer spoken,
    String source,
    int nextIndex,
    String? emotion,
  ) {
    if (emotion == null) return;
    final next = _nextMeaningfulChar(source, nextIndex);
    final atClauseEnd = next == null || '。！？!?，,、；;：:…\n'.contains(next);
    if (!atClauseEnd) return;

    final previous = spoken.isEmpty
        ? ''
        : String.fromCharCode(_lastRune(spoken.toString()));
    final pause = switch (emotion) {
      'happy' => '，',
      'sad' || 'thinking' || 'shy' => '……',
      'angry' => '！',
      'surprise' => '？',
      _ => '',
    };
    if (pause.isEmpty) return;
    if (pause.length == 1 && previous == pause) return;
    if (pause == '……' && previous == '…') return;
    spoken.write(pause);
  }

  static void _writeSentenceBreak(StringBuffer spoken) {
    if (spoken.isEmpty) return;
    final previous = String.fromCharCode(_lastRune(spoken.toString()));
    if (!'。！？!?…，,、；;：:'.contains(previous)) {
      spoken.write('。');
    }
  }

  static String? _nextMeaningfulChar(String source, int index) {
    var cursor = index;
    while (cursor < source.length) {
      final rune = _runeAt(source, cursor);
      if (_isEmojiRune(rune) ||
          _isEmojiJoiner(rune) ||
          _isInvisibleRune(rune)) {
        cursor += _runeWidth(rune);
        continue;
      }
      final character = String.fromCharCode(rune);
      if (character == ' ' || character == '\t') {
        cursor += 1;
        continue;
      }
      return character;
    }
    return null;
  }

  static int _skipSilentWhitespace(String source, int index) {
    var cursor = index;
    while (cursor < source.length) {
      final rune = _runeAt(source, cursor);
      if (rune == 0x20 || rune == 0x09 || rune == 0x0A || rune == 0x0D) {
        cursor += 1;
        continue;
      }
      break;
    }
    return cursor;
  }

  static String _tidySpokenText(String value) {
    var text = value;
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    text = text.replaceAll(RegExp(r'\s+([，。！？；：、,.!?;:）】」』])'), r'$1');
    text = text.replaceAll(RegExp(r'([（【「『])\s+'), r'$1');
    text = text.replaceAll(RegExp(r'^[,，、；;：:\s]+'), '');
    text = text.replaceAll(RegExp(r'[,，、；;：:\s]+$'), '。');
    text = text.replaceAll(RegExp(r'。{2,}'), '。');
    text = text.trim();
    if (!_hasSpeakableContent(text)) return '';
    final last = String.fromCharCode(_lastRune(text));
    if ('，,、；;：:'.contains(last)) {
      text = '${text.substring(0, text.length - 1)}。';
    }
    return text;
  }

  static String _normalizeWhitespace(String value) =>
      value.replaceAll('\t', ' ').replaceAll(RegExp(r' {2,}'), ' ').trim();

  static bool _hasSpeakableContent(String text) {
    for (final rune in text.runes) {
      if (rune >= 0x30 && rune <= 0x39) return true;
      if (rune >= 0x41 && rune <= 0x5A) return true;
      if (rune >= 0x61 && rune <= 0x7A) return true;
      if (rune >= 0x00C0 && rune <= 0x024F) return true;
      if (rune >= 0x0400 && rune <= 0x04FF) return true;
      if (rune >= 0x3040 && rune <= 0x30FF) return true;
      if (rune >= 0x3400 && rune <= 0x9FFF) return true;
      if (rune >= 0xAC00 && rune <= 0xD7AF) return true;
      if (rune >= 0xF900 && rune <= 0xFAFF) return true;
    }
    return false;
  }

  static bool _isStageDirection(String text) {
    final value = text.toLowerCase();
    if (value.isEmpty || value.length > 80) return false;
    return _stageDirectionKeywords.any(value.contains) ||
        _emotionForRuneIn(value) != null;
  }

  static bool _endsWithSpace(StringBuffer buffer) {
    if (buffer.isEmpty) return false;
    return String.fromCharCode(_lastRune(buffer.toString())) == ' ';
  }

  static int _runeWidth(int rune) => rune > 0xFFFF ? 2 : 1;

  static int _runeAt(String value, int index) {
    final first = value.codeUnitAt(index);
    if (first >= 0xD800 && first <= 0xDBFF && index + 1 < value.length) {
      final second = value.codeUnitAt(index + 1);
      if (second >= 0xDC00 && second <= 0xDFFF) {
        return 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00);
      }
    }
    return first;
  }

  static int _lastRune(String value) {
    final lastIndex = value.length - 1;
    final unit = value.codeUnitAt(lastIndex);
    if (unit >= 0xDC00 && unit <= 0xDFFF && lastIndex > 0) {
      final previous = value.codeUnitAt(lastIndex - 1);
      if (previous >= 0xD800 && previous <= 0xDBFF) {
        return 0x10000 + ((previous - 0xD800) << 10) + (unit - 0xDC00);
      }
    }
    return unit;
  }

  static bool _isInvisibleRune(int rune) =>
      rune == 0x200B ||
      rune == 0x200C ||
      rune == 0x200E ||
      rune == 0x200F ||
      rune == 0x2060 ||
      rune == 0xFEFF ||
      (rune >= 0xFE00 && rune <= 0xFE0F) ||
      (rune >= 0xE0100 && rune <= 0xE01EF) ||
      (rune >= 0x0000 && rune <= 0x0008) ||
      rune == 0x000B ||
      rune == 0x000C ||
      (rune >= 0x000E && rune <= 0x001F) ||
      rune == 0x007F;

  static bool _isEmojiJoiner(int rune) =>
      rune == 0x200D ||
      rune == 0x20E3 ||
      (rune >= 0xFE00 && rune <= 0xFE0F) ||
      (rune >= 0x1F3FB && rune <= 0x1F3FF) ||
      (rune >= 0xE0020 && rune <= 0xE007F);

  static bool _isEmojiRune(int rune) {
    if (rune < 0xA9) return false;
    return rune == 0xA9 ||
        rune == 0xAE ||
        rune == 0x2122 ||
        (rune >= 0x2190 && rune <= 0x21FF) ||
        (rune >= 0x2300 && rune <= 0x23FF) ||
        (rune >= 0x25A0 && rune <= 0x25FF) ||
        (rune >= 0x2600 && rune <= 0x27BF) ||
        (rune >= 0x2900 && rune <= 0x297F) ||
        (rune >= 0x2B00 && rune <= 0x2BFF) ||
        (rune >= 0x1F000 && rune <= 0x1FAFF) ||
        (rune >= 0x1F1E6 && rune <= 0x1F1FF);
  }

  static String? _emotionForRune(int rune) {
    if (rune >= 0x1F600 && rune <= 0x1F64F) {
      if (rune == 0x1F62D ||
          rune == 0x1F622 ||
          rune == 0x1F61E ||
          rune == 0x1F614 ||
          rune == 0x1F61F) {
        return 'sad';
      }
      if (rune == 0x1F620 || rune == 0x1F621 || rune == 0x1F624) {
        return 'angry';
      }
      if (rune == 0x1F62E ||
          rune == 0x1F62F ||
          rune == 0x1F631 ||
          rune == 0x1F632) {
        return 'surprise';
      }
      if (rune == 0x1F633) return 'shy';
      if (rune == 0x1F914) return 'thinking';
      if (rune == 0x1F641 || rune == 0x1F610 || rune == 0x1F611) {
        return 'sad';
      }
      return 'happy';
    }
    if (rune >= 0x1F910 && rune <= 0x1F92F) {
      if (rune == 0x1F914) return 'thinking';
      if (rune == 0x1F92C) return 'angry';
      if (rune == 0x1F929 || rune == 0x1F92A) return 'happy';
      if (rune == 0x1F92F) return 'surprise';
      return 'happy';
    }
    if (rune >= 0x1F970 && rune <= 0x1F97A) {
      if (rune == 0x1F97A) return 'sad';
      return 'happy';
    }
    if (rune >= 0x1F900 && rune <= 0x1F9FF) {
      if (rune == 0x1F971) return 'sad';
      return 'happy';
    }
    if (rune == 0x2764) return 'happy';
    if (rune == 0x1F494 || rune == 0x1F480) return 'sad';
    if (rune == 0x1F4A2 || rune == 0x1F47F) return 'angry';
    if (rune == 0x1F4AD) return 'thinking';
    if (rune == 0x1F44B || rune == 0x1F44D || rune == 0x1F64C) return 'happy';
    return null;
  }

  static String? _emotionForRuneIn(String text) {
    for (final rune in text.runes) {
      final emotion = _emotionForRune(rune);
      if (emotion != null) return emotion;
    }
    return null;
  }

  static List<String> _emotionsInText(String text) {
    final result = <String>[];
    for (final rune in text.runes) {
      final emotion = _emotionForRune(rune);
      if (emotion != null) result.add(emotion);
    }
    return result;
  }

  static String _dominantEmotion(String text, List<String> emojiEmotions) {
    final scores = <String, double>{};
    final value = text.toLowerCase();
    for (final entry in _emotionCues.entries) {
      for (final term in entry.value) {
        var offset = 0;
        while (offset < value.length) {
          final index = value.indexOf(term, offset);
          if (index < 0) break;
          scores[entry.key] =
              (scores[entry.key] ?? 0) + (term.length >= 2 ? 1.4 : 1.0);
          offset = index + term.length;
        }
      }
    }
    for (final emotion in emojiEmotions) {
      scores[emotion] = (scores[emotion] ?? 0) + 1.8;
    }

    final excitement = RegExp(r'[!！]').allMatches(text).length;
    final questions = RegExp(r'[?？]').allMatches(text).length;
    if (excitement >= 2) scores['happy'] = (scores['happy'] ?? 0) + 0.8;
    if (questions >= 2) {
      scores['thinking'] = (scores['thinking'] ?? 0) + 0.4;
    }

    if (scores.isEmpty) return neutralEmotion;
    final sorted = scores.entries.toList()
      ..sort((left, right) => right.value.compareTo(left.value));
    final best = sorted.first;
    if (best.value < 1.0) return neutralEmotion;
    if (sorted.length > 1 && sorted[1].value == best.value) {
      return neutralEmotion;
    }
    return best.key;
  }
}
