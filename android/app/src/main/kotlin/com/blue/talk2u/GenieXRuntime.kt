package com.blue.talk2u

import android.content.Context
import android.os.Build
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
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.runBlocking
import org.json.JSONObject

/** Owns the one public GenieX QAIRT session used by the application. */
internal class GenieXRuntime(context: Context) : AutoCloseable {
    data class DownloadProgress(val downloadedBytes: Long, val totalBytes: Long)

    private val appContext = context.applicationContext
    private val sdk: GenieXSdk by lazy {
        runCatching { GenieXSdk.Companion.getInstance() }
            .getOrElse { error ->
                val message = "GenieX SDK is unavailable: ${error.message ?: error.javaClass.simpleName}"
                Log.e("Talk2U/GenieX", message, error)
                throw IllegalStateException(message, error)
            }
    }
    private val modelManager = ModelManagerWrapper
    private val qairtRuntimeId = requireNotNull(RuntimeIdValue.QAIRT.value)
    private val stateLock = Any()
    private val downloadCancelled = AtomicBoolean(false)

    @Volatile private var initialized = false
    @Volatile private var llm: LlmWrapper? = null
    @Volatile private var verified = false
    @Volatile private var chipset = ""
    @Volatile private var modelKey: String? = null
    @Volatile private var profile: ProfilingData? = null
    @Volatile private var lastKnownModelBytes = 0L

    private data class QairtBundle(
        val root: File,
        val entryPoint: File,
        val contextSize: Int,
    )

    fun capabilities(): Map<String, Any?> {
        ensureInitialized()
        return diagnostics() + modelStatus()
    }

    fun modelStatus(): Map<String, Any?> {
        ensureInitialized()
        val installedKey = findInstalledKey()
        if (installedKey != null && lastKnownModelBytes == 0L) {
            val paths = runCatching { runBlocking { modelManager.getPaths(installedKey) } }.getOrNull()
            val modelRoot = paths?.model_dir?.takeIf(String::isNotBlank)?.let(::File)
            if (modelRoot?.isDirectory == true) {
                lastKnownModelBytes = modelRoot.walkTopDown()
                    .filter(File::isFile)
                    .sumOf(File::length)
            }
        }
        return mapOf(
            "modelReady" to (installedKey != null),
            "modelKey" to installedKey,
            "modelBytes" to lastKnownModelBytes,
        )
    }

    fun downloadModel(onProgress: (DownloadProgress) -> Unit): Map<String, Any?> {
        try {
            ensureInitialized()
            if (findInstalledKey() != null) return modelStatus()
            downloadCancelled.set(false)
            runBlocking {
                modelManager.pullFlow(modelPullInput()).collect { event ->
                    check(!downloadCancelled.get()) { "GenieX model download was cancelled" }
                    when (event) {
                        is ModelManagerWrapper.PullEvent.Progress -> {
                            val progress = aggregateProgress(event.files)
                            lastKnownModelBytes = progress.totalBytes
                            onProgress(progress)
                        }
                        is ModelManagerWrapper.PullEvent.Error -> error(
                            event.message.ifBlank { "GenieX model pull failed with code ${event.code}" },
                        )
                        ModelManagerWrapper.PullEvent.Completed -> Unit
                    }
                }
            }
            val installed = findInstalledKey()
            checkNotNull(installed) { "GenieX completed the download but did not install the model" }
            return modelStatus()
        } catch (error: Throwable) {
            Log.e("Talk2U/GenieX", "Qwen3 model download failed", error)
            throw error
        }
    }

    fun cancelDownload() {
        downloadCancelled.set(true)
    }

    fun deleteModel() {
        close()
        ensureInitialized()
        val installed = findInstalledKey() ?: return
        val result = runBlocking { modelManager.remove(installed) }
        check(result == GENIEX_SUCCESS) { "GenieX model removal failed with code $result" }
        modelKey = null
        lastKnownModelBytes = 0L
    }

    fun load(): Map<String, Any?> = synchronized(stateLock) {
        ensureInitialized()
        destroyLocked()
        val paths = installedPaths()
        check(paths.runtime_id == qairtRuntimeId) {
            "Refusing non-QAIRT model runtime '${paths.runtime_id}'"
        }
        val bundle = validateQairtBundle(paths)
        val created = runBlocking {
            LlmWrapper.builder()
                .llmCreateInput(
                    LlmCreateInput(
                        paths.model_name.ifBlank { MODEL_NAME },
                        bundle.entryPoint.path,
                        null,
                        qairtModelConfig(),
                        qairtRuntimeId,
                        ComputeUnitValue.NPU.value,
                    ),
                )
                .build()
                .getOrThrow()
        }
        llm = created
        modelKey = findInstalledKey()
        verified = false
        profile = null
        diagnostics()
    }

