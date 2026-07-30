import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/rust/api/chat_api.dart' as rust_api;
import 'package:talk2u/src/rust/frb_generated.dart';
import 'package:talk2u/src/state/chat_state.dart';
import 'package:talk2u/src/theme/app_theme.dart';
import 'package:talk2u/src/pages/chat_page.dart';
import 'package:talk2u/src/services/offline_llm_service.dart';
import 'package:talk2u/src/services/offline_speech_service.dart';
import 'package:talk2u/src/services/accelerator_telemetry_service.dart';
import 'package:talk2u/src/settings/ui_preferences.dart';

enum _StartupFailure { rustCoreTimeout, localDataTimeout }

final class _StartupException implements Exception {
  const _StartupException(this.failure);

  final _StartupFailure failure;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await UiPreferences.load();
  runApp(Talk2UApp(preferences: preferences));
}

class Talk2UApp extends StatelessWidget {
  const Talk2UApp({required this.preferences, super.key});

  final UiPreferences preferences;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: preferences),
        ChangeNotifierProvider(create: (_) => ChatState()),
      ],
      child: Consumer<UiPreferences>(
        builder: (context, preferences, _) => MaterialApp(
          onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
          debugShowCheckedModeBanner: false,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          locale: preferences.locale,
          theme: AppTheme.build(Brightness.light, preferences.colorTheme),
          darkTheme: AppTheme.build(Brightness.dark, preferences.colorTheme),
          themeMode: preferences.themeMode,
          themeAnimationDuration: const Duration(milliseconds: 300),
          themeAnimationCurve: Curves.easeInOutCubicEmphasized,
          home: const _StartupGate(),
        ),
      ),
    );
  }
}

class _StartupGate extends StatefulWidget {
  const _StartupGate();

  @override
  State<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<_StartupGate> {
  late Future<void> _startup;

  @override
  void initState() {
    super.initState();
    _startup = _initialize();
  }

  Future<void> _initialize() async {
    await RustLib.init().timeout(
      const Duration(seconds: 20),
      onTimeout: () =>
          throw const _StartupException(_StartupFailure.rustCoreTimeout),
    );
    final appDir = await getApplicationDocumentsDirectory().timeout(
      const Duration(seconds: 10),
    );
    await rust_api
        .initApp(dataPath: appDir.path)
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () =>
              throw const _StartupException(_StartupFailure.localDataTimeout),
        );

    unawaited(
      OfflineSpeechService.instance.initialize().timeout(
        const Duration(seconds: 8),
        onTimeout: () {},
      ),
    );
    unawaited(OfflineLlmService.instance.initialize());
    AcceleratorTelemetryService.instance.start();
  }

  void _retry() {
    setState(() => _startup = _initialize());
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _startup,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.done &&
          snapshot.error == null) {
        return const ChatPage();
      }

      final theme = Theme.of(context);
      final strings = AppLocalizations.of(context);
      final errorDescription = switch (snapshot.error) {
        _StartupException(:final failure) => switch (failure) {
          _StartupFailure.rustCoreTimeout => strings.rustCoreTimeout,
          _StartupFailure.localDataTimeout => strings.localDataTimeout,
        },
        final error => '$error',
      };
      return Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: theme.colorScheme.surface,
              child: snapshot.hasError
                  ? const SizedBox.shrink()
                  : const Center(child: CircularProgressIndicator()),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                minimum: const EdgeInsets.all(16),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  color: theme.colorScheme.surface.withValues(alpha: 0.92),
                  child: snapshot.hasError
                      ? Row(
                          children: [
                            Expanded(
                              child: Text(
                                strings.startupFailed(errorDescription),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              tooltip: strings.retry,
                              onPressed: _retry,
                              icon: const Icon(Icons.refresh),
                            ),
                          ],
                        )
                      : Row(
                          children: [
                            const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 12),
                            Text(strings.startupPreparing),
                          ],
                        ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
