import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/rust/api/data_models.dart';
import 'package:talk2u/src/state/chat_state.dart';
import 'package:talk2u/src/widgets/chat_message_area.dart';
import 'package:talk2u/src/widgets/message_bubble.dart';

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
  testWidgets('completed messages render as bubbles', (tester) async {
    final controller = ScrollController();
    final state = ChatState(
      readConversation: (id) async => Conversation(
        id: id,
        title: 'test',
        model: 'test',
        createdAt: 0,
        updatedAt: 0,
        dialogueStyle: DialogueStyle.mixed,
        turnCount: 1,
        memorySummaries: const [],
        messages: const [
          Message(
            id: 'm1',
            role: MessageRole.assistant,
            content: 'hello',
            model: 'test',
            timestamp: 0,
            messageType: MessageType.say,
          ),
        ],
      ),
    );
    try {
      await state.loadConversation('c1');
      await tester.pumpWidget(
        _app(
          ChatMessageArea(
            chatState: state,
            scrollController: controller,
            onChooseCharacter: () {},
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(MessageBubble), findsOneWidget);
    } finally {
      controller.dispose();
      state.dispose();
    }
  });
}
