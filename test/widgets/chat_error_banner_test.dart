import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/widgets/chat_error_banner.dart';

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  testWidgets('retry is only offered when the error is actionable', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        ChatErrorBanner(
          message: 'network down',
          canRetry: false,
          onRetry: () {},
          onDismiss: () {},
        ),
      ),
    );
    expect(find.text('network down'), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsNothing);
  });

  testWidgets('retry and dismiss callbacks fire', (tester) async {
    var retried = 0;
    var dismissed = 0;
    await tester.pumpWidget(
      _app(
        ChatErrorBanner(
          message: 'network down',
          canRetry: true,
          onRetry: () => retried++,
          onDismiss: () => dismissed++,
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(retried, 1);
    expect(dismissed, 1);
  });
}
