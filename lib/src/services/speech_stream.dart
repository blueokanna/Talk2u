import 'dart:math' as math;

import 'package:talk2u/src/services/speech_text_normalizer.dart';

/// Splits a growing model response into speakable units.
///
/// The first unit is released as soon as a sentence terminator arrives, so
/// synthesis can overlap with the rest of generation. While generation is still
/// running, [takeClause] provides a comma-sized fallback when playback catches
/// up; a complete sentence always wins over that fallback.
///
/// The splitter is deliberately stateful and synchronous: both the model delta
/// callback and the synthesis loop run on the Dart isolate, so no locking is
/// needed and the original text order is preserved.
class SpeechStreamSegmenter {
  SpeechStreamSegmenter({this.minimumSentenceRunes = 1})
    : assert(minimumSentenceRunes >= 1);

  /// Very short sentences are kept. MOSS synthesises `嗯。` correctly and the
  /// user explicitly asked for sentence-level completeness, not a length gate.
  final int minimumSentenceRunes;

  final List<int> _pending = <int>[];
  final _MarkdownFenceGate _fences = _MarkdownFenceGate();

  bool get hasPending => _pending.isNotEmpty || _fences.hasPending;

  /// Appends a raw model delta and returns every completed sentence.
  ///
  /// Markdown fenced code is discarded before it reaches the sentence scanner:
  /// a code block can contain thousands of full stops that must never become
  /// speech.
  List<String> add(String delta) {
    if (delta.isEmpty) return const <String>[];
    _append(_fences.filter(delta));
    return takeSentences();
  }

  /// Returns complete sentences that are already buffered.
  List<String> takeSentences() {
    final result = <String>[];
    while (true) {
      final end = _findSentenceEnd();
      if (end <= 0) break;
      final raw = _take(end);
      _appendSpeakable(raw, result);
    }
    return result;
  }

  /// Releases the text before the last clause break.
  ///
  /// Called only when the audio queue is empty and no complete sentence has
  /// arrived. Returns `null` when there is not yet enough text to speak
  /// naturally; the caller then waits for the next model delta.
  String? takeClause() {
    if (_pending.isEmpty) return null;
    var lastClause = -1;
    var depth = 0;
    for (var index = 0; index < _pending.length; index++) {
      final rune = _pending[index];
      if (_opensBracket(rune)) {
        depth++;
      } else if (_closesBracket(rune)) {
        if (depth > 0) depth--;
      } else if (depth == 0 && _isClauseBreak(rune)) {
        lastClause = index;
      }
    }
    if (lastClause < 0) {
      // No punctuation at all. Do not let a pathological reply grow the
      // segmenter without bound; release a bounded window and keep going.
      if (_pending.length < 96) return null;
      final raw = _take(80);
      final result = <String>[];
      _appendSpeakable(raw, result);
      return result.isEmpty ? null : result.join(' ');
    }
    final raw = _take(lastClause + 1);
    final result = <String>[];
    _appendSpeakable(raw, result);
    return result.isEmpty ? null : result.join(' ');
  }

  /// Flushes the remaining text at end-of-stream.
  List<String> flush() {
    _append(_fences.flush());
    final result = takeSentences();
    while (_pending.isNotEmpty) {
      final clause = takeClause();
      if (clause != null) {
        result.add(clause);
        continue;
      }
      // No punctuation at all: release a bounded window rather than losing the
      // tail. The synthesis loop further splits this by `splitMossText`.
      final raw = _take(math.min(_pending.length, 64));
      _appendSpeakable(raw, result);
    }
    if (result.isNotEmpty && !_endsWithTerminalPunctuation(result.last)) {
      result[result.length - 1] = '${result.last}。';
    }
    return result;
  }

  static bool _endsWithTerminalPunctuation(String text) {
    final runes = text.runes.toList(growable: false);
    var last = runes.length - 1;
    while (last >= 0 &&
        (_isClosingQuote(runes[last]) ||
            runes[last] == 0x20 ||
            runes[last] == 0x09)) {
      last--;
    }
    if (last < 0) return false;
    final rune = runes[last];
    return rune == 0x3002 || // 。
        rune == 0xFF01 || // ！
        rune == 0xFF1F || // ？
        rune == 0x0021 ||
        rune == 0x003F ||
        rune == 0x2026;
  }

  void _append(String text) {
    if (text.isEmpty) return;
    _pending.addAll(text.runes);
  }

  String _take(int length) {
    final safeLength = length.clamp(0, _pending.length);
    final raw = String.fromCharCodes(_pending.take(safeLength));
    _pending.removeRange(0, safeLength);
    return raw;
  }

  void _appendSpeakable(String raw, List<String> target) {
    final spoken = SpeechTextNormalizer.prepare(raw).spokenText.replaceFirst(
      // An emoji-only fragment can leave its punctuation behind after the
      // emoji is removed. A leading break is not a word and must not be sent to
      // the vocoder as the first phoneme of the sentence.
      RegExp(r'^[。！？!?…，,、；;：:\s]+'),
      '',
    );
    if (spoken.isNotEmpty) target.add(spoken);
  }

