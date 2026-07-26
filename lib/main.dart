import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:talk2u/src/rust/api/chat_api.dart' as rust_api;
import 'package:talk2u/src/rust/frb_generated.dart';
import 'package:talk2u/src/state/chat_state.dart';
import 'package:talk2u/src/pages/chat_page.dart';
import 'package:talk2u/src/services/offline_llm_service.dart';
import 'package:talk2u/src/services/offline_speech_service.dart';
import 'package:talk2u/src/widgets/live2d_avatar.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Talk2UApp());
}

class Talk2UApp extends StatelessWidget {
  const Talk2UApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ChatState(),
      child: MaterialApp(
        title: 'Talk2U',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF6750A4),
          useMaterial3: true,
          brightness: Brightness.light,
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: CupertinoPageTransitionsBuilder(),
              TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            },
          ),
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF6750A4),
          useMaterial3: true,
          brightness: Brightness.dark,
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: CupertinoPageTransitionsBuilder(),
              TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            },
          ),
        ),
        themeMode: ThemeMode.system,
        home: const _StartupGate(),
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
      onTimeout: () => throw TimeoutException('Rust 核心加载超时'),
    );
    final appDir = await getApplicationDocumentsDirectory().timeout(
      const Duration(seconds: 10),
    );
    await rust_api
        .initApp(dataPath: appDir.path)
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw TimeoutException('本地数据初始化超时'),
        );

    // Optional device capabilities must never hold the first Flutter frame.
    unawaited(
      OfflineSpeechService.instance.initialize().timeout(
        const Duration(seconds: 8),
        onTimeout: () {},
      ),
    );
    unawaited(OfflineLlmService.instance.initialize());
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
      return Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            const Live2dAvatar(modelPath: Live2dModelPaths.bundledMao),
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
                                '启动失败：${snapshot.error}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              tooltip: '重试启动',
                              onPressed: _retry,
                              icon: const Icon(Icons.refresh),
                            ),
                          ],
                        )
                      : const Row(
                          children: [
                            SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 12),
                            Text('正在准备本地对话...'),
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
