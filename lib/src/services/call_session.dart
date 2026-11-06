import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:talk2u/src/services/turn_taking.dart';

enum CallPhase { idle, listening, thinking, speaking, halted }

/// Everything a hands-free call needs from the speech stack, and nothing about
/// how speech is implemented.
abstract interface class CallSpeechPort {
  bool get listening;
  bool get speaking;
  bool get generating;
  double get amplitude;
  bool get echoCancellationVerified;
  String get captureSource;
  Stream<String> get transcripts;
  Stream<double> get frameEnergies;

  Future<void> initialize();

  Future<void> startListening();

  Future<void> stopListening();

  Future<void> speak(String text);

  /// Resolves only after the utterance has finished playing.
  Future<void> speakToCompletion(String text);

  Future<void> stopSpeaking();

  bool isSelfEcho(String transcript);
}

/// Turn-taking state machine for continuous voice chat.
///
/// Owns the listen → transcribe → generate → speak → listen cycle, the
/// self-echo rejection, and barge-in. When the platform confirms a hardware
/// echo canceller the microphone stays open during playback and the
/// reference-anchored gate decides whether an incoming frame is residual echo
/// or a human interrupting. Without that confirmation the session degrades to
/// half-duplex: the microphone is closed while speaking, so the agent can never
/// hear itself.
class CallSession extends ChangeNotifier {
  CallSession({
    required CallSpeechPort port,
    required Future<void> Function(String text) onSend,
    required Future<void> Function() onStopGeneration,
    ReferenceAnchoredEchoGate? gate,
    this.settleDelay = const Duration(milliseconds: 320),
    this.maximumTurnMilliseconds = 120000,
  }) : _port = port,
       _onSend = onSend,
       _onStopGeneration = onStopGeneration,
       _gate = gate ?? ReferenceAnchoredEchoGate();

  final CallSpeechPort _port;
  final Future<void> Function(String text) _onSend;
  final Future<void> Function() _onStopGeneration;
  final ReferenceAnchoredEchoGate _gate;
  final Duration settleDelay;
  final int maximumTurnMilliseconds;

  CallPhase _phase = CallPhase.idle;
  StreamSubscription<String>? _transcriptSubscription;
  StreamSubscription<double>? _energySubscription;
  Timer? _turnTimeout;
  int _generation = 0;
  bool _busy = false;
  String? _lastError;
  int _bargeInCount = 0;
  DateTime? _dispatchGraceUntil;

  CallPhase get phase => _phase;
  bool get active => _phase != CallPhase.idle && _phase != CallPhase.halted;
  bool get isBusy => _busy;
  String? get lastError => _lastError;
  int get bargeInCount => _bargeInCount;

  /// Acoustic interruption is only offered when the platform actually granted
  /// an echo canceller; otherwise the session stays half-duplex rather than
  /// pretending to hear the user over its own voice.
  bool get acousticBargeIn => _port.echoCancellationVerified;

  String get captureSource => _port.captureSource;

