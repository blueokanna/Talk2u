# Rust core: dependency boundaries and storage format

This document records what the Rust core uses, why it uses it, and what was
removed. It is written to be checkable: every claim below has a file, a symbol,
or a command attached to it.

## Why this file exists

The core previously carried several crates that overlapped. A conversation
touch went through `chrono` for time, `rmp-serde` for encoding, `reqwest` for
transport, and `discord` had a second `reqwest::Client` with its own timeout
policy. Three of those four were the only implementation of their concern, so
the problem was not the count — it was that each new call site could pick a
different one and the invariants (bounded payloads, atomic writes, no replay
after emission) lived in prose rather than in a type.

The rule now: one concern, one implementation, and the invariant is enforced
where the bytes are.

| Crate | Concern | Invariant it enforces |
| --- | --- | --- |
| `courierust` | Outbound HTTP/TLS + SSE body streaming | A retry never re-sends a request that already produced bytes |
| `rustglm` | The Zhipu **contract**: model capability registry, `thinking`/chunk wire types | A parameter the vendor rejects cannot be constructed, because the app does not hand-write the object |
| `rustbinary` | Conversation envelope on disk | A payload cannot be decoded beyond its declared bound |
| `tzcraft` | Instants | Time is one integer type everywhere, and comparisons cannot mix instant with duration |
| `recurse-x` | Name resolution as a diagnostic | A failed probe is reported as unknown, never as "endpoint is down" |
| `nextjson` | Serialisation derives | One derive family for both the file envelope and the settings blobs |

### What rustglm is, and is not, used for

`rustglm` is **not** the transport. Its client calls
`TlsSettings::with_system_roots()`, which on Android resolves to courierust's
`cfg(unix)` path (`/etc/ssl/certs/...`) and finds nothing — the CA store lives in
`/system/etc/security/cacerts` and `/apex/com.android.conscrypt/cacerts`. The SDK
also exposes no way to inject a `RootStore`: `HttpConfig` carries only
`tls_verify`. Using its client would mean a Zhipu-only path that cannot verify a
certificate on the platform this app ships to.

So the crate is used for what only it knows:

* `ModelCapabilities::of(model)` — which models reason, which accept
  `thinking.type: "disabled"`, which support `reasoning_effort`;
* `Thinking` — the exact wire object, serialised by the crate instead of by hand;
* `ChatCompletionChunk` / `ResponseContent` — the streaming delta shape,
  including content that arrives as parts rather than a string;
