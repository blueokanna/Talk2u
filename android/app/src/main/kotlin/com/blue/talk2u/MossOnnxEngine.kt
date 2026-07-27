package com.blue.talk2u

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OnnxTensorLike
import ai.onnxruntime.OnnxValue
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtLoggingLevel
import ai.onnxruntime.OrtProvider
import ai.onnxruntime.OrtSession
import ai.onnxruntime.providers.NNAPIFlags
import android.os.Build
import java.io.Closeable
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.nio.IntBuffer
import java.util.EnumSet
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.min
import org.json.JSONArray
import org.json.JSONObject

class MossOnnxEngine(
    private val modelRoot: File,
    private val cpuThreads: Int = 2,
    private val requireHardware: Boolean = true,
) : Closeable {
    private val env = OrtEnvironment.getEnvironment()
    private val manifestPath = resolveManifestPath(modelRoot)
    private val manifestDir = manifestPath.parentFile ?: modelRoot
    private val manifest = ModelManifest.fromJson(readJson(manifestPath))
    private val ttsMetaPath = resolveManifestRelativePath(manifest.modelFiles.ttsMeta)
    private val codecMetaPath = resolveManifestRelativePath(manifest.modelFiles.codecMeta)
    private val ttsMeta = TtsMeta.fromJson(readJson(ttsMetaPath))
    private val codecMeta = CodecMeta.fromJson(readJson(codecMetaPath))
    private val ttsDir = ttsMetaPath.parentFile ?: manifestDir
    private val codecDir = codecMetaPath.parentFile ?: manifestDir
    private val closed = AtomicBoolean(false)
    private val sessions = createSessionBundle()
    private val activeProvider = sessions.provider.label

    @Synchronized
    fun synthesize(
        textTokenChunks: List<IntArray>,
        outputFile: File,
        voice: String,
        maxFrames: Int,
        seed: Long,
        cancelled: AtomicBoolean,
    ): SynthesisResult {
        check(!closed.get()) { "MOSS-TTS-Nano engine is closed" }
        require(textTokenChunks.isNotEmpty()) { "textTokenChunks must not be empty" }
        require(textTokenChunks.all { it.isNotEmpty() }) { "textTokenChunks contains an empty chunk" }
        val startedAt = System.currentTimeMillis()
        val sampleRate = codecMeta.codecConfig.sampleRate
        val silenceSamples = sampleRate * 120 / 1000
        var totalSamples = 0L
        var totalFrames = 0
        val generatedChunks = textTokenChunks.mapIndexed { index, tokenIds ->
            ensureActive(cancelled)
            val inputRows = buildInputRows(tokenIds, voice)
            val prefillResult = runPrefill(inputRows, sessions.prefill)
            runDecode(
                prefillResult = prefillResult,
                maxFrames = maxFrames,
                seed = seed + index,
                cancelled = cancelled,
                decodeSession = sessions.decode,
                localFrameSession = sessions.localFrame,
            )
        }
        ensureActive(cancelled)
        outputFile.parentFile?.mkdirs()
        RandomAccessFile(outputFile, "rw").use { output ->
            output.setLength(0)
            output.write(ByteArray(44))
            generatedChunks.forEachIndexed { index, audioTokens ->
                ensureActive(cancelled)
                val samples = decodeAudioTokens(audioTokens, sessions.codec)
                writePcm16(output, samples)
                totalSamples += samples.size
                totalFrames += audioTokens.size
                if (index < generatedChunks.lastIndex) {
                    writeSilence(output, silenceSamples)
                    totalSamples += silenceSamples
                }
            }
            ensureActive(cancelled)
            writeWavHeader(output, sampleRate, totalSamples)
        }
        return SynthesisResult(
            outputFile = outputFile,
            generatedFrames = totalFrames,
            sampleRate = sampleRate,
            durationMs = (totalSamples.toDouble() / sampleRate * 1000.0).toLong(),
            elapsedMs = System.currentTimeMillis() - startedAt,
            provider = activeProvider,
        )
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        sessions.close()
    }

    private fun createSessionBundle(): SessionBundle {
        val failures = mutableListOf<String>()
        val candidates = buildList {
            val available = OrtEnvironment.getAvailableProviders()
            if (OrtProvider.QNN in available && qnnRuntimeLoadable()) {
                add(AccelerationProvider.QNN_HTP)
            }
            if (
                OrtProvider.NNAPI in available &&
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
            ) {
                add(AccelerationProvider.NNAPI_ACCELERATOR)
            }
            if (!requireHardware) add(AccelerationProvider.CPU)
        }
        for (provider in candidates) {
            try {
                return createSessionBundle(provider)
            } catch (error: Throwable) {
                failures += "${provider.label}: ${error.message ?: error.javaClass.simpleName}"
            }
        }
        val suffix = if (failures.isEmpty()) {
            "no deployable QNN HTP or strict NNAPI execution provider was found"
        } else {
            failures.joinToString("; ")
        }
        error("MOSS-TTS-Nano hardware acceleration is unavailable: $suffix")
    }

    private fun createSessionBundle(provider: AccelerationProvider): SessionBundle {
        val options = createSessionOptions(provider)
        val created = ArrayList<OrtSession>(4)
        try {
            fun open(role: String, file: File): OrtSession {
                require(file.isFile) { "Missing ONNX file: ${file.absolutePath}" }
                return try {
                    env.createSession(file.absolutePath, options).also(created::add)
                } catch (error: Throwable) {
                    throw IllegalStateException(
                        "${provider.label} rejected $role graph ${file.name}: " +
                            (error.message ?: error.javaClass.simpleName),
                        error,
                    )
                }
            }
            return SessionBundle(
                provider = provider,
                options = options,
                prefill = open("prefill", File(ttsDir, ttsMeta.files.prefill)),
                decode = open("decode-step", File(ttsDir, ttsMeta.files.decodeStep)),
                localFrame = open(
                    "local-frame",
                    File(ttsDir, ttsMeta.files.localFixedSampledFrame),
                ),
                codec = open("codec", File(codecDir, codecMeta.files.decodeFull)),
            )
        } catch (error: Throwable) {
            created.asReversed().forEach { runCatching { it.close() } }
            options.close()
            throw error
        }
    }

    private fun createSessionOptions(provider: AccelerationProvider): OrtSession.SessionOptions {
        val options = OrtSession.SessionOptions().apply {
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            setIntraOpNumThreads(
                if (provider == AccelerationProvider.CPU) cpuThreads.coerceIn(1, 4) else 1,
            )
            setInterOpNumThreads(1)
            setSessionLogLevel(
                if (BuildConfig.DEBUG) {
                    OrtLoggingLevel.ORT_LOGGING_LEVEL_INFO
                } else {
                    OrtLoggingLevel.ORT_LOGGING_LEVEL_WARNING
                },
            )
            if (BuildConfig.DEBUG) setSessionLogVerbosityLevel(1)
        }
        try {
            when (provider) {
                AccelerationProvider.QNN_HTP -> {
                    options.addConfigEntry("session.disable_cpu_ep_fallback", "1")
                    options.addQnn(
                        mapOf(
                            "backend_path" to "libQnnHtp.so",
                            "enable_htp_fp16_precision" to "1",
                            "htp_performance_mode" to "sustained_high_performance",
                            "htp_graph_finalization_optimization_mode" to "3",
                            "offload_graph_io_quantization" to "0",
                        ),
                    )
                }
                AccelerationProvider.NNAPI_ACCELERATOR -> {
                    options.addConfigEntry("session.disable_cpu_ep_fallback", "1")
                    options.addNnapi(EnumSet.of(NNAPIFlags.CPU_DISABLED))
                }
                AccelerationProvider.CPU -> Unit
            }
            return options
        } catch (error: Throwable) {
            options.close()
            throw error
        }
    }

    private fun resolveManifestRelativePath(relativePath: String): File {
        val direct = File(manifestDir, relativePath).canonicalFile
        if (direct.exists()) return direct
        val alias = relativePath
            .replace("MOSS-TTS-Nano-ONNX-CPU", "MOSS-TTS-Nano-100M-ONNX")
            .replace("MOSS-Audio-Tokenizer-Nano-ONNX-CPU", "MOSS-Audio-Tokenizer-Nano-ONNX")
        return File(manifestDir, alias).canonicalFile
    }

    private fun buildInputRows(textTokenIds: IntArray, voice: String): InputRows {
        val config = manifest.ttsConfig
        val rowWidth = config.nVq + 1
        val promptAudioCodes = selectBuiltinVoicePromptAudioCodes(voice)
        val prefixTokens = manifest.promptTemplates.userPromptPrefixTokenIds + config.audioStartTokenId
        val suffixTokens = intArrayOf(config.audioEndTokenId) +
            manifest.promptTemplates.userPromptAfterReferenceTokenIds +
            textTokenIds +
            manifest.promptTemplates.assistantPromptPrefixTokenIds +
            intArrayOf(config.audioStartTokenId)
        val rows = ArrayList<IntArray>()
        rows += buildTextRows(prefixTokens, config, rowWidth)
        rows += buildAudioRows(promptAudioCodes, config, rowWidth)
        rows += buildTextRows(suffixTokens, config, rowWidth)
        return InputRows(rows.toTypedArray(), IntArray(rows.size) { 1 })
    }

    private fun buildTextRows(tokens: IntArray, config: TtsConfig, rowWidth: Int): List<IntArray> {
        return tokens.map { token ->
            IntArray(rowWidth) { index -> if (index == 0) token else config.audioPadTokenId }
        }
    }

    private fun buildAudioRows(
        audioCodes: List<IntArray>,
        config: TtsConfig,
        rowWidth: Int,
    ): List<IntArray> {
        return audioCodes.map { codeRow ->
            IntArray(rowWidth) { index ->
                when {
                    index == 0 -> config.audioUserSlotTokenId
                    index - 1 < min(codeRow.size, config.nVq) -> codeRow[index - 1]
                    else -> config.audioPadTokenId
                }
            }
        }
    }

    private fun selectBuiltinVoicePromptAudioCodes(voice: String): List<IntArray> {
        val selected = manifest.builtinVoices.firstOrNull {
            it.voice == voice && it.promptAudioCodes.isNotEmpty()
        } ?: manifest.builtinVoices.firstOrNull { it.promptAudioCodes.isNotEmpty() }
        return selected?.promptAudioCodes
            ?: error("No built-in voice prompt codes found in ${manifestPath.absolutePath}")
    }

    private fun runPrefill(inputRows: InputRows, prefillSession: OrtSession): PrefillResult {
        val sequenceLength = inputRows.inputIds.size
        val rowWidth = inputRows.inputIds[0].size
        val flattened = IntArray(sequenceLength * rowWidth)
        var offset = 0
        for (row in inputRows.inputIds) {
            for (value in row) flattened[offset++] = value
        }
        OnnxTensor.createTensor(
            env,
            IntBuffer.wrap(flattened),
            longArrayOf(1, sequenceLength.toLong(), rowWidth.toLong()),
        ).use { inputTensor ->
            OnnxTensor.createTensor(
                env,
                IntBuffer.wrap(inputRows.attentionMask),
                longArrayOf(1, sequenceLength.toLong()),
            ).use { maskTensor ->
                val outputs = prefillSession.run(
                    mapOf("input_ids" to inputTensor, "attention_mask" to maskTensor),
                )
                return PrefillResult(
                    globalHidden = extractLastHiddenTensor(outputs.requiredTensor("global_hidden")),
                    pastValidLengths = sequenceLength,
                    pastResult = outputs,
                )
            }
        }
    }

    private fun runDecode(
        prefillResult: PrefillResult,
        maxFrames: Int,
        seed: Long,
        cancelled: AtomicBoolean,
        decodeSession: OrtSession,
        localFrameSession: OrtSession,
    ): List<IntArray> {
        val config = manifest.ttsConfig
        val audioTokens = ArrayList<IntArray>()
        val rowWidth = config.nVq + 1
        val cappedFrames = maxFrames.coerceIn(1, manifest.generationDefaults.maxNewFrames)
        val previousTokens = Array(config.nVq) { HashSet<Int>() }
        val pastInputNames = ttsMeta.onnx.decodeInputNames.drop(2)
        val presentOutputNames = ttsMeta.onnx.decodeOutputNames.drop(1)
        val random = java.util.Random(seed)
        var pastValidLengths = prefillResult.pastValidLengths
        var globalHidden = prefillResult.globalHidden
        var pastResult: OrtSession.Result? = prefillResult.pastResult
        try {
            for (step in 0 until cappedFrames) {
                ensureActive(cancelled)
                val frameResult = runLocalFrame(
                    globalHidden,
                    previousTokens,
                    random,
                    localFrameSession,
                )
                if (!frameResult.shouldContinue) break
                val audioRow = IntArray(rowWidth) { index ->
                    if (index == 0) config.audioAssistantSlotTokenId else config.audioPadTokenId
                }
                for (quantizer in 0 until config.nVq) {
                    val token = frameResult.frame[quantizer]
                    audioRow[quantizer + 1] = token
                    previousTokens[quantizer].add(token)
                }
                audioTokens += frameResult.frame
                OnnxTensor.createTensor(
                    env,
                    IntBuffer.wrap(audioRow),
                    longArrayOf(1, 1, rowWidth.toLong()),
                ).use { inputTensor ->
                    OnnxTensor.createTensor(
                        env,
                        IntBuffer.wrap(intArrayOf(pastValidLengths)),
                        longArrayOf(1),
                    ).use { pastTensor ->
                        val feeds = linkedMapOf<String, OnnxTensorLike>(
                            "input_ids" to inputTensor,
                            "past_valid_lengths" to pastTensor,
                        )
                        val previousResult = pastResult ?: error("Missing decode KV cache")
                        for (index in pastInputNames.indices) {
                            feeds[pastInputNames[index]] =
                                previousResult.requiredTensor(presentOutputNames[index])
                        }
                        val outputs = decodeSession.run(feeds)
                        val nextHidden = extractLastHiddenTensor(outputs.requiredTensor("global_hidden"))
                        globalHidden.close()
                        previousResult.close()
                        pastResult = outputs
                        globalHidden = nextHidden
                        pastValidLengths += 1
                    }
                }
            }
        } finally {
            globalHidden.close()
            pastResult?.close()
        }
        if (audioTokens.isEmpty()) error("MOSS-TTS-Nano did not generate audio tokens")
        return audioTokens
    }

    private fun runLocalFrame(
        globalHidden: OnnxTensor,
        previousTokens: Array<HashSet<Int>>,
        random: java.util.Random,
        localFrameSession: OrtSession,
    ): LocalFrameResult {
        val config = manifest.ttsConfig
        val codebookSize = config.audioCodebookSizes.firstOrNull() ?: 1024
        val seenMask = IntArray(config.nVq * codebookSize)
        for (channelIndex in previousTokens.indices) {
            val channelOffset = channelIndex * codebookSize
            for (tokenId in previousTokens[channelIndex]) {
                if (tokenId in 0 until codebookSize) seenMask[channelOffset + tokenId] = 1
            }
        }
        val assistantRandom = floatArrayOf(
            random.nextDouble().coerceIn(1e-6, 1.0 - 1e-6).toFloat(),
        )
        val audioRandom = FloatArray(config.nVq) {
            random.nextDouble().coerceIn(1e-6, 1.0 - 1e-6).toFloat()
        }
        OnnxTensor.createTensor(
            env,
            IntBuffer.wrap(seenMask),
            longArrayOf(1, config.nVq.toLong(), codebookSize.toLong()),
        ).use { seenTensor ->
            OnnxTensor.createTensor(
                env,
                FloatBuffer.wrap(assistantRandom),
                longArrayOf(1),
            ).use { assistantTensor ->
                OnnxTensor.createTensor(
                    env,
                    FloatBuffer.wrap(audioRandom),
                    longArrayOf(1, config.nVq.toLong()),
                ).use { audioTensor ->
                    localFrameSession.run(
                        mapOf(
                            "global_hidden" to globalHidden,
                            "repetition_seen_mask" to seenTensor,
                            "assistant_random_u" to assistantTensor,
                            "audio_random_u" to audioTensor,
                        ),
                    ).use { outputs ->
                        return LocalFrameResult(
                            shouldContinue = outputs.requiredTensor("should_continue").scalarInt() > 0,
                            frame = outputs.requiredTensor("frame_token_ids").intArrayValue(),
                        )
                    }
                }
            }
        }
    }

    private fun decodeAudioTokens(
        audioTokens: List<IntArray>,
        codecDecodeSession: OrtSession,
    ): FloatArray {
        val frameCount = audioTokens.size
        val quantizerCount = manifest.ttsConfig.nVq
        val flattened = IntArray(frameCount * quantizerCount)
        var offset = 0
        for (frame in audioTokens) {
            for (quantizer in 0 until quantizerCount) flattened[offset++] = frame[quantizer]
        }
        OnnxTensor.createTensor(
            env,
            IntBuffer.wrap(flattened),
            longArrayOf(1, frameCount.toLong(), quantizerCount.toLong()),
        ).use { codesTensor ->
            OnnxTensor.createTensor(
                env,
                IntBuffer.wrap(intArrayOf(frameCount)),
                longArrayOf(1),
            ).use { lengthsTensor ->
                codecDecodeSession.run(
                    mapOf("audio_codes" to codesTensor, "audio_code_lengths" to lengthsTensor),
                ).use { outputs ->
                    val audio = outputs.requiredTensor("audio").value as Array<*>
                    val batch = audio[0] as Array<*>
                    val channels = batch.map { it as FloatArray }
                    val reportedLength = outputs.requiredTensor("audio_lengths").scalarInt()
                    val length = min(reportedLength, channels.minOfOrNull { it.size } ?: 0)
                    return FloatArray(length) { sampleIndex ->
                        channels.sumOf { it[sampleIndex].toDouble() }.toFloat() / channels.size
                    }
                }
            }
        }
    }

    private fun writePcm16(output: RandomAccessFile, samples: FloatArray) {
        val chunkSamples = 8192
        val buffer = ByteBuffer.allocate(chunkSamples * 2).order(ByteOrder.LITTLE_ENDIAN)
        var offset = 0
        while (offset < samples.size) {
            buffer.clear()
            val end = min(offset + chunkSamples, samples.size)
            for (index in offset until end) {
                buffer.putShort((samples[index].coerceIn(-1f, 1f) * 32767f).toInt().toShort())
            }
            output.write(buffer.array(), 0, buffer.position())
            offset = end
        }
    }

    private fun writeSilence(output: RandomAccessFile, sampleCount: Int) {
        val buffer = ByteArray(16384)
        var remainingBytes = sampleCount * 2
        while (remainingBytes > 0) {
            val count = min(buffer.size, remainingBytes)
            output.write(buffer, 0, count)
            remainingBytes -= count
        }
    }

    private fun writeWavHeader(output: RandomAccessFile, sampleRate: Int, sampleCount: Long) {
        val dataSize = sampleCount * 2
        require(dataSize <= Int.MAX_VALUE - 44) { "Generated audio is too long" }
        val buffer = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put("RIFF".toByteArray(Charsets.US_ASCII))
        buffer.putInt((36 + dataSize).toInt())
        buffer.put("WAVE".toByteArray(Charsets.US_ASCII))
        buffer.put("fmt ".toByteArray(Charsets.US_ASCII))
        buffer.putInt(16)
        buffer.putShort(1.toShort())
        buffer.putShort(1.toShort())
        buffer.putInt(sampleRate)
        buffer.putInt(sampleRate * 2)
        buffer.putShort(2.toShort())
        buffer.putShort(16.toShort())
        buffer.put("data".toByteArray(Charsets.US_ASCII))
        buffer.putInt(dataSize.toInt())
        output.seek(0)
        output.write(buffer.array())
    }

    private fun ensureActive(cancelled: AtomicBoolean) {
        if (cancelled.get() || Thread.currentThread().isInterrupted) {
            throw CancellationException("MOSS-TTS-Nano synthesis cancelled")
        }
    }

    companion object {
        fun probeRuntime(): Boolean {
            OrtEnvironment.getEnvironment()
            return true
        }

        fun runtimeProviders(): List<String> {
            val available = OrtEnvironment.getAvailableProviders()
            return buildList {
                if (OrtProvider.QNN in available && qnnRuntimeLoadable()) add("QNN_HTP")
                if (OrtProvider.NNAPI in available && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    add("NNAPI_ACCELERATOR")
                }
                add("CPU")
            }
        }

        fun runtimeDetails(): Map<String, Any?> = mapOf(
            "qnn" to QnnRuntime.status.asMap(),
            "providers" to OrtEnvironment.getAvailableProviders().map { it.name },
        )

        private fun qnnRuntimeLoadable(): Boolean = QnnRuntime.status.ready

        private fun resolveManifestPath(modelRoot: File): File {
            val candidates = listOf(
                File(modelRoot, "browser_poc_manifest.json"),
                File(modelRoot, "MOSS-TTS-Nano-100M-ONNX/browser_poc_manifest.json"),
                File(modelRoot, "MOSS-TTS-Nano-ONNX-CPU/browser_poc_manifest.json"),
            )
            return candidates.firstOrNull { it.isFile }
                ?: error("browser_poc_manifest.json not found in ${modelRoot.absolutePath}")
        }

        private fun readJson(file: File): JSONObject {
            require(file.isFile) { "Missing JSON file: ${file.absolutePath}" }
            return JSONObject(file.readText(Charsets.UTF_8))
        }

        private fun flattenIntTensorValue(raw: Any?): IntArray {
            val values = ArrayList<Int>()
            fun append(value: Any?) {
                when (value) {
                    is Int -> values += value
                    is Long -> values += value.toInt()
                    is Short -> values += value.toInt()
                    is Byte -> values += value.toInt()
                    is IntArray -> values += value.toList()
                    is LongArray -> value.forEach { values += it.toInt() }
                    is ShortArray -> value.forEach { values += it.toInt() }
                    is ByteArray -> value.forEach { values += it.toInt() }
                    is Array<*> -> value.forEach(::append)
                    null -> Unit
                    else -> error("Unsupported int tensor value: ${value.javaClass}")
                }
            }
            append(raw)
            return values.toIntArray()
        }

        private fun extractLastHiddenTensor(tensor: OnnxTensor): OnnxTensor {
            val shape = tensor.info.shape
            val hidden = when (shape.size) {
                2 -> (tensor.value as Array<*>)[0] as FloatArray
                3 -> {
                    val batch = (tensor.value as Array<*>)[0] as Array<*>
                    batch[batch.size - 1] as FloatArray
                }
                else -> error("Unexpected global_hidden rank: ${shape.size}")
            }
            return OnnxTensor.createTensor(
                OrtEnvironment.getEnvironment(),
                FloatBuffer.wrap(hidden.copyOf()),
                longArrayOf(1, hidden.size.toLong()),
            )
        }

        private fun OrtSession.Result.requiredValue(name: String): OnnxValue {
            return get(name).orElseThrow { IllegalStateException("Missing ONNX output: $name") }
        }

        private fun OrtSession.Result.requiredTensor(name: String): OnnxTensor {
            return requiredValue(name) as OnnxTensor
        }

        private fun OnnxTensor.scalarInt(): Int {
            return flattenIntTensorValue(value).firstOrNull() ?: error("Scalar int tensor is empty")
        }

        private fun OnnxTensor.intArrayValue(): IntArray {
            return flattenIntTensorValue(value)
        }
    }

    private data class InputRows(val inputIds: Array<IntArray>, val attentionMask: IntArray)
    private data class PrefillResult(
        val globalHidden: OnnxTensor,
        val pastValidLengths: Int,
        val pastResult: OrtSession.Result,
    )
    private data class LocalFrameResult(val shouldContinue: Boolean, val frame: IntArray)

    private enum class AccelerationProvider(val label: String) {
        QNN_HTP("QNN_HTP"),
        NNAPI_ACCELERATOR("NNAPI_ACCELERATOR"),
        CPU("CPU"),
    }

    private data class SessionBundle(
        val provider: AccelerationProvider,
        val options: OrtSession.SessionOptions,
        val prefill: OrtSession,
        val decode: OrtSession,
        val localFrame: OrtSession,
        val codec: OrtSession,
    ) : Closeable {
        override fun close() {
            listOf(codec, localFrame, decode, prefill).forEach {
                runCatching { it.close() }
            }
            runCatching { options.close() }
        }
    }
}