  Future<void> start() async {
    if (_phase != CallPhase.idle) return;
    _lastError = null;
    _generation++;
    try {
      await _port.initialize();
      _gate
        ..reset()
        ..bindHardwareEchoCancellation(_port.echoCancellationVerified);
      _transcriptSubscription ??= _port.transcripts.listen(_handleTranscript);
      if (acousticBargeIn) {
        _energySubscription ??= _port.frameEnergies.listen(_handleFrameEnergy);
      }
      await _port.startListening();
      _setPhase(CallPhase.listening);
      _armTurnTimeout();
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> stop() async {
    _generation++;
    _turnTimeout?.cancel();
    _turnTimeout = null;
    await _transcriptSubscription?.cancel();
    await _energySubscription?.cancel();
    _transcriptSubscription = null;
    _energySubscription = null;
    _gate.reset();
    _busy = false;
    try {
      if (_port.speaking || _port.generating) await _port.stopSpeaking();
    } on Object catch (_) {
      // Playback teardown must not block ending the call.
    }
    try {
      if (_port.listening) await _port.stopListening();
    } on Object catch (_) {
      // Recorder teardown must not block ending the call.
    }
    _setPhase(CallPhase.idle);
  }

  /// Mic button. Opens the microphone on demand; if the agent is talking, the
  /// user pressing the mic is itself an interrupt.
  Future<void> toggleMicrophone() async {
    if (_phase == CallPhase.idle) {
      await start();
      return;
    }
    if (_port.listening && !_port.speaking) {
      await _port.stopListening();
      return;
    }
    await interrupt();
  }

  /// Stops whatever the agent is doing and hands the turn back to the user.
  Future<void> interrupt() async {
    if (_port.speaking || _port.generating) {
      try {
        await _port.stopSpeaking();
      } on Object catch (error) {
        _lastError = error.toString();
      }
    }
    try {
      await _onStopGeneration();
    } on Object catch (error) {
      _lastError = error.toString();
    }
    _busy = false;
    await _listen();
  }

  /// Called when the chat layer finished a reply. Speaking is the only place
  /// where playback is allowed to start, so a late completion from an earlier
  /// turn cannot talk over the current one.
  Future<void> onResponseCompleted(String reply) async {
    if (_phase == CallPhase.idle || _phase == CallPhase.halted) return;
    if (reply.trim().isEmpty) {
      await _listen();
      return;
    }
    final generation = _generation;
    _setPhase(CallPhase.speaking);
    try {
      // Half-duplex fallback: close the microphone so the recognizer cannot
      // pick up the assistant's own voice at all.
      if (!acousticBargeIn && _port.listening) {
        await _port.stopListening();
      }
      await _port.speakToCompletion(reply);
    } on Object catch (error) {
      _lastError = error.toString();
    }
    if (generation != _generation) return;
    if (acousticBargeIn && _port.listening) {
      _setPhase(CallPhase.listening);
      _armTurnTimeout();
      return;
    }
    await Future<void>.delayed(settleDelay);
    if (generation != _generation) return;
    await _listen();
  }

  void onResponseFailed() {
    if (_phase == CallPhase.idle || _phase == CallPhase.halted) return;
    _busy = false;
    unawaited(_listen());
  }

  void _handleTranscript(String raw) {
    if (_phase == CallPhase.idle || _phase == CallPhase.halted) return;
    final transcript = raw.trim();
    if (transcript.isEmpty) return;
    if (_port.isSelfEcho(transcript)) return;

    if (_phase == CallPhase.speaking) {
      _bargeInCount++;
      // The sentence that interrupted the agent is the next turn, not noise.
      unawaited(_interruptAndDispatch(transcript));
      return;
    }
    if (_phase == CallPhase.thinking) {
      final grace = _dispatchGraceUntil;
      if (grace != null && DateTime.now().isBefore(grace)) return;
      _bargeInCount++;
      unawaited(interrupt());
      return;
    }
    if (_busy || _phase != CallPhase.listening) return;
    unawaited(_dispatch(transcript));
  }

  void _handleFrameEnergy(double rms) {
    if (!acousticBargeIn) return;
    if (_phase != CallPhase.speaking && _phase != CallPhase.thinking) return;
    // The tail of the utterance that opened this turn is still in the buffer;
    // treating it as an interruption would cancel the reply it just triggered.
    final grace = _dispatchGraceUntil;
    if (grace != null && DateTime.now().isBefore(grace)) return;
    final snapshot = _gate.evaluate(
      observedRms: rms,
      referenceAmplitude: _port.amplitude,
      playbackActive: _port.speaking,
    );
    if (snapshot.decision == TurnTakingDecision.bargeIn) {
      _bargeInCount++;
      unawaited(interrupt());
    }
  }

  Future<void> _interruptAndDispatch(String transcript) async {
    await interrupt();
    if (_phase != CallPhase.listening) return;
    await _dispatch(transcript);
  }

  Future<void> _dispatch(String transcript) async {
    final generation = _generation;
    _busy = true;
    _dispatchGraceUntil = DateTime.now().add(const Duration(milliseconds: 900));
    _turnTimeout?.cancel();
    _setPhase(CallPhase.thinking);
    try {
      await _onSend(transcript);
    } catch (error) {
      if (generation != _generation) return;
      _fail(error);
      return;
    }
    if (generation != _generation) return;
    _armTurnTimeout();
  }

  Future<void> _listen({int attempt = 0}) async {
    if (_phase == CallPhase.idle || _phase == CallPhase.halted) return;
    _busy = false;
    _setPhase(CallPhase.listening);
    if (!_port.listening) {
      try {
        await _port.startListening();
      } catch (error) {
        _fail(error);
        return;
      }
    }
    if (!_port.listening && attempt < 3) {
      // The recogniser may still be finishing the previous utterance; retry
      // instead of leaving the session believing it is listening with a closed
      // microphone.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (_phase != CallPhase.listening) return;
      await _listen(attempt: attempt + 1);
      return;
    }
    _armTurnTimeout();
  }

  void _armTurnTimeout() {
    _turnTimeout?.cancel();
    _turnTimeout = Timer(
      Duration(milliseconds: maximumTurnMilliseconds),
      () {
        if (_phase == CallPhase.thinking) {
          unawaited(interrupt());
        }
      },
    );
  }

  void _fail(Object error) {
    _lastError = error.toString();
    _busy = false;
    _turnTimeout?.cancel();
    _setPhase(CallPhase.halted);
  }

  void _setPhase(CallPhase value) {
    if (_phase == value) return;
    _phase = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _generation++;
    _turnTimeout?.cancel();
    _transcriptSubscription?.cancel();
    _energySubscription?.cancel();
    super.dispose();
  }
}
