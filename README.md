# Talk2U

Talk2U 是一个 Flutter + Rust 的本地角色聊天应用。聊天记录、角色设定、记忆和知识数据保存在本机；模型回复可以来自用户选择的联网 LLM，也可以在 Android/iOS 上由端侧 Qwen 模型生成。Android、Windows 和 Linux 默认显示 Live2D 对话界面，对话文字按需展开，文字输入始终可用；端侧语音在 Android 系统能力不可用时回退到 sherpa-onnx。

本文档既是安装说明，也是当前实现边界。请先阅读“能力状态”，再按“Windows 到 Android 真机的最短路径”操作。

## 能力状态

| 能力 | 状态 | 实际实现 |
| --- | --- | --- |
| 智谱清言 | 已实现 | OpenAI-compatible SSE，智谱 API Key 转 JWT |
| DeepSeek | 已实现 | OpenAI-compatible SSE，支持 `deepseek-chat` / `deepseek-reasoner` |
| OpenAI | 已实现 | Chat Completions SSE，Bearer API Key |
| Anthropic | 已实现 | Messages API、`x-api-key`、`anthropic-version`、Anthropic SSE |
| Kimi | 已实现 | Moonshot OpenAI-compatible SSE |
| Qwen | 已实现 | DashScope OpenAI-compatible SSE |
| 自定义 URL | 已实现 | OpenAI-compatible；API Key 可留空，支持 HTTP(S) 完整地址 |
| 跨平台继续同一对话 | 已实现 | conversation 与供应商解耦，切换供应商不创建新会话 |
| 本地记忆/知识检索 | 已实现 | Rust 本地文件存储、短期上下文、长期摘要、知识事实检索 |
| Android/iOS 端侧 LLM | 已实现，有平台边界 | `fcllama`/llama.cpp 运行 Qwen2.5 3B Q4_K_M；Android 使用 ARM64 CPU/NEON，iOS 使用 Metal GPU；模型按需下载并校验 SHA-256 |
| 跨平台离线语音 | 已实现 | Android/Windows/Linux 使用 sherpa-onnx SenseVoice STT 与 Matcha TTS；模型按需下载 |
| Android/Windows/Linux Live2D | 有条件实现 | Android WebView、Windows WebView2、Linux CEF + Pixi；运行时必须取得 Cubism Core 5 |
| Cubism 5 moc3 | 已实现 | 导入时读取 `MOC3` 头并接受 moc3 版本 1-5；运行时拒绝 Core 4 |
| `.cdi3.json` | 已实现 | 校验 Version 3，并用于发现 LipSync 参数 |
| LipSync | 已实现 | Android TTS `onAudioAvailable` 的 PCM RMS 驱动模型嘴部参数 |
| 肢体动作/表情 | 已实现，取决于模型 | 只播放 `talk2u.avatar.json` 明确映射或名称可验证的动作组 |
| Android 离线 TTS | 已实现 | 优先选择系统离线 voice，不可用时回退到已下载的 sherpa Matcha |
| Android 离线 STT | 已实现 | 优先使用 Android on-device recognizer，不可用时回退到已下载的 sherpa SenseVoice |
| 原生 Vulkan/OpenGL ES 预检 | 已实现 | NDK C++ 真实创建 Vulkan instance/device；失败时真实创建 EGL OpenGL ES 3/2 context |
| Live2D Web 图形兼容 | 已实现 | 硬件 WebGL2 创建失败时降级 WebGL1；context lost 后恢复、重载或重建 PlatformView |
| Live2D 实际 Vulkan/OpenGL 后端 | 可验证、不可由 WebView 强制 | 实际 Vulkan 或 OpenGL ES 后端由系统 WebView/ANGLE 决定，应用只接受真实 GPU renderer 结果 |
| 官方 Cubism Native SDK 5 渲染器 | 未集成 | 仓库没有可再分发的 Native Core/Framework，不能宣称原生 Vulkan 已完成 |
| Discord | 已实现 | 独立 Rust 轮询桥接进程，共用对话、记忆和供应商层 |
| iOS/macOS Live2D | 未实现 | 当前 Live2D 宿主只覆盖 Android、Windows 和 Linux |
| Discord Gateway/Android 常驻 Bot | 未实现 | 当前是桌面或服务器前台轮询进程 |

“已实现”不等于第三方服务永远可用。实际联网调用还需要有效 API Key、账户额度、可访问的服务地址和正确模型 ID。仓库不会内置任何 API Key。

## 架构

```text
Flutter UI
  ├─ 平台/模型选择、角色、对话和记忆界面
  ├─ 默认全屏 Live2D；对话记录按需展开；文字输入常驻
  ├─ AndroidView -> Live2D WebView；Windows -> WebView2；Linux -> CEF
  ├─ Android/iOS fcllama -> Qwen2.5 3B 端侧回复
  ├─ sherpa-onnx -> 跨平台离线 STT/TTS
  └─ MethodChannel/EventChannel -> Android 系统 TTS/STT 与 PCM 振幅
             |
flutter_rust_bridge
             |
Rust core
  ├─ ProviderRuntime
  │   ├─ OpenAI-compatible
  │   └─ Anthropic Messages
  ├─ ChatEngine
  │   ├─ conversation 上下文
  │   ├─ 本地知识检索
  │   ├─ 记忆摘要
  │   └─ 可选推理管线
  ├─ ConversationStore / MemoryEngine / KnowledgeStore
  └─ DiscordBridge
```

供应商只决定“下一次请求发到哪里”。conversation ID、角色 system prompt、用户/助手消息、摘要和知识事实都不属于某个供应商，因此可以从 DeepSeek 切换到 OpenAI 或 Anthropic 后继续同一上下文。