data class SynthesisResult(
    val outputFile: File,
    val generatedFrames: Int,
    val sampleRate: Int,
    val durationMs: Long,
    val elapsedMs: Long,
    val provider: String,
)

private data class ModelManifest(
    val modelFiles: ModelFiles,
    val ttsConfig: TtsConfig,
    val promptTemplates: PromptTemplates,
    val generationDefaults: GenerationDefaults,
    val builtinVoices: List<BuiltinVoice>,
) {
    companion object {
        fun fromJson(json: JSONObject): ModelManifest {
            val voices = json.optJSONArray("builtin_voices")
            return ModelManifest(
                modelFiles = ModelFiles.fromJson(json.getJSONObject("model_files")),
                ttsConfig = TtsConfig.fromJson(json.getJSONObject("tts_config")),
                promptTemplates = PromptTemplates.fromJson(json.getJSONObject("prompt_templates")),
                generationDefaults = GenerationDefaults.fromJson(json.optJSONObject("generation_defaults")),
                builtinVoices = if (voices == null) emptyList() else List(voices.length()) {
                    BuiltinVoice.fromJson(voices.getJSONObject(it))
                },
            )
        }
    }
}

private data class ModelFiles(val ttsMeta: String, val codecMeta: String) {
    companion object {
        fun fromJson(json: JSONObject) = ModelFiles(
            ttsMeta = json.getString("tts_meta"),
            codecMeta = json.getString("codec_meta"),
        )
    }
}

