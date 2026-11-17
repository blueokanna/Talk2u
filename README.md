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
| 本地记忆/知识检索 | 已实现 | Rust 本地文件存储、短期上下文、长期摘要、知识事实检索；system 上下文按 token 预算保留，超长人设从尾部裁剪 |
| Android 端侧 LLM | 已实现 | 去审查 `huihui-ai/Huihui-Qwen3-4B-Instruct-2507-abliterated` 的编译产物，以及上游 `Qwen/Qwen3-4B-Instruct-2507`（QAIRT w4a16 → NPU，或 GGUF → Hexagon NPU；Q4_0/Q8_0 为纯 HTP）；GenieX SDK 0.3.17，4096 token 窗口内按 token 预算裁剪历史；输出预算由实际 prompt 动态计算（512–3072 token），不再固定占 1024 |
| 离线 STT | 已实现 | Android SM8850 上使用 sherpa-onnx + SenseVoice 2024-07-17 INT8 QNN context，提供 ASR/LID/SER/AED |
| 持续语音通话 | Android 有条件实现 | `CallSession` 状态机；确认硬件 AEC 后全双工，否则半双工；参考信号双讲检测 + 文本自回音过滤；可语音/点按打断 |
| 重新生成 | 已实现 | 旧回复不进入新 prompt，附带“禁止复用开头/句式/收尾”的显式指令，并以 temperature/top_p 0.95 重新采样；成功后原位替换旧消息 |
| 空闲资源占用 | 已实现 | 启动只探测 MOSS/QNN 能力，首次朗读才加载 HTP 上下文；无 1 Hz 硬件遥测轮询、无全程 30 ms 流式定时器、非通话模式不自动合成语音；Live2D 在后台、离页或系统要求减少动画时停止持续渲染；流式增量在后台只入缓冲，回前台一次性重绘；`onTrimMemory` 会清空 Flutter 图片缓存与未被播放的合成 WAV，临界时释放 QNN/ORT session |
| Android/Windows/Linux Live2D | 有条件实现 | Android 使用 Cubism SDK for Native 5 R.5 + C++ + OpenGL ES；Windows 使用 WebView2，Linux 使用 CEF |
| Cubism 5 moc3 | 已实现 | 导入时读取 `MOC3` 头并接受 moc3 版本 1-5；运行时拒绝 Core 4 |
| `.cdi3.json` | 已实现 | 校验 Version 3，并用于发现 LipSync 参数 |
| LipSync | 已实现 | MOSS 生成 WAV 的真实 PCM 振幅包络驱动模型嘴部参数 |
| 肢体动作/表情 | 已实现，取决于模型 | 语境、emoji 与舞台指示生成 cue；同一情绪在多个等价表演间轮换，并在说话开始时维持主导情绪表情 |
| 次级动态 | 已实现 | Native renderer 在标准参数上叠加缓慢视线漂移、头部微摆与说话时的身体起伏；缺失参数会自动跳过 |
| 舞台指示静音 | 已实现 | `（哈哈大笑）`、`*挥手*` 等动作不送入 MOSS，但仍影响 Live2D cue；解释性括号保留朗读 |
| Android 离线 TTS | 有条件实现 | 导入 SM8850/HTP v81 部署包后，prefill/decode 使用 QNN HTP，sampler/codec 使用 ORT CPU；不回退系统 TTS；朗读前过滤 emoji、Markdown、代码、URL 与空行 |
| Android 离线 STT | 已实现 | SenseVoice INT8 支持中文、英文及自动语言识别；模型由应用下载、校验和管理 |
| Android NNAPI 设备诊断 | 已实现 | 枚举设备名、版本、类型和 feature level；CPU 类型不会计为加速设备 |
| 原生 Vulkan/OpenGL ES 预检 | 已实现 | NDK C++ 真实创建 Vulkan instance/device；失败时真实创建 EGL OpenGL ES 3/2 context |
| Android Live2D GPU 渲染 | 已实现 | `GLSurfaceView` 托管 Native C++ Cubism renderer，实际使用硬件 OpenGL ES；首帧成功后才报告 ready |
| Android 前置摄像头视线跟随 | 已实现，需用户主动开启 | Camera2 硬件人脸检测（SIMPLE/FULL 模式）；只读取每帧的人脸包围盒并立即释放，不保存、不上传图像；坐标经屏幕方向与镜像归一化后驱动 Live2D 视线，后台、切页或关闭立即释放摄像头 |
| 真人/活体识别 | 未实现，且不声称 | 普通 RGB 人脸检测无法区分照片、屏幕或面具；代码中 `livenessVerified` 恒为 `false`，界面只表述“检测到人脸” |
| 官方 Cubism Native SDK 5 渲染器 | 已集成，需外部 SDK | Gradle/CMake 从 `TALK2U_CUBISM_SDK_ROOT` 使用 Framework 与 Core；Core 不进入 Git 仓库 |
| Discord | 已实现 | 独立 Rust 轮询桥接进程，共用对话、记忆和供应商层 |
| iOS/macOS Live2D | 未实现 | 当前 Live2D 宿主只覆盖 Android、Windows 和 Linux |
| Discord Gateway/Android 常驻 Bot | 未实现 | 当前是桌面或服务器前台轮询进程 |

“已实现”不等于第三方服务永远可用。实际联网调用还需要有效 API Key、账户额度、可访问的服务地址和正确模型 ID。仓库不会内置任何 API Key。

## 研究贡献

`docs/emotion_aware_rag_paper.tex` 的 AHCA 描述的是上下文层（身份锚定、分层记忆、W-RRF 检索、情绪衰减、多样性调节）。在这之上，本仓库实现了四个此前只存在于设计里的系统级机制，每一个都有可复现的代码路径，而不是概念图：

