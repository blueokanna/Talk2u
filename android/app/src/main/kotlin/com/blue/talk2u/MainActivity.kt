package com.blue.talk2u

import android.Manifest
import android.app.ActivityManager
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.media.AudioFormat
import android.os.Build
import android.os.Bundle
import android.os.StatFs
import android.os.SystemClock
import android.provider.Settings
import android.speech.ModelDownloadListener
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
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
import java.util.zip.ZipInputStream
import kotlin.math.sqrt
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity(), TextToSpeech.OnInitListener {
    private val speechChannelName = "talk2u/speech"
    private val speechEventsName = "talk2u/speech_events"
    private val live2dModelsChannelName = "talk2u/live2d_models"
    private val llmRuntimeChannelName = "talk2u/llm_runtime"
    private val recordAudioRequest = 4102

    private var textToSpeech: TextToSpeech? = null
    private var ttsReady = false
    private var selectedTtsVoiceName = ""
    private var selectedTtsLocale = ""
    private var speechRecognizer: SpeechRecognizer? = null
    private var modelDownloadRecognizer: SpeechRecognizer? = null
    private var eventSink: EventChannel.EventSink? = null
    private var pendingRecognitionResult: MethodChannel.Result? = null
    @Volatile private var ttsAudioEncoding = AudioFormat.ENCODING_PCM_16BIT
    @Volatile private var lastAmplitudeEmitAt = 0L
    private var ttsInitialized = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            Thread({
                Log.i("Talk2U/GPU", GpuBackendProbe.diagnostics().toString())
            }, "talk2u-gpu-probe").start()
        }
        textToSpeech = TextToSpeech(this, this)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, speechEventsName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, speechChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capabilities" -> result.success(capabilities())
                    "refreshCapabilities" -> {
                        refreshSpeechCapabilities()
                        result.success(capabilities())
                    }
                    "speak" -> speak(call.argument<String>("text").orEmpty(), result)
                    "stopSpeaking" -> {
                        textToSpeech?.stop()
                        emit(mapOf("type" to "amplitude", "value" to 0.0))
                        emit(mapOf("type" to "speechDone"))
                        result.success(null)
                    }
                    "startListening" -> startListening(result)
                    "stopListening" -> {
                        speechRecognizer?.stopListening()
                        result.success(null)
                    }
                    "installOfflineTtsData" -> launchSpeechSettings(
                        TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA,
                        result,
                    )
                    "openVoiceInputSettings" -> launchSpeechSettings(
                        Settings.ACTION_VOICE_INPUT_SETTINGS,
                        result,
                    )
                    "downloadOfflineSttModel" -> requestOfflineSttModel(result)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, live2dModelsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "importArchive" -> {
                        val archivePath = call.argument<String>("path")
                        if (archivePath.isNullOrBlank()) {
                            result.error("invalid_archive", "未收到 Live2D ZIP 文件路径", null)
                            return@setMethodCallHandler
                        }
                        runLive2dImport(result) { importLive2dArchive(archivePath) }
                    }
                    "installBundledMao" -> runLive2dImport(result, ::installBundledMao)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, llmRuntimeChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capabilities" -> result.success(llmRuntimeCapabilities())
                    else -> result.notImplemented()
                }
            }

        flutterEngine.platformViewsController.registry.registerViewFactory(
            "talk2u/live2d",
            Live2dViewFactory(this, flutterEngine.dartExecutor.binaryMessenger),
        )
    }

    override fun onInit(status: Int) {
        ttsInitialized = true
        ttsReady = status == TextToSpeech.SUCCESS && selectOfflineVoice()
        if (ttsReady) {
            textToSpeech?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {
                    lastAmplitudeEmitAt = 0L
                    emit(mapOf("type" to "speechStart"))
                }

                override fun onDone(utteranceId: String?) {
                    emit(mapOf("type" to "amplitude", "value" to 0.0))
                    emit(mapOf("type" to "speechDone"))
                }

                override fun onStop(utteranceId: String?, interrupted: Boolean) {
                    emit(mapOf("type" to "amplitude", "value" to 0.0))
                    emit(mapOf("type" to "speechDone"))
                }

                @Suppress("DEPRECATION")
                override fun onError(utteranceId: String?) {
                    emit(mapOf("type" to "error", "message" to "离线 TTS 合成失败"))
                }

                override fun onError(utteranceId: String?, errorCode: Int) {
                    emit(mapOf("type" to "error", "message" to "离线 TTS 错误: $errorCode"))
                }

                override fun onBeginSynthesis(
                    utteranceId: String?,
                    sampleRateInHz: Int,
                    audioFormat: Int,
                    channelCount: Int,
                ) {
                    ttsAudioEncoding = audioFormat
                }

                override fun onRangeStart(
                    utteranceId: String?,
                    start: Int,
                    end: Int,
                    frame: Int,
                ) {
                    emit(
                        mapOf(
                            "type" to "speechRange",
                            "start" to start,
                            "end" to end,
                            "frame" to frame,
                        ),
                    )
                }

                override fun onAudioAvailable(utteranceId: String?, audio: ByteArray?) {
                    if (audio == null || audio.isEmpty()) return
                    val normalized = calculatePcmAmplitude(audio, ttsAudioEncoding)
                    emitAmplitude(normalized)
                }
            })
        }
        emit(mapOf("type" to "capabilities", "value" to capabilities()))
    }

    private fun selectOfflineVoice(): Boolean {
        val engine = textToSpeech ?: return false
        val voices = engine.voices ?: return false
        val preferred = voices.firstOrNull {
            !it.isNetworkConnectionRequired && it.locale.language == Locale.CHINESE.language
        } ?: voices.firstOrNull { !it.isNetworkConnectionRequired }
        if (preferred != null) {
            engine.voice = preferred
            selectedTtsVoiceName = preferred.name
            selectedTtsLocale = preferred.locale.toLanguageTag()
        }
        return preferred != null
    }

    private fun capabilities(): Map<String, Any> {
        val onDeviceStt = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(this)
        return mapOf(
            "offlineTts" to ttsReady,
            "offlineStt" to onDeviceStt,
            "sttModelDownload" to (
                onDeviceStt && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
            ),
            "audioAmplitude" to (ttsReady && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N),
            "ttsVoice" to selectedTtsVoiceName,
            "ttsLocale" to selectedTtsLocale,
            "sttLocale" to if (onDeviceStt) "zh-CN" else "",
        )
    }

    private fun llmRuntimeCapabilities(): Map<String, Any> {
        val activityManager = getSystemService(ACTIVITY_SERVICE) as ActivityManager
        val memory = ActivityManager.MemoryInfo().also(activityManager::getMemoryInfo)
        val socModel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Build.SOC_MODEL.orEmpty()
        } else {
            Build.HARDWARE.orEmpty()
        }
        val identity = listOf(
            Build.MODEL,
            Build.DEVICE,
            Build.PRODUCT,
            socModel,
        ).joinToString(" ").uppercase(Locale.ROOT)
        val onePlusProfile = when {
            "PJD110" in identity || "ONEPLUS 12" in identity -> "oneplus-12"
            "PJZ110" in identity || "ONEPLUS 13" in identity && "13T" !in identity -> "oneplus-13"
            "PKX110" in identity || "ONEPLUS 13T" in identity -> "oneplus-13t"
            "ONEPLUS 15T" in identity -> "oneplus-15t"
            "PLK110" in identity || "ONEPLUS 15" in identity -> "oneplus-15"
            else -> "generic-arm64"
        }
        val preferredVendorBackend = when {
            socModel.startsWith("SM", ignoreCase = true) ||
                "QCOM" in identity || "QUALCOMM" in identity -> "qnn-htp"
            socModel.startsWith("MT", ignoreCase = true) ||
                "MEDIATEK" in identity -> "neuropilot"
            "KIRIN" in identity || "HUAWEI" in identity -> "hiai"
            else -> "cpu-neon"
        }
        val nativeCompute = GpuBackendProbe.diagnostics().optJSONObject("llmCompute")

        fun candidate(id: String, nativeKey: String, modelFormat: String): Map<String, Any> {
            val probe = nativeCompute?.optJSONObject(nativeKey)
            val runtimePresent = probe?.optBoolean("runtimePresent", false) == true
            val adapterLinked = probe?.optBoolean("executionAdapterLinked", false) == true
            return mapOf(
                "id" to id,
                "runtimePresent" to runtimePresent,
                "executionAdapterLinked" to adapterLinked,
                "executable" to (runtimePresent && adapterLinked),
                "modelFormat" to modelFormat,
                "library" to probe?.optString("library").orEmpty(),
                "reason" to if (runtimePresent && adapterLinked) {
                    "ready"
                } else if (!runtimePresent) {
                    "vendor runtime is not loadable in the app process"
                } else {
                    "vendor SDK adapter and converted model are not linked"
                },
            )
        }

        return mapOf(
            "schemaVersion" to 1,
            "device" to mapOf(
                "manufacturer" to Build.MANUFACTURER,
                "brand" to Build.BRAND,
                "model" to Build.MODEL,
                "device" to Build.DEVICE,
                "socModel" to socModel,
                "abis" to Build.SUPPORTED_ABIS.toList(),
                "totalMemoryBytes" to memory.totalMem,
            ),
            "targetProfile" to onePlusProfile,
            "preferredVendorBackend" to preferredVendorBackend,
            "activeBackend" to "cpu-neon",
            "activeBackendVerified" to true,
            "contextSize" to 8192,
            "backends" to listOf(
                mapOf(
                    "id" to "cpu-neon",
                    "runtimePresent" to true,
                    "executionAdapterLinked" to true,
                    "executable" to true,
                    "modelFormat" to "gguf",
                    "reason" to "llama.cpp ARM64 CPU backend",
                ),
                candidate("qnn-htp", "qnn", "QNN context binary"),
                candidate("hiai", "hiAi", "HiAI offline model"),
                candidate("neuropilot", "neuroPilot", "MediaTek NeuroPilot model"),
                candidate("vulkan", "vulkan", "gguf"),
            ),
        )
    }

    private fun calculatePcmAmplitude(audio: ByteArray, encoding: Int): Double {
        var sumSquares = 0.0
        var sampleCount = 0
        when (encoding) {
            AudioFormat.ENCODING_PCM_8BIT -> {
                for (byte in audio) {
                    val sample = ((byte.toInt() and 0xff) - 128) / 128.0
                    sumSquares += sample * sample
                    sampleCount++
                }
            }
            AudioFormat.ENCODING_PCM_FLOAT -> {
                var index = 0
                while (index + 3 < audio.size) {
                    val bits = (audio[index].toInt() and 0xff) or
                        ((audio[index + 1].toInt() and 0xff) shl 8) or
                        ((audio[index + 2].toInt() and 0xff) shl 16) or
                        (audio[index + 3].toInt() shl 24)
                    val sample = Float.fromBits(bits).toDouble().coerceIn(-1.0, 1.0)
                    sumSquares += sample * sample
                    sampleCount++
                    index += 4
                }
            }
            else -> {
                var index = 0
                while (index + 1 < audio.size) {
                    val value = (audio[index].toInt() and 0xff) or
                        (audio[index + 1].toInt() shl 8)
                    val sample = value.toShort().toInt() / 32768.0
                    sumSquares += sample * sample
                    sampleCount++
                    index += 2
                }
            }
        }
        if (sampleCount == 0) return 0.0
        val rms = sqrt(sumSquares / sampleCount)
        return ((rms - 0.015).coerceAtLeast(0.0) * 4.5).coerceAtMost(1.0)
    }

    private fun emitAmplitude(value: Double) {
        val now = SystemClock.uptimeMillis()
        if (now - lastAmplitudeEmitAt < 32L) return
        lastAmplitudeEmitAt = now
        emit(mapOf("type" to "amplitude", "value" to value))
    }

    private fun importLive2dArchive(archivePath: String): String {
        val archive = File(archivePath)
        require(archive.isFile) { "找不到选择的 Live2D ZIP 文件" }
        require(archive.length() <= 512L * 1024L * 1024L) {
            "Live2D ZIP 超过 512 MB 导入限制"
        }

        val modelsRoot = File(filesDir, "live2d_models").apply { mkdirs() }
        val importDir = File(
            modelsRoot,
            "model-${System.currentTimeMillis()}-${archive.length().toString(16)}",
        )
        require(importDir.mkdirs()) { "无法创建 Live2D 模型目录" }

        try {
            extractLive2dArchive(archive, importDir)
            val modelFiles = importDir.walkTopDown()
                .filter { it.isFile && it.name.lowercase(Locale.ROOT).endsWith(".model3.json") }
                .toList()
            require(modelFiles.size == 1) {
                if (modelFiles.isEmpty()) {
                    "ZIP 中没有 .model3.json"
                } else {
                    "ZIP 中包含多个 .model3.json，请只打包一个模型"
                }
            }
            validateLive2dModel(modelFiles.single(), importDir)
            return modelFiles.single().canonicalPath
        } catch (error: Exception) {
            importDir.deleteRecursively()
            throw error
        }
    }

    private fun runLive2dImport(
        result: MethodChannel.Result,
        operation: () -> String,
    ) {
        Thread {
            try {
                val modelPath = operation()
                runOnUiThread { result.success(modelPath) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "live2d_import_failed",
                        error.message ?: "Live2D 模型导入失败",
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
            require(staging.mkdirs()) { "无法创建内置 Mao 模型目录" }
            try {
                copyAssetTree("flutter_assets/model/mao/runtime", staging)
                require(File(staging, "mao_pro.model3.json").isFile) {
                    "APK 中缺少内置 Mao 模型；请检查 pubspec assets"
                }
                if (installDir.exists()) installDir.deleteRecursively()
                require(staging.renameTo(installDir)) { "无法完成内置 Mao 模型安装" }
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
            "无法创建模型目录: ${destination.name}"
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
                require(entryCount <= 4096) { "ZIP 文件条目过多" }
                val entryName = entry.name.replace('\\', '/')
                require(!entryName.startsWith('/') && !entryName.split('/').contains("..")) {
                    "ZIP 包含不安全路径: ${entry.name}"
                }
                val output = File(destination, entryName).canonicalFile
                require(output.path.startsWith(destinationPath)) {
                    "ZIP 包含越界路径: ${entry.name}"
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
                                "解压后模型超过 512 MB 限制"
                            }
                            target.write(buffer, 0, read)
                        }
                    }
                }
                zip.closeEntry()
            }
        }
        require(entryCount > 0) { "ZIP 文件为空或格式无效" }
    }

    private fun validateLive2dModel(modelFile: File, importRoot: File) {
        val json = JSONObject(modelFile.readText(Charsets.UTF_8))
        require(json.optInt("Version", -1) == 3) {
            "只支持 Cubism .model3.json Version 3"
        }
        val references = json.optJSONObject("FileReferences")
            ?: throw IllegalArgumentException("model3.json 缺少 FileReferences")
        val modelDirectory = modelFile.parentFile ?: importRoot
        includeUnreferencedVtuberAssets(references, modelDirectory, importRoot)
        fun normalizeReference(relativePath: String): String {
            val file = resolveModelReference(modelDirectory, importRoot, relativePath)
            return relativeModelPath(modelDirectory, file)
        }

        val moc = references.optString("Moc")
        require(moc.isNotBlank()) { "model3.json 缺少 Moc 文件引用" }
        references.put("Moc", normalizeReference(moc))

        val textures = references.optJSONArray("Textures")
        require(textures != null && textures.length() > 0) { "model3.json 没有纹理引用" }
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
                    "cdi3.json 的 Version 必须为 3"
                }
            }
        }

        val lipSyncIds = discoverLipSyncIds(json, displayInfo)

        validateModelMemory(mocFile, textureFiles)
        writeAvatarConfig(modelDirectory, lipSyncIds)
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
            "模型引用了非本地资源: $relativePath"
        }
        val rootPath = importRoot.canonicalPath + File.separator
        val direct = File(modelDirectory, relativePath).canonicalFile
        if (direct.path.startsWith(rootPath) && direct.isFile) return direct

        var current = modelDirectory.canonicalFile
        for (segment in relativePath.replace('\\', '/').split('/').filter { it.isNotEmpty() }) {
            current = when (segment) {
                "." -> current
                ".." -> current.parentFile
                    ?: throw IllegalArgumentException("模型引用路径越界: $relativePath")
                else -> {
                    val matches = current.listFiles()
                        ?.filter { it.name.equals(segment, ignoreCase = true) }
                        .orEmpty()
                    require(matches.size == 1) { "模型资源缺失或大小写冲突: $relativePath" }
                    matches.single()
                }
            }
        }
        val resolved = current.canonicalFile
        require(resolved.path.startsWith(rootPath) && resolved.isFile) {
            "模型资源缺失或路径越界: $relativePath"
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
            "${mocFile.name} 不是有效的 moc3 文件"
        }
        val mocVersion = header[4].toInt() and 0xff
        require(mocVersion in 1..5) {
            "${mocFile.name} 使用了 Cubism 5 Core 尚不支持的 moc3 版本 $mocVersion"
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
        if (result.isNotEmpty()) return result.toList()

        displayInfo?.optJSONArray("Parameters")?.let { parameters ->
            for (index in 0 until parameters.length()) {
                val parameter = parameters.optJSONObject(index) ?: continue
                val id = parameter.optString("Id")
                val name = parameter.optString("Name").lowercase(Locale.ROOT)
                if (id == "ParamMouthOpenY" || id == "ParamA" || name == "mouth open" || name == "嘴巴开合") {
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
                "无法读取纹理尺寸: ${texture.name}"
            }
            require(options.outWidth <= 4096 && options.outHeight <= 4096) {
                "Android 最小运行配置不接受超过 4096x4096 的纹理: ${texture.name}"
            }
            rgbaTextureBytes += options.outWidth.toLong() * options.outHeight.toLong() * 4L
        }

        val estimatedBytes = (mocFile.length() * 1.5 + rgbaTextureBytes * 1.5).toLong()
        val activityManager = getSystemService(ACTIVITY_SERVICE) as ActivityManager
        val memoryInfo = ActivityManager.MemoryInfo().also(activityManager::getMemoryInfo)
        val storageAvailable = StatFs(filesDir.path).availableBytes
        require(storageAvailable >= mocFile.length() + rgbaTextureBytes / 4L) {
            "设备剩余存储空间不足以安全加载该模型"
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
            "模型预计至少占用 ${estimatedMb} MB，超过本设备 Live2D 安全预算 ${budgetMb} MB；" +
                "请减小 moc3/纹理数量或改用桌面端，已阻止加载以避免闪退"
        }
    }

    private fun writeAvatarConfig(modelDirectory: File, lipSyncIds: List<String>) {
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
        if (lipSync.optJSONArray("parameterIds")?.length() in listOf(null, 0)) {
            lipSync.put("parameterIds", JSONArray(lipSyncIds))
        }
        if (!lipSync.has("gain")) lipSync.put("gain", 1.0)
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
        if (!config.has("cues")) config.put("cues", JSONObject())
        configFile.writeText(config.toString(2), Charsets.UTF_8)
    }

    private fun speak(text: String, result: MethodChannel.Result) {
        if (!ttsReady) {
            result.error("offline_tts_unavailable", "设备未安装可用的离线 TTS 语音包", null)
            return
        }
        if (text.isBlank()) {
            result.error("empty_text", "朗读文本不能为空", null)
            return
        }
        val utteranceId = "talk2u-${System.currentTimeMillis()}"
        val status = textToSpeech?.speak(text, TextToSpeech.QUEUE_FLUSH, Bundle(), utteranceId)
        if (status == TextToSpeech.ERROR) {
            result.error("tts_start_failed", "无法启动离线 TTS", null)
        } else {
            result.success(null)
        }
    }

    private fun launchSpeechSettings(action: String, result: MethodChannel.Result) {
        try {
            startActivity(Intent(action))
            result.success(null)
        } catch (error: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_SETTINGS))
                result.success(null)
            } catch (fallbackError: Exception) {
                result.error(
                    "speech_settings_unavailable",
                    fallbackError.message ?: error.message ?: "设备没有可用的语音设置页面",
                    null,
                )
            }
        }
    }

    private fun recognitionIntent(): Intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-CN")
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
    }

    private fun requestOfflineSttModel(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            !SpeechRecognizer.isOnDeviceRecognitionAvailable(this)
        ) {
            launchSpeechSettings(Settings.ACTION_VOICE_INPUT_SETTINGS, result)
            return
        }
        modelDownloadRecognizer?.destroy()
        val recognizer = try {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(this)
        } catch (error: RuntimeException) {
            result.error("stt_model_download_unavailable", error.message, null)
            return
        }
        modelDownloadRecognizer = recognizer
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                recognizer.triggerModelDownload(
                    recognitionIntent(),
                    mainExecutor,
                    object : ModelDownloadListener {
                        override fun onProgress(completedPercent: Int) {
                            emit(
                                mapOf(
                                    "type" to "sttModelDownloadProgress",
                                    "value" to completedPercent.coerceIn(0, 100),
                                ),
                            )
                        }

                        override fun onSuccess() {
                            emit(mapOf("type" to "sttModelDownloadDone"))
                            releaseModelDownloadRecognizer()
                        }

                        override fun onScheduled() {
                            emit(mapOf("type" to "sttModelDownloadScheduled"))
                        }

                        override fun onError(error: Int) {
                            emit(mapOf("type" to "sttModelDownloadError", "code" to error))
                            releaseModelDownloadRecognizer()
                        }
                    },
                )
            } else {
                @Suppress("DEPRECATION")
                recognizer.triggerModelDownload(recognitionIntent())
                emit(mapOf("type" to "sttModelDownloadScheduled"))
            }
            result.success("requested")
        } catch (error: RuntimeException) {
            releaseModelDownloadRecognizer()
            result.error("stt_model_download_failed", error.message, null)
        }
    }

    private fun releaseModelDownloadRecognizer() {
        modelDownloadRecognizer?.destroy()
        modelDownloadRecognizer = null
    }

    private fun refreshSpeechCapabilities() {
        if (ttsInitialized) ttsReady = selectOfflineVoice()
        emit(mapOf("type" to "capabilities", "value" to capabilities()))
    }

    private fun startListening(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            !SpeechRecognizer.isOnDeviceRecognitionAvailable(this)
        ) {
            result.error("offline_stt_unavailable", "设备没有可验证的离线语音识别服务", null)
            return
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            pendingRecognitionResult = result
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.RECORD_AUDIO),
                recordAudioRequest,
            )
            return
        }
        if (createAndStartRecognizer()) {
            result.success(null)
        } else {
            result.error("offline_stt_start_failed", "无法启动设备的离线语音识别器", null)
        }
    }

    private fun createAndStartRecognizer(): Boolean {
        speechRecognizer?.destroy()
        try {
            speechRecognizer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                SpeechRecognizer.createOnDeviceSpeechRecognizer(this)
            } else {
                return false
            }
        } catch (error: RuntimeException) {
            emit(
                mapOf(
                    "type" to "recognitionError",
                    "message" to (error.message ?: "离线语音识别器创建失败"),
                ),
            )
            return false
        }
        speechRecognizer?.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) = emit(mapOf("type" to "listening"))
            override fun onBeginningOfSpeech() = Unit
            override fun onRmsChanged(rmsdB: Float) {
                emit(mapOf("type" to "inputLevel", "value" to ((rmsdB + 2f) / 12f).coerceIn(0f, 1f)))
            }
            override fun onBufferReceived(buffer: ByteArray?) = Unit
            override fun onEndOfSpeech() = emit(mapOf("type" to "listeningEnd"))
            override fun onError(error: Int) = emit(mapOf("type" to "recognitionError", "code" to error))
            override fun onResults(results: Bundle?) {
                val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                if (text != null) emit(mapOf("type" to "recognitionResult", "text" to text, "final" to true))
            }
            override fun onPartialResults(partialResults: Bundle?) {
                val text = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                if (text != null) emit(mapOf("type" to "recognitionResult", "text" to text, "final" to false))
            }
            override fun onEvent(eventType: Int, params: Bundle?) = Unit
        })
        return try {
            speechRecognizer?.startListening(recognitionIntent())
            true
        } catch (error: RuntimeException) {
            speechRecognizer?.destroy()
            speechRecognizer = null
            emit(
                mapOf(
                    "type" to "recognitionError",
                    "message" to (error.message ?: "离线语音识别启动失败"),
                ),
            )
            false
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != recordAudioRequest) return
        val result = pendingRecognitionResult ?: return
        pendingRecognitionResult = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            if (createAndStartRecognizer()) {
                result.success(null)
            } else {
                result.error("offline_stt_start_failed", "无法启动设备的离线语音识别器", null)
            }
        } else {
            result.error("microphone_denied", "麦克风权限被拒绝", null)
        }
    }

    private fun emit(event: Any) {
        runOnUiThread { eventSink?.success(event) }
    }

    override fun onResume() {
        super.onResume()
        if (ttsInitialized) refreshSpeechCapabilities()
    }

    override fun onDestroy() {
        pendingRecognitionResult?.error("activity_destroyed", "语音识别已随页面关闭", null)
        pendingRecognitionResult = null
        speechRecognizer?.destroy()
        speechRecognizer = null
        releaseModelDownloadRecognizer()
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        ttsReady = false
        super.onDestroy()
    }
}