private data class TtsConfig(
    val nVq: Int,
    val audioPadTokenId: Int,
    val audioStartTokenId: Int,
    val audioEndTokenId: Int,
    val audioUserSlotTokenId: Int,
    val audioAssistantSlotTokenId: Int,
    val audioCodebookSizes: IntArray,
) {
    companion object {
        fun fromJson(json: JSONObject) = TtsConfig(
            nVq = json.getInt("n_vq"),
            audioPadTokenId = json.getInt("audio_pad_token_id"),
            audioStartTokenId = json.getInt("audio_start_token_id"),
            audioEndTokenId = json.getInt("audio_end_token_id"),
            audioUserSlotTokenId = json.optInt("audio_user_slot_token_id", 8),
            audioAssistantSlotTokenId = json.getInt("audio_assistant_slot_token_id"),
            audioCodebookSizes = json.getJSONArray("audio_codebook_sizes").toIntArrayCompat(),
        )
    }
}

private data class PromptTemplates(
    val userPromptPrefixTokenIds: IntArray,
    val userPromptAfterReferenceTokenIds: IntArray,
    val assistantPromptPrefixTokenIds: IntArray,
) {
    companion object {
        fun fromJson(json: JSONObject) = PromptTemplates(
            userPromptPrefixTokenIds = json.getJSONArray("user_prompt_prefix_token_ids").toIntArrayCompat(),
            userPromptAfterReferenceTokenIds =
                json.getJSONArray("user_prompt_after_reference_token_ids").toIntArrayCompat(),
            assistantPromptPrefixTokenIds =
                json.getJSONArray("assistant_prompt_prefix_token_ids").toIntArrayCompat(),
        )
    }
}