1. **参考信号锚定的双讲检测（RATT）** — 助手自己合成音频，天然拥有回声参考。用 20 ms 振幅包络 + 180 ms 峰值保持把盲回声路径辨识降级为已知参考检测，从而与设备延迟解耦；再把平台 AEC 的 `enabled` 结果当作能力门控，决定全双工还是半双工。参见 `turn_taking.dart`、`call_session.dart`、`FullDuplexAudioCapture.kt`，推导与评测协议见 [docs/reference_anchored_turn_taking.tex](docs/reference_anchored_turn_taking.tex)。
2. **反自启动的重生成** — 旧回复被排除在新 prompt 之外（消除 self-priming），旧回复的开头/结尾/段长被写成显式反重复约束，采样温度与 top-p 同时抬高，成功后原位替换消息 ID。这解决的是“重生成等于复读”，而不是“重生成等于再采样一次”。参见 `chat_engine.rs::regenerate_response_with_snapshot`。
3. **非语言情感转导** — MOSS 的 JNI 没有 emotion 参数，也没有 SSML。这里把 emoji 与 Markdown 结构映射为声码器可正确处理的停顿与标点，同时把同一批符号解析为主导情绪，驱动整段回复的初帧表情；纯 emoji 回复直接跳过合成。参见 `speech_text_normalizer.dart`。
4. **播放进度锚定的表演时间轴** — 用实际 WAV 的振幅包络作为时间基准，把静音舞台指示、情绪词与 emoji 偏移映射到帧级 Live2D 动作，并在同一情绪家族内轮换等价表演以避免动作重复。参见 `offline_speech_service.dart` 与 `live2d_native_renderer.cpp`。

没有语料的指标一律标为待测：RATT 的 barge-in 延迟、误打断率、自回音回合率、过抑制率都在论文小节里给出协议与消融设置，仓库不预先写死数字。

## Rust 核心的依赖边界

Rust 核心现在按“一件事一个 crate”划分，每个依赖只有唯一职责，不存在互相覆盖的第二实现：

| crate | 职责 | 落地位置 |
| --- | --- | --- |
| `courierust` | 唯一出站 HTTP/TLS 实现：SSE 增量解析、重试与去重、Android 信任锚加载 | `rust/src/api/transport.rs` |
| `rustglm` | 只提供智谱的“契约”：模型能力表、`thinking` 与流式分片的线上类型；它的 HTTP 客户端刻意不用，原因见智谱一节 | `rust/src/api/model_policy.rs` |
| `rustbinary` | 对话落盘封包（`T2UB` magic + 版本号 + 有界解码），旧格式只读迁移；v2 增加 zlib 压缩 | `rust/src/api/storage_codec.rs` |
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
  ├─ Android GenieX SDK -> QAIRT QNN HTP/NPU，或 llama.cpp -> Hexagon NPU -> Qwen3-4B（去审查或上游）
  ├─ sherpa-onnx Kotlin/JNI + SenseVoice QNN -> SM8850 HTP 端侧 STT
  ├─ MOSS-TTS Native JNI -> QNN HTP(prefill/decode) + ORT CPU(sampler/codec)
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

为避免上下文无限膨胀，请求层按 token 预算选择最近历史（最多 200 条，云端上限 80K token），更早的信息交给长期摘要、事实分层与知识检索；历史文件本身不会因为这个窗口被删除。

### 本地存储与长上下文

- `T2UB` v2 先用 `rustbinary` 生成紧凑二进制，再按实际收益选择 zlib 封装；头部记录解压后长度，解码时同时受 64 MiB 上限和声明长度校验，压缩炸弹不会进入反序列化。v1 文件保持只读兼容，首次写入自动升级。
- 每个对话旁的 `.t2ui` 是派生摘要缓存（标题、最后一句预览、模型、时间）。会话列表只读这个几十字节的文件，不再为了显示一行预览而解压全部消息；缓存缺失或损坏时回退到完整解码并重建。
- `MemoryEngine` 的长期摘要、事实层级和检索仍然独立于对话文件：历史窗口被裁剪不等于历史被删除，后续轮次可以直接继续同一 conversation。
- 端侧 Qwen 的 transformer KV cache 由 GenieX 持有，应用无法读取或复用；这里优化的是 prompt 预算、上下文选择和落盘成本，不把它包装成“KV cache 复用”。当前 native 会话每轮仍由运行时管理 KV 生命周期。

### 长回复不静默截断

- 端侧 Qwen 不再固定预留 1024 token：每轮按 `4096 - 实际 prompt - 128` 计算输出预算，短上下文最多 3072 token，长上下文仍保底 512 token；超长 system prompt 从尾部裁剪，不会挤掉最近的用户问题。
- 云端在收到 `finish_reason: "length"`（OpenAI-compatible）或 `stop_reason: "max_tokens"`（Anthropic）时，Rust 会自动发起最多 2 次续写：把已生成内容末尾最多 3000 字作为 assistant 前缀，附一条“从截断处继续、不要重复”的系统指令和一次仅存在于请求中的“继续。”，再把新增 delta 接到同一条回复。续写消息不落盘，最终只发一个 `Done`。
- 续写失败不会丢弃已经拿到的长回复；达到 64K 字符或连续两次没有增长也会停止，避免无限循环。单次输出的硬上限仍然由云端模型与 `max_tokens` 决定，不能诚实地宣称“无限长度”。

## 设计系统：Material 3 Expressive

界面只使用 Material 3 / Material 3 Expressive 组件。完整规则见 [docs/design_system.md](docs/design_system.md)，实现集中在三处：

- `lib/src/theme/app_shapes.dart`：M3 shape scale（4 / 8 / 12 / 16 / 28 / stadium），语义角色（`surface`、`overlay`、`field`、`sheet`、`drawer`、`fab`、`pill`、`badge`、气泡）全部使用 `RoundedSuperellipseBorder`；页面里不再出现手写圆角。
- `lib/src/theme/app_motion.dart`：直接引用 Flutter 导出的 `Durations` 与 `Easing`，共享轴页面转场前进 400 ms、返回 300 ms；`FluidSwitcher` 负责同一页面内的内容穿梭；减弱动效时直接渲染终值。
- `lib/src/rendering/aurora_engine.dart` + `lib/src/widgets/aurora_backdrop.dart`：整个 App 共用一个 `Ticker`，相位以 30 Hz 广播；极光层在主题/尺寸稳定后一次性光栅化为 `ui.Image`（逻辑尺寸 55%），之后每帧只做一次平移 blit；主题动画期间用 180 ms 去抖避免逐帧重建；后台与减弱动效时停表并停在 30% 的确定性相位。

组件层面：思考面板用 M3 Expressive 的 `Expansible`，消息动作用 `ActionChip`，模型安装动作用 `MenuAnchor`，底部面板拖拽条交给 `BottomSheetThemeData`，不再手写装饰。