为避免上下文无限膨胀，请求层最多选择最近 20 条历史消息，并把长期信息交给摘要和知识检索层。历史文件不会因为这个窗口被删除。

## 仓库目录

```text
android/                 Android 原生 TTS/STT、Live2D PlatformView
assets/live2d/           Live2D HTML 宿主与可再分发 JS 依赖
lib/                     Flutter UI、状态、角色与端侧服务
model/mao/runtime/       内置最小 Cubism 5 运行时模型
model/Custom_Suiika/     可选外部参考模型；仓库不要求存在，也不打进 APK
rust/src/api/            聊天、供应商、记忆、知识与存储
rust/src/connectors/     外部平台连接器
test/                    Flutter 单元测试
tool/                    Android、Cubism Core 和模型打包脚本
```

## Windows 到 Android 真机的最短路径

### 1. 安装基础工具

需要：

- Windows 10/11 x64。
- Flutter SDK，项目当前 Dart 约束见 `pubspec.yaml`。
- Rust stable MSVC 工具链。
- Visual Studio Build Tools，包含“使用 C++ 的桌面开发”。
- JDK 17。
- Android SDK 36、Build Tools 36、NDK `28.0.12674087`、CMake `3.22.1` 和 `3.31.0`。应用原生探针使用 3.22.1，fcllama 使用 3.31.0。
- 一台启用 USB 调试的 ARM64 Android 设备。

检查命令：

```powershell
flutter --version
flutter doctor -v
rustc --version
cargo --version
java -version
adb devices
```

JDK 必须显示 17。设备应在 `adb devices` 中显示为 `device`，不能是 `unauthorized`。

### 2. 自动准备仓库内 Android SDK（可选）

脚本会下载 Google command-line tools，显示 Android 许可，并把 SDK 安装到仓库的 `.android-sdk/`。只有阅读并接受相应许可后才可传入开关。

Flutter 已在 PATH：

```powershell
.\tool\bootstrap_android.ps1 -AcceptAndroidLicenses
```

Flutter 不在 PATH：

```powershell
.\tool\bootstrap_android.ps1 `
  -FlutterRoot 'C:\dev\flutter' `
  -AcceptAndroidLicenses
```

自定义 Android SDK 位置：

```powershell
.\tool\bootstrap_android.ps1 `
  -SdkRoot 'C:\Android\sdk' `
  -FlutterRoot 'C:\dev\flutter' `
  -AcceptAndroidLicenses