private data class GenerationDefaults(val maxNewFrames: Int) {
    companion object {
        fun fromJson(json: JSONObject?) = GenerationDefaults(
            maxNewFrames = json?.optInt("max_new_frames", 375) ?: 375,
        )
    }
}

private data class BuiltinVoice(val voice: String, val promptAudioCodes: List<IntArray>) {
    companion object {
        fun fromJson(json: JSONObject): BuiltinVoice {
            val codes = json.optJSONArray("prompt_audio_codes")
            return BuiltinVoice(
                voice = json.optString("voice", ""),
                promptAudioCodes = if (codes == null) emptyList() else List(codes.length()) { index ->
                    codes.getJSONArray(index).toIntArrayCompat()
                },
            )
        }
    }
}

private data class TtsMeta(val files: TtsFiles, val onnx: TtsOnnxNames) {
    companion object {
        fun fromJson(json: JSONObject) = TtsMeta(
            files = TtsFiles.fromJson(json.getJSONObject("files")),
            onnx = TtsOnnxNames.fromJson(json.getJSONObject("onnx")),
        )
    }
}

private data class TtsFiles(
    val prefill: String,
    val decodeStep: String,
    val localFixedSampledFrame: String,
) {
    companion object {
        fun fromJson(json: JSONObject) = TtsFiles(
            prefill = json.getString("prefill"),
            decodeStep = json.getString("decode_step"),
            localFixedSampledFrame = json.getString("local_fixed_sampled_frame"),
        )
    }
}

