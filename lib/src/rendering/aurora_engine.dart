import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:talk2u/src/rendering/motion_policy.dart';

/// One frame clock for every ambient effect in the application.
///
/// The app has several "always alive" surfaces: the aurora field, the hero glow
/// and the idle avatar sheen. Giving each of them its own `AnimationController`
/// would schedule one ticker per effect, and Flutter would then run one callback
/// and one repaint per effect per frame. Instead, [AuroraEngine] owns a single
/// [Ticker] and publishes its phase through [AuroraClock]; every ambient widget
/// listens to that one notifier inside its own [RepaintBoundary]. The result is
/// one scheduling decision and one clock read per frame for the whole app.
///
/// The clock notifies at 30 Hz rather than 60. A 20–30 second drift does not
/// need 60 samples per second, and halving the notifications halves the repaint
/// work of the ambient layer without a visible change.
///
/// The engine stops itself when:
///
/// * the user asked for reduced motion (`MediaQuery.disableAnimations`), leaving
///   the field parked on a deterministic frame;
/// * the application is not resumed, because [AppMotionScope] mutes the ticker;
/// * no widget listens to the clock, because the ticker is only started once the
///   inherited scope is read.
class AuroraEngine extends StatefulWidget {
  const AuroraEngine({
    super.key,
    required this.child,
    this.period = const Duration(seconds: 28),
  });

  final Widget child;

  /// One full drift cycle. Ambient motion is intentionally slow.
  final Duration period;

  /// The nearest clock. Throws a descriptive error when the engine is missing,
  /// because silently creating a second clock would defeat the whole point.
  static AuroraClock of(BuildContext context) {
    final clock = maybeOf(context);
    if (clock == null) {
      throw FlutterError(
        'AuroraEngine.of() was called without an AuroraEngine above it.\n'
        'Wrap the application (or the subtree that needs ambient motion) in '
        'AuroraEngine, next to AppMotionScope.',
      );
    }
    return clock;
  }

  /// The nearest clock, or null when the subtree does not want one.
  ///
  /// A caller that renders a static preview can use this to fall back to a
  /// composed frame instead of throwing.
  static AuroraClock? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<_AuroraScope>()?.clock;
  }

  @override
  State<AuroraEngine> createState() => _AuroraEngineState();
}

class _AuroraEngineState extends State<AuroraEngine>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_handleTick);
  late final AuroraClock _clock = AuroraClock(period: widget.period);

  /// Phase the clock had when the current ticker run started. Re-basing on
  /// every start keeps the field continuous across pause/resume instead of
  /// jumping by however long the app was backgrounded.
  double _phaseAtStart = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  void _sync() {
    final animate = AppMotionPolicy.of(context).animate;
    if (animate) {
      if (!_ticker.isActive) {
        _phaseAtStart = _clock.seconds;
        _ticker.start();
      }
      _clock.running = true;
    } else {
      if (_ticker.isActive) _ticker.stop();
      _clock.running = false;
      _clock.park();
    }
  }

  void _handleTick(Duration elapsed) {
    final seconds =
        _phaseAtStart + elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    _clock.advance(seconds);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _AuroraScope(clock: _clock, child: widget.child);
}

/// The shared ambient phase, in seconds and in turns.
///
/// It is a [ChangeNotifier] so a [CustomPainter] can use it directly as its
/// `repaint` argument: the painter then skips the widget rebuild entirely and
/// only repaints its own layer.
class AuroraClock extends ChangeNotifier {
  AuroraClock({required this.period})
    : _periodSeconds = period.inMicroseconds / Duration.microsecondsPerSecond;

  final Duration period;
  final double _periodSeconds;

  double _seconds = 0;
  double _lastNotified = -1;
  bool _running = false;

  /// Seconds elapsed inside the current cycle: `0 <= seconds < period`.
  double get seconds => _seconds;

  /// Position inside the cycle as `0..1`.
  double get turns => _periodSeconds <= 0 ? 0 : _seconds / _periodSeconds;

  /// Position inside the cycle in radians, for painters.
  double get phase => turns * 6.283185307179586;

  bool get running => _running;

  set running(bool value) {
    if (_running == value) return;
    _running = value;
    // Do not notify: the phase, not the run flag, is what ambient painters
    // consume, and a paused field must not repaint just to record the flag.
  }

  void advance(double seconds) {
    _seconds = _periodSeconds <= 0 ? 0 : seconds % _periodSeconds;
    if (_seconds < 0) _seconds += _periodSeconds;
    // 30 Hz. The first sample and a wrapped phase always notify.
    if (_lastNotified < 0 ||
        _seconds < _lastNotified ||
        _seconds - _lastNotified >= 1 / 30) {
      _lastNotified = _seconds;
      notifyListeners();
    }
  }

  /// Parks on a composed frame. Used for reduced motion, so a static screenshot
  /// looks intentional rather than random.
  void park() {
    _seconds = _periodSeconds * 0.3;
    _lastNotified = _seconds;
    notifyListeners();
  }

  @override
  void dispose() {
    _running = false;
    super.dispose();
  }
}

class _AuroraScope extends InheritedWidget {
  const _AuroraScope({required this.clock, required super.child});

  final AuroraClock clock;

  @override
  bool updateShouldNotify(_AuroraScope oldWidget) => clock != oldWidget.clock;
}
