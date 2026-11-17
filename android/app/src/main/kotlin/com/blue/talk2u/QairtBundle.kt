package com.blue.talk2u

/**
 * Validates a QAIRT context-binary bundle before it is moved into private
 * storage.
 *
 * A QAIRT bundle is not a checkpoint: it is a compiled graph plus the Genie
 * dialog configuration that tells the runtime where the tokenizer, the context
 * binaries and the HTP backend extension live. Loading a bundle whose config
 * disagrees with the session (wrong context size, a non-HTP backend, a missing
 * ctx-bin) fails deep inside QAIRT with an opaque QNN error, after the model has
 * been mapped into memory.
 *
 * Everything here is pure JVM code — `java.io` and `org.json` only — so the rules
 * are unit-tested on the host instead of on a device.
 */
internal data class QairtBundle(
    /** Directory that holds `genie_config.json`; the entry point's parent. */
    val root: java.io.File,
    /** First context binary declared by the config. */
    val entryPoint: java.io.File,
    /** Tokenizer the config points at. */
    val tokenizer: java.io.File,
    /** Optional HTP backend extension (custom op package). */
    val backendExtension: java.io.File?,
    /** KV-cache size declared by the bundle. */
    val contextSize: Int,
    /** Model id declared by `metadata.json`. */
    val modelId: String,
    /** Quantization declared by `metadata.json`. */
    val precision: String,
)

internal object QairtBundleValidator {
    const val GENIE_CONFIG_FILE = "genie_config.json"
    const val MODEL_METADATA_FILE = "metadata.json"
    private const val QAIRT_BACKEND_TYPE = "QnnHtp"
    private const val QAIRT_PRECISION = "w4a16"

    /**
     * Finds the directory that actually holds the bundle.
     *
     * A compiler writes `genie_config.json` at the bundle root, but an archive
     * usually wraps it in one or two directory levels. Searching is bounded so a
     * 4096-file archive cannot turn import into a full-tree walk.
     */
    fun findRoot(archiveRoot: java.io.File): java.io.File {
        require(archiveRoot.isDirectory) { "The QAIRT archive was not extracted" }
        val config = archiveRoot.walkTopDown()
            .maxDepth(SEARCH_DEPTH)
            .firstOrNull { it.isFile && it.name == GENIE_CONFIG_FILE }
            ?: throw IllegalArgumentException(
                "The archive contains no $GENIE_CONFIG_FILE at its root or one level below it",
            )
        return requireNotNull(config.parentFile) {
            "The $GENIE_CONFIG_FILE has no parent directory"
        }.canonicalFile
    }

    /**
     * Validates [root] and returns the resolved bundle.
     *
     * @param expectedContextSize the KV-cache size the runtime will request.
     */
    fun load(root: java.io.File, expectedContextSize: Int): QairtBundle {
        val canonicalRoot = root.canonicalFile
        require(canonicalRoot.isDirectory) {
            "The QAIRT bundle directory is missing: ${canonicalRoot.path}"
        }

        val configFile = requiredFile(canonicalRoot, GENIE_CONFIG_FILE)
        val config = parseObject(configFile, GENIE_CONFIG_FILE)
        val dialog = config.requiredObject("dialog")

        val contextSize = dialog.requiredObject("context").requiredPositiveInt("size")
        require(contextSize == expectedContextSize) {
            "The bundle declares a $contextSize token context; this build requires " +
                "$expectedContextSize. Recompile the model with --context-length $expectedContextSize."
        }

        val tokenizer = requiredFile(
            canonicalRoot,
            dialog.requiredObject("tokenizer").requiredString("path"),
        )

        val engine = dialog.requiredObject("engine")
        val backend = engine.requiredObject("backend")
        val backendType = backend.requiredString("type")
        require(backendType.equals(QAIRT_BACKEND_TYPE, ignoreCase = true)) {
            "The bundle is compiled for '$backendType'; the NPU path requires $QAIRT_BACKEND_TYPE"
        }
        val backendExtension = backend.optString("extensions")
            .takeIf(String::isNotBlank)
            ?.let { requiredFile(canonicalRoot, it) }

        val model = engine.requiredObject("model")
        require(model.requiredString("type").equals("binary", ignoreCase = true)) {
            "The bundle does not use context binaries"
        }
        val binaries = model.requiredObject("binary").getJSONArray("ctx-bins")
        require(binaries.length() > 0) { "The bundle declares no context binaries" }

        var entryPoint: java.io.File? = null
        for (index in 0 until binaries.length()) {
            val binary = requiredFile(canonicalRoot, binaries.getString(index))
            if (entryPoint == null) entryPoint = binary
        }

        val metadata = parseObject(requiredFile(canonicalRoot, MODEL_METADATA_FILE), MODEL_METADATA_FILE)
        require(metadata.requiredString("runtime").equals("genie", ignoreCase = true)) {
            "The bundle is not a Genie model"
        }
        val precision = metadata.requiredString("precision")
        require(precision.equals(QAIRT_PRECISION, ignoreCase = true)) {
            "The bundle is quantized as '$precision'; the validated deployment is $QAIRT_PRECISION"
        }
        val modelId = metadata.requiredString("model_id")

        return QairtBundle(
            root = canonicalRoot,
            entryPoint = requireNotNull(entryPoint),
            tokenizer = tokenizer,
            backendExtension = backendExtension,
            contextSize = contextSize,
            modelId = modelId,
            precision = precision,
        )
    }

    /**
     * Resolves a path declared inside the bundle and proves it stays inside.
     *
     * The config is untrusted input: it arrives inside the archive the user
     * picked. A `../../` path must fail here, not become a read of the app's
     * private directory.
     */
    private fun requiredFile(root: java.io.File, relativePath: String): java.io.File {
        require(relativePath.isNotBlank()) { "The bundle declares an empty path" }
        val declared = normalizeDeclaredPath(relativePath)
        val file = SafeRelativePath.resolveIn(root, declared)
        require(file.isFile) { "The bundle is missing ${declared}" }
        require(file.length() > 0L) { "The bundle contains an empty ${declared}" }
        return file
    }

    /**
     * Compilers write paths as `./tokenizer.json`, `tokenizer.json`, and rarely
     * with a duplicated separator. All three mean the same file; only the first
     * two are safe to normalise, so anything else is left for
     * [SafeRelativePath.resolveIn] to reject.
     */
    private fun normalizeDeclaredPath(declared: String): String {
        var path = declared.trim().replace('\\', '/')
        while (path.startsWith("./")) path = path.removePrefix("./")
        return path
    }

    private fun parseObject(file: java.io.File, name: String): org.json.JSONObject =
        try {
            org.json.JSONObject(file.readText(Charsets.UTF_8))
        } catch (error: org.json.JSONException) {
            throw IllegalArgumentException("Invalid $name: ${error.message}", error)
        }

    private fun org.json.JSONObject.requiredObject(name: String): org.json.JSONObject =
        optJSONObject(name) ?: throw IllegalArgumentException("The bundle config is missing '$name'")

    private fun org.json.JSONObject.requiredString(name: String): String =
        optString(name).trim().takeIf(String::isNotEmpty)
            ?: throw IllegalArgumentException("The bundle config is missing '$name'")

    private fun org.json.JSONObject.requiredPositiveInt(name: String): Int =
        optInt(name, 0).takeIf { it > 0 }
            ?: throw IllegalArgumentException("The bundle config has an invalid '$name'")

    /**
     * `FileTreeWalk` counts the archive root as depth 0, so a config inside one
     * wrapper directory sits at depth 2.
     */
    private const val SEARCH_DEPTH = 2
}
