package com.blue.talk2u

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipInputStream

/**
 * On-device model identities this build serves.
 *
 * Both are the same Qwen3-4B-Instruct-2507 family, so they share the ChatML
 * template, the 4096-token context and the output cap. They differ only in
 * weights and in how they can be installed.
 */
internal enum class ModelPreset(
    val id: String,
    val displayName: String,
    val family: String,
    val huggingFaceRepo: String,
    val baseModel: String,
    val license: String,
    /** GenieX AI Hub catalog key; null when the preset has no published bundle. */
    val hubModel: String?,
    /** `metadata.json` `model_id` an official QAIRT bundle declares. */
    val qairtModelId: String?,
) {
    /** The abliterated derivative. Import only: no public compiled bundle exists. */
    ABLITERATED(
        id = "abliterated",
        displayName = "Huihui-Qwen3-4B-Instruct-2507-abliterated",
        family = "Qwen3-4B-Instruct-2507",
        huggingFaceRepo = "huihui-ai/Huihui-Qwen3-4B-Instruct-2507-abliterated",
        baseModel = "Qwen/Qwen3-4B-Instruct-2507",
        license = "Apache-2.0",
        hubModel = null,
        qairtModelId = null,
    ),

    /** The upstream checkpoint with Qualcomm's published QAIRT bundle. */
    BASE(
        id = "base",
        displayName = "Qwen3-4B-Instruct-2507",
        family = "Qwen3-4B-Instruct-2507",
        huggingFaceRepo = "Qwen/Qwen3-4B-Instruct-2507",
        baseModel = "Qwen/Qwen3-4B-Instruct-2507",
        license = "Apache-2.0",
        hubModel = "ai-hub-models/Qwen3-4B-Instruct-2507",
        qairtModelId = "qwen3_4b_instruct_2507",
    ),
    ;

    companion object {
        fun fromId(id: String?): ModelPreset? = entries.firstOrNull { it.id == id }

        /** Preset the app installs when the user has not chosen one. */
        val default: ModelPreset = ABLITERATED
    }
}

/** Shared numeric limits for every preset. */
internal object OnDeviceModel {
    const val CONTEXT_SIZE = 4096
    const val MAX_OUTPUT_TOKENS = 3072

    /**
     * Tokens pinned at the head of the context while the sliding window moves.
     * Covers the persona system prompt, so the character survives a long chat.
     */
    const val SLIDING_WINDOW_KEEP = 384

    /** Messages kept when a turn is retried on a shorter context. */
    const val RETRY_TURNS = 3

    /**
     * Layers handed to the accelerator.
     *
     * `-1` is llama.cpp's "all layers" value. The previous `64` happened to be
     * enough for Qwen3-4B's 36 blocks, but it was a magic ceiling rather than
     * the documented contract; a checkpoint with more blocks would silently
     * leave layers on the CPU.
     */
    const val OFFLOAD_LAYERS = -1

    /**
     * Host threads attached to a non-CPU llama.cpp session.
     *
     * GenieX's llama.cpp plugin defaults to eight pinned threads with a polling
     * wait even when every transformer layer is on HTP0. Those threads do not
     * execute the model, but they stay runnable through decode. Two are enough
     * for tokenization, sampling and the few host-side graph edges.
     */
    const val HOST_THREADS = 2
}

/**
 * GGUF `general.file_type` values and their HTP suitability.
 *
 * llama.cpp's HTP backend has native kernels for the legacy, block-simple
 * quantizations. K-quants and IQ-quants execute some tensors on the CPU, which is
 * exactly the behaviour that makes a phone hot while the UI still says NPU. The
 * GenieX run notes state it directly: use Q4_0 or Q8_0 for a clean NPU run.
 */
