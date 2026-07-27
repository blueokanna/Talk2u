package com.blue.talk2u

import android.content.Context
import android.system.Os
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest

internal object QnnRuntime {
    data class Status(
        val bundled: Boolean,
        val ready: Boolean,
        val architecture: String,
        val fastRpcDirectory: String?,
        val error: String?,
    ) {
        fun asMap(): Map<String, Any?> = mapOf(
            "bundled" to bundled,
            "ready" to ready,
            "architecture" to architecture,
            "fastRpcDirectory" to fastRpcDirectory,
            "error" to error,
        )
    }

    @Volatile
    private var current = Status(
        bundled = BuildConfig.QNN_BUNDLED,
        ready = false,
        architecture = BuildConfig.QNN_HTP_ARCH,
        fastRpcDirectory = null,
        error = if (BuildConfig.QNN_BUNDLED) "QNN runtime has not been prepared" else "QNN is not bundled",
    )

    val status: Status
        get() = current

    fun prepare(context: Context): Status = synchronized(this) {
        if (current.ready || !BuildConfig.QNN_BUNDLED) return@synchronized current
        current = runCatching { prepareBundledRuntime(context.applicationContext) }
            .getOrElse { error ->
                Status(
                    bundled = true,
                    ready = false,
                    architecture = BuildConfig.QNN_HTP_ARCH,
                    fastRpcDirectory = null,
                    error = error.message ?: error.javaClass.simpleName,
                )
            }
        current
    }

    private fun prepareBundledRuntime(context: Context): Status {
        val arch = BuildConfig.QNN_HTP_ARCH
        val skelName = "libQnnHtp${arch.uppercase()}Skel.so"
        val assetPath = "qnn/htp/$arch/$skelName"
        val fastRpcDirectory = runCatching {
            extractSkel(context, assetPath, skelName)
        }.getOrElse {
            val nativeDirectory = File(context.applicationInfo.nativeLibraryDir)
            require(File(nativeDirectory, skelName).isFile) {
                "QNN $arch skel is absent from assets and native libraries"
            }
            nativeDirectory
        }
        val searchPath = buildList {
            add(fastRpcDirectory.absolutePath)
            Os.getenv("ADSP_LIBRARY_PATH")
                ?.split(';')
                ?.map(String::trim)
                ?.filter(String::isNotEmpty)
                ?.let(::addAll)
            add("/vendor/dsp/cdsp")
            add("/vendor/lib/rfsa/adsp")
            add("/system/lib/rfsa/adsp")
            add("/dsp")
        }.distinct().joinToString(";")
        Os.setenv("ADSP_LIBRARY_PATH", searchPath, true)
        System.loadLibrary("QnnSystem")
        System.loadLibrary("QnnHtp${arch.uppercase()}Stub")
        System.loadLibrary("QnnHtp")
        return Status(
            bundled = true,
            ready = true,
            architecture = arch,
            fastRpcDirectory = fastRpcDirectory.absolutePath,
            error = null,
        )
    }

    private fun extractSkel(context: Context, assetPath: String, fileName: String): File {
        val expectedSha256 = BuildConfig.QNN_SKEL_SHA256
        require(expectedSha256.isNotEmpty()) { "QNN skel digest is missing" }
        val directory = File(context.noBackupFilesDir, "qnn/htp/${BuildConfig.QNN_HTP_ARCH}")
        require(directory.isDirectory || directory.mkdirs()) {
            "Unable to create QNN FastRPC directory"
        }
        val destination = File(directory, fileName)
        if (destination.isFile && destination.sha256() == expectedSha256) return directory
        val temporary = File(directory, "$fileName.tmp")
        runCatching {
            context.assets.open(assetPath).use { input ->
                FileOutputStream(temporary, false).use { output ->
                    input.copyTo(output, 1024 * 1024)
                    output.fd.sync()
                }
            }
            require(temporary.sha256() == expectedSha256) { "QNN skel SHA-256 mismatch" }
            if (destination.exists()) require(destination.delete()) { "Unable to replace QNN skel" }
            require(temporary.renameTo(destination)) { "Unable to install QNN skel" }
            Os.chmod(destination.absolutePath, 0b111101101)
        }.onFailure {
            temporary.delete()
        }.getOrThrow()
        return directory
    }

    private fun File.sha256(): String {
        val digest = MessageDigest.getInstance("SHA-256")
        inputStream().buffered().use { input ->
            val buffer = ByteArray(1024 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
