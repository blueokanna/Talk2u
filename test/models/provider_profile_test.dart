import 'package:flutter_test/flutter_test.dart';
import 'package:talk2u/src/models/provider_profile.dart';

void main() {
  test('migrates a persisted Android offline provider to Qwen3 QAIRT', () {
    const legacy = ProviderProfile(
      id: ProviderProfile.androidOfflineId,
      name: 'Legacy local model',
      apiUrl: 'device://legacy',
      chatModel: 'Legacy model',
      protocol: 'local',
      maxOutputTokens: 128,
    );

    final profiles = ProviderProfile.withRuntimeDefaults(const [
      legacy,
    ], includeAndroidOffline: true);

    expect(profiles, hasLength(1));
    expect(profiles.single.apiUrl, 'device://geniex-qairt-npu');
    expect(profiles.single.chatModel, 'Qwen3-4B-Instruct-2507');
    expect(profiles.single.maxOutputTokens, 256);
  });

  test('removes the Android-only provider on unsupported platforms', () {
    final profiles = ProviderProfile.withRuntimeDefaults(const [
      ProviderProfile.androidOffline,
    ], includeAndroidOffline: false);

    expect(profiles, isEmpty);
  });
}