internal object GgufFileType {
    fun label(fileType: Int?): String = when (fileType) {
        0 -> "F32"
        1 -> "F16"
        2 -> "Q4_0"
        3 -> "Q4_1"
        4 -> "Q4_1_SOME_F16"
        7 -> "Q8_0"
        8 -> "Q5_0"
        9 -> "Q5_1"
        10 -> "Q2_K"
        11 -> "Q3_K_S"
        12 -> "Q3_K_M"
        13 -> "Q3_K_L"
        14 -> "Q4_K_S"
        15 -> "Q4_K_M"
        16 -> "Q5_K_S"
        17 -> "Q5_K_M"
        18 -> "Q6_K"
        19 -> "IQ2_XXS"
        20 -> "IQ2_XS"
        21 -> "IQ3_XXS"
        22 -> "IQ1_S"
        23 -> "IQ4_NL"
        24 -> "IQ3_S"
        25 -> "IQ2_S"
        26 -> "IQ4_XS"
        27 -> "IQ1_M"
        else -> fileType?.let { "type $it" } ?: "unknown"
    }

    /**
     * True for the two quantizations GenieX documents as a clean HTP run.
     *
     * This is deliberately a whitelist. A new quantization gets added here only
     * after the HTP kernels are confirmed, not because the label looks close
     * enough to Q4_0.
     */
    fun isCleanOnHtp(fileType: Int?): Boolean = fileType == 2 || fileType == 7
}

/** Execution family of an installed artifact. */
internal enum class LlmRuntime(val id: String) {
    /** QAIRT context binaries executed by `libgeniex_plugin_qairt.so`. */
    QAIRT("qairt"),

    /** llama.cpp GGUF executed by `libgeniex_plugin_llama_cpp.so`. */
    LLAMA_CPP("llama-cpp"),
}

/** Artifact format accepted by the importer. */
internal enum class ArtifactKind(val id: String, val runtime: LlmRuntime) {
    /** Zipped QAIRT bundle (`genie_config.json` + context binaries). */
    QAIRT_BUNDLE("qairt-bundle", LlmRuntime.QAIRT),

    /** Single-file llama.cpp GGUF checkpoint. */
    GGUF("gguf", LlmRuntime.LLAMA_CPP),
}

/**
 * Where a session actually runs.
 *
 * GenieX registers two plugins and each accepts its own device aliases; the
 * SDK's own message is `Unknown device alias (expected one of: cpu, gpu, npu,
 * hybrid)`. The llama.cpp plugin can therefore execute a GGUF on the Hexagon
 * NPU through `libggml-hexagon.so` + `libggml-htp-v<arch>.so`, which is what
 * [LLAMA_NPU] uses — no QAIRT compilation required.
 */
internal enum class Accelerator(val id: String, val backendId: String) {
    /** Hexagon HTP through QAIRT context binaries. */
    QAIRT_NPU("qairt-npu", "geniex-qairt-npu"),

    /** Hexagon HTP through the llama.cpp ggml-hexagon backend. */
    LLAMA_NPU("llama-npu", "geniex-llamacpp-npu"),

    /** Adreno GPU through the OpenCL backend of llama.cpp. */
    LLAMA_GPU("llama-gpu", "geniex-llamacpp-gpu"),

    /** CPU through the scalar backend of llama.cpp. */
    LLAMA_CPU("llama-cpu", "geniex-llamacpp-cpu"),
    ;

    val isHardware: Boolean
        get() = this != LLAMA_CPU

    val isNpu: Boolean
        get() = this == QAIRT_NPU || this == LLAMA_NPU
}

/** Progress of one import, in bytes actually written to private storage. */
internal data class InstallProgress(val copiedBytes: Long, val totalBytes: Long)

/** An artifact that is installed and ready to be loaded. */
internal data class InstalledArtifact(
    val preset: ModelPreset,
    val kind: ArtifactKind,
    /** GGUF file, or the QAIRT bundle root. */
    val path: File,
    /** Bytes on disk, summed from the files this artifact owns. */
    val bytes: Long,
    /** Model name the artifact declares about itself. */
    val declaredName: String?,
    /** Extra engine-specific facts for diagnostics. */
    val detail: Map<String, Any?>,
    /** GenieX model-manager key, only for a bundle pulled from the AI Hub. */
    val hubKey: String? = null,
)

