package com.blue.talk2u

import android.content.Context
import androidx.annotation.Keep
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicLong

@Keep
fun interface NativeInitProgressCallback {
    fun onProgress(stage: String)
}

class NativeMossRuntime private constructor(private val handle: AtomicLong) : Closeable {
    data class SynthesisResult(
        val outputFile: File,
        val sampleRate: Int,
        val generatedFrames: Int,
        val audioSamples: Long,
        val durationMs: Long,
        val elapsedMs: Long,
        val prefillMs: Long,
        val decodeMs: Long,
        val codecMs: Long,
        val htpBusyMs: Long,
        val provider: String,
    )

    data class Telemetry(
        val htpBusyNanos: Long,
        val htpInvocations: Long,
        val htpInFlight: Boolean,
        val cpuThreads: Int,
        val performanceMode: String,
    )

    fun synthesize(
        text: String,
        outputFile: File,
        voice: String,
        maxFrames: Int,
        seed: Long,
    ): SynthesisResult {
        require(text.isNotBlank()) { "Text cannot be empty" }
        require(maxFrames in 1..375) { "maxFrames must be between 1 and 375" }
        val current = handle.get()
        check(current != 0L) { "MOSS runtime is closed" }
        val payload = JSONObject(
            nativeRun(current, text.trim(), outputFile.absolutePath, voice, maxFrames, seed),
        )
        return SynthesisResult(
            outputFile = File(payload.getString("outputPath")),
            sampleRate = payload.getInt("sampleRate"),
            generatedFrames = payload.getInt("generatedFrames"),
            audioSamples = payload.getLong("audioSamples"),
            durationMs = payload.getLong("durationMs"),
            elapsedMs = payload.getLong("elapsedMs"),
            prefillMs = payload.getLong("prefillMs"),
            decodeMs = payload.getLong("decodeMs"),
            codecMs = payload.getLong("codecMs"),
            htpBusyMs = payload.getLong("htpBusyMs"),
            provider = payload.getString("provider"),
        )
    }

    fun telemetry(): Telemetry {
        val current = handle.get()
        check(current != 0L) { "MOSS runtime is closed" }
        val payload = JSONObject(nativeGetTelemetry(current))
        return Telemetry(
            htpBusyNanos = payload.getLong("htpBusyNanos"),
            htpInvocations = payload.getLong("htpInvocations"),
            htpInFlight = payload.getInt("htpInFlight") > 0,
            cpuThreads = payload.getInt("cpuThreads"),
            performanceMode = payload.getString("performanceMode"),
        )
    }

    override fun close() {
        val current = handle.getAndSet(0L)
        if (current != 0L) nativeRelease(current)
    }

    companion object {
        private const val SKEL_ASSET = "qnn/htp/v81/libQnnHtpV81Skel.so"
        private const val SKEL_SHA256 =
            "87e6463b4b4441eedb1b2ae889443510249eae4d6533278d3a5c798b8eea25d1"

        init {
            System.loadLibrary("QnnSystem")
            System.loadLibrary("QnnHtpV81Stub")
            System.loadLibrary("QnnHtp")
            System.loadLibrary("onnxruntime")
            System.loadLibrary("moss")
        }

        fun create(
            context: Context,
            modelRoot: File,
            onProgress: (String) -> Unit = {},
        ): NativeMossRuntime {
            require(modelRoot.isDirectory) { "Prepared MOSS model directory is missing" }
            val appContext = context.applicationContext
            val fastRpcDir = File(appContext.noBackupFilesDir, "qnn/htp/v81")
            val skel = extractVerifiedAsset(appContext, fastRpcDir)
            check(skel.isFile) { "QNN HTP V81 skel extraction failed" }
            val cacheDir = File(appContext.noBackupFilesDir, "qnn/context")
            check(cacheDir.mkdirs() || cacheDir.isDirectory) { "Cannot create QNN context cache" }
            val nativeLibraryDir = appContext.applicationInfo.nativeLibraryDir
                ?: error("Android did not expose the native library directory")
            val nativeHandle = nativeCreateSession(
                modelRoot.absolutePath,
                nativeLibraryDir,
                cacheDir.absolutePath,
                fastRpcDir.absolutePath,
                true,
                true,
                NativeInitProgressCallback(onProgress),
            )
            check(nativeHandle != 0L) { "Native MOSS session creation returned an invalid handle" }
            return NativeMossRuntime(AtomicLong(nativeHandle))
        }

        fun probeQnn(context: Context): Int {
            val appContext = context.applicationContext
            extractVerifiedAsset(appContext, File(appContext.noBackupFilesDir, "qnn/htp/v81"))
            val nativeLibraryDir = appContext.applicationInfo.nativeLibraryDir
                ?: error("Android did not expose the native library directory")
            return nativeProbeQnn(nativeLibraryDir)
        }

        private fun extractVerifiedAsset(context: Context, targetDir: File): File {
            check(targetDir.mkdirs() || targetDir.isDirectory) { "Cannot create FastRPC directory" }
            val target = File(targetDir, "libQnnHtpV81Skel.so")
            if (target.isFile && sha256(target) == SKEL_SHA256) return target
            val temporary = File(targetDir, "libQnnHtpV81Skel.so.tmp")
            context.assets.open(SKEL_ASSET).use { input ->
                FileOutputStream(temporary, false).use { output ->
                    input.copyTo(output, DEFAULT_BUFFER_SIZE)
                    output.fd.sync()
                }
            }
            check(sha256(temporary) == SKEL_SHA256) {
                temporary.delete()
                "Packaged QNN HTP V81 skel failed SHA-256 verification"
            }
            if (target.exists() && !target.delete()) {
                temporary.delete()
                error("Cannot replace the QNN HTP V81 skel")
            }
            check(temporary.renameTo(target)) { "Cannot install the QNN HTP V81 skel" }
            check(target.setReadable(true, true)) { "Cannot make the QNN HTP V81 skel readable" }
            return target
        }

        private fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            FileInputStream(file).use { input ->
                val buffer = ByteArray(1024 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }

        @JvmStatic
        private external fun nativeProbeQnn(nativeLibraryDir: String): Int

        @JvmStatic
        private external fun nativeCreateSession(
            modelRoot: String,
            nativeLibraryDir: String,
            contextCacheDir: String,
            fastRpcDir: String,
            hardwareOnly: Boolean,
            enableContextCache: Boolean,
            progressCallback: NativeInitProgressCallback,
        ): Long

        @JvmStatic
        private external fun nativeRun(
            handle: Long,
            text: String,
            outputPath: String,
            voice: String,
            maxFrames: Int,
            seed: Long,
        ): String

        @JvmStatic
        private external fun nativeGetTelemetry(handle: Long): String

        @JvmStatic
        private external fun nativeRelease(handle: Long)
    }
}
