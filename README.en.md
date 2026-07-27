# Talk2U

Talk2U is a Flutter and Rust character chat application. Conversations, character profiles, memories, and knowledge are stored locally. Replies can come from a configured online LLM or from the on-device Qwen model on Android. Android, Windows, and Linux provide a Live2D chat surface.

This document describes the implemented behavior and its verification boundary. It does not claim that proprietary accelerators or third-party services work without their licensed runtime, device driver, model support, credentials, and real-device validation. See [README.md](README.md) for the full Chinese guide.

## Capability Matrix

| Capability | Status | Implementation |
| --- | --- | --- |
| Zhipu GLM | Implemented | `rustglm 1.0.0`, Zhipu JWT authentication, streaming chat |
| DeepSeek, OpenAI, Kimi, Qwen | Implemented | OpenAI-compatible streaming adapters |
| Anthropic | Implemented | Messages API headers, request conversion, and Anthropic SSE |
| Local memory and knowledge | Implemented | Rust local storage, recent context, summaries, and fact retrieval |
| Android local LLM | Conditional | Exact `Qwen/Qwen3-4B-Instruct-2507` Genie deployment; validated SM8850/V81 HTP, then explicit CPU fallback |
| Offline STT | Implemented | SenseVoice on Android, Windows, and Linux; Android system on-device STT is preferred |
| Continuous voice call | Conditional on Android | Final STT results are sent automatically; completed replies are spoken and listening resumes |
| Android offline TTS | Conditional | Verified system offline voice or MOSS-TTS ONNX; strict NNAPI, mixed NNAPI/ORT, then explicit CPU fallback |
| Windows/Linux offline TTS | Not implemented | The current desktop speech path only provides SenseVoice STT |
| Live2D | Conditional | Android WebView, Windows WebView2, Linux CEF, Pixi, and a legally supplied Cubism Core 5 |
| Live2D semantic cues | Implemented, model-dependent | Context and silent stage directions select configured motion or expression mappings |
| Android GPU diagnostics | Implemented | Real Vulkan device creation, EGL OpenGL ES fallback, and actual WebGL renderer reporting |
| Android NNAPI diagnostics | Implemented | Device name, version, type, and feature level; CPU devices are excluded from accelerator results |

An implemented online provider still requires a valid API key, account quota, reachable endpoint, and a model ID enabled for that account.

## Architecture

```text
Flutter UI
  |-- chat, characters, memory, and provider selection
  |-- Android WebView / Windows WebView2 / Linux CEF Live2D host
  |-- Android Genie local Qwen3 (HTP -> CPU)
  |-- Android, Windows, and Linux SenseVoice STT
  |-- Android system speech and MOSS-TTS with reported NNAPI/CPU execution
  `-- Flutter platform and event channels
                 |
          flutter_rust_bridge
                 |
Rust core
  |-- provider adapters and streaming
  |-- conversation engine
  |-- memory and knowledge storage
  `-- Discord bridge
```

Provider selection only determines where the next request is sent. Conversation history, character prompts, summaries, and retrieved facts remain associated with the conversation, so a conversation can continue after changing providers.

## Build Requirements

- Flutter matching the SDK constraint in `pubspec.yaml`
- Rust stable and the MSVC toolchain on Windows
- JDK 17
- Android SDK 36, Build Tools 36, NDK `28.0.12674087`, and CMake `3.22.1`
- Visual Studio C++ desktop tools for Windows builds
- Flutter Linux desktop dependencies, GTK 3, CMake, Ninja, and a C++ toolchain for Linux builds

```powershell
flutter pub get

Push-Location rust
cargo test --all-targets
Pop-Location

flutter test
flutter analyze lib test
flutter build apk --debug --target-platform android-arm64
```

The Android package is currently restricted to `arm64-v8a`. Every enabled ABI must contain compatible Flutter, Rust, plugin, ONNX Runtime, and optional vendor runtime libraries.

## Zhipu and RustGLM

The Zhipu provider is implemented with the pinned `rustglm = 1.0.0` crate rather than a parallel handwritten Zhipu transport. Talk2U converts its provider-neutral request into `GlmChatCompletionRequest`, configures the SDK HTTP client and retry policy, then consumes the SDK stream.

