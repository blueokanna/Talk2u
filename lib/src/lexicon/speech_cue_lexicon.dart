/// Animation-cue lexicon matched against a reply before it is spoken.
///
/// The terms are Chinese/English language resources rather than UI strings: they
/// map what the character *says* onto a Live2D cue family. Punctuation sets live
/// here too because CJK and ASCII punctuation must be treated identically.
library;

/// A cue family plus the phrases that trigger it.
class SpeechCuePattern {
  const SpeechCuePattern(this.cue, this.priority, this.terms);

  final String cue;

  /// Lower values win when two patterns match at the same offset.
  final int priority;
  final List<String> terms;
}

/// Phrases that select a cue without any surrounding context.
const plainSpeechCuePatterns = <SpeechCuePattern>[
  SpeechCuePattern('wave', 0, ['挥手', '招手', '挥了挥', 'wave', '再见', '拜拜']),
  SpeechCuePattern('hug', 0, ['抱住', '抱抱', '拥抱', '相拥', 'hug']),
  SpeechCuePattern('nod', 0, ['点头', '颔首', '答应', '赞同', '明白', 'nod', '嗯嗯']),
  SpeechCuePattern('emphasis', 1, [
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
  SpeechCuePattern('thinking', 1, [
    '为什么',
    '怎么会',
    '想一想',
    '思考',
    '疑惑',
    'question',
  ]),
  SpeechCuePattern('dramatic', 1, [
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
  SpeechCuePattern('angry', 1, [
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
  SpeechCuePattern('sad', 1, [
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
  SpeechCuePattern('shy', 1, ['害羞', '脸红', '不好意思', '低下头', '小声说', 'shy']),
  SpeechCuePattern('surprise', 1, [
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
  SpeechCuePattern('happy', 1, [
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
  SpeechCuePattern('greeting', 1, [
    '你好',
    '嗨',
    '哈喽',
    '欢迎',
    '👋',
    'hello',
    'hi ',
  ]),
];

/// Terms that make a segment sound like an internal question.
const thinkingCueTerms = ['为什么', '怎么', '是否', '想一想', '思考', '疑惑', 'question'];

/// Terms that make a segment sound emphatic.
const emphasisCueTerms = [
  '必须',
  '一定',
  '注意',
  '重点',
  '关键',
  '终于',
  '立刻',
  '绝不能',
  'important',
];

/// Terms that make a segment sound like narration.
const dramaticCueTerms = [
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
];

/// Characters that end a sentence, so a probe can start on a fresh one.
const sentenceBreakCharacters = '。！？；…\n!?;.';

/// Characters that allow a long clause to be split.
const clauseBreakCharacters = '，、,：:';

/// Sentence breakers used by the MOSS text splitter.
///
/// `.` is deliberately absent: it would split decimals such as `3.14`.
const mossSentenceBreakCharacters = '。！？!?…\n';

/// Clause breakers used by the MOSS text splitter.
const mossClauseBreakCharacters = '，、；：,;: ';

/// Question marks in both scripts.
const questionMarks = '？?';

/// Exclamation marks in both scripts.
const exclamationMarks = '！!';