/**
 * Private storage for on-device language-model artifacts.
 *
 * Layout:
 *
 * ```
 * models/on-device-llm/
 *   staging/<kind>-<epoch>/     copy and validation happen here
 *   qairt/                      genie_config.json + context binaries
 *   gguf/model.gguf             one GGUF, replaced atomically
 *   installed.json              which preset/format is installed, and where
 * ```
 *
 * Only one artifact is active at a time. Importing replaces the previous one as
 * a single transaction: copy into staging, validate the copy, swap. A cancelled
 * or rejected import therefore leaves the working model untouched — the failure
 * mode that matters when the user has spent twenty minutes on a 3 GB transfer.
 */
internal class OnDeviceArtifactStore(context: Context) {
    private val resolver: ContentResolver = context.applicationContext.contentResolver
    private val root = File(context.noBackupFilesDir, "models/on-device-llm")
    private val stagingRoot = File(root, "staging")
    private val qairtRoot = File(root, "qairt")
    private val qairtPrevious = File(root, "qairt-previous")
    private val ggufRoot = File(root, "gguf")
    private val ggufFile = File(ggufRoot, "model.gguf")
    private val ggufPrevious = File(ggufRoot, "model.previous.gguf")
    private val marker = File(root, "installed.json")

    @Volatile
    private var cancelled = false

    /** Requests that the running copy loop stop at the next chunk boundary. */
    fun cancel() {
        cancelled = true
    }

    /** Returns the active artifact, or null when nothing is installed. */
    fun installed(): InstalledArtifact? {
        readMarker()?.let { return it }
        // No marker (first run after an upgrade): fall back to a directory probe.
        return when {
            qairtRoot.isDirectory -> runCatching { qairtArtifact(ModelPreset.default, qairtRoot) }
                .getOrNull()
            ggufFile.isFile -> runCatching { ggufArtifact(ModelPreset.default, ggufFile) }
                .getOrNull()
            else -> null
        }
    }

    /** Best-effort description even when the on-disk artifact is broken. */
    fun status(): Map<String, Any?> {
        val artifact = installed()
        return mapOf(
            "modelReady" to (artifact != null),
            "modelBytes" to (artifact?.bytes ?: 0L),
            "modelId" to (artifact?.preset?.id ?: markerPresetId()),
            "artifact" to artifact?.let {
                mapOf(
                    "modelId" to it.preset.id,
                    "model" to it.preset.displayName,
                    "kind" to it.kind.id,
                    "runtime" to it.kind.runtime.id,
                    "path" to it.path.absolutePath,
                    "bytes" to it.bytes,
                    "declaredName" to it.declaredName,
                    "hubKey" to it.hubKey,
                ) + it.detail
            },
        )
    }

    /** Installs a `.gguf` file picked through the Storage Access Framework. */
    fun installGguf(
        preset: ModelPreset,
        uri: Uri,
        onProgress: (InstallProgress) -> Unit,
    ): InstalledArtifact {
        cancelled = false
        prepareStaging()
        val staging = newStagingDirectory("gguf")
        val target = File(staging, "model.gguf")
        try {
            val copied = copy(uri, target, GGUF_MAX_BYTES, onProgress)
            require(copied >= GGUF_MIN_BYTES) {
                "The selected file is too small to be a 4B GGUF checkpoint ($copied bytes)"
            }
            // Validate in staging, then re-resolve the artifact from its final
            // path: the swap renames the staging directory away, so an artifact
            // captured before it would point at a path that no longer exists.
            ggufArtifact(preset, target)
            // A fresh GGUF directory keeps the QAIRT bundle out of `installed()`
            // so the import cannot look like a no-op.
            replaceDirectory(staging, ggufRoot)
            deletePrivate(qairtRoot)
            deletePrivate(qairtPrevious)
            val installed = ggufArtifact(preset, ggufFile)
            writeMarker(installed)
            return installed
        } finally {
            deletePrivate(staging)
        }
    }

