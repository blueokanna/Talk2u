// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'Talk2U';

  @override
  String get settings => '设置';

  @override
  String get appearance => '外观与语言';

  @override
  String get themeMode => '主题模式';

  @override
  String get themeSystem => '跟随系统';

  @override
  String get themeLight => '浅色';

  @override
  String get themeDark => '深色';

  @override
  String get colorScheme => '配色方案';

  @override
  String get colorTeal => '青绿';

  @override
  String get colorBlue => '蓝色';

  @override
  String get colorGreen => '绿色';

  @override
  String get colorRose => '玫红';

  @override
  String get language => '界面语言';

  @override
  String get languageSystem => '跟随系统语言';

  @override
  String get languageChinese => '简体中文';

  @override
  String get languageEnglish => 'English';

  @override
  String get modelAndApi => '模型与接口';

  @override
  String get deviceAi => '设备端侧 AI';

  @override
  String get offlineRecognition => '端侧语音识别';

  @override
  String get mossSpeech => 'MOSS 端侧语音';

  @override
  String get startupPreparing => '正在准备本地对话...';

  @override
  String startupFailed(String error) {
    return '启动失败：$error';
  }

  @override
  String get rustCoreTimeout => 'Rust 核心加载超时';

  @override
  String get localDataTimeout => '本地数据初始化超时';

  @override
  String get retry => '重试';

  @override
  String get live2dDiagnostics => 'Live2D 性能';

  @override
  String get renderBackend => '实际后端';

  @override
  String get gpuDevice => 'GPU 设备';

  @override
  String get renderedFrames => '已渲染帧数';

  @override
  String get cpuUsage => 'CPU 使用率';

  @override
  String get gpuUsage => 'GPU 使用率';

  @override
  String get npuUsage => 'NPU 使用率';

  @override
  String get processScope => '应用进程';

  @override
  String get deviceScope => '整机';

  @override
  String get usageUnavailable => '不可用';

  @override
  String get gpuUsageUnavailable => '不可用：应用无权读取 GPU 利用率节点';

  @override
  String get npuUsageUnavailable => '不可用：Android/QNN 不向应用提供全局 NPU 利用率';

  @override
  String npuRecentWorkload(String value) {
    return '本应用最近 1 秒 HTP 调用占空比 $value%';
  }

  @override
  String get close => '关闭';

  @override
  String diagnosticsFailed(String error) {
    return '无法读取 Live2D 性能：$error';
  }

  @override
  String percentValue(String value) {
    return '$value%';
  }

  @override
  String get live2dDiagnosticsTooltip => 'Live2D 性能';

  @override
  String get reloadLive2d => '重新加载 Live2D';

  @override
  String get currentPlatformUnavailable => '当前平台没有可用的 Live2D 运行时';

  @override
  String get mossRuntimeUnavailable => 'QNN HTP 不可用';

  @override
  String get senseVoiceQnnUnsupported => 'QNN HTP · ASR / LID / SER / AED';

  @override
  String get platform => '平台';

  @override
  String get showSecret => '显示密钥';

  @override
  String get hideSecret => '隐藏密钥';

  @override
  String get apiKeyRequired => '请输入 API Key';

  @override
  String get apiUrl => '调用 URL';

  @override
  String get validHttpUrlRequired => '请输入完整的 HTTP(S) URL';

  @override
  String get chatModelId => '对话模型 ID';

  @override
  String get modelIdRequired => '请输入模型 ID';

  @override
  String get reasoningModelId => '推理模型 ID（可选）';

  @override
  String get maxOutputTokens => '最大输出 Token';

  @override
  String get tokenRangeError => '请输入 1 到 131072 之间的整数';

  @override
  String get enableReasoningByDefault => '默认启用推理管线';

  @override
  String get reasoningRequiresModel => '仅在当前平台配置了推理模型时生效';

  @override
  String get saveConfiguration => '保存配置';

  @override
  String get testConnection => '测试连接';

  @override
  String get manageModel => '管理端侧模型';

  @override
  String get deleteModel => '删除模型';

  @override
  String get installQwen => '下载 Qwen3-4B-Instruct-2507 模型';

  @override
  String get cancelDownload => '取消下载';

  @override
  String get deleteSenseVoice => '删除 SenseVoice';

  @override
  String get downloadSenseVoice => '下载 SenseVoice';

  @override
  String get deleteMoss => '删除 MOSS-TTS-Nano';

  @override
  String get importMoss => '导入 MOSS QNN HTP 部署包';

  @override
  String get mossVoice => 'MOSS 内置克隆音色';

  @override
  String get stopPreview => '停止试听';

  @override
  String get previewVoice => '试听当前音色';

  @override
  String get mossPreviewText => '你好，很高兴认识你。今天想聊些什么？我会认真听，也会自然地回应你。';

  @override
  String qwenReady(String acceleration) {
    return '已就绪 · $acceleration';
  }

  @override
  String get qwenInstallHint => '无需 API；GenieX 自动下载芯片匹配的 QAIRT 模型包';

  @override
  String qwenModelReady(String license, String size) {
    return '已就绪 · $license · $size';
  }

  @override
  String qwenModelPackage(String license) {
    return '$license · QAIRT · Qualcomm QNN HTP/NPU';
  }

  @override
  String get loadingModel => '正在载入模型...';

  @override
  String get senseVoiceReady => '已就绪 · SM8850 QNN HTP · 完全离线';

  @override
  String get senseVoiceSize => '约 154.5 MiB · SenseVoice INT8 · SM8850 QNN';

  @override
  String get mossGenerating => '正在进行端侧语音推理';

  @override
  String get mossInitializing => '正在初始化 QNN HTP 上下文';

  @override
  String mossReady(String acceleration) {
    return '已就绪 · $acceleration · 48 kHz · 中文/英文/日文';
  }

  @override
  String loadSettingsFailed(String error) {
    return '加载设置失败：$error';
  }

  @override
  String get settingsWriteFailed => '设置文件写入失败';

  @override
  String providerSaved(String provider) {
    return '$provider 配置已保存';
  }

  @override
  String saveFailed(String error) {
    return '保存失败：$error';
  }

  @override
  String connectionTestFailed(String error) {
    return '连接测试失败：$error';
  }

  @override
  String get qwenInstalled => 'Qwen3-4B-Instruct-2507 模型已安装并校验完成';

  @override
  String qwenInstallFailed(String error) {
    return 'Qwen3 部署包安装失败：$error';
  }

  @override
  String get offlineModelDeleted => '已删除端侧 AI 模型';

  @override
  String offlineModelDeleteFailed(String error) {
    return '无法删除端侧 AI 模型：$error';
  }

  @override
  String get senseVoiceInstalled => 'SenseVoice 离线识别模型已安装';

  @override
  String senseVoiceInstallFailed(String error) {
    return 'SenseVoice 下载失败：$error';
  }

  @override
  String get mossImported => 'MOSS QNN HTP 部署包已导入并校验';

  @override
  String mossImportFailed(String error) {
    return 'MOSS QNN 部署包导入失败：$error';
  }

  @override
  String get mossDeleted => '已删除 MOSS-TTS-Nano 端侧模型';

  @override
  String mossDeleteFailed(String error) {
    return '无法删除 MOSS-TTS-Nano：$error';
  }

  @override
  String get mossVoiceChanged => '已切换 MOSS 内置克隆音色';

  @override
  String mossVoiceChangeFailed(String error) {
    return '无法切换 MOSS 音色：$error';
  }

  @override
  String mossPreviewFailed(String error) {
    return 'MOSS-TTS-Nano 试听失败：$error';
  }

  @override
  String get cancel => '取消';

  @override
  String get delete => '删除';

  @override
  String get edit => '编辑';

  @override
  String get send => '发送';

  @override
  String get copy => '复制';

  @override
  String get copied => '已复制到剪贴板';

  @override
  String get regenerate => '重新生成';

  @override
  String get rewrite => '重写';

  @override
  String get rollback => '回溯';

  @override
  String get editAndResend => '编辑并重发';

  @override
  String get deleteMessage => '删除消息';

  @override
  String get deleteMessageConfirm => '确定要删除这条消息吗？';

  @override
  String get rollbackConversation => '回溯对话';

  @override
  String get rollbackConversationConfirm =>
      '将删除这条消息及之后的所有对话记录，相关记忆也会被清除。确定要回溯吗？';

  @override
  String get thinking => '深度思考';

  @override
  String get thinkingProcess => '思考过程';

  @override
  String get editMessageHint => '编辑消息...';

  @override
  String get typing => '正在输入...';

  @override
  String get emptyReply => '（空回复）';

  @override
  String get offlineVoiceInput => '离线语音输入';

  @override
  String get offlineVoiceUnavailable => '设备无离线识别引擎';

  @override
  String get aiResponding => 'AI 正在回复...';

  @override
  String get messageHint => '输入消息...';

  @override
  String get stopGenerating => '停止生成';

  @override
  String get conversations => '对话';

  @override
  String get newConversation => '新建';

  @override
  String get noConversations => '暂无对话';

  @override
  String get startConversationHint => '点击新建开始聊天';

  @override
  String get untitledConversation => '未命名对话';

  @override
  String get deleteConversation => '删除对话';

  @override
  String get deleteConversationConfirm => '确定要删除这个对话吗？此操作不可撤销。';

  @override
  String get justNow => '刚刚';

  @override
  String minutesAgo(int count) {
    return '$count 分钟前';
  }

  @override
  String daysAgo(int count) {
    return '$count 天前';
  }

  @override
  String get charactersTitle => '我的角色';

  @override
  String get deleteCharacter => '删除角色';

  @override
  String deleteCharacterConfirm(String name) {
    return '确定要删除“$name”吗？此操作不可撤销。';
  }

  @override
  String charactersImported(int count) {
    return '成功导入 $count 个角色';
  }

  @override
  String get characterImportFailed => '导入失败，请检查文件格式';

  @override
  String exportFailed(String error) {
    return '导出失败：$error';
  }

  @override
  String shareCharacter(String name) {
    return '角色配置：$name';
  }

  @override
  String get shareAllCharacters => '全部角色配置';

  @override
  String get importCharacters => '导入角色';

  @override
  String get exportAll => '导出全部';

  @override
  String get export => '导出';

  @override
  String get createCharacter => '创建角色';

  @override
  String get editCharacter => '编辑角色';

  @override
  String get regularAssistant => '普通助手';

  @override
  String get directChat => '无需创建角色，直接开始对话';

  @override
  String get noCharacterSettings => '不使用角色设定';

  @override
  String characterSaveFailed(String error) {
    return '角色保存失败：$error';
  }

  @override
  String live2dModelsImported(int count) {
    return 'Live2D 模型已导入，共发现 $count 个模型';
  }

  @override
  String live2dModelImportFailed(String error) {
    return 'Live2D 模型导入失败：$error';
  }

  @override
  String get chooseLive2dModel => '选择 Live2D 模型';

  @override
  String get maoLicenseTitle => '使用内置 Mao 示例模型';

  @override
  String get maoLicenseDescription =>
      '该模型由 Live2D Inc. 提供，使用前必须同意 Cubism 示例模型授权要求。model/Live2d/mao/ReadMe.txt 中包含来源与许可说明。';

  @override
  String get licenseAccepted => '我已阅读并同意';

  @override
  String get maoInstalled => 'Cubism 5 Mao 模型已安装';

  @override
  String maoInstallFailed(String error) {
    return '内置模型安装失败：$error';
  }

  @override
  String get characterName => '姓名';

  @override
  String get characterNameHint => '输入 AI 昵称';

  @override
  String get characterNameRequired => '请输入角色名称';

  @override
  String get gender => '性别';

  @override
  String get genderMale => '男性';

  @override
  String get genderFemale => '女性';

  @override
  String get genderOther => '其他';

  @override
  String get characterSetting => '角色设定';

  @override
  String get characterSettingHelp => '描述角色的背景、性格、身份以及与你的关系等；这些内容会影响对话效果。';

  @override
  String get characterSettingHint => '描述角色的性格、身份、背景等';

  @override
  String get characterSettingRequired => '请输入角色设定';

  @override
  String get characterDescription => '角色简介';

  @override
  String get characterDescriptionHelp => '在角色列表中介绍这个角色，不影响对话效果。';

  @override
  String get characterDescriptionHint => '介绍你的 AI 角色';

  @override
  String get characterGreeting => '角色开场白';

  @override
  String get characterGreetingHint => '请输入角色开场白';

  @override
  String get dialogueStyleExample => '对话风格示例';

  @override
  String get dialogueStyleHelp => '请填写体现 AI 角色说话风格与语气的文本。';

  @override
  String get dialogueStyleHint => '体现角色说话风格的示例';

  @override
  String get userName => '用户名称';

  @override
  String get userNameHint => 'AI 对你的称呼';

  @override
  String get userPersona => '用户聊天人设';

  @override
  String get userPersonaHelp => '描述你在 AI 眼中扮演的身份、性格或经历。';

  @override
  String get userPersonaHint => '描述你在对话中的身份';

  @override
  String get live2dModel => 'Live2D 模型';

  @override
  String get noLive2dModel => '未导入 Live2D ZIP 模型包';

  @override
  String get importLive2dModel => '导入 Live2D ZIP 模型包';

  @override
  String get installMaoModel => '安装内置 Cubism 5 Mao 模型';

  @override
  String get tags => '标签';

  @override
  String get addTag => '添加标签';

  @override
  String get tagNameHint => '输入标签名称';

  @override
  String get confirm => '确认';

  @override
  String offlineSttUnavailable(String error) {
    return '端侧语音识别不可用：$error';
  }

  @override
  String get continuousCallRequiresSpeech => '持续通话需要可用的端侧语音识别和语音合成';

  @override
  String continuousCallStartFailed(String error) {
    return '无法开始持续通话：$error';
  }

  @override
  String continuousCallStopped(String error) {
    return '持续通话已停止：$error';
  }

  @override
  String get noOfflineTtsVoice => '未检测到可用的端侧 TTS 语音包';

  @override
  String offlineTtsUnavailable(String error) {
    return '端侧语音合成不可用：$error';
  }

  @override
  String get restart => '重启';

  @override
  String get restartConversationSubtitle => '清除对话记录，保留角色设定和开场白';

  @override
  String get conversationStyle => '对话风格';

  @override
  String get styleFree => '自由';

  @override
  String get styleDialogue => '纯对话';

  @override
  String get styleAction => '纯动作';

  @override
  String get styleMixed => '混合（自动识别）';

  @override
  String get providerAndModel => '平台与模型';

  @override
  String get apiProvider => 'API 平台';

  @override
  String providerNotConfigured(String provider) {
    return '$provider（未配置）';
  }

  @override
  String get notConfigured => '未配置';

  @override
  String get chatModel => '对话模型';

  @override
  String get reasoningModelHint => '推理模型，自动启用推理管线';

  @override
  String get restartStory => '重启剧情';

  @override
  String get restartStoryConfirm => '确定要重启剧情吗？所有对话记录将被清除，但角色设定和开场白会保留。';

  @override
  String get stopReading => '停止朗读';

  @override
  String get readLastReply => '端侧朗读上一条回复';

  @override
  String get noOfflineTtsPack => '设备无端侧 TTS 语音包';

  @override
  String get characterList => '角色列表';

  @override
  String get settingsSubtitle => 'API 密钥、模型配置';

  @override
  String get hideConversation => '隐藏对话';

  @override
  String get showConversation => '查看对话';

  @override
  String get endContinuousCall => '结束持续通话';

  @override
  String get startContinuousCall => '开始持续通话';

  @override
  String get conversation => '对话';

  @override
  String get startNewConversation => '开始新的对话';

  @override
  String get startNewConversationHint => '输入消息开始聊天，或选择一个角色';

  @override
  String get chooseCharacter => '选择角色';

  @override
  String llmRoute(String acceleration) {
    return 'LLM · $acceleration';
  }

  @override
  String ttsRoute(String acceleration) {
    return 'TTS · $acceleration';
  }

  @override
  String live2dScriptFailed(String error) {
    return 'Live2D 脚本错误：$error';
  }

  @override
  String live2dRuntimeFailed(String error) {
    return 'Live2D 运行时启动失败：$error';
  }

  @override
  String get live2dLoadFailed => 'Live2D 加载失败';

  @override
  String get live2dInvalidStatus => 'Live2D 返回了无效状态';

  @override
  String get diagnosticsInvalidJson => '诊断结果不是 JSON 对象';
}
