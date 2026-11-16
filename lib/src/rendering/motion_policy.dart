import 'package:flutter/widgets.dart';

/// Shared motion decisions, not a second frame clock. Flutter tickers and native
/// renderers retain ownership of their own frames.
@immutable
class AppMotionPolicy {
  const AppMotionPolicy({this.active = true, this.reducedMotion = false});

  final bool active;
  final bool reducedMotion;
  bool get animate => active && !reducedMotion;
  Duration duration(Duration normal) => animate ? normal : Duration.zero;

  static AppMotionPolicy of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_MotionPolicyScope>();
    return AppMotionPolicy(
      active:
          (scope?.policy.active ?? true) &&
          TickerMode.valuesOf(context).enabled,
      reducedMotion:
          (scope?.policy.reducedMotion ?? false) ||
          MediaQuery.disableAnimationsOf(context),
    );
  }
}

/// Install below MaterialApp's MediaQuery, above its Navigator.
class AppMotionScope extends StatefulWidget {
  const AppMotionScope({required this.child, super.key});
  final Widget child;

  @override
  State<AppMotionScope> createState() => _AppMotionScopeState();
}

class _AppMotionScopeState extends State<AppMotionScope>
    with WidgetsBindingObserver {
  late bool _active;

  @override
  void initState() {
    super.initState();
    _active =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (_active != active) setState(() => _active = active);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _MotionPolicyScope(
    policy: AppMotionPolicy(
      active: _active,
      reducedMotion: MediaQuery.disableAnimationsOf(context),
    ),
    child: TickerMode(enabled: _active, child: widget.child),
  );
}

class _MotionPolicyScope extends InheritedWidget {
  const _MotionPolicyScope({required this.policy, required super.child});
  final AppMotionPolicy policy;

  @override
  bool updateShouldNotify(_MotionPolicyScope oldWidget) =>
      policy.active != oldWidget.policy.active ||
      policy.reducedMotion != oldWidget.policy.reducedMotion;
}