    /** Installs a zipped QAIRT bundle picked through the Storage Access Framework. */
    fun installQairtBundle(
        preset: ModelPreset,
        uri: Uri,
        onProgress: (InstallProgress) -> Unit,
    ): InstalledArtifact {
        cancelled = false
        prepareStaging()
        val staging = newStagingDirectory("qairt")
        try {
            val extracted = extract(uri, staging, QAIRT_MAX_BYTES, onProgress)
            require(extracted > 0L) { "The selected ZIP archive is empty" }
            val staged = QairtBundleValidator.load(
                QairtBundleValidator.findRoot(staging),
                OnDeviceModel.CONTEXT_SIZE,
            )
            qairtArtifact(preset, staged.root)
            // `staged.root` is inside staging; moving its parent keeps the whole
            // extracted tree addressable by the config's relative paths.
            replaceDirectory(requireNotNull(staged.root.parentFile), qairtRoot)
            deletePrivate(ggufRoot)
            val installed = qairtArtifact(preset, qairtRoot)
            writeMarker(installed)
            return installed
        } finally {
            deletePrivate(staging)
        }
    }

    /**
     * Records a bundle GenieX already installed from the AI Hub.
     *
     * The bytes stay in the SDK's own store — copying three gigabytes to end up
     * with two copies on a phone is not a trade worth making.
     */
    fun adoptHubBundle(preset: ModelPreset, hubKey: String, modelDir: File): InstalledArtifact {
        require(modelDir.isDirectory) { "The pulled bundle directory is missing: ${modelDir.path}" }
        val artifact = qairtArtifact(preset, modelDir).copy(hubKey = hubKey)
        deletePrivate(ggufRoot)
        writeMarker(artifact)
        return artifact
    }

    /** Removes the active artifact. */
    fun delete(kind: ArtifactKind? = null) {
        when (kind) {
            ArtifactKind.GGUF -> deletePrivate(ggufRoot)
            ArtifactKind.QAIRT_BUNDLE -> {
                deletePrivate(qairtRoot)
                deletePrivate(qairtPrevious)
            }
            null -> {
                deletePrivate(ggufRoot)
                deletePrivate(qairtRoot)
                deletePrivate(qairtPrevious)
            }
        }
        deletePrivate(stagingRoot)
        deletePrivate(marker)
    }

    private fun qairtArtifact(preset: ModelPreset, directory: File): InstalledArtifact {
        val bundle = QairtBundleValidator.load(directory, OnDeviceModel.CONTEXT_SIZE)
        // An official bundle declares its own id; an imported derivative may
        // declare anything, so the declared value is reported, not enforced.
        val expected = preset.qairtModelId
        require(expected == null || bundle.modelId == expected) {
            "The bundle declares model_id '${bundle.modelId}', but ${preset.displayName} " +
                "ships '$expected'"
        }
        return InstalledArtifact(
            preset = preset,
            kind = ArtifactKind.QAIRT_BUNDLE,
            path = directory,
            bytes = directoryBytes(bundle.root),
            declaredName = bundle.modelId,
            detail = mapOf(
                "precision" to bundle.precision,
                "contextSize" to bundle.contextSize,
                "entryPoint" to bundle.entryPoint.name,
                "tokenizer" to bundle.tokenizer.name,
            ),
        )
    }