设置页的端侧模型卡片同时列出 `Qwen/Qwen3-4B-Instruct-2507` 与去审查衍生版，上游排在前：上游 checkpoint 保留 AI Hub 下载，两者都可以导入 QAIRT 或 GGUF。安装目标由用户显式选择，不再用一个“the model”条目掩盖上游模型。

验证：`dart analyze lib test`、`flutter test`。`test/rendering/design_system_test.dart` 锁定 shape scale 数值、30 Hz 通知上限、减弱动效停表，以及 `FluidSwitcher` 在切换前后的图层数量。

## 依赖策略

Dart 直接依赖跟随最新稳定版（`dart pub outdated` 的 direct dependencies 为空），但有三个明确的钉子：

- `flutter_rust_bridge` 固定 `2.13.0`：`lib/src/rust/**` 与 `rust/src/frb_generated.rs` 由同一版本的生成器产出，运行时还会校验版本；升级必须整条链一起重生成，不能只改 pubspec。
- `intl` 保持 `any`：版本由 `flutter_localizations` 决定，手写约束只会和 Flutter SDK 打架。
- 原 `flutter_markdown` 已停止维护，改用其维护分支 `flutter_markdown_plus 1.0.12`，`MarkdownBody`/`MarkdownStyleSheet` API 不变。

Rust 直接依赖同样取最新稳定版；`cargo update` 负责传递依赖。`jni = 0.22.4` 是精确钉子（JNI ABI），`libc` 只用于 Android 的被动 GGML 探针。没有 `dependency_overrides`：传递依赖的版本是 pub/cargo 求解器在 Flutter SDK 与插件约束下算出的结果，不靠覆盖强行抬高。

## 仓库目录

