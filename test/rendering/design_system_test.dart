import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/rendering/aurora_engine.dart';
import 'package:talk2u/src/rendering/motion_policy.dart';
import 'package:talk2u/src/settings/ui_preferences.dart';
import 'package:talk2u/src/theme/app_theme.dart';
import 'package:talk2u/src/widgets/aurora_backdrop.dart';
import 'package:talk2u/src/widgets/fluid_switcher.dart';

Widget _wrapped(Widget child, {bool reducedMotion = false}) => MediaQuery(
  data: MediaQueryData(disableAnimations: reducedMotion),
  child: AppMotionScope(
    child: Directionality(textDirection: TextDirection.ltr, child: child),
  ),
);

void main() {
  test('Latin uses Google Sans and CJK falls back to HarmonyOS Sans', () {
    final theme = AppTheme.build(Brightness.light, AppColorTheme.teal);
    // `ThemeData` has no public `fontFamily` getter, so the top-level family is
    // observed through the derived text themes it seeds.
    for (final style in [
      theme.textTheme.bodyMedium!,
      theme.textTheme.titleLarge!,
      theme.primaryTextTheme.bodyMedium!,
    ]) {
      expect(style.fontFamily, 'Google Sans');
      expect(style.fontFamilyFallback?.first, 'HarmonyOS Sans SC');
      expect(style.fontFamilyFallback, contains('sans-serif'));
    }
  });

  test('shape roles share the Material 3 radius scale', () {
    expect(AppShapes.extraSmall, 4);
    expect(AppShapes.small, 8);
    expect(AppShapes.medium, 12);
    expect(AppShapes.large, 16);
    expect(AppShapes.extraLarge, 28);

    final surface = AppShapes.surface as RoundedSuperellipseBorder;
    expect(
      surface.borderRadius,
      const BorderRadius.all(AppShapes.radiusExtraLarge),
    );
    expect(AppShapes.pill, isA<StadiumBorder>());

    // The bubble tail collapses on the sender's side only.
    final mine = AppShapes.bubbleRadius(mine: true);
    expect(mine.bottomRight, AppShapes.radiusSmall);
    expect(mine.bottomLeft, AppShapes.radiusExtraLarge);
    final theirs = AppShapes.bubbleRadius(mine: false);
    expect(theirs.bottomLeft, AppShapes.radiusSmall);
    expect(theirs.bottomRight, AppShapes.radiusExtraLarge);
  });

  testWidgets('the ambient clock parks under reduced motion', (tester) async {
    late AuroraClock clock;
    Widget app(bool reduced) => _wrapped(
      AuroraEngine(
        child: Builder(
          builder: (context) {
            clock = AuroraEngine.of(context);
            return const SizedBox();
          },
        ),
      ),
      reducedMotion: reduced,
    );

    await tester.pumpWidget(app(true));
    expect(clock.running, isFalse);
    // Parked on a composed frame, not on zero.
    expect(clock.turns, closeTo(0.3, 0.0001));

    await tester.pumpWidget(app(false));
    expect(clock.running, isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the ambient clock notifies at most 30 times per second', (
    tester,
  ) async {
    final clock = AuroraClock(period: const Duration(seconds: 28));
    addTearDown(clock.dispose);
    var notifications = 0;
    clock.addListener(() => notifications++);

    // 60 samples over one second: a naive notifier would fire 60 times.
    for (var frame = 0; frame < 60; frame++) {
      clock.advance((frame + 1) / 60);
    }
    expect(notifications, lessThanOrEqualTo(31));
    expect(clock.turns, closeTo(1 / 28, 0.0001));
  });

  testWidgets('the aurora backdrop paints and disposes without a clock', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: AuroraBackdrop(child: SizedBox.expand())),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'fluid switcher renders no transition layer under reduced motion',
    (tester) async {
      await tester.pumpWidget(
        _wrapped(
          FluidSwitcher(
            child: const SizedBox(key: ValueKey(1), width: 10, height: 10),
          ),
          reducedMotion: true,
        ),
      );
      await tester.pumpWidget(
        _wrapped(
          FluidSwitcher(
            child: const SizedBox(key: ValueKey(2), width: 10, height: 10),
          ),
          reducedMotion: true,
        ),
      );
      await tester.pump();
      expect(find.byType(Opacity), findsNothing);
    },
  );

  testWidgets('the entering route is opaque from its first frame', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      _wrapped(
        MaterialApp(
          navigatorKey: navigator,
          theme: ThemeData(
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {TargetPlatform.android: FluidPageTransitionsBuilder()},
            ),
          ),
          home: const Scaffold(body: Text('chat')),
        ),
      ),
    );

    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('settings')),
      ),
    );
    await tester.pump();
    await tester.pump();

    // The previous route's Live2D platform view must not be able to show
    // through the entering page's background. Fading the whole route from 0
    // was exactly that bug.
    Opacity enteringOpacity() => tester.widget<Opacity>(
      find
          .ancestor(of: find.text('settings'), matching: find.byType(Opacity))
          .first,
    );
    expect(enteringOpacity().opacity, 1.0);
    await tester.pump(const Duration(milliseconds: 100));
    expect(enteringOpacity().opacity, 1.0);
    await tester.pumpAndSettle();
  });

  testWidgets('fluid switcher keeps both children during a shared-axis swap', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrapped(
        FluidSwitcher(
          child: const SizedBox(key: ValueKey(1), width: 10, height: 10),
        ),
      ),
    );
    await tester.pumpWidget(
      _wrapped(
        FluidSwitcher(
          child: const SizedBox(key: ValueKey(2), width: 10, height: 10),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(Opacity), findsNWidgets(2));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(find.byType(Opacity), findsNothing);
    await tester.pumpAndSettle();
  });
}