    fun ensureLoaded(): Map<String, Any?> = synchronized(stateLock) {
        if (llm != null) diagnostics() else load()
    }

    fun generate(
        messages: List<Pair<String, String>>,
        maxTokens: Int,
        onText: (String) -> Unit,
    ): String {
        val active = synchronized(stateLock) {
            checkNotNull(llm) { "GenieX Qwen3 runtime is not loaded" }
        }
        require(messages.any { it.second.isNotBlank() }) { "Qwen3 chat messages are empty" }
        val chat = messages.mapNotNull { (role, content) ->
            content.trim().takeIf(String::isNotEmpty)?.let {
                ChatMessage(normalizeRole(role), it)
            }
        }.toTypedArray()

        val streamed = StringBuilder()
        var completedProfile: ProfilingData? = null
        runBlocking {
            check(active.reset() == GENIEX_SUCCESS) { "Unable to reset the GenieX Qwen3 session" }
            val prompt = active.applyChatTemplate(chat, "", false, true).getOrThrow().formattedText
            check(prompt.isNotBlank()) { "GenieX returned an empty Qwen3 chat template" }
            active.generateStreamFlow(prompt, generationConfig(maxTokens)).collect { result ->
                when (result) {
                    is LlmStreamResult.Token -> {
                        streamed.append(result.text)
                        onText(streamed.toString())
                    }
                    is LlmStreamResult.Completed -> completedProfile = result.profile
                    is LlmStreamResult.Error -> throw result.throwable
                }
            }
        }
        val response = streamed.toString().trim()
        check(response.isNotEmpty()) { "GenieX QAIRT/NPU returned an empty response" }
        check(!response.contains("<|im_start|>") && !response.contains("<|im_end|>")) {
            "GenieX returned raw chat-template control tokens"
        }
        synchronized(stateLock) {
            check(llm === active) { "GenieX session changed during generation" }
            profile = completedProfile
            verified = true
        }
        return response
    }

    fun stop() {
        val active = llm ?: return
        runCatching { runBlocking { active.stopStream().getOrThrow() } }
    }

