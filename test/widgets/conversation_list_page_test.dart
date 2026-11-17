import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/pages/conversation_list_page.dart';
import 'package:talk2u/src/rust/api/data_models.dart';

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
  testWidgets('conversation drawer fits a 304 dp drawer and selects a row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(304, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    String? selected;
    final now = DateTime.now().millisecondsSinceEpoch;
    await tester.pumpWidget(
      _app(
        SizedBox(
          width: 304,
          child: ConversationListPage(
            conversations: [
              ConversationSummary(
                id: 'c1',
                title: '一个很长很长的会话标题用来验证省略',
                lastMessagePreview: '上一条消息的预览文本',
                model: 'test',
                updatedAt: now,
              ),
              ConversationSummary(
                id: 'c2',
                title: 'Second',
                lastMessagePreview: '',
                model: 'test',
                updatedAt: now - 3600000,
              ),
            ],
            currentConversationId: 'c2',
            onNewConversation: () {},
            onSelectConversation: (id) => selected = id,
            onDeleteConversation: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Second'));
    expect(selected, 'c2');
  });
}
