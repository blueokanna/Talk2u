import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/rendering/motion_policy.dart';
import 'package:talk2u/src/theme/app_theme.dart';

void main() {
  testWidgets(
    'system reduced motion updates policy without disabling tickers',
    (tester) async {
      late AppMotionPolicy policy;
      late bool tickerEnabled;
      Widget app(bool reduced, {bool visible = true}) => MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: AppMotionScope(
          child: TickerMode(
            enabled: visible,
            child: Builder(
              builder: (context) {
                policy = AppMotionPolicy.of(context);
                tickerEnabled = TickerMode.valuesOf(context).enabled;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(false));
      expect(policy.animate, isTrue);
      expect(
        policy.duration(const Duration(milliseconds: 300)),
        const Duration(milliseconds: 300),
      );
      await tester.pumpWidget(app(true));
      expect(policy.reducedMotion, isTrue);
      expect(policy.animate, isFalse);
      expect(tickerEnabled, isTrue); // Finite controllers must still finish.
      expect(policy.duration(const Duration(milliseconds: 300)), Duration.zero);
      await tester.pumpWidget(app(false, visible: false));
      expect(policy.active, isFalse);
    },
  );

  testWidgets('background mutes tickers and resume restores policy', (
    tester,
  ) async {
    late AppMotionPolicy policy;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: AppMotionScope(
          child: Builder(
            builder: (context) {
              policy = AppMotionPolicy.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // A paused engine normally produces no frames; force one to inspect the
    // inherited policy after the observer's setState.
    tester.binding.scheduleForcedFrame();
    await tester.pump();
    expect(policy.active, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(policy.active, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'reduced motion route transition renders final child immediately',
    (tester) async {
      const child = Text('Destination');
      Widget? transition;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Builder(
              builder: (context) {
                transition = const MotionPageTransitionsBuilder()
                    .buildTransitions<void>(
                      MaterialPageRoute<void>(builder: (_) => child),
                      context,
                      const AlwaysStoppedAnimation(0),
                      const AlwaysStoppedAnimation(0),
                      child,
                    );
                return transition!;
              },
            ),
          ),
        ),
      );
      expect(identical(transition, child), isTrue);
      expect(find.text('Destination'), findsOneWidget);
    },
  );
}
