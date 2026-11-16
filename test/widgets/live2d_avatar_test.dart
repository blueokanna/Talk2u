import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/l10n/generated/app_localizations.dart';
import 'package:talk2u/src/widgets/live2d_avatar.dart';

void main() {
  test('explicit same-name cues are separate events; gaze is not a cue', () {
    final controller = Live2dAvatarController();
    var notifications = 0;
    controller.addListener(() => notifications++);
    controller.perform('nod');
    controller.perform('nod');
    expect(controller.revision, 2);
    controller.lookAt(2, -2);
    expect(controller.gaze, const Offset(1, -1));
    expect(controller.revision, 2);
    controller.lookAt(1, -1);
    expect(notifications, 3);
    controller.lookAt(double.nan, double.infinity);
    expect(controller.gaze, Offset.zero);
    controller.lookAt(.5, .5);
    controller.clearGaze();
    expect(controller.gaze, Offset.zero);
    controller.dispose();
  });

  testWidgets('duplicate ready does not replay cue; hidden view pauses', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    MethodChannel? avatarChannel;
    final controller = Live2dAvatarController();
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        final id = (call.arguments as Map)['id'];
        avatarChannel = MethodChannel('talk2u/live2d_$id');
        messenger.setMockMethodCallHandler(avatarChannel!, (call) async {
          calls.add(call);
          if (call.method == 'getStatus') return jsonEncode({'type': 'ready'});
          return null;
        });
      }
      return null;
    });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      if (avatarChannel != null) {
        messenger.setMockMethodCallHandler(avatarChannel!, null);
      }
      controller.dispose();
    });
    Widget app({bool visible = true, bool reduced = false}) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Live2dAvatar(
          modelPath: Live2dModelPaths.bundledMao,
          controller: controller,
          visible: visible,
        ),
      ),
    );
    await tester.pumpWidget(app());
    await tester.pump();
    await tester.pump();
    expect(avatarChannel, isNotNull);
    controller.perform('nod');
    await tester.pump();
    expect(calls.where((call) => call.method == 'perform'), hasLength(1));
    tester.binding.channelBuffers.push(
      avatarChannel!.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('status', jsonEncode({'type': 'ready'})),
      ),
      (_) {},
    );
    await tester.pump();
    expect(calls.where((call) => call.method == 'perform'), hasLength(1));
    await tester.pumpWidget(app(visible: false));
    expect(
      (calls.lastWhere((call) => call.method == 'setRenderPolicy').arguments
          as Map)['active'],
      isFalse,
    );
    controller.perform('nod');
    await tester.pump();
    expect(calls.where((call) => call.method == 'perform'), hasLength(1));
    await tester.pumpWidget(app(reduced: true));
    controller.perform('nod');
    await tester.pump();
    expect(calls.where((call) => call.method == 'perform'), hasLength(1));
    expect(
      (calls.lastWhere((call) => call.method == 'setRenderPolicy').arguments
          as Map)['reducedMotion'],
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}
