import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/widgets/message_bubble.dart';

class _Harness extends StatefulWidget {
  const _Harness();

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  String content = '# title\n\nbody';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Column(
          children: [
            ElevatedButton(
              onPressed: () => setState(() {}),
              child: const Text('rebuild'),
            ),
            ElevatedButton(
              onPressed: () => setState(() => content = '## changed'),
              child: const Text('change'),
            ),
            MessageBubble(
              content: content,
              isUser: false,
              model: 'test',
              timestamp: 0,
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  testWidgets('completed Markdown is reused when only the parent rebuilds', (
    tester,
  ) async {
    MessageBubble.resetMarkdownBuildCount();
    await tester.pumpWidget(const _Harness());
    expect(MessageBubble.markdownBuildCount, 1);

    await tester.tap(find.text('rebuild'));
    await tester.pump();
    // Unchanged content must not construct a new Markdown tree.
    expect(MessageBubble.markdownBuildCount, 1);

    await tester.tap(find.text('change'));
    await tester.pump();
    expect(MessageBubble.markdownBuildCount, 2);
  });
}
