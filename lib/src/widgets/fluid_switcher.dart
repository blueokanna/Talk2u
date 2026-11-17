import 'package:flutter/material.dart';
import 'package:talk2u/src/rendering/motion_policy.dart';
import 'package:talk2u/src/theme/app_motion.dart';

/// A shared-axis replacement for [AnimatedSwitcher].
///
/// Material 3 Expressive describes transitions where the outgoing and incoming
/// content are one continuous movement rather than two cross-fades. This widget
/// implements that: the incoming child arrives from [axis] while fading in and
/// settling from 98 % scale, and the outgoing child leaves along the same axis,
/// so the eye follows a single line through the swap.
///
/// The child **must** carry a key that changes when the content changes; without
/// one there is no reliable identity to diff, and the switcher returns the child
/// unchanged instead of guessing.
///
/// Reduced motion returns the child directly — no animation layer, no second
/// mounted subtree. The controller is single per instance and disposed with the
/// state, so a page with four switchers still schedules one ticker per switcher
/// only while a transition is running.
class FluidSwitcher extends StatefulWidget {
  const FluidSwitcher({
    super.key,
    required this.child,
    this.axis = Axis.vertical,
    this.alignment = Alignment.center,
  });

  final Widget child;

  /// Axis along which the outgoing and incoming content travel.
  final Axis axis;

  /// Alignment used to stack the two children.
  final AlignmentGeometry alignment;

  @override
  State<FluidSwitcher> createState() => _FluidSwitcherState();
}

class _FluidSwitcherState extends State<FluidSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.swap,
    value: 1,
  );

  Widget? _previous;
  int _generation = 0;

  @override
  void didUpdateWidget(FluidSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isReplacement(oldWidget.child, widget.child)) return;
    if (!AppMotionPolicy.of(context).animate) {
      _previous = null;
      _generation++;
      _controller.value = 1;
      return;
    }
    final generation = ++_generation;
    _previous = oldWidget.child;
    _controller.forward(from: 0).whenComplete(() {
      // A replacement that arrives mid-flight starts a newer generation; its
      // transition must keep its own outgoing child, so only the newest
      // generation is allowed to clear it.
      if (!mounted || generation != _generation) return;
      setState(() => _previous = null);
    });
  }

  static bool _isReplacement(Widget previous, Widget next) {
    if (identical(previous, next)) return false;
    final a = previous.key;
    final b = next.key;
    if (a != null || b != null) return a != b;
    return previous.runtimeType != next.runtimeType;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!AppMotionPolicy.of(context).animate) return widget.child;
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final progress = _controller.value;
        if (progress >= 1 || _previous == null) return child!;
        final entering = AppMotion.emphasizedDecelerate.transform(progress);
        final leaving = AppMotion.emphasizedAccelerate.transform(progress);
        final horizontal = widget.axis == Axis.horizontal;
        final travel = horizontal ? 0.06 : 0.04;
        final offset = MediaQuery.sizeOf(context);
        return Stack(
          alignment: widget.alignment,
          clipBehavior: Clip.hardEdge,
          fit: StackFit.passthrough,
          children: [
            IgnorePointer(
              child: Opacity(
                opacity: (1 - leaving).clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset(
                    horizontal ? offset.width * travel * leaving : 0,
                    horizontal ? 0 : offset.height * travel * leaving,
                  ),
                  child: Transform.scale(
                    scale: 1 - 0.01 * leaving,
                    child: _previous,
                  ),
                ),
              ),
            ),
            Opacity(
              opacity: entering,
              child: Transform.translate(
                offset: Offset(
                  horizontal ? -offset.width * travel * (1 - entering) : 0,
                  horizontal ? 0 : -offset.height * travel * (1 - entering),
                ),
                child: Transform.scale(
                  scale: 0.98 + 0.02 * entering,
                  child: child,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