private data class TtsOnnxNames(
    val decodeInputNames: List<String>,
    val decodeOutputNames: List<String>,
) {
    companion object {
        fun fromJson(json: JSONObject) = TtsOnnxNames(
            decodeInputNames = json.getJSONArray("decode_input_names").toStringList(),
            decodeOutputNames = json.getJSONArray("decode_output_names").toStringList(),
        )
    }
}

private data class CodecMeta(val files: CodecFiles, val codecConfig: CodecConfig) {
    companion object {
        fun fromJson(json: JSONObject) = CodecMeta(
            files = CodecFiles.fromJson(json.getJSONObject("files")),
            codecConfig = CodecConfig.fromJson(json.getJSONObject("codec_config")),
        )
    }
}

private data class CodecFiles(val decodeFull: String) {
    companion object {
        fun fromJson(json: JSONObject) = CodecFiles(json.getString("decode_full"))
    }
}

private data class CodecConfig(val sampleRate: Int) {
    companion object {
        fun fromJson(json: JSONObject) = CodecConfig(json.getInt("sample_rate"))
    }
}

private fun JSONArray.toIntArrayCompat(): IntArray {
    return IntArray(length()) { getInt(it) }
}

private fun JSONArray.toStringList(): List<String> {
    return List(length()) { getString(it) }
}