`SdkError` handling preserves meaningful categories:

| RustGLM error | Talk2U error |
| --- | --- |
| HTTP 401/403 | Authentication error |
| HTTP 429 | Rate-limit error |
| Other HTTP status | API error |
| Transport or timeout | Network error |
| Configuration or validation | Validation error |
| Stream or decode | Stream error |
| Unsupported, agent, or tool | Non-retryable validation error |

Decode failures do not expose the raw response body in user-facing errors.

## Android Hardware TTS

MOSS-TTS-Nano uses four ONNX sessions: prefill, decode step, local sampled frame, and audio-token decoder. A single provider must create all four sessions. Sessions are retained across utterances and released when the service or activity is released.

The MOSS path attempts strict NNAPI, mixed NNAPI/ORT execution, and then explicitly falls back to CPU:

- NNAPI uses `NNAPIFlags.CPU_DISABLED` and `session.disable_cpu_ep_fallback=1`.
- If any subgraph cannot compile strictly, a second bundle keeps NNAPI's CPU device disabled while allowing ORT CPU fallback for unsupported nodes.
- Mixed execution is reported as containing CPU and is not presented as pure NPU verification; if it also fails, separate CPU sessions are created.
- The UI reports the provider that actually synthesized the WAV and labels CPU fallback explicitly.

The default `onnxruntime-android 1.27.0` native library exports NNAPI but not QNN. The current MOSS build can therefore attempt strict NNAPI, mixed NNAPI/ORT, and then CPU. The Java `addQnn` API alone is not evidence that the native library contains QNN EP.

### Qualcomm QNN HTP

QAIRT 2.48 was used to inspect and statically prepare all four graphs. `tools/qnn/moss_v81_status.json` keeps MOSS HTP disabled because V81 finalization fails on `q::QNN_CumulativeSum` and the upstream decode KV grows from 768 to 769, so it is not recurrent-safe for 375 steps. Raw dynamic ONNX is never sent to QNN or described as HTP-ready.

Supply local artifacts through Gradle properties or environment variables:

```powershell
$env:TALK2U_QNN_SDK_ROOT='D:\Qualcomm AI Engine Direct SDK'
$env:TALK2U_QNN_HTP_ARCH='v81'
flutter build apk --debug --target-platform android-arm64
```

MOSS HTP activation additionally requires:

1. All four static graphs finalize for SM8850/V81.
2. A fixed-capacity decode graph consumes its own outputs for 375 steps.
3. A physical SM8850 generates and plays a valid WAV.
4. Deployment hashes and a device-validation marker are present.

Library presence or provider enumeration is never treated as execution proof.

### Huawei and NNAPI

The repository does not contain or directly integrate licensed Huawei HiAI DDK binaries. Huawei devices use the strict NNAPI path. It requires Android 10 or later, a non-CPU NNAPI driver, and full driver support for all four MOSS graphs.

NNAPI device types are interpreted as defined by Android: `0` OTHER, `1` CPU, `2` GPU, `3` ACCELERATOR, and `4` UNKNOWN. Type `1` is never reported as an accelerator. Even a listed accelerator is only a capability signal; successful strict synthesis is the execution proof.

No OnePlus 15 or Huawei Mate 10 Pro real-device pass has been performed in this workspace. The code and build have been verified, but device acceptance requires the checklist below.

### Separate Local LLM Path

MOSS acceleration does not accelerate the local Qwen LLM. Android uses the exact Qwen3-4B-Instruct-2507 Genie deployment and tries validated HTP, then CPU. HTP is marked verified only after the first successful query. QAIRT Composer 2.48 supports `Qwen3ForCausalLM` with `Z4`, `Q4`, `Z8`, and `Q5_K`, but its direct `.bin` output uses `QnnGenAiTransformer` on the host CPU; Composer support alone is not HTP support. Genie 2.48 does not expose a QNN GPU dialog backend. Flutter reports the backend that actually loaded and shows CPU fallback. Windows and Linux have no local desktop LLM backend.

## Continuous Speech