```

脚本会生成 `android/local.properties`，该文件只属于本机，不要提交。

### 3. 安装 Rust Android target

当前 APK 只构建 `arm64-v8a`，这是为了减小包体和最小化原生组合数量：

```powershell
rustup target add aarch64-linux-android
```

需要 x86_64 模拟器时，必须同时完成以下三项：

1. 在 `android/app/build.gradle.kts` 的 `abiFilters` 增加 `x86_64`。
2. 从同一文件的 `packaging.jniLibs.excludes` 删除 `lib/x86_64/**`。
3. 执行 `rustup target add x86_64-linux-android`，然后使用 `--target-platform android-x64` 构建。

不要只增加其中一项。APK 中每个被声明支持的 ABI 都必须同时拥有 Flutter、Rust 和插件 JNI 库，否则会在启动时加载原生库失败。仓库内的 Cargokit 补丁只构建 Flutter 命令明确请求的架构，不会再向 debug 包偷偷追加模拟器 ABI。

### 4. 获取依赖并运行测试

```powershell
flutter pub get

Push-Location rust
cargo test --all-targets
Pop-Location

flutter test
flutter analyze lib test
```

`flutter pub get` 不能在首次构建或修改 `pubspec.yaml` 后省略。它会生成被 Git 忽略的 `.flutter-plugins-dependencies`；缺少该文件时 Dart 包可能仍能被分析，但 Android Gradle 不会注册 `rust_lib_talk2u`，最终 APK 也就没有 Rust 动态库。

### 5. 构建并安装 debug APK

```powershell
flutter build apk --debug --target-platform android-arm64
flutter install
```

APK 默认输出：

```text
build/app/outputs/flutter-apk/app-debug.apk
```

不要只看“Built”字样。构建后检查 APK 的原生库和 ABI：

```powershell
tar -tf .\build\app\outputs\flutter-apk\app-debug.apk |
  Select-String 'lib/arm64-v8a/(libflutter|librust_lib_talk2u)\.so'

.\.android-sdk\build-tools\36.0.0\aapt.exe dump badging `
  .\build\app\outputs\flutter-apk\app-debug.apk |
  Select-String 'sdkVersion|targetSdkVersion|native-code'
```

第一条必须同时出现 `libflutter.so` 和 `librust_lib_talk2u.so`；第二条的 `native-code` 当前必须只有 `arm64-v8a`。

也可以直接安装：

```powershell
adb install -r .\build\app\outputs\flutter-apk\app-debug.apk
```

首次启动直接进入“普通助手”的 Live2D 对话界面，画面使用内置 Mao，但不会注入任何角色设定；不创建角色也能像普通 AI 一样聊天。需要自定义身份时，再从角色列表创建角色并选择 Live2D 模型。联网使用时配置一个 API 平台；Android/iOS 完全离线使用时在设置中下载端侧 AI 模型。

### 6. 构建 Windows 和 Linux

Windows 必须安装 Visual Studio 的“使用 C++ 的桌面开发”工作负载和 Microsoft Edge WebView2 Evergreen Runtime（Windows 10/11 通常已安装）：

```powershell
flutter build windows --debug
```

Linux 构建必须在 Linux 主机或 CI 上执行，并预先安装 Flutter Linux 桌面依赖、GTK 3、CMake、Ninja 和标准 C++ 工具链。首次构建会从 CEF 官方 CDN 下载 Standard Distribution，体积较大：

```bash
flutter build linux --debug
```

Windows 使用系统 WebView2 Runtime；Linux 的 CEF 运行库会随构建 bundle 打包。两端都不能只复制可执行文件，应分发整个 `build/windows/x64/runner/Debug/` 或 `build/linux/x64/debug/bundle/` 目录。

## 配置 LLM 平台

打开应用抽屉中的“设置”。每个平台都有独立的 API Key、调用 URL、对话模型、可选推理模型和最大输出 Token。内置 URL 和模型已预填，通常只需要选择平台并输入对应 API Key。

| 平台 | 协议 | 默认 URL | 默认对话模型 |
| --- | --- | --- | --- |
| 智谱清言 | OpenAI-compatible + 智谱 JWT | `https://open.bigmodel.cn/api/paas/v4/chat/completions` | `glm-4.7` |
| DeepSeek | OpenAI-compatible | `https://api.deepseek.com/chat/completions` | `deepseek-chat` |
| OpenAI | Chat Completions | `https://api.openai.com/v1/chat/completions` | `gpt-4.1-mini` |
| Anthropic | Messages API | `https://api.anthropic.com/v1/messages` | `claude-sonnet-4-5` |
| Kimi | OpenAI-compatible | `https://api.moonshot.cn/v1/chat/completions` | `moonshot-v1-8k` |
| Qwen | OpenAI-compatible | `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions` | `qwen-plus` |
| 自定义 | OpenAI-compatible | 用户填写 | 用户填写 |

第三方平台会更新模型名。遇到“model not found”时，以对应平台控制台当前显示的模型 ID 为准，直接在设置中覆盖默认值，不需要改代码。

### API Key 获取入口

- 智谱开放平台：<https://open.bigmodel.cn/>
- DeepSeek 开放平台：<https://platform.deepseek.com/>
- OpenAI API 平台：<https://platform.openai.com/api-keys>
- Anthropic Console：<https://console.anthropic.com/settings/keys>
- Moonshot 开放平台：<https://platform.moonshot.cn/>
- 阿里云百炼：<https://bailian.console.aliyun.com/>

不要使用 ChatGPT、Claude 或其他聊天网站的登录密码；这里需要开发者 API Key。聊天产品订阅也不一定包含 API 额度。

### Anthropic 的区别

Anthropic 不是把 Messages URL 当作普通 OpenAI 接口调用。Rust 层会执行以下转换：

- 使用 `x-api-key`，而不是 `Authorization: Bearer`。
- 添加 `anthropic-version: 2023-06-01`。
- 把所有 system 消息合并到顶层 `system` 字段。
- 解析 `content_block_delta`、`text_delta`、`thinking_delta` 和 `message_stop`。
- 删除 Anthropic 不接受的智谱 `thinking` 字段。

### 自定义 OpenAI-compatible URL

选择“自定义 OpenAI 兼容接口”，填写完整 endpoint，例如：

```text
https://gateway.example.com/v1/chat/completions
```

本机 Ollama、vLLM 或兼容网关可填写：

```text
http://192.168.1.20:11434/v1/chat/completions
```

注意：

- Android 真机里的 `127.0.0.1` 是手机自身，不是开发电脑。
- Android 官方模拟器访问宿主机通常使用 `10.0.2.2`。
- 真机访问电脑应使用局域网 IP，并开放防火墙端口。
- 自签名 HTTPS 证书默认不会被信任。
- HTTP 会明文传输内容和密钥，只应在可信局域网使用。
- 自定义平台的 API Key 可以留空，适合无鉴权的本地服务。
- 当前自定义协议是 Chat Completions 兼容格式，不是 OpenAI Responses API。

### 在聊天中切换平台但保留上下文

1. 在设置中分别保存 DeepSeek、OpenAI、Anthropic 等平台的 Key。
2. 打开或创建一个 conversation。
3. 在聊天页右上角菜单打开“平台与模型”。
4. 选择 DeepSeek 并发送消息。
5. 再打开同一菜单，选择 OpenAI 或 Anthropic。
6. 下一条消息仍携带同一 conversation 的角色设定、最近历史、摘要和相关知识。

切换被禁止的唯一正常时机是上一条流式回复仍在生成。等待完成后再切换，避免同一 conversation 出现并发写入。

## 端侧离线 AI 与语音模型

模型不打入 APK 或桌面安装包，用户在设置页按需下载。下载支持取消，完成后会检查文件大小、格式和 SHA-256；模型加载、解压、识别与合成放在后台任务中，不阻塞首屏。

| 用途 | 平台 | 模型 | 下载大小 | SHA-256 |
| --- | --- | --- | ---: | --- |
| 离线对话 | Android ARM64 / iOS | Qwen2.5 3B Instruct Q4_K_M | 2,104,932,768 B | `626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d` |
| 离线 STT | Android/Windows/Linux | SenseVoice 2025 INT8 | 165,783,878 B | `7305f7905bfcf77fa0b39388a313f3da35c68d971661a65475b56fb2162c8e63` |
| 离线 TTS | Android/Windows/Linux | Matcha 中英双语 | 79,033,838 B | `271b804af570400d3bcdcb53bf6e53cc9f75180ee763b9f13eb5eaf2b0d086ef` |
| TTS 声码器 | Android/Windows/Linux | Vocos 16 kHz universal | 53,882,848 B | `b599142a1fb8ff03de3e84ac35ff537c619e56f4267a6fe894851a42844acf9e` |

`fcllama` 和 llama.cpp 使用 MIT 许可，当前 Qwen2.5 3B 权重使用 Qwen Research License；`sherpa-onnx` 使用 Apache-2.0。引擎许可证不自动覆盖模型权重，准备公开再分发安装包或模型镜像前，仍须逐项复核相应模型发布页的权重许可与署名要求。当前实现让设备直接从 Qwen 或 k2-fsa 的官方发布地址下载，不在仓库中重新分发权重。

### 端侧 LLM 硬件后端

| 平台/芯片 | 当前推理后端 | 当前状态 |
| --- | --- | --- |
| Android ARM64（高通、麒麟、联发科） | llama.cpp CPU/NEON | 已实现；不需要 API Key；未接入 QNN、HiAI 或 NeuroPilot NPU |
| iPhone/iPad | llama.cpp Metal GPU | 已实现；不需要 API Key |
| Windows x64/ARM64 | 无端侧 LLM 后端 | 未实现 DirectML/CUDA/Vulkan/CPU 本地推理，当前只能使用联网平台 |
| Linux x64/ARM64 | 无端侧 LLM 后端 | 未实现 CUDA/Vulkan/ROCm/CPU 本地推理，当前只能使用联网平台 |
| macOS | 无端侧 LLM 后端 | 当前 `fcllama` 接入只启用 iOS，macOS 尚未接入 |

Android/iOS 下载并校验 3B 模型后，不填写任何联网 API Key 也可以对话。应用会在发送第一条消息时自动切换到端侧平台并懒加载模型，避免在启动阶段同步加载约 2.1 GB 权重而卡住。当前 `fcllama 0.0.3` 没有 QNN、HiAI、NeuroPilot、DirectML 或通用桌面后端，因此应用不会把 CPU/NEON 伪装成 NPU/GPU 加速。

Android 会优先使用系统自身可验证的 on-device STT 和离线 TTS voice，保留厂商端侧优化与更低延迟；系统能力缺失或 ROM 不支持时，下载 SenseVoice/Matcha 后自动使用 sherpa-onnx。Windows/Linux 直接使用 sherpa-onnx。所有平台即使未安装语音模型也始终可以文字输入。

## Live2D Cubism 5 模型与 Core

### 必须先理解的兼容边界

当前运行链路是 Android `WebView`、Windows `WebView2` 或 Linux `CEF` -> PixiJS 6.5.10 -> pixi-live2d-display 0.4.0 -> Cubism Core 5。它会在加载前检查 Core 主版本至少为 5，仓库中的两个 moc 文件也都真实读取为 MOC3 version 5。`pixi-live2d-display` 本身仍把这条运行时注册为 Cubism 4 API 层，因此本项目不能把它描述为“官方 Cubism SDK for Native 5 已集成”。

这一区别很重要：MOC3 v5、CDI3、物理、姿势、动作和表情的当前路径可以运行；若模型依赖未来新增、且第三方 Web 框架尚未实现的 SDK 5 Framework 行为，必须换成已接受许可的官方 Cubism SDK for Web/Native 5 实现并重新做真机验收。仓库不会用版本字符串掩盖这个边界。

### 为什么仓库没有 Cubism Core

`live2dcubismcore.min.js` 受 Live2D 许可约束，不能作为普通开源依赖随意再分发。因此仓库包含 Pixi 和 `pixi-live2d-display` 的可再分发文件，但不包含 Cubism Core。

运行时加载顺序：

1. `assets/live2d/vendor/live2dcubismcore.min.js`。
2. 如果本地文件不存在，尝试 Live2D 官方 CDN。
3. 两者都失败时显示真实错误，不用静态图片冒充 Live2D。

联网运行可使用官方 CDN。需要完全离线显示时，必须自己获取 Cubism SDK for Web 5 并接受 Live2D 许可。

### 安装 Cubism Core 5 供离线使用

1. 从 <https://www.live2d.com/en/sdk/download/web/> 下载 Cubism SDK for Web 5。
2. 阅读 SDK 和 Cubism Core 的许可条款。
3. 解压 SDK。
4. 执行：

```powershell
.\tool\install_live2d_core.ps1 `
  -SdkRoot 'C:\SDK\CubismSdkForWeb-5-r.x' `
  -AcceptLive2DLicense
```

脚本会寻找 `live2dcubismcore.min.js`，复制到：

```text
assets/live2d/vendor/live2dcubismcore.min.js
```

然后重新构建 APK。脚本会打印 SHA-256，便于确认最终打包的是哪个 Core。不要把该文件提交或公开分发，除非你的许可明确允许。

### 最小可运行模型：虹色 Mao

仓库已包含 Live2D 官方示例模型“虹色 Mao”的 runtime 文件：

```text
model/mao/runtime/
  mao_pro.model3.json
  mao_pro.moc3              # MOC3 version 5
  mao_pro.cdi3.json         # DisplayInfo version 3
  mao_pro.physics3.json
  mao_pro.pose3.json
  mao_pro.4096/texture_00.png
  motions/
  expressions/
  talk2u.avatar.json
```

应用内安装步骤：

1. 打开角色列表。
2. 新建或编辑角色。
3. 点击“安装内置 Cubism 5 Mao 模型”。
4. 阅读并确认示例模型授权提示。
5. 保存角色并进入聊天。

安装操作把 APK asset 复制到应用私有目录并再次校验。它不依赖外部文件管理权限。

示例模型许可原文摘要和官方链接在 `model/mao/ReadMe.txt`。商业使用前必须自行确认当前许可。

### 导入自己的模型

应用导入的是完整 ZIP，不是单独的 `.model3.json`：

```text
my-avatar.zip
└─ my-avatar/
   ├─ avatar.model3.json
   ├─ avatar.moc3
   ├─ avatar.cdi3.json
   ├─ avatar.physics3.json
   ├─ textures/
   ├─ motions/
   ├─ expressions/
   └─ talk2u.avatar.json    # 可选但推荐
```

ZIP 中必须只有一个 `.model3.json`。导入器会：

- 阻止 ZIP Slip 和目录越界。
- 限制最多 4096 个条目和 512 MB 解压体积。
- 校验 JSON 和所有被引用资源。
- 处理 Windows/Android 文件名大小写差异并规范引用。
- 检查 `MOC3` 签名和 moc3 版本 1-5。
- 校验 `.cdi3.json` 的 `Version == 3`。
- 从 `Groups/LipSync` 或 `.cdi3.json` 发现嘴部参数。
- 自动发现 VTube Studio 包中未写入 `.model3.json` 的 `Expressions/*.exp3.json` 和 `Animations/*.motion3.json`，并生成运行时引用。
- 拒绝超过 4096x4096 的单张纹理。
- 按设备总内存、当前可用内存和纹理/moc 展开体积计算保守预算，超预算时阻止加载。

电脑端先验证并打包：

```powershell
.\tool\package_live2d_model.ps1 `
  -ModelDirectory 'C:\models\my-avatar' `
  -OutputPath 'C:\models\my-avatar-talk2u.zip'
```

脚本会在创建 ZIP 前检查资源、moc3 版本、`.cdi3.json` 和 LipSync 参数。

### `model/` 中的两个模型

| 目录 | MOC/CDI | LipSync | 运行时资源 | Android 默认打包 |
| --- | --- | --- | --- | --- |
| `model/mao/runtime` | MOC3 v5 / CDI3 v3 | `ParamA` | 1 张 4K 纹理、7 动作、8 表情 | 是 |
| 可选 `model/Custom_Suiika` | MOC3 v5 / CDI3 v3 | CDI3 中的 `ParamMouthOpenY` | 外部模型包，内容取决于用户提供的版本 | 否 |

`Custom_Suiika` 不随仓库分发。若自行放入大型版本，其多张 2K 纹理在解码后的 GPU/CPU 内存会远大于压缩文件体积；默认打进 APK 会显著增大安装包，并可能在中低端 Android 设备上触发内存回收。因此它只能作为可选导入参考，必须先用打包脚本生成 ZIP，再由目标设备的内存校验决定能否加载。

`.vtube.json` 等 VTube Studio 附加文件会保留在 ZIP 中，但当前运行时不解析 VTube Studio 的摄像头追踪和热键协议。导入 `Custom_Suiika` 这类包时，导入器会把未引用的 Idle 和表情文件补进应用私有目录中的 `.model3.json`；原始 `model/` 文件不会被修改。

### Vulkan、OpenGL 与真机诊断

本项目现在有两条必须分开理解的图形检查路径。

第一条是 NDK C++ 原生 GPU 预检。`libtalk2u_gpu_probe.so` 会在目标设备上：

1. 动态加载系统 `libvulkan.so`，创建 Vulkan instance。
2. 检查 `VK_KHR_surface`、`VK_KHR_android_surface`、图形队列和 `VK_KHR_swapchain`。
3. 创建并立即释放 Vulkan logical device；CPU Vulkan/SwiftShader 不算通过。
4. 无论 Vulkan 是否通过，都独立创建 EGL pbuffer，按 OpenGL ES 3、OpenGL ES 2 顺序验证 fallback；SwiftShader/软件 renderer 不算通过。
5. 每条成功或失败路径都会释放 Vulkan device/instance、EGL context/surface/display。

诊断中的“原生候选”来自这项预检。它证明设备原生 API 可以初始化，但**不证明当前 Live2D 画面由该 API 绘制**，因为预检没有加载 Cubism 模型。

第二条才是当前 Live2D 实际画面：

1. `AndroidView` 和 WebView 都启用硬件加速，并把 renderer priority 设为 `IMPORTANT`。
2. 先请求 `high-performance` 硬件 WebGL2；创建失败时改用硬件 WebGL1。
3. 拒绝 SwiftShader、llvmpipe 等软件 renderer，不把软件画面标成 Vulkan/OpenGL ES 成功。
4. WebGL context lost 时等待驱动恢复；WebGL2 恢复后使用 WebGL1 兼容模式重载。恢复超时或 WebView render process 消失时，Flutter 自动重建一次 PlatformView，并提供手动重试。
5. 模型就绪后，聊天页人物右上角出现信息图标。点开可查看 Core 版本、WebGL 版本、实际 GPU/backend、两个原生 API 的预检结果、LipSync 参数、自然动作能力和 cue 覆盖。

诊断中的 `vulkan-via-angle` 才能证明该设备这一次实际走 Vulkan；`opengl-es-via-webgl` 表示已回退 OpenGL ES；`software: true` 表示软件渲染，不应作为发布验收结果。设备声明支持 Vulkan 但诊断显示 OpenGL 并不矛盾，因为最终选择属于系统 WebView/驱动。

如果实际后端显示 `angle-backend-unspecified` 或 `webgl-driver-unspecified`，只能判定硬件 WebGL 已创建，不能判定底层是 Vulkan 还是 OpenGL ES。不要根据 Android feature、C++ 原生候选或 WebGL 版本字符串猜测后端。WebGL 版本字符串描述的是 WebGL 语义层，即使 ANGLE 底层使用 Vulkan，也可能包含 `OpenGL ES` 字样。

若产品验收条件是“应用自己控制原生 Vulkan，并在初始化失败时创建原生 OpenGL renderer”，则必须接入有合法许可的 Cubism SDK for Native 5 C++ renderer。当前仓库没有对应 Core/Framework 二进制，所以该项明确仍未完成，不能用 WebGL 后端检测冒充。

### LipSync 是怎样工作的

```text
Android 离线 TTS
  -> UtteranceProgressListener.onAudioAvailable(PCM)
  -> 按 PCM_8BIT / PCM_16BIT / PCM_FLOAT 计算 RMS
  -> Flutter EventChannel 传递 0..1 振幅
  -> Live2D PlatformView MethodChannel
  -> Cubism `beforeModelUpdate`（动作、表情、物理之后，实际绘制之前）
  -> Cubism parameterIds，例如 ParamA / ParamMouthOpenY
```

这不是随机张嘴，也没有读取麦克风来伪造朗读振幅。某些厂商 TTS 引擎虽然能朗读，却不实现 `onAudioAvailable`；这种设备上会有声音但没有 PCM 口型。请更换支持音频回调的离线 TTS 引擎或语音包。

### 动作和表情映射

模型作者应在模型根目录加入 `talk2u.avatar.json`：

```json
{
  "version": 1,
  "lipSync": {
    "parameterIds": ["ParamMouthOpenY"],
    "gain": 1.0,
    "smoothing": 0.45
  },
  "cues": {
    "greeting": {
      "motion": {"group": "Greeting", "index": 0},
      "expression": "smile"
    },
    "wave": {
      "motion": {"group": "Wave", "index": 0}
    },
    "nod": {
      "motion": {"group": "Nod", "index": 0}
    },
    "happy": {"expression": "happy"},
    "sad": {"expression": "sad"},
    "angry": {"expression": "angry"},
    "shy": {"expression": "blush"},
    "surprise": {"expression": "surprise"}
  }
}
```

支持的 cue：

```text
neutral, greeting, wave, hug, nod, happy, sad, angry, shy, surprise
```

应用会按 Android TTS 的 `onRangeStart` 从当前朗读位置触发明确动作词和常见情绪词。只有配置存在，或模型本身有可验证的同名 motion/expression，才播放对应资源。未知名称不会按序号随机猜测。

Mao 的项目配置根据 CDI3 参数名和 motion 曲线做了显式映射：`exp_02/04/05/06/08` 分别用于开心、惊讶、难过、害羞和生气；`mtn_02` 用于点头，右臂运动明显的 `mtn_04` 用于招手/问候。这些是 Talk2U 的项目映射，不是模型作者提供的语义元数据，发布前仍应在目标设备逐项观看验收。三个 `special_*` 魔法动作没有被自动解释为情绪。

### Live2D 防闪退措施

- 导入前检查 ZIP 体积、条目数量、路径和资源完整性。
- 加载前按 RGBA 解码大小估算模型内存。
- 限制单张纹理不超过 4096x4096。
- 只构建 ARM64，减少未测试 ABI 组合。
- Android WebView 开启硬件加速，并请求重要渲染进程优先级。
- C++ 分别预检 Vulkan logical device 与 EGL OpenGL ES context，不依赖功能声明猜测。
- WebGL2 创建失败时降级 WebGL1，context lost 后最多自动恢复两次。
- PCM 口型事件限制在约 30 FPS，避免高频平台通道调用拖慢 UI。
- 处理 WebView renderer 被系统回收或崩溃的回调，自动重建一次并保留手动重试。
- Flutter 对已停止的 Live2D channel 调用会被吸收，不产生未处理 Future 错误。
- 缺少 Core、模型损坏、Core 版本过低时显示真实错误。

这些措施可以消除已知的资源和生命周期崩溃路径，但任何项目都不能诚实保证在所有厂商 ROM、驱动和任意第三方模型上“绝不闪退”。真机验收仍然必须执行。

## Android 系统离线语音

### 离线 TTS

设置页的“Android 端侧语音”会显示当前选择的离线 voice 和语言。若未检测到：

1. 点击离线 TTS 右侧的语音设置图标。
2. 系统将打开 TTS 数据安装页；如果 ROM 没有该页面，则打开系统设置。
3. 在系统 TTS 引擎中安装中文离线语音包。
4. 返回应用；应用恢复前台时会重新枚举 voice，无需强制重启。
5. 设置页必须显示具体 voice 名称，聊天页朗读按钮才会启用。

代码明确排除 `isNetworkConnectionRequired == true` 的 voice，不会在“离线 TTS”名义下静默使用云端语音。

### 离线语音识别

离线 STT 的启用条件：

- Android 12 / API 31 或更高。
- `SpeechRecognizer.isOnDeviceRecognitionAvailable(context)` 返回 true。
- 已授予 `RECORD_AUDIO`。
- 系统识别服务已安装 `zh-CN` 端侧语言数据。

步骤：

1. Android 13+ 且系统声明支持模型下载时，点击离线语音识别右侧的下载图标。应用调用 `SpeechRecognizer.triggerModelDownload` 请求 `zh-CN` 模型；Android 14+ 会显示真实进度/排队/成功/错误回调。
2. Android 12 或不支持下载 API 的 ROM 会显示设置图标；进入系统语音输入设置手动安装中文离线包。
3. 回到应用后能力状态会自动刷新。
4. 首次点击麦克风按钮时允许录音权限。

应用使用 `createOnDeviceSpeechRecognizer`，并设置 `EXTRA_PREFER_OFFLINE=true`。当系统不能证明端侧识别可用时，不会回退到云端识别；若已下载 SenseVoice，则自动改用 sherpa-onnx。

厂商 ROM 的 on-device recognizer 差异很大。`triggerModelDownload` 是向系统识别服务提交请求，并不允许应用绕过厂商/Google 的模型许可自行抓取文件。若设备根本不提供 on-device 服务，可在设置页下载 SenseVoice；当前仓库不会把在线识别包装成离线能力。

## 角色、详细知识和长期对话

角色编辑页可配置名称、性别、描述、性格、背景、开场白、标签和 Live2D 模型。开始角色聊天时，角色设定作为 system 消息写入 conversation。

Rust 聊天引擎会组合：

- 角色身份锚定。
- 最近对话历史。
- 短期情绪轨迹和未展开线索。
- 长期记忆摘要。
- 与当前问题相关的本地知识事实。
- say/do 对话风格。
- 可选的推理模型结果。

详细知识对话的质量仍取决于角色资料、知识事实和所选模型。不要只写一句模糊角色简介，然后期待模型拥有未提供的专业资料。

本地数据位于应用 documents 目录。Android 正常应用无权读取其他应用的私有目录。API Key 目前也保存在应用私有 `settings.json` 中，并未接入 Android Keystore；不要在已 root、多人共用或不可信备份环境中保存高权限 Key。

## Discord 接入

仓库包含独立 Rust Discord 频道桥接。它轮询新消息，把消息送入同一个 `ChatEngine`，再把回复发回频道。

### Discord Bot 设置

1. 在 Discord Developer Portal 创建 Application 和 Bot。
2. 启用 Message Content Intent。
3. 邀请 Bot 到服务器。
4. 给目标频道授予 `View Channel`、`Read Message History`、`Send Messages`。
5. 准备一个 Talk2U 数据目录，其中 `settings.json` 已包含要使用的平台配置。

启动：

```powershell
$env:TALK2U_DISCORD_TOKEN = '<bot token>'
cargo run --manifest-path rust/Cargo.toml --bin discord_bridge -- `
  'D:\data\talk2u-discord' `
  '<channel id>'
```

继续已有 conversation：

```powershell
cargo run --manifest-path rust/Cargo.toml --bin discord_bridge -- `
  'D:\data\talk2u-discord' `
  '<channel id>' `
  '<conversation id>'
```

可选环境变量：

| 变量 | 作用 |
| --- | --- |
| `TALK2U_DISCORD_PROVIDER` | 覆盖当前供应商 ID |
| `TALK2U_DISCORD_MODEL` | 覆盖对话模型 ID |
| `TALK2U_DISCORD_ENABLE_THINKING` | `true` / `false` |
| `TALK2U_DISCORD_SYSTEM_PROMPT` | 新建 conversation 的角色提示 |
| `TALK2U_DISCORD_POLL_SECONDS` | 2-60 秒轮询间隔 |

首次启动以频道最后一条现有消息作为游标，不回复历史消息。长回复按 Unicode 字符安全分片。未发送完的分片写入 `discord_bridge_<channel>.json`，重启后继续发送。

限制：

- 这是前台轮询进程，不是 Discord Gateway。
- 它不在 Android 后台常驻。
- conversation 文件目前没有跨进程锁。不要让 Flutter 应用和 Discord bridge 同时写同一个数据目录。
- 真正的多设备同时在线需要带认证的同步服务或事务数据库。

## 测试与验收

### 自动测试

```powershell
Push-Location rust
cargo test --all-targets
Pop-Location

flutter test
flutter analyze lib test
flutter build apk --debug --target-platform android-arm64
```

Rust 测试覆盖供应商鉴权/请求转换、Anthropic 和 OpenAI-compatible SSE、跨模型上下文、记忆、知识、错误重试和 Discord 分片。Flutter 测试覆盖聊天状态竞态与动作 cue 推断。

### 没有真实 Key 时的验收边界

自动测试可以证明请求结构、上下文组装和流解析，但不能证明你的第三方账户、额度、区域网络和模型权限。至少使用一个低额度测试 Key 在真机完成一次真实请求，然后再配置其他平台。

### Android 真机验收清单

先执行仓库级静态诊断：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\tool\verify_runtime.ps1
```

完全离线发布包必须把“缺少本地 Cubism Core”从警告提升为失败：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\tool\verify_runtime.ps1 `
  -RequireOfflineCubismCore
```

该脚本读取内置 Mao 的真实 MOC3 头、CDI3、LipSync 和纹理引用；若可选 `Custom_Suiika` 存在也会一并校验。它还检查现有 APK 是否同时包含 ARM64 Flutter、Rust 和 C++ GPU probe 动态库，但不能替代 GPU、TTS 和麦克风真机检查。

- [ ] 冷启动不崩溃。
- [ ] 设置页能保存并重新读取平台配置。
- [ ] DeepSeek 能收到流式回复。
- [ ] 不新建 conversation，切到 OpenAI/Anthropic 后能回答上一轮信息。
- [ ] 安装内置 Mao 后角色页能保存模型路径。
- [ ] Live2D 状态不显示 Core/模型错误，画布持续有动画。
- [ ] 诊断中 Vulkan 和 OpenGL ES 至少一个原生预检通过。
- [ ] “实际后端”是 `vulkan-via-angle` 或 `opengl-es-via-webgl`；`unspecified` 不能作为后端验收通过。
- [ ] “GPU”不是 SwiftShader、llvmpipe 或 software renderer。
- [ ] 朗读时有声音，嘴部随实际声音变化，停止后闭合。
- [ ] 明确配置的 motion/expression 能被触发。
- [ ] 开启飞行模式后，已安装的 TTS 仍能朗读。
- [ ] 开启飞行模式后，系统声明可用的 on-device STT 仍能识别。
- [ ] 导入超大模型时被明确拒绝，而不是应用闪退。
- [ ] 切后台再返回，Live2D 和语音按钮仍可用。

观察崩溃和原生日志：

```powershell
adb logcat -c
adb logcat | Select-String -Pattern 'talk2u|chromium|AndroidRuntime|libc|flutter'
```

## 常见问题

### 平台显示“未配置”

该平台的 API Key、URL 或模型 ID 为空。自定义本地接口允许 API Key 留空，其他内置平台需要 Key。

### 401 / 403

检查 API Key、账户项目、模型权限和 endpoint。智谱 Key 需要平台提供的 `id.secret` 格式以生成 JWT。Anthropic 必须选择 Anthropic 平台，不能把 Messages URL 填到 OpenAI-compatible 自定义项后期待协议自动识别。

### 404 / model not found

URL 可能漏了 `/v1/chat/completions` 或 `/v1/messages`，也可能模型 ID 已被平台更新。在平台控制台复制当前模型 ID并覆盖默认值。

### 自定义本地 URL 在手机上连不上

不要写电脑的 `127.0.0.1`。使用电脑局域网 IP，确认服务监听 `0.0.0.0`，允许防火墙端口，并从手机浏览器或网络工具确认地址可达。

### Live2D 显示“运行库加载失败”

设备无法访问官方 CDN，并且 APK 没有本地 Cubism Core。按“安装 Cubism Core 5 供离线使用”操作后重新构建 APK。

### Live2D 显示 Core 版本低于 5

你放入的是旧 `live2dcubismcore.min.js`。从 Cubism SDK for Web 5 重新安装 Core，并清理后重建：

```powershell
flutter clean
flutter pub get
flutter build apk --debug --target-platform android-arm64
```

### 模型能朗读但不张嘴

依次检查：

1. 模型 `Groups` 是否包含 `LipSync`。
2. `.cdi3.json` 是否有 `ParamMouthOpenY`、`ParamA` 或明确嘴部参数。
3. `talk2u.avatar.json` 的 `parameterIds` 是否与模型一致。
4. 设置页的离线 TTS 是否显示具体 voice。
5. 厂商 TTS 是否真的回调 `onAudioAvailable`。

### 模型没有对应动作

给动作组和表情使用有语义的名称，或显式编写 `talk2u.avatar.json`。应用不会把未知的 `motion_01`、`motion_02` 强行解释成挥手或拥抱。

### 离线 STT 按钮不可用

设备不满足 Android 12+、端侧 recognizer 或离线中文包条件。Android 13+ 在设置页点击模型下载图标；更低版本或不支持下载 API 的 ROM 点击语音输入设置入口安装语言数据。如果系统仍报告不可用，当前版本会保持禁用而不会调用云识别。

### APK 太大

只把 `model/mao/runtime` 打进 APK。不要把 `.cmo3`、`.can3` 或大型参考模型源文件加入 `pubspec.yaml`。用户模型通过 ZIP 导入。

### PowerShell 提示“禁止运行脚本”

这是本机执行策略阻止 `.ps1` 启动，不代表脚本内容或模型校验失败。可以只为当前进程临时放行：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

然后重新运行仓库脚本。该设置只影响当前 PowerShell 窗口，关闭窗口后失效；不要为了运行本项目修改整台机器的永久策略。

## 发布注意事项

当前 `release` build 仍使用 debug signing，仅用于可安装测试包。上架前必须：

1. 创建并安全保存生产 keystore。
2. 在本机私有 `key.properties` 中配置签名，不能提交密码。
3. 修改 `android/app/build.gradle.kts` 的 release signingConfig。
4. 审核所有 Live2D 模型、Cubism Core、字体、图像和语音模型许可。
5. 提供隐私政策，说明消息会发送到用户选择的 LLM 平台。
6. 验证 API Key 本地存储策略；高安全场景应迁移到 Android Keystore。
7. 在至少一台低内存设备和一台目标主力设备完成真机清单。

## 当前不能宣称的事项

- 不能宣称 Cubism Core 已随仓库合法分发；默认仓库没有该文件。
- 不能把 C++ Vulkan/OpenGL ES 预检结果宣称为 Live2D 模型的实际渲染后端。
- 不能宣称 WebView 路径由应用强制 Vulkan 优先，或等同于官方 Cubism Native SDK 5 渲染器。
- 不能宣称所有 Android ROM 都提供离线中文 TTS/STT。
- 不能宣称未配置 `talk2u.avatar.json` 的编号动作具有某个语义。
- 不能宣称没有 API Key 时已经验证第三方真实联网回复。
- 不能宣称大型 `Custom_Suiika` 一定能在任意 Android 设备加载。
- 不能宣称 Windows WebView2 或 Linux CEF Web 宿主等同于 Live2D 原生宿主；iOS/macOS 当前没有 Live2D 宿主。
- 不能宣称 Android 已使用高通 QNN、华为 HiAI、联发科 NeuroPilot NPU，或 Windows/Linux 已支持端侧 LLM 硬件加速。
- 不能宣称当前文件存储支持多进程或多设备并发写入。

这些限制会以错误、禁用状态或导入拒绝明确呈现，而不是通过占位动画、云端回退或静态图伪造成功。