    fun diagnostics(): Map<String, Any?> {
        val currentProfile = profile
        return mapOf(
            "activeBackend" to if (llm != null) BACKEND else null,
            "activeBackendVerified" to verified,
            "runtime" to "GenieX",
            "runtimeVersion" to GENIEX_VERSION,
            "plugin" to qairtRuntimeId,
            "pluginVersion" to runCatching {
                sdk.getPluginVersion(qairtRuntimeId).orEmpty()
            }.getOrDefault(""),
            "computeUnit" to ComputeUnitValue.NPU.value,
            "device" to "Qualcomm $chipset HTP/NPU",
            "chipset" to chipset,
            "contextSize" to CONTEXT_SIZE,
            "model" to MODEL_NAME,
            "modelKey" to modelKey,
            "profile" to currentProfile?.let {
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

    override fun close() = synchronized(stateLock) {
        stop()
        destroyLocked()
    }

    private fun ensureInitialized() = synchronized(stateLock) {
        if (initialized) return@synchronized
        // Fail fast (with a clean error, not a native crash) if this device is not a
        // supported Qualcomm Snapdragon HTP v81 target.
        val socModel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Build.SOC_MODEL.trim().uppercase()
        } else {
            ""
        }
        if (socModel.isNotBlank() && !SUPPORTED_SOCS.contains(socModel)) {
            throw IllegalStateException(
                "GenieX Qwen3 需要 ${SUPPORTED_SOCS.joinToString("/")} HTP v81；" +
                    "当前设备芯片: ${socModel.ifEmpty { "未知" }}",
            )
        }

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
            Log.e("Talk2U/GenieX", "GenieX SDK init threw", error)
            throw IllegalStateException(
                "GenieX SDK 初始化失败: ${error.message ?: error.javaClass.simpleName}",
                error,
            )
        }
        check(initError.isNullOrBlank()) { "GenieX initialization failed: $initError" }
        chipset = runCatching { runBlocking { modelManager.detectChipset() } }
            .getOrNull()
            .orEmpty()
            .trim()
            .ifBlank { socModel }
        check(chipset.isNotBlank()) { "GenieX could not detect the Qualcomm chipset" }
        val pluginVersion = runCatching { sdk.getPluginVersion(qairtRuntimeId).orEmpty() }
            .getOrNull()
            .orEmpty()
        check(pluginVersion.isNotBlank()) { "GenieX QAIRT plugin is not registered" }
        initialized = true
    }

    private fun installedPaths(): ModelPaths {
        val key = findInstalledKey()
        checkNotNull(key) { "Install the GenieX Qwen3-4B-Instruct-2507 QAIRT model first" }
        return checkNotNull(runBlocking { modelManager.getPaths(key) }) {
            "GenieX did not return model paths for $key"
        }
    }

    private fun validateQairtBundle(paths: ModelPaths): QairtBundle {
        val entryPoint = File(paths.model_path).canonicalFile
        require(entryPoint.isFile) {
            "GenieX QAIRT model entry point is missing: ${entryPoint.path}"
        }
        val root = paths.model_dir
            .takeIf(String::isNotBlank)
            ?.let(::File)
            ?.canonicalFile
            ?: requireNotNull(entryPoint.parentFile) {
                "GenieX QAIRT model entry point has no bundle directory"
            }
        require(root.isDirectory) { "GenieX QAIRT model bundle is missing: ${root.path}" }
        require(entryPoint.isInside(root)) {
            "GenieX QAIRT model entry point is outside its bundle directory"
        }

        val configFile = requiredBundleFile(root, GENIE_CONFIG_FILE)
        val config = runCatching { JSONObject(configFile.readText(Charsets.UTF_8)) }
            .getOrElse { error ->
                throw IllegalArgumentException(
                    "Invalid $GENIE_CONFIG_FILE: ${error.message ?: error.javaClass.simpleName}",
                    error,
                )
            }
        val dialog = config.requiredObject("dialog")
        val contextSize = dialog.requiredObject("context").requiredPositiveInt("size")
        require(contextSize == CONTEXT_SIZE) {
            "Unsupported Qwen3 context size $contextSize; expected $CONTEXT_SIZE"
        }

        val tokenizerPath = dialog.requiredObject("tokenizer").requiredString("path")
        requiredBundleFile(root, tokenizerPath)

        val engine = dialog.requiredObject("engine")
        val backend = engine.requiredObject("backend")
        require(backend.requiredString("type") == QAIRT_BACKEND_TYPE) {
            "GenieX model is not configured for the QnnHtp backend"
        }
        backend.optString("extensions")
            .takeIf(String::isNotBlank)
            ?.let { requiredBundleFile(root, it) }

        val model = engine.requiredObject("model")
        require(model.requiredString("type") == "binary") {
            "GenieX QAIRT model must use context binaries"
        }
        val binaries = model.requiredObject("binary").getJSONArray("ctx-bins")
        require(binaries.length() > 0) { "GenieX QAIRT model has no context binaries" }
        var entryPointDeclared = false
        for (index in 0 until binaries.length()) {
            val binary = requiredBundleFile(root, binaries.getString(index))
            entryPointDeclared = entryPointDeclared || binary == entryPoint
        }
        require(entryPointDeclared) {
            "GenieX model entry point is not declared in $GENIE_CONFIG_FILE"
        }

        val metadataFile = requiredBundleFile(root, MODEL_METADATA_FILE)
        val metadata = runCatching { JSONObject(metadataFile.readText(Charsets.UTF_8)) }
            .getOrElse { error ->
                throw IllegalArgumentException(
                    "Invalid $MODEL_METADATA_FILE: ${error.message ?: error.javaClass.simpleName}",
                    error,
                )
            }
        require(metadata.requiredString("runtime").equals("genie", ignoreCase = true)) {
            "The installed Qwen3 package is not a Genie model"
        }
        require(metadata.requiredString("precision").equals(QAIRT_PRECISION, ignoreCase = true)) {
            "The installed Qwen3 package is not the required W4A16 model"
        }
        require(metadata.requiredString("model_id") == MODEL_ID) {
            "Unexpected GenieX model id '${metadata.optString("model_id")}'"
        }
        return QairtBundle(root, entryPoint, contextSize)
    }

    private fun requiredBundleFile(root: File, relativePath: String): File {
        require(relativePath.isNotBlank()) { "GenieX model bundle contains an empty path" }
        val file = File(root, relativePath).canonicalFile
        require(file.isInside(root) && file.isFile) {
            "GenieX model bundle is missing $relativePath"
        }
        require(file.length() > 0L) { "GenieX model bundle contains an empty $relativePath" }
        return file
    }

    private fun File.isInside(root: File): Boolean =
        path == root.path || path.startsWith(root.path + File.separator)

    private fun JSONObject.requiredObject(name: String): JSONObject =
        optJSONObject(name) ?: throw IllegalArgumentException("GenieX config is missing '$name'")

    private fun JSONObject.requiredString(name: String): String =
        optString(name).trim().takeIf(String::isNotEmpty)
            ?: throw IllegalArgumentException("GenieX config is missing '$name'")

    private fun JSONObject.requiredPositiveInt(name: String): Int =
        optInt(name, 0).takeIf { it > 0 }
            ?: throw IllegalArgumentException("GenieX config has an invalid '$name'")

    private fun findInstalledKey(): String? {
        val installed = runBlocking { modelManager.list() }
        val alias = runCatching {
            runBlocking { modelManager.resolveAlias(HUB_MODEL_NAME) }
        }.getOrNull()
        val candidates = buildList {
            add(HUB_MODEL_NAME)
            add(MODEL_NAME)
            alias?.takeIf(String::isNotBlank)?.let(::add)
            addAll(installed.filter { it.endsWith("/$MODEL_NAME") || it.contains(MODEL_NAME) })
        }
        return candidates.distinct().firstOrNull { candidate ->
            val paths = runCatching {
                runBlocking { modelManager.getPaths(candidate) }
            }.getOrNull() ?: return@firstOrNull false
            paths.runtime_id == qairtRuntimeId && File(paths.model_path).exists()
        }
    }

    private fun modelPullInput() = ModelPullInput(
        HUB_MODEL_NAME,
        null,
        HubSource.AUTO,
        null,
        null,
        chipset,
        MODEL_NAME,
        ModelType.LLM,
    )

    private fun destroyLocked() {
        val active = llm
        llm = null
        verified = false
        profile = null
        active?.close()
    }

    private fun generationConfig(maxTokens: Int): GenerationConfig = GenerationConfig(
        maxTokens.coerceIn(1, MAX_OUTPUT_TOKENS),
        emptyArray(),
        0,
        0,
        SamplerConfig(0.8f, 0.95f, 40, 0.0f, 1.0f, 0.0f, 0.0f, 42, "", ""),
        emptyArray(),
        0,
        emptyArray(),
        0,
        false,
        0,
    )

    private fun qairtModelConfig(): ModelConfig = ModelConfig().apply {
        // GenieX 0.3.17 treats zero as "read from genie_config.json" for QAIRT.
        nCtx = 0
        nGpuLayers = 0
    }

    private fun aggregateProgress(files: List<FileProgress>): DownloadProgress {
        var downloaded = 0L
        var total = 0L
        files.forEach { file ->
            downloaded += file.downloaded_bytes.coerceAtLeast(0L)
            total += file.total_bytes.coerceAtLeast(0L)
        }
        return DownloadProgress(downloaded.coerceAtMost(total), total)
    }

    private fun normalizeRole(role: String): String = when (role) {
        "system", "assistant" -> role
        else -> "user"
    }

    companion object {
        const val MODEL_NAME = "Qwen3-4B-Instruct-2507"
        const val HUB_MODEL_NAME = "ai-hub-models/Qwen3-4B-Instruct-2507"
        const val BACKEND = "geniex-qairt-npu"
        const val GENIEX_VERSION = "0.3.17"
        const val CONTEXT_SIZE = 4096
        const val MAX_OUTPUT_TOKENS = 256
        private const val MODEL_ID = "qwen3_4b_instruct_2507"
        private const val GENIE_CONFIG_FILE = "genie_config.json"
        private const val MODEL_METADATA_FILE = "metadata.json"
        private const val QAIRT_BACKEND_TYPE = "QnnHtp"
        private const val QAIRT_PRECISION = "w4a16"
        private const val GENIEX_SUCCESS = 0
        private val SUPPORTED_SOCS = setOf("SM8750", "SM8850")
    }
}
