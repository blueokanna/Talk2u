import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/services/offline_llm_service.dart';
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

  testWidgets('the Qwen card lists both Qwen3-4B-Instruct-2507 identities', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final service = OfflineLlmService.instance;
    final previous = service.runtimeCapabilities;
    // No native answer yet: the built-in catalogue must still expose both
    // identities instead of silently showing only the abliterated derivative.
    service.runtimeCapabilities = const {};
    try {
      await tester.pumpWidget(
        _app(
          OnDeviceModelsSection(
            onDownloadQwenHub: (_) {},
            onInstallQwenArtifact: (_, _) {},
            onCancelQwenImport: () {},
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

      expect(find.text('Qwen3-4B-Instruct-2507'), findsOneWidget);
      expect(
        find.text('Huihui-Qwen3-4B-Instruct-2507-abliterated'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      service.runtimeCapabilities = previous;
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('model cards fit a 360 dp phone without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final service = OfflineLlmService.instance;
    final previous = service.runtimeCapabilities;
    service.runtimeCapabilities = const {};
    try {
      await tester.pumpWidget(
        _app(
          SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: OnDeviceModelsSection(
              onDownloadQwenHub: (_) {},
              onInstallQwenArtifact: (_, _) {},
              onCancelQwenImport: () {},
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
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
    } finally {
      service.runtimeCapabilities = previous;
      debugDefaultTargetPlatformOverride = null;
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
            onDownloadQwenHub: (_) {},
            onInstallQwenArtifact: (_, _) {},
            onCancelQwenImport: () {},
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