* `ApiError`-shaped status classification, which `ChatError::from_http_error`
  reproduces from the response body (the SDK's own `kind()` only looks at the
  status, and GLM's quota errors carry their meaning in `error.code`).

### The bug that registry caught

`build_request_body` used to send `thinking: {"type": "disabled", "budget_tokens": …}`:

* `budget_tokens` is not part of the vendor type at all — the object is
  `{"type": …, "clear_thinking": …}`;
* `glm-4.7` and `glm-4.7-flash` **always** reason and answer `400` for
  `thinking.type: "disabled"`, so turning the switch off produced a failed
  request instead of a faster answer.

`model_policy::thinking_for` now returns one of `Omit` / `Enabled` / `Disabled`
from the registry and the request builder serialises `rustglm::Thinking`, so the
field is simply absent for models that cannot honour it. `glm-4-air`, which the
registry does not track, keeps an explicit legacy entry rather than a guess.

## Clock (`rust/src/api/clock.rs`)

`now_millis()` is the only way the core asks what time it is. It reads
`tzcraft::Ticks` (128-bit nanoseconds) and converts to `i64` milliseconds
because that is the widest instant Flutter can carry through
`flutter_rust_bridge` without loss.

Two details matter in production:

* The fallback is `SystemTime` and it exists because `Ticks::now()` fails only
  when the device clock is set before 1970. Falling back keeps message ordering
  usable; returning `0` would stamp every message identical and make the list
  sort by insertion accident.
* `format_utc` is used by the Discord bridge log lines, which run for days at a
  time with a 2–5 s poll interval. A log line without an instant is not
  attributable after the fact.

## Conversation storage (`storage_codec.rs` + `conversation_store.rs`)

Files are `T2UB`:

```
offset  size  field
0       4     magic "T2UB"
4       2     format version (u16, little endian)
6       4     payload length (u32, little endian)
10      n     rustbinary-encoded Conversation
```

* The length prefix is checked against the actual file size before decoding, so
  a truncated or hostile file fails as a typed error instead of allocating.
* Writes are write-to-temp + `rename`, so a process kill mid-write leaves the
  previous conversation intact rather than a half-file.
* `.msgpack` and `.json` files from earlier builds are still read. Migration is
  read-only in the sense that matters: the legacy file is decoded, re-encoded as
  `T2UB`, and the new file is renamed into place; nothing is deleted until the
  rename succeeds.
* `rmp-serde` remains solely for that decoder. It is listed in `Cargo.toml` with
  that comment so nobody has to rediscover it.

`storage_path.rs` validates conversation ids against path traversal before they
are joined into a path. Ids arrive from Dart, so they are untrusted input.

## Transport (`rust/src/api/transport.rs`)

`courierust` is a blocking client, so the whole request runs on the blocking
pool and results come back through a channel.

**One pipeline.** Every provider — Zhipu, DeepSeek, OpenAI, Kimi, Qwen, custom
endpoints — posts to `transport::post_stream` and is parsed by the same SSE state
machine. There is no provider-specific HTTP client, no second retry policy and no
per-provider stream reader, which is what makes "does the app handle a truncated
stream?" a single question with a single answer.

* **Streaming.** `post_stream` returns a `ByteStream` that yields chunks as they
  arrive; `SseDecoder` turns those chunks into complete lines, holding only the
  bytes of the line currently in flight. A line that exceeds 256 KiB without a
  newline aborts the stream with a typed error instead of growing the buffer
  until the process dies ? a slow trickle of bytes is exactly how a long reply
  and a hostile peer are made to look alike.
* **Retry.** `next_delay` is a pure function so the policy is testable without a
  socket. It refuses to retry once bytes have been emitted: replaying a partially
  consumed completion would duplicate text in the conversation. It also honours a
  server-supplied `Retry-After`, clamped to 30 s so a bogus header cannot park a
  request forever.
* **Android trust anchors.** `courierust`'s `cfg(unix)` system-root branch only
  looks at `/etc/ssl/...`, which does not exist on Android. `trust_anchors()`
  loads the hashed CA files from `/system/etc/security/cacerts` and from
  `/apex/com.android.conscrypt/cacerts`, so the app trusts exactly what the
  device trusts — including user-installed CAs, which matters for corporate
  proxies.
* **Headers.** `headers_from_pairs` and `secret_header_value` are the only ways a
  header reaches the wire, and both reject CR/LF. A key pasted with a newline is
  a header-injection primitive, not a typo.
* **URLs.** `validate_http_url` rejects anything that is not absolute `http(s)`
  with a host. `file://` in a provider field would otherwise be a local file read.

`ProviderRuntime::request_headers` returns courierust's `HeaderMap` directly, so
there is no conversion layer to drift out of sync.

### Errors come from the body, not from the provider name

GLM reports quota and concurrency failures in `error.code` inside the response
body, with an HTTP status that says nothing useful (`1302` usually arrives as
400). `ChatError::from_http_error` therefore parses the body and only falls back
to status mapping when there is no code:

| Body | Error | Retryable |
| --- | --- | --- |
| `error.code` 1302 / 1303 / 1305 | `RateLimitError` | Yes |
| `error.code` 1001–1004, 1110–1112, 1120–1121 | `AuthError` | No |
| `error.code` 1113, 1304, 1308, 1310 | `GlmBusinessError` | No |
| no code, 401/403 | `AuthError` | No |
| no code, 429 | `RateLimitError` | Yes |
| no code, 5xx | `ApiError` | Yes |
| not JSON | `ApiError` with the body truncated to 1000 chars | By status |

This classification used to come free with the Zhipu SDK's `GlmError`. It is
reproduced here from the wire format, so moving Zhipu onto the shared transport
did not cost the retry decisions — `glm_business_codes_survive_without_the_sdk`
is the test that pins that down.

### TLS interop, measured

Trust anchors come from the device at startup, not from a vendored bundle. That
is the right default, and it also means the app inherits every limitation of a
native-root client:

* The store is a **snapshot**. Windows auto-fetches third-party roots on demand
  while browsing, so a profile that has never visited a given CA's sites may not
  have that root yet. Measured on this machine: 59 roots enumerated, and a
  cross-signed chain with no local root fails with `no trusted root found`.
* A server that omits intermediate certificates fails the same way; courierust
  does not chase `AIA` extensions.
* A receiver with an old TLS stack can reject the `ClientHello` outright
  (`www.baidu.com` answers with a `protocol_version` alert, description 70).

None of these affect the endpoints this app targets. Verified here against
`open.bigmodel.cn` (200), `api.deepseek.com` (401), `api.anthropic.com` (403) and
`www.cloudflare.com` (200) — every case proves the handshake, which is what the
opt-in test asserts. Because every provider shares this client, a provider cannot
silently have different TLS behaviour from its neighbours.

## DNS diagnosis (`rust/src/api/network_diagnosis.rs`)

`courierust` resolves through the platform stub resolver. That is correct for
normal operation and useless for diagnosis: when a name is poisoned or filtered,
the stub returns an address that connects nowhere, and the app can only say
"network error".

`recurse-x` walks the delegation chain from the root and answers the question the
stub cannot: what does this name actually resolve to, independent of what the
device was told?

The diagnosis asks *two* resolvers the same question, because either one alone
is either unreliable or uninformative:

* the **device** resolver (`std::net::ToSocketAddrs`, i.e. the path the
  transport itself takes). Always available, and its answer is the one that has
  to be explained.
* the **walk** (`recurse_x`, root-referral driven). Independent by
  construction, and only available when the network lets UDP/53 out.

The verdict is a pure function of both answer sets and the rcode:

| Device | Walk | Verdict | What the user is told |
| --- | --- | --- | --- |
| any | any loopback / RFC 1918 / link-local / unique-local | `suspicious` | Likely DNS hijack or a local `hosts` override, with both answers |
| public | public, shares an address | `resolved` | The name is fine; the problem is the path to that address |
| public | public, disjoint | `disagreement` | Both answers shown; explicitly says this may also be CDN steering |
| public | walk failed | `unverified` | The device answer is shown, plus "cannot rule out local tampering" |
| ? | walk failed, device empty | `inconclusive` | No hint is appended at all |
| ? | empty, `NOERROR` | `empty` | Upstream filtering |
| ? | empty, `NXDOMAIN` | `nxdomain` | The name does not exist |

Three deliberate limits:

* **It is not a gate.** Iterative resolution needs outbound UDP/53 to the root
  servers; captive portals and some networks drop it. A failed walk therefore
  never blocks a request and never produces a hijack claim ? the app does not get
  to blame the network for its own blind spot.
* **Disagreement is not an accusation.** A CDN hands different edges to
  different resolvers, so a disjoint answer set is reported as a difference with
  both address lists, not as interference.
* **It is bounded.** 6 s for the whole probe, on the blocking pool. The
  connection test already waited for the failing request; the diagnosis is not
  allowed to multiply that wait.

Wiring: `chat_api::validate_api_key` appends the hint only when the stream failed
with `ChatError::NetworkError`, which is the only failure the diagnosis can speak
to.

## Release builds: two rules the debug build never exercises

R8 is only applied to `release`, so both of these fail on a debug build and kill
the shipped app on the first launch.

**1. Native entry points must survive minification.** `libnpu_jni.so` resolves
`com.geniex.sdk.*` by name with `FindClass`/`GetStaticMethodID`. R8 renamed
`ModelManagerWrapper` to `D.g`, the lookup returned null, and ART aborted:

```text
Abort message: 'JNI DETECTED ERROR IN APPLICATION: java_class == null
#06 libnpu_jni.so (Java_com_geniex_sdk_jni_ModelManager_getPaths+288)
```

The GenieX AAR ships no consumer rules, so `android/app/proguard-rules.pro` keeps
`com.geniex.**`, every class that declares a `native` method (the JNI symbol name
is derived from the declaring class), and the attribute set Kotlin's suspend
shapes need.

**1b. Reflective field names must survive too.** `libsherpa-onnx-jni.so` resolves
`decodingMethod`, `featConfig`, `modelConfig` ? with `GetFieldID`. With only the
GenieX rule in place, R8 renamed the field, `OfflineRecognizer`'s constructor
threw before the microphone was ever opened, and every utterance failed:

```text
java.lang.NoSuchFieldError: no "Ljava/lang/String;" field "decodingMethod"
    in class "Lcom/k2fsa/sherpa/onnx/OfflineRecognizerConfig;"
    at com.k2fsa.sherpa.onnx.OfflineRecognizer.newFromFile(Native Method)
```

`-keep class com.k2fsa.sherpa.onnx.** { *; }` is what makes that lookup succeed.
Verification is static and cheap: the release dex must still contain
`decodingMethod`, which is a five-line check on the shipped artifact.

**2. Platform-channel replies are main-thread-only.** `FullDuplexAudioCapture`
delivered each 20 ms frame straight from its capture thread, and Flutter aborts
the process:

```text
FATAL EXCEPTION: talk2u-full-duplex-capture
java.lang.RuntimeException: Methods marked with @UiThread must be executed on the main thread.
    at io.flutter.embedding.engine.FlutterJNI.dispatchPlatformMessage
```

Frames now hop to a main-thread `Handler` in arrival order and are never dropped:
the recognizer needs every sample, and one 20 ms frame is 640 bytes, so even a
long main-thread stall cannot turn the queue into a memory problem. The existing
`deliverLlmResult` helper already followed this rule; the capture path did not.

## What was removed, and why

| Removed | Reason |
| --- | --- |
| `chrono` | `tzcraft` covers every instant the core needs |
| `reqwest`, `rustls`, `aws-lc-rs` | Second TLS/HTTP stack; `courierust` owns all outbound traffic |
| `rustls-platform-verifier`, `android_tls.rs`, `MainActivity.initializeRustTls`, `org.rustls.platformverifier` proguard rule | The Android TLS hand-off existed only for reqwest's rustls backend. With reqwest gone it is dead code, and the JNI ordering hazard it created is gone with it |
| `futures` | Only `StreamExt` was used, and `ByteStream::next` is an inherent method |
| `RetryHandler` (`error_handler.rs`) | Retry belongs to the transport, which is the only layer that knows whether bytes were emitted |
| `StreamTimeoutConfig::tcp_keepalive_secs`, `connect_timeout_secs` | Never read; `courierust` owns socket options |
| Groovy `JsonSlurper` metadata probe in `app/build.gradle.kts` | It existed to locate the rustls Android AAR through `cargo metadata`; with that dependency gone, Gradle no longer needs a Rust toolchain at configuration time |
| `bincode-next`, `proptest`, `tokio-test`, `rsntp`, `hmac`, `sha2`, `base64url` | Zero call sites |
| `examples/zhipu_stream_probe.rs` | It existed to exercise the SDK client, which this app must not use (see the trust-anchor note above); the opt-in `courierust_completes_a_tls_request` test covers the path that actually runs |
| `StreamingHandler::stream_zhipu_chat`, `zhipu_base_url`, `map_glm_error` | The Zhipu-only transport; `rustglm::SdkError` mapping died with it, and its retry semantics now live in `transport::next_delay` |
| hand-written SSE line buffering in `stream_chat` | Replaced by `SseDecoder`, which also bounds a line that never terminates |

## Version constraints worth knowing

* `tzcraft 0.1.2` with default features requires `rustbinary` feature `alloc`,
  which `rustbinary 0.1.8` does not publish. The pair is therefore used as
  `tzcraft = { version = "0.1.2", default-features = false, features = ["std"] }`;
  anything else fails to resolve.
* `recurse-x` is used with `default-features = false, features = ["std"]`. The
  `dot`/`doh`/`doh3`/`doq`/`persist`/`dnssec` features are not needed for a
  plain UDP delegation walk, and enabling them would pull a second TLS stack and
  the `rustbinary` fingerprint/reflection features into the Android build.
* `rust-version = "1.88"` is declared because that is the oldest *complete*
  toolchain available to verify this build; the code itself needs 1.87
  (`u32::is_multiple_of` in `memory_engine.rs`), and the heaviest dependency
  floor is 1.85 (`uuid`, `jni`, `tokio`, `rmp-serde`).

## Verification

```text
cd rust
rustup run 1.99.0 cargo test --lib          # 158 pass, 2 opt-in network tests
rustup run 1.99.0 cargo check --lib         # no warnings

cd ..
flutter analyze                              # No issues found
flutter test                                 # 83 tests
flutter build apk --release --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

`frames_arrive_before_the_response_is_complete` is the one that matters most
here: a loopback `courierust` server sends one SSE frame, then blocks until the
client confirms it received it. A transport that buffered the body until EOF
would deadlock and fail on its timeout, so the test proves incremental delivery
by construction rather than by timing.

Two tests need network and are opt-in:

```text
cd rust
rustup run 1.99.0 cargo test --lib -- --ignored courierust_completes_a_tls_request
rustup run 1.99.0 cargo test --lib -- --ignored dns_walk_reaches_the_delegation_chain
```

The first proves trust anchors + TLS + HTTP framing against the provider domain.
The second needs outbound UDP/53 to the root servers and legitimately fails on
networks that drop it — which is exactly the degradation the diagnosis reports as
`unverified` rather than as a hijack.

## Device verification (PLK110 / SM8850 / Android 16)

Measured on the release APK, not asserted from the design:

| Surface | Evidence |
| --- | --- |
| QNN runtime | `runtime={bundled=true, ready=true, gpuReady=false, architecture=v81, pluginRegistered=true, epDeviceCount=1, ortVersion=1.26.0, qnnPluginVersion=2.4.0, qairtSdkVersion=2.48.0, fastRpcDevices=[/dev/fastrpc-cdsp]}` |
| Local LLM | `activeBackend=geniex-qairt-npu, activeBackendVerified=true, computeUnit=npu`, measured `prefillTokensPerSecond=171.2`, `decodeTokensPerSecond=8.0` |
| MOSS TTS | `synthesis provider=QNN_HTP(prefill,decode)+ORT_CPU(sampler,codec)`, `frames=31 elapsedMs=3441 prefill=77 decode=2356 codec=522 htp_busy=462` |
| SenseVoice | loads a QNN context binary with the plugin, then transcribes 10 s windows; the window count and audio length are returned from the native side |
| Echo cancellation | `Talk2U/FullDuplex: audio session=5769 aec=true ns=true agc=false` ? full duplex enabled |
| Live2D | Impeller/Vulkan (`libvulkan.adreno.so`, `Application Name = Talk2U Live2D`) plus the native GLES renderer |

`gpuReady=false` is expected: `libQnnGpu.so` is not packaged, and every engine
here uses HTP or ORT, never the QNN GPU backend. `agc=false` is the honest
read-back of `AutomaticGainControl.enabled`; the app does not claim otherwise.

Known warning, not a defect: sherpa-onnx logs
`Failed to get field ID for 'decodingMethod'`, because the Kotlin API inside the
prebuilt AAR is older than its JNI. It falls back to greedy search, which is what
SenseVoice expects; aligning it means rebuilding the AAR, not changing this app.
