package com.blue.talk2u

import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicLong

internal object GenieRuntimeBridge {
    data class LoadResult(
        val backend: String,
        val config: String,
        val failures: List<String>,
        val verified: Boolean = false,
    ) {
        fun asMap(): Map<String, Any> = mapOf(
            "activeBackend" to backend,
            "activeBackendVerified" to verified,
            "config" to config,
            "fallbackFailures" to failures,
        )
    }

    private const val manifestName = "talk2u-genie-manifest.json"
    private val lock = Any()
    private val nextOwner = AtomicLong(1)
    private var handle = 0L
    private var activeOwner = 0L
    private var activeModelRoot: String? = null
    private var activeBackend: String? = null
    private var activeBackendVerified = false
    private var activeConfig: String? = null
    private var activeFailures: List<String> = emptyList()

    init {
        System.loadLibrary("talk2u_gpu_probe")
    }

    fun available(): Boolean = runCatching { nativeAvailable() }.getOrDefault(false)

    fun newOwner(): Long = nextOwner.getAndIncrement()

    fun load(owner: Long, modelRoot: File, qnnReady: Boolean): LoadResult = synchronized(lock) {
        loadLocked(owner, modelRoot, qnnReady)
    }

    fun ensureLoaded(owner: Long, modelRoot: File, qnnReady: Boolean): LoadResult = synchronized(lock) {
        val canonicalRoot = modelRoot.canonicalFile
        if (
            handle > 0 &&
            activeOwner == owner &&
            activeModelRoot == canonicalRoot.path
        ) {
            return@synchronized LoadResult(
                backend = requireNotNull(activeBackend),
                config = requireNotNull(activeConfig),
                failures = activeFailures,
                verified = activeBackendVerified,
            )
        }
        loadLocked(owner, canonicalRoot, qnnReady)
    }

    private fun loadLocked(owner: Long, modelRoot: File, qnnReady: Boolean): LoadResult {
        require(owner > 0) { "Invalid Genie session owner" }
        require(owner == nextOwner.get() - 1) { "Genie request came from a retired activity" }
        releaseLocked()
        require(available()) { "Genie runtime is not bundled or could not be loaded" }
        val root = modelRoot.canonicalFile
        val manifestFile = File(root, manifestName)
        require(manifestFile.isFile) { "$manifestName is missing" }
        val manifest = JSONObject(manifestFile.readText(Charsets.UTF_8))
        require(manifest.optInt("schemaVersion") == 1) { "Unsupported Genie manifest schema" }
        require(manifest.optString("modelId") == "Qwen/Qwen3-4B-Instruct-2507") {
            "The deployment package is not Qwen3-4B-Instruct-2507"
        }
        val backends = manifest.getJSONArray("backends")
        val candidates = ArrayList<JSONObject>()
        for (index in 0 until backends.length()) candidates += backends.getJSONObject(index)
        val priority = mapOf("qnn-htp" to 0, "cpu" to 1)
        candidates.sortBy { priority[it.optString("id")] ?: Int.MAX_VALUE }
        val failures = ArrayList<String>()
        for (backend in candidates) {
            val id = backend.optString("id")
            if (id == "qnn-htp") {
                val socModel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    Build.SOC_MODEL.orEmpty()
                } else {
                    Build.HARDWARE.orEmpty()
                }
                val validated = backend.optBoolean("contextValidated", false) &&
                    backend.optString("targetSoc").equals("SM8850", true) &&
                    backend.optString("htpArchitecture").equals("v81", true)
                if (!validated) {
                    failures += "qnn-htp: manifest has no validated SM8850/v81 context"
                    continue
                }
                if (!socModel.equals("SM8850", true)) {
                    failures += "qnn-htp: deployment targets SM8850, device reports $socModel"
                    continue
                }
                if (!qnnReady) {
                    failures += "qnn-htp: QNN V81 runtime is not ready"
                    continue
                }
            }
            if (id !in priority) continue
            val configRelative = backend.optString("config")
            val configFile = safeChild(root, configRelative)
            if (!configFile.isFile) {
                failures += "$id: missing $configRelative"
                continue
            }
            try {
                val config = absolutizePaths(JSONObject(configFile.readText(Charsets.UTF_8)), root)
                val created = nativeCreate(config.toString())
                require(created > 0) { "Genie returned an invalid dialog handle" }
                handle = created
                activeOwner = owner
                activeModelRoot = root.path
                activeBackend = id
                activeBackendVerified = false
                activeConfig = configRelative
                activeFailures = failures.toList()
                return LoadResult(id, configRelative, activeFailures)
            } catch (error: Throwable) {
                failures += "$id: ${error.message ?: error.javaClass.simpleName}"
            }
        }
        error("No Genie backend could load: ${failures.joinToString("; ")}")
    }

    fun query(owner: Long, prompt: String): String {
        val current = synchronized(lock) {
            require(activeOwner == owner) { "Genie session belongs to a retired activity" }
            handle
        }
        require(current > 0) { "Genie dialog is not loaded" }
        val response = nativeQuery(current, prompt)
        synchronized(lock) {
            if (handle == current && activeOwner == owner) activeBackendVerified = true
        }
        return response
    }

    fun stop(owner: Long) {
        val current = synchronized(lock) { if (activeOwner == owner) handle else 0L }
        if (current > 0) nativeStop(current)
    }

    fun release(owner: Long) = synchronized(lock) {
        if (activeOwner == owner) releaseLocked()
    }

    fun activeBackend(): String? = synchronized(lock) { activeBackend }

    fun activeBackendVerified(): Boolean = synchronized(lock) { activeBackendVerified }

    fun activeFallbackFailures(): List<String> = synchronized(lock) { activeFailures.toList() }

    private fun releaseLocked() {
        if (handle > 0) runCatching { nativeFree(handle) }
        handle = 0
        activeOwner = 0
        activeModelRoot = null
        activeBackend = null
        activeBackendVerified = false
        activeConfig = null
        activeFailures = emptyList()
    }

    private fun safeChild(root: File, relative: String): File {
        require(relative.isNotBlank() && !File(relative).isAbsolute) { "Unsafe manifest path" }
        val child = File(root, relative).canonicalFile
        require(child.path.startsWith(root.path + File.separator)) { "Manifest path escapes model root" }
        return child
    }

    private fun absolutizePaths(value: Any, root: File): Any {
        when (value) {
            is JSONObject -> {
                val keys = value.keys().asSequence().toList()
                for (key in keys) value.put(key, absolutizePaths(value.get(key), root))
            }
            is JSONArray -> {
                for (index in 0 until value.length()) {
                    value.put(index, absolutizePaths(value.get(index), root))
                }
            }
            is String -> if (value.startsWith("./")) {
                return safeChild(root, value.removePrefix("./")).absolutePath
            }
        }
        return value
    }

    private external fun nativeAvailable(): Boolean
    private external fun nativeCreate(configJson: String): Long
    private external fun nativeQuery(handle: Long, prompt: String): String
    private external fun nativeStop(handle: Long)
    private external fun nativeFree(handle: Long)
}
