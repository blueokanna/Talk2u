import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:talk2u/src/rust/api/chat_api.dart' as rust_api;
import 'package:talk2u/src/rust/frb_generated.dart';
import 'package:talk2u/src/state/chat_state.dart';
import 'package:talk2u/src/pages/chat_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  final appDir = await getApplicationDocumentsDirectory();
  await rust_api.initApp(dataPath: appDir.path);

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
        home: const ChatPage(),
      ),
    );
  }
}
