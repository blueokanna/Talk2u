package com.blue.talk2u

import android.content.Context
import android.os.Build
import android.system.Os
import android.util.Log
import com.geniex.sdk.GenieXSdk
import com.geniex.sdk.LlmWrapper
import com.geniex.sdk.ModelManagerWrapper
import com.geniex.sdk.bean.ChatMessage
import com.geniex.sdk.bean.ComputeUnitValue
import com.geniex.sdk.bean.FileProgress
import com.geniex.sdk.bean.GenerationConfig
import com.geniex.sdk.bean.HubSource
import com.geniex.sdk.bean.LlmCreateInput
import com.geniex.sdk.bean.LlmStreamResult
import com.geniex.sdk.bean.ModelConfig
import com.geniex.sdk.bean.ModelPaths
import com.geniex.sdk.bean.ModelPullInput
import com.geniex.sdk.bean.ModelType
import com.geniex.sdk.bean.ProfilingData
import com.geniex.sdk.bean.RuntimeIdValue
import com.geniex.sdk.bean.SamplerConfig
import java.io.File
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.runBlocking

/**
 * Owns the single on-device LLM session.
 *
 * Two artifacts are executable, and each can reach the Hexagon NPU:
 *
 * | Artifact | Engine | Accelerators |
 * | --- | --- | --- |
 * | QAIRT context binaries (`QnnHtp`) | `libgeniex_plugin_qairt.so` | `NPU` only |
 * | llama.cpp GGUF | `libgeniex_plugin_llama_cpp.so` | `NPU` (ggml-hexagon), `GPU` (OpenCL), `CPU` |
 *
 * The GGUF NPU path is not a guess: GenieX 0.3.17 ships `libggml-hexagon.so`,
 * `libggml-htp-v81.so`, and classifies `npu` as a device alias for the llama.cpp
 * plugin (`Unknown device alias (expected one of: cpu, gpu, npu, hybrid)`). A
 * GGUF therefore reaches the HTP without QAIRT compilation, which is what
 * [Accelerator.LLAMA_NPU] uses.
 *
 * The accelerator is never assumed. Before a session exists the runtime proves
 * the pieces it needs, and an unsatisfiable request is an error rather than a
 * silent downgrade. The `auto` policy is NPU → CPU for a GGUF (never GPU), and
 * it records why each rejected candidate was rejected. The importer only accepts
 * Q4_0/Q8_0 GGUF, so a session that does reach the HTP has every tensor on the
 * NPU; CPU is the explicit fallback when the HTP itself is unavailable.
 *
 * [verified] means: a session created with this compute unit completed a turn and
 * returned profiling data. The SDK exposes no per-operator backend counters, so
 * this is session-level evidence; it is deliberately not called "per-operator
 * verified".
 */
internal class OnDeviceLlmRuntime(context: Context) : AutoCloseable {
    private val appContext = context.applicationContext
    private val store = OnDeviceArtifactStore(appContext)
    private val modelManager = ModelManagerWrapper
    private val sdk: GenieXSdk by lazy {
        runCatching { GenieXSdk.getInstance() }.getOrElse { error ->
            val message =
                "GenieX SDK is unavailable: ${error.message ?: error.javaClass.simpleName}"
            Log.e(LOG_TAG, message, error)
            throw IllegalStateException(message, error)
        }
    }

    private val stateLock = Any()

    // `stop` must interrupt a running turn without taking stateLock, while
    // `close` must never free a native handle that `stopStream` is still using.
    private val stopLock = Any()
    private val generationCancelled = AtomicBoolean(false)
    private val pullCancelled = AtomicBoolean(false)

    @Volatile private var sdkReady = false
    @Volatile private var llm: LlmWrapper? = null
    @Volatile private var session: Session? = null
    @Volatile private var lastProfile: ProfilingData? = null
    @Volatile private var verified = false
    @Volatile private var rejectedAccelerators: List<String> = emptyList()

    /** Registry snapshot taken after the llama.cpp session was created. */
    @Volatile private var ggmlSnapshot: GgmlSnapshot? = null

    /** Cached accelerator probes; all three are pure lookups after the first answer. */
    @Volatile private var qairtNpuCache: Pair<Boolean, String>? = null
    @Volatile private var htpCache: Pair<Boolean, String>? = null
    @Volatile private var gpuCache: Pair<Boolean, String>? = null

