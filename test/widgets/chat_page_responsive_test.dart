import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/pages/chat_page.dart';
import 'package:talk2u/src/state/chat_state.dart';

void main() {
  final devices = <String, ({Size size, double keyboard})>{
    'HUAWEI Mate 10 Pro': (size: const Size(360, 720), keyboard: 300),
    'OnePlus 15': (size: const Size(424, 924), keyboard: 360),
    'OnePlus 15T': (size: const Size(405, 880), keyboard: 340),
  };

  for (final entry in devices.entries) {
    testWidgets('${entry.key} keeps chat responsive with the keyboard open', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await tester.binding.setSurfaceSize(entry.value.size);
      final state = ChatState();
      try {
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: state,
            child: MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLocalizations.supportedLocales,
              home: MediaQuery(
                data: MediaQueryData(
                  size: entry.value.size,
                  devicePixelRatio: 1,
                  viewInsets: EdgeInsets.only(bottom: entry.value.keyboard),
                  textScaler: const TextScaler.linear(1.1),
                ),
                child: const ChatPage(),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(find.byTooltip('查看对话'));
        await tester.pump();
        await tester.enterText(
          find.byType(TextField),
          '第一行\n第二行\n第三行\n第四行\n第五行',
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.text('开始新的对话'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
        debugDefaultTargetPlatformOverride = null;
        await tester.binding.setSurfaceSize(null);
      }
    });
  }
}