The call button enables an Android turn loop:

```text
listen -> final recognition -> send -> generate -> speak -> resume listening
```

Partial Android recognition results update the UI but are not sent. SenseVoice records PCM with adaptive voice activity detection and ends a turn after speech followed by approximately 850 ms of silence. Its recognizer lives in a dedicated long-running isolate, so the ONNX model is loaded once and the Flutter UI thread does not run inference. Ending the call or disposing the page stops recording and playback.

The call requires both an available offline STT and offline TTS on the same device. It is not currently a full-duplex echo-cancelled telephony stack, and the Windows/Linux desktop build cannot start a complete offline call until desktop TTS is implemented.

## Silent Stage Directions

Speech preparation distinguishes stage directions from explanatory parentheses. For example:

```text
Input:  女生：（哈哈大笑）你说的太好了！
Spoken: 你说的太好了！
Cue:    happy at spoken offset 0
```

Parenthesized or bracketed content is removed only when it contains recognized action or emotion terms. Explanatory text such as `NNAPI (Neural Networks API)` remains spoken. Asterisk actions such as `*wave*` are silent and still produce a semantic cue. Offsets remain compatible with Android UTF-16 TTS range callbacks.

Actual motion quality depends on the imported model. Talk2U only plays a motion or expression that is explicitly mapped in `talk2u.avatar.json` or can be verified from model metadata. It does not assign semantics to arbitrary numbered motion files.

## Live2D and GPU Rendering

Android enables hardware acceleration for the activity and WebView and requests a high-performance WebGL context. WebGL2 falls back to hardware WebGL1. Software renderers such as SwiftShader and llvmpipe are rejected by diagnostics.

The native probe separately creates a Vulkan instance/device and an EGL OpenGL ES context. This proves native API availability only. It does not prove that the current Live2D frame uses that API. The actual WebView/ANGLE renderer is reported separately:

- `vulkan-via-angle` proves the current WebView frame uses Vulkan through ANGLE.
- `opengl-es-via-webgl` reports the OpenGL ES path.
- An unspecified backend proves only that hardware WebGL was created.

The application cannot force WebView/ANGLE to prefer Vulkan. A fully application-controlled Vulkan/OpenGL renderer requires a legally licensed Cubism SDK for Native 5 integration, which is not present.

Cubism Core is license-restricted and is not distributed by this repository. Obtain Cubism SDK for Web 5 under its license for offline Live2D operation.

## Verification

Completed automated checks for this change include:

- Rust tests, including RustGLM error mapping
- Flutter speech planning and MOSS utility tests
- Android Kotlin compilation
- Android C++ external native build
- Dart formatting and diff whitespace checks

Real-device acceptance must include:

- Verify the NNAPI device list does not classify a CPU device as acceleration.
- Run a real MOSS synthesis, verify the reported NNAPI/CPU provider, validate the WAV, and confirm playback.
- Verify `女生：（哈哈大笑）你说的太好了！` speaks only the dialogue and triggers a happy cue.
- Run at least 20 call turns, then end the call and confirm microphone capture and playback stop.
- Confirm the actual Live2D renderer is not a software renderer.
- Test airplane-mode STT, TTS, LLM, and Cubism assets separately; each requires its local asset to be present.
- Measure temperature, audio latency, memory, and battery drain on every release target.

## Claims That Must Not Be Made

- Do not claim QNN from an API symbol, library presence, or provider enumeration.
- Do not claim that the default ONNX Runtime AAR contains QNN EP.
- Do not claim direct Huawei HiAI DDK integration.
- Do not claim real-device validation on OnePlus 15 or Huawei Mate 10 Pro until it is performed.
- Do not label Qwen3 Composer CPU execution as NPU or GPU execution.
- Do not claim Windows/Linux offline TTS, continuous offline calls, or local LLM hardware acceleration.
- Do not claim the native Vulkan probe is the actual Live2D renderer.
- Do not claim that Cubism Core is legally bundled with the repository.

Failures are surfaced as unavailable capabilities or explicit errors. CPU fallback is allowed only when it is explicitly reported; it is never labeled as NPU/GPU execution.
