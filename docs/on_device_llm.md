# On-device LLM: weights, artifacts, accelerators

This document is the contract between the Flutter app, the Kotlin runtime and the
compiled model it executes. It states what the app accepts, why, and what it
refuses. Every rule below is enforced in code and covered by a test you can run
on a host machine without a phone.

## 1. Which weights

Two presets are supported, and both run on the Hexagon NPU.

| Preset | Weights | Install paths | Nucleus |
| --- | --- | --- | --- |
| `abliterated` | `huihui-ai/Huihui-Qwen3-4B-Instruct-2507-abliterated` | import QAIRT bundle or GGUF | no published bundle |
| `base` | `Qwen/Qwen3-4B-Instruct-2507` | AI Hub pull (QAIRT), import QAIRT bundle or GGUF | Qualcomm has a compiled bundle |

| Field | Value |
| --- | --- |
| Architecture | Qwen3 decoder (36 layers, hidden 2560) |
| License | Apache-2.0, inherited from the base checkpoint; re-verify the derivative card before redistribution |
| Context | 4096 tokens |
| Output budget | `4096 - prompt - 128`, clamped to 512–3072 tokens |

The output budget is computed per turn rather than fixed at 1024. A short prompt
can use the full 3072-token ceiling; a long history still reserves 512 tokens so
a reply is never silently starved to a few words. The Kotlin runtime enforces the
same 3072 ceiling, and the Dart prompt builder trims an oversized system prompt
from the tail before spending the remainder on recent turns.

The derivative repository publishes **safetensors**. No mobile runtime executes a
safetensors checkpoint directly, and no public source publishes a pre-compiled NPU
bundle for it. The app therefore does not pretend to "download the model": it
installs a **compiled artifact** produced from those weights — a QAIRT bundle you
compile, or a GGUF — and it says which engine that artifact will run on.

For `base`, the original path is kept: GenieX pulls Qualcomm's chipset-matched
QAIRT bundle from the AI Hub catalog. That is the one preset where "download"
is a truthful label.

Both identities are visible in the settings card, each with its own install
actions, and the installed one is marked. The Dart side does not hard-code that
list: `OfflineLlmService.presets` parses `capabilities.presets` from
`OnDeviceLlmRuntime`, which reports the id, display name, base model, license and
hub key for every preset the packaged GenieX build can actually load. Before the
native report arrives, the two built-in identities are used so the card is
correct on first frame. The AI Hub action is only rendered for a preset that
declares a `hubModel`, which is why the abliterated row offers imports only.

## 2. Accepted artifacts

Exactly two formats are executable, and both are imported from a file the user
selects. Import is a three-phase transaction: copy into `staging/`, validate the
copy, swap it into place. A cancelled or rejected import leaves the previously
installed artifact untouched.

### 2.1 QAIRT bundle (`ArtifactKind.QAIRT_BUNDLE`) — Hexagon NPU

A ZIP archive containing the Genie dialog configuration and the compiled context
binaries. The validator (`QairtBundle.kt`) requires:

- `genie_config.json` at the bundle root (or one directory below it);
- `dialog.context.size == 4096` — the KV cache the runtime requests;
- `dialog.tokenizer.path` — an existing, non-empty file inside the bundle;
- `dialog.engine.backend.type == "QnnHtp"` — a GPU or CPU compiled graph is
  rejected, because this path is the NPU path;
- `dialog.engine.backend.extensions` — optional, but must exist when declared;
- `dialog.engine.model.type == "binary"` and a non-empty `binary.ctx-bins` list,
  every entry present and non-empty;
- `metadata.json` with `runtime == "genie"`, `precision == "w4a16"` and a
  non-blank `model_id`.

All declared paths are resolved with `SafeRelativePath`, so a `../../` in the
archive is rejected before it becomes a read outside the bundle.

The first context binary is the session entry point; `metadata.json`'s
`model_id` is reported in diagnostics and in the settings card, so you can see
which declared model a bundle identifies itself as.

### 2.2 llama.cpp GGUF (`ArtifactKind.GGUF`) — Hexagon NPU; GPU/CPU only by explicit request

