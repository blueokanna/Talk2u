import 'dart:convert';

class ProviderProfile {
  static const androidOfflineId = 'android-offline';

  final String id;
  final String name;
  final String? apiKey;
  final String apiUrl;
  final String chatModel;
  final String? thinkingModel;
  final String protocol;
  final int maxOutputTokens;

  const ProviderProfile({
    required this.id,
    required this.name,
    this.apiKey,
    required this.apiUrl,
    required this.chatModel,
    this.thinkingModel,
    required this.protocol,
    required this.maxOutputTokens,
  });

  bool get isLocal => protocol == 'local';

  bool get isConfigured =>
      isLocal ||
      (!requiresApiKey || (apiKey?.trim().isNotEmpty ?? false)) &&
          apiUrl.trim().isNotEmpty &&
          chatModel.trim().isNotEmpty &&
          maxOutputTokens > 0;

  bool get requiresApiKey =>
      !isLocal && (id != 'custom' || protocol == 'anthropic');

  bool get supportsThinking => thinkingModel?.trim().isNotEmpty ?? false;

  static const androidOffline = ProviderProfile(
    id: androidOfflineId,
    name: '设备离线 AI',
    apiUrl: 'device://llama.cpp',
    chatModel: 'Qwen2.5-3B-Instruct-Q4_K_M',
    protocol: 'local',
    maxOutputTokens: 384,
  );

  factory ProviderProfile.fromJson(Map<String, dynamic> json) =>
      ProviderProfile(
        id: json['id'] as String? ?? 'custom',
        name: json['name'] as String? ?? '自定义接口',
        apiKey: json['api_key'] as String?,
        apiUrl: json['api_url'] as String? ?? '',
        chatModel: json['chat_model'] as String? ?? '',
        thinkingModel: json['thinking_model'] as String?,
        protocol: json['protocol'] as String? ?? 'openai',
        maxOutputTokens: json['max_output_tokens'] as int? ?? 4096,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'api_key': apiKey,
    'api_url': apiUrl,
    'chat_model': chatModel,
    'thinking_model': thinkingModel,
    'protocol': protocol,
    'max_output_tokens': maxOutputTokens,
  };

  ProviderProfile copyWith({
    String? name,
    String? apiKey,
    String? apiUrl,
    String? chatModel,
    String? thinkingModel,
    bool clearThinkingModel = false,
    String? protocol,
    int? maxOutputTokens,
  }) => ProviderProfile(
    id: id,
    name: name ?? this.name,
    apiKey: apiKey ?? this.apiKey,
    apiUrl: apiUrl ?? this.apiUrl,
    chatModel: chatModel ?? this.chatModel,
    thinkingModel: clearThinkingModel
        ? null
        : thinkingModel ?? this.thinkingModel,
    protocol: protocol ?? this.protocol,
    maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
  );

  static List<ProviderProfile> decodeList(String source) {
    final decoded = jsonDecode(source) as List<dynamic>;
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(ProviderProfile.fromJson)
        .toList();
  }

  static String encodeList(Iterable<ProviderProfile> profiles) =>
      jsonEncode(profiles.map((profile) => profile.toJson()).toList());
}