  /// Index just past the next sentence terminator and its trailing quotes.
  ///
  /// All indices are rune indices into [_pending], never UTF-16 code-unit
  /// offsets. A surrogate pair must not shift a later cut and split an emoji or
  /// a CJK extension-B glyph in half.
  int _findSentenceEnd() {
    final runes = _pending;
    var depth = 0;
    for (var index = 0; index < runes.length; index++) {
      final rune = runes[index];
      if (_opensBracket(rune)) {
        depth++;
        continue;
      }
      if (_closesBracket(rune)) {
        if (depth > 0) depth--;
        continue;
      }
      if (depth > 0) continue;
      if (rune == 0x0A) {
        if (index >= minimumSentenceRunes) {
          return _includeTrailing(runes, index + 1);
        }
        continue;
      }
      if (_isStrongBreak(rune) && index >= minimumSentenceRunes) {
        var end = index + 1;
        // `...` / `……` is one prosodic break, not three sentences.
        while (end < runes.length &&
            (runes[end] == 0x2E || runes[end] == 0x2026)) {
          end++;
        }
        return _includeTrailing(runes, end);
      }
      if (rune == 0x2E && _isLatinSentencePeriod(runes, index)) {
        return _includeTrailing(runes, index + 1);
      }
    }
    return -1;
  }

  bool _isLatinSentencePeriod(List<int> runes, int index) {
    if (index + 1 < runes.length) {
      final next = runes[index + 1];
      if (next == 0x2E || _isAsciiDigit(next) || _isAsciiLetter(next)) {
        return false;
      }
      if (next != 0x20 && next != 0x09 && next != 0x0A && next != 0x0D) {
        return false;
      }
    }
    // Do not split a URL or an e-mail address at its dot.
    var start = index;
    while (start > 0) {
      final unit = runes[start - 1];
      if (unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D) break;
      start--;
    }
    final token = String.fromCharCodes(runes.sublist(start, index));
    if (token.contains('://') ||
        token.startsWith('www.') ||
        token.contains('@') ||
        token.contains('/')) {
      return false;
    }
    return true;
  }

  int _includeTrailing(List<int> runes, int end) {
    var cursor = end;
    while (cursor < runes.length) {
      final rune = runes[cursor];
      if (_isClosingQuote(rune) || rune == 0x20 || rune == 0x09) {
        cursor++;
        continue;
      }
      break;
    }
    return cursor;
  }

  static bool _isStrongBreak(int rune) =>
      rune == 0x3002 || // 。
      rune == 0xFF01 || // ！
      rune == 0xFF1F || // ？
      rune == 0x0021 || // !
      rune == 0x003F || // ?
      rune == 0x2026 || // …
      rune == 0xFF1B || // ；
      rune == 0x003B; // ;

  static bool _isClauseBreak(int rune) =>
      rune == 0x3001 || // 、
      rune == 0xFF0C || // ，
      rune == 0x002C || // ,
      rune == 0xFF1A || // ：
      rune == 0x003A || // :
      rune == 0x2014 || // —
      rune == 0x2013; // –

  static bool _opensBracket(int rune) =>
      rune == 0x0028 || // (
      rune == 0x3010 || // 【
      rune == 0x005B || // [
      rune == 0x300C || // 「
      rune == 0x300E || // 『
      rune == 0xFF08; // （

  static bool _closesBracket(int rune) =>
      rune == 0x0029 || // )
      rune == 0x3011 || // 】
      rune == 0x005D || // ]
      rune == 0x300D || // 」
      rune == 0x300F || // 』
      rune == 0xFF09; // ）

  static bool _isClosingQuote(int rune) =>
      rune == 0x201D || // ”
      rune == 0x2019 || // ’
      rune == 0x300D || // 」
      rune == 0x300F; // 』

  static bool _isAsciiDigit(int rune) => rune >= 0x30 && rune <= 0x39;

  static bool _isAsciiLetter(int rune) =>
      (rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A);
}

/// Removes fenced Markdown blocks from a stream.
///
/// A fence can be split across two model deltas (` ` + `` ` `` + `` ` ``), so
/// the last two marker characters are held back until they can be classified.
class _MarkdownFenceGate {
  String _held = '';
  bool _insideFence = false;
  String _marker = '```';

  bool get hasPending => _held.isNotEmpty;

  String filter(String delta) {
    if (delta.isEmpty) return '';
    var text = '$_held$delta';
    _held = '';
    final output = StringBuffer();
    while (true) {
      if (_insideFence) {
        final close = text.indexOf(_marker);
        if (close < 0) {
          final keep = math.min(text.length, _marker.length - 1);
          _held = text.substring(text.length - keep);
          break;
        }
        text = text.substring(close + _marker.length);
        _insideFence = false;
        continue;
      }
      final open = _findOpeningFence(text);
      if (open < 0) {
        final keep = _trailingFenceCharacters(text);
        if (keep > 0) {
          output.write(text.substring(0, text.length - keep));
          _held = text.substring(text.length - keep);
        } else {
          output.write(text);
        }
        break;
      }
      output.write(text.substring(0, open));
      final marker = text.startsWith('~~~', open) ? '~~~' : '```';
      _insideFence = true;
      _marker = marker;
      text = text.substring(open + marker.length);
    }
    return output.toString();
  }

  String flush() {
    final held = _held;
    _held = '';
    return _insideFence ? '' : held;
  }

  static int _findOpeningFence(String text) {
    final backticks = text.indexOf('```');
    final tildes = text.indexOf('~~~');
    if (backticks < 0) return tildes;
    if (tildes < 0) return backticks;
    return math.min(backticks, tildes);
  }

  static int _trailingFenceCharacters(String text) {
    var count = 0;
    for (var index = text.length - 1; index >= 0 && count < 2; index--) {
      final rune = text.codeUnitAt(index);
      if (rune != 0x60 && rune != 0x7E) break;
      count++;
    }
    return count;
  }
}
