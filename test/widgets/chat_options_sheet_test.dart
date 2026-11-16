import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/rust/api/data_models.dart';
import 'package:talk2u/src/state/chat_state.dart';
import 'package:talk2u/src/widgets/chat_options_sheet.dart';

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
  testWidgets('dialogue style changes apply without closing the sheet', (
    tester,
  ) async {
    final state = ChatState();
    try {
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showChatOptionsSheet(
                  context,
                  chatState: state,
                  onRestartStory: () {},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(ChoiceChip), findsNWidgets(4));
      // Order: free, sayOnly, doOnly, mixed.
      await tester.tap(find.byType(ChoiceChip).at(2));
      await tester.pump();

      expect(state.dialogueStyle, DialogueStyle.doOnly);
      // A benign selection must not dismiss the sheet.
      expect(find.byType(ChoiceChip), findsNWidgets(4));
    } finally {
      state.dispose();
    }
  });

  testWidgets('restart action closes the sheet before invoking the callback', (
    tester,
  ) async {
    final state = ChatState();
    var restarted = false;
    try {
      // A conversation id is required for the restart row to render.
      state.setCurrentConversationIdForTest('conv-1');
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showChatOptionsSheet(
                  context,
                  chatState: state,
                  onRestartStory: () => restarted = true,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ListTile).first);
      await tester.pumpAndSettle();

      expect(restarted, isTrue);
      expect(find.byType(ChoiceChip), findsNothing);
    } finally {
      state.dispose();
    }
  });
}
