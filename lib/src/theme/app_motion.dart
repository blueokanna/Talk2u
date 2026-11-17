import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:talk2u/src/rendering/motion_policy.dart';

/// Material 3 motion, expressed once for the whole application.
///
/// Flutter 3.47 exports the generated Material motion tokens
/// (`package:flutter/material.dart` re-exports `src/material/motion.dart`), so
/// this class references [Durations] and [Easing] instead of restating their
/// numbers. Two consequences matter:
///
/// * a token the framework retunes in a future release moves with the SDK;
/// * any screen that needs a duration or a curve has exactly one place to look,
///   which is what makes unrelated screens feel like one system.
///
/// The names are semantic rather than numeric so a call site reads as intent:
/// `AppMotion.tap`, not `200 milliseconds`.
abstract final class AppMotion {
  // --------------------------------------------------------------- durations

  /// 100 ms — an icon or a label changing state in place.
  static const Duration micro = Durations.short2;

  /// 150 ms — a small element entering or leaving.
  static const Duration small = Durations.short3;

  /// 200 ms — the default tap response.
  static const Duration tap = Durations.short4;

  /// 250 ms — a card or a sheet resizing.
  static const Duration resize = Durations.medium1;

  /// 300 ms — a control swapping its content.
  static const Duration swap = Durations.medium2;

  /// 350 ms — a list row arriving.
  static const Duration enter = Durations.medium3;

  /// 400 ms — a large surface arriving, and the page transition forward.
  static const Duration page = Durations.medium4;

  /// 500 ms — an emphasis transition that still has to stay readable.
  static const Duration emphasis = Durations.long2;

  /// 1000 ms — a transient confirmation (a copied-to-clipboard snackbar) that
  /// must not outlive the user's attention.
  static const Duration transient = Durations.extralong4;

  // ------------------------------------------------------------------ easing

  /// Content entering the screen: fast start, long settle.
  static const Curve emphasizedDecelerate = Easing.emphasizedDecelerate;

  /// Content leaving the screen: slow start, decisive exit.
  static const Curve emphasizedAccelerate = Easing.emphasizedAccelerate;

  /// Symmetric, for anything returning to its resting position.
  static const Curve standard = Easing.standard;

  /// In-place state change that accelerates.
  static const Curve standardAccelerate = Easing.standardAccelerate;

  /// In-place state change that decelerates.
  static const Curve standardDecelerate = Easing.standardDecelerate;

  // ------------------------------------------------------------------ springs

  /// A damped spring with the ratio Material 3 Expressive describes for spatial
  /// transitions: mass 1, stiffness 1400, damping 64, i.e. a damping ratio of
  /// about 0.86.
  ///
  /// Flutter does not ship named spring tokens, so this is the app's encoding of
  /// that family, not an invented constant: any value in this band produces the
  /// same barely-overshooting settle. [springTo] is the only supported way to
  /// run it, which keeps every spring in the app identical.
  static const SpringDescription expressiveSpring = SpringDescription(
    mass: 1,
    stiffness: 1400,
    damping: 64,
  );

  /// Drives [controller] to [target] with [expressiveSpring].
  ///
  /// Callers must skip this when [AppMotionPolicy.animate] is false; a spring
  /// has no meaningful "reduced" form, so the correct reduced-motion result is
  /// the final value, not a faster spring.
  static TickerFuture springTo(AnimationController controller, double target) {
    return controller.animateWith(
      SpringSimulation(
        expressiveSpring,
        controller.value,
        target,
        controller.velocity,
      ),
    );
  }

  /// Collapses [duration] to zero when the user asked for reduced motion.
  static Duration of(BuildContext context, Duration duration) =>
      AppMotionPolicy.of(context).duration(duration);
}

/// Page transition that carries the outgoing and incoming screens together.
///
/// This is the shared-axis idea Material 3 Expressive describes, composed from
/// the route's own animations: the incoming screen rises a few percent while it
/// fades in, and the outgoing screen recedes by a smaller amount instead of
/// being cut away. Both halves run on the same emphasized tokens, which is why
/// two sibling routes read as one movement.
///
/// It deliberately stays close to Flutter's own `FadeForwardsPageTransitionsBuilder`
/// (the Android U contract) and adds only the depth cue, so system back gestures
/// and predictive back still line up. Sized at [AppMotion.page] forward and
/// [AppMotion.swap] back, matching the Material page durations.
class FluidPageTransitionsBuilder extends PageTransitionsBuilder {
  const FluidPageTransitionsBuilder({this.axis = Axis.vertical});

  /// Direction the incoming screen travels along.
  final Axis axis;

  @override
  Duration get transitionDuration => AppMotion.page;

  @override
  Duration get reverseTransitionDuration => AppMotion.swap;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // The test suite asserts this exact identity: reduced motion must render the
    // destination immediately, not a zero-length transition that still mounts a
    // second layer.
    if (!AppMotionPolicy.of(context).animate) return child;
    return _FluidTransition(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      axis: axis,
      child: child,
    );
  }
}

class _FluidTransition extends StatefulWidget {
  const _FluidTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.axis,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Axis axis;
  final Widget child;

  @override
  State<_FluidTransition> createState() => _FluidTransitionState();
}

class _FluidTransitionState extends State<_FluidTransition> {
  late final CurvedAnimation _incoming = CurvedAnimation(
    parent: widget.animation,
    curve: AppMotion.emphasizedDecelerate,
    reverseCurve: AppMotion.emphasizedAccelerate,
  );
  late final CurvedAnimation _outgoing = CurvedAnimation(
    parent: widget.secondaryAnimation,
    curve: AppMotion.emphasizedAccelerate,
    reverseCurve: AppMotion.emphasizedDecelerate,
  );

  @override
  void dispose() {
    _incoming.dispose();
    _outgoing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_incoming, _outgoing]),
      // The subtree is passed through untouched: only the transform and the
      // opacity layer are recomputed per frame, never the page itself.
      child: widget.child,
      builder: (context, child) {
        final entering = _incoming.value;
        final leaving = _outgoing.value;
        // The entering route is opaque from its first frame. Fading it in would
        // multiply the whole incoming page (background included) by 0 and let
        // the previous route's Live2D platform view show through the new page
        // during the transition. Only the covered route fades, and it is already
        // behind an opaque page.
        final opacity = (1 - 0.25 * leaving).clamp(0.0, 1.0);
        // 0.985 → 1 while entering, 1 → 0.992 while being covered. A larger
        // zoom on a full screen reads as a jump rather than as depth.
        final scale = (0.985 + 0.015 * entering) * (1 - 0.008 * leaving);
        final size = MediaQuery.sizeOf(context);
        final vertical = widget.axis == Axis.vertical;
        // Entering travels +3.5 %, the covered route recedes −2 %. Keeping both
        // signs in one expression is what makes the pair read as one shared
        // axis instead of two independent fades.
        final travel = 0.035 * (1 - entering) * (1 - leaving) - 0.02 * leaving;
        return Opacity(
          opacity: opacity,
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..scaleByDouble(scale, scale, 1, 1)
              ..translateByDouble(
                vertical ? 0 : size.width * travel,
                vertical ? size.height * travel : 0,
                0,
                1,
              ),
            child: child,
          ),
        );
      },
    );
  }
}