A single `.gguf` file. `rust/src/api/gguf.rs` parses the header through JNI and
the importer requires:

- magic `GGUF`, version 2 or 3;
- a non-zero tensor count;
- `general.architecture == "qwen3"`.

Everything else about the file is reported (`general.name`, `general.file_type`,
`qwen3.block_count`, `qwen3.embedding_length`) and shown in diagnostics. The
check exists because a 2.5 GB copy that loads and then answers garbage is worse
than a rejected import.

A GGUF of these weights is published by `mradermacher` as
`Huihui-Qwen3-4B-Instruct-2507-abliterated-GGUF`. **Q4_0 and Q8_0 are the only
accepted exports.** GenieX's run notes are explicit that K-quants (including the
common `Q4_K_M`) leave some tensors on the CPU: the session still reports NPU,
but the heat and latency come from those CPU kernels. The importer therefore
rejects any other `general.file_type` with a message naming the quantization and
asking for a re-export; accepting it and labelling the card `mixed CPU` would
still burn CPU time the user explicitly ruled out. A header with no
`general.file_type` is rejected for the same reason. The `mradermacher` mirror
publishes Q8_0 (4,280,405,792 B) and K-quants but **no Q4_0**, so Q8_0 is the
clean-HTP Huihui artifact available today. A pure Q4_0 can be derived from that
Q8_0 without changing the weights:

```bash
llama-quantize --allow-requantize --pure \
  Huihui-Qwen3-4B-Instruct-2507-abliterated.Q8_0.gguf \
  Huihui-Qwen3-4B-Instruct-2507-abliterated.Q4_0.gguf Q4_0
```

The result used on the test device is 2,269,269,792 B, SHA-256
`d16aa41cfc07b40951a2b5df12c61e09187be0eb8e3d07b9ccad4ec46a9c3dae`, with
`general.file_type=2` and all 253 weight tensors at Q4_0 (the 145 one-dimensional
norm tensors stay F32). It is a local derivative of the official Q8_0, not an
upstream release; the app accepts it because the header and tensor types are the
Q4_0 contract. Q4_0 fits the per-session HTP address window; Q8_0 is larger and
relies on the backend's mapping of weights in and out of the session.

### 2.2.1 `auto`: NPU first, CPU fallback, never GPU

The launcher uses `auto` by default. For a GGUF the candidate list is:

1. the Hexagon NPU (`npu` → `HTP0`, `nGpuLayers = -1`);
2. the CPU, only if the NPU candidate cannot be opened.

The GPU is deliberately not in the automatic ladder; it remains an explicit
`gpu` request for diagnostics. If the HTP backend is absent, the NPU session is
destroyed, the reason is appended to `rejectedAccelerators`, and the CPU session
is opened. The failure is visible in diagnostics and the UI labels the active
backend `geniex-llamacpp-cpu`; a CPU turn is never marked as verified hardware
acceleration. QAIRT bundles have no CPU runtime, so that path reports the NPU
failure rather than hiding it.

At session open the Kotlin runtime asks the Rust GGML probe which backends the
loaded llama.cpp plugin actually registered. The probe opens the already-mapped
`libggml.so` with `RTLD_NOLOAD`, resolves `ggml_backend_reg_by_name` and the
device table, and never calls `ggml_backend_load_all_from_path`; it therefore
cannot register a second backend next to GenieX's copy. If the HTP backend is
missing, the session is destroyed and the error names the packaged devices. That
is the difference between "a session exists" and "the NPU engine is loaded".

### 2.2.2 `Austriani/Qwen3.8-4B-Distill-ARA-Abliterated`: why it is not an NPU preset