    private fun ggufArtifact(preset: ModelPreset, file: File): InstalledArtifact {
        val summary = GgufInspector.inspect(file)
        require(summary.qwen3) {
            "The GGUF declares architecture '${summary.architecture.orEmpty()}', " +
                "but ${preset.displayName} is a qwen3 checkpoint"
        }
        require(summary.tensorCount > 0) { "The GGUF declares no tensors" }
        // The HTP kernels are only complete for the legacy block quantizations.
        // A K-quant would load, but llama.cpp would execute its scale/min tensors
        // (and, for some graphs, whole matmuls) on the CPU while the UI still
        // reported an NPU session. Rejecting it at import is the only truthful
        // way to keep the "every layer on the NPU" contract; the user can
        // re-export the same weights as Q4_0 or Q8_0 and import again.
        val quantization = GgufFileType.label(summary.fileType)
        if (!GgufFileType.isCleanOnHtp(summary.fileType)) {
            throw UnsupportedGgufQuantization(quantization)
        }
        return InstalledArtifact(
            preset = preset,
            kind = ArtifactKind.GGUF,
            path = file,
            bytes = file.length(),
            declaredName = summary.name,
            detail = mapOf(
                "architecture" to summary.architecture,
                "tensorCount" to summary.tensorCount,
                "fileType" to summary.fileType,
                "quantization" to quantization,
                "npuClean" to true,
                "blockCount" to summary.blockCount,
                "embeddingLength" to summary.embeddingLength,
                "ggufVersion" to summary.version,
            ),
        )
    }

    /** Swaps [staged] in as [destination], keeping the previous tree until the swap wins. */
    private fun replaceDirectory(staged: File, destination: File) {
        destination.parentFile?.let { parent ->
            require(parent.isDirectory || parent.mkdirs()) { "Cannot create the model directory" }
        }
        val previous = if (destination == ggufRoot) ggufPrevious else qairtPrevious
        deletePrivate(previous)
        if (destination.exists() && !destination.renameTo(previous)) {
            throw IllegalStateException("Cannot move the previous model aside")
        }
        if (!staged.renameTo(destination)) {
            if (previous.exists()) previous.renameTo(destination)
            throw IllegalStateException("Cannot move the model into place")
        }
        deletePrivate(previous)
    }

    private fun readMarker(): InstalledArtifact? {
        if (!marker.isFile) return null
        return runCatching {
            val json = JSONObject(marker.readText(Charsets.UTF_8))
            val preset = ModelPreset.fromId(json.optString("modelId")) ?: ModelPreset.default
            val kind = ArtifactKind.entries.firstOrNull { it.id == json.optString("kind") }
                ?: return@runCatching null
            val path = json.optString("path").takeIf(String::isNotBlank)?.let(::File)
                ?: return@runCatching null
            val hubKey = json.optString("hubKey").takeIf(String::isNotBlank)
            when (kind) {
                ArtifactKind.QAIRT_BUNDLE -> qairtArtifact(preset, path).copy(hubKey = hubKey)
                ArtifactKind.GGUF -> ggufArtifact(preset, path)
            }
        }.getOrNull()
    }

    private fun markerPresetId(): String? = runCatching {
        JSONObject(marker.readText(Charsets.UTF_8)).optString("modelId")
            .takeIf(String::isNotBlank)
    }.getOrNull()

    private fun writeMarker(artifact: InstalledArtifact) {
        runCatching {
            require(root.isDirectory || root.mkdirs()) { "Cannot create the model directory" }
            val json = JSONObject()
                .put("modelId", artifact.preset.id)
                .put("kind", artifact.kind.id)
                .put("runtime", artifact.kind.runtime.id)
                .put("path", artifact.path.absolutePath)
                .put("bytes", artifact.bytes)
                .put("declaredName", artifact.declaredName)
                .put("hubKey", artifact.hubKey)
                .put("huggingFaceRepo", artifact.preset.huggingFaceRepo)
                .put("installedAt", System.currentTimeMillis())
            artifact.detail.forEach { (key, value) -> json.put(key, value ?: JSONObject.NULL) }
            marker.writeText(json.toString(2), Charsets.UTF_8)
        }
    }

