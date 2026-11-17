import 'package:flutter/material.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/rendering/motion_policy.dart';
import 'package:talk2u/src/theme/app_motion.dart';
import 'package:talk2u/src/theme/app_shapes.dart';

/// The collapsible reasoning panel attached to an assistant message.
///
/// Built on Material 3 Expressive's [Expansible], which is the framework's
/// replacement for hand-rolled `AnimatedCrossFade` panels: the header and body
/// are one widget, the body's height animates on a single controller, and the
/// expanded state is owned by the controller rather than duplicated in a `bool`
/// beside it.
///
/// The panel opens automatically while the model is still streaming reasoning,
/// then stays open until the reader collapses it. That mirrors what the
/// transcript expects: reasoning arrives before the answer, so it must be
/// visible without a tap, and a dismissed panel must not keep re-opening on
/// every token.
class ThinkingSection extends StatefulWidget {
  const ThinkingSection({
    super.key,
    required this.content,
    this.isStreaming = false,
  });

  final String content;
  final bool isStreaming;

  @override
  State<ThinkingSection> createState() => _ThinkingSectionState();
}

class _ThinkingSectionState extends State<ThinkingSection> {
  final ExpansibleController _controller = ExpansibleController();

  @override
  void initState() {
    super.initState();
    // `Expansible` reads the controller's initial state when it mounts, so the
    // panel can start open without playing an entrance animation.
    if (widget.isStreaming) _controller.expand();
  }

  @override
  void didUpdateWidget(ThinkingSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isStreaming && !oldWidget.isStreaming) _controller.expand();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.content.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final animate = AppMotionPolicy.of(context).animate;
    final shape = AppShapes.field.copyWith(
      side: BorderSide(
        color: theme.colorScheme.tertiary.withValues(alpha: 0.25),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 12, bottom: 6),
      child: Material(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.35),
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: Expansible(
          controller: _controller,
          animationStyle: animate
              ? const AnimationStyle(
                  duration: AppMotion.resize,
                  curve: AppMotion.standardDecelerate,
                  reverseCurve: AppMotion.standardAccelerate,
                )
              : AnimationStyle.noAnimation,
          headerBuilder: (context, animation) =>
              _Header(controller: _controller, isStreaming: widget.isStreaming),
          bodyBuilder: (context, animation) => Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SelectableText(
              widget.content,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
                height: 1.6,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller, required this.isStreaming});

  final ExpansibleController controller;
  final bool isStreaming;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = AppLocalizations.of(context);
    final animate = AppMotionPolicy.of(context).animate;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final expanded = controller.isExpanded;
        return InkWell(
          onTap: controller.toggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  Icons.psychology_rounded,
                  size: 18,
                  color: theme.colorScheme.tertiary,
                ),
                const SizedBox(width: 8),
                Text(
                  strings.thinkingProcess,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
                if (isStreaming) ...[
                  const SizedBox(width: 8),
                  SizedBox.square(
                    dimension: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.tertiary,
                    ),
                  ),
                ],
                const Spacer(),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: animate ? AppMotion.tap : Duration.zero,
                  curve: AppMotion.standardDecelerate,
                  child: Icon(
                    Icons.expand_more_rounded,
                    size: 20,
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