This model was evaluated rather than assumed. The facts, from
[the model card](https://huggingface.co/Austriani/Qwen3.8-4B-Distill-ARA-Abliterated)
and [the GGUF repository](https://huggingface.co/Austriani/Qwen3.8-4B-Distill-ARA-Abliterated-RP-GGUF):

- its Hub config is `Qwen3_5ForConditionalGeneration` (`model_type: qwen3_5`), a
  multimodal Qwen3.8 distill, 4.54 B BF16 parameters;
- the `-RP-GGUF` repository does publish `Q4_0` and `Q8_0` files;
- the Q4_0 header declares `general.architecture = qwen35`, 32 blocks, 2560
  embedding and `general.file_type = 2` (Q4_0);
- the packaged `libllama.so` does contain `llama_model_qwen35` and the
  DeltaNet/GDN graph builders, so llama.cpp can load the text GGUF;
- **but** the packaged `libggml-hexagon.so` shows only the matrix/OpenCL-style
  compute path and no HTP-specific `ggml_ssm_conv` / `ggml_gated_delta_net`
  kernels. Qwen3.8
  is a hybrid recurrent model; its SSM layers would execute on the CPU even when
  the attention and FFN layers are offloaded. That is a mixed/CPU run, not a clean
  HTP run;
- there is no QAIRT/QNN context-binary bundle for this architecture, so the
  QAIRT path cannot make it NPU-only either.

The importer therefore keeps the Qwen3 architecture check and rejects `qwen35`
with a named error. Adding this model as a preset would advertise an NPU path
that the packaged HTP backend cannot deliver. It becomes viable only with a
GenieX/ggml-hexagon build that ships Qwen3.5 GDN HTP kernels plus a Q4_0/Q8_0
GGUF, or with a QAIRT bundle compiled for the target SoC.

### 2.3 Building the QAIRT bundle

The bundle must be compiled for the exact SoC family, because context binaries
embed HTP-specific graph layouts. The app validates the result but cannot build
it, and it will not ship a prebuilt binary for a third-party derivative.

Requirements for the compile step:

- source = the abliterated HF repository (upload the checkpoint, or run the
  export on a machine that has it);
- precision `w4a16`, context length `4096`;
- backend `QnnHtp`, output `qnn_context_binary` (a Genie dialog bundle), matching
  the QAIRT runtime the app packages (HTP v81 on `SM8750`/`SM8850`);
- the artifact must end up with the layout described in 2.1.

Qualcomm AI Hub Workbench is the supported path; see
<https://geniex.aihub.qualcomm.com/en/run/android/api-reference> and
<https://app.aihub.qualcomm.com/docs/> for the current CLI. Verify the produced
`genie_config.json` against section 2.1 before importing: the validator reports
the first mismatch by name, so a failed import tells you which field is wrong.

## 3. Accelerator negotiation

`OnDeviceLlmRuntime` never guesses. Before creating a session it resolves one of
four accelerators and proves the pieces it needs:

| Accelerator | Backend id | Requires | Evidence |
| --- | --- | --- | --- |
| QAIRT NPU | `geniex-qairt-npu` | QAIRT bundle, `SM8750`/`SM8850`, `libQnnHtp*.so`, HTP skel, FastRPC directory | session created with `ComputeUnitValue.NPU` on `RuntimeIdValue.QAIRT`, plugin version non-blank |
| llama.cpp NPU | `geniex-llamacpp-npu` | GGUF Q4_0/Q8_0, `libggml-hexagon.so`, `libggml-htp-v81.so`, `ADSP_LIBRARY_PATH`, HTP v81 SoC | session created with `ComputeUnitValue.NPU` on `RuntimeIdValue.LLAMA_CPP`, `nGpuLayers = -1`, HTP backend present in the passive GGML probe |
| GPU | `geniex-llamacpp-gpu` | GGUF, `libggml-opencl.so`, a loadable OpenCL driver | session created with `ComputeUnitValue.GPU`, `nGpuLayers = -1` |
| CPU | `geniex-llamacpp-cpu` | GGUF | session created with `ComputeUnitValue.CPU`, `nGpuLayers = 0` |

### Why a GGUF can run on the NPU

This is not a hope, it is shipped: GenieX 0.3.17's AAR contains
`libggml-hexagon.so` and `libggml-htp-v81.so` (the ggml Hexagon backend built for
HTP v81), and `libgeniex.so` contains the device-alias table

```text
Unknown device alias (expected one of: cpu, gpu, npu, hybrid)
```

plus `geniex::htp::htp_backend_present`, `geniex::classify_device`,
`geniex::build_model_params(config, device)` and `HTP0`. So the llama.cpp plugin
accepts `npu` as a device and routes the graph to the Hexagon backend. The only
prerequisite the app has to supply is `ADSP_LIBRARY_PATH` pointing at the
directory that holds the packaged `.so` files, because FastRPC loads the DSP
libraries through it — `QnnRuntime.ensureAdspLibraryPath` does exactly that for
both NPU paths.

`nGpuLayers = -1` is the offload switch for the llama.cpp accelerators: the
plugin documents `-1` as "all layers", while `0` keeps the graph on the CPU. The
old value `64` happened to cover Qwen3-4B's 36 blocks, but it was a ceiling
rather than the contract.

Rules:

- A QAIRT artifact selects the QAIRT NPU. Asking for the GPU with a QAIRT bundle
  installed is an error with a message that names the fix, not a silent switch.
- A GGUF under `auto` targets **the NPU first and the CPU second**. The GPU is
  not in the automatic ladder. Each NPU rejection is recorded in
  `rejectedAccelerators` with its reason (missing HTP skel, HTP backend not
  registered, unsupported SoC, ...), and a CPU fallback is opened only after the
  NPU candidate fails. `gpu` and `cpu` remain explicit diagnostic choices.
- The importer records `general.file_type`, its label and an `npuClean` flag.
  Only Q4_0/Q8_0 reach the store; every other quantization is rejected at import
  with a message naming the file's quantization. There is no `mixed CPU` session
  in the automatic path.
- `hardwareAccelerationVerified` is `true` only after a **completed turn** returns
  profiling data on a session created with that compute unit, and — for the GGUF
  NPU path — only if the passive GGML probe confirmed the `HTP` backend is
  registered in the process. A loaded session alone is not evidence; the SDK
  exposes no per-operator backend counters, so the claim is scoped to "the HTP
  backend was present and the session ran and returned a profile", not "every
  operator ran on the HTP".
- The NPU probe does not `dlopen` the 87 MB `libQnnHtpPrepare.so`. Answering "is
  the NPU available?" must not map the QAIRT runtime into the process; the load
  happens when a session is actually created, where the failure is actionable.

### 3.1 HTP execution budget

The app does not leave the NPU path to defaults it cannot see:

- `GGML_HEXAGON_ARCH` is pinned to `81`, so a failed device query cannot make the
  DSP skel fall back to v73 on an SM8850;
- `GGML_HEXAGON_NDEV=1` allocates one virtual HTP session, which is what the SDK's
  `npu` alias resolves to; the loader asks for all layers with
  `nGpuLayers = -1`;
- the CPU thread count is set **only** for the explicit CPU fallback
  (`availableProcessors()` clamped to 2–6). An NPU/GPU session gets
  `HOST_THREADS = 2`: GenieX otherwise attaches eight pinned threads with a
  polling wait even though every transformer layer is on HTP0, and those threads
  then compete with the UI during the whole decode;
- the bundled `ggml-hexagon` build enables HMX and op fusion, and the app pins
  them anyway (`GGML_HEXAGON_USE_HMX=1`, `MM_SELECT=3` = HMX → tiled → flat,
  `OPFUSION=1` = every fusion) so an SDK default change cannot silently fall
  back to HVX-only or unfused ops. It does not enable `OPPOLL` (polling burns host
  CPU) or `VERBOSE`/`PROFILE` in production.

Both accepted quants keep every tensor on the HTP, but they are not equal in
memory behaviour. Q4_0 of a 4B model is about 2.5 GiB and fits the per-session
virtual address window; Q8_0 is 4.28 GiB, so the backend maps weights in and out
of the session while it runs. Q4_0 is therefore the faster choice when a
repository offers both. The `mradermacher` Huihui mirror offers only Q8_0, which
is why that is the artifact named in the UI and in section 2.2.

Measured on the PLK110 (`SM8850`, HTP v81) with the pure Q4_0 artifact, all 36
layers assigned to `HTP0`, HMX enabled and two host threads: 11.97 tok/s decode
and 50–68 tok/s prefill on short prompts, with 190–205 ms time to first token.
The log confirms `computeUnit=npu`, `htpRegistered=true`, and `HTP0` for every
layer; the speed is the packaged GenieX 0.3.17 backend's limit, not a CPU
fallback.

## 4. Memory lifecycle

| Moment | What happens |
| --- | --- |
| Import | Streamed copy through a 256 KiB buffer; the provider's declared size is only a hint and the written bytes are bounded (9 GiB GGUF / 8 GiB bundle) |
| Import validation (GGUF) | Constant-memory header walk, bounded to 64 MiB / 65 536 keys / 8 MiB per string |
| Import validation (QAIRT) | `genie_config.json` and `metadata.json` only; no context binary is mapped |
| First turn | `LlmWrapper` maps the context binaries; `nCtx` comes from `genie_config.json` for QAIRT and from `OnDeviceModel.CONTEXT_SIZE` for GGUF |
| Streaming | Whole-text snapshots coalesced to at most one every 50 ms, so a multi-thousand-token reply costs tens of platform-channel frames instead of one copy per token |
| `TRIM_MEMORY_RUNNING_CRITICAL` | The session is destroyed; the artifact stays on disk and the next turn reloads it |
| `onDestroy` | `stop()` → `close()`, queued on the single-threaded LLM executor so a native handle is never freed under a running stream |

`stop()` deliberately does not take `stateLock`: a cancel must be able to
interrupt a turn that holds it, while `close()` takes both locks in a fixed order
so the native handle is never destroyed under `stopStream()`.

## 5. Prompt

`rust/src/api/chatml.rs` renders ChatML for both engines:

```
<|im_start|>role\ncontent<|im_end|>\n
...
<|im_start|>assistant\n
```

One implementation serves the NPU and the GPU because both artifacts are the same
Qwen3 checkpoint. The renderer strips every `<|...|>` span from message content —
not just the three tokens it names — so a user message cannot close the system
turn, and a reply that leaks markup is rejected instead of rendered. The prompt
size is bounded at 1 MiB where the bytes are appended.

The SDK's own `applyChatTemplate` is not used: GenieX 0.3.17 returns an empty
string for the AI Hub Qwen3 bundle, and the behaviour is not part of a documented
contract we can rely on.

## 6. Failure modes you will actually see

| Symptom | Cause | Fix |
| --- | --- | --- |
| `The bundle declares a 2048 token context` | compiled with the wrong context length | recompile with `--context-length 4096` |
| `The bundle is compiled for 'QnnGpu'` | GPU graph imported as an NPU bundle | import it as a GGUF instead, or recompile for `QnnHtp` |
| `the file is not a GGUF container` | safetensors picked by mistake | download the GGUF, not the original checkpoint |
| `no OpenCL driver is exposed` | vendor driver not readable by the app | use a QAIRT bundle, or request `cpu` explicitly for diagnostics |
| `SM8750/SM8850 HTP v81 is required` | unsupported SoC for the NPU path | use a supported SoC or an explicit `cpu` diagnostic build |
| `The GGUF is Q4_K_M` | the importer only accepts full-HTP quantizations | re-export as `Q4_0` or `Q8_0`; the importer rejects the file before it replaces the working model |
| `The HTP GGML backend is not registered` | the NPU candidate failed and the CPU fallback was opened | inspect `rejectedAccelerators`; fix the AAR/packaging if NPU is required |
| empty reply, context exhausted | conversation longer than 4096 tokens | the runtime retries with the system prompt and the last 3 turns before failing |

## 7. Tests

Host-runnable, no device required:

```bash
cargo test --offline --manifest-path rust/Cargo.toml --lib chatml:: gguf::
cd android && ./gradlew :app:testDebugUnitTest --tests '*QairtBundleValidatorTest'
```

Device-runnable: `integration_test/live2d_gpu_test.dart` and a real generation
whose diagnostics carry `activeBackend`, `computeUnit` and `profile`.
