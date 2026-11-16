import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:talk2u/src/services/turn_taking.dart';

enum CallPhase { idle, listening, thinking, speaking, halted }

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

/// Owns the listen → generate → speak cycle. Acoustic interruption is enabled
/// only after the running capture source confirms its hardware echo canceller.
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
  Timer? _captureWatchdog;
  Future<void>? _startOperation;
  Future<void>? _stopOperation;
  Future<void>? _interruptOperation;
  bool _openingCapture = false;
  bool _microphonePaused = false;
  bool _acceptResponses = false;
  bool _disposed = false;
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
  bool get acousticBargeIn => _port.echoCancellationVerified;
  String get captureSource => _port.captureSource;
  bool _current(int generation) => !_disposed && generation == _generation;

  Future<void> start() async {
    if (_disposed) return;
    final stopping = _stopOperation;
    if (stopping != null) await stopping;
    if (_disposed) return;
    final starting = _startOperation;
    if (starting != null) return starting;
    if (active) return;
    final operation = _start();
    _startOperation = operation;
    try {
      await operation;
    } finally {
      if (identical(_startOperation, operation)) _startOperation = null;
    }
  }

  Future<void> _start() async {
    final generation = ++_generation;
    _lastError = null;
    _microphonePaused = false;
    _acceptResponses = true;
    _dispatchGraceUntil = null;
    try {
      await _port.initialize();
      if (!_current(generation)) return;
      _gate.reset();
      _transcriptSubscription ??= _port.transcripts.listen(_handleTranscript);
      // Capabilities become authoritative only after capture has opened.
      _energySubscription ??= _port.frameEnergies.listen(_handleFrameEnergy);
      _setPhase(CallPhase.listening);
      await _ensureCapture(generation);
      if (!_current(generation) || !active) return;
      _captureWatchdog?.cancel();
      // VAD can finish with silence or rejected echo, producing no transcript.
      // Reopen capture after recognition settles, including between replies.
      _captureWatchdog = Timer.periodic(const Duration(milliseconds: 400), (_) {
        if (_microphonePaused || _interruptOperation != null || !active) return;
        if (_phase == CallPhase.speaking && !acousticBargeIn) return;
        unawaited(_ensureCapture(_generation));
      });
    } catch (error) {
      if (_current(generation)) _fail(error);
    }
  }

  Future<void> stop() {
    final stopping = _stopOperation;
    if (stopping != null) return stopping;
    final operation = _stop();
    _stopOperation = operation;
    return operation.whenComplete(() {
      if (identical(_stopOperation, operation)) _stopOperation = null;
    });
  }

  Future<void> _stop() async {
    _generation++;
    _acceptResponses = false;
    _turnTimeout?.cancel();
    _captureWatchdog?.cancel();
    _busy = false;
    _setPhase(CallPhase.idle);
    await _transcriptSubscription?.cancel();
    await _energySubscription?.cancel();
    _transcriptSubscription = null;
    _energySubscription = null;
    _gate.reset();
    try {
      await _onStopGeneration();
    } on Object catch (_) {
      // Independent teardown steps must still run if generation stop fails.
    }
    try {
      // Also cancel speech still awaiting model initialization.
      await _port.stopSpeaking();
    } on Object catch (_) {}
    await _startOperation;
    try {
      await _port.stopListening();
    } on Object catch (_) {}
  }

  Future<void> toggleMicrophone() async {
    if (!active) {
      await start();
      return;
    }
    if (_port.listening && !_port.speaking) {
      _microphonePaused = true;
      await _port.stopListening();
      return;
    }
    await interrupt();
  }

  Future<void> interrupt() {
    if (!active || _disposed) return Future.value();
    final pending = _interruptOperation;
    if (pending != null) return pending;
    final operation = _interrupt();
    _interruptOperation = operation;
    return operation.whenComplete(() {
      if (identical(_interruptOperation, operation)) _interruptOperation = null;
    });
  }

  Future<void> _interrupt() async {
    final generation = ++_generation;
    _acceptResponses = false;
    _turnTimeout?.cancel();
    _gate.reset();
    _dispatchGraceUntil = null;
    _microphonePaused = false;
    try {
      await _port.stopSpeaking();
    } on Object catch (error) {
      if (_current(generation)) _lastError = error.toString();
    }
    if (!_current(generation)) return;
    try {
      await _onStopGeneration();
    } on Object catch (error) {
      if (_current(generation)) _lastError = error.toString();
    }
    if (_current(generation)) await _listen();
  }

  Future<void> onResponseCompleted(String reply) async {
    if (!active ||
        !_acceptResponses ||
        _interruptOperation != null ||
        _phase == CallPhase.speaking) {
      return;
    }
    _acceptResponses = false;
    _turnTimeout?.cancel();
    if (reply.trim().isEmpty) {
      await _listen();
      return;
    }
    final generation = _generation;
    _setPhase(CallPhase.speaking);
    try {
      if (!acousticBargeIn && _port.listening) {
        await _port.stopListening();
      }
      if (!_current(generation)) return;
      await _port.speakToCompletion(reply);
    } on Object catch (error) {
      if (_current(generation)) _lastError = error.toString();
    }
    if (!_current(generation)) return;
    if (!acousticBargeIn || !_port.listening) {
      await Future<void>.delayed(settleDelay);
    }
    if (_current(generation)) await _listen();
  }

  void onResponseFailed() {
    if (!active ||
        _phase != CallPhase.thinking ||
        _interruptOperation != null) {
      return;
    }
    _acceptResponses = false;
    unawaited(_listen());
  }

  void _handleTranscript(String raw) {
    if (!active || _interruptOperation != null) return;
    final transcript = raw.trim();
    if (transcript.isEmpty || _port.isSelfEcho(transcript)) return;
    if (_phase == CallPhase.speaking && !acousticBargeIn) return;
    if (_phase == CallPhase.speaking || _phase == CallPhase.thinking) {
      final grace = _dispatchGraceUntil;
      if (_phase == CallPhase.thinking &&
          grace != null &&
          DateTime.now().isBefore(grace)) {
        return;
      }
      _bargeInCount++;
      unawaited(_interruptAndDispatch(transcript));
      return;
    }
    if (_busy || _microphonePaused || _phase != CallPhase.listening) return;
    unawaited(_dispatch(transcript));
  }

  void _handleFrameEnergy(double rms) {
    if (!acousticBargeIn || _interruptOperation != null) return;
    if (_phase != CallPhase.speaking && _phase != CallPhase.thinking) return;
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
    final generation = _generation + 1;
    await interrupt();
    if (!_current(generation) || _phase != CallPhase.listening) return;
    await _dispatch(transcript);
  }

  Future<void> _dispatch(String transcript) async {
    final generation = ++_generation;
    _busy = true;
    _acceptResponses = true;
    _dispatchGraceUntil = DateTime.now().add(const Duration(milliseconds: 900));
    _setPhase(CallPhase.thinking);
    _turnTimeout?.cancel();
    // onSend can await the entire generation, so arm before calling it.
    _turnTimeout = Timer(Duration(milliseconds: maximumTurnMilliseconds), () {
      if (_current(generation) && _phase == CallPhase.thinking) {
        unawaited(interrupt());
      }
    });
    try {
      await _onSend(transcript);
    } catch (error) {
      if (_current(generation)) _fail(error);
    }
  }

  Future<void> _listen() async {
    if (!active || _disposed) return;
    _turnTimeout?.cancel();
    _busy = false;
    _setPhase(CallPhase.listening);
    if (!_microphonePaused) await _ensureCapture(_generation);
  }

  Future<void> _ensureCapture(int generation) async {
    if (_openingCapture || _port.listening || !_current(generation)) return;
    _openingCapture = true;
    try {
      await _port.startListening();
      if (!_current(generation)) {
        // A stop during startup must not leave a newly opened microphone alive.
        if (!active) await _port.stopListening();
        return;
      }
      _gate.bindHardwareEchoCancellation(_port.echoCancellationVerified);
    } catch (error) {
      if (_current(generation)) _fail(error);
    } finally {
      _openingCapture = false;
    }
  }

  void _fail(Object error) {
    _lastError = error.toString();
    _busy = false;
    _acceptResponses = false;
    _turnTimeout?.cancel();
    _captureWatchdog?.cancel();
    _setPhase(CallPhase.halted);
  }

  void _setPhase(CallPhase value) {
    if (_disposed || _phase == value) return;
    _phase = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _turnTimeout?.cancel();
    _captureWatchdog?.cancel();
    _transcriptSubscription?.cancel();
    _energySubscription?.cancel();
    super.dispose();
  }
}