```text
android/                 Android 原生 TTS/STT、Live2D PlatformView
assets/live2d/           桌面 Web 宿主目录（需自行按许可放置 index.html 与 Core JS，仓库不提供）
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

### 16 KB 页大小兼容（Google Play 强制项）

从 2025-11-01 起，面向 Android 15+ 的新提审与更新必须支持 16 KB 页。它对原生代码是两条独立的硬约束，只改一条不算通过：

1. **ELF 可加载段对齐**：每个 `PT_LOAD` 的 `p_align ≥ 16384` 且为 2 的幂，`p_vaddr - p_offset` 按 16 KB 同余。
2. **安装包内布局**：未压缩的 `lib/*.so` 在 ZIP 中的数据偏移必须 16 KB 对齐（`zipalign -P 16`）；一旦改为压缩打包（由系统解压到 `nativeLibraryDir`），约束落在解压后的 ELF 上。

本仓库的落地方式：

- `android/app/src/main/cpp/CMakeLists.txt` 用 `add_link_options` 给所有共享目标加 `-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384`，覆盖 MOSS/QNN/Live2D/探针等全部自建库。
- Rust 侧同时写进 `rust/.cargo/config.toml` 与 Cargokit 的 `android_environment.dart`。后者必须改，因为 `CARGO_ENCODED_RUSTFLAGS` 会**整体覆盖** Cargo 配置文件中的 target rustflags；只写 config.toml 时 Flutter 构建出来的 `librust_lib_talk2u.so` 会是 4 KB 对齐。
- 预编译依赖（QNN、ORT、sherpa-onnx AAR、GenieX AAR、Live2D Core）无法靠链接参数修正，必须在打包后检查真实文件。`tools/verify_android_native.py` 直接解析 ELF 程序头、ZIP 本地文件头与压缩方式；Hexagon DSP 固件（`e_machine=164`）单独归类，不冒充 Android 宿主 ELF。
- Gradle 在 `merge*NativeLibs`、`assemble*`、`bundle*` 之后自动运行同一检查器，任何不合格的库都会让构建失败，而不是等上架被拒。

实测与边界（2026-02 在当前工作区）：

```powershell
python tools/verify_android_native.py --help
adb shell getconf PAGE_SIZE     # 当前测试机返回 4096，属于 4 KB 设备
```

- 现有预编译依赖中 49 个 Android 宿主 ELF 全部满足 16 KB；14 个 Hexagon DSP 文件单列。
- 之前已安装的 `base.apk` 里 45 个 `lib/*.so` 是 STORED 且 ZIP 偏移仅 4 字节对齐。由于该包同时是 `extractNativeLibs=true`（系统解压后加载），这**不能单独判定它在 16 KB 设备上一定失败**；但它确实不满足“直接 mmap ZIP 内库”的路径。现在已从 `noCompress` 移除 `so`，走官方支持的“压缩 + 安装时解压”路径，并对最终包重新审计。
- 上述结论都不等于“已在 16 KB 真机运行”。真正的验收必须找一台 `getconf PAGE_SIZE` 为 16384 的设备安装运行，本仓库不会用模拟器或 4 KB 机器伪造这条结论。


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

模型权重不打入 APK。两个预设都保留：去审查的 `huihui-ai/Huihui-Qwen3-4B-Instruct-2507-abliterated`（仓库只发布 safetensors，因此安装的是由它编译出的**产物**）与上游 `Qwen/Qwen3-4B-Instruct-2507`（保留原来的 AI Hub QAIRT 下载路径）。SenseVoice 由应用按需下载并校验；MOSS 使用经过验证的 HTP v81 目录，由 Android 目录选择器导入并逐文件校验。

| 用途 | 平台 | 模型 | 体积 |
| --- | --- | --- | ---: |
| 离线对话 | Android，QAIRT | 任一预设编译为 QAIRT w4a16（QnnHtp，4096 context）→ Hexagon NPU | 约 2.5–3.5 GiB |
| 离线对话 | Android，llama.cpp | 任一权重的 GGUF，但只接受 Q4_0/Q8_0（纯 HTP）；导入器拒绝 K-quant/IQ-quant → Hexagon NPU；`auto` 先 NPU，失败回退 CPU，不走 GPU | 约 2.5–4.3 GiB |
| 离线 STT | Android SM8850/HTP v81 | SenseVoice 2024-07-17 INT8 QNN 10 秒 context | 162,023,574 B |
| 离线 TTS | Android SM8850/HTP v81 | MOSS-TTS-Nano 100M QNN 部署包 + Audio Tokenizer | 684.4 MiB（13 文件） |

去审查模型继承基座 `Qwen/Qwen3-4B-Instruct-2507` 的 Apache-2.0；分发前仍需复核该衍生仓库的模型卡。QAIRT/QNN 二进制受 Qualcomm SDK 条款约束，不由仓库重新分发；仓库既不分发量化后的 GGUF，也不分发 NPU context binary。

### 端侧 LLM 硬件后端

| 平台/芯片 | 当前推理后端 | 当前状态 |
| --- | --- | --- |
| Android SM8850/SM8750 + QAIRT 包 | GenieX SDK → QAIRT QNN HTP/NPU | 会话以 `ComputeUnitValue.NPU` 创建，且首轮返回 profiling 后才标为已验证 |
| Android SM8850/SM8750 + GGUF | GenieX SDK → llama.cpp → Hexagon NPU（`ggml-hexagon`） | `compute_unit=npu`（SDK 解析为 `HTP0`）+ `nGpuLayers=-1`；只安装 Q4_0/Q8_0，导入时校验，保证整个图走 HTP |
| Android + GGUF（无 HTP 后端） | NPU 不可用 → CPU 回退 | `auto` 先尝试 NPU；HTP 未注册时销毁 NPU 会话、记录原因并打开 CPU 会话，界面标注 CPU |
| 其他 Android SoC | NPU 不可用 → CPU 回退；`cpu`/`gpu` 可显式指定 | 自动路径要求 HTP v81；CPU 会话不会被标为硬件加速 |
| iPhone/iPad | 无端侧 LLM 后端 | 当前接入只覆盖 Android |
| Windows x64/ARM64 | 无端侧 LLM 后端 | 未实现 DirectML/CUDA/Vulkan/CPU 本地推理，当前只能使用联网平台 |
| Linux x64/ARM64 | 无端侧 LLM 后端 | 未实现 CUDA/Vulkan/ROCm/CPU 本地推理，当前只能使用联网平台 |
| macOS | 无端侧 LLM 后端 | 当前只能使用联网平台 |

Android 设置页把两个预设分别列出：上游 `Qwen/Qwen3-4B-Instruct-2507` 保留 AI Hub 下载，两个预设都可以导入 QAIRT 或 GGUF。导入走 Storage Access Framework：`importQairtBundle` 接收 ZIP（`genie_config.json` + context binaries），`importGguf` 接收单个 GGUF。两者都先复制到 `staging/`、校验副本、再原子替换，取消或校验失败不会破坏已安装的产物。校验规则：QAIRT 要求 `QnnHtp`、`w4a16`、4096 context、tokenizer 与 ctx-bin 全部存在且不越界；GGUF 由 Rust 解析头部并要求 `general.architecture=qwen3`，**且 `general.file_type` 必须是 Q4_0 或 Q8_0**。K-quant/IQ-quant 会在导入时被拒绝并说明原因，而不是先让用户装上一个仍会偷偷把张量放到 CPU 的模型。`Huihui-Qwen3-4B-Instruct-2507-abliterated` 在 `mradermacher` 镜像只发布了 Q8_0（4,280,405,792 B）与 K-quant，没有官方 Q4_0；可直接使用 Q8_0，或用 `llama-quantize --allow-requantize --pure` 从它派生纯 Q4_0（2,269,269,792 B，方法见 `docs/on_device_llm.md`）。NPU 会话无法建立时，`auto` 回退 CPU 并标注；失败码为 `qwen3_import_failed` / `qwen3_import_cancelled` / `qwen3_gguf_quantization` / `qwen3_load_failed` / `qwen3_generate_failed`。

提示词不依赖 SDK 的 Jinja 渲染：GenieX 0.3.17 对 Qwen3 包调用 `applyChatTemplate` 会返回空串。ChatML 现在由 Rust 构造（`rust/src/api/chatml.rs`，经 JNI 调用）：`<|im_start|>role\ncontent<|im_end|>\n` 并以 `<|im_start|>assistant\n` 结尾，剥离内容里全部 `<|...|>` 控制标记，提示词上限 1 MiB；回复若泄漏控制标记则直接拒绝。NPU 与 GPU 共用同一实现，因为两者是同一份 Qwen3 权重。流式文本按 50 ms 合并后经 MethodChannel 送回 Flutter，上千 token 的回复只有几十帧，而不是每个 token 复制一次整串。

Android 不调用系统 on-device STT/TTS。MOSS 仅从带完整清单的 SM8850/HTP v81 包创建原生 session。SenseVoice 使用官方 SM8850 QNN context binary，通过 sherpa-onnx Kotlin/JNI API 的 `provider=qnn` 和 `QnnConfig` 加载；初始化或 HTP 执行失败会直接报错，不回退并伪报 QNN。

### Android MOSS-TTS 硬件执行

Android 使用与参考工程一致的 ONNX Runtime `1.26.0/API 26` core 和 QNN Plugin EP `2.4.0` 同构产物。Gradle 对 ORT core、Plugin EP 和 C API 头文件执行固定 SHA-256 校验，禁止混用 ABI。QAIRT host 库和 HTP skel 来自本机合法安装的 SDK；只有经过验证的部署才会创建 QNN session。prefill/decode 使用 QNN HTP，sampler/codec 使用 ORT CPU 多线程且不会伪报为 NPU。APK 中存在 QNN 库或 provider 可枚举，都不单独构成硬件执行证据；必须完成真机图执行验证。

MOSS 初始化会生成或复用 QNN context cache，合成时依次加载 prefill、decode/sampler、codec 并及时释放，以控制移动设备峰值内存。界面只有在真实合成返回有效 WAV 和 provider 计划后才显示已执行验证。

### 流式朗读：句子级流水线

通话模式和普通聊天都不再等整段回复保存完才开口。`ChatState.responseEvents` 把模型增量原样广播出去；通话模式交给 `CallSession`，普通聊天交给 `NormalReplySpeech`。`SpeechStreamSegmenter` 在 Dart 侧完成分句，`MossTtsService.speakStream` 边合成边播放：

- 第一个完整句子（`。 ！ ？ ! ? …`，英文 `.` 仅在后面是空白/结尾且不属于小数、URL 或邮箱时成立）一到就开始合成，后续句子在第一句播放期间预取。
- 如果当前音频已经播完、下一句还没生成完，段切分器退到最后一个逗号/顿号/分号处释放一个从句，避免静音空洞；从句结束后如果整句仍未完成，再按同样的规则继续。
- 括号内的问号/感叹号不算句末；Markdown 围栏代码整块丢弃，围栏标记即使被拆成两个 delta 也不会把代码读出来。
- emoji、零宽字符、bidi 控制符、全角空格和软连字符在进入 MOSS 前剥离或折叠；纯 emoji 片段不会触发空合成。
- 所有切分索引都按 rune 计数，非 BMP 字符（emoji、CJK 扩展 B）不会因为 UTF-16 代理对而被截断。
- 普通聊天默认开启“自动朗读回复”，在对话选项里可以关闭；关闭后仍可在生成过程中点朗读按钮，从当前已经生成的部分开始，后续句子继续接上。手动朗读已完成的回复保持一次性路径。
- 通话模式忽略该开关（它有自己的麦克风/回合计时器），但两者共用同一个分句器、合成队列和取消语义。

实现集中在 `lib/src/services/speech_stream.dart`、`normal_speech.dart`、`moss_tts_service.dart` 的 `speakStream` 与 `call_session.dart` 的流式 TTS 状态；`speech_stream_test.dart`、`normal_speech_test.dart` 和 `call_session_test.dart` 固定分句、逗号回退、围栏丢弃、非 BMP 边界、自动朗读/手动启动，以及“首句先于完成开始”的行为。

### 内存压力回收（Dart + Native）

Android 的 `onTrimMemory` 现在会真正回收 Dart 侧可回收的部分，而不是只取消一次推理：

- `MainActivity.onTrimMemory` 在 `RUNNING_LOW` 及以上通过 `talk2u/memory` 通道发 `trim`；`RUNNING_CRITICAL` 时额外 `closeMossEngine()`，释放 QNN/ORT session（下一次朗读会用磁盘上的 context cache 重新创建）。
- `lib/src/services/memory_pressure_service.dart` 收到 `trim` 后清空 Flutter `ImageCache`（含 live images）并删除未被播放占用的合成 WAV；`MossTtsService.trimAudioCache()` 在播放中直接跳过，不会删除正在播放的文件。
- 启动时把 `ImageCache` 从 Flutter 默认的 1000 项 / 100 MB 收紧到 64 项 / 32 MB。这个 UI 不加载远程图片，默认上限只会让长会话里的解码位图无限堆积。
- `test/services/memory_pressure_service_test.dart` 固定缓存上限与"清空图片 + 释放一次音频"的行为。

实测（PLK110，冷启动后静止）：`dumpsys meminfo` 的 TOTAL PSS 约 425 MB，其中 Native Heap 约 110 MB、Unknown 约 135 MB、Other mmap 约 79 MB、`.so` 约 56 MB。静止状态下执行 `adb shell am send-trim-memory com.blue.talk2u RUNNING_LOW` 前后差异小于 1 MB——因为此时并没有解码图片或缓存 WAV 可回收。这个回收通路针对的是长会话与后台压力场景，不应宣称"降低了静止内存"。

QAIRT 2.48 的静态化流程固定 recurrent KV 容量。V81 无法接受 sampler 的 `QNN_CumulativeSum`，因此 sampler 明确使用 ORT CPU；streaming codec 的 QNN 图虽能运行，但在 PLK110 上会产生逐帧累积的嘶哑/噪声，已退回 ORT CPU 以保证音质。原始动态 ONNX 不会直接送入 Android QNN runtime。

通过 `TALK2U_QNN_SDK_ROOT` 打包合法取得的 QAIRT 运行库；`TALK2U_QNN_ORT_AAR` 仅用于覆盖默认 ORT core AAR，QNN Plugin EP 仍由 Qualcomm Maven 包提供：

```powershell
$env:TALK2U_QNN_SDK_ROOT='D:\Qualcomm AI Engine Direct SDK'
$env:TALK2U_QNN_HTP_ARCH='v81'
flutter build apk --debug --target-platform android-arm64
```

应用设置页选择包含 `moss-qnn-deployment.json` 的目录后，先在 staging 目录复制并验证全部文件，再原子替换旧部署。首次初始化可能因 QNN context 生成耗时较长；后续会复用与模型哈希绑定的私有缓存。

仓库不包含 MOSS 权重：`model/TTS/moss-qnn-v81-streaming` 只有清单与 tokenizer 元数据，13 个声明文件里 9 个约 684 MiB 的 `*.data` / `*.qnn.onnx` 需要按清单另行获取。导入前用与 App 完全相同的规则离线检查，缺文件会按名字列出，而不是等到手机上才报“导入失败”：

```powershell
python tools/check_moss_package.py model/TTS/moss-qnn-v81-streaming
python tools/check_moss_package.py C:\Downloads\moss-qnn-v81-streaming.zip
```

退出码：`0` 完整且校验通过，`2` 缺文件/大小不符/SHA-256 不符，`1` 参数或清单错误。`--json` 输出机器可读报告，`--no-hashes` 只做大小预检。手机端导入失败时，Kotlin 侧用 `moss_package_incomplete` 错误码回传完整缺失列表，界面显示“部署包不完整或已损坏，请检查：…”，链路与这个脚本一致。

如果权重文件本身正确、只是随包的 `moss-qnn-deployment.json` 过期（例如 ZIP 内清单仍指向旧版 `browser_poc_manifest.json`），可以只替换清单、不重打包权重：

```powershell
python tools/check_moss_package.py C:\Downloads\moss-qnn-v81-streaming.zip `
  --rewrite-manifest model/TTS/moss-qnn-v81-streaming/moss-qnn-deployment.json `
  --output build/moss-qnn-v81-streaming.zip
```

该命令只有在**所有文件都已与替换清单一致**时才写出新 ZIP；否则删除输出并以非零退出码结束，不会把损坏的包“修”成能通过校验的包。本工作区里的 `C:\Users\blueo\OneDrive\GitHub Resources\Talk2U\moss-qnn-v81-streaming.zip` 就是这种情况：13 个文件、684.4 MiB 全部匹配，只有清单里 `browser_poc_manifest.json` 的大小/哈希是旧值。修复后的包已生成在 `build/moss-qnn-v81-streaming.zip` 并通过同一套校验。

### 一加 15 真机导入与 NPU 执行（已实测）

2026-11-16 在本机 `PLK110`（SM8850，Android API 37，页面大小 4096）上完成了一次完整链路：

1. 通过设置页“从 ZIP 文件导入”导入修复后的 317 MiB ZIP；Kotlin 侧解压后逐文件校验 13 个文件（684.4 MiB）全部通过，原子替换安装目录。
2. `MossTtsQnn` 注册 QNN Plugin EP（1 device），加载 `libQnnHtpV81Skel.so` 到 CDSP domain（`fastrpc … _dom=cdsp`），生成并复用 prefill/decode 的 QNN context binary（`prefill_v2_q248_*.ctx.onnx`、`decode_v2_*.ctx.onnx`）。
3. 两次真实合成返回 `provider=QNN_HTP(prefill,decode)+ORT_CPU(sampler,codec)`，分别 3475 ms / 20 帧与 4348 ms / 49 帧；界面显示 `TTS · Qualcomm QNN HTP + ORT CPU`。

同一台机器上仍未验证的项目：16 KB 页面大小（该机为 4096，只能在 16384 设备上验证）、听感主观评价、长时间通话温升与功耗。不要把这些写成已通过。

华为 Mate 10 Pro 当前不接入许可受限的 HiAI DDK 二进制，也不使用通用 NNAPI 代替 Qualcomm QNN，因此 MOSS 在该设备上不可用。

端侧 Qwen LLM 使用独立的 GenieX 会话：它与 MOSS 共用 QNN HTP 运行时，但不共享 session，也不会因为 MOSS 合成成功就继承"已验证"状态。QAIRT 的验证证据来自会话以 NPU 创建且一轮生成返回 profiling；GGUF 的验证证据额外要求 Rust 侧的被动 GGML 探针确认 `HTP` 后端已在当前进程注册（`RTLD_NOLOAD` 打开已映射的 `libggml.so`，不重复加载）。GGUF 的 `activeBackend` 是 `geniex-llamacpp-npu`，GPU 是 `geniex-llamacpp-gpu`，CPU 是 `geniex-llamacpp-cpu` 且不会被标为硬件加速。Windows/Linux 尚未接入本项目的端侧 LLM 后端。

## Live2D Cubism 5 模型与 Core

### SDK、平台链路与许可

本项目明确使用 Live2D Cubism SDK。Android 运行链路是 `AndroidView` -> `GLSurfaceView` -> `libtalk2u_live2d.so` -> Cubism SDK for Native 5 R.5 Framework/Core -> OpenGL ES。模型更新、动作、表情、物理、姿势、呼吸、眨眼、口型、纹理上传和绘制均在 Native C++ 中执行；首个无 GL 错误的真实绘制帧完成后才报告 ready。Windows/Linux 仍使用现有 WebView2/CEF + Pixi Web 链路，两类实现不能混为一谈。

Android Gradle/CMake 只从 `TALK2U_CUBISM_SDK_ROOT` 指向的本机 SDK 读取所需文件。仓库不包含、不 vendoring、也不允许提交 `Live2DCubismCore` 二进制、Core 头文件或完整 Cubism SDK。Core 会在本机构建时静态链接进 APK 的 `libtalk2u_live2d.so`；公开发布二进制前必须自行确认许可范围。

官方入口与协议：

- Live2D 官网：<https://www.live2d.com/en/>
- Live2D Proprietary Software License Agreement：<https://www.live2d.com/eula/live2d-proprietary-software-license-agreement_en.html>
- Live2D Open Software License Agreement：<https://www.live2d.com/eula/live2d-open-software-license-agreement_en.html>

Windows/Linux Web 宿主需要合法取得的 Cubism Core for Web。**仓库不包含 Web 宿主页面本身**：`assets/live2d/index.html` 与 `assets/live2d/vendor/live2dcubismcore.min.js` 都必须由构建者自行提供并按许可放置；缺失时桌面端会直接给出“宿主资源未安装”的明确错误，而不是启动一个注定 404 的 WebView。Android Native 构建不使用这些 JavaScript 文件。

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

本次真机验收设备为 PLK110、SM8850、Android 17（API 37）、Adreno 840、4096 字节页。Mao 已实际显示并持续动画；两张采样截图的舞台像素有 18.113% 变化，图形统计为 653 帧、0.46% jank、GPU median 3 ms。该结果只证明这台设备和当前构建，不自动覆盖其他 ROM、GPU 驱动或第三方模型。

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

## 摄像头观察与视线跟随

Live2D 的“观察”是一个可选的本地能力，不参与对话推理，也不做身份判断。入口在聊天页顶部：只有用户点击并确认说明后才会申请权限，订阅状态流本身不会打开摄像头。

实现链路：

```text
Flutter: CameraObservationService (MethodChannel/EventChannel)
  └─ Android: CameraObservation.kt (Camera2 + 前置 camera 的 SIMPLE/FULL face detect)
       ├─ 仅在本地 ImageReader 上取人脸包围盒，帧立即释放
       ├─ 200 ms 节流，输出 status / faceCount / primaryFace(归一化、镜像)
       └─ 后台、离页、关闭、权限拒绝、销毁时释放 device/session/reader/线程
  └─ Live2dAvatarController.lookAt(x, y) → Native 平滑视线目标（不叠加表演 cue）
```

几条刻意的设计边界：

- **不做活体识别。** Camera2 的 `STATISTICS_FACE_DETECT_MODE_SIMPLE/FULL` 只能给出“画面里像人脸的区域”。照片、屏幕、海报与面具同样会触发。`CameraObservationState.livenessVerified` 恒为 `false`，界面文案只写“检测到人脸”，不写“真人已确认”。
- **不保存、不上传。** 取帧只为读取元数据，像素被丢弃；没有截图、没有缓存文件、没有网络上传路径。应用进程退出即无残留。
- **不自动恢复。** 授权弹窗可能触发 Activity pause，此时会安全取消启动，避免“用户点了拒绝却还在开摄像头”。返回应用后需要再次点击。
- **硬件不支持就说 unsupported。** 没有前置摄像头、没有 `FACE_DETECT` 能力、或 5 秒内拿不到角色元数据时直接返回 `unsupported`，不用软件人脸检测冒充。
- **与渲染策略一致。** 系统开启“减少动画”时，视线目标仍会更新，但非口型的平滑位移被收紧；离页或后台时 Live2D 与本能力同时停止。

## Android 应用内离线语音

### SenseVoice STT

设置页下载并校验官方 `sherpa-onnx-qnn-SM8850-binary-10-seconds-sense-voice-zh-en-ja-ko-yue-2024-07-17-int8` 后，应用通过 sherpa-onnx Kotlin/JNI 在 QNN HTP 上识别。录音固定为 16 kHz、PCM16、单声道并限制为 10 秒；结果完整保留转写文本、语种、情感和音频事件字段。

识别完全由应用管理，不依赖 `SpeechRecognizer`、Google 语音服务或厂商 ROM 的离线语言包。首次录音仍需授予 `RECORD_AUDIO`。

### MOSS-TTS

设置页 MOSS 卡片右侧的文件夹按钮提供两种导入方式：“从 ZIP 文件导入”与“从解压目录导入”。目录必须包含 `moss-qnn-deployment.json`、MOSS TTS/codec 元数据、tokenizer、共享权重和 `.qnn.onnx` 图。导入器拒绝目录穿越、版本不匹配、错误 SoC/HTP 架构、缺失文件、大小或 SHA-256 不匹配。

**权重不在仓库里。** `model/TTS/moss-qnn-v81-streaming/` 只跟踪清单、tokenizer 与浏览器元数据；`*.data`、`*.onnx`、`*.bin` 被 `.gitignore` 排除，完整部署包约 684 MB，需从模型来源获取后自行导入。设置页在未安装时显示的是“部署包约 X”的提示，不是已安装体积；安装完成后显示 native 实测字节数。

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
python -m unittest discover -s tools -p "test_*.py" -v
node --test --test-isolation=none test/rendering/avatar_frame_gate_test.cjs

Push-Location android
.\gradlew.bat :app:testDebugUnitTest
Pop-Location
```

`tools/run_quality_checks.ps1` 按 CI 顺序跑同一组门禁（可用 `-SkipRust`、`-SkipFlutter`、`-SkipAndroid` 跳过），任何一步失败都会给出失败命令与退出码：

```powershell
pwsh tools/run_quality_checks.ps1
```

`tools` 下的 26 项主机侧测试全部只用 Python 标准库：ELF/ZIP 16 KB 审计 10 项，MOSS 部署包审计 16 项（目录与 ZIP、缺失/截断/SHA-256、越界路径、清单重写与拒绝改写、命令行退出码、真实仓库清单）。Flutter 侧当前 201 项。

Android 侧现在也有纯 JVM 单测（`android/app/src/test/kotlin`），共 32 项：芯片代号解析（`ChipsetTest` 7）、ZIP/SAF 路径越界防护（`SafeRelativePathTest` 5）、MOSS 清单校验（`MossDeploymentParserTest` 8，覆盖 schema、provider plan、重复/穿越路径、大小与 SHA-256、必需文件、文件数上限）、GGUF 量化识别（`GgufFileTypeTest` 2）与 QAIRT 包校验（`QairtBundleValidatorTest` 10）。它们不依赖设备，也不需要 Cubism SDK；在 CI 或没有许可 SDK 的机器上用以下命令即可运行：

```powershell
cd android
.\gradlew.bat :app:testDebugUnitTest -Ptalk2u.cubismSdkRoot=/nonexistent -Ptalk2u.requireCubism=false
```

> PowerShell 里带点的 `-P` 参数要用引号包住，否则会被拆成 `-Ptalk2u`：`"-Ptalk2u.requireCubism=false"`。cmd/bash 无此问题。

### 生成 FRB 绑定

`rust/src/frb_generated.rs` 与 `lib/src/rust/**` 必须和 `flutter_rust_bridge` 版本一致（当前 2.11.1）。codegen 默认会**自动升级依赖**，曾把 `Cargo.toml`/`pubspec.yaml` 改到 2.13 并在网络受限时卡住，因此本地生成必须显式关闭该行为：

```powershell
flutter_rust_bridge_codegen generate --no-deps-check --no-auto-upgrade-dependency --no-build-runner --no-dart-format --no-rust-format
```

升级 FRB 是一个独立任务：Rust 依赖、`pubspec.yaml`、codegen 二进制与生成物必须同时切换版本，并跑完整回归；不要只改其中一处。

### 流式事件协议

`ChatStreamEvent` 现在是类型化枚举：`contentDelta` / `thinkingDelta` / `retryReset` / `generationCancelled` / `done` / `error`。重试清空与用户取消不再通过 `__RETRY_RESET__`、`__GENERATION_CANCELLED__` 这类字符串哨兵传递，Dart 侧也不需要再做子串匹配。

Rust 测试覆盖供应商鉴权/请求转换、Anthropic 和 OpenAI-compatible SSE、跨模型上下文、记忆、知识、错误重试和 Discord 分片，并新增三类一致性回归：传输层 `Done` 不能被提前转发、取消后旧回复不能写入新轮次、并发写入只能有一个赢家；`T2UB` 压缩/解压上限、摘要 sidecar 与压缩炸弹拒绝也有独立用例。Flutter 测试覆盖聊天状态竞态、语音/MOSS 生命周期与取消、流式分句与逗号回退、PCM 采集、摄像头观察竞态、动效策略和动作 cue 推断。Python 用例保证 16 KB 检查器在坏 ELF、4 KB 对齐、错误 ABI 和缺失输入上会失败关闭，而不是放行。

这些门禁已固化在 `.github/workflows/quality.yml`：Rust 执行 `cargo fmt --check`、`cargo clippy --all-targets -- -D warnings`、`cargo test --all-targets`；Flutter 执行格式检查、`flutter analyze`、`flutter test`，并运行桌面 RAF 门控测试与 `tools` 下的主机侧审计器；`android-unit` 在无 Cubism SDK 的情况下跑 `:app:testDebugUnitTest`。Android 打包仍留在发布清单中，因为它依赖外部许可的 Cubism/QNN 产物和真机。

CI 里有两处工程约束值得注意：Gradle wrapper（`gradlew`、`gradlew.bat`、`gradle-wrapper.jar`）是**提交进仓库**的——Flutter 只在完整构建时才会重新生成它，而完整构建需要许可 SDK，所以 `android/.gitignore` 用 `!` 规则把它们放行；`android-unit` 先 `flutter pub get`，再由 CI 写 `android/local.properties`（`sdk.dir` + `flutter.sdk`），因为 Flutter 只在 `flutter build` 时写这个文件。

Flutter 版本在 workflow 里固定为 `3.47.9`：`flutter analyze` 的规则集随 stable 更新而变化，固定版本才能让 CI 的结论和本机一致。Android SDK 不重新 bootstrap，直接用 runner 镜像自带的 `ANDROID_HOME` 与 `sdkmanager` 安装 `platforms;android-36`、`build-tools;36.0.0`。Analyzer 失败时会把诊断以 `::error::` 注解回写到 check run，因为公开仓库的 job 日志需要认证，而注解是公开可读的。

### UI 文案与重绘约束

- `test/l10n/no_hardcoded_cjk_test.dart` 扫描整个 `lib/`：除 `lib/src/lexicon`（语言数据）、`lib/src/prompts`（模型提示词）、`lib/src/rust` 与 `lib/l10n/generated`（生成物）外，禁止出现中文字符；同一个测试还校验 en/zh 两份 ARB 的键集合完全一致。
- 服务层没有 `BuildContext`，通过 `lib/src/l10n/app_strings.dart` 的 `AppStrings.current` 取当前语言的 `AppLocalizations`；`main()` 在 `runApp` 前按 `UiPreferences.locale`（或系统语言）配置一次，语言切换与系统语言变化时再同步。默认英文，因此单元测试与启动早期也不会漏出未翻译文案。
- MOSS 的初始化/导入阶段已从字符串改为 `MossOperation` 枚举，由设置页映射到 ARB；`moss_status_l10n_test.dart` 校验每个阶段的英文文案不含 CJK。SenseVoice 的“是否正在下载 ASR”也从 `operationLabel.contains(...)` 改为 `asrDownloading` 布尔量，不再用文案做逻辑判断。
- Qwen、MOSS 与 SenseVoice 的失败状态改为稳定错误码（`lastErrorCode`），设置页通过 `serviceErrorText` 映射到 ARB；未知原生错误才回退到原始详情。`service_error_text_test.dart` 锁定已知错误码的英文文案不含 CJK。
- 语言数据与模型输入不放进 ARB：情感/cue 词表在 `lib/src/lexicon`（`emotion_lexicon.dart`、`speech_cue_lexicon.dart`、`moss_voice_catalog.dart`），角色系统提示词与离线重写指令在 `lib/src/prompts/persona_prompts.dart`。它们是“喂给模型/用于匹配的中文数据”，不是界面文案，翻译它们只会改变人设的推理语言。
- 内置 provider 名称（如 `android-offline`）在磁盘上保持稳定英文标识，显示时经 `lib/src/l10n/provider_names.dart` 本地化，避免持久化配置把某一种语言写死。
- Kotlin 侧的用户可见错误详情也已统一为英文（`MainActivity`、`OnDeviceLlmRuntime`、`OnDeviceModel`、`ModelStore`、`Chipset`），并补齐 `live2d_import_failed`、`invalid_*`、`activity_destroyed`、`qwen3_import_*` 等错误码到 ARB 的映射；唯一保留的中文是 `moc3` 参数名 `嘴巴开合`，它是模型元数据而不是文案，代码里已加注释说明。

- 消息气泡只在“已完成”的消息上渲染 Markdown；流式阶段用纯文本，避免每个 token 重建 AST。
- 完成态 Markdown 按 `content + ThemeData 实例 + TextScaler` 缓存 widget 实例，父级每 48 ms 重绘时不会重复解析历史消息；`message_bubble_cache_test.dart` 用构建计数验证这一点。
- `ChatState.messages` 的不可变视图与 `displayMessages` 只在消息列表结构或流式状态变化时重建；流式 delta 通知不会每 48 ms 重新过滤整张消息表（`displayMessagesBuildCount` 测试锁定）。

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
- [ ] MOSS 实际合成后显示 `QNN_HTP(prefill,decode)+ORT_CPU(sampler,codec)`，且只有 prefill/decode 被标为 HTP；“候选”、NNAPI 名称或库存在不能作为硬件验收通过。
- [ ] NNAPI 诊断不把类型为 CPU 的设备列为非 CPU 加速设备。
- [ ] 明确配置的 motion/expression 能被触发。
- [ ] 开启飞行模式后，已安装的 TTS 仍能朗读。
- [ ] 开启飞行模式后，已安装的 SenseVoice 仍能识别中文和英文。
- [ ] 导入超大模型时被明确拒绝，而不是应用闪退。
- [ ] 切后台再返回，Live2D 和语音按钮仍可用。
- [ ] 开启“视线跟随”后授权前置摄像头，屏幕出现人脸时角色视线跟随；注意这是人脸存在检测，照片与人脸照片同样可能触发。
- [ ] 关闭摄像头、切到后台、打开设置页后，系统状态栏摄像头指示应立即消失；返回聊天页不会自动重开。
- [ ] 连续打断三轮后仍能正常进入下一轮，且被打断的部分回复保留在记录中。
- [ ] 连续发送两次（或通话中重复触发发送）只产生一条用户消息和一个回复。

在 PLK110 上已勾选的项（2026-11-16，当前构建）：冷启动不崩溃；MOSS ZIP 导入逐文件校验通过；MOSS 真实合成返回 `QNN_HTP(prefill,decode)+ORT_CPU(sampler,codec)`；Qwen3 首轮生成后状态为 `Qualcomm QNN HTP/NPU（已验证）`；英文与中文两轮生成、以及"重写"路径都返回非空文本。其余条目仍需在目标设备上逐项执行。

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
- 不能宣称仓库默认 ONNX Runtime AAR 已包含 QNN EP，不能宣称已直接接入华为 HiAI DDK。
- 一加 15（PLK110）上已实测的只有：MOSS 部署包导入与校验、MOSS 在 `QNN_HTP(prefill,decode)+ORT_CPU(sampler,codec)` 下的真实合成、Qwen3 在 `geniex-qairt-npu` 下的真实生成与重写。不能据此宣称该机型已完成全部真机验收：16 KB 页（该机为 4096）、听感、温升/功耗、长时通话仍未验证；Mate 10 Pro 未做任何验收。
- 不能宣称 Windows/Linux 已完成端侧 TTS、持续离线通话或端侧 LLM 硬件加速。
- 不能宣称当前文件存储支持多进程或多设备并发写入。
- 不能宣称摄像头人脸检测等于真人、活体或身份认证；它只是本地的人脸存在与位置检测。
- 不能宣称仓库自带 Windows/Linux 的 Live2D Web 宿主；`assets/live2d/` 必须由构建者按许可补齐。
- 不能宣称项目已在任意 16 KB 页设备上通过；当前环境只有 4 KB 设备，ELF 与打包布局通过不等于真机运行通过。

这些限制会以错误、禁用状态或导入拒绝明确呈现，而不是通过占位动画、云端回退或静态图伪造成功。
