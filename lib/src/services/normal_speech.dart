import 'package:talk2u/src/services/call_session.dart';

/// Owns the normal-chat streaming TTS handle.
///
/// Call mode has a microphone state machine around its speech; normal chat does
/// not. This class keeps the shared part in one place: start on the first delta
/// when auto-read is enabled, keep the same sink for the rest of the reply, and
/// close it exactly once.
class NormalReplySpeech {
  NormalReplySpeech({
    required StreamingReplySpeech Function() create,
    required bool Function() autoRead,
  }) : _create = create,
       _autoRead = autoRead;

  final StreamingReplySpeech Function() _create;
  final bool Function() _autoRead;
  StreamingReplySpeech? _active;
  StreamingReplySpeech? _finishing;

  bool get active => _active != null || _finishing != null;

  /// Feeds one model delta. Starts the sink when the user enabled auto-read and
  /// the TTS runtime is ready; otherwise this is a no-op.
  void append(String delta) {
    if (delta.isEmpty) return;
    final current = _active;
    if (current != null) {
      current.append(delta);
      return;
    }
    // A reply that is already finishing cannot accept more text.
    if (_finishing != null) return;
    if (!_autoRead()) return;
    final created = _create();
    _active = created;
    created.append(delta);
  }

  /// Starts the sink from the current partial text when the speaker button is
  /// pressed during generation.
  void startManual(String initial) {
    final current = _active;
    if (current != null) {
      if (initial.isNotEmpty) current.append(initial);
      return;
    }
    if (_finishing != null) return;
    final created = _create();
    _active = created;
    if (initial.isNotEmpty) created.append(initial);
  }

  /// Closes the sink and lets the final playback drain.
  Future<void> finish(String fullReply) async {
    final current = _active;
    if (current == null) return;
    _active = null;
    _finishing = current;
    try {
      await current.finish(fullReply);
    } finally {
      if (identical(_finishing, current)) _finishing = null;
    }
  }

  /// Stops playback immediately (new turn, user stop, page disposal).
  Future<void> cancel() async {
    final current = _active ?? _finishing;
    _active = null;
    _finishing = null;
    if (current == null) return;
    await current.cancel();
  }
}
