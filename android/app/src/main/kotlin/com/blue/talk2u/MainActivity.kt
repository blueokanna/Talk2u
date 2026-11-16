package com.blue.talk2u

import android.app.ActivityManager
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.BitmapFactory
import android.os.Build
import android.os.StatFs
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipInputStream
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    companion object {
        init {
            System.loadLibrary("rust_lib_talk2u")
        }
    }

    private val live2dModelsChannelName = "talk2u/live2d_models"
    private val llmRuntimeChannelName = "talk2u/llm_runtime"
    private val mossTtsChannelName = "talk2u/moss_tts"
    private val acceleratorTelemetryChannelName = "talk2u/accelerator_telemetry"
    private val memoryChannelName = "talk2u/memory"
    private val fullDuplexAudioChannelName = "talk2u/full_duplex_audio"
    private val fullDuplexFramesChannelName = "talk2u/full_duplex_frames"
    private val mossImportRequest = 4203
    private val mossZipImportRequest = 4204
    private val sherpaZipImportRequest = 4205
    private val modelStore by lazy { ModelStore(applicationContext) }
    private val mossExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "talk2u-moss-tts").apply { priority = Thread.NORM_PRIORITY - 1 }
    }
    private val llmExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "talk2u-qwen3-qairt").apply { priority = Thread.NORM_PRIORITY - 1 }
    }
    private val asrExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "talk2u-sensevoice-qnn").apply { priority = Thread.NORM_PRIORITY - 1 }
    }
    private val genieXRuntime by lazy { GenieXRuntime(applicationContext) }
    private val senseVoiceRuntime by lazy { SenseVoiceQnnRuntime(applicationContext) }
    @Volatile private var mossCancellation = AtomicBoolean(false)
    @Volatile private var mossImportChannel: MethodChannel? = null
    @Volatile private var memoryChannel: MethodChannel? = null
    @Volatile private var activityDestroyed = false
    @Volatile private var mossInitializing = false
    @Volatile private var mossInitializationStage = "idle"
    @Volatile private var mossInitializationError: String? = null
    @Volatile private var mossEngine: NativeMossRuntime? = null
    @Volatile private var mossEngineRoot: String? = null
    private var pendingMossImportResult: MethodChannel.Result? = null
    private var pendingMossZipImportResult: MethodChannel.Result? = null
    private var pendingSherpaZipImportResult: MethodChannel.Result? = null
    private val acceleratorTelemetrySampler = AcceleratorTelemetry.Sampler()
    private val fullDuplexAudio by lazy { FullDuplexAudioCapture(applicationContext) }
    private var cameraObservation: CameraObservation? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Platform to Dart only: `onTrimMemory` sends `trim` with the trim level.
        memoryChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            memoryChannelName,
        )
        cameraObservation?.close()
        cameraObservation = CameraObservation(this, flutterEngine.dartExecutor.binaryMessenger)
        val qnnStatus = QnnRuntime.prepare(applicationContext)
        Log.i("Talk2U/QNN", "runtime=${qnnStatus.asMap()}")
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            Thread({
                Log.i("Talk2U/GPU", GpuBackendProbe.diagnostics().toString())
            }, "talk2u-gpu-probe").start()
        }
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            fullDuplexFramesChannelName,
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    fullDuplexAudio.attachSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    fullDuplexAudio.attachSink(null)
                }
            },
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fullDuplexAudioChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capabilities" -> result.success(fullDuplexAudio.capabilities())
                    "start" -> result.success(fullDuplexAudio.start())
                    "stop" -> {
                        fullDuplexAudio.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, acceleratorTelemetryChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method != "sample") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val mossTelemetry = runCatching { mossEngine?.telemetry() }.getOrNull()
                result.success(
                    acceleratorTelemetrySampler.sample(
                        qnnReady = QnnRuntime.status.ready,
                        moss = mossTelemetry,
                    ),
                )
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, live2dModelsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "importArchive", "importArchiveModels" -> {
                        val archivePath = call.argument<String>("path")
                        if (archivePath.isNullOrBlank()) {
                            result.error("invalid_archive", "No Live2D ZIP path was provided", null)
                            return@setMethodCallHandler
                        }
                        runLive2dImport(result) {
                            val models = importLive2dArchive(archivePath)
                            if (call.method == "importArchive") models.first() else models
                        }
                    }
                    "installBundledMao" -> runLive2dImport(result, ::installBundledMao)
                    else -> result.notImplemented()
                }
            }

        val llmRuntimeChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            llmRuntimeChannelName,
        )
        llmRuntimeChannel
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capabilities" -> llmExecutor.execute {
                        runCatching { llmRuntimeCapabilities() }.fold(
                            onSuccess = { value -> deliverLlmResult(result) { result.success(value) } },
                            onFailure = { error -> deliverLlmError(result, "capabilities", error) },
                        )
                    }
                    "modelStatus" -> llmExecutor.execute {
                        runCatching { genieXRuntime.modelStatus() }.fold(
                            onSuccess = { value -> deliverLlmResult(result) { result.success(value) } },
                            onFailure = { error -> deliverLlmError(result, "model_status", error) },
                        )
                    }
                    "download" -> llmExecutor.execute {
                        runCatching {
                            genieXRuntime.downloadModel { progress ->
                                deliverLlmResult(result) {
                                    llmRuntimeChannel.invokeMethod(
                                        "downloadProgress",
                                        mapOf(
                                            "downloadedBytes" to progress.downloadedBytes,
                                            "totalBytes" to progress.totalBytes,
                                        ),
                                    )
                                }
                            }
                        }.fold(
                            onSuccess = { value -> deliverLlmResult(result) { result.success(value) } },
                            onFailure = { error -> deliverLlmError(result, "download", error) },
                        )
                    }
                    "cancelDownload" -> {
                        genieXRuntime.cancelDownload()
                        result.success(null)
                    }
                    "deleteModel" -> llmExecutor.execute {
                        runCatching { genieXRuntime.deleteModel() }.fold(
                            onSuccess = { deliverLlmResult(result) { result.success(null) } },
                            onFailure = { error -> deliverLlmError(result, "delete", error) },
                        )
                    }
                    "load" -> llmExecutor.execute {
                        runCatching { genieXRuntime.load() }.fold(
                            onSuccess = { value -> deliverLlmResult(result) { result.success(value) } },
                            onFailure = { error ->
                                Log.e("Talk2U/LLM", "Unable to load Qwen3 QAIRT/NPU model", error)
                                deliverLlmError(result, "load", error)
                            },
                        )
                    }
                    "generate" -> {
                        val messages: List<Pair<String, String>> =
                            (call.argument<List<*>>("messages") ?: emptyList<Any?>())
                            .mapNotNull { value ->
                                val message = value as? Map<*, *> ?: return@mapNotNull null
                                val content = message["content"]?.toString().orEmpty()
                                if (content.isBlank()) null else
                                    message["role"]?.toString().orEmpty() to content
                            }
                        val maxTokens = call.argument<Int>("maxTokens")
                            ?.coerceIn(1, GenieXRuntime.MAX_OUTPUT_TOKENS)
                            ?: GenieXRuntime.MAX_OUTPUT_TOKENS
                        val generationId = call.argument<Int>("generationId")
                        if (messages.isEmpty()) {
                            result.error("invalid_qwen3_messages", "Qwen3 chat messages are empty", null)
                        } else if (generationId == null || generationId <= 0) {
                            result.error("invalid_qwen3_generation", "Qwen3 generationId is invalid", null)
                        } else {
                            llmExecutor.execute {
                                runCatching {
                                    genieXRuntime.ensureLoaded()
                                    genieXRuntime.generate(
                                        messages,
                                        maxTokens,
                                    ) { text ->
                                        deliverLlmResult(result) {
                                            llmRuntimeChannel.invokeMethod(
                                                "token",
                                                mapOf(
                                                    "generationId" to generationId,
                                                    "text" to text,
                                                ),
                                            )
                                        }
                                    }
                                }.fold(
                                    onSuccess = { text ->
                                        Log.i(
                                            "Talk2U/LLM",
                                            "query details=${genieXRuntime.diagnostics()}",
                                        )
                                        deliverLlmResult(result) { result.success(text) }
                                    },
                                    onFailure = { error ->
                                        deliverLlmError(result, "generate", error)
                                    },
                                )
                            }
                        }
                    }
                    "stop" -> {
                        genieXRuntime.stop()
                        result.success(null)
                    }
                    "release" -> {
                        llmExecutor.execute {
                            genieXRuntime.close()
                            deliverLlmResult(result) { result.success(null) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SenseVoiceQnnRuntime.CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "capabilities" -> result.success(
                    senseVoiceRuntime.diagnostics() + mapOf(
                        "qnn" to QnnRuntime.status.asMap(),
                    ),
                )
                "load" -> {
                    val root = secureAppModelRoot(call.argument<String>("modelRoot"))
                    if (root == null) {
                        result.error("invalid_sensevoice_path", "The SenseVoice model path is unsafe", null)
                    } else {
                        asrExecutor.execute {
                            runCatching { senseVoiceRuntime.load(root) }.fold(
                                onSuccess = { value ->
                                    deliverLlmResult(result) { result.success(value) }
                                },
                                onFailure = { error ->
                                    Log.e("Talk2U/ASR", "Unable to load SenseVoice QNN", error)
                                    deliverLlmResult(result) {
                                        result.error(
                                            "sensevoice_load_failed",
                                            error.message ?: error.javaClass.simpleName,
                                            senseVoiceRuntime.diagnostics(),
                                        )
                                    }
                                },
                            )
                        }
                    }
                }
                "recognize" -> {
                    val root = secureAppModelRoot(call.argument<String>("modelRoot"))
                    val pcm = call.argument<ByteArray>("pcm16le")
                    if (root == null) {
                        result.error("invalid_sensevoice_path", "The SenseVoice model path is unsafe", null)
                    } else if (pcm == null || pcm.isEmpty()) {
                        result.error("invalid_sensevoice_audio", "The SenseVoice PCM audio is empty", null)
                    } else {
                        asrExecutor.execute {
                            runCatching {
                                senseVoiceRuntime.load(root)
                                senseVoiceRuntime.recognize(pcm)
                            }.fold(
                                onSuccess = { value ->
                                    deliverLlmResult(result) { result.success(value) }
                                },
                                onFailure = { error ->
                                    Log.e("Talk2U/ASR", "SenseVoice QNN recognition failed", error)
                                    deliverLlmResult(result) {
                                        result.error(
                                            "sensevoice_recognition_failed",
                                            error.message ?: error.javaClass.simpleName,
                                            senseVoiceRuntime.diagnostics(),
                                        )
                                    }
                                },
                            )
                        }
                    }
                }
                "release" -> asrExecutor.execute {
                    senseVoiceRuntime.close()
                    deliverLlmResult(result) { result.success(null) }
                }
                "importZip" -> beginSherpaZipImport(result)
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mossTtsChannelName)
            .also { mossImportChannel = it }
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "availableStorageBytes" -> result.success(StatFs(filesDir.path).availableBytes)
                    "probe" -> runCatching { QnnRuntime.status.ready }
                        .fold(
                            onSuccess = result::success,
                            onFailure = {
                                result.error(
                                    "moss_runtime_unavailable",
                                    "The MOSS-TTS-Nano ONNX Runtime could not be loaded: ${it.message}",
                                    null,
                                )
                            },
                        )
                    "providers" -> runCatching {
                        check(QnnRuntime.status.ready && QnnRuntime.status.epDeviceCount > 0) {
                            "The QNN Plugin EP exposed no usable device"
                        }
                        listOf("QNN_HTP", "ORT_CPU")
                    }
                        .fold(
                            onSuccess = {
                                Log.i("Talk2U/MOSS", "availableProviders=$it")
                                result.success(it)
                            },
                            onFailure = {
                                result.error(
                                    "moss_provider_probe_failed",
                                    "The MOSS-TTS-Nano execution providers could not be read: ${it.message}",
                                    null,
                                )
                            },
                        )
                    "runtimeDetails" -> result.success(
                        mapOf(
                            "engine" to "native-onnxruntime-qnn-plugin-ep",
                            "providerPlan" to mapOf(
                                "prefill" to "QNN_HTP",
                                "decode" to "QNN_HTP",
                                "sampler" to "ORT_CPU",
                                "codec" to "ORT_CPU",
                            ),
                            "ortVersion" to BuildConfig.ORT_VERSION,
                            "qnnPluginVersion" to BuildConfig.QNN_PLUGIN_VERSION,
                            "htpArchitecture" to "v81",
                            "hardwareOnly" to true,
                        ) + mossRuntimeState(),
                    )
                    "runtimeState" -> result.success(mossRuntimeState())
                    "initialize" -> initializeMoss(result)
                    "modelInfo" -> result.success(modelStore.inspectInstalled()?.asMap())
                    "importModel" -> beginMossModelImport(result)
                    "importModelZip" -> beginMossZipImport(result)
                    "deleteModel" -> mossExecutor.execute {
                        runCatching {
                            closeMossEngine()
                            modelStore.deleteInstalled()
                        }.fold(
                            onSuccess = {
                                deliverMossResult(result) { result.success(null) }
                            },
                            onFailure = { error ->
                                deliverMossResult(result) {
                                    result.error(
                                        "moss_delete_failed",
                                        error.message ?: error.javaClass.simpleName,
                                        null,
                                    )
                                }
                            },
                        )
                    }
                    "synthesize" -> synthesizeMoss(call.arguments as? Map<*, *>, result)
                    "cancel" -> {
                        mossCancellation.set(true)
                        result.success(null)
                    }
                    "release" -> releaseMoss(result)
                    else -> result.notImplemented()
                }
            }

        flutterEngine.platformViewsController.registry.registerViewFactory(
            "talk2u/live2d",
            Live2dViewFactory(this, flutterEngine.dartExecutor.binaryMessenger),
        )
    }

    private fun llmRuntimeCapabilities(): Map<String, Any?> {
        val activityManager = getSystemService(ACTIVITY_SERVICE) as ActivityManager
        val memory = ActivityManager.MemoryInfo().also(activityManager::getMemoryInfo)
        val socModel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Build.SOC_MODEL.orEmpty()
        } else {
            Build.HARDWARE.orEmpty()
        }
        return mapOf(
            "schemaVersion" to 3,
            "device" to mapOf(
                "manufacturer" to Build.MANUFACTURER,
                "brand" to Build.BRAND,
                "model" to Build.MODEL,
                "device" to Build.DEVICE,
                "socModel" to socModel,
                "abis" to Build.SUPPORTED_ABIS.toList(),
                "totalMemoryBytes" to memory.totalMem,
            ),
            "targetProfile" to "$socModel-qairt-npu",
            "availableStorageBytes" to StatFs(filesDir.path).availableBytes,
            "modelId" to GenieXRuntime.MODEL_NAME,
            "modelFormat" to "QAIRT context binary",
            "runtime" to "GenieX",
            "runtimeDetails" to genieXRuntime.diagnostics(),
            "activeBackend" to genieXRuntime.diagnostics()["activeBackend"],
            "activeBackendVerified" to genieXRuntime.diagnostics()["activeBackendVerified"],
            "contextSize" to GenieXRuntime.CONTEXT_SIZE,
            "backends" to listOf(
                mapOf(
                    "id" to GenieXRuntime.BACKEND,
                    "priority" to 0,
                    "device" to "Qualcomm HTP/NPU",
                    "fallbackAllowed" to false,
                ),
            ),
        ) + genieXRuntime.modelStatus()
    }

    private fun secureAppModelRoot(value: String?): File? {
        if (value.isNullOrBlank()) return null
        val root = runCatching { File(value).canonicalFile }.getOrNull() ?: return null
        val dataRoot = applicationInfo.dataDir?.let(::File)?.canonicalFile ?: return null
        return root.takeIf { it.isDirectory && it.isInside(dataRoot) }
    }

    private fun deliverLlmResult(result: MethodChannel.Result, action: () -> Unit) {
        if (activityDestroyed) return
        runOnUiThread {
            if (!activityDestroyed) runCatching(action)
        }
    }

    private fun llmErrorDetails(operation: String, error: Throwable): Map<String, Any?> = mapOf(
        "operation" to operation,
        "cause" to error.javaClass.simpleName,
        "activeBackend" to genieXRuntime.diagnostics()["activeBackend"],
        "activeBackendVerified" to genieXRuntime.diagnostics()["activeBackendVerified"],
        "runtime" to "GenieX/QAIRT",
        "retryable" to true,
    )

    private fun deliverLlmError(
        result: MethodChannel.Result,
        operation: String,
        error: Throwable,
    ) {
        Log.e("Talk2U/LLM", "GenieX $operation failed", error)
        deliverLlmResult(result) {
            result.error(
                "qwen3_${operation}_failed",
                error.message ?: error.javaClass.simpleName,
                llmErrorDetails(operation, error),
            )
        }
    }

    private fun importLive2dArchive(archivePath: String): List<String> {
        val archive = File(archivePath)
        require(archive.isFile) { "The selected Live2D ZIP file was not found" }
        require(archive.length() <= 512L * 1024L * 1024L) {
            "Live2D ZIP exceeds the 512 MB import limit"
        }

        val modelsRoot = File(filesDir, "live2d_models").apply { mkdirs() }
        val importDir = File(
            modelsRoot,
            "model-${System.currentTimeMillis()}-${archive.length().toString(16)}",
        )
        require(importDir.mkdirs()) { "Cannot create the Live2D model directory" }

        try {
            extractLive2dArchive(archive, importDir)
            val modelFiles = importDir.walkTopDown()
                .filter { it.isFile && it.name.lowercase(Locale.ROOT).endsWith(".model3.json") }
                .sortedBy { it.relativeTo(importDir).path }
                .toList()
            require(modelFiles.isNotEmpty()) { "The ZIP contains no .model3.json" }
            modelFiles.forEach { validateLive2dModel(it, importDir) }
            return modelFiles.map { it.canonicalPath }
        } catch (error: Exception) {
            importDir.deleteRecursively()
            throw error
        }
    }

    private fun runLive2dImport(
        result: MethodChannel.Result,
        operation: () -> Any,
    ) {
        Thread {
            try {
                val value = operation()
                runOnUiThread { result.success(value) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "live2d_import_failed",
                        error.message ?: "Live2D model import failed",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun installBundledMao(): String {
        val modelsRoot = File(filesDir, "live2d_models").apply { mkdirs() }
        val installDir = File(modelsRoot, "bundled-mao-cubism5-v1")
        val modelFile = File(installDir, "mao_pro.model3.json")
        if (!modelFile.isFile) {
            val staging = File(modelsRoot, "bundled-mao-staging-${System.currentTimeMillis()}")
            require(staging.mkdirs()) { "Cannot create the bundled Mao model directory" }
            try {
                copyAssetTree("flutter_assets/model/Live2d/mao/runtime", staging)
                require(File(staging, "mao_pro.model3.json").isFile) {
                    "The bundled Mao model is missing from the APK; check the pubspec assets"
                }
                if (installDir.exists()) installDir.deleteRecursively()
                require(staging.renameTo(installDir)) { "Cannot finish installing the bundled Mao model" }
            } catch (error: Exception) {
                staging.deleteRecursively()
                throw error
            }
        }
        validateLive2dModel(modelFile, installDir)
        return modelFile.canonicalPath
    }

    private fun copyAssetTree(assetPath: String, destination: File) {
        val children = assets.list(assetPath).orEmpty()
        if (children.isEmpty()) {
            destination.parentFile?.mkdirs()
            assets.open(assetPath).use { source ->
                BufferedOutputStream(FileOutputStream(destination)).use { target ->
                    source.copyTo(target)
                }
            }
            return
        }
        require(destination.mkdirs() || destination.isDirectory) {
            "Cannot create the model directory: ${destination.name}"
        }
        for (child in children) {
            copyAssetTree("$assetPath/$child", File(destination, child))
        }
    }

    private fun extractLive2dArchive(archive: File, destination: File) {
        val destinationPath = destination.canonicalPath + File.separator
        var entryCount = 0
        var totalBytes = 0L
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)

        ZipInputStream(BufferedInputStream(FileInputStream(archive))).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                entryCount++
                require(entryCount <= 4096) { "The ZIP contains too many entries" }
                val entryName = entry.name.replace('\\', '/')
                require(!entryName.startsWith('/') && !entryName.split('/').contains("..")) {
                    "The ZIP contains an unsafe path: ${entry.name}"
                }
                val output = File(destination, entryName).canonicalFile
                require(output.path.startsWith(destinationPath)) {
                    "The ZIP contains an out-of-bounds path: ${entry.name}"
                }
                if (entry.isDirectory) {
                    output.mkdirs()
                } else {
                    output.parentFile?.mkdirs()
                    BufferedOutputStream(FileOutputStream(output)).use { target ->
                        while (true) {
                            val read = zip.read(buffer)
                            if (read < 0) break
                            totalBytes += read
                            require(totalBytes <= 512L * 1024L * 1024L) {
                                "The unpacked model exceeds the 512 MB limit"
                            }
                            target.write(buffer, 0, read)
                        }
                    }
                }
                zip.closeEntry()
            }
        }
        require(entryCount > 0) { "The ZIP is empty or malformed" }
    }

    private fun validateLive2dModel(modelFile: File, importRoot: File) {
        val json = JSONObject(modelFile.readText(Charsets.UTF_8))
        require(json.optInt("Version", -1) == 3) {
            "Only Cubism .model3.json Version 3 is supported"
        }
        val references = json.optJSONObject("FileReferences")
            ?: throw IllegalArgumentException("model3.json is missing FileReferences")
        val modelDirectory = modelFile.parentFile ?: importRoot
        includeUnreferencedVtuberAssets(references, modelDirectory, importRoot)
        fun normalizeReference(relativePath: String): String {
            val file = resolveModelReference(modelDirectory, importRoot, relativePath)
            return relativeModelPath(modelDirectory, file)
        }

        val moc = references.optString("Moc")
        require(moc.isNotBlank()) { "model3.json has no Moc file reference" }
        references.put("Moc", normalizeReference(moc))

        val textures = references.optJSONArray("Textures")
        require(textures != null && textures.length() > 0) { "model3.json has no texture references" }
        val textureFiles = mutableListOf<File>()
        for (index in 0 until textures.length()) {
            val normalized = normalizeReference(textures.getString(index))
            textures.put(index, normalized)
            textureFiles += File(modelDirectory, normalized).canonicalFile
        }

        for (key in listOf("Physics", "Pose", "UserData", "DisplayInfo")) {
            references.optString(key).takeIf { it.isNotBlank() }?.let { value ->
                references.put(key, normalizeReference(value))
            }
        }
        references.optJSONArray("Expressions")?.let { expressions ->
            for (index in 0 until expressions.length()) {
                expressions.optJSONObject(index)?.let { expression ->
                    expression.optString("File").takeIf { it.isNotBlank() }?.let { value ->
                        expression.put("File", normalizeReference(value))
                    }
                }
            }
        }
        references.optJSONObject("Motions")?.let { motions ->
            val groups = motions.keys()
            while (groups.hasNext()) {
                val items = motions.optJSONArray(groups.next()) ?: continue
                for (index in 0 until items.length()) {
                    items.optJSONObject(index)?.let { motion ->
                        motion.optString("File").takeIf { it.isNotBlank() }?.let { value ->
                            motion.put("File", normalizeReference(value))
                        }
                    }
                }
            }
        }

        val mocFile = File(modelDirectory, references.getString("Moc")).canonicalFile
        validateMocVersion(mocFile)

        val displayInfoFile = references.optString("DisplayInfo")
            .takeIf { it.isNotBlank() }
            ?.let { File(modelDirectory, it).canonicalFile }
        val displayInfo = displayInfoFile?.let { file ->
            JSONObject(file.readText(Charsets.UTF_8)).also { cdi ->
                require(cdi.optInt("Version", -1) == 3) {
                    "cdi3.json Version must be 3"
                }
            }
        }

        val lipSyncIds = discoverLipSyncIds(json, displayInfo)

        validateModelMemory(mocFile, textureFiles)
        writeAvatarConfig(modelDirectory, lipSyncIds, json, displayInfo)
        modelFile.writeText(json.toString(2), Charsets.UTF_8)
    }

    private fun includeUnreferencedVtuberAssets(
        references: JSONObject,
        modelDirectory: File,
        importRoot: File,
    ) {
        val expressionReferences = references.optJSONArray("Expressions") ?: JSONArray().also {
            references.put("Expressions", it)
        }
        val referencedExpressions = mutableSetOf<String>()
        for (index in 0 until expressionReferences.length()) {
            expressionReferences.optJSONObject(index)
                ?.optString("File")
                ?.takeIf { it.isNotBlank() }
                ?.let { referencedExpressions += it.replace('\\', '/').lowercase(Locale.ROOT) }
        }

        val motionReferences = references.optJSONObject("Motions") ?: JSONObject().also {
            references.put("Motions", it)
        }
        val referencedMotions = mutableSetOf<String>()
        val motionGroups = motionReferences.keys()
        while (motionGroups.hasNext()) {
            val items = motionReferences.optJSONArray(motionGroups.next()) ?: continue
            for (index in 0 until items.length()) {
                items.optJSONObject(index)
                    ?.optString("File")
                    ?.takeIf { it.isNotBlank() }
                    ?.let { referencedMotions += it.replace('\\', '/').lowercase(Locale.ROOT) }
            }
        }

        val files = importRoot.walkTopDown().filter(File::isFile).toList()
        for (file in files) {
            val relative = relativeModelPath(modelDirectory, file)
            val normalized = relative.lowercase(Locale.ROOT)
            when {
                normalized.endsWith(".exp3.json") && normalized !in referencedExpressions -> {
                    val baseName = file.name.removeSuffix(".exp3.json")
                    var name = baseName
                    var suffix = 2
                    val existingNames = (0 until expressionReferences.length()).mapNotNull { index ->
                        expressionReferences.optJSONObject(index)?.optString("Name")
                    }.toMutableSet()
                    while (name in existingNames) {
                        name = "$baseName $suffix"
                        suffix++
                    }
                    expressionReferences.put(JSONObject().put("Name", name).put("File", relative))
                    referencedExpressions += normalized
                }
                normalized.endsWith(".motion3.json") && normalized !in referencedMotions -> {
                    val baseName = file.name.removeSuffix(".motion3.json")
                    val group = if (baseName.equals("idle", ignoreCase = true)) "Idle" else baseName
                    val items = motionReferences.optJSONArray(group) ?: JSONArray().also {
                        motionReferences.put(group, it)
                    }
                    items.put(JSONObject().put("File", relative))
                    referencedMotions += normalized
                }
            }
        }

        if (expressionReferences.length() == 0) references.remove("Expressions")
        if (motionReferences.length() == 0) references.remove("Motions")
    }

    private fun resolveModelReference(
        modelDirectory: File,
        importRoot: File,
        relativePath: String,
    ): File {
        require(!relativePath.contains("://") && !File(relativePath).isAbsolute) {
            "The model references a non-local resource: $relativePath"
        }
        val rootPath = importRoot.canonicalPath + File.separator
        val direct = File(modelDirectory, relativePath).canonicalFile
        if (direct.path.startsWith(rootPath) && direct.isFile) return direct

        var current = modelDirectory.canonicalFile
        for (segment in relativePath.replace('\\', '/').split('/').filter { it.isNotEmpty() }) {
            current = when (segment) {
                "." -> current
                ".." -> current.parentFile
                    ?: throw IllegalArgumentException("The model reference escapes the model directory: $relativePath")
                else -> {
                    val matches = current.listFiles()
                        ?.filter { it.name.equals(segment, ignoreCase = true) }
                        .orEmpty()
                    require(matches.size == 1) { "The model resource is missing or case-conflicting: $relativePath" }
                    matches.single()
                }
            }
        }
        val resolved = current.canonicalFile
        require(resolved.path.startsWith(rootPath) && resolved.isFile) {
            "The model resource is missing or escapes the model directory: $relativePath"
        }
        return resolved
    }

    private fun relativeModelPath(modelDirectory: File, target: File): String {
        val from = modelDirectory.canonicalPath.split(File.separatorChar)
        val to = target.canonicalPath.split(File.separatorChar)
        var common = 0
        while (common < from.size && common < to.size && from[common] == to[common]) common++
        return (List(from.size - common) { ".." } + to.drop(common)).joinToString("/")
    }

    private fun validateMocVersion(mocFile: File) {
        val header = ByteArray(8)
        val bytesRead = FileInputStream(mocFile).use { it.read(header) }
        require(bytesRead == header.size && header.copyOfRange(0, 4).contentEquals("MOC3".toByteArray())) {
            "${mocFile.name} is not a valid moc3 file"
        }
        val mocVersion = header[4].toInt() and 0xff
        require(mocVersion in 1..5) {
            "${mocFile.name} uses moc3 version $mocVersion, which this Cubism 5 Core does not support yet"
        }
    }

    private fun discoverLipSyncIds(modelJson: JSONObject, displayInfo: JSONObject?): List<String> {
        val result = linkedSetOf<String>()
        modelJson.optJSONArray("Groups")?.let { groups ->
            for (index in 0 until groups.length()) {
                val group = groups.optJSONObject(index) ?: continue
                if (!group.optString("Name").equals("LipSync", ignoreCase = true)) continue
                val ids = group.optJSONArray("Ids") ?: continue
                for (idIndex in 0 until ids.length()) {
                    ids.optString(idIndex).takeIf { it.isNotBlank() }?.let(result::add)
                }
            }
        }
        displayInfo?.optJSONArray("Parameters")?.let { parameters ->
            for (index in 0 until parameters.length()) {
                val parameter = parameters.optJSONObject(index) ?: continue
                val id = parameter.optString("Id")
                val name = parameter.optString("Name").lowercase(Locale.ROOT)
                if (
                    id in listOf("ParamMouthOpenY", "ParamA", "ParamI", "ParamU", "ParamE", "ParamO") ||
                    name == "mouth open" ||
                    // Model metadata, not UI text: some Cubism models name the
                    // mouth parameter in Chinese, and matching it is the only way
                    // to find the lip-sync parameter for those models.
                    name == "嘴巴开合"
                ) {
                    result += id
                }
            }
        }
        return result.toList()
    }

    private fun validateModelMemory(mocFile: File, textures: List<File>) {
        var rgbaTextureBytes = 0L
        for (texture in textures.distinctBy { it.canonicalPath }) {
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(texture.path, options)
            require(options.outWidth > 0 && options.outHeight > 0) {
                "Cannot read the texture dimensions: ${texture.name}"
            }
            require(options.outWidth <= 4096 && options.outHeight <= 4096) {
                "Textures larger than 4096x4096 are rejected on Android: ${texture.name}"
            }
            rgbaTextureBytes += options.outWidth.toLong() * options.outHeight.toLong() * 4L
        }

        val estimatedBytes = (mocFile.length() * 1.5 + rgbaTextureBytes * 1.5).toLong()
        val activityManager = getSystemService(ACTIVITY_SERVICE) as ActivityManager
        val memoryInfo = ActivityManager.MemoryInfo().also(activityManager::getMemoryInfo)
        val storageAvailable = StatFs(filesDir.path).availableBytes
        require(storageAvailable >= mocFile.length() + rgbaTextureBytes / 4L) {
            "Not enough free storage to load this model safely"
        }
        val systemBudget = if (memoryInfo.totalMem > 0L && memoryInfo.availMem > 0L) {
            minOf(
                (memoryInfo.totalMem * 0.12).toLong(),
                (memoryInfo.availMem * 0.22).toLong(),
                1024L * 1024L * 1024L,
            )
        } else {
            (activityManager.largeMemoryClass.toLong() * 1024L * 1024L * 0.6).toLong()
        }
        val safeBudget = systemBudget
        require(estimatedBytes <= safeBudget) {
            val estimatedMb = estimatedBytes / (1024L * 1024L)
            val budgetMb = safeBudget / (1024L * 1024L)
            "The model needs at least $estimatedMb MB, above this device's Live2D budget of $budgetMb MB. " +
                "Reduce the moc3/texture count or use the desktop build; loading was blocked to avoid a crash"
        }
    }

    private fun writeAvatarConfig(
        modelDirectory: File,
        lipSyncIds: List<String>,
        modelJson: JSONObject,
        displayInfo: JSONObject?,
    ) {
        val configFile = File(modelDirectory, "talk2u.avatar.json")
        val config = if (configFile.isFile) {
            JSONObject(configFile.readText(Charsets.UTF_8))
        } else {
            JSONObject()
        }
        config.put("version", 1)
        val lipSync = config.optJSONObject("lipSync") ?: JSONObject().also {
            config.put("lipSync", it)
        }
        val parameterIds = linkedSetOf<String>()
        displayInfo?.optJSONArray("Parameters")?.let { parameters ->
            for (index in 0 until parameters.length()) {
                parameters.optJSONObject(index)?.optString("Id")
                    ?.takeIf { it.isNotBlank() }
                    ?.let(parameterIds::add)
            }
        }
        val vowelIds = listOf("ParamA", "ParamI", "ParamU", "ParamE", "ParamO")
            .filter(parameterIds::contains)
        val usesVisemes = vowelIds.size >= 3
        if (usesVisemes) {
            lipSync.put("mode", "viseme")
            lipSync.put("parameterIds", JSONArray(vowelIds))
            lipSync.put("visemeParameterIds", JSONArray(vowelIds))
        } else if (lipSync.optJSONArray("parameterIds")?.length() in listOf(null, 0)) {
            lipSync.put("mode", "open")
            lipSync.put("parameterIds", JSONArray(lipSyncIds))
        }
        if (!lipSync.has("gain")) lipSync.put("gain", 1.8)
        if (!lipSync.has("smoothing")) lipSync.put("smoothing", 0.45)
        if (!lipSync.has("attack")) lipSync.put("attack", 0.58)
        if (!lipSync.has("release")) lipSync.put("release", 0.28)
        if (!lipSync.has("staleAfterMs")) lipSync.put("staleAfterMs", 240)
        val naturalBehavior = config.optJSONObject("naturalBehavior") ?: JSONObject().also {
            config.put("naturalBehavior", it)
        }
        if (!naturalBehavior.has("expressionDurationMs")) {
            naturalBehavior.put("expressionDurationMs", 4200)
        }
        val speechBody = naturalBehavior.optJSONObject("speechBody") ?: JSONObject().also {
            naturalBehavior.put("speechBody", it)
        }
        if (!speechBody.has("enabled")) speechBody.put("enabled", true)
        if (!speechBody.has("gain")) speechBody.put("gain", 1.15)
        if (!speechBody.has("smoothing")) speechBody.put("smoothing", 0.12)
        val gaze = naturalBehavior.optJSONObject("gaze") ?: JSONObject().also {
            naturalBehavior.put("gaze", it)
        }
        if (!gaze.has("enabled")) gaze.put("enabled", true)
        if (!gaze.has("intervalMinMs")) gaze.put("intervalMinMs", 2600)
        if (!gaze.has("intervalMaxMs")) gaze.put("intervalMaxMs", 5600)
        if (!gaze.has("rangeX")) gaze.put("rangeX", 0.22)
        if (!gaze.has("rangeY")) gaze.put("rangeY", 0.12)
        if (!naturalBehavior.has("microExpressions")) {
            naturalBehavior.put("microExpressions", JSONArray())
        }
        val aliases = config.optJSONObject("parameterAliases") ?: JSONObject().also {
            config.put("parameterAliases", it)
        }
        val aliasCandidates = linkedMapOf(
            "angleX" to listOf("ParamAngleX", "AngleX"),
            "angleY" to listOf("ParamAngleY", "AngleY"),
            "angleZ" to listOf("ParamAngleZ", "AngleZ"),
            "bodyX" to listOf("ParamBodyAngleX", "ParamBodyAngleX3", "Param92"),
            "bodyY" to listOf("ParamBodyAngleY", "ParamBodyAngleY2", "Param93"),
            "bodyZ" to listOf("ParamBodyAngleZ", "ParamBodyAngleZ2", "Param94"),
            "shoulder" to listOf("ParamShoulderY", "ParamBodyAngleZ3"),
            "armL" to listOf("ParamArmLA01", "ParamArmLA", "Param104"),
            "armR" to listOf("ParamArmRA01", "ParamArmRA", "Param431"),
            "forearmL" to listOf("ParamArmLA02", "ParamArmLB01", "Param105"),
            "forearmR" to listOf("ParamArmRA02", "ParamArmRB01", "Param432"),
            "handL" to listOf("ParamHandL", "Param106"),
            "handR" to listOf("ParamHandR", "Param433"),
        )
        for ((name, candidates) in aliasCandidates) {
            val matched = candidates.filter(parameterIds::contains)
            if (matched.isNotEmpty()) aliases.put(name, JSONArray(matched))
        }
        val references = modelJson.optJSONObject("FileReferences") ?: JSONObject()
        val capabilities = JSONObject()
        val expressions = JSONArray()
        references.optJSONArray("Expressions")?.let { values ->
            for (index in 0 until values.length()) {
                values.optJSONObject(index)?.optString("Name")
                    ?.takeIf { it.isNotBlank() }
                    ?.let(expressions::put)
            }
        }
        capabilities.put("expressions", expressions)
        val motions = JSONObject()
        references.optJSONObject("Motions")?.let { groups ->
            val names = groups.keys()
            while (names.hasNext()) {
                val name = names.next()
                motions.put(name, groups.optJSONArray(name)?.length() ?: 0)
            }
        }
        capabilities.put("motions", motions)
        config.put("modelCapabilities", capabilities)
        if (!config.has("cues")) config.put("cues", JSONObject())
        configFile.writeText(config.toString(2), Charsets.UTF_8)
    }

    private fun beginMossModelImport(result: MethodChannel.Result) {
        if (pendingMossImportResult != null) {
            result.error("moss_import_busy", "A MOSS model import is already running", null)
            return
        }
        pendingMossImportResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
        }
        runCatching { startActivityForResult(intent, mossImportRequest) }
            .onFailure { error ->
                pendingMossImportResult = null
                result.error(
                    "moss_import_picker_failed",
                    error.message ?: "Cannot open the MOSS model directory picker",
                    null,
                )
            }
    }

    private fun beginMossZipImport(result: MethodChannel.Result) {
        if (pendingMossZipImportResult != null) {
            result.error("moss_import_busy", "A MOSS model import is already running", null)
            return
        }
        pendingMossZipImportResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/zip"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/zip", "application/octet-stream"))
        }
        runCatching { startActivityForResult(intent, mossZipImportRequest) }
            .onFailure { error ->
                pendingMossZipImportResult = null
                result.error(
                    "moss_import_picker_failed",
                    error.message ?: "Cannot open the ZIP file picker",
                    null,
                )
            }
    }

    private fun beginSherpaZipImport(result: MethodChannel.Result) {
        if (pendingSherpaZipImportResult != null) {
            result.error("sherpa_import_busy", "A SenseVoice model import is already running", null)
            return
        }
        pendingSherpaZipImportResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(
                "application/zip",
                "application/x-tar",
                "application/octet-stream",
                "application/x-bzip2",
            ))
        }
        runCatching { startActivityForResult(intent, sherpaZipImportRequest) }
            .onFailure { error ->
                pendingSherpaZipImportResult = null
                result.error(
                    "sherpa_import_picker_failed",
                    error.message ?: "Cannot open the file picker",
                    null,
                )
            }
    }

    @Deprecated("Kept for Android document-tree result delivery")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            mossImportRequest -> handleMossTreeResult(resultCode, data)
            mossZipImportRequest -> handleMossZipResult(resultCode, data)
            sherpaZipImportRequest -> handleSherpaZipResult(resultCode, data)
        }
    }

    private fun handleMossTreeResult(resultCode: Int, data: Intent?) {
        val pending = pendingMossImportResult ?: return
        pendingMossImportResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            pending.error("moss_import_cancelled", "No MOSS QNN deployment directory was selected", null)
            return
        }
        runCatching {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        }
        mossExecutor.execute {
            runCatching {
                closeMossEngine()
                notifyMossImportStarted()
                val info = modelStore.importFromTree(uri) { progress ->
                    if (progress.copiedBytes == progress.totalBytes) {
                        Log.i("Talk2U/MOSS", "imported ${progress.fileName}")
                    }
                }
                mossEngine(info.root)
                info
            }.fold(
                onSuccess = { info ->
                    deliverMossResult(pending) {
                        pending.success(info.asMap() + mossRuntimeState())
                    }
                },
                onFailure = { error ->
                    Log.e("Talk2U/MOSS", "MOSS deployment import failed", error)
                    deliverMossResult(pending) {
                        reportMossImportFailure(pending, error)
                    }
                },
            )
        }
    }

    private fun handleMossZipResult(resultCode: Int, data: Intent?) {
        val pending = pendingMossZipImportResult ?: return
        pendingMossZipImportResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            pending.error("moss_import_cancelled", "No MOSS QNN deployment ZIP was selected", null)
            return
        }
        mossExecutor.execute {
            runCatching {
                closeMossEngine()
                Log.i("Talk2U/MOSS", "Importing MOSS from ZIP: $uri")
                notifyMossImportStarted()
                val info = modelStore.importFromZip(uri) { progress ->
                    if (progress.copiedBytes == progress.totalBytes) {
                        Log.i("Talk2U/MOSS", "imported ${progress.fileName}")
                    }
                }
                mossEngine(info.root)
                info
            }.fold(
                onSuccess = { info ->
                    deliverMossResult(pending) {
                        pending.success(info.asMap() + mossRuntimeState())
                    }
                },
                onFailure = { error ->
                    Log.e("Talk2U/MOSS", "MOSS ZIP import failed", error)
                    deliverMossResult(pending) {
                        reportMossImportFailure(pending, error)
                    }
                },
            )
        }
    }

    private fun handleSherpaZipResult(resultCode: Int, data: Intent?) {
        val pending = pendingSherpaZipImportResult ?: return
        pendingSherpaZipImportResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            pending.error("sherpa_import_cancelled", "No SenseVoice model ZIP was selected", null)
            return
        }
        asrExecutor.execute {
            runCatching {
                senseVoiceRuntime.importFromZip(uri, contentResolver) { msg ->
                    Log.i("Talk2U/SenseVoice", msg)
                }
            }.fold(
                onSuccess = {
                    deliverAsrResult(pending) { pending.success(true) }
                },
                onFailure = { error ->
                    Log.e("Talk2U/SenseVoice", "ZIP import failed", error)
                    deliverAsrResult(pending) {
                        pending.error(
                            "sherpa_import_failed",
                            error.message ?: error.javaClass.simpleName,
                            null,
                        )
                    }
                },
            )
        }
    }

    private fun ModelStore.ModelInfo.asMap(): Map<String, Any> = mapOf(
        "root" to root.path,
        "bytes" to totalBytes,
        "target" to target,
        "qnnSdkVersion" to qnnSdkVersion,
        "ortVersion" to ortVersion,
        "voices" to voices.map { mapOf("id" to it.id, "label" to it.label) },
    )

    private fun mossRuntimeState(): Map<String, Any?> = mapOf(
        "initialized" to (mossEngine != null),
        "initializing" to mossInitializing,
        "stage" to mossInitializationStage,
        "error" to mossInitializationError,
        "provider" to "QNN_HTP(prefill,decode)+ORT_CPU(sampler,codec)",
    )

    private fun initializeMoss(result: MethodChannel.Result) {
        val info = modelStore.inspectInstalled()
        if (info == null) {
            result.error("moss_model_missing", "Import a MOSS QNN HTP v81 deployment package first", null)
            return
        }
        mossExecutor.execute {
            runCatching {
                mossEngine(info.root)
                mossRuntimeState()
            }.fold(
                onSuccess = { state ->
                    deliverMossResult(result) { result.success(state) }
                },
                onFailure = { error ->
                    Log.e("Talk2U/MOSS", "Automatic MOSS initialization failed", error)
                    deliverMossResult(result) {
                        result.error(
                            "moss_initialization_failed",
                            error.message ?: error.javaClass.simpleName,
                            mossRuntimeState(),
                        )
                    }
                },
            )
        }
    }

    private fun synthesizeMoss(arguments: Map<*, *>?, result: MethodChannel.Result) {
        val outputValue = arguments?.get("outputPath") as? String
        val text = (arguments?.get("text") as? String).orEmpty().trim()
        if (outputValue.isNullOrBlank() || text.isEmpty()) {
            result.error("invalid_moss_request", "The MOSS-TTS-Nano inference parameters are incomplete", null)
            return
        }
        val modelInfo = modelStore.inspectInstalled()
        if (modelInfo == null) {
            result.error("moss_model_missing", "Import a MOSS QNN HTP v81 deployment package first", null)
            return
        }
        val modelRoot = modelInfo.root.canonicalFile
        val outputFile = runCatching { File(outputValue).canonicalFile }.getOrNull()
        val cacheRoot = cacheDir.canonicalFile
        if (outputFile == null || !outputFile.isInside(cacheRoot)) {
            result.error("invalid_moss_output_path", "The MOSS-TTS-Nano audio output path is unsafe", null)
            return
        }
        val voices = modelInfo.voices.mapTo(HashSet(), ModelStore.Voice::id)
        val voice = (arguments["voice"] as? String).orEmpty().let {
            if (it in voices) it else modelInfo.voices.first().id
        }
        val maxFrames = (arguments["maxFrames"] as? Number)?.toInt()?.coerceIn(1, 375) ?: 375
        val seed = (arguments["seed"] as? Number)?.toLong() ?: System.nanoTime()
        mossCancellation.set(true)
        val cancellation = AtomicBoolean(false)
        mossCancellation = cancellation
        mossExecutor.execute {
            try {
                if (cancellation.get()) {
                    deliverMossResult(result) {
                        result.error("moss_cancelled", "MOSS-TTS-Nano inference was cancelled", null)
                    }
                    return@execute
                }
                val engine = mossEngine(modelRoot)
                val synthesis = engine.synthesize(
                    text = text,
                    outputFile = outputFile,
                    voice = voice,
                    maxFrames = maxFrames,
                    seed = seed,
                    cancellation = cancellation,
                )
                if (cancellation.get()) {
                    outputFile.delete()
                    deliverMossResult(result) {
                        result.error("moss_cancelled", "MOSS-TTS-Nano inference was cancelled", null)
                    }
                    return@execute
                }
                deliverMossResult(result) {
                    Log.i(
                        "Talk2U/MOSS",
                        "synthesis provider=${synthesis.provider} elapsedMs=${synthesis.elapsedMs} " +
                            "durationMs=${synthesis.durationMs} frames=${synthesis.generatedFrames}",
                    )
                    result.success(
                        mapOf(
                            "path" to synthesis.outputFile.path,
                            "sampleRate" to synthesis.sampleRate,
                            "durationMs" to synthesis.durationMs,
                            "elapsedMs" to synthesis.elapsedMs,
                            "prefillMs" to synthesis.prefillMs,
                            "decodeMs" to synthesis.decodeMs,
                            "codecMs" to synthesis.codecMs,
                            "htpBusyMs" to synthesis.htpBusyMs,
                            "generatedFrames" to synthesis.generatedFrames,
                            "provider" to synthesis.provider,
                        ),
                    )
                }
            } catch (error: Throwable) {
                outputFile.delete()
                if (cancellation.get()) {
                    deliverMossResult(result) {
                        result.error("moss_cancelled", "MOSS-TTS-Nano inference was cancelled", null)
                    }
                } else {
                    val message = error.message ?: error.javaClass.simpleName
                    Log.e("Talk2U/MOSS", "MOSS-TTS-Nano synthesis failed", error)
                    deliverMossResult(result) {
                        result.error("moss_synthesis_failed", "MOSS-TTS-Nano inference failed: $message", null)
                    }
                }
            }
        }
    }

    private fun releaseMoss(result: MethodChannel.Result) {
        mossCancellation.set(true)
        mossExecutor.execute {
            closeMossEngine()
            deliverMossResult(result) { result.success(null) }
        }
    }

    private fun mossEngine(modelRoot: File): NativeMossRuntime {
        val path = modelRoot.canonicalPath
        val current = mossEngine
        if (current != null && mossEngineRoot == path) return current
        closeMossEngine()
        mossInitializing = true
        mossInitializationStage = "plugin"
        mossInitializationError = null
        return try {
            NativeMossRuntime.create(applicationContext, modelRoot) { stage ->
                mossInitializationStage = stage
                Log.i("Talk2U/MOSS", "initializing stage=$stage")
            }.also {
                mossEngine = it
                mossEngineRoot = path
                mossInitializationStage = "ready"
            }
        } catch (error: Throwable) {
            mossInitializationStage = "failed"
            mossInitializationError = error.message ?: error.javaClass.simpleName
            throw error
        } finally {
            mossInitializing = false
        }
    }

    private fun closeMossEngine() {
        mossEngine?.close()
        mossEngine = null
        mossEngineRoot = null
        if (!mossInitializing) mossInitializationStage = "idle"
    }

    private fun deliverMossResult(result: MethodChannel.Result, action: () -> Unit) {
        if (activityDestroyed) return
        runOnUiThread {
            if (!activityDestroyed) runCatching(action)
        }
    }

    /**
     * Reports a MOSS import failure.
     *
     * An incomplete package is the most common cause, so it gets a dedicated code
     * and a payload listing the missing files; everything else keeps the generic
     * `moss_import_failed` code. The UI localizes both.
     */
    private fun reportMossImportFailure(result: MethodChannel.Result, error: Throwable) {
        if (error is MossPackageIncomplete) {
            result.error("moss_package_incomplete", error.missing.joinToString(", "), null)
        } else {
            result.error(
                "moss_import_failed",
                error.message ?: error.javaClass.simpleName,
                null,
            )
        }
    }

    /**
     * Tells Dart that the picker returned and the copy/verify phase started.
     *
     * The import call blocks until the whole package is installed, so without this
     * callback the settings card would keep showing the "choose a file" stage.
     */
    private fun notifyMossImportStarted() {
        runOnUiThread { mossImportChannel?.invokeMethod("importStarted", null) }
    }

    private fun deliverAsrResult(result: MethodChannel.Result, action: () -> Unit) {
        if (activityDestroyed) return
        runOnUiThread {
            if (!activityDestroyed) runCatching(action)
        }
    }

    private fun File.isInside(root: File): Boolean {
        return path == root.path || path.startsWith(root.path + File.separator)
    }

    override fun onResume() {
        super.onResume()
        cameraObservation?.onResume()
    }

    override fun onPause() {
        cameraObservation?.onPause()
        super.onPause()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (cameraObservation?.onRequestPermissionsResult(requestCode, permissions, grantResults) == true) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        cameraObservation?.close()
        cameraObservation = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level < ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) return
        // Per-utterance work is the first thing to drop: a cancelled synthesis
        // costs nothing, while the installed package stays untouched.
        mossCancellation.set(true)
        runOnUiThread { memoryChannel?.invokeMethod("trim", level) }
        if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL) {
            // Under critical pressure the QNN/ORT sessions are released as well;
            // the next utterance re-creates them from the on-disk context cache.
            mossExecutor.execute(::closeMossEngine)
        }
    }

    override fun onDestroy() {
        activityDestroyed = true
        cameraObservation?.close()
        cameraObservation = null
        runCatching { fullDuplexAudio.close() }
        mossCancellation.set(true)
        mossExecutor.execute(::closeMossEngine)
        mossExecutor.shutdown()
        llmExecutor.execute { genieXRuntime.close() }
        llmExecutor.shutdown()
        asrExecutor.execute { senseVoiceRuntime.close() }
        asrExecutor.shutdown()
        pendingMossImportResult?.error("activity_destroyed", "The MOSS model import ended because the page was closed", null)
        pendingMossImportResult = null
        super.onDestroy()
    }
}
