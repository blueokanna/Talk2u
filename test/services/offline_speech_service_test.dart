import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/services/moss_tts_service.dart';
import 'package:talk2u/src/services/offline_speech_service.dart';

void main() {
  test('parses verified Android speech capabilities', () {
    final capabilities = SpeechCapabilities.fromMap({
      'offlineTts': true,
      'offlineStt': true,
      'sttModelDownload': true,
      'audioAmplitude': true,
      'ttsVoice': 'zh-cn-offline',
      'ttsLocale': 'zh-CN',
      'sttLocale': 'zh-CN',
      'ttsVoices': [
        {'name': '中文（明朗男声）', 'locale': 'zh-CN', 'gender': 'male'},
        {'name': '中文（温柔女声）', 'locale': 'zh-CN', 'gender': 'female'},
      ],
    });

    expect(capabilities.offlineTts, isTrue);
    expect(capabilities.offlineStt, isTrue);
    expect(capabilities.sttModelDownload, isTrue);
    expect(capabilities.audioAmplitude, isTrue);
    expect(capabilities.ttsVoice, 'zh-cn-offline');
    expect(capabilities.ttsVoices, hasLength(2));
    expect(capabilities.ttsVoices.first.gender, 'male');
    expect(capabilities.ttsVoices.first.displayLabel, contains('男声'));
  });

  group('OfflineSpeechService animation cue', () {
    test('recognizes explicit body actions before emotion words', () {
      expect(OfflineSpeechService.inferAnimationCue('她开心地挥手说再见'), 'wave');
      expect(OfflineSpeechService.inferAnimationCue('*抱住你* 别难过'), 'hug');
      expect(OfflineSpeechService.inferAnimationCue('认真地点头'), 'nod');
    });

    test('recognizes common emotions in Chinese and English', () {
      expect(OfflineSpeechService.inferAnimationCue('哈哈，太开心了'), 'happy');
      expect(OfflineSpeechService.inferAnimationCue('I am angry now'), 'angry');
      expect(OfflineSpeechService.inferAnimationCue('真的很难过'), 'sad');
      expect(OfflineSpeechService.inferAnimationCue('有点不好意思'), 'shy');
      expect(OfflineSpeechService.inferAnimationCue('居然是真的吗'), 'surprise');
      expect(OfflineSpeechService.inferAnimationCue('哈喽～ 👋'), 'greeting');
    });

    test('extracts changing actions and emotions from narrative text', () {
      final cues = OfflineSpeechService.inferAnimationCues(
        '她突然停下脚步，眼泪悄悄涌出，最后抬起头认真点头。',
      );

      expect(cues.map((cue) => cue.cue), ['surprise', 'sad', 'nod']);
    });

    test('uses a talking motion for ordinary playback', () {
      expect(OfflineSpeechService.inferAnimationCue('我们继续讨论这个问题。'), 'talking');
    });

    test('creates contextual motion cues for story sentences', () {
      final cues = OfflineSpeechService.inferAnimationCues(
        '从前有一座安静的小城。为什么钟声突然停了？一定要在天黑前找到答案！',
      );

      expect(cues.first.cue, 'dramatic');
      expect(cues.map((cue) => cue.cue), containsAll(['surprise', 'emphasis']));
    });

    test('extracts ordered cues for TTS range callbacks', () {
      final cues = OfflineSpeechService.inferAnimationCues(
        '你好，我很开心，然后挥手再见，最后抱抱你。',
      );

      expect(cues.map((cue) => cue.cue), ['greeting', 'happy', 'wave', 'hug']);
      expect(
        cues.map((cue) => cue.start),
        orderedEquals(cues.map((cue) => cue.start).toList()..sort()),
      );
    });

    test('deduplicates nearby repeated actions', () {
      final cues = OfflineSpeechService.inferAnimationCues('挥手挥手，然后继续说明。');
      expect(cues.where((cue) => cue.cue == 'wave'), hasLength(1));
    });
  });

  group('MOSS playback amplitude envelope', () {
    test('uses generated PCM energy instead of a synthetic mouth pattern', () {
      final directory = Directory.systemTemp.createTempSync('talk2u-moss-wav-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}${Platform.pathSeparator}speech.wav');
      _writePcmWav(file, [
        ...List<double>.filled(20, 0),
        ...List<double>.filled(20, 0.10),
      ], sampleRate: 1000);

      final envelope = buildWavAmplitudeEnvelope(file.path);

      expect(envelope, hasLength(2));
      expect(envelope.first, 0);
      expect(envelope.last, closeTo(0.495, 0.002));
    });

    test('clamps loud audio and rejects invalid input', () {
      final directory = Directory.systemTemp.createTempSync('talk2u-moss-wav-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final loud = File('${directory.path}${Platform.pathSeparator}loud.wav');
      _writePcmWav(loud, [1, -1], sampleRate: 1000);
      expect(buildWavAmplitudeEnvelope(loud.path).first, 1);
      final invalid = File(
        '${directory.path}${Platform.pathSeparator}invalid.wav',
      )..writeAsBytesSync([1, 2, 3]);
      expect(
        () => buildWavAmplitudeEnvelope(invalid.path),
        throwsFormatException,
      );
    });
  });

  group('MOSS-TTS-Nano', () {
    test('exposes verified Chinese male and female voices', () {
      final chinese = MossTtsService.voices.where(
        (voice) => voice.locale == 'zh-CN',
      );

      expect(chinese.where((voice) => voice.gender == 'male'), hasLength(3));
      expect(chinese.where((voice) => voice.gender == 'female'), hasLength(3));
      expect(MossTtsService.modelBytes, 717414286);
    });

    test('splits long narrative text on semantic boundaries', () {
      final chunks = splitMossText(
        '从前有一座安静的小城。她忽然停下脚步，认真听远处传来的钟声。后来大家终于找到了答案，太好了！真的吗？',
        maxCharacters: 24,
      );

      expect(chunks, hasLength(4));
      expect(chunks.first, endsWith('。'));
      expect(chunks.last, endsWith('？'));
      expect(chunks.every((chunk) => chunk.isNotEmpty), isTrue);
    });

    test('caps unpunctuated segments for progressive synthesis', () {
      final chunks = splitMossText(
        '这是一段没有停顿符号但需要尽快开始播放的长文本内容用于验证分段合成不会等待整段回答全部完成',
        maxCharacters: 12,
      );

      expect(chunks.length, greaterThan(1));
      expect(chunks.every((chunk) => chunk.runes.length <= 12), isTrue);
      expect(chunks.join(), '这是一段没有停顿符号但需要尽快开始播放的长文本内容用于验证分段合成不会等待整段回答全部完成');
    });

    test(
      'normalizes full-width text like the official SentencePiece runtime',
      () {
        expect(
          normalizeMossSentencePieceText('你好，真的吗？ＡＢＣ　１２３！'),
          '你好,真的吗?ABC 123!',
        );
      },
    );
  });
}

void _writePcmWav(File file, List<double> samples, {required int sampleRate}) {
  final dataSize = samples.length * 2;
  final bytes = ByteData(44 + dataSize);
  void text(int offset, String value) {
    final encoded = value.codeUnits;
    for (var index = 0; index < encoded.length; index++) {
      bytes.setUint8(offset + index, encoded[index]);
    }
  }

  text(0, 'RIFF');
  bytes.setUint32(4, 36 + dataSize, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  text(36, 'data');
  bytes.setUint32(40, dataSize, Endian.little);
  for (var index = 0; index < samples.length; index++) {
    bytes.setInt16(
      44 + index * 2,
      (samples[index].clamp(-1, 1) * 32767).round(),
      Endian.little,
    );
  }
  file.writeAsBytesSync(bytes.buffer.asUint8List());
}
