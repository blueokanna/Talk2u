import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/services/turn_taking.dart';

void main() {
  group('ReferenceAnchoredEchoGate', () {
    test('treats playback leakage as echo, never as barge-in', () {
      final gate = ReferenceAnchoredEchoGate();

      TurnTakingDecision? last;
      for (var frame = 0; frame < 60; frame++) {
        last = gate
            .evaluate(
              observedRms: 0.30,
              referenceAmplitude: 0.95,
              playbackActive: true,
            )
            .decision;
      }

      expect(last, isNot(TurnTakingDecision.bargeIn));
    });

    test('detects double talk above the residual echo floor', () {
      final gate = ReferenceAnchoredEchoGate();

      TurnTakingSnapshot? snapshot;
      for (var frame = 0; frame < 20; frame++) {
        snapshot = gate.evaluate(
          observedRms: 0.42,
          referenceAmplitude: 0.2,
          playbackActive: true,
        );
      }

      expect(snapshot!.decision, TurnTakingDecision.bargeIn);
      expect(snapshot.voicedMilliseconds, greaterThanOrEqualTo(140));
    });

    test('hardware cancellation tightens the leak estimate', () {
      final gate = ReferenceAnchoredEchoGate()..bindHardwareEchoCancellation(true);
      final withoutCanceller = ReferenceAnchoredEchoGate();

      final cancelled = gate.evaluate(
        observedRms: 0.02,
        referenceAmplitude: 1,
        playbackActive: true,
      );
      final raw = withoutCanceller.evaluate(
        observedRms: 0.02,
        referenceAmplitude: 1,
        playbackActive: true,
      );

      expect(cancelled.threshold, lessThan(raw.threshold));
    });

    test('silence keeps the noise floor low and stays quiet', () {
      final gate = ReferenceAnchoredEchoGate();
      TurnTakingSnapshot? snapshot;
      for (var frame = 0; frame < 40; frame++) {
        snapshot = gate.evaluate(
          observedRms: 0.003,
          referenceAmplitude: 0,
          playbackActive: false,
        );
      }
      expect(snapshot!.decision, TurnTakingDecision.quiet);
      expect(gate.last.threshold, lessThan(0.05));
    });
  });

  group('SelfEchoTranscriptFilter', () {
    test('rejects the recognizer echoing the agent own sentence', () {
      final filter = SelfEchoTranscriptFilter()
        ..rememberSpoken('今天外面下着小雨，我们改天再去海边吧。');

      expect(filter.isSelfEcho('今天外面下着小雨，我们改天再去海边吧'), isTrue);
      // A truncated capture of our own line is still self echo.
      expect(filter.isSelfEcho('今天外面下着小雨'), isTrue);
    });

    test('accepts an unrelated user utterance', () {
      final filter = SelfEchoTranscriptFilter()
        ..rememberSpoken('今天外面下着小雨，我们改天再去海边吧。');

      expect(filter.isSelfEcho('帮我把明天的会议推迟到下午三点'), isFalse);
    });

    test('ignores very short fragments to avoid dropping real answers', () {
      final filter = SelfEchoTranscriptFilter()..rememberSpoken('好的');
      expect(filter.isSelfEcho('好的'), isFalse);
    });

    test('expired history no longer suppresses speech', () {
      var now = DateTime(2026, 1, 1, 12);
      final filter = SelfEchoTranscriptFilter(clock: () => now)
        ..rememberSpoken('这是一段会被遗忘的语音内容');

      now = now.add(const Duration(seconds: 30));

      expect(filter.isSelfEcho('这是一段会被遗忘的语音内容'), isFalse);
    });
  });
}
