package com.blue.talk2u

import android.content.Context
import android.system.Os
import android.system.OsConstants
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest

internal object QnnRuntime {
    data class Status(
        val bundled: Boolean,
        val ready: Boolean,
        val gpuReady: Boolean,
        val architecture: String,
        val fastRpcDirectory: String?,
        val pluginRegistered: Boolean,
        val epDeviceCount: Int,
        val allEpDeviceCount: Int,
        val ortVersion: String,
        val qnnPluginVersion: String,
        val qairtSdkVersion: String,
        val qairtSdkBuildId: String,
        val fastRpcDevices: List<String>,
        val error: String?,
    ) {
        fun asMap(): Map<String, Any?> = mapOf(
            "bundled" to bundled,
            "ready" to ready,
            "gpuReady" to gpuReady,
            "architecture" to architecture,
            "fastRpcDirectory" to fastRpcDirectory,
            "pluginRegistered" to pluginRegistered,
            "epDeviceCount" to epDeviceCount,
            "allEpDeviceCount" to allEpDeviceCount,
            "ortVersion" to ortVersion,
            "qnnPluginVersion" to qnnPluginVersion,
            "qairtSdkVersion" to qairtSdkVersion,
            "qairtSdkBuildId" to qairtSdkBuildId,
            "fastRpcDevices" to fastRpcDevices,
            "error" to error,
        )
    }

    @Volatile
    private var current = Status(
        bundled = BuildConfig.QNN_BUNDLED,
        ready = false,
        gpuReady = false,
        architecture = BuildConfig.QNN_HTP_ARCH,
        fastRpcDirectory = null,
        pluginRegistered = false,
        epDeviceCount = 0,
        allEpDeviceCount = 0,
        ortVersion = BuildConfig.ORT_VERSION,
        qnnPluginVersion = BuildConfig.QNN_PLUGIN_VERSION,
        qairtSdkVersion = BuildConfig.QAIRT_SDK_VERSION,
        qairtSdkBuildId = BuildConfig.QAIRT_SDK_BUILD_ID,
        fastRpcDevices = emptyList(),
        error = if (BuildConfig.QNN_BUNDLED) "QNN runtime has not been prepared" else "QNN is not bundled",
    )

    @Volatile
    private var nativePluginRegistered = false

    @Volatile
    private var qnnEpDeviceCount = 0

    @Volatile
    private var detectedOrtVersion = BuildConfig.ORT_VERSION

    @Volatile
    private var fastRpcDevices: List<String> = emptyList()

    val status: Status
        get() = current

    fun prepare(context: Context): Status = synchronized(this) {
        if (current.ready || !BuildConfig.QNN_BUNDLED) return@synchronized current
        current = runCatching { prepareBundledRuntime(context.applicationContext) }
            .getOrElse { error ->
                Log.e(LOG_TAG, "QNN runtime initialization failed", error)
                Status(
                    bundled = true,
                    ready = false,
                    gpuReady = false,
                    architecture = BuildConfig.QNN_HTP_ARCH,
                    fastRpcDirectory = null,
                    pluginRegistered = nativePluginRegistered,
                    epDeviceCount = qnnEpDeviceCount,
                    allEpDeviceCount = qnnEpDeviceCount,
                    ortVersion = detectedOrtVersion,
                    qnnPluginVersion = BuildConfig.QNN_PLUGIN_VERSION,
                    qairtSdkVersion = BuildConfig.QAIRT_SDK_VERSION,
                    qairtSdkBuildId = BuildConfig.QAIRT_SDK_BUILD_ID,
                    fastRpcDevices = fastRpcDevices,
                    error = error.message ?: error.javaClass.simpleName,
                )
            }
        Log.i(LOG_TAG, "status=${current.asMap()}")
        current
    }

    private fun prepareBundledRuntime(context: Context): Status {
        val knownFastRpcDevices = listOf(
            "/dev/fastrpc-cdsp",
            "/dev/fastrpc-cdsp-secure",
            "/dev/fastrpc-cdsp1",
            "/dev/fastrpc-cdsp2",
            "/dev/fastrpc-cdsp3",
        )
        val readableDevices = knownFastRpcDevices.filter { path ->
            runCatching { Os.access(path, OsConstants.R_OK) }.getOrDefault(false)
        }
        val enumeratedDevices = File("/dev").list()
            ?.asSequence()
            ?.filter { it.startsWith("fastrpc-") }
            ?.map { "/dev/$it" }
            ?.toList()
            .orEmpty()
        fastRpcDevices = (readableDevices + enumeratedDevices).distinct().sorted()
        val arch = BuildConfig.QNN_HTP_ARCH
        val skelName = "libQnnHtp${arch.uppercase()}Skel.so"
        val assetPath = "qnn/htp/$arch/$skelName"
        // Keep the HTP stub and skel from the same GenieX/QAIRT package. An
        // older asset skel paired with the AAR's stub can crash FastRPC.
        val nativeDirectory = File(context.applicationInfo.nativeLibraryDir)
        val nativeSkel = File(nativeDirectory, skelName)
        val fastRpcDirectory = if (nativeSkel.isFile) {
            nativeDirectory
        } else {
            extractSkel(context, assetPath, skelName)
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
        val gpuReady = runCatching {
            System.loadLibrary("QnnGpu")
            true
        }.getOrDefault(false)
        // Plugin EP registration is process-global inside ONNX Runtime. MOSS owns
        // the single native Ort::Env so Java and JNI cannot register the same EP.
        qnnEpDeviceCount = NativeMossRuntime.probeQnn(context)
        nativePluginRegistered = qnnEpDeviceCount > 0
        require(nativePluginRegistered) {
            "QNN plugin registered but exposed no QNN execution-provider devices"
        }
        return Status(
            bundled = true,
            ready = true,
            gpuReady = gpuReady,
            architecture = arch,
            fastRpcDirectory = fastRpcDirectory.absolutePath,
            pluginRegistered = true,
            epDeviceCount = qnnEpDeviceCount,
            allEpDeviceCount = qnnEpDeviceCount,
            ortVersion = detectedOrtVersion,
            qnnPluginVersion = BuildConfig.QNN_PLUGIN_VERSION,
            qairtSdkVersion = BuildConfig.QAIRT_SDK_VERSION,
            qairtSdkBuildId = BuildConfig.QAIRT_SDK_BUILD_ID,
            fastRpcDevices = fastRpcDevices,
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

    private const val LOG_TAG = "Talk2UQNN"
}
