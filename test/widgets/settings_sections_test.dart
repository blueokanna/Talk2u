import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/state/chat_state.dart';
import 'package:talk2u/src/widgets/chat_execution_status.dart';
import 'package:talk2u/src/widgets/settings/on_device_models_section.dart';

/// An offline-provider state without touching the Rust bridge.
class _OfflineChatState extends ChatState {
  @override
  bool get usesAndroidOfflineProvider => true;
}

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
  testWidgets('execution status shows the offline LLM route', (tester) async {
    final state = _OfflineChatState();
    try {
      await tester.pumpWidget(
        _app(ChatExecutionStatus(chatState: state, session: null)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      // Not yet verified by a real generation, so the route must read pending.
      expect(find.byIcon(Icons.pending_outlined), findsOneWidget);
    } finally {
      state.dispose();
    }
  });

  testWidgets('model section is inert on unsupported platforms', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await tester.pumpWidget(
        _app(
          OnDeviceModelsSection(
            onDownloadQwen: () {},
            onCancelQwenDownload: () {},
            onDeleteQwen: () {},
            onImportSenseVoiceZip: () {},
            onDownloadSenseVoice: () {},
            onDeleteMoss: () {},
            onImportMossZip: () {},
            onImportMossDir: () {},
            onSelectMossVoice: (_) {},
            onPreviewMossVoice: () {},
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(ListTile), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
