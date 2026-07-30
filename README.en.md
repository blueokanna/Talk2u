# Talk2U

Talk2U is a Flutter and Rust character chat application. Conversations, character profiles, memories, and knowledge are stored locally. Replies can come from a configured online LLM or from the on-device Qwen model on Android. Android speech is app-managed: sherpa-onnx SenseVoice INT8 provides STT and MOSS-TTS-Nano provides TTS through Qualcomm QNN HTP.

This document describes the implemented behavior and its verification boundary. It does not claim that proprietary accelerators or third-party services work without their licensed runtime, device driver, model support, credentials, and real-device validation. See [README.md](README.md) for the full Chinese guide.

## Download link for the open-source model with built-in folder in the Model folder
[Download](https://1drv.ms/f/c/716401d0cdd5bd0e/IgDdaEU7EX-mRqR-h47_q-UUAftK4GNb5I9nDv1JGAVG0ik?e=VTbi0P)

## Capability Matrix

| Capability | Status | Implementation |
| --- | --- | --- |
| Zhipu GLM | Implemented | `rustglm 1.0.0`, Zhipu JWT authentication, streaming chat |
| DeepSeek, OpenAI, Kimi, Qwen | Implemented | OpenAI-compatible streaming adapters |
| Anthropic | Implemented | Messages API headers, request conversion, and Anthropic SSE |
| Local memory and knowledge | Implemented | Rust local storage, recent context, summaries, and fact retrieval |
| Android local LLM | Implemented | `Qwen/Qwen3-4B-Instruct-2507` Q4_K_M through llama.cpp, with 36 transformer blocks and the output matrix on Adreno Vulkan |
| Offline STT | Implemented | sherpa-onnx SenseVoice 2024-07-17 INT8 QNN context on SM8850, preserving ASR/LID/SER/AED results |
| Continuous voice call | Conditional on Android | Final STT results are sent automatically; completed replies are spoken and listening resumes |
| Android offline TTS | Conditional | MOSS prefill/decode/codec on QNN HTP and sampler on ORT CPU after importing a validated SM8850/v81 package; no system TTS fallback |
| Windows/Linux offline TTS | Not implemented | The current desktop speech path only provides SenseVoice STT |
| Live2D | Conditional | Cubism SDK for Native 5 R.5 with C++/OpenGL ES on Android; WebView2 on Windows and CEF on Linux |
| Live2D semantic cues | Implemented, model-dependent | Context and silent stage directions select configured motion or expression mappings |
| Android Live2D GPU rendering | Implemented | Native C++ Cubism OpenGL ES renderer; software GL implementations are rejected and ready follows the first valid frame |
| Android NNAPI diagnostics | Implemented | Device name, version, type, and feature level; CPU devices are excluded from accelerator results |

An implemented online provider still requires a valid API key, account quota, reachable endpoint, and a model ID enabled for that account.

## Architecture

```text
Flutter UI
  |-- chat, characters, memory, and provider selection
  |-- Android GLSurfaceView / Native C++ Cubism OpenGL ES
  |-- Windows WebView2 / Linux CEF Live2D host
  |-- Android llama.cpp/Vulkan Qwen3-4B-Instruct-2507 (Adreno GPU)
  |-- sherpa-onnx Kotlin/JNI SenseVoice QNN STT (SM8850 HTP)
  |-- Native MOSS JNI: QNN HTP prefill/decode/codec + ORT CPU sampler
  `-- Flutter platform channel for MOSS package import and synthesis
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
- Cubism SDK for Native 5 R.5 obtained under the applicable Live2D terms; the default path is `D:\CubismSdkForNative-5`
- Visual Studio C++ desktop tools for Windows builds
- Flutter Linux desktop dependencies, GTK 3, CMake, Ninja, and a C++ toolchain for Linux builds

```powershell
$env:TALK2U_CUBISM_SDK_ROOT='D:\CubismSdkForNative-5'
flutter pub get

Push-Location rust
cargo test --all-targets
Pop-Location

flutter test
flutter analyze lib test
flutter build apk --debug --target-platform android-arm64
```

The Android package is currently restricted to `arm64-v8a`. Every enabled ABI must contain compatible Flutter, Rust, plugin, ONNX Runtime, and optional vendor runtime libraries.

Gradle and CMake consume the Framework sources, OpenGL ES shaders, headers, and ARM64 Core static library directly from the external SDK. Do not commit `Live2DCubismCore`, copied Core headers, or the Cubism SDK to a public repository. The local APK statically links Core into `libtalk2u_live2d.so`; binary distribution remains subject to the Live2D license accepted by the builder.

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

MOSS-TTS-Nano uses four ONNX stages: prefill, recurrent decode, local sampler, and streaming audio codec. Prefill, decode, and codec require full QNN HTP assignment. The v81 sampler intentionally uses ORT CPU. Sessions are loaded and released stage by stage to bound peak memory.

The HTP stages disable CPU EP fallback. The runtime reports the explicit mixed plan `QNN_HTP(prefill,decode)+ORT_CPU(sampler,codec)` only after a real synthesis returns a structurally valid WAV. Generic NNAPI is not used as Qualcomm execution evidence.

Android uses the same matching ONNX Runtime `1.26.0/API 26` core and QNN Plugin EP `2.4.0` artifacts as the reference project. Gradle enforces fixed SHA-256 values for the ORT core, Plugin EP, and C API header, preventing ABI mixing. QAIRT host libraries and the HTP skel come from a legally installed SDK. Prefill/decode use QNN HTP; sampler/codec use multithreaded ORT CPU and are never reported as NPU work. Physical-device graph execution remains mandatory proof.

### Qualcomm QNN HTP

QAIRT 2.48 is used to prepare fixed-shape recurrent graphs. V81 rejects the sampler's `QNN_CumulativeSum`, so that stage remains on ORT CPU. Raw dynamic ONNX is never accepted by the Android importer.

Supply local artifacts through Gradle properties or environment variables:

```powershell
$env:TALK2U_QNN_SDK_ROOT='D:\Qualcomm AI Engine Direct SDK'
$env:TALK2U_QNN_HTP_ARCH='v81'
flutter build apk --debug --target-platform android-arm64
```

MOSS deployment requires:

1. Prefill and decode finalize for SM8850/V81.
2. A fixed-capacity decode graph consumes its own outputs for 375 steps.
3. A physical SM8850 generates and plays a valid WAV.
4. Every deployment file is covered by the manifest size and SHA-256 checks.

Library presence or provider enumeration is never treated as execution proof.

### Huawei and NNAPI

The repository does not contain or directly integrate licensed Huawei HiAI DDK binaries. Generic NNAPI is not used as a substitute for Qualcomm QNN, so MOSS is unavailable on the Huawei Mate 10 Pro in the current implementation. NNAPI enumeration remains diagnostic only and is never used as evidence of MOSS hardware execution.

No OnePlus 15 or Huawei Mate 10 Pro real-device pass has been performed in this workspace. The code and build have been verified, but device acceptance requires the checklist below.

### Separate Local LLM Path

MOSS acceleration does not accelerate the local Qwen LLM. Android downloads the pinned Qwen3-4B-Instruct-2507 Q4_K_M GGUF with resume support, verifies its exact 2,497,281,120-byte size and SHA-256, then atomically installs it in app-private storage. llama.cpp validates `general.architecture=qwen3` and 36 transformer layers. Embedding, sampling, and small operations remain on CPU; transformer layers, matrix multiplication, and attention run on Adreno Vulkan. JNI streams accumulated UTF-8 output to Flutter token by token.

## Continuous Speech

The call button enables an Android turn loop:

```text
listen -> final recognition -> send -> generate -> speak -> resume listening
```

Android recognition always uses the installed SenseVoice INT8 model through sherpa-onnx. Ending the call or disposing the page stops the app recorder and MOSS playback.

The call requires both an available offline STT and offline TTS on the same device. It is not currently a full-duplex echo-cancelled telephony stack, and the Windows/Linux desktop build cannot start a complete offline call until desktop TTS is implemented.

## Silent Stage Directions

Speech preparation distinguishes stage directions from explanatory parentheses. For example:

```text
Input:  Girl: (laughs) You said it so well!
Spoken: You said it so well!
Cue:    happy at spoken offset 0
```

Parenthesized or bracketed content is removed only when it contains recognized action or emotion terms. Explanatory text such as `NNAPI (Neural Networks API)` remains spoken. Asterisk actions such as `*wave*` are silent and still produce a semantic cue. Offsets remain compatible with Android UTF-16 TTS range callbacks.

Actual motion quality depends on the imported model. Talk2U only plays a motion or expression that is explicitly mapped in `talk2u.avatar.json` or can be verified from model metadata. It does not assign semantics to arbitrary numbered motion files.

## Live2D and GPU Rendering

This project explicitly uses the Live2D Cubism SDK. Android renders through `AndroidView` -> `GLSurfaceView` -> `libtalk2u_live2d.so` -> Cubism SDK for Native 5 R.5 Framework/Core -> OpenGL ES. Model updates, motions, expressions, physics, pose, breathing, eye blink, lip sync, texture upload, and drawing run in Native C++. The renderer rejects SwiftShader, llvmpipe, softpipe, lavapipe, and software-labelled GL implementations. It reports ready only after the first frame completes without a GL error.

The separate native probe creates a Vulkan logical device and an EGL OpenGL ES context. Those results prove API availability only. The current Live2D frame is identified by `Cubism Native OpenGL ES`, the renderer/vendor/version strings from its own GL context, and an increasing `frameCount`. A Vulkan probe pass must not be reported as Cubism Vulkan rendering.

Windows and Linux retain the existing WebView2/CEF + Pixi path. The repository contains neither Native Cubism Core nor `live2dcubismcore.min.js`; each is consumed only from SDK files legally supplied by the builder. Never commit or vendor the Core or complete Cubism SDK into a public repository.

Official resources and terms:

- Live2D website: <https://www.live2d.com/en/>
- Live2D Proprietary Software License Agreement: <https://www.live2d.com/eula/live2d-proprietary-software-license-agreement_en.html>
- Live2D Open Software License Agreement: <https://www.live2d.com/eula/live2d-open-software-license-agreement_en.html>

On the verified PLK110/SM8850/API 36 device, Mao rendered on the Adreno 840 and continued animating. Two sampled frames differed in 18.113% of stage pixels; graphics statistics reported 653 frames, 0.46% jank, and a 3 ms GPU median. This does not substitute for acceptance testing on other drivers or models.

## Verification

Completed automated checks for this change include:

- Rust tests, including RustGLM error mapping
- Flutter speech planning and MOSS utility tests
- Android Kotlin compilation
- Android C++ external native build
- Dart formatting and diff whitespace checks

Real-device acceptance must include:

- Verify the NNAPI device list does not classify a CPU device as acceleration.
- Run one real Qwen generation and require verified `llama-vulkan` on an Adreno device; a loaded backend alone is insufficient.
- Run a real MOSS synthesis, require `QNN_HTP` with CPU EP fallback disabled, validate the WAV, and confirm playback.
- Verify `女生：（哈哈大笑）你说的太好了！` speaks only the dialogue and triggers a happy cue.
- Run at least 20 call turns, then end the call and confirm microphone capture and playback stop.
- Confirm the actual Live2D backend is `Cubism Native OpenGL ES`, the renderer is not software, and `frameCount` increases.
- Test airplane-mode STT, TTS, LLM, and Cubism assets separately; each requires its local asset to be present.
- Measure temperature, audio latency, memory, and battery drain on every release target.

## Claims That Must Not Be Made

- Do not claim QNN from an API symbol, library presence, or provider enumeration.
- Do not claim that the default ONNX Runtime AAR contains QNN EP.
- Do not claim direct Huawei HiAI DDK integration.
- Do not claim real-device validation on OnePlus 15 or Huawei Mate 10 Pro until it is performed.
- Do not label llama.cpp CPU execution as NPU or GPU execution.
- Do not claim Windows/Linux offline TTS, continuous offline calls, or local LLM hardware acceleration.
- Do not claim the native Vulkan probe is the actual Live2D renderer; Android currently uses Cubism Native OpenGL ES.
- Do not claim that Cubism Core is legally bundled with the public repository.

Failures are surfaced as unavailable capabilities or explicit errors. Qwen and MOSS do not fall back to CPU.