    /**
     * Streams a SAF document into [destination].
     *
     * The copy never trusts the provider: the declared size is only a hint, the
     * written byte count is checked against [limit] as it grows, and the loop
     * honours cancellation at every chunk.
     */
    private fun copy(
        uri: Uri,
        destination: File,
        limit: Long,
        onProgress: (InstallProgress) -> Unit,
    ): Long {
        val declared = declaredSize(uri, limit)
        destination.parentFile?.let { parent ->
            require(parent.isDirectory || parent.mkdirs()) { "Cannot create the staging directory" }
        }
        val buffer = ByteArray(COPY_BUFFER_BYTES)
        var total = 0L
        var lastReported = 0L
        var lastReportedAt = System.nanoTime()
        resolver.openInputStream(uri)?.use { input ->
            FileOutputStream(destination).use { output ->
                while (true) {
                    if (cancelled) throw ImportCancelled()
                    val read = input.read(buffer)
                    if (read < 0) break
                    total += read
                    require(total <= limit) {
                        "The selected file grows beyond the $limit byte import limit"
                    }
                    output.write(buffer, 0, read)
                    val now = System.nanoTime()
                    if (total - lastReported >= PROGRESS_STEP_BYTES ||
                        now - lastReportedAt >= PROGRESS_STEP_NANOS
                    ) {
                        lastReported = total
                        lastReportedAt = now
                        onProgress(InstallProgress(total, if (declared > 0) declared else total))
                    }
                }
                output.fd.sync()
            }
        } ?: throw IllegalStateException("The selected document cannot be opened")
        onProgress(InstallProgress(total, if (declared > 0) declared else total))
        return total
    }

    /** Extracts every file of a ZIP archive under [destination]. */
    private fun extract(
        uri: Uri,
        destination: File,
        limit: Long,
        onProgress: (InstallProgress) -> Unit,
    ): Long {
        val declared = declaredSize(uri, limit)
        var extracted = 0L
        var files = 0
        var lastReported = 0L
        var lastReportedAt = System.nanoTime()
        val seen = HashSet<String>()
        resolver.openInputStream(uri)?.let { raw ->
            ZipInputStream(BufferedInputStream(raw)).use { zip ->
                while (true) {
                    if (cancelled) throw ImportCancelled()
                    val entry = zip.nextEntry ?: break
                    if (entry.isDirectory) continue
                    val name = SafeRelativePath.normalize(entry.name)
                    require(seen.add(name)) { "The archive contains a duplicate entry: $name" }
                    files += 1
                    require(files <= MAX_ARCHIVE_FILES) { "The archive contains too many files" }
                    val file = SafeRelativePath.resolveIn(destination, name)
                    file.parentFile?.let { parent ->
                        require(parent.isDirectory || parent.mkdirs()) {
                            "Cannot create a directory for $name"
                        }
                    }
                    FileOutputStream(file).use { output ->
                        val buffer = ByteArray(COPY_BUFFER_BYTES)
                        while (true) {
                            if (cancelled) throw ImportCancelled()
                            val read = zip.read(buffer)
                            if (read < 0) break
                            extracted += read
                            require(extracted <= limit) {
                                "The archive expands beyond the $limit byte import limit"
                            }
                            output.write(buffer, 0, read)
                            val now = System.nanoTime()
                            if (extracted - lastReported >= PROGRESS_STEP_BYTES ||
                                now - lastReportedAt >= PROGRESS_STEP_NANOS
                            ) {
                                lastReported = extracted
                                lastReportedAt = now
                                onProgress(
                                    InstallProgress(
                                        extracted,
                                        if (declared > 0) declared else extracted,
                                    ),
                                )
                            }
                        }
                        output.fd.sync()
                    }
                }
            }
        } ?: throw IllegalStateException("The selected archive cannot be opened")
        onProgress(InstallProgress(extracted, if (declared > 0) declared else extracted))
        return extracted
    }

    private fun declaredSize(uri: Uri, limit: Long): Long {
        val declared = runCatching {
            resolver.openAssetFileDescriptor(uri, "r")?.use { it.length }
        }.getOrNull() ?: 0L
        require(declared <= limit) {
            "The selected file is $declared bytes, above the $limit byte import limit"
        }
        return declared
    }

