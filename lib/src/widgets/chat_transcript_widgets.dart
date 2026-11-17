import 'package:flutter/material.dart';
import 'package:talk2u/src/rendering/motion_policy.dart';
import 'package:talk2u/src/theme/app_motion.dart';
import 'package:talk2u/src/theme/app_shapes.dart';

/// Entrance animation for a transcript row.
///
/// Kept out of the chat page so the page owns orchestration, not widget
/// animation internals. The curve and duration are the shared Material 3
/// entering tokens, so a row arrives with the same physics as a page.
class AnimatedMessageItem extends StatefulWidget {
  const AnimatedMessageItem({super.key, required this.child});

  final Widget child;

  @override
  State<AnimatedMessageItem> createState() => _AnimatedMessageItemState();
}

class _AnimatedMessageItemState extends State<AnimatedMessageItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.enter,
  );
  late final CurvedAnimation _progress = CurvedAnimation(
    parent: _controller,
    curve: AppMotion.emphasizedDecelerate,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.08),
    end: Offset.zero,
  ).animate(_progress);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotionPolicy.of(context).animate) {
      if (_controller.value < 1 && !_controller.isAnimating) {
        _controller.forward();
      }
    } else {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!AppMotionPolicy.of(context).animate) return widget.child;
    return FadeTransition(
      opacity: _progress,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

/// Three-dot "assistant is thinking" indicator.
///
/// The ticker stops when reduced motion is requested, so an idle transcript does
/// not keep a frame callback alive. The dots are painted in the pill role from
/// the shape scale, matching the bubble they preview.
class TypingDots extends StatefulWidget {
  const TypingDots({super.key});

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.emphasis,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotionPolicy.of(context).animate) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = 0.5;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      shape: AppShapes.pill,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (index) {
                final delay = index * 0.2;
                final t = (_controller.value - delay).clamp(0.0, 1.0);
                final scale = 0.5 + 0.5 * (1 - (2 * t - 1).abs());
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Transform.scale(
                    scale: scale,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: ShapeDecoration(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.4 + 0.6 * scale,
                        ),
                        shape: const CircleBorder(),
                      ),
                    ),
                  ),
                );
              }),
            );
          },
        ),
      ),
    );
  }
}
