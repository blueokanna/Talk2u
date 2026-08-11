package com.blue.talk2u

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.os.Build
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineSenseVoiceModelConfig
import com.k2fsa.sherpa.onnx.QnnConfig
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.zip.ZipInputStream
import org.json.JSONObject

internal class SenseVoiceQnnRuntime(private val context: Context) : AutoCloseable {
    private var recognizer: OfflineRecognizer? = null
    private var activeRoot: File? = null

    fun load(modelRoot: File): Map<String, Any?> =
            synchronized(this) {
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
                require(manifest.getLong("modelBytes") == model.length()) {
                    "SenseVoice model size mismatch"
                }
                require(manifest.getLong("tokensBytes") == tokens.length()) {
                    "SenseVoice tokens size mismatch"
                }
                val modelSha256 = manifest.getString("modelSha256").lowercase()
                val tokensSha256 = manifest.getString("tokensSha256").lowercase()
                require(modelSha256.matches(SHA256_PATTERN) && tokensSha256.matches(SHA256_PATTERN)) {
                    "SenseVoice content digests are invalid"
                }
                modelSpec.modelBytes?.let { expected ->
                    require(model.length() == expected) { "Unexpected SenseVoice model size" }
                }
                modelSpec.tokensBytes?.let { expected ->
                    require(tokens.length() == expected) { "Unexpected SenseVoice tokens size" }
                }
                modelSpec.modelSha256?.let { expected ->
                    require(modelSha256 == expected) { "Unexpected SenseVoice model digest" }
                }
                modelSpec.tokensSha256?.let { expected ->
                    require(tokensSha256 == expected) { "Unexpected SenseVoice tokens digest" }
                }
                require(sha256(model) == modelSha256) { "SenseVoice model SHA-256 mismatch" }
                require(sha256(tokens) == tokensSha256) { "SenseVoice tokens SHA-256 mismatch" }

                qnnStatus.fastRpcDirectory?.let(OfflineRecognizer::prependAdspLibraryPath)
                val config =
                        OfflineRecognizerConfig(
                                featConfig =
                                        FeatureConfig(
                                                sampleRate = SAMPLE_RATE,
                                                featureDim = 80,
                                                dither = 0.0f
                                        ),
                                modelConfig =
                                        OfflineModelConfig(
                                                senseVoice =
                                                        OfflineSenseVoiceModelConfig(
                                                                language = "auto",
                                                                useInverseTextNormalization = true,
                                                                qnnConfig =
                                                                        QnnConfig(
                                                                                backendLib =
                                                                                        "libQnnHtp.so",
                                                                                systemLib =
                                                                                        "libQnnSystem.so",
                                                                                contextBinary =
                                                                                        model.path,
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

    fun recognize(pcm16le: ByteArray): Map<String, Any?> =
            synchronized(this) {
                val active = checkNotNull(recognizer) { "SenseVoice QNN runtime is not loaded" }
                require(pcm16le.isNotEmpty() && pcm16le.size % 2 == 0) { "PCM16 audio is invalid" }
                val pcmBytes = minOf(pcm16le.size, MAX_PCM_BYTES)
                val samples = FloatArray(pcmBytes / 2)
                for (index in samples.indices) {
                    val offset = index * 2
                    val value =
                            (pcm16le[offset].toInt() and 0xff) or
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

    fun diagnostics(): Map<String, Any?> =
            mapOf(
                    "engine" to "sherpa-onnx-kotlin",
                    "provider" to "QNN_HTP",
                    "soc" to detectedSoc(),
                    "supportedSocs" to SUPPORTED_SOCS.sorted(),
                    "htpArchitecture" to HTP_ARCHITECTURE,
                    "model" to "SenseVoice 2024-07-17 INT8",
                    "loaded" to (recognizer != null),
                    "maxAudioSeconds" to MAX_AUDIO_SECONDS,
            )

    private fun sherpaRoot(): File {
        return File(context.filesDir, "sherpa-speech")
    }

    fun importFromZip(zipUri: Uri, resolver: ContentResolver, log: (String) -> Unit) {
        val modelSpec = modelSpecForDevice()
        val root = sherpaRoot()
        if (!root.exists()) root.mkdirs()
        check(root.isDirectory) { "Cannot create sherpa-speech directory" }

        val staging = File(root, ".${modelSpec.packageId}-import")
        staging.deleteRecursively()
        check(staging.mkdirs()) { "Cannot create SenseVoice import staging directory" }

        try {
            var foundModel = false
            var foundTokens = false
            var modelDigest = ""
            var tokensDigest = ""
            var extractedBytes = 0L

            resolver.openInputStream(zipUri)?.use { input ->
                ZipInputStream(BufferedInputStream(input)).use { zip ->
                    val buffer = ByteArray(1024 * 1024)
                    while (true) {
                        val entry = zip.nextEntry ?: break
                        if (entry.isDirectory) continue

                        val name = entry.name.trimStart('/').replace('\\', '/')
                        val fileName = File(name).name

                        if (fileName == "model.bin" || fileName == "tokens.txt") {
                            if (fileName == "model.bin") require(!foundModel) {
                                "ZIP contains duplicate model.bin entries"
                            }
                            if (fileName == "tokens.txt") require(!foundTokens) {
                                "ZIP contains duplicate tokens.txt entries"
                            }
                            val dest = File(staging, fileName)
                            val digest = MessageDigest.getInstance("SHA-256")
                            var fileBytes = 0L
                            FileOutputStream(dest).use { output ->
                                while (true) {
                                    if (Thread.currentThread().isInterrupted) {
                                        throw InterruptedException("SenseVoice import cancelled")
                                    }
                                    val count = zip.read(buffer)
                                    if (count < 0) break
                                    output.write(buffer, 0, count)
                                    digest.update(buffer, 0, count)
                                    fileBytes += count
                                    extractedBytes += count
                                    require(fileBytes <= MAX_MODEL_FILE_BYTES) {
                                        "SenseVoice ZIP entry is too large"
                                    }
                                    require(extractedBytes <= MAX_IMPORT_BYTES) {
                                        "SenseVoice ZIP expands beyond the package limit"
                                    }
                                }
                                output.fd.sync()
                            }
                            log("Extracted $fileName (${dest.length()} bytes)")
                            val actualDigest = digest.digest().joinToString("") { "%02x".format(it) }
                            if (fileName == "model.bin") {
                                foundModel = true
                                modelDigest = actualDigest
                            } else {
                                foundTokens = true
                                tokensDigest = actualDigest
                            }
                        }
                    }
                }
            }
                    ?: error("Cannot open the SenseVoice ZIP archive")

            require(foundModel) { "ZIP does not contain model.bin" }
            require(foundTokens) { "ZIP does not contain tokens.txt" }

            val model = File(staging, "model.bin")
            val tokens = File(staging, "tokens.txt")
            val expectedModelDigest = requireNotNull(modelSpec.modelSha256) {
                "Local ZIP import is not enabled for ${modelSpec.soc}; use the verified package download"
            }
            val expectedTokensDigest = requireNotNull(modelSpec.tokensSha256)
            require(model.length() == modelSpec.modelBytes && modelDigest == expectedModelDigest) {
                "SenseVoice model.bin does not match the pinned ${modelSpec.soc} package"
            }
            require(tokens.length() == modelSpec.tokensBytes && tokensDigest == expectedTokensDigest) {
                "SenseVoice tokens.txt does not match the pinned ${modelSpec.soc} package"
            }

            File(staging, MANIFEST_FILE)
                    .writeText(
                            JSONObject()
                                    .apply {
                                        put("schemaVersion", 1)
                                        put("packageId", modelSpec.packageId)
                                        put("archiveSha256", modelSpec.archiveSha256)
                                        put("targetSoc", modelSpec.soc)
                                        put("htpArchitecture", HTP_ARCHITECTURE)
                                        put("maxAudioSeconds", MAX_AUDIO_SECONDS)
                                        put("modelBytes", model.length())
                                        put("tokensBytes", tokens.length())
                                        put("modelSha256", modelDigest)
                                        put("tokensSha256", tokensDigest)
                                    }
                                    .toString(2),
                    )

            val destination = File(root, modelSpec.packageId)
            val backup = File(root, ".${modelSpec.packageId}-backup")
            if (backup.exists()) check(backup.deleteRecursively()) {
                "Cannot clean SenseVoice backup directory"
            }
            val hadInstalledModel = destination.exists()
            if (hadInstalledModel) check(destination.renameTo(backup)) {
                "Cannot preserve the installed SenseVoice model"
            }
            try {
                check(staging.renameTo(destination)) { "Cannot activate imported SenseVoice model" }
                if (backup.exists()) check(backup.deleteRecursively()) {
                    "Cannot clean the previous SenseVoice model"
                }
            } catch (error: Throwable) {
                if (destination.exists()) destination.deleteRecursively()
                if (hadInstalledModel && backup.exists()) check(backup.renameTo(destination)) {
                    "SenseVoice activation failed and the previous model could not be restored"
                }
                throw error
            }
            log("SenseVoice model installed successfully")
        } catch (error: Throwable) {
            staging.deleteRecursively()
            throw error
        }
    }

    override fun close() =
            synchronized(this) {
                recognizer?.release()
                recognizer = null
                activeRoot = null
            }

    companion object {
        private data class ModelSpec(
                val soc: String,
                val packageId: String,
                val archiveSha256: String,
                val modelBytes: Long? = null,
                val tokensBytes: Long? = null,
                val modelSha256: String? = null,
                val tokensSha256: String? = null,
        )

        const val CHANNEL = "talk2u/sensevoice_qnn"
        const val MANIFEST_FILE = "talk2u-sensevoice-manifest.json"
        private const val HTP_ARCHITECTURE = "v81"
        private val MODEL_SPECS =
                listOf(
                                ModelSpec(
                                        soc = "SM8750",
                                        packageId =
                                                "sherpa-onnx-qnn-SM8750-binary-10-seconds-sense-voice-zh-en-ja-ko-yue-2024-07-17-int8",
                                        archiveSha256 =
                                                "1e9cbe0498c335b00c9c0f63dc683be7ed2b6cf0c5673df1f5c7715d6909936e",
                                ),
                                ModelSpec(
                                        soc = "SM8850",
                                        packageId =
                                                "sherpa-onnx-qnn-SM8850-binary-10-seconds-sense-voice-zh-en-ja-ko-yue-2024-07-17-int8",
                                        archiveSha256 =
                                                "ecbc1ffba39f8e23582b79a199d12e8455425a22ef7b6b18c535ce25fcff2d64",
                                        modelBytes = 254_193_664L,
                                        tokensBytes = 315_894L,
                                        modelSha256 =
                                                "522763135f536bc43e9d122bac39254f49df4afbb003462d6d8bcdb77051de30",
                                        tokensSha256 =
                                                "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc",
                                ),
                        )
                        .associateBy(ModelSpec::soc)
        private val SUPPORTED_SOCS = MODEL_SPECS.keys
        private const val SAMPLE_RATE = 16_000
        private const val MAX_AUDIO_SECONDS = 10
        private const val MAX_PCM_BYTES = SAMPLE_RATE * MAX_AUDIO_SECONDS * 2
        private const val MAX_MODEL_FILE_BYTES = 512L * 1024 * 1024
        private const val MAX_IMPORT_BYTES = 512L * 1024 * 1024
        private val SHA256_PATTERN = Regex("[0-9a-f]{64}")

        private fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().buffered().use { input ->
                val buffer = ByteArray(1024 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }

        private fun detectedSoc(): String =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
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