    private val socModel: String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Build.SOC_MODEL.orEmpty().trim()
        } else {
            Build.HARDWARE.orEmpty().trim()
        }
    private val socCode: String = Chipset.normalize(socModel)

    /** One loaded session: what it runs, and on which compute unit. */
    private data class Session(
        val artifact: InstalledArtifact,
        val accelerator: Accelerator,
        val computeUnit: String,
        val pluginVersion: String,
    )

    // ---------------------------------------------------------------- install

    fun capabilities(): Map<String, Any?> {
        ensureSdk()
        return diagnostics() + store.status() + mapOf(
            "supported" to true,
            "presets" to ModelPreset.entries.map(::presetMap),
            "accelerators" to acceleratorReport(),
        )
    }

    /** Artifact state without touching the native session. */
    fun modelStatus(): Map<String, Any?> = store.status()

    /**
     * Pulls Qualcomm's published QAIRT bundle for [preset].
     *
     * Only [ModelPreset.BASE] has a catalog entry; the abliterated derivative has
     * no public compiled bundle, so asking for it here is a typed error instead
     * of a download that could only fail.
     */
    fun installFromHub(
        preset: ModelPreset,
        onProgress: (InstallProgress) -> Unit,
    ): Map<String, Any?> {
        ensureSdk()
        val hubModel = preset.hubModel
            ?: throw IllegalStateException(
                "${preset.displayName} has no published QAIRT bundle; import a compiled " +
                    "bundle or a GGUF instead",
            )
        close()
        pullCancelled.set(false)
        val chipset = requireHubChipset()
        val input = ModelPullInput(
            hubModel,
            null,
            HubSource.AUTO,
            null,
            null,
            chipset,
            preset.displayName,
            ModelType.LLM,
        )
        // The hub reports progress for the current attempt only, while bytes from
        // earlier attempts stay on disk and are reused. Add that baseline so a
        // resumed pull does not look like it restarted from zero.
        val resumeBase = cachedHubBytes()
        var attempt = 0
        while (true) {
            attempt++
            try {
                runBlocking {
                    modelManager.pullFlow(input).collect { event ->
                        check(!pullCancelled.get()) { "The model download was cancelled" }
                        when (event) {
                            is ModelManagerWrapper.PullEvent.Progress -> {
                                val progress = aggregateProgress(event.files)
                                onProgress(
                                    InstallProgress(
                                        (resumeBase + progress.copiedBytes)
                                            .coerceAtMost(progress.totalBytes),
                                        progress.totalBytes,
                                    ),
                                )
                            }
                            is ModelManagerWrapper.PullEvent.Error -> error(
                                event.message.ifBlank {
                                    "The model pull failed with code ${event.code}"
                                },
                            )
                            ModelManagerWrapper.PullEvent.Completed -> Unit
                        }
                    }
                }
                break
            } catch (error: Throwable) {
                if (pullCancelled.get() || attempt >= MAX_PULL_ATTEMPTS) throw error
                Log.w(LOG_TAG, "model pull attempt $attempt failed; resuming", error)
                Thread.sleep(PULL_RETRY_BASE_DELAY_MS * attempt)
                check(!pullCancelled.get()) { "The model download was cancelled" }
            }
        }
        val key = findInstalledHubKey(preset)
            ?: throw IllegalStateException(
                "The download finished but GenieX did not install a QAIRT bundle for " +
                    preset.displayName,
            )
        val paths = requireNotNull(runBlocking { modelManager.getPaths(key) }) {
            "GenieX returned no paths for $key"
        }
        val root = paths.model_dir.takeIf(String::isNotBlank)?.let(::File)
            ?: throw IllegalStateException("GenieX returned no bundle directory for $key")
        val artifact = store.adoptHubBundle(preset, key, root)
        return artifactMap(artifact) + store.status()
    }

    fun installGguf(
        preset: ModelPreset,
        uri: android.net.Uri,
        onProgress: (InstallProgress) -> Unit,
    ): Map<String, Any?> {
        val artifact = store.installGguf(preset, uri, onProgress)
        close()
        return artifactMap(artifact) + store.status()
    }

    fun installQairtBundle(
        preset: ModelPreset,
        uri: android.net.Uri,
        onProgress: (InstallProgress) -> Unit,
    ): Map<String, Any?> {
        val artifact = store.installQairtBundle(preset, uri, onProgress)
        close()
        return artifactMap(artifact) + store.status()
    }

    fun cancelInstall() {
        store.cancel()
        pullCancelled.set(true)
    }

    fun deleteModel() {
        close()
        val hubKey = store.installed()?.hubKey
        store.delete()
        if (hubKey != null) {
            runCatching { runBlocking { modelManager.remove(hubKey) } }
                .onFailure { Log.w(LOG_TAG, "Unable to remove $hubKey from the GenieX store", it) }
        }
    }

    // ------------------------------------------------------------------- load

    /**
     * Creates a session for the installed artifact.
     *
     * @param requested `auto`, `qairt`, `npu`/`htp`, `gpu` or `cpu`.
     */
    fun load(requested: String?): Map<String, Any?> = synchronized(stateLock) {
        ensureSdk()
        destroyLocked()
        buildSessionLocked(parseRequest(requested))
        diagnostics()
    }

    fun ensureLoaded(requested: String?): Map<String, Any?> = synchronized(stateLock) {
        if (llm != null) diagnostics() else load(requested)
    }

    private fun buildSessionLocked(requested: Accelerator?): Session {
        val artifact = store.installed()
            ?: throw IllegalStateException(
                "No on-device model is installed. Import a QAIRT bundle or a GGUF, " +
                    "or download the Qualcomm bundle for ${ModelPreset.BASE.displayName}.",
            )
        val candidates = plan(artifact, requested)
        if (candidates.isEmpty()) {
            throw IllegalStateException(
                "No accelerator can run ${artifact.preset.displayName}: " +
                    rejectedAccelerators.joinToString("; "),
            )
        }
        var lastError: Throwable? = null
        for (candidate in candidates) {
            try {
                return openSession(artifact, candidate)
            } catch (error: Throwable) {
                lastError = error
                noteRejected(candidate, error)
                Log.e(LOG_TAG, "Unable to open a ${candidate.id} session", error)
            }
        }
        throw IllegalStateException(
            "Unable to start ${artifact.preset.displayName}: " +
                rejectedAccelerators.joinToString("; "),
            lastError,
        )
    }

    /**
     * Ordered accelerators worth attempting for [artifact].
     *
     * `auto` is **NPU first, CPU second**, never GPU. The GPU path remains an
     * explicit diagnostic request; it is not part of the automatic ladder. If the
     * NPU candidate fails, the rejection reason is recorded and the CPU session
     * is opened, so the user still gets an answer and the UI can state that the
     * fallback happened. A QAIRT bundle has no CPU runtime, so that path has no
     * fallback and reports the NPU failure instead.
     */
    private fun plan(artifact: InstalledArtifact, requested: Accelerator?): List<Accelerator> {
        rejectedAccelerators = emptyList()
        return when (artifact.kind) {
            ArtifactKind.QAIRT_BUNDLE -> when (requested) {
                null, Accelerator.QAIRT_NPU -> {
                    val (available, detail) = qairtNpuAvailability()
                    if (available) listOf(Accelerator.QAIRT_NPU) else {
                        rejectedAccelerators = listOf("NPU: $detail")
                        emptyList()
                    }
                }
                else -> {
                    rejectedAccelerators = listOf(
                        "the installed artifact is a QAIRT bundle compiled for the NPU; " +
                            "import a GGUF to use ${requested.id}",
                    )
                    emptyList()
                }
            }
            ArtifactKind.GGUF -> when (requested) {
                Accelerator.QAIRT_NPU -> {
                    rejectedAccelerators = listOf(
                        "the installed artifact is a GGUF; download the Qualcomm bundle " +
                            "for the QAIRT NPU path",
                    )
                    emptyList()
                }
                Accelerator.LLAMA_NPU -> {
                    val (available, detail) = htpAvailability()
                    if (available) listOf(Accelerator.LLAMA_NPU) else {
                        rejectedAccelerators = listOf("NPU: $detail")
                        listOf(Accelerator.LLAMA_CPU)
                    }
                }
                Accelerator.LLAMA_GPU -> {
                    val (available, detail) = gpuAvailability()
                    if (available) listOf(Accelerator.LLAMA_GPU) else {
                        rejectedAccelerators = listOf("GPU: $detail")
                        emptyList()
                    }
                }
                Accelerator.LLAMA_CPU -> listOf(Accelerator.LLAMA_CPU)
                null -> {
                    val (available, detail) = htpAvailability()
                    if (available) {
                        // NPU first; CPU is the only fallback. If the NPU session
                        // fails during open, buildSessionLocked moves here and
                        // noteRejected records why.
                        listOf(Accelerator.LLAMA_NPU, Accelerator.LLAMA_CPU)
                    } else {
                        rejectedAccelerators = listOf("NPU: $detail")
                        listOf(Accelerator.LLAMA_CPU)
                    }
                }
            }
        }
    }

    private fun noteRejected(accelerator: Accelerator, error: Throwable) {
        rejectedAccelerators = rejectedAccelerators +
            "${accelerator.id}: ${error.message ?: error.javaClass.simpleName}"
    }

    private fun openSession(artifact: InstalledArtifact, accelerator: Accelerator): Session {
        val runtime = artifact.kind.runtime
        val pluginId = when (runtime) {
            LlmRuntime.QAIRT -> GenieXSdk.PLUGIN_ID_QAIRT
            LlmRuntime.LLAMA_CPP -> GenieXSdk.PLUGIN_ID_LLAMA_CPP
        }
        val pluginVersion = runCatching { sdk.getPluginVersion(pluginId).orEmpty() }
            .getOrNull()
            .orEmpty()
            .trim()
        check(pluginVersion.isNotBlank()) {
            "The GenieX '$pluginId' plugin is not registered in this build"
        }

        // Both NPU paths need the DSP libraries reachable through FastRPC. QAIRT
        // resolves its HTP skel there, and ggml-hexagon loads its HTP library the
        // same way.
        if (accelerator.isNpu) {
            checkNotNull(QnnRuntime.ensureAdspLibraryPath(appContext)) {
                "The FastRPC library directory is unavailable; the Hexagon NPU cannot be reached"
            }
        }

        var modelPath = artifact.path.path
        var tokenizerPath: String? = null
        if (runtime == LlmRuntime.QAIRT) {
            val bundle = QairtBundleValidator.load(artifact.path, OnDeviceModel.CONTEXT_SIZE)
            modelPath = bundle.entryPoint.path
            tokenizerPath = bundle.tokenizer.path
        }

        val input = LlmCreateInput(
            artifact.preset.displayName,
            modelPath,
            tokenizerPath,
            modelConfig(artifact, accelerator),
            runtimeId(runtime).value,
            computeUnit(accelerator).value,
        )
        val created = runBlocking {
            LlmWrapper.builder()
                .llmCreateInput(input)
                .build()
                .getOrThrow()
        }
        var npuProbe: GgmlSnapshot? = null
        if (accelerator == Accelerator.LLAMA_NPU) {
            // A created session is not evidence that layers were offloaded. The
            // passive registry probe answers the only question that matters: did
            // ggml actually register its HTP backend in this process? If it did
            // not, llama.cpp has already fallen back to CPU and continuing would
            // hand the user a hot phone while the UI says NPU.
            val probe = GgmlProbe.snapshot(appContext.applicationInfo.nativeLibraryDir)
            npuProbe = probe
            if (probe.loaded && !probe.htpReady) {
                runCatching { created.destroy() }
                throw IllegalStateException(
                    "The HTP GGML backend is not registered; llama.cpp would run on the CPU. " +
                        "Packaged devices: " +
                        probe.devices.joinToString().ifBlank { "none" } +
                        (probe.error?.let { " ($it)" } ?: ""),
                )
            }
            if (!probe.loaded) {
                Log.w(
                    LOG_TAG,
                    "GGML probe could not open the loaded libggml.so: ${probe.error}",
                )
            }
        }
        val opened = Session(
            artifact,
            accelerator,
            computeUnit(accelerator).value.orEmpty(),
            pluginVersion,
        )
        synchronized(stateLock) {
            destroyLocked()
            llm = created
            session = opened
            verified = false
            lastProfile = null
            // destroyLocked clears the previous snapshot; install the one taken
            // for this session afterwards.
            ggmlSnapshot = npuProbe
        }
        Log.i(
            LOG_TAG,
            "session.open model=${artifact.preset.id} artifact=${artifact.kind.id} " +
                "runtime=${runtime.id} computeUnit=${opened.computeUnit} plugin=$pluginVersion",
        )
        return opened
    }

    private fun runtimeId(runtime: LlmRuntime): RuntimeIdValue = when (runtime) {
        LlmRuntime.QAIRT -> RuntimeIdValue.QAIRT
        LlmRuntime.LLAMA_CPP -> RuntimeIdValue.LLAMA_CPP
    }

    /**
     * Maps an accelerator onto the SDK device alias.
     *
     * QAIRT and llama.cpp both drive the Hexagon through `NPU`; the difference is
     * the plugin and the artifact, not the alias.
     */
    private fun computeUnit(accelerator: Accelerator): ComputeUnitValue = when (accelerator) {
        Accelerator.QAIRT_NPU, Accelerator.LLAMA_NPU -> ComputeUnitValue.NPU
        Accelerator.LLAMA_GPU -> ComputeUnitValue.GPU
        Accelerator.LLAMA_CPU -> ComputeUnitValue.CPU
    }

    private fun modelConfig(
        artifact: InstalledArtifact,
        accelerator: Accelerator,
    ): ModelConfig = ModelConfig().apply {
        when (artifact.kind) {
            ArtifactKind.QAIRT_BUNDLE -> {
                // GenieX reads n_ctx from genie_config.json for QAIRT when zero.
                nCtx = 0
                nGpuLayers = 0
            }
            ArtifactKind.GGUF -> {
                nCtx = OnDeviceModel.CONTEXT_SIZE
                // -1 is llama.cpp's documented "all layers". Zero is CPU-only.
                nGpuLayers =
                    if (accelerator == Accelerator.LLAMA_CPU) 0 else OnDeviceModel.OFFLOAD_LAYERS
                // Let the plugin pick its per-device thread defaults for NPU and
                // GPU? No: GenieX 0.3.17 defaults to eight host threads pinned
                // to the big cores with a 1 ms polling wait. On an NPU session
                // those threads only service tokenization, sampling and a few
                // edge ops, but the poll keeps them runnable for the whole
                // decode and competes with the UI and the Live2D renderer. Two
                // threads cover that host work without a busy-wait pool.
                val threads =
                    if (accelerator == Accelerator.LLAMA_CPU) defaultThreads()
                    else OnDeviceModel.HOST_THREADS
                nThreads = threads
                nThreadsBatch = threads
            }
        }
    }

    // --------------------------------------------------------------- generate

    /**
     * Runs one turn and returns the full reply.
     *
     * The callback receives whole-text snapshots, coalesced to at most one every
     * [EMIT_INTERVAL_NANOS]. Emitting per token made the bridge allocate and
     * transfer a copy of the whole reply thousands of times; a multi-thousand
     * token answer spent more time in `String` copies and platform channels
     * than in decode.
     */
    fun generate(
        messages: List<Pair<String, String>>,
        maxTokens: Int,
        requested: String?,
        onText: (String) -> Unit,
    ): String = synchronized(stateLock) {
        ensureSdk()
        if (llm == null) {
            buildSessionLocked(parseRequest(requested))
        }
        val active = checkNotNull(llm) { "The on-device model is not loaded" }
        generationCancelled.set(false)
        require(messages.any { it.second.isNotBlank() }) { "The Qwen3 chat messages are empty" }
        val chat = toChatMessages(messages)
        check(chat.isNotEmpty()) { "Every Qwen3 chat message was blank" }

        var response = runTurn(active, chat, maxTokens, onText)
        checkGenerationActive()
        if (response.isEmpty()) {
            // An empty reply in practice means the prompt no longer fits the KV
            // cache. Retrying with the system prompt and the last few turns is
            // bounded work and keeps a long chat usable.
            val trimmed = trimForRetry(messages)
            if (trimmed.size < messages.size) {
                Log.w(LOG_TAG, "turn.retry trimmed=${trimmed.size} of ${messages.size}")
                response = runTurn(active, toChatMessages(trimmed), maxTokens, onText)
            }
        }
        checkGenerationActive()
        check(response.isNotEmpty()) {
            "The on-device model returned no content; the context window may be exhausted. " +
                "Start a new conversation."
        }
        check(!ChatMlPrompt.leaksControlToken(response)) {
            "The on-device model leaked chat-template control tokens; the reply was rejected"
        }
        verified = when (session?.accelerator) {
            // QAIRT exposes only the Hexagon NPU, and the plugin coerces any
            // other device request onto it.
            Accelerator.QAIRT_NPU -> true
            // A GGUF NPU session is only "verified" when the HTP backend is
            // actually registered; the registry probe is taken at session open.
            Accelerator.LLAMA_NPU -> ggmlSnapshot?.htpReady == true
            Accelerator.LLAMA_GPU -> true
            Accelerator.LLAMA_CPU, null -> false
        }
        response
    }

    private fun checkGenerationActive() {
        if (generationCancelled.get()) {
            throw CancellationException("The on-device generation was cancelled")
        }
    }

    private fun toChatMessages(messages: List<Pair<String, String>>): Array<ChatMessage> =
        messages.mapNotNull { (role, content) ->
            content.trim().takeIf(String::isNotEmpty)?.let { ChatMessage(normalizeRole(role), it) }
        }.toTypedArray()

    private fun normalizeRole(role: String): String = when (role.lowercase()) {
        "system", "assistant" -> role.lowercase()
        else -> "user"
    }

    /** System messages plus the newest [OnDeviceModel.RETRY_TURNS] other turns. */
    private fun trimForRetry(messages: List<Pair<String, String>>): List<Pair<String, String>> {
        val system = messages.filter { normalizeRole(it.first) == "system" }
        val turns = messages.filter { normalizeRole(it.first) != "system" }
        val keep = OnDeviceModel.RETRY_TURNS
        val kept = if (turns.size <= keep) turns else turns.takeLast(keep)
        return system + kept
    }

    /** Runs one turn and returns the full text, or an empty string. */
    private fun runTurn(
        active: LlmWrapper,
        chat: Array<ChatMessage>,
        maxTokens: Int,
        onText: (String) -> Unit,
    ): String {
        val prompt = ChatMlPrompt.build(chat.map { it.role to it.content })
        check(prompt.isNotBlank()) { "The Rust prompt builder produced no text" }
        Log.i(
            LOG_TAG,
            "turn.start messages=${chat.size} promptBytes=${prompt.length} " +
                "computeUnit=${session?.computeUnit.orEmpty()}",
        )

        val streamed = StringBuilder()
        var completedProfile: ProfilingData? = null
        var lastEmit = 0L
        runBlocking {
            checkGenerationActive()
            check(active.reset() == GENIEX_SUCCESS) { "Unable to reset the on-device session" }
            checkGenerationActive()
            active.generateStreamFlow(prompt, generationConfig(maxTokens)).collect { result ->
                checkGenerationActive()
                when (result) {
                    is LlmStreamResult.Token -> {
                        streamed.append(result.text)
                        val now = System.nanoTime()
                        if (now - lastEmit >= EMIT_INTERVAL_NANOS) {
                            lastEmit = now
                            onText(streamed.toString())
                        }
                    }
                    is LlmStreamResult.Completed -> completedProfile = result.profile
                    is LlmStreamResult.Error -> throw result.throwable
                }
            }
        }
        if (streamed.isNotEmpty()) onText(streamed.toString())
        Log.i(
            LOG_TAG,
            "turn.done replyChars=${streamed.length} " +
                "promptTokens=${completedProfile?.promptTokens} " +
                "generatedTokens=${completedProfile?.generatedTokens} " +
                "prefill=${completedProfile?.prefillSpeed} decode=${completedProfile?.decodingSpeed} " +
                "stop=${completedProfile?.stopReason}",
        )
        lastProfile = completedProfile
        return streamed.toString().trim()
    }

    private fun generationConfig(maxTokens: Int): GenerationConfig = GenerationConfig(
        maxTokens.coerceIn(1, OnDeviceModel.MAX_OUTPUT_TOKENS),
        emptyArray(),
        0,
        0,
        SamplerConfig(0.8f, 0.95f, 40, 0.0f, 1.05f, 0.0f, 0.0f, 42, "", ""),
        emptyArray(),
        0,
        emptyArray(),
        0,
        true,
        OnDeviceModel.SLIDING_WINDOW_KEEP,
    )

    /** Interrupts the running turn without holding [stateLock]. */
    fun stop() {
        generationCancelled.set(true)
        synchronized(stopLock) {
            val active = llm ?: return
            runCatching { runBlocking { active.stopStream().getOrThrow() } }
        }
    }

    // ------------------------------------------------------------ diagnostics

    fun diagnostics(): Map<String, Any?> {
        val current = session
        val profile = lastProfile
        val (qairtReady, qairtDetail) = qairtNpuAvailability()
        val (htpReady, htpDetail) = htpAvailability()
        val (gpuReady, gpuDetail) = gpuAvailability()
        val artifact = current?.artifact
        return mapOf(
            "activeBackend" to current?.accelerator?.backendId,
            "activeBackendVerified" to verified,
            "ggml" to ggmlSnapshot?.let { snapshot ->
                mapOf(
                    "loaded" to snapshot.loaded,
                    "htpRegistered" to snapshot.htpRegistered,
                    "htpDevice" to snapshot.htpDevice,
                    "devices" to snapshot.devices,
                    "error" to snapshot.error,
                )
            },
            "engine" to artifact?.kind?.runtime?.id,
            "artifactKind" to artifact?.kind?.id,
            "computeUnit" to current?.computeUnit,
            "pluginVersion" to current?.pluginVersion,
            "runtime" to "GenieX",
            "runtimeVersion" to GENIEX_VERSION,
            "modelId" to (artifact?.preset?.id ?: store.status()["modelId"]),
            "model" to artifact?.preset?.displayName,
            "modelRepo" to artifact?.preset?.huggingFaceRepo,
            "contextSize" to OnDeviceModel.CONTEXT_SIZE,
            "maxOutputTokens" to OnDeviceModel.MAX_OUTPUT_TOKENS,
            "device" to Build.MODEL,
            "socModel" to socModel,
            "socCode" to socCode,
            "npu" to mapOf(
                "qairt" to mapOf("available" to qairtReady, "detail" to qairtDetail),
                "htp" to mapOf("available" to htpReady, "detail" to htpDetail),
            ),
            "gpu" to mapOf("available" to gpuReady, "detail" to gpuDetail),
            "rejectedAccelerators" to rejectedAccelerators,
            "profile" to profile?.let {
                mapOf(
                    "ttftMs" to it.ttftMs,
                    "promptTokens" to it.promptTokens,
                    "generatedTokens" to it.generatedTokens,
                    "prefillTokensPerSecond" to it.prefillSpeed,
                    "decodeTokensPerSecond" to it.decodingSpeed,
                    "stopReason" to it.stopReason,
                )
            },
        )
    }

    private fun presetMap(preset: ModelPreset): Map<String, Any?> = mapOf(
        "id" to preset.id,
        "displayName" to preset.displayName,
        "family" to preset.family,
        "huggingFaceRepo" to preset.huggingFaceRepo,
        "baseModel" to preset.baseModel,
        "license" to preset.license,
        "hubModel" to preset.hubModel,
    )

    /**
     * Every accelerator with the reason it is or is not usable for the installed
     * artifact. This is what the settings page renders; nothing here is a guess.
     */
    private fun acceleratorReport(): List<Map<String, Any?>> {
        val artifact = store.installed()
        val kind = artifact?.kind
        val (qairtReady, qairtDetail) = qairtNpuAvailability()
        val (htpReady, htpDetail) = htpAvailability()
        val (gpuReady, gpuDetail) = gpuAvailability()
        return listOf(
            mapOf(
                "id" to Accelerator.QAIRT_NPU.id,
                "backendId" to Accelerator.QAIRT_NPU.backendId,
                "accelerator" to "npu",
                "available" to qairtReady,
                "detail" to qairtDetail,
                "requires" to ArtifactKind.QAIRT_BUNDLE.id,
                "usability" to when {
                    !qairtReady -> qairtDetail
                    kind != ArtifactKind.QAIRT_BUNDLE ->
                        "download the Qualcomm QAIRT bundle for ${ModelPreset.BASE.displayName}"
                    else -> "ready"
                },
            ),
            mapOf(
                "id" to Accelerator.LLAMA_NPU.id,
                "backendId" to Accelerator.LLAMA_NPU.backendId,
                "accelerator" to "npu",
                "available" to htpReady,
                "detail" to htpDetail,
                "requires" to ArtifactKind.GGUF.id,
                "usability" to when {
                    !htpReady -> htpDetail
                    kind != ArtifactKind.GGUF -> "import a Q4_0 or Q8_0 GGUF"
                    else -> "ready"
                },
            ),
            mapOf(
                "id" to Accelerator.LLAMA_GPU.id,
                "backendId" to Accelerator.LLAMA_GPU.backendId,
                "accelerator" to "gpu",
                "available" to gpuReady,
                "detail" to gpuDetail,
                "requires" to ArtifactKind.GGUF.id,
                "usability" to when {
                    !gpuReady -> gpuDetail
                    kind != ArtifactKind.GGUF -> "import a GGUF"
                    else -> "ready"
                },
            ),
            mapOf(
                "id" to Accelerator.LLAMA_CPU.id,
                "backendId" to Accelerator.LLAMA_CPU.backendId,
                "accelerator" to "cpu",
                "available" to (kind == ArtifactKind.GGUF),
                "detail" to "llama.cpp scalar backend",
                "requires" to ArtifactKind.GGUF.id,
                "usability" to if (kind == ArtifactKind.GGUF) "ready" else "import a GGUF",
            ),
        )
    }

    /**
     * QAIRT needs a supported HTP SoC, the QNN host libraries and the HTP skel.
     *
     * The probe deliberately does not `loadLibrary` the 87 MB
     * `libQnnHtpPrepare.so`: answering "is the NPU available?" must not map the
     * QAIRT runtime into the process. Whether it loads is decided when the
     * session is created, where the failure is actionable.
     */
    private fun qairtNpuAvailability(): Pair<Boolean, String> = qairtNpuCache ?: run {
        val arch = BuildConfig.QNN_HTP_ARCH.uppercase()
        val libs = appContext.applicationInfo.nativeLibraryDir
        val result = when {
            socCode.isBlank() ->
                false to "the SoC is unknown (${socModel.ifBlank { "unreported" }})"
            socCode !in Chipset.supported ->
                false to "${Chipset.supported.joinToString("/")} HTP v81 is required, " +
                    "this device is $socCode"
            !File(libs, "libQnnHtp${arch}Skel.so").isFile ->
                false to "libQnnHtp${arch}Skel.so is not packaged"
            else -> true to "$socCode HTP/$arch"
        }
        qairtNpuCache = result
        result
    }

    /**
     * The GGUF NPU path: ggml-hexagon needs its HTP backend library for this
     * architecture plus the host-side Hexagon module, both shipped by the GenieX
     * AAR, and the same HTP-capable SoC as the QAIRT path.
     */
    private fun htpAvailability(): Pair<Boolean, String> = htpCache ?: run {
        val arch = BuildConfig.QNN_HTP_ARCH.lowercase()
        val libs = appContext.applicationInfo.nativeLibraryDir
        val result = when {
            socCode.isBlank() ->
                false to "the SoC is unknown (${socModel.ifBlank { "unreported" }})"
            socCode !in Chipset.supported ->
                false to "${Chipset.supported.joinToString("/")} HTP v81 is required, " +
                    "this device is $socCode"
            !File(libs, "libggml-hexagon.so").isFile ->
                false to "libggml-hexagon.so is not packaged"
            !File(libs, "libggml-htp-$arch.so").isFile ->
                false to "libggml-htp-$arch.so is not packaged"
            else -> true to "$socCode HTP/$arch via ggml-hexagon"
        }
        htpCache = result
        result
    }

    /**
     * The GPU path: the OpenCL driver llama.cpp binds to, plus the ggml OpenCL
     * backend that comes from the GenieX AAR.
     *
     * `System.loadLibrary("OpenCL")` resolves the vendor driver the same way
     * `libggml-opencl.so` does, so a failure here is a real "no GPU backend"
     * answer rather than a guess. The result is cached: a failing dlopen throws,
     * and this probe runs on every capabilities query.
     */
    private fun gpuAvailability(): Pair<Boolean, String> = gpuCache ?: run {
        val backend = File(appContext.applicationInfo.nativeLibraryDir, "libggml-opencl.so")
        val result = if (!backend.isFile) {
            false to "libggml-opencl.so is not packaged"
        } else {
            runCatching { System.loadLibrary("OpenCL") }.fold(
                onSuccess = { true to "OpenCL (${Build.HARDWARE})" },
                onFailure = { error ->
                    false to "no OpenCL driver is exposed " +
                        "(${error.message ?: error.javaClass.simpleName})"
                },
            )
        }
        gpuCache = result
        result
    }

    private fun artifactMap(artifact: InstalledArtifact): Map<String, Any?> = mapOf(
        "modelReady" to true,
        "modelBytes" to artifact.bytes,
        "modelId" to artifact.preset.id,
        "artifact" to mapOf(
            "modelId" to artifact.preset.id,
            "model" to artifact.preset.displayName,
            "kind" to artifact.kind.id,
            "runtime" to artifact.kind.runtime.id,
            "path" to artifact.path.absolutePath,
            "bytes" to artifact.bytes,
            "declaredName" to artifact.declaredName,
            "hubKey" to artifact.hubKey,
        ) + artifact.detail,
    )

    // ----------------------------------------------------------------- cleanup

    /**
     * Releases the native session when the system is under critical pressure.
     *
     * A loaded 4B context plus KV cache costs 2-3 GB of address space that the
     * Activity would otherwise keep resident until `onDestroy`. The artifact stays
     * on disk, so the next turn reloads it.
     */
    fun trim(level: Int) {
        if (level < android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL) return
        synchronized(stateLock) {
            if (llm == null) return
            Log.i(LOG_TAG, "trim.release level=$level")
            destroyLocked()
        }
    }

    override fun close() {
        generationCancelled.set(true)
        // Always acquire stateLock before stopLock. `destroyLocked` takes
        // stopLock itself, so a concurrent `stop()` on another thread is waited
        // out instead of racing the native handle.
        synchronized(stateLock) { destroyLocked() }
    }

    private fun destroyLocked() = synchronized(stopLock) {
        val active = llm
        llm = null
        session = null
        verified = false
        lastProfile = null
        ggmlSnapshot = null
        active?.let { handle -> runCatching { handle.close() } }
    }

    /**
     * Exports the paths and GGML knobs the plugin reads at `geniex_init`.
     *
     * The AAR's llama.cpp plugin finds its own directory in most cases, but the
     * environment is the one place where a packaging change can be corrected
     * without patching the SDK. `GGML_HEXAGON_ARCH` is pinned to the same HTP
     * architecture the QAIRT deployment uses, so a failed hwinfo query can no
     * longer default the DSP skel to v73 on a v81 device.
     *
     * HMX and op fusion are the two HTP features that keep matrix work inside
     * the NPU; both are on in the bundled backend, but they are pinned here so a
     * future default cannot silently fall back to HVX-only or unfused ops. The
     * selection values are the backend's own documented order:
     * `MM_SELECT=3` is HMX -> tiled -> flat, `OPFUSION=1` enables every fusion.
     * Nothing verbose or profiling-related is exported: those add host work and
     * can write model traffic to logcat, which this app does not do.
     *
     * Deliberately no `GENIEX_LOG=info`: the SDK's info log can include prompt
     * text, and the passive GGML probe already provides the backend facts the
     * app needs without writing user content to logcat.
     */
    private fun prepareNativeRuntimeEnvironment() {
        val nativeDirectory = appContext.applicationInfo.nativeLibraryDir
        if (QnnRuntime.ensureAdspLibraryPath(appContext) == null) return
        runCatching {
            Os.setenv("GENIEX_PLUGIN_PATH", nativeDirectory, true)
            Os.setenv(
                "GGML_HEXAGON_ARCH",
                BuildConfig.QNN_HTP_ARCH.removePrefix("v"),
                true,
            )
            Os.setenv("GGML_HEXAGON_NDEV", "1", true)
            Os.setenv("GGML_HEXAGON_USE_HMX", "1", true)
            Os.setenv("GGML_HEXAGON_MM_SELECT", "3", true)
            Os.setenv("GGML_HEXAGON_OPFUSION", "1", true)
        }.onFailure { Log.w(LOG_TAG, "Unable to export the GGML runtime environment", it) }
    }

    private fun ensureSdk() = synchronized(stateLock) {        if (sdkReady) return@synchronized
        prepareNativeRuntimeEnvironment()
        var initError: String? = null
        try {
            sdk.init(
                appContext,
                object : GenieXSdk.InitCallback {
                    override fun onSuccess() = Unit
                    override fun onFailure(reason: String) {
                        initError = reason
                    }
                },
            )
        } catch (error: Throwable) {
            Log.e(LOG_TAG, "GenieX SDK initialization threw", error)
            throw IllegalStateException(
                "GenieX SDK initialization failed: ${error.message ?: error.javaClass.simpleName}",
                error,
            )
        }
        check(initError.isNullOrBlank()) { "GenieX initialization failed: $initError" }
        sdkReady = true
    }

    // ------------------------------------------------------------------ hub IO

    private fun requireHubChipset(): String {
        val detected = runCatching { runBlocking { modelManager.detectChipset() } }
            .getOrNull()
            .orEmpty()
        return Chipset.requireSupported(socModel, detected)
    }

    /** Bytes already materialised under the SDK cache, including `.inflight` parts. */
    private fun cachedHubBytes(): Long {
        val root = File(appContext.filesDir, "geniex/models")
        if (!root.isDirectory) return 0L
        return root.walkTopDown().filter(File::isFile).sumOf(File::length)
    }

    private fun aggregateProgress(files: List<FileProgress>): InstallProgress {
        var copied = 0L
        var total = 0L
        files.forEach { file ->
            copied += file.downloaded_bytes.coerceAtLeast(0L)
            total += file.total_bytes.coerceAtLeast(0L)
        }
        return InstallProgress(copied.coerceAtMost(total), total)
    }

    /** Finds the SDK store key that holds a runnable QAIRT bundle for [preset]. */
    private fun findInstalledHubKey(preset: ModelPreset): String? {
        val installed = runCatching { runBlocking { modelManager.list() } }
            .getOrDefault(emptyList())
        val hubModel = preset.hubModel ?: return null
        val alias = runCatching { runBlocking { modelManager.resolveAlias(hubModel) } }
            .getOrNull()
        val candidates = buildList {
            add(hubModel)
            add(preset.displayName)
            alias?.takeIf(String::isNotBlank)?.let(::add)
            addAll(installed.filter { it.contains(preset.displayName) || it.contains("Qwen3-4B") })
        }
        return candidates.distinct().firstOrNull { candidate ->
            val paths: ModelPaths = runCatching {
                runBlocking { modelManager.getPaths(candidate) }
            }.getOrNull() ?: return@firstOrNull false
            paths.runtime_id == requireNotNull(RuntimeIdValue.QAIRT.value) &&
                File(paths.model_path).exists()
        }
    }

    private fun parseRequest(requested: String?): Accelerator? =
        when (requested?.lowercase()) {
            null, "", "auto" -> null
            "npu", "htp", "llama-npu" -> Accelerator.LLAMA_NPU
            "qairt", "qairt-npu" -> Accelerator.QAIRT_NPU
            "gpu" -> Accelerator.LLAMA_GPU
            "cpu" -> Accelerator.LLAMA_CPU
            else -> throw IllegalArgumentException("Unknown accelerator '$requested'")
        }

    private fun defaultThreads(): Int =
        Runtime.getRuntime().availableProcessors().coerceIn(2, 6)

    companion object {
        private const val LOG_TAG = "Talk2U/LLM"
        private const val GENIEX_VERSION = "0.3.17"
        private const val GENIEX_SUCCESS = 0

        /** 50 ms: fast enough to look live, 20x fewer platform-channel frames. */
        private const val EMIT_INTERVAL_NANOS = 50_000_000L

        private const val MAX_PULL_ATTEMPTS = 3
        private const val PULL_RETRY_BASE_DELAY_MS = 2_000L
    }
}
