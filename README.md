# Talk2U

Talk2U 是一个 Flutter + Rust 的本地角色聊天应用。聊天记录、角色设定、记忆和知识数据保存在本机；模型回复可以来自用户选择的联网 LLM，也可以在 Android 上由端侧 Qwen 模型生成。Android、Windows 和 Linux 默认显示 Live2D 对话界面，对话文字按需展开，文字输入始终可用。Android 语音不依赖系统 TTS/STT：识别使用应用内 sherpa-onnx + SenseVoice INT8，合成使用 MOSS-TTS-Nano + Qualcomm QNN HTP。

> 本文档既是安装说明，也是当前实现边界。请先阅读“能力状态”，再按“Windows 到 Android 真机的最短路径”操作。

## Model 内置文件夹开源模型下载链接
[下载](https://1drv.ms/f/c/716401d0cdd5bd0e/IgDdaEU7EX-mRqR-h47_q-UUAftK4GNb5I9nDv1JGAVG0ik?e=VTbi0P)

## 能力状态

| 能力 | 状态 | 实际实现 |
| --- | --- | --- |
| 智谱清言 | 已实现 | 与其它平台共用 `courierust` 传输与同一套 SSE 解析，按 OpenAI 协议直连 |
| DeepSeek | 已实现 | OpenAI-compatible SSE，支持 `deepseek-chat` / `deepseek-reasoner` |
| OpenAI | 已实现 | Chat Completions SSE，Bearer API Key |
| Anthropic | 已实现 | Messages API、`x-api-key`、`anthropic-version`、Anthropic SSE |
| Kimi | 已实现 | Moonshot OpenAI-compatible SSE |
| Qwen | 已实现 | DashScope OpenAI-compatible SSE |
| 自定义 URL | 已实现 | OpenAI-compatible；API Key 可留空，支持 HTTP(S) 完整地址 |
| 跨平台继续同一对话 | 已实现 | conversation 与供应商解耦，切换供应商不创建新会话 |
| 本地记忆/知识检索 | 已实现 | Rust 本地文件存储、短期上下文、长期摘要、知识事实检索；system 上下文按 token 预算完整保留 |
| Android 端侧 LLM | 已实现 | `Qwen/Qwen3-4B-Instruct-2507` Q4_K_M GGUF；4096 token 窗口内按 token 预算裁剪历史，单次输出上限 1024 token |
| 离线 STT | 已实现 | Android SM8850 上使用 sherpa-onnx + SenseVoice 2024-07-17 INT8 QNN context，提供 ASR/LID/SER/AED |
| 持续语音通话 | Android 有条件实现 | `CallSession` 状态机；确认硬件 AEC 后全双工，否则半双工；参考信号双讲检测 + 文本自回音过滤；可语音/点按打断 |
| 重新生成 | 已实现 | 旧回复不进入新 prompt，附带“禁止复用开头/句式/收尾”的显式指令，并以 temperature/top_p 0.95 重新采样；成功后原位替换旧消息 |
| 空闲资源占用 | 已实现 | 无 1 Hz 硬件遥测轮询、无全程 30 ms 流式定时器、非通话模式不自动合成语音 |
| Android/Windows/Linux Live2D | 有条件实现 | Android 使用 Cubism SDK for Native 5 R.5 + C++ + OpenGL ES；Windows 使用 WebView2，Linux 使用 CEF |
| Cubism 5 moc3 | 已实现 | 导入时读取 `MOC3` 头并接受 moc3 版本 1-5；运行时拒绝 Core 4 |
| `.cdi3.json` | 已实现 | 校验 Version 3，并用于发现 LipSync 参数 |
| LipSync | 已实现 | MOSS 生成 WAV 的真实 PCM 振幅包络驱动模型嘴部参数 |
| 肢体动作/表情 | 已实现，取决于模型 | 语境、emoji 与舞台指示生成 cue；同一情绪在多个等价表演间轮换，并在说话开始时维持主导情绪表情 |
| 次级动态 | 已实现 | Native renderer 在标准参数上叠加缓慢视线漂移、头部微摆与说话时的身体起伏；缺失参数会自动跳过 |
| 舞台指示静音 | 已实现 | `（哈哈大笑）`、`*挥手*` 等动作不送入 MOSS，但仍影响 Live2D cue；解释性括号保留朗读 |
| Android 离线 TTS | 有条件实现 | 导入 SM8850/HTP v81 部署包后，prefill/decode/codec 使用 QNN HTP，sampler 使用 ORT CPU；不回退系统 TTS；朗读前过滤 emoji、Markdown、代码、URL 与空行 |
| Android 离线 STT | 已实现 | SenseVoice INT8 支持中文、英文及自动语言识别；模型由应用下载、校验和管理 |
| Android NNAPI 设备诊断 | 已实现 | 枚举设备名、版本、类型和 feature level；CPU 类型不会计为加速设备 |
| 原生 Vulkan/OpenGL ES 预检 | 已实现 | NDK C++ 真实创建 Vulkan instance/device；失败时真实创建 EGL OpenGL ES 3/2 context |
| Android Live2D GPU 渲染 | 已实现 | `GLSurfaceView` 托管 Native C++ Cubism renderer，实际使用硬件 OpenGL ES；首帧成功后才报告 ready |
| 官方 Cubism Native SDK 5 渲染器 | 已集成，需外部 SDK | Gradle/CMake 从 `TALK2U_CUBISM_SDK_ROOT` 使用 Framework 与 Core；Core 不进入 Git 仓库 |
| Discord | 已实现 | 独立 Rust 轮询桥接进程，共用对话、记忆和供应商层 |
| iOS/macOS Live2D | 未实现 | 当前 Live2D 宿主只覆盖 Android、Windows 和 Linux |
| Discord Gateway/Android 常驻 Bot | 未实现 | 当前是桌面或服务器前台轮询进程 |

“已实现”不等于第三方服务永远可用。实际联网调用还需要有效 API Key、账户额度、可访问的服务地址和正确模型 ID。仓库不会内置任何 API Key。

## 研究贡献

`docs/emotion_aware_rag_paper.tex` 的 AHCA 描述的是上下文层（身份锚定、分层记忆、W-RRF 检索、情绪衰减、多样性调节）。在这之上，本仓库实现了四个此前只存在于设计里的系统级机制，每一个都有可复现的代码路径，而不是概念图：

1. **参考信号锚定的双讲检测（RATT）** — 助手自己合成音频，天然拥有回声参考。用 20 ms 振幅包络 + 180 ms 峰值保持把盲回声路径辨识降级为已知参考检测，从而与设备延迟解耦；再把平台 AEC 的 `enabled` 结果当作能力门控，决定全双工还是半双工。参见 `turn_taking.dart`、`call_session.dart`、`FullDuplexAudioCapture.kt`，推导与评测协议见 [docs/reference_anchored_turn_taking.tex](docs/reference_anchored_turn_taking.tex)。
2. **反自启动的重生成** — 旧回复被排除在新 prompt 之外（消除 self-priming），旧回复的开头/结尾/段长被写成显式反重复约束，采样温度与 top-p 同时抬高，成功后原位替换消息 ID。这解决的是“重生成等于复读”，而不是“重生成等于再采样一次”。参见 `chat_engine.rs::regenerate_response`。
3. **非语言情感转导** — MOSS 的 JNI 没有 emotion 参数，也没有 SSML。这里把 emoji 与 Markdown 结构映射为声码器可正确处理的停顿与标点，同时把同一批符号解析为主导情绪，驱动整段回复的初帧表情；纯 emoji 回复直接跳过合成。参见 `speech_text_normalizer.dart`。
4. **播放进度锚定的表演时间轴** — 用实际 WAV 的振幅包络作为时间基准，把静音舞台指示、情绪词与 emoji 偏移映射到帧级 Live2D 动作，并在同一情绪家族内轮换等价表演以避免动作重复。参见 `offline_speech_service.dart` 与 `live2d_native_renderer.cpp`。

没有语料的指标一律标为待测：RATT 的 barge-in 延迟、误打断率、自回音回合率、过抑制率都在论文小节里给出协议与消融设置，仓库不预先写死数字。

## Rust 核心的依赖边界

Rust 核心现在按“一件事一个 crate”划分，每个依赖只有唯一职责，不存在互相覆盖的第二实现：

| crate | 职责 | 落地位置 |
| --- | --- | --- |
| `courierust` | 唯一出站 HTTP/TLS 实现：SSE 增量解析、重试与去重、Android 信任锚加载 | `rust/src/api/transport.rs` |
| `rustglm` | 只提供智谱的“契约”：模型能力表、`thinking` 与流式分片的线上类型；它的 HTTP 客户端刻意不用，原因见智谱一节 | `rust/src/api/model_policy.rs` |
| `rustbinary` | 对话落盘封包（`T2UB` magic + 版本号 + 有界解码），旧格式只读迁移 | `rust/src/api/storage_codec.rs` |
| `tzcraft` | 全局时间源：128 位纳秒 `Ticks`，向下取整语义，跨平台一致 | `rust/src/api/clock.rs` |
| `recurse-x` | 独立递归 DNS：与设备解析器交叉验证，区分劫持与链路故障 | `rust/src/api/network_diagnosis.rs` |
| `nextjson` | 持久化结构的序列化 derive | `rust/src/api/data_models.rs` |

`reqwest` 与 `rustls` 已经完全不在依赖树里。智谱、DeepSeek、OpenAI、Kimi、Qwen、自定义端点全部走同一个 `courierust` 客户端；Android 上的信任锚由本仓库自己从 `/apex/com.android.conscrypt/cacerts` 与 `/system/etc/security/cacerts` 读取，因为该 crate 自带的 `load_system()` 只认 Linux 发行版的证书布局。这条加载路径就是"应用信任设备所信任的一切"（含用户手动安装的 CA）的实现。

设计取舍、迁移语义与验证命令见 [docs/rust_stack.md](docs/rust_stack.md)。

## 架构

```text
Flutter UI
  ├─ 平台/模型选择、角色、对话和记忆界面
  ├─ 默认全屏 Live2D；对话记录按需展开；文字输入常驻
  ├─ AndroidView -> GLSurfaceView -> Cubism Native C++/OpenGL ES
  ├─ Windows -> WebView2；Linux -> CEF
  ├─ Android llama.cpp/Vulkan -> Qwen3-4B-Instruct-2507 Q4_K_M（Adreno GPU）
  ├─ sherpa-onnx Kotlin/JNI + SenseVoice QNN -> SM8850 HTP 端侧 STT
  ├─ MOSS-TTS Native JNI -> QNN HTP(prefill/decode/codec) + ORT CPU(sampler)
  └─ MethodChannel -> MOSS 部署包导入、QNN 探测与 WAV 合成
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
model/Live2d/mao/runtime/       内置最小 Cubism 5 运行时模型
model/Custom_Suiika/     可选外部参考模型；仓库不要求存在，也不打进 APK
rust/src/api/            聊天、供应商、记忆、知识与存储
rust/src/connectors/     外部平台连接器
test/                    Flutter 单元测试
tools/qnn/               QNN 部署状态、检查与打包工具
```

## Windows 到 Android 真机的最短路径

### 1. 安装基础工具

需要：

- Windows 10/11 x64。
- Flutter SDK，项目当前 Dart 约束见 `pubspec.yaml`。
- Rust stable MSVC 工具链。
- Visual Studio Build Tools，包含“使用 C++ 的桌面开发”。
- JDK 17。
- Android SDK 36、Build Tools 36、NDK `28.0.12674087` 和 CMake `3.22.1`。
- 已接受相应许可的 Cubism SDK for Native 5 R.5；默认路径为 `D:\CubismSdkForNative-5`。
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

### 2. 安装 Rust Android target

当前 APK 只构建 `arm64-v8a`，这是为了减小包体和最小化原生组合数量：

```powershell
rustup target add aarch64-linux-android
```

需要 x86_64 模拟器时，必须同时完成以下三项：

1. 在 `android/app/build.gradle.kts` 的 `abiFilters` 增加 `x86_64`。
2. 从同一文件的 `packaging.jniLibs.excludes` 删除 `lib/x86_64/**`。
3. 执行 `rustup target add x86_64-linux-android`，然后使用 `--target-platform android-x64` 构建。

不要只增加其中一项。APK 中每个被声明支持的 ABI 都必须同时拥有 Flutter、Rust 和插件 JNI 库，否则会在启动时加载原生库失败。仓库内的 Cargokit 补丁只构建 Flutter 命令明确请求的架构，不会再向 debug 包偷偷追加模拟器 ABI。

### 3. 获取依赖并运行测试

```powershell
flutter pub get

Push-Location rust
cargo test --all-targets
Pop-Location

flutter test
flutter analyze lib test
```

`flutter pub get` 不能在首次构建或修改 `pubspec.yaml` 后省略。它会生成被 Git 忽略的 `.flutter-plugins-dependencies`；缺少该文件时 Dart 包可能仍能被分析，但 Android Gradle 不会注册 `rust_lib_talk2u`，最终 APK 也就没有 Rust 动态库。

### 4. 构建并安装 debug APK

Android 构建会直接从本机 Cubism SDK 读取 Framework 源码、OpenGL ES shader、头文件和 ARM64 Core 静态库。SDK 不复制进仓库；路径不同时设置：

```powershell
$env:TALK2U_CUBISM_SDK_ROOT='D:\CubismSdkForNative-5'
```

不得把 `Live2DCubismCore`、整个 Cubism SDK 或从中复制的受限文件提交到公开仓库。生成的 APK 会把本机 Core 静态链接进 `libtalk2u_live2d.so`，发布该 APK 前仍必须确认自己的 Live2D 许可允许对应分发方式。

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

### 5. 构建 Windows 和 Linux

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
| 智谱清言 | OpenAI-compatible | `https://open.bigmodel.cn/api/paas/v4/chat/completions` | `glm-4.7` |
| DeepSeek | OpenAI-compatible | `https://api.deepseek.com/chat/completions` | `deepseek-chat` |
| OpenAI | Chat Completions | `https://api.openai.com/v1/chat/completions` | `gpt-4.1-mini` |
| Anthropic | Messages API | `https://api.anthropic.com/v1/messages` | `claude-sonnet-4-5` |
| Kimi | OpenAI-compatible | `https://api.moonshot.cn/v1/chat/completions` | `moonshot-v1-8k` |
| Qwen | OpenAI-compatible | `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions` | `qwen-plus` |
| 自定义 | OpenAI-compatible | 用户填写 | 用户填写 |

> 智谱不是第二套传输层：它的端点说 OpenAI chat-completions 协议，因此与其它供应商共用同一条 `transport::post_stream` + SSE 状态机，只是 `api_url`、`api_key` 和模型 ID 不同

`rustglm` 1.1.0 仍然是依赖，但不是 HTTP 客户端——它的客户端用 `TlsSettings::with_system_roots()` 取信任锚，只认 Linux 发行版的证书布局，在 Android 上必然握手失败。它真正承担的是只有它知道的那些东西：

- `ModelCapabilities::of(model)` 决定模型是否会推理、以及 `thinking.type: "disabled"` 对它是合法参数还是 400。`glm-4.7` 与 `glm-4.7-flash` 永远思考、拒绝该字段，所以应用直接不发，而不是硬塞；旧的手写表在这点上就是错的，还额外发明了厂商类型里根本不存在的 `budget_tokens`。
- `Thinking` 负责生成精确的 `thinking` 对象，由 crate 序列化。
- `ChatCompletionChunk` 负责解码流式分片，包括 `content` 以数组分片而非字符串返回的情况。

业务错误码仍然从响应体分类，因为智谱把配额与并发问题放在 `error.code` 里而不是状态行：

| 响应 | Talk2U 错误 | 可重试 |
| --- | --- | --- |
| `error.code` 1302 / 1303 / 1305（并发、频率、过载） | 限流 | 是，带退避 |
| `error.code` 1001–1004、1110–1112、1120–1121 | 鉴权 | 否 |
| `error.code` 1113、1304、1308、1310（余额、日/周/月额度） | 智谱业务错误 | 否 |
| 无 code 的 HTTP 401/403 | 鉴权 | 否 |
| 无 code 的 HTTP 429 | 限流 | 是 |
| 无 code 的 HTTP 5xx | API 错误 | 是 |
| 非 JSON 响应体 | API 错误，body 截断到 1000 字符 | 按状态码 |

流内以 JSON `error` 对象结尾、或 `finish_reason` 为 `sensitive` 的响应，会作为流错误暴露，而不是静默返回空回复。

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

模型权重不打入 APK。SenseVoice 与 Qwen3-4B-Instruct-2507 由应用按需断点下载并校验；MOSS 使用经过验证的 HTP v81 目录，由 Android 目录选择器导入并逐文件校验。

| 用途 | 平台 | 模型 | 下载大小 |
| --- | --- | --- | ---: |
| 离线对话 | Android ARM64 | Qwen3-4B-Instruct-2507 Q4_K_M GGUF | 2,497,281,120 B |
| 离线 STT | Android SM8850/HTP v81 | SenseVoice 2024-07-17 INT8 QNN 10 秒 context | 162,023,574 B |
| 离线 TTS | Android SM8850/HTP v81 | MOSS-TTS-Nano 100M QNN 部署包 + Audio Tokenizer | 取决于准备结果 |

Qwen3-4B-Instruct-2507 模型卡声明 Apache-2.0；GGUF 固定到 `unsloth/Qwen3-4B-Instruct-2507-GGUF@a06e946b`。`sherpa-onnx` 与 MOSS 模型也需分别遵守各自许可。QAIRT/QNN 二进制受 Qualcomm SDK 条款约束，不由仓库重新分发。

### 端侧 LLM 硬件后端

| 平台/芯片 | 当前推理后端 | 当前状态 |
| --- | --- | --- |
| Android SM8850 | llama.cpp Vulkan/Adreno | 卸载 36 个 transformer block 与输出矩阵；首轮非空生成成功后才显示为已验证 |
| 其他 Android ARM64 | llama.cpp Vulkan 或 ARM64 CPU | Vulkan 不可用时明确显示 CPU/NEON，不伪报 GPU/NPU |
| iPhone/iPad | 无端侧 LLM 后端 | 当前接入只覆盖 Android |
| Windows x64/ARM64 | 无端侧 LLM 后端 | 未实现 DirectML/CUDA/Vulkan/CPU 本地推理，当前只能使用联网平台 |
| Linux x64/ARM64 | 无端侧 LLM 后端 | 未实现 CUDA/Vulkan/ROCm/CPU 本地推理，当前只能使用联网平台 |
| macOS | 无端侧 LLM 后端 | 当前只能使用联网平台 |

Android 设置页会断点下载固定版本 GGUF，校验精确大小和 SHA-256 后原子安装到应用私有目录。运行时再次校验清单、文件大小、`general.architecture=qwen3` 和 36 层结构；输入 embedding、采样与小算子留在 CPU，transformer、矩阵乘和 attention 由 Adreno Vulkan 执行。逐 token 结果通过 JNI/MethodChannel 流式送回 Flutter。

Android 不调用系统 on-device STT/TTS。MOSS 仅从带完整清单的 SM8850/HTP v81 包创建原生 session。SenseVoice 使用官方 SM8850 QNN context binary，通过 sherpa-onnx Kotlin/JNI API 的 `provider=qnn` 和 `QnnConfig` 加载；初始化或 HTP 执行失败会直接报错，不回退并伪报 QNN。

### Android MOSS-TTS 硬件执行

Android 使用与参考工程一致的 ONNX Runtime `1.26.0/API 26` core 和 QNN Plugin EP `2.4.0` 同构产物。Gradle 对 ORT core、Plugin EP 和 C API 头文件执行固定 SHA-256 校验，禁止混用 ABI。QAIRT host 库和 HTP skel 来自本机合法安装的 SDK；只有经过验证的部署才会创建 QNN session。prefill/decode 使用 QNN HTP，sampler/codec 使用 ORT CPU 多线程且不会伪报为 NPU。APK 中存在 QNN 库或 provider 可枚举，都不单独构成硬件执行证据；必须完成真机图执行验证。

MOSS 初始化会生成或复用 QNN context cache，合成时依次加载 prefill、decode/sampler、codec 并及时释放，以控制移动设备峰值内存。界面只有在真实合成返回有效 WAV 和 provider 计划后才显示已执行验证。

QAIRT 2.48 的静态化流程固定 recurrent KV 容量。V81 无法接受 sampler 的 `QNN_CumulativeSum`，因此 sampler 明确使用 ORT CPU；streaming codec 使用部署包中的固定形状 QNN HTP 图。原始动态 ONNX 不会直接送入 Android QNN runtime。

通过 `TALK2U_QNN_SDK_ROOT` 打包合法取得的 QAIRT 运行库；`TALK2U_QNN_ORT_AAR` 仅用于覆盖默认 ORT core AAR，QNN Plugin EP 仍由 Qualcomm Maven 包提供：

```powershell
$env:TALK2U_QNN_SDK_ROOT='D:\Qualcomm AI Engine Direct SDK'
$env:TALK2U_QNN_HTP_ARCH='v81'
flutter build apk --debug --target-platform android-arm64
```

应用设置页选择包含 `moss-qnn-deployment.json` 的目录后，先在 staging 目录复制并验证全部文件，再原子替换旧部署。首次初始化可能因 QNN context 生成耗时较长；后续会复用与模型哈希绑定的私有缓存。

华为 Mate 10 Pro 当前不接入许可受限的 HiAI DDK 二进制，也不使用通用 NNAPI 代替 Qualcomm QNN，因此 MOSS 在该设备上不可用。仓库没有在一加 15 或 Mate 10 Pro 上完成 MOSS 真机验收，不能把可构建路径写成真机已通过。

端侧 Qwen LLM 是独立的 llama.cpp Vulkan 推理链路，不会因为 MOSS-TTS 使用 QNN HTP 就继承其 NPU 状态。Windows/Linux 尚未接入本项目的端侧 LLM 后端。

## Live2D Cubism 5 模型与 Core

### SDK、平台链路与许可

本项目明确使用 Live2D Cubism SDK。Android 运行链路是 `AndroidView` -> `GLSurfaceView` -> `libtalk2u_live2d.so` -> Cubism SDK for Native 5 R.5 Framework/Core -> OpenGL ES。模型更新、动作、表情、物理、姿势、呼吸、眨眼、口型、纹理上传和绘制均在 Native C++ 中执行；首个无 GL 错误的真实绘制帧完成后才报告 ready。Windows/Linux 仍使用现有 WebView2/CEF + Pixi Web 链路，两类实现不能混为一谈。

Android Gradle/CMake 只从 `TALK2U_CUBISM_SDK_ROOT` 指向的本机 SDK 读取所需文件。仓库不包含、不 vendoring、也不允许提交 `Live2DCubismCore` 二进制、Core 头文件或完整 Cubism SDK。Core 会在本机构建时静态链接进 APK 的 `libtalk2u_live2d.so`；公开发布二进制前必须自行确认许可范围。

官方入口与协议：

- Live2D 官网：<https://www.live2d.com/en/>
- Live2D Proprietary Software License Agreement：<https://www.live2d.com/eula/live2d-proprietary-software-license-agreement_en.html>
- Live2D Open Software License Agreement：<https://www.live2d.com/eula/live2d-open-software-license-agreement_en.html>

Windows/Linux Web 宿主需要合法取得的 Cubism Core for Web。仓库保留 Web host 与可再分发的 Pixi 依赖，但不包含 `live2dcubismcore.min.js`；离线桌面发布时需按许可自行提供。

### 安装 Cubism Core 5 供 Windows/Linux Web 宿主离线使用

1. 从 <https://www.live2d.com/en/sdk/download/web/> 下载 Cubism SDK for Web 5。
2. 阅读 SDK 和 Cubism Core 的许可条款。
3. 解压 SDK。
4. 将 SDK 中对应的 Core 文件放到：

```text
assets/live2d/vendor/live2dcubismcore.min.js
```

然后重新构建桌面应用。不要把该文件提交或公开分发，除非你的许可明确允许。Android Native 构建不使用这个 JavaScript 文件。

### 最小可运行模型：虹色 Mao

仓库已包含 Live2D 官方示例模型“虹色 Mao”的 runtime 文件：

```text
model/Live2d/mao/runtime/
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

示例模型许可原文摘要和官方链接在 `model/Live2d/mao/ReadMe.txt`。商业使用前必须自行确认当前许可。

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

导入器会在应用内完成上述结构、资源、moc3、`.cdi3.json` 与 LipSync 校验；无效 ZIP 不会进入运行时目录。

### `model/` 中的两个模型

| 目录 | MOC/CDI | LipSync | 运行时资源 | Android 默认打包 |
| --- | --- | --- | --- | --- |
| `model/Live2d/mao/runtime` | MOC3 v5 / CDI3 v3 | `ParamA` | 1 张 4K 纹理、7 动作、8 表情 | 是 |
| 可选 `model/Custom_Suiika` | MOC3 v5 / CDI3 v3 | CDI3 中的 `ParamMouthOpenY` | 外部模型包，内容取决于用户提供的版本 | 否 |

`Custom_Suiika` 不随仓库分发。若自行放入大型版本，其多张 2K 纹理在解码后的 GPU/CPU 内存会远大于压缩文件体积；默认打进 APK 会显著增大安装包，并可能在中低端 Android 设备上触发内存回收。因此它只能作为可选导入参考，必须先用打包脚本生成 ZIP，再由目标设备的内存校验决定能否加载。

`.vtube.json` 等 VTube Studio 附加文件会保留在 ZIP 中，但当前运行时不解析 VTube Studio 的摄像头追踪和热键协议。导入 `Custom_Suiika` 这类包时，导入器会把未引用的 Idle 和表情文件补进应用私有目录中的 `.model3.json`；原始 `model/` 文件不会被修改。

### Vulkan、OpenGL 与真机诊断

Android Live2D 的实际 renderer 是 Cubism Native OpenGL ES，不经过 WebView、WebGL 或 ANGLE。`GLSurfaceView` 请求 RGBA8888、16-bit depth 的 OpenGL ES 2 context；Native 层读取 `GL_RENDERER`/`GL_VENDOR`/`GL_VERSION`，拒绝 SwiftShader、llvmpipe、softpipe、lavapipe 和标记为 software 的实现。Cubism shader 从外部 SDK 的 `StandardES` 目录打包为只读 asset，并由 R.5 file loader 加载。每帧执行 Framework 的 begin/end frame 生命周期并检查 GL error，首帧成功前不会把模型标为 ready。

独立的 NDK C++ GPU 预检 `libtalk2u_gpu_probe.so` 会在目标设备上：

1. 动态加载系统 `libvulkan.so`，创建 Vulkan instance。
2. 检查 `VK_KHR_surface`、`VK_KHR_android_surface`、图形队列和 `VK_KHR_swapchain`。
3. 创建并立即释放 Vulkan logical device；CPU Vulkan/SwiftShader 不算通过。
4. 无论 Vulkan 是否通过，都独立创建 EGL pbuffer，按 OpenGL ES 3、OpenGL ES 2 顺序验证 fallback；SwiftShader/软件 renderer 不算通过。
5. 每条成功或失败路径都会释放 Vulkan device/instance、EGL context/surface/display。

诊断中的 Vulkan/OpenGL 预检只说明设备 API 能否初始化。当前 Live2D 画面的证据来自同一 Native renderer 报告的 `Cubism Native OpenGL ES`、实际 GL renderer 字符串和递增的 `frameCount`。设备即使通过 Vulkan 预检，Live2D 也仍是 OpenGL ES；当前没有 Cubism Vulkan renderer，不能把预检结果写成实际 Vulkan 渲染。

本次真机验收设备为 PLK110、SM8850、Android API 36、Adreno 840。Mao 已实际显示并持续动画；两张采样截图的舞台像素有 18.113% 变化，图形统计为 653 帧、0.46% jank、GPU median 3 ms。该结果只证明这台设备和当前构建，不自动覆盖其他 ROM、GPU 驱动或第三方模型。

### LipSync 是怎样工作的

```text
MOSS QNN/ORT 合成
  -> 48 kHz PCM16 WAV
  -> Flutter isolate 按 20 ms 窗口计算 RMS
  -> 播放进度同步 0..1 振幅
  -> Live2D PlatformView MethodChannel
  -> Native C++ Cubism model update（动作、表情、物理之后，实际绘制之前）
  -> Cubism parameterIds，例如 ParamA / ParamMouthOpenY
```

这不是随机张嘴，也没有读取麦克风来伪造朗读振幅。振幅直接来自当前 MOSS 输出 WAV，因此不受厂商系统 TTS 回调能力影响。

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
neutral, calm, greeting, wave, hug, nod, listening,
happy, happySoft, excited, sad, sadSoft, sigh,
angry, angrySoft, shy, shySoft, surprise, surpriseSoft,
thinking, thinkingSoft, talking, talkingSoft, emphasis, dramatic
```

应用会按 MOSS WAV 的播放进度映射到当前文本位置，触发明确动作词、常见情绪词和 emoji 情绪。同一情绪在一次长回复中会轮换到等价的次级表演（例如 `happy` → `happySoft` → `excited`），避免每句话都重复同一个动作。模型没有定义某个变体时，Kotlin 层会回退到基础 cue；导入模型若完全没有 `talk2u.avatar.json`，只为 `neutral/talking/nod/listening` 这类结构性状态生成保守映射，不会把任意动作伪装成情绪。

Mao 的项目配置根据 CDI3 参数名和 motion 曲线做了显式映射：`exp_02/04/05/06/08` 分别用于开心、惊讶、难过、害羞和生气；`mtn_02` 用于点头，右臂运动明显的 `mtn_04` 用于招手/问候。这些是 Talk2U 的项目映射，不是模型作者提供的语义元数据，发布前仍应在目标设备逐项观看验收。三个 `special_*` 魔法动作没有被自动解释为情绪。

Native renderer 还会在标准参数存在时叠加一层轻量次级动态：缓慢的视线漂移、头部微摆，以及说话时随口腔能量变化的身体起伏。它们只使用 `ParamAngleX/Y/Z`、`ParamBodyAngleX/Z`、`ParamEyeBallX/Y`，模型未导出对应参数时自动跳过，因此不会破坏第三方模型的骨架。

### 语音文本净化与情绪

朗读前，回复会经过确定性文本净化，而不是直接把 Markdown 送进声码器：

- 移除 `<think>` / `<analysis>` 等推理块、围栏代码块、行内代码、URL、邮箱、HTML 和 emoji 短代码。
- 移除 Markdown 标题、列表符号、引用符号、表格分隔线、强调符号；保留链接文字。
- emoji 不朗读，但会转成停顿或情绪标记并参与主导情绪判断；纯 emoji 回复直接跳过朗读。
- 连续空行压缩为句号停顿，不把换行符送进 MOSS；省略号和重复标点会归一到自然停顿。
- `（哈哈大笑）`、`*挥手*` 等舞台指示静音，但保留时间偏移供 Live2D 使用；解释性括号（如 `NNAPI（神经网络 API）`）仍然朗读。

主导情绪会决定整段回复的第一帧表情，随后再由逐句 cue 接管。MOSS-TTS-Nano 的公开 JNI 只接受文本与音色，没有独立 emotion 参数，因此语音情绪通过两条可靠路径实现：保留模型写出的情绪标点，以及把 emoji 映射为 `，`、`……`、`！`、`？` 这类可被声码器正确处理的停顿；不会伪造模型不支持的 SSML 或情绪权重。

### Live2D 防闪退措施

- 导入前检查 ZIP 体积、条目数量、路径和资源完整性。
- 加载前按 RGBA 解码大小估算模型内存。
- 限制单张纹理不超过 4096x4096。
- 只构建 ARM64，减少未测试 ABI 组合。
- Android Native renderer 拒绝已知软件 OpenGL 实现，并在首帧检查 GL error。
- C++ 分别预检 Vulkan logical device 与 EGL OpenGL ES context，不依赖功能声明猜测。
- `GLSurfaceView` 生命周期与 Activity 绑定，surface/context 重建时重新创建 Cubism 图形资源。
- PCM 口型事件限制在约 30 FPS，避免高频平台通道调用拖慢 UI。
- Flutter 对已停止的 Live2D channel 调用会被吸收，不产生未处理 Future 错误。
- 缺少 Core、模型损坏、Core 版本过低时显示真实错误。

这些措施可以消除已知的资源和生命周期崩溃路径，但任何项目都不能诚实保证在所有厂商 ROM、驱动和任意第三方模型上“绝不闪退”。真机验收仍然必须执行。

## Android 应用内离线语音

### SenseVoice STT

设置页下载并校验官方 `sherpa-onnx-qnn-SM8850-binary-10-seconds-sense-voice-zh-en-ja-ko-yue-2024-07-17-int8` 后，应用通过 sherpa-onnx Kotlin/JNI 在 QNN HTP 上识别。录音固定为 16 kHz、PCM16、单声道并限制为 10 秒；结果完整保留转写文本、语种、情感和音频事件字段。

识别完全由应用管理，不依赖 `SpeechRecognizer`、Google 语音服务或厂商 ROM 的离线语言包。首次录音仍需授予 `RECORD_AUDIO`。

### MOSS-TTS

设置页的文件夹按钮用于导入准备好的 `moss-qnn-v81` 目录。目录必须包含 `moss-qnn-deployment.json`、MOSS TTS/codec 元数据、tokenizer、共享权重和 `.qnn.onnx` 图。导入器拒绝目录穿越、版本不匹配、错误 SoC/HTP 架构、缺失文件、大小或 SHA-256 不匹配。

成功导入后可选择 MOSS 内置中英文音色并试听。系统 TTS 不再作为后备路径；QNN 初始化或合成失败会直接显示错误。

### 连续对话与打断

连续通话只在 Android 上可用，要求同一设备同时具备可用的 SenseVoice 与 MOSS，并且通话逻辑集中在 `CallSession` 状态机里（idle / listening / thinking / speaking / halted），不再散落在页面布尔量中。

**回声消除是真实能力，不是声明。** 采集走独立通道 `FullDuplexAudioCapture`：`AudioRecord` + `VOICE_COMMUNICATION` 源，把平台 `AcousticEchoCanceler` 附着到真实 audio session，并回读 `enabled` 结果；`NoiseSuppressor`、`AutomaticGainControl` 同样逐个核实。只有确认拿到回声消除，才启用全双工：

| 平台测量结果 | 运行模式 | 播放期间麦克风 |
| --- | --- | --- |
| AEC 已附着且 `enabled == true` | 全双工 | 保持开启，可被语音打断 |
| AEC 不可用或被拒 | 半双工 | 关闭，播完再开 |

界面状态栏会显示当前是哪种模式，避免把“设备不支持”误判成“打断失灵”。

全双工的判定不是简单阈值，而是**以自身播放为参考信号**的双讲检测（`ReferenceAnchoredEchoGate`）：合成音频的 20 ms 振幅包络就是已知参考，用 180 ms 峰值保持消除设备相关的 20–120 ms 延迟影响，得到残差回声预测 `E = λ·R`，只有观测能量连续 140 ms 超过 `max(噪声底×3.2, 1.6E + 0.012)` 才判定用户在说话。硬件 AEC 生效时 λ = 0.18，否则 0.55。参数与推导写在 [docs/reference_anchored_turn_taking.tex](docs/reference_anchored_turn_taking.tex)。

能量判定回答“什么时候让路”，不回答“这段转写是不是用户说的”。因此还有第二道闸：`SelfEchoTranscriptFilter` 用字符二元组 Dice 系数比对最近 8 秒内真正播放过的文本，相似度 ≥ 0.6 或长度 ≥ 8 的子串直接丢弃，短于 6 个有效字符不参与判定，避免把用户一句“好的”误杀。

打断路径：

1. 直接开口：能量双讲检测触发，立即停播并回到监听，转写随后进入正常回合。
2. 点按 Live2D 或麦克风：停止播放与生成，通话模式下手动收回话轮。
3. 输入框发送文字：停播并标记“等待回复”，不会在生成期间误开麦克风。

状态机还有两个针对全双工的守卫：派发话轮后 900 ms 内忽略能量打断（否则上一句的录音尾巴会取消它刚触发的回复）；`thinking` 阶段参考信号为零，任何持续人声都判定为真打断，因此生成过程中也能被叫停。若 120 秒内没有任何回合推进，自动收回话轮。

### 重新生成语义

“重新生成”不是把同一 prompt 再发一次。Rust 侧会：

- 从上下文中排除被拒绝的旧回复，避免模型顺着旧答案续写或改写。
- 把旧回复的开头、结尾、段落数和平均句长写入显式的反重复指令。
- 追加一个基于时间轮换的创作方向（换切入点、更克制、更口语、先动作后展开等）。
- 使用 `temperature=0.95`、`top_p=0.95` 重新采样。
- 成功后原位替换旧消息并保留消息 ID；失败或取消时旧回复保持不变，不会出现“回答被删掉但新回答没来”的空窗。

如果用户重新生成的是更早的回复，UI 会先回滚到该消息，再由 Rust 追加新回复；这条路径会丢失“旧回复文本”作为反重复参考，但仍保留显式的新方向指令与更高采样温度。

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

先执行仓库级检查和 Android 构建：

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub
Push-Location android
.\gradlew.bat :app:assembleDebug -Ptarget-platform=android-arm64 --no-daemon
Pop-Location
git diff --check
git ls-files | Select-String -Pattern 'Live2DCubismCore|live2dcubismcore'
tar -tf .\build\app\outputs\apk\debug\app-debug.apk
```

`git ls-files` 不应返回 Cubism Core。APK 应包含 `libtalk2u_live2d.so` 和 Cubism `StandardES` shader，但不应包含独立的 `libLive2DCubismCore.so`。静态检查不能替代 GPU、TTS、LLM 和麦克风真机检查。

- [ ] 冷启动不崩溃。
- [ ] 设置页能保存并重新读取平台配置。
- [ ] DeepSeek 能收到流式回复。
- [ ] 不新建 conversation，切到 OpenAI/Anthropic 后能回答上一轮信息。
- [ ] 安装内置 Mao 后角色页能保存模型路径。
- [ ] Live2D 状态不显示 Core/模型错误，画布持续有动画。
- [ ] 诊断中 Vulkan 和 OpenGL ES 至少一个原生预检通过。
- [ ] “实际后端”是 `Cubism Native OpenGL ES`，`frameCount` 持续递增。
- [ ] “GPU”不是 SwiftShader、llvmpipe 或 software renderer。
- [ ] 朗读时有声音，嘴部随实际声音变化，停止后闭合。
- [ ] `女生：（哈哈大笑）你说的太好了！` 只朗读“你说的太好了！”，同时触发 happy cue。
- [ ] 持续通话能完成“监听 -> 最终识别 -> 生成 -> 朗读 -> 恢复监听”至少 20 轮，结束后麦克风和播报均停止。
- [ ] Qwen 首轮真实生成后显示 `Qualcomm QNN HTP/NPU`，未验证时不能进入端侧对话。
- [ ] MOSS 实际合成后只显示 `QNN_HTP`；“候选”、NNAPI 名称或库存在不能作为硬件验收通过。
- [ ] NNAPI 诊断不把类型为 CPU 的设备列为非 CPU 加速设备。
- [ ] 明确配置的 motion/expression 能被触发。
- [ ] 开启飞行模式后，已安装的 TTS 仍能朗读。
- [ ] 开启飞行模式后，已安装的 SenseVoice 仍能识别中文和英文。
- [ ] 导入超大模型时被明确拒绝，而不是应用闪退。
- [ ] 切后台再返回，Live2D 和语音按钮仍可用。

观察崩溃和原生日志：

```powershell
adb logcat -c
adb logcat | Select-String -Pattern 'Talk2U|Cubism|QNN|AndroidRuntime|libc|flutter'
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

### Android 构建提示缺少 Cubism SDK

确认 `TALK2U_CUBISM_SDK_ROOT` 指向完整的 Cubism SDK for Native 5 R.5，且其中存在 `Core/include`、`Core/lib/android/arm64-v8a`、`Framework` 和 OpenGL sample 的 `stb_image.h`。默认检查 `D:\CubismSdkForNative-5`。

### Live2D 显示 Core 版本低于 5

Android 使用的外部 Native SDK Core 过旧或与 Framework 不匹配。使用同一套 Cubism SDK for Native 5 R.5 的 Core 与 Framework，清理后重建：

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
4. 设置页是否显示 MOSS voice 与实际 provider。
5. 生成的 WAV 是否有效且振幅包络非空。

### 模型没有对应动作

给动作组和表情使用有语义的名称，或显式编写 `talk2u.avatar.json`。应用不会把未知的 `motion_01`、`motion_02` 强行解释成挥手或拥抱。

### 离线 STT 按钮不可用

在设置页安装 SenseVoice QNN 包，并授予麦克风权限。模型文件必须完整包含 `model.bin`、`tokens.txt` 与 Talk2U 安装清单；该 context 仅适用于 SM8850/HTP v81。

### APK 太大

只把 `model/Live2d/mao/runtime` 打进 APK。不要把 `.cmo3`、`.can3` 或大型参考模型源文件加入 `pubspec.yaml`。用户模型通过 ZIP 导入。

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

- 不能宣称 Cubism Core 已随公开仓库合法分发；Android Core 只来自构建者本机接受许可后的外部 SDK。
- 不能把 C++ Vulkan 预检结果宣称为 Live2D 模型的实际渲染后端；Android 当前实际使用 Cubism Native OpenGL ES。
- 不能宣称所有 Android ROM 都提供离线中文 TTS/STT。
- 不能宣称未配置 `talk2u.avatar.json` 的编号动作具有某个语义。
- 不能宣称没有 API Key 时已经验证第三方真实联网回复。
- 不能宣称大型 `Custom_Suiika` 一定能在任意 Android 设备加载。
- 不能宣称 Windows WebView2 或 Linux CEF Web 宿主等同于 Live2D 原生宿主；iOS/macOS 当前没有 Live2D 宿主。
- 不能仅凭库存在、provider 枚举或 NNAPI 设备枚举宣称 MOSS 已使用 NPU；必须有禁用 CPU EP 回退的真实合成结果 `QNN_HTP`。
- 不能宣称仓库默认 ONNX Runtime AAR 已包含 QNN EP，不能宣称已直接接入华为 HiAI DDK，也不能宣称一加 15 或 Mate 10 Pro 已实机通过。
- 不能宣称 Windows/Linux 已完成端侧 TTS、持续离线通话或端侧 LLM 硬件加速。
- 不能宣称当前文件存储支持多进程或多设备并发写入。

这些限制会以错误、禁用状态或导入拒绝明确呈现，而不是通过占位动画、云端回退或静态图伪造成功。
