import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/services/offline_speech_service.dart';
import 'package:talk2u/src/services/sherpa_speech_service.dart';

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
    });

    expect(capabilities.offlineTts, isTrue);
    expect(capabilities.offlineStt, isTrue);
    expect(capabilities.sttModelDownload, isTrue);
    expect(capabilities.audioAmplitude, isTrue);
    expect(capabilities.ttsVoice, 'zh-cn-offline');
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
    });

    test('uses neutral cue for ordinary text', () {
      expect(OfflineSpeechService.inferAnimationCue('我们继续讨论这个问题。'), 'neutral');
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

  group('sherpa playback amplitude envelope', () {
    test('uses generated PCM energy instead of a synthetic mouth pattern', () {
      final samples = Float32List.fromList([
        ...List<double>.filled(20, 0),
        ...List<double>.filled(20, 0.10),
      ]);

      final envelope = buildPcmAmplitudeEnvelope(
        samples,
        1000,
        frameMilliseconds: 20,
      );

      expect(envelope, hasLength(2));
      expect(envelope.first, 0);
      expect(envelope.last, closeTo(0.3825, 0.001));
    });

    test('clamps loud audio and rejects invalid input', () {
      expect(
        buildPcmAmplitudeEnvelope(Float32List.fromList([1, -1]), 1000).first,
        1,
      );
      expect(buildPcmAmplitudeEnvelope(Float32List(0), 16000), isEmpty);
      expect(buildPcmAmplitudeEnvelope(Float32List(10), 0), isEmpty);
    });
  });
}
