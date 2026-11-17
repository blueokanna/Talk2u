import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/services/speech_stream.dart';

void main() {
  test('releases the first sentence before the rest of the reply arrives', () {
    final segmenter = SpeechStreamSegmenter();
    expect(segmenter.add('你好'), isEmpty);
    expect(segmenter.takeClause(), isNull);
    expect(segmenter.add('，今天过得怎么样？'), ['你好，今天过得怎么样？']);
    expect(segmenter.add('我正在'), isEmpty);
    expect(segmenter.add('听你说。'), ['我正在听你说。']);
  });

  test('clause fallback keeps the voice moving when playback catches up', () {
    final segmenter = SpeechStreamSegmenter();
    expect(segmenter.add('这句话还没有结束，'), isEmpty);
    expect(segmenter.add('但已经够长'), isEmpty);
    // A trailing comma is normalised into a terminal pause so MOSS can close
    // the clause cleanly instead of clipping the last syllable.
    expect(segmenter.takeClause(), '这句话还没有结束。');
    expect(segmenter.add('可以继续了。'), ['但已经够长可以继续了。']);
  });

  test('punctuation inside brackets is not a sentence boundary', () {
    final segmenter = SpeechStreamSegmenter();
    expect(segmenter.add('他说（真的吗？当然！）'), isEmpty);
    expect(segmenter.add('然后笑了。'), ['他说（真的吗？当然！）然后笑了。']);
  });

  test('fenced code is never spoken, even when the fence is split', () {
    final segmenter = SpeechStreamSegmenter();
    expect(segmenter.add('看这个：``'), isEmpty);
    expect(segmenter.add('`dart\nfinal a = 1;\nprint(a);\n``'), isEmpty);
    expect(segmenter.add('` 结束。'), ['看这个： 结束。']);
    expect(segmenter.flush(), isEmpty);
  });

  test('emoji and markdown decorations are removed from speech', () {
    final segmenter = SpeechStreamSegmenter();
    expect(segmenter.add('**真的**吗？😀'), ['真的吗？']);
  });

  test('English periods split sentences but leave decimals and URLs alone', () {
    final segmenter = SpeechStreamSegmenter();
    expect(segmenter.add('Version 3.14 is ready.'), ['Version 3.14 is ready.']);
    expect(segmenter.add('Pi is 3.14. Next.'), ['Pi is 3.14.', 'Next.']);
    // URLs are removed before speech; the dot inside the URL must not split the
    // segment into "See https://example." and "com/a.b now.".
    expect(segmenter.add('See https://example.com/a.b now.'), ['See now.']);
    expect(segmenter.add('Hello world.'), ['Hello world.']);
  });

  test('non-BMP glyphs never shift a sentence cut', () {
    final segmenter = SpeechStreamSegmenter();
    expect(segmenter.add('😀。下一句。'), ['下一句。']);
    expect(segmenter.add('𠀀。'), ['𠀀。']);
  });

  test('long unpunctuated text is released in bounded windows', () {
    final segmenter = SpeechStreamSegmenter();
    expect(segmenter.add('a' * 120), isEmpty);
    final clause = segmenter.takeClause();
    expect(clause, isNotNull);
    expect(clause!.length, lessThanOrEqualTo(80));
    expect(segmenter.flush().join().length, greaterThan(0));
  });

  test('flush releases an unpunctuated tail without losing it', () {
    final segmenter = SpeechStreamSegmenter();
    expect(segmenter.add('没有句号的一段话'), isEmpty);
    expect(segmenter.flush(), ['没有句号的一段话。']);
  });
}
