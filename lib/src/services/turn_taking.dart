import 'dart:math' as math;

import 'package:flutter/foundation.dart';

enum TurnTakingDecision {
  /// Nothing audible in the room; keep listening.
  quiet,

  /// Energy is consistent with the agent's own playback leaking back.
  echo,

  /// A human is speaking over the agent; playback should yield immediately.
  bargeIn,
}

@immutable
class TurnTakingSnapshot {
  const TurnTakingSnapshot({
    required this.decision,
    required this.observedRms,
    required this.expectedEcho,
    required this.threshold,
    required this.voicedMilliseconds,
  });

  final TurnTakingDecision decision;
  final double observedRms;
  final double expectedEcho;
  final double threshold;
  final int voicedMilliseconds;
}

/// Double-talk detector anchored on the agent's own speech reference.
///
/// Conventional acoustic echo cancellation has to estimate the echo path
/// blindly. A companion agent does not: it synthesizes the playback itself, so
/// the reference envelope `a(t)` is exactly known. That turns echo suppression
/// into a known-reference problem.
///
/// The remaining unknown is the device-dependent bulk delay between playback
/// and capture (20–120 ms), so the estimate uses a peak-hold of the reference
/// over a short window instead of a time-aligned sample. This keeps the
/// detector delay-agnostic: no cross-correlation, no half-duplex mute.
///
/// Decision rule for an observed frame `x` and reference peak `R`:
///
///   E = lambda * R                       (predicted residual echo)
///   tau = max(n * g, E * gamma + m)      (barge-in threshold)
///
/// `bargeIn` requires `x > tau` for at least [holdMilliseconds] of continuous
/// voiced audio, which is what separates real double-talk from a click.
class ReferenceAnchoredEchoGate {
  ReferenceAnchoredEchoGate({
    this.leakFactor = 0.55,
    this.echoMargin = 0.012,
    this.relativeMargin = 1.6,
    this.minimumThreshold = 0.014,
    this.noiseMultiplier = 3.2,
    this.holdMilliseconds = 140,
    this.referenceWindowMilliseconds = 180,
  });

  /// Baseline residual-echo gain. Tightened by the caller once a hardware echo
  /// canceller is confirmed, because the platform already removed most of it.
  double leakFactor;
  final double echoMargin;
  final double relativeMargin;
  final double minimumThreshold;
  final double noiseMultiplier;
  final int holdMilliseconds;
  final int referenceWindowMilliseconds;

  static const _frameMilliseconds = 20;

  final _referenceHistory = <double>[];
  double _noiseFloor = 0.004;
  int _voicedMilliseconds = 0;
  int _echoHoldoffMilliseconds = 0;
  TurnTakingSnapshot _last = const TurnTakingSnapshot(
    decision: TurnTakingDecision.quiet,
    observedRms: 0,
    expectedEcho: 0,
    threshold: 0,
    voicedMilliseconds: 0,
  );

  TurnTakingSnapshot get last => _last;

  void reset() {
    _referenceHistory.clear();
    _noiseFloor = 0.004;
    _voicedMilliseconds = 0;
    _echoHoldoffMilliseconds = 0;
  }

  static double rmsOfPcm16(Uint8List frame) {
    final samples = frame.length ~/ 2;
    if (samples == 0) return 0;
    final data = ByteData.sublistView(frame, 0, samples * 2);
    var energy = 0.0;
    for (var index = 0; index < samples; index++) {
      final sample = data.getInt16(index * 2, Endian.little) / 32768.0;
      energy += sample * sample;
    }
    return math.sqrt(energy / samples);
  }

