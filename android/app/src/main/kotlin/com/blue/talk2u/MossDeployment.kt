package com.blue.talk2u

import org.json.JSONObject

/** One file declared by `moss-qnn-deployment.json`. */
internal data class MossManifestFile(
    val path: String,
    val size: Long,
    val sha256: String,
)

/** Validated view of a MOSS deployment manifest. */
internal data class MossDeployment(
    val files: List<MossManifestFile>,
    val soc: String,
    val htpArchitecture: String,
    val qnnSdkVersion: String,
    val ortVersion: String,
)

/**
 * Parsing and validation of `moss-qnn-deployment.json`.
 *
 * Kept separate from [ModelStore] so the security-relevant rules (schema,
 * provider plan, required files, bounded sizes, safe paths, SHA-256 shape) are
 * exercised by JVM tests instead of only by importing a 684 MB archive.
 */
internal object MossDeploymentParser {
    const val MANIFEST = "moss-qnn-deployment.json"
    const val TTS_DIR = "MOSS-TTS-Nano-100M-ONNX"
    const val CODEC_DIR = "MOSS-Audio-Tokenizer-Nano-ONNX"
    const val MAX_FILE_BYTES = 2L * 1024 * 1024 * 1024
    const val MAX_FILE_COUNT = 64

    val acceptedCodecProviders = setOf("ORT_CPU", "QNN_HTP")

    val requiredPaths = setOf(
        "$TTS_DIR/browser_poc_manifest.json",
        "$TTS_DIR/tts_browser_onnx_meta.json",
        "$TTS_DIR/tokenizer.model",
        "$TTS_DIR/moss_tts_prefill.qnn.onnx",
        "$TTS_DIR/moss_tts_decode_step.qnn.onnx",
        "$TTS_DIR/moss_tts_local_fixed_sampled_frame.onnx",
        "$TTS_DIR/moss_tts_global_shared.data",
        "$TTS_DIR/moss_tts_local_shared.data",
        "$CODEC_DIR/codec_browser_onnx_meta.json",
        "$CODEC_DIR/moss_audio_tokenizer_decode_step.qnn.onnx",
        "$CODEC_DIR/moss_audio_tokenizer_decode_shared.data",
    )

    private val sha256Pattern = Regex("[0-9a-f]{64}")

    fun parse(manifest: JSONObject): MossDeployment {
        require(manifest.getInt("schemaVersion") == 1) { "Unsupported deployment schema" }
        require(manifest.getString("runtime") == "onnxruntime-qnn-plugin-ep") {
            "Deployment does not target the ONNX Runtime QNN Plugin EP"
        }
        require(manifest.getString("qnnSdkVersion") == "2.48.0") {
            "This app requires a QAIRT/QNN SDK 2.48.0 deployment"
        }
        require(manifest.getString("ortVersion").startsWith("1.26.")) {
            "This app requires an ONNX Runtime 1.26 deployment"
        }
        require(manifest.optString("onnxruntimeQnnVersion") == "2.4.0") {
            "This app requires QNN Plugin EP 2.4.0"
        }

        val target = manifest.getJSONObject("target")
        val soc = target.getString("soc")
        val htpArchitecture = target.getString("htpArchitecture")
        require(soc == "SM8850" && htpArchitecture.equals("v81", ignoreCase = true)) {
            "This build accepts only SM8850 HTP v81 deployments"
        }

        val plan = manifest.getJSONObject("providerPlan")
        require(
            plan.getString("prefill") == "QNN_HTP" &&
                plan.getString("decode") == "QNN_HTP" &&
                plan.getString("sampler") == "ORT_CPU" &&
                plan.getString("codec") in acceptedCodecProviders,
        ) { "Unexpected execution-provider plan" }

        val array = manifest.getJSONArray("files")
        require(array.length() in requiredPaths.size..MAX_FILE_COUNT) {
            "Invalid deployment file count"
        }
        val paths = HashSet<String>()
        val files = ArrayList<MossManifestFile>(array.length())
        for (index in 0 until array.length()) {
            val item = array.getJSONObject(index)
            val path = SafeRelativePath.normalize(item.getString("path"))
            require(paths.add(path)) { "Duplicate deployment path: $path" }
            val size = item.getLong("size")
            require(size > 0 && size <= MAX_FILE_BYTES) { "Invalid file size for $path" }
            val hash = item.getString("sha256").lowercase()
            require(sha256Pattern.matches(hash)) { "Invalid SHA-256 for $path" }
            files.add(MossManifestFile(path, size, hash))
        }
        require(paths.containsAll(requiredPaths)) {
            "Deployment is missing required runtime files: ${(requiredPaths - paths).joinToString()}"
        }

        return MossDeployment(
            files = files,
            soc = soc,
            htpArchitecture = htpArchitecture,
            qnnSdkVersion = manifest.getString("qnnSdkVersion"),
            ortVersion = manifest.getString("ortVersion"),
        )
    }
}
