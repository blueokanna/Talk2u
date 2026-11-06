# Talk2U

Talk2U is a Flutter and Rust character chat application. Conversations, character profiles, memories, and knowledge are stored locally. Replies can come from a configured online LLM or from the on-device Qwen model on Android. Android speech is app-managed: sherpa-onnx SenseVoice INT8 provides STT and MOSS-TTS-Nano provides TTS through Qualcomm QNN HTP.

This document describes the implemented behavior and its verification boundary. It does not claim that proprietary accelerators or third-party services work without their licensed runtime, device driver, model support, credentials, and real-device validation. See [README.md](README.md) for the full Chinese guide.

## Download link for the open-source model with built-in folder in the Model folder
[Download](https://1drv.ms/f/c/716401d0cdd5bd0e/IgDdaEU7EX-mRqR-h47_q-UUAftK4GNb5I9nDv1JGAVG0ik?e=VTbi0P)

## Capability Matrix

| Capability | Status | Implementation |
| --- | --- | --- |
| Zhipu GLM | Implemented | OpenAI-compatible wire over the shared `courierust` transport, same SSE parser as every other provider |
| DeepSeek, OpenAI, Kimi, Qwen | Implemented | OpenAI-compatible streaming adapters |
| Anthropic | Implemented | Messages API headers, request conversion, and Anthropic SSE |
| Local memory and knowledge | Implemented | Rust local storage, recent context, summaries, and fact retrieval; durable system blocks are kept within a token budget |
| Android local LLM | Implemented | `Qwen/Qwen3-4B-Instruct-2507` Q4_K_M through llama.cpp; the 4096-token window is budgeted by tokens and the output cap is 1024 tokens |
| Offline STT | Implemented | sherpa-onnx SenseVoice 2024-07-17 INT8 QNN context on SM8850, preserving ASR/LID/SER/AED results |
| Continuous voice call | Conditional on Android | `CallSession` state machine; full duplex when the platform confirms hardware AEC, half duplex otherwise; reference-anchored double-talk detection plus lexical self-echo rejection; voice or tap interruption |
| Regenerate | Implemented | The rejected reply is excluded from the new prompt, an explicit anti-repetition directive is added, sampling uses temperature/top_p 0.95, and the old message is replaced in place |
| Idle resource use | Implemented | No 1 Hz telemetry polling, no always-on 30 ms stream timer, and no automatic speech synthesis outside call mode |
| Android offline TTS | Conditional | MOSS prefill/decode/codec on QNN HTP and sampler on ORT CPU; no system TTS fallback; emoji, Markdown, code, URLs and blank lines are filtered before synthesis |
| Windows/Linux offline TTS | Not implemented | The current desktop speech path only provides SenseVoice STT |
| Live2D | Conditional | Cubism SDK for Native 5 R.5 with C++/OpenGL ES on Android; WebView2 on Windows and CEF on Linux |
| Live2D semantic cues | Implemented, model-dependent | Context, emoji and silent stage directions select configured motion or expression mappings; equivalent performances rotate within a long reply |
| Android Live2D GPU rendering | Implemented | Native C++ Cubism OpenGL ES renderer; software GL implementations are rejected and ready follows the first valid frame |
| Android NNAPI diagnostics | Implemented | Device name, version, type, and feature level; CPU devices are excluded from accelerator results |

An implemented online provider still requires a valid API key, account quota, reachable endpoint, and a model ID enabled for that account.

## Research Contributions

The AHCA paper in `docs/emotion_aware_rag_paper.tex` covers the context layer (identity anchoring, tiered memory, W-RRF retrieval, emotional decay, diversity regulation). On top of it this repository implements four systems-level mechanisms that are code paths, not diagrams:

1. **Reference-anchored turn taking (RATT).** The agent synthesises its own audio, so it already holds the echo reference. A 20 ms amplitude envelope plus a 180 ms peak-hold turns blind echo-path identification into known-reference detection and removes the device-delay dependency; the measured `enabled` state of the platform `AcousticEchoCanceler` gates full duplex versus half duplex. See `turn_taking.dart`, `call_session.dart`, `FullDuplexAudioCapture.kt`, and [docs/reference_anchored_turn_taking.tex](docs/reference_anchored_turn_taking.tex).
2. **Regeneration without self-priming.** The rejected reply is excluded from the new prompt, its opening/ending/shape become an explicit anti-repetition constraint, temperature and top-p are raised together, and the message id is preserved on success. The point is that regeneration is not resampling: it is a forced divergence from a specific prior output. See `chat_engine.rs::regenerate_response`.
3. **Non-verbal affect transduction.** MOSS exposes neither an emotion parameter nor SSML. Emoji and Markdown structure are mapped to pauses and punctuation the vocoder handles correctly, and the same symbols decide the sustained expression for the whole reply; an emoji-only reply skips synthesis. See `speech_text_normalizer.dart`.
4. **Playback-anchored performance timeline.** The generated WAV envelope is the time base; silent stage directions, emotion words and emoji offsets drive frame-level Live2D cues, with equivalent performances rotating inside an emotion family. See `offline_speech_service.dart` and `live2d_native_renderer.cpp`.

No number is claimed without a corpus: barge-in latency, false-interruption rate, self-echo turn rate and over-suppression rate are specified as a protocol with ablations in the paper section, and the repository deliberately does not hard-code results.

## Rust dependency boundaries

The Rust core keeps one crate per job. Every dependency owns exactly one concern, and no two of them implement the same concern:

| crate | Role | Where |
| --- | --- | --- |
| `courierust` | The only outbound HTTP/TLS implementation: incremental SSE parsing, retry without replay, Android trust-anchor loading | `rust/src/api/transport.rs` |
| `rustglm` | The Zhipu contract only: model capability registry, `thinking` and streamed-chunk wire types. Its HTTP client is deliberately unused — see the Zhipu section | `rust/src/api/model_policy.rs` |
| `rustbinary` | Conversation envelope on disk (`T2UB` magic + version + bounded decode), read-only migration of the old format | `rust/src/api/storage_codec.rs` |
| `tzcraft` | The single time source: 128-bit nanosecond `Ticks`, floor semantics, identical on every platform | `rust/src/api/clock.rs` |
| `recurse-x` | Independent recursive DNS, cross-checked against the device resolver to separate hijack from path failure | `rust/src/api/network_diagnosis.rs` |
| `nextjson` | Serialisation derives for persisted structs | `rust/src/api/data_models.rs` |

`reqwest` and `rustls` do not appear anywhere in the dependency tree. Every provider — Zhipu, DeepSeek, OpenAI, Kimi, Qwen, custom endpoints — goes out through the same `courierust` client, which on Android reads trust anchors from `/apex/com.android.conscrypt/cacerts` and `/system/etc/security/cacerts` because the crate's own `load_system()` only knows the Linux bundle layout. That loader is why the app trusts exactly what the device trusts, including user-installed CAs.

See [docs/rust_stack.md](docs/rust_stack.md) for the design rationale, migration semantics, and verification commands.

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

## Zhipu

Zhipu is not a second transport. Its endpoint speaks the OpenAI chat-completions wire, so it goes through the same `transport::post_stream` + SSE state machine as every other provider; only `api_url`, `api_key` and the model id differ. There is one TLS trust store, one retry policy and one parser to reason about.

`rustglm` 1.1.0 is still a dependency, but not as the HTTP client — its client resolves trust anchors with `TlsSettings::with_system_roots()`, which only knows the Linux bundle layout and therefore cannot verify anything on Android. What it is used for is the part only it knows:

* `ModelCapabilities::of(model)` decides whether a model reasons, and whether `thinking.type: "disabled"` is legal for it. `glm-4.7` and `glm-4.7-flash` always reason and answer `400` to that flag, so the app omits the field instead of asserting it — the previous hand-written table got this wrong and also invented a `budget_tokens` key the vendor type does not have.
* `Thinking` produces the exact `thinking` object, serialised by the crate.
* `ChatCompletionChunk` decodes streamed deltas, including content delivered as parts rather than a string.

Business codes are classified from the body, since GLM reports quota and concurrency problems in `error.code` rather than in the status line:

| Response | Talk2U error | Retryable |
| --- | --- | --- |
| `error.code` 1302 / 1303 / 1305 (concurrency, rate, overload) | Rate limit | Yes, with backoff |
| `error.code` 1001–1004, 1110–1112, 1120–1121 | Authentication | No |
| `error.code` 1113, 1304, 1308, 1310 (balance, daily/monthly quota) | GLM business error | No |
| HTTP 401/403 without a code | Authentication | No |
| HTTP 429 without a code | Rate limit | Yes |
| HTTP 5xx without a code | API error | Yes |
| Non-JSON body | API error with the body truncated to 1000 chars | By status |

A stream that ends with a JSON `error` object, or with `finish_reason: "sensitive"`, surfaces as a stream error instead of a silent empty reply.

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

Android recognition always uses the installed SenseVoice INT8 model through sherpa-onnx. The turn loop lives in `CallSession` (idle / listening / thinking / speaking / halted) instead of a set of page booleans.

**Echo cancellation is measured, not asserted.** Capture runs through `FullDuplexAudioCapture`: `AudioRecord` on the `VOICE_COMMUNICATION` source with the platform `AcousticEchoCanceler` attached to the real audio session id, reading `enabled` back after attachment (`NoiseSuppressor` and `AutomaticGainControl` are verified the same way).

| Platform measurement | Mode | Microphone during playback |
| --- | --- | --- |
| AEC attached and `enabled == true` | full duplex | stays open, voice interruption enabled |
| AEC unavailable or refused | half duplex | closed until playback ends |

The status row states which mode is active, so a device limitation cannot be mistaken for a broken barge-in.

Full duplex does not use a bare energy threshold. It uses the agent's own playback as the reference (`ReferenceAnchoredEchoGate`): the 20 ms amplitude envelope of the synthesised audio is the known reference, a 180 ms peak-hold removes the device-dependent 20–120 ms delay, and the residual is predicted as `E = λR`. A frame counts as near-end speech only after 140 ms of observed energy above `max(noiseFloor × 3.2, 1.6E + 0.012)`; `λ = 0.18` with a verified canceller and `0.55` without. The derivation and full protocol are in [docs/reference_anchored_turn_taking.tex](docs/reference_anchored_turn_taking.tex).

Energy says *when* to yield, not *whether* the transcript is the user's. A second gate (`SelfEchoTranscriptFilter`) compares the transcript against the text actually spoken in the last 8 seconds using a character-bigram Dice coefficient: `≥ 0.6`, or an 8+ character substring, is dropped. Transcripts shorter than six normalised characters are never rejected, so a real "好的" survives.

Interruption paths:

1. Start talking: the double-talk detector stops playback immediately and the transcript becomes the next turn.
2. Tap the Live2D area or the mic: playback and generation stop; in call mode the turn is handed back.
3. Type in the composer: playback stops and the turn is marked as awaiting a reply.

Two guards exist because this is now real full duplex: energy-based interruption is ignored for 900 ms after a turn is dispatched (otherwise the tail of the utterance that started the turn cancels the reply it triggered), and in the `thinking` state the reference is zero, so sustained speech is treated as a genuine interrupt and cancels generation. A 120 s idle turn timer returns the floor.

The call requires both offline STT and offline TTS on the same device. The Windows/Linux desktop build cannot start a complete offline call until desktop TTS is implemented.

## Speech Text Normalization

Replies are normalized before synthesis instead of sending Markdown and emoji to the vocoder:

- Reasoning blocks (`<think>`, `<analysis>`), fenced code, inline code, URLs, emails, HTML and emoji shortcodes are removed.
- Markdown headings, list markers, blockquotes, table rules and emphasis markers are removed; link labels are kept.
- Emoji are never spoken. They become natural pauses or affect the sustained emotion, and an emoji-only reply is skipped entirely.
- Blank lines collapse into sentence pauses; newline characters never reach MOSS. Ellipses and repeated punctuation normalize to a single natural pause.
- Stage directions stay silent but keep their timeline offsets; explanatory parentheses such as `NNAPI (Neural Networks API)` remain spoken.

MOSS-TTS-Nano's public JNI accepts only text and a voice id; it has no separate emotion parameter. Emotional delivery therefore relies on preserving the model's expressive punctuation and mapping emoji to standard pauses (`，`, `……`, `！`, `？`). The dominant emotion also selects the avatar's first expression and is carried through the per-sentence cue timeline; no unsupported SSML or invented emotion weights are used.

## Silent Stage Directions

Speech preparation distinguishes stage directions from explanatory parentheses. For example:

```text
Input:  Girl: (laughs) You said it so well!
Spoken: You said it so well!
Cue:    happy at spoken offset 0
```

Parenthesized or bracketed content is removed only when it contains recognized action or emotion terms. Explanatory text such as `NNAPI (Neural Networks API)` remains spoken. Asterisk actions such as `*wave*` are silent and still produce a semantic cue. Offsets follow the cleaned UTF-16 text passed to the avatar.

### Regeneration semantics

Regeneration is not the same prompt sent twice. The Rust engine excludes the rejected reply from the new context, writes the old opening/ending/paragraph shape into an explicit anti-repetition directive, adds a time-rotated creative direction, and samples at `temperature=0.95` / `top_p=0.95`. On success the previous message is replaced in place and keeps its id; on failure or cancellation the old reply is left untouched.

Actual motion quality depends on the imported model. Talk2U only plays a motion or expression that is explicitly mapped in `talk2u.avatar.json` or can be verified from model metadata. It does not assign semantics to arbitrary numbered motion files. Emotion families rotate through equivalent variants (`happy` → `happySoft` → `excited`) so long replies do not repeat one motion, and the native renderer layers slow gaze drift, head sway and speech-driven body movement on standard Cubism parameters when the model exposes them.

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

- Rust tests, including GLM business-code and HTTP status error classification
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