    private fun prepareStaging() {
        require(stagingRoot.isDirectory || stagingRoot.mkdirs()) {
            "Cannot create the model staging directory"
        }
        // A previous run may have died between copy and swap; its staging tree is
        // garbage by definition because swap is the last step.
        stagingRoot.listFiles()?.forEach(::deletePrivate)
    }

    private fun newStagingDirectory(prefix: String): File {
        val directory = File(stagingRoot, "$prefix-${System.currentTimeMillis()}")
        require(directory.mkdirs()) { "Cannot create the model staging directory" }
        return directory
    }

    private fun directoryBytes(directory: File): Long = directory
        .walkTopDown()
        .filter(File::isFile)
        .sumOf(File::length)

    private fun deletePrivate(file: File) {
        if (!file.exists()) return
        file.deleteRecursively()
    }

    companion object {
        /** A 4B checkpoint at Q4 is ~2.5 GB; anything below 512 MB is not one. */
        const val GGUF_MIN_BYTES = 512L * 1024 * 1024

        /** Q8_0 of 4B is ~4.3 GB; the bound leaves room for F16 (8.2 GB). */
        const val GGUF_MAX_BYTES = 9L * 1024 * 1024 * 1024

        /** A w4a16 QAIRT bundle for 4B is 2.5–3.5 GB. */
        const val QAIRT_MAX_BYTES = 8L * 1024 * 1024 * 1024

        private const val MAX_ARCHIVE_FILES = 4096
        private const val COPY_BUFFER_BYTES = 256 * 1024
        private const val PROGRESS_STEP_BYTES = 4L * 1024 * 1024
        private const val PROGRESS_STEP_NANOS = 250_000_000L
    }
}

/** Raised when an import stops because the user cancelled it. */
internal class ImportCancelled : IllegalStateException("The model import was cancelled")

/**
 * Raised when the GGUF header names a quantization without complete HTP kernels.
 *
 * A distinct type lets the channel return a stable code, so the Flutter layer can
 * show the localized "use Q4_0 or Q8_0" message instead of an English native
 * string. The message remains the fallback for logs and diagnostics.
 */
internal class UnsupportedGgufQuantization(
    val quantization: String,
) : IllegalArgumentException(
    "The GGUF is $quantization. This build installs only Q4_0 or Q8_0 " +
        "so every tensor runs on the Hexagon NPU; $quantization leaves tensors " +
        "on the CPU. Re-export the checkpoint as Q4_0 or Q8_0.",
)

/** Reads the GGUF header through the Rust bridge. */
internal object GgufInspector {
    data class Summary(
        val version: Int,
        val tensorCount: Long,
        val fileBytes: Long,
        val architecture: String?,
        val name: String?,
        val fileType: Int?,
        val blockCount: Int?,
        val embeddingLength: Int?,
        val qwen3: Boolean,
    )

    fun inspect(file: File): Summary {
        require(file.isFile) { "The GGUF file is missing: ${file.absolutePath}" }
        val response = OnDeviceAiNative.inspectGguf(file.absolutePath)
            ?: throw IllegalStateException("The GGUF inspector returned no result")
        val json = runCatching { JSONObject(response) }.getOrElse {
            throw IllegalStateException("The GGUF inspector returned malformed JSON")
        }
        if (!json.optBoolean("ok")) {
            throw IllegalStateException(
                json.optString("error").ifBlank { "The GGUF inspector rejected the file" },
            )
        }
        return Summary(
            version = json.optInt("version"),
            tensorCount = json.optLong("tensorCount"),
            fileBytes = json.optLong("fileBytes"),
            architecture = json.optString("architecture").takeIf(String::isNotBlank),
            name = json.optString("name").takeIf(String::isNotBlank),
            fileType = json.optInt("fileType", -1).takeIf { it >= 0 },
            blockCount = json.optInt("blockCount", 0).takeIf { it > 0 },
            embeddingLength = json.optInt("embeddingLength", 0).takeIf { it > 0 },
            qwen3 = json.optBoolean("qwen3"),
        )
    }
}
