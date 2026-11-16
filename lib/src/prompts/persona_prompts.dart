/// Model-facing prompt templates.
///
/// These strings are input for the language model, not text shown in the UI, so
/// they are intentionally outside the ARB files: translating them would change
/// the persona's reasoning language instead of the interface language. Keeping
/// them in one module also lets the cloud and on-device paths share wording.
library;

/// Builds the character system prompt.
///
/// [gender] is `male`, `female`, or empty to omit the sentence entirely.
String characterSystemPrompt({
  required String name,
  required String gender,
  required String setting,
  required String description,
  required String dialogueExample,
  required String userName,
  required String userSetting,
}) {
  final parts = <String>['你是"$name"，一个AI角色。请始终以该角色的身份进行对话，不要跳出角色。'];
  switch (gender) {
    case 'male':
      parts.add('你的性别是男。');
    case 'female':
      parts.add('你的性别是女。');
  }
  if (setting.isNotEmpty) parts.add('角色设定：$setting');
  if (description.isNotEmpty) parts.add('角色简介：$description');
  if (dialogueExample.isNotEmpty) parts.add('对话风格示例：$dialogueExample');
  if (userName.isNotEmpty) parts.add('请称呼用户为"$userName"。');
  if (userSetting.isNotEmpty) parts.add('用户的人设信息：$userSetting');
  return parts.join('\n');
}

/// Tells the model to rewrite its previous answer without reusing [rejected].
///
/// GenieX runs the local Qwen3 session with sampling disabled, so the prompt is
/// the only lever that changes the output; the rejected reply is quoted back and
/// explicitly forbidden. This mirrors `build_regeneration_directive` in Rust.
String offlineRewriteDirective(String rejected) =>
    '用户要求重写你上一条回复。下面这段内容已经被用户否决，'
    '不要重复它、不要改写它，必须换一个角度和说法，给出全新的回复。\n$rejected';
