import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/services/camera_observation_service.dart';
import 'package:talk2u/src/widgets/camera_observation_banner.dart';
import 'package:talk2u/src/widgets/chat_empty_state.dart';

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
  testWidgets('idle camera state renders nothing', (tester) async {
    await tester.pumpWidget(
      _app(
        CameraObservationBanner(
          state: const CameraObservationState(status: 'idle'),
          onClose: () {},
        ),
      ),
    );
    expect(find.byIcon(Icons.videocam_outlined), findsNothing);
  });

  testWidgets('observing camera banner can be closed', (tester) async {
    var closed = false;
    await tester.pumpWidget(
      _app(
        CameraObservationBanner(
          state: const CameraObservationState(
            status: 'observing',
            faceCount: 1,
            primaryFace: CameraFacePosition(centerX: 0.5, centerY: 0.5),
          ),
          onClose: () => closed = true,
        ),
      ),
    );
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    expect(closed, isTrue);
  });

  testWidgets('empty transcript offers character selection', (tester) async {
    var chosen = false;
    await tester.pumpWidget(
      _app(ChatEmptyState(onChooseCharacter: () => chosen = true)),
    );
    expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.person_add_rounded));
    expect(chosen, isTrue);
  });
}