  /// Feeds one 20 ms capture frame and the reference amplitude that the
  /// synthesiser reported for the same instant.
  TurnTakingSnapshot evaluate({
    required double observedRms,
    required double referenceAmplitude,
    required bool playbackActive,
  }) {
    final reference = playbackActive
        ? referenceAmplitude.clamp(0.0, 1.0).toDouble()
        : 0.0;
    _referenceHistory.add(reference);
    final window = math.max(
      1,
      referenceWindowMilliseconds ~/ _frameMilliseconds,
    );
    if (_referenceHistory.length > window) {
      _referenceHistory.removeRange(0, _referenceHistory.length - window);
    }
    final referencePeak = _referenceHistory.reduce(math.max);

    final expectedEcho = leakFactor * referencePeak;
    final threshold = math.max(
      math.max(minimumThreshold, _noiseFloor * noiseMultiplier),
      expectedEcho * relativeMargin + echoMargin,
    );

    if (_echoHoldoffMilliseconds > 0) {
      _echoHoldoffMilliseconds -= _frameMilliseconds;
    }

    var decision = TurnTakingDecision.quiet;
    if (observedRms > threshold) {
      _voicedMilliseconds += _frameMilliseconds;
      decision = _voicedMilliseconds >= holdMilliseconds
          ? TurnTakingDecision.bargeIn
          : _echoHoldoffMilliseconds > 0
          ? TurnTakingDecision.echo
          : TurnTakingDecision.quiet;
    } else {
      _voicedMilliseconds = math.max(0, _voicedMilliseconds - _frameMilliseconds);
      if (observedRms > expectedEcho * 0.6 && expectedEcho > minimumThreshold) {
        decision = TurnTakingDecision.echo;
        _echoHoldoffMilliseconds = 240;
      } else {
        if (referencePeak < 0.05) {
          _noiseFloor = (_noiseFloor * 0.95 + observedRms * 0.05)
              .clamp(0.001, 0.03)
              .toDouble();
        }
      }
    }

    _last = TurnTakingSnapshot(
      decision: decision,
      observedRms: observedRms,
      expectedEcho: expectedEcho,
      threshold: threshold,
      voicedMilliseconds: _voicedMilliseconds,
    );
    return _last;
  }

  /// A hardware echo canceller removes most of the residual, so the software
  /// gate only needs to catch what is left.
  void bindHardwareEchoCancellation(bool verified) {
    leakFactor = verified ? 0.18 : 0.55;
  }
}

/// Rejects transcripts the recognizer produced from the agent's own voice.
///
/// The gate above works on energy and can therefore be defeated by a loud
/// speaker. This filter uses the one signal a companion agent always has: the
/// exact text it just read out. Character-bigram Dice similarity against
/// recently spoken segments catches ASR hallucinating the agent's own words
/// without penalising a user who genuinely repeats a short phrase.
class SelfEchoTranscriptFilter {
  SelfEchoTranscriptFilter({
    this.similarityThreshold = 0.6,
    this.maxSegments = 4,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final double similarityThreshold;
  final int maxSegments;
  final DateTime Function() _clock;
  final _segments = <({String text, DateTime at})>[];

  void rememberSpoken(String text) {
    final normalized = _normalize(text);
    if (normalized.length < 4) return;
    _segments.add((text: normalized, at: _clock()));
    if (_segments.length > maxSegments) {
      _segments.removeRange(0, _segments.length - maxSegments);
    }
  }

  void clear() => _segments.clear();

  bool isSelfEcho(
    String transcript, {
    Duration horizon = const Duration(seconds: 8),
  }) {
    final normalized = _normalize(transcript);
    if (normalized.length < 6) return false;
    final cutoff = _clock().subtract(horizon);
    for (final segment in _segments) {
      if (segment.at.isBefore(cutoff)) continue;
      if (segment.text.contains(normalized) && normalized.length >= 8) {
        return true;
      }
      if (_dice(segment.text, normalized) >= similarityThreshold) return true;
    }
    return false;
  }

  static String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');

  static double _dice(String left, String right) {
    final leftGrams = _bigrams(left);
    final rightGrams = _bigrams(right);
    if (leftGrams.isEmpty || rightGrams.isEmpty) return 0;
    var overlap = 0;
    for (final entry in leftGrams.entries) {
      final other = rightGrams[entry.key];
      if (other == null) continue;
      overlap += math.min(entry.value, other);
    }
    final total =
        leftGrams.values.fold<int>(0, (sum, count) => sum + count) +
        rightGrams.values.fold<int>(0, (sum, count) => sum + count);
    return total == 0 ? 0 : 2 * overlap / total;
  }

  static Map<String, int> _bigrams(String value) {
    final result = <String, int>{};
    for (var index = 0; index + 1 < value.length; index++) {
      final gram = value.substring(index, index + 2);
      result[gram] = (result[gram] ?? 0) + 1;
    }
    return result;
  }
}
