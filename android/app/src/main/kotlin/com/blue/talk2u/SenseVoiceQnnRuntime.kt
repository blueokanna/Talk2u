package com.blue.talk2u

import android.content.Context
import android.os.Build
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineSenseVoiceModelConfig
import com.k2fsa.sherpa.onnx.QnnConfig
import java.io.File
import org.json.JSONObject

internal class SenseVoiceQnnRuntime(private val context: Context) : AutoCloseable {
    private var recognizer: OfflineRecognizer? = null
    private var activeRoot: File? = null

    fun load(modelRoot: File): Map<String, Any?> = synchronized(this) {
        val root = modelRoot.canonicalFile
        if (recognizer != null && activeRoot == root) return@synchronized diagnostics()
        close()

        val modelSpec = modelSpecForDevice()
        val qnnStatus = QnnRuntime.prepare(context)
        require(qnnStatus.ready && qnnStatus.architecture.equals("v81", true)) {
            qnnStatus.error ?: "QNN HTP v81 is unavailable"
        }
        val manifestFile = File(root, MANIFEST_FILE)
        require(manifestFile.isFile) { "$MANIFEST_FILE is missing" }
        val manifest = JSONObject(manifestFile.readText(Charsets.UTF_8))
        require(manifest.getInt("schemaVersion") == 1) { "Unsupported SenseVoice manifest" }
        require(manifest.getString("packageId") == modelSpec.packageId) {
            "The SenseVoice package does not match ${modelSpec.soc}"
        }
        require(manifest.getString("archiveSha256") == modelSpec.archiveSha256) {
            "SenseVoice package digest is not pinned"
        }
        require(manifest.getString("targetSoc").equals(modelSpec.soc, true)) {
            "The SenseVoice QNN context targets a different SoC"
        }
        require(manifest.getString("htpArchitecture").equals(HTP_ARCHITECTURE, true)) {
            "The SenseVoice QNN context does not target HTP $HTP_ARCHITECTURE"
        }
        val model = File(root, "model.bin").canonicalFile
        val tokens = File(root, "tokens.txt").canonicalFile
        require(model.parentFile == root && model.isFile && model.length() > 0) {
            "SenseVoice model.bin is missing"
        }
        require(tokens.parentFile == root && tokens.isFile && tokens.length() > 0) {
            "SenseVoice tokens.txt is missing"
        }
        require(manifest.getLong("modelBytes") == model.length()) { "SenseVoice model size mismatch" }
        require(manifest.getLong("tokensBytes") == tokens.length()) { "SenseVoice tokens size mismatch" }

        qnnStatus.fastRpcDirectory?.let(OfflineRecognizer::prependAdspLibraryPath)
        val config = OfflineRecognizerConfig(
            featConfig = FeatureConfig(sampleRate = SAMPLE_RATE, featureDim = 80, dither = 0.0f),
            modelConfig = OfflineModelConfig(
                senseVoice = OfflineSenseVoiceModelConfig(
                    language = "auto",
                    useInverseTextNormalization = true,
                    qnnConfig = QnnConfig(
                        backendLib = "libQnnHtp.so",
                        systemLib = "libQnnSystem.so",
                        contextBinary = model.path,
                    ),
                ),
                tokens = tokens.path,
                numThreads = 2,
                debug = false,
                provider = "qnn",
            ),
        )
        recognizer = OfflineRecognizer(config = config)
        activeRoot = root
        diagnostics()
    }

    fun recognize(pcm16le: ByteArray): Map<String, Any?> = synchronized(this) {
        val active = checkNotNull(recognizer) { "SenseVoice QNN runtime is not loaded" }
        require(pcm16le.isNotEmpty() && pcm16le.size % 2 == 0) { "PCM16 audio is invalid" }
        val pcmBytes = minOf(pcm16le.size, MAX_PCM_BYTES)
        val samples = FloatArray(pcmBytes / 2)
        for (index in samples.indices) {
            val offset = index * 2
            val value = (pcm16le[offset].toInt() and 0xff) or
                (pcm16le[offset + 1].toInt() shl 8)
            samples[index] = value.toShort() / 32768.0f
        }
        val stream = active.createStream()
        try {
            stream.acceptWaveform(samples, SAMPLE_RATE)
            active.decode(stream)
            val result = active.getResult(stream)
            mapOf(
                "text" to result.text.trim(),
                "language" to result.lang,
                "emotion" to result.emotion,
                "event" to result.event,
                "provider" to "QNN_HTP",
                "hardwareAccelerated" to true,
            )
        } finally {
            stream.release()
        }
    }

    fun diagnostics(): Map<String, Any?> = mapOf(
        "engine" to "sherpa-onnx-kotlin",
        "provider" to "QNN_HTP",
        "soc" to detectedSoc(),
        "supportedSocs" to SUPPORTED_SOCS.sorted(),
        "htpArchitecture" to HTP_ARCHITECTURE,
        "model" to "SenseVoice 2024-07-17 INT8",
        "loaded" to (recognizer != null),
        "maxAudioSeconds" to MAX_AUDIO_SECONDS,
    )

    override fun close() = synchronized(this) {
        recognizer?.release()
        recognizer = null
        activeRoot = null
    }

    companion object {
        private data class ModelSpec(
            val soc: String,
            val packageId: String,
            val archiveSha256: String,
        )

        const val CHANNEL = "talk2u/sensevoice_qnn"
        const val MANIFEST_FILE = "talk2u-sensevoice-manifest.json"
        private const val HTP_ARCHITECTURE = "v81"
        private val MODEL_SPECS = listOf(
            ModelSpec(
                soc = "SM8750",
                packageId = "sherpa-onnx-qnn-SM8750-binary-10-seconds-sense-voice-zh-en-ja-ko-yue-2024-07-17-int8",
                archiveSha256 = "1e9cbe0498c335b00c9c0f63dc683be7ed2b6cf0c5673df1f5c7715d6909936e",
            ),
            ModelSpec(
                soc = "SM8850",
                packageId = "sherpa-onnx-qnn-SM8850-binary-10-seconds-sense-voice-zh-en-ja-ko-yue-2024-07-17-int8",
                archiveSha256 = "ecbc1ffba39f8e23582b79a199d12e8455425a22ef7b6b18c535ce25fcff2d64",
            ),
        ).associateBy(ModelSpec::soc)
        private val SUPPORTED_SOCS = MODEL_SPECS.keys
        private const val SAMPLE_RATE = 16_000
        private const val MAX_AUDIO_SECONDS = 10
        private const val MAX_PCM_BYTES = SAMPLE_RATE * MAX_AUDIO_SECONDS * 2

        private fun detectedSoc(): String = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Build.SOC_MODEL.trim().uppercase()
        } else {
            ""
        }

        private fun modelSpecForDevice(): ModelSpec {
            val soc = detectedSoc()
            return requireNotNull(MODEL_SPECS[soc]) {
                "SenseVoice QNN supports ${SUPPORTED_SOCS.sorted().joinToString()} HTP v81; " +
                    "detected ${soc.ifEmpty { "unknown SoC" }}"
            }
        }
    }
}
