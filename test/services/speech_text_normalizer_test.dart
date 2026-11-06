import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/services/moss_tts_service.dart';
import 'package:talk2u/src/services/speech_text_normalizer.dart';

void main() {
  group('SpeechTextNormalizer', () {
    test('removes emoji instead of letting the vocoder read them', () {
      final plan = SpeechTextNormalizer.prepare('太棒了😊😊！下次见👋');

      expect(plan.spokenText, isNot(contains('😊')));
      expect(plan.spokenText, isNot(contains('👋')));
      expect(plan.spokenText, contains('太棒了'));
      expect(plan.spokenText, contains('下次见'));
      expect(plan.emotion, 'happy');
    });

    test('turns blank lines into sentence pauses, never newline characters', () {
      final plan = SpeechTextNormalizer.prepare(
        '第一段。\n\n\n第二段，\n还有一句。',
      );

      expect(plan.spokenText, isNot(contains('\n')));
      expect(plan.spokenText, '第一段。第二段，还有一句。');
    });

    test('drops reasoning, code fences, inline code, markdown and URLs', () {
      final plan = SpeechTextNormalizer.prepare(
        '<think>内部推理不应朗读</think>\n'
        '## 结论\n'
        '**重点**是[链接](https://example.com) 和 `code`。\n'
        '```dart\nprint("x");\n```\n'
        '访问 https://example.com 获取原文。',
      );

      expect(plan.spokenText, isNot(contains('内部推理')));
      expect(plan.spokenText, isNot(contains('print')));
      expect(plan.spokenText, isNot(contains('https')));
      expect(plan.spokenText, isNot(contains('##')));
      expect(plan.spokenText, isNot(contains('**')));
      expect(plan.spokenText, contains('结论'));
      expect(plan.spokenText, contains('重点是链接'));
    });

    test('keeps explanatory parentheses but removes stage directions', () {
      final explanatory = SpeechTextNormalizer.prepare(
        'NNAPI（神经网络 API）仍然兼容。',
      );
      expect(explanatory.spokenText, contains('神经网络 API'));

      final direction = SpeechTextNormalizer.prepare(
        '女生：（哈哈大笑）你说得太好了！',
      );
      expect(direction.spokenText, '你说得太好了！');
      expect(direction.stageDirections.single.text, '哈哈大笑');
      expect(direction.emotion, 'happy');
    });

    test('maps emoji affect into the sustained emotion', () {
      expect(SpeechTextNormalizer.emotionOf('真的很难过😭'), 'sad');
      expect(SpeechTextNormalizer.emotionOf('气死我了😡'), 'angry');
      expect(SpeechTextNormalizer.emotionOf('哈哈😄太好了'), 'happy');
      expect(SpeechTextNormalizer.emotionOf('为什么会这样🤔'), 'thinking');
    });

    test('produces punctuation-only cleanup for emoji-only replies', () {
      final plan = SpeechTextNormalizer.prepare('😊😊😊');
      expect(plan.spokenText, isEmpty);
    });

    test('cleans streaming transcripts without touching normal words', () {
      expect(
        SpeechTextNormalizer.cleanTranscript(' 你好 😊 世界 \n'),
        '你好 世界',
      );
    });

    test('cleaned replies split into speakable MOSS chunks', () {
      final plan = SpeechTextNormalizer.prepare(
        '她笑了😊。\n\n然后说：我们可以出发了。',
      );
      final chunks = splitMossText(plan.spokenText, maxCharacters: 12);

      expect(chunks, isNotEmpty);
      expect(chunks.every((chunk) => !chunk.contains('\n')), isTrue);
      expect(chunks.every((chunk) => !chunk.contains('😊')), isTrue);
    });
  });
}
