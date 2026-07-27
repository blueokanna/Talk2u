package com.blue.talk2u

import android.Manifest
import android.app.ActivityManager
import android.content.ComponentCallbacks2
import android.content.Context
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
import android.speech.tts.Voice
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
import java.util.concurrent.CancellationException
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipInputStream
import kotlin.math.sqrt
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity(), TextToSpeech.OnInitListener {
    private data class TtsSegment(
        val offset: Int,
        val first: Boolean,
        val last: Boolean,
    )

    private data class TtsChunk(
        val offset: Int,
        val text: String,
        val rate: Float,
        val pitch: Float,
        val volume: Float,
    )

    private data class TtsProsody(
        val rate: Float,
        val pitchOffset: Float,
        val volume: Float,
    )

    companion object {
        init {
            System.loadLibrary("rust_lib_talk2u")
        }
    }

    private external fun initializeRustTls(context: Context): Boolean

    private val speechChannelName = "talk2u/speech"
    private val speechEventsName = "talk2u/speech_events"
    private val live2dModelsChannelName = "talk2u/live2d_models"
    private val llmRuntimeChannelName = "talk2u/llm_runtime"
    private val mossTtsChannelName = "talk2u/moss_tts"
    private val recordAudioRequest = 4102
    private val speechPreferences by lazy {
        getSharedPreferences("talk2u_speech", Context.MODE_PRIVATE)
    }

    private var textToSpeech: TextToSpeech? = null
    private var ttsReady = false
    private var selectedTtsVoiceName = ""
    private var selectedTtsLocale = ""
    private var baseTtsPitch = 1.0f
    private var speechRecognizer: SpeechRecognizer? = null
    private var modelDownloadRecognizer: SpeechRecognizer? = null
    private var eventSink: EventChannel.EventSink? = null
    private var pendingRecognitionResult: MethodChannel.Result? = null
    @Volatile private var ttsAudioEncoding = AudioFormat.ENCODING_PCM_16BIT
    @Volatile private var lastAmplitudeEmitAt = 0L
    @Volatile private var loggedTtsAmplitude = false
    private var ttsInitialized = false
    private val ttsSegments = ConcurrentHashMap<String, TtsSegment>()
    private val mossExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "talk2u-moss-tts").apply { priority = Thread.NORM_PRIORITY - 1 }
    }
    @Volatile private var mossCancellation = AtomicBoolean(false)
    @Volatile private var activityDestroyed = false
    private var mossEngine: MossOnnxEngine? = null
    private var mossEngineRoot: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        val tlsReady = runCatching { initializeRustTls(applicationContext) }
            .onFailure { Log.e("Talk2U/TLS", "Unable to initialize Android TLS verifier", it) }
            .getOrDefault(false)
        if (!tlsReady) {
            Log.e("Talk2U/TLS", "Android TLS verifier initialization returned false")
        }
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val qnnStatus = QnnRuntime.prepare(applicationContext)
        Log.i("Talk2U/QNN", "runtime=${qnnStatus.asMap()}")
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
                    "selectTtsVoice" -> selectTtsVoice(
                        call.argument<String>("name").orEmpty(),
                        result,
                    )
                    "speak" -> speak(
                        call.argument<String>("text").orEmpty(),
                        call.argument<String>("style").orEmpty(),
                        result,
                    )
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
                    "importArchive", "importArchiveModels" -> {
                        val archivePath = call.argument<String>("path")
                        if (archivePath.isNullOrBlank()) {
                            result.error("invalid_archive", "未收到 Live2D ZIP 文件路径", null)
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, llmRuntimeChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capabilities" -> result.success(llmRuntimeCapabilities())
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mossTtsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "availableStorageBytes" -> result.success(StatFs(filesDir.path).availableBytes)
                    "probe" -> runCatching { MossOnnxEngine.probeRuntime() }
                        .fold(
                            onSuccess = result::success,
                            onFailure = {
                                result.error(
                                    "moss_runtime_unavailable",
                                    "MOSS-TTS-Nano ONNX Runtime 无法加载: ${it.message}",
                                    null,
                                )
                            },
                        )
                    "providers" -> runCatching { MossOnnxEngine.runtimeProviders() }
                        .fold(
                            onSuccess = {
                                Log.i("Talk2U/MOSS", "availableProviders=$it")
                                result.success(it)
                            },
                            onFailure = {
                                result.error(
                                    "moss_provider_probe_failed",
                                    "MOSS-TTS-Nano 无法读取 ONNX Runtime 执行提供程序: ${it.message}",
                                    null,
                                )
                            },
                        )
                    "runtimeDetails" -> result.success(MossOnnxEngine.runtimeDetails())
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

    override fun onInit(status: Int) {
        ttsInitialized = true
        ttsReady = status == TextToSpeech.SUCCESS && selectOfflineVoice()
        Log.i(
            "Talk2U.Speech",
            "TTS initialized status=$status ready=$ttsReady voice=$selectedTtsVoiceName locale=$selectedTtsLocale",
        )
        if (ttsReady) {
            textToSpeech?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {
                    lastAmplitudeEmitAt = 0L
                    loggedTtsAmplitude = false
                    val segment = utteranceId?.let(ttsSegments::get)
                    Log.i("Talk2U.Speech", "speechStart id=$utteranceId offset=${segment?.offset ?: 0}")
                    if (segment?.first != false) emit(mapOf("type" to "speechStart"))
                }

                override fun onDone(utteranceId: String?) {
                    val segment = utteranceId?.let(ttsSegments::remove)
                    Log.i("Talk2U.Speech", "speechDone id=$utteranceId last=${segment?.last != false}")
                    if (segment?.last != false) {
                        emit(mapOf("type" to "amplitude", "value" to 0.0))
                        emit(mapOf("type" to "speechDone"))
                    }
                }

                override fun onStop(utteranceId: String?, interrupted: Boolean) {
                    if (utteranceId == null || ttsSegments.remove(utteranceId) == null) return
                    ttsSegments.clear()
                    Log.i("Talk2U.Speech", "speechStop id=$utteranceId interrupted=$interrupted")
                    emit(mapOf("type" to "amplitude", "value" to 0.0))
                    emit(mapOf("type" to "speechDone"))
                }

                @Suppress("DEPRECATION")
                override fun onError(utteranceId: String?) {
                    if (utteranceId == null || ttsSegments.remove(utteranceId) == null) return
                    ttsSegments.clear()
                    Log.e("Talk2U.Speech", "speechError id=$utteranceId")
                    emit(mapOf("type" to "error", "message" to "离线 TTS 合成失败"))
                }

                override fun onError(utteranceId: String?, errorCode: Int) {
                    if (utteranceId == null || ttsSegments.remove(utteranceId) == null) return
                    ttsSegments.clear()
                    Log.e("Talk2U.Speech", "speechError id=$utteranceId code=$errorCode")
                    emit(mapOf("type" to "error", "message" to "离线 TTS 错误: $errorCode"))
                }

                override fun onBeginSynthesis(
                    utteranceId: String?,
                    sampleRateInHz: Int,
                    audioFormat: Int,
                    channelCount: Int,
                ) {
                    ttsAudioEncoding = audioFormat
                    Log.i(
                        "Talk2U.Speech",
                        "speechSynthesis id=$utteranceId rate=$sampleRateInHz format=$audioFormat channels=$channelCount",
                    )
                }

                override fun onRangeStart(
                    utteranceId: String?,
                    start: Int,
                    end: Int,
                    frame: Int,
                ) {
                    val offset = utteranceId?.let(ttsSegments::get)?.offset ?: 0
                    Log.d("Talk2U.Speech", "speechRange id=$utteranceId start=${offset + start} end=${offset + end}")
                    emit(
                        mapOf(
                            "type" to "speechRange",
                            "start" to offset + start,
                            "end" to offset + end,
                            "frame" to frame,
                        ),
                    )
                }

                override fun onAudioAvailable(utteranceId: String?, audio: ByteArray?) {
                    if (audio == null || audio.isEmpty()) return
                    val normalized = calculatePcmAmplitude(audio, ttsAudioEncoding)
                    if (normalized > 0.01 && !loggedTtsAmplitude) {
                        loggedTtsAmplitude = true
                        Log.i("Talk2U.Speech", "speechAmplitude id=$utteranceId value=$normalized")
                    }
                    emitAmplitude(normalized)
                }
            })
        }
        emit(mapOf("type" to "capabilities", "value" to capabilities()))
    }

    private fun selectOfflineVoice(): Boolean {
        val engine = textToSpeech ?: return false
        val voices = offlineTtsVoices()
        if (voices.isEmpty()) return false
        Log.i(
            "Talk2U.Speech",
            "TTS voices=" + voices.joinToString(" | ") {
                "${it.name}:${it.locale.toLanguageTag()}:network=${it.isNetworkConnectionRequired}"
            },
        )
        val savedName = speechPreferences.getString("tts_voice", null)
        val preferred = voices
            .sortedByDescending { voiceScore(it) + if (it.name == savedName) 100000 else 0 }
            .firstOrNull {
                runCatching { applyTtsVoice(engine, it) }.getOrDefault(false)
            }
        return preferred != null
    }

    private fun offlineTtsVoices(): List<Voice> {
        return textToSpeech?.voices
            ?.filter { !it.isNetworkConnectionRequired }
            ?.sortedWith(
                compareByDescending<Voice> { it.locale.language == Locale.CHINESE.language }
                    .thenByDescending { it.quality }
                    .thenBy { it.name },
            )
            .orEmpty()
    }

    private fun voiceScore(voice: Voice): Int {
        val name = voice.name.lowercase(Locale.ROOT)
        var score = voice.quality
        if (voice.locale.language == Locale.CHINESE.language) score += 1000
        if ("中文" in name || "普通话" in name || "mandarin" in name) score += 900
        if ("自然" in name || "情感" in name || "neural" in name) score += 160
        if ("温柔" in name || "warm" in name || "gentle" in name) score += 120
        if ("英文" in name || "english" in name) score -= 800
        return score
    }

    private fun voiceGender(voice: Voice): String {
        val name = voice.name.lowercase(Locale.ROOT)
        return when {
            "女声" in name || "女性" in name || "female" in name || "woman" in name -> "female"
            "男声" in name || "男性" in name || "male" in name -> "male"
            else -> "unknown"
        }
    }

    private fun applyTtsVoice(engine: TextToSpeech, voice: Voice): Boolean {
        if (engine.setVoice(voice) == TextToSpeech.ERROR) return false
        engine.setSpeechRate(0.93f)
        baseTtsPitch = when (voiceGender(voice)) {
            "male" -> 0.94f
            "female" -> 1.03f
            else -> 1.0f
        }
        engine.setPitch(baseTtsPitch)
        selectedTtsVoiceName = voice.name
        selectedTtsLocale = voice.locale.toLanguageTag()
        return true
    }

    private fun selectTtsVoice(name: String, result: MethodChannel.Result) {
        val engine = textToSpeech
        if (!ttsInitialized || engine == null) {
            result.error("offline_tts_unavailable", "设备离线 TTS 引擎尚未初始化", null)
            return
        }
        val voice = offlineTtsVoices().firstOrNull { it.name == name }
        if (voice == null) {
            result.error("tts_voice_unavailable", "选择的离线音色已不可用", null)
            return
        }
        engine.stop()
        if (!applyTtsVoice(engine, voice)) {
            result.error("tts_voice_failed", "无法启用选择的离线音色", null)
            return
        }
        speechPreferences.edit().putString("tts_voice", voice.name).apply()
        ttsReady = true
        val value = capabilities()
        emit(mapOf("type" to "capabilities", "value" to value))
        result.success(value)
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
            "ttsVoices" to offlineTtsVoices().map {
                mapOf(
                    "name" to it.name,
                    "locale" to it.locale.toLanguageTag(),
                    "gender" to voiceGender(it),
                )
            },
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
        return ((rms - 0.008).coerceAtLeast(0.0) * 8.0).coerceAtMost(1.0)
    }

    private fun emitAmplitude(value: Double) {
        val now = SystemClock.uptimeMillis()
        if (now - lastAmplitudeEmitAt < 32L) return
        lastAmplitudeEmitAt = now
        emit(mapOf("type" to "amplitude", "value" to value))
    }

    private fun importLive2dArchive(archivePath: String): List<String> {
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
                .sortedBy { it.relativeTo(importDir).path }
                .toList()
            require(modelFiles.isNotEmpty()) { "ZIP 中没有 .model3.json" }
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
        displayInfo?.optJSONArray("Parameters")?.let { parameters ->
            for (index in 0 until parameters.length()) {
                val parameter = parameters.optJSONObject(index) ?: continue
                val id = parameter.optString("Id")
                val name = parameter.optString("Name").lowercase(Locale.ROOT)
                if (
                    id in listOf("ParamMouthOpenY", "ParamA", "ParamI", "ParamU", "ParamE", "ParamO") ||
                    name == "mouth open" ||
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

    private fun speak(text: String, style: String, result: MethodChannel.Result) {
        if (!ttsReady) {
            result.error("offline_tts_unavailable", "设备未安装可用的离线 TTS 语音包", null)
            return
        }
        if (text.isBlank()) {
            result.error("empty_text", "朗读文本不能为空", null)
            return
        }
        val engine = textToSpeech
        if (engine == null) {
            result.error("offline_tts_unavailable", "设备离线 TTS 引擎尚未初始化", null)
            return
        }
        val chunks = splitTtsText(
            text,
            TextToSpeech.getMaxSpeechInputLength().coerceAtMost(280),
            style,
        )
        val batchId = System.currentTimeMillis()
        ttsSegments.clear()
        Log.i("Talk2U.Speech", "speak requested chars=${text.length} chunks=${chunks.size}")
        for ((index, chunk) in chunks.withIndex()) {
            val utteranceId = "talk2u-$batchId-$index"
            ttsSegments[utteranceId] = TtsSegment(
                offset = chunk.offset,
                first = index == 0,
                last = index == chunks.lastIndex,
            )
            val queueMode = if (index == 0) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD
            engine.setSpeechRate(chunk.rate)
            engine.setPitch(chunk.pitch)
            val parameters = Bundle().apply {
                putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, chunk.volume)
            }
            val status = engine.speak(chunk.text, queueMode, parameters, utteranceId)
            if (status == TextToSpeech.ERROR) {
                engine.stop()
                ttsSegments.clear()
                result.error("tts_start_failed", "无法启动离线 TTS", null)
                return
            }
        }
        result.success(null)
    }

    private fun splitTtsText(text: String, maximumLength: Int, style: String): List<TtsChunk> {
        val result = mutableListOf<TtsChunk>()
        val strongBoundaries = setOf('。', '！', '？', '；', '\n', '!', '?', ';', '.', '…')
        val softBoundaries = setOf('，', '、', ',', ':', '：')
        val allBoundaries = (strongBoundaries + softBoundaries + ' ').toCharArray()
        val closingPunctuation = setOf('”', '’', '」', '』', '）', ')', '】', ']')
        var cursor = 0
        while (cursor < text.length) {
            while (cursor < text.length && text[cursor].isWhitespace()) cursor++
            if (cursor >= text.length) break
            var end = (cursor + maximumLength).coerceAtMost(text.length)
            var foundBoundary = false
            for (index in cursor until end) {
                val character = text[index]
                val strong = character in strongBoundaries && index - cursor >= 2
                val soft = character in softBoundaries && index - cursor >= 36
                if (strong || soft) {
                    end = index + 1
                    while (end < text.length && text[end] in closingPunctuation) end++
                    foundBoundary = true
                    break
                }
            }
            if (!foundBoundary && end < text.length) {
                val boundary = text.lastIndexOfAny(allBoundaries, end - 1)
                if (boundary > cursor) end = boundary + 1
            }
            if (
                end < text.length &&
                end > cursor &&
                Character.isHighSurrogate(text[end - 1]) &&
                Character.isLowSurrogate(text[end])
            ) {
                end--
            }
            val raw = text.substring(cursor, end)
            val leading = raw.indexOfFirst { !it.isWhitespace() }.coerceAtLeast(0)
            val value = raw.trim()
            if (value.isNotEmpty()) {
                val prosody = ttsProsody(value, style)
                result.add(
                    TtsChunk(
                        offset = cursor + leading,
                        text = value,
                        rate = prosody.rate,
                        pitch = (baseTtsPitch + prosody.pitchOffset).coerceIn(0.78f, 1.16f),
                        volume = prosody.volume,
                    ),
                )
            }
            cursor = end
        }
        return result
    }

    private fun ttsProsody(text: String, style: String): TtsProsody {
        val lower = text.lowercase(Locale.ROOT)
        return when {
            style == "sad" -> TtsProsody(0.80f, -0.07f, 0.86f)
            style == "angry" -> TtsProsody(1.04f, -0.06f, 1.0f)
            style == "happy" -> TtsProsody(1.05f, 0.075f, 1.0f)
            style == "surprise" -> TtsProsody(1.08f, 0.10f, 1.0f)
            style == "dramatic" -> TtsProsody(0.86f, -0.035f, 0.9f)
            style == "shy" -> TtsProsody(0.86f, 0.02f, 0.88f)
            listOf("轻声", "小声", "低语", "耳语", "悄悄", "whisper").any(lower::contains) ->
                TtsProsody(0.84f, -0.01f, 0.78f)
            listOf("难过", "伤心", "悲伤", "哭", "失落", "孤独", "遗憾", "绝望", "sad").any(lower::contains) ->
                TtsProsody(0.80f, -0.07f, 0.86f)
            listOf("温柔", "温暖", "安心", "安慰", "拥抱", "柔和", "tender", "gentle").any(lower::contains) ->
                TtsProsody(0.87f, 0.015f, 0.92f)
            listOf("生气", "愤怒", "恼火", "争吵", "怒吼", "厉声", "angry").any(lower::contains) ->
                TtsProsody(1.04f, -0.06f, 1.0f)
            listOf("开心", "高兴", "喜悦", "兴奋", "幸福", "哈哈", "欢呼", "happy").any(lower::contains) ->
                TtsProsody(1.05f, 0.075f, 1.0f)
            listOf("惊讶", "震惊", "突然", "意外", "竟然", "surprise").any(lower::contains) ->
                TtsProsody(1.08f, 0.10f, 1.0f)
            listOf("黑暗", "寂静", "危险", "危机", "紧张", "屏住呼吸", "suspense").any(lower::contains) ->
                TtsProsody(0.86f, -0.035f, 0.9f)
            listOf("害羞", "脸红", "不好意思", "小声", "shy").any(lower::contains) ->
                TtsProsody(0.86f, 0.02f, 0.88f)
            '？' in text || '?' in text -> TtsProsody(0.94f, 0.055f, 0.96f)
            '！' in text || '!' in text -> TtsProsody(1.02f, 0.035f, 1.0f)
            else -> TtsProsody(0.93f, 0.0f, 0.96f)
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

    private fun synthesizeMoss(arguments: Map<*, *>?, result: MethodChannel.Result) {
        val modelRootValue = arguments?.get("modelRoot") as? String
        val outputValue = arguments?.get("outputPath") as? String
        val chunksValue = arguments?.get("tokenChunks") as? List<*>
        if (modelRootValue.isNullOrBlank() || outputValue.isNullOrBlank() || chunksValue.isNullOrEmpty()) {
            result.error("invalid_moss_request", "MOSS-TTS-Nano 推理参数不完整", null)
            return
        }
        val modelRoot = runCatching { File(modelRootValue).canonicalFile }.getOrNull()
        val outputFile = runCatching { File(outputValue).canonicalFile }.getOrNull()
        val dataRoot = applicationInfo.dataDir?.let(::File)?.canonicalFile
        val cacheRoot = cacheDir.canonicalFile
        if (modelRoot == null || dataRoot == null || !modelRoot.isInside(dataRoot)) {
            result.error("invalid_moss_model_path", "MOSS-TTS-Nano 模型路径不安全", null)
            return
        }
        if (outputFile == null || !outputFile.isInside(cacheRoot)) {
            result.error("invalid_moss_output_path", "MOSS-TTS-Nano 音频输出路径不安全", null)
            return
        }
        val tokenChunks = runCatching {
            chunksValue.map { rawChunk ->
                val values = rawChunk as? List<*> ?: error("token chunk is not a list")
                require(values.isNotEmpty() && values.size <= 512)
                IntArray(values.size) { index ->
                    val value = values[index] as? Number ?: error("token is not numeric")
                    value.toInt().also { require(it in 0 until 16384) }
                }
            }.also {
                require(it.size <= 64)
                require(it.sumOf(IntArray::size) <= 8192)
            }
        }.getOrElse {
            result.error("invalid_moss_tokens", "MOSS-TTS-Nano 文本 token 无效", null)
            return
        }
        val voices = setOf(
            "Junhao", "Zhiming", "Weiguo", "Xiaoyu", "Yuewen", "Lingyu",
            "Trump", "Ava", "Bella", "Adam", "Nathan", "Soyo", "Saki",
            "Mortis", "Umiri", "Mei", "Anon", "Arisa",
        )
        val voice = (arguments["voice"] as? String).orEmpty().let {
            if (it in voices) it else "Junhao"
        }
        val maxFrames = (arguments["maxFrames"] as? Number)?.toInt()?.coerceIn(40, 375) ?: 375
        val seed = (arguments["seed"] as? Number)?.toLong() ?: System.nanoTime()
        mossCancellation.set(true)
        val cancellation = AtomicBoolean(false)
        mossCancellation = cancellation
        mossExecutor.execute {
            try {
                val engine = mossEngine(modelRoot)
                val synthesis = engine.synthesize(
                    textTokenChunks = tokenChunks,
                    outputFile = outputFile,
                    voice = voice,
                    maxFrames = maxFrames,
                    seed = seed,
                    cancelled = cancellation,
                )
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
                            "generatedFrames" to synthesis.generatedFrames,
                            "provider" to synthesis.provider,
                        ),
                    )
                }
            } catch (_: CancellationException) {
                outputFile.delete()
                deliverMossResult(result) {
                    result.error("moss_cancelled", "MOSS-TTS-Nano 推理已取消", null)
                }
            } catch (error: Throwable) {
                outputFile.delete()
                val message = error.message ?: error.javaClass.simpleName
                Log.e("Talk2U/MOSS", "MOSS-TTS-Nano synthesis failed", error)
                deliverMossResult(result) {
                    result.error("moss_synthesis_failed", "MOSS-TTS-Nano 推理失败: $message", null)
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

    private fun mossEngine(modelRoot: File): MossOnnxEngine {
        val path = modelRoot.canonicalPath
        val current = mossEngine
        if (current != null && mossEngineRoot == path) return current
        closeMossEngine()
        return MossOnnxEngine(
            modelRoot = modelRoot,
            cpuThreads = mossCpuThreads(),
            requireHardware = true,
        ).also {
            mossEngine = it
            mossEngineRoot = path
        }
    }

    private fun closeMossEngine() {
        mossEngine?.close()
        mossEngine = null
        mossEngineRoot = null
    }

    private fun mossCpuThreads(): Int {
        val cores = Runtime.getRuntime().availableProcessors().coerceAtLeast(1)
        return if (cores >= 6) 4 else 2
    }

    private fun deliverMossResult(result: MethodChannel.Result, action: () -> Unit) {
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
        if (ttsInitialized) refreshSpeechCapabilities()
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level < ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) return
        mossCancellation.set(true)
    }

    override fun onDestroy() {
        activityDestroyed = true
        mossCancellation.set(true)
        mossExecutor.execute(::closeMossEngine)
        mossExecutor.shutdown()
        pendingRecognitionResult?.error("activity_destroyed", "语音识别已随页面关闭", null)
        pendingRecognitionResult = null
        speechRecognizer?.destroy()
        speechRecognizer = null
        releaseModelDownloadRecognizer()
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        ttsSegments.clear()
        ttsReady = false
        super.onDestroy()
    }
}
