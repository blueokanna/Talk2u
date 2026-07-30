package com.blue.talk2u

import android.content.Context
import android.content.res.AssetManager
import android.graphics.SurfaceTexture
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import android.util.Log
import android.view.Choreographer
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

internal object GpuBackendProbe {
    private val loadError: String?
    private val loaded: Boolean
    private val cachedResult: JSONObject by lazy {
        if (!loaded) {
            JSONObject()
                .put("schemaVersion", 2)
                .put("preferredNativeBackend", "none")
                .put("error", loadError ?: "GPU probe library is unavailable")
        } else {
            runCatching { JSONObject(nativeProbe()) }.getOrElse { error ->
                JSONObject()
                    .put("schemaVersion", 2)
                    .put("preferredNativeBackend", "none")
                    .put("error", error.message ?: "GPU probe failed")
            }
        }
    }

    init {
        var failure: String? = null
        loaded = try {
            System.loadLibrary("talk2u_gpu_probe")
            true
        } catch (error: UnsatisfiedLinkError) {
            failure = error.message
            false
        }
        loadError = failure
    }

    private external fun nativeProbe(): String

    fun diagnostics(): JSONObject = JSONObject(cachedResult.toString())
}

internal object Live2dNativeBridge {
    init {
        System.loadLibrary("talk2u_live2d")
    }

    external fun nativeCreate(
        assets: AssetManager,
        modelPath: String,
        backgroundColor: Int,
    ): Long
    external fun nativePrepare(handle: Long)
    external fun nativeSurfaceCreated(
        handle: Long,
        surface: Surface,
        width: Int,
        height: Int,
    )
    external fun nativeSurfaceChanged(handle: Long, width: Int, height: Int)
    external fun nativeSurfaceDestroyed(handle: Long)
    external fun nativeDrawFrame(handle: Long): Boolean
    external fun nativeSetMouth(handle: Long, value: Float)
    external fun nativeSetSpeaking(handle: Long, value: Boolean)
    external fun nativeMotion(handle: Long, group: String, index: Int)
    external fun nativeExpression(handle: Long, name: String)
    external fun nativeResetExpression(handle: Long)
    external fun nativeDiagnostics(handle: Long): String
    external fun nativeDestroy(handle: Long)
}

class Live2dViewFactory(
    private val context: Context,
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context?, viewId: Int, args: Any?): PlatformView {
        val creationParams = args as? Map<*, *> ?: emptyMap<String, Any>()
        return Live2dView(this.context, messenger, viewId, creationParams)
    }
}

private data class Live2dCue(
    val group: String?,
    val index: Int,
    val expression: String?,
)

private object Live2dViewCoordinator {
    private var active: Live2dView? = null

    @Synchronized
    fun activate(view: Live2dView) {
        if (active === view) return
        active?.retireForReplacement()
        active = view
    }

    @Synchronized
    fun release(view: Live2dView) {
        if (active === view) active = null
    }
}

private class ManagedLive2dVulkanTextureView(
    context: Context,
    private val callbacks: Callbacks,
) : TextureView(context), TextureView.SurfaceTextureListener {
    interface Callbacks {
        fun onSurfaceCreated(surface: Surface, width: Int, height: Int)
        fun onSurfaceChanged(width: Int, height: Int)
        fun onSurfaceDestroyed()
        fun onDrawFrame()
        fun onDetached()
    }

    private val renderThread = HandlerThread("talk2u-live2d-vulkan").apply { start() }
    private val renderHandler = Handler(renderThread.looper)
    @Volatile private var resumed = true
    @Volatile private var attached = false
    @Volatile private var stopped = false
    private var frameScheduled = false
    @Volatile private var nativeSurfaceCreated = false
    private var activeSurfaceTexture: SurfaceTexture? = null
    private var activeSurface: Surface? = null
    private lateinit var choreographer: Choreographer
    private val frameCallback = Choreographer.FrameCallback {
        frameScheduled = false
        if (!stopped && resumed && nativeSurfaceCreated) callbacks.onDrawFrame()
        scheduleFrame()
    }

    init {
        isOpaque = true
        surfaceTextureListener = this
        renderHandler.post {
            choreographer = Choreographer.getInstance()
            scheduleFrame()
        }
    }

    fun queueEvent(action: () -> Unit) {
        if (!stopped) renderHandler.post(action)
    }

    fun onResume() {
        resumed = true
        renderHandler.post(::scheduleFrame)
    }

    fun hasNativeSurface(): Boolean = nativeSurfaceCreated

    fun onPause() {
        resumed = false
        renderHandler.post {
            if (::choreographer.isInitialized && frameScheduled) {
                choreographer.removeFrameCallback(frameCallback)
                frameScheduled = false
            }
        }
    }

    private fun scheduleFrame() {
        if (stopped || !resumed || !attached || !nativeSurfaceCreated || frameScheduled ||
            !::choreographer.isInitialized
        ) return
        frameScheduled = true
        choreographer.postFrameCallback(frameCallback)
    }

    override fun onSurfaceTextureAvailable(texture: SurfaceTexture, width: Int, height: Int) {
        val surface = Surface(texture)
        renderHandler.post {
            if (stopped || !surface.isValid) {
                surface.release()
                return@post
            }
            releaseActiveSurface()
            activeSurfaceTexture = texture
            activeSurface = surface
            callbacks.onSurfaceCreated(surface, width.coerceAtLeast(1), height.coerceAtLeast(1))
            nativeSurfaceCreated = true
            scheduleFrame()
        }
    }

    override fun onSurfaceTextureSizeChanged(texture: SurfaceTexture, width: Int, height: Int) {
        renderHandler.post {
            if (!stopped && nativeSurfaceCreated && activeSurfaceTexture === texture) {
                callbacks.onSurfaceChanged(width.coerceAtLeast(1), height.coerceAtLeast(1))
                scheduleFrame()
            }
        }
    }

    override fun onSurfaceTextureDestroyed(texture: SurfaceTexture): Boolean {
        renderHandler.post {
            if (activeSurfaceTexture === texture) {
                releaseActiveSurface()
            }
        }
        return true
    }

    override fun onSurfaceTextureUpdated(texture: SurfaceTexture) = Unit

    private fun releaseActiveSurface() {
        if (nativeSurfaceCreated) callbacks.onSurfaceDestroyed()
        nativeSurfaceCreated = false
        activeSurfaceTexture = null
        activeSurface?.release()
        activeSurface = null
        if (::choreographer.isInitialized && frameScheduled) {
            choreographer.removeFrameCallback(frameCallback)
            frameScheduled = false
        }
    }

    fun shutdown() {
        if (stopped) return
        stopped = true
        resumed = false
        renderHandler.post {
            releaseActiveSurface()
            renderThread.quitSafely()
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        attached = true
        renderHandler.post(::scheduleFrame)
    }

    override fun onDetachedFromWindow() {
        attached = false
        renderHandler.post {
            if (::choreographer.isInitialized && frameScheduled) {
                choreographer.removeFrameCallback(frameCallback)
                frameScheduled = false
            }
        }
        callbacks.onDetached()
        super.onDetachedFromWindow()
    }
}

private class ResourceUsageSampler {
    private var previousCpuTicks: Long? = null
    private var previousElapsedNanos: Long? = null
    private val clockTicksPerSecond = runCatching {
        Os.sysconf(OsConstants._SC_CLK_TCK).coerceAtLeast(1L)
    }.getOrDefault(100L)

    fun sample(): JSONObject {
        val result = JSONObject()
        result.put("cpu", sampleCpu())
        result.put("gpu", sampleGpu())
        result.put(
            "npu",
            JSONObject()
                .put("available", false)
                .put("scope", "device")
                .put("reason", "Android and QNN do not expose global NPU utilization to applications"),
        )
        result.put("sampledAtElapsedMs", SystemClock.elapsedRealtime())
        return result
    }

    private fun sampleCpu(): JSONObject {
        val now = SystemClock.elapsedRealtimeNanos()
        val ticks = runCatching {
            val stat = File("/proc/self/stat").readText(Charsets.US_ASCII)
            val fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ')
            fields[11].toLong() + fields[12].toLong()
        }.getOrNull()
        val previousTicks = previousCpuTicks
        val previousTime = previousElapsedNanos
        previousCpuTicks = ticks
        previousElapsedNanos = now
        val output = JSONObject().put("scope", "process").put("source", "/proc/self/stat")
        if (ticks == null || previousTicks == null || previousTime == null || now <= previousTime) {
            return output.put("available", false)
        }
        val elapsedSeconds = (now - previousTime).toDouble() / 1_000_000_000.0
        val cpuSeconds = (ticks - previousTicks).coerceAtLeast(0L).toDouble() / clockTicksPerSecond
        val capacity = Runtime.getRuntime().availableProcessors().coerceAtLeast(1)
        val percent = (cpuSeconds / elapsedSeconds * 100.0 / capacity).coerceIn(0.0, 100.0)
        return output.put("available", true).put("percent", percent)
    }

    private fun sampleGpu(): JSONObject {
        val candidates = listOf(
            "/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage",
            "/sys/devices/platform/soc/3d00000.qcom,kgsl-3d0/kgsl/kgsl-3d0/gpu_busy_percentage",
        )
        for (path in candidates) {
            val value = runCatching {
                Regex("[0-9]+(?:\\.[0-9]+)?")
                    .find(File(path).readText(Charsets.US_ASCII))
                    ?.value
                    ?.toDouble()
            }.getOrNull() ?: continue
            return JSONObject()
                .put("available", true)
                .put("scope", "device")
                .put("source", path)
                .put("percent", value.coerceIn(0.0, 100.0))
        }
        return JSONObject()
            .put("available", false)
            .put("scope", "device")
            .put("reason", "GPU utilization sysfs is not readable by this application")
    }
}

private class Live2dView(
    private val context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
    creationParams: Map<*, *>,
) : PlatformView, MethodChannel.MethodCallHandler, DefaultLifecycleObserver {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "talk2u/live2d_$viewId")
    private val modelPath = validateModelPath(creationParams["modelPath"] as? String)
    private val backgroundColor =
        (creationParams["backgroundColor"] as? Number)?.toInt() ?: 0xffffffff.toInt()
    private val cues = loadCues(modelPath)
    private val resourceUsageSampler = ResourceUsageSampler().also { it.sample() }
    private val container = FrameLayout(context)
    private val preparationExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "talk2u-live2d-prepare").apply {
            priority = Thread.NORM_PRIORITY - 1
        }
    }
    private val lifecycleOwner = context as? LifecycleOwner
    @Volatile private var renderView: ManagedLive2dVulkanTextureView? = null
    @Volatile private var nativeHandle = 0L
    @Volatile private var disposed = false
    @Volatile private var retired = false
    @Volatile private var failed = false
    @Volatile private var lastStatus: String? = null
    @Volatile private var surfaceReady = false

    init {
        channel.setMethodCallHandler(this)
        lifecycleOwner?.lifecycle?.addObserver(this)
        Live2dViewCoordinator.activate(this)
        preparationExecutor.execute(::prepareNativeRenderer)
    }

    override fun getView(): View = container

    override fun onResume(owner: LifecycleOwner) {
        if (!disposed && !retired) {
            renderView?.onResume()
            surfaceReady = !failed && nativeHandle > 0 && renderView?.hasNativeSurface() == true
        }
    }

    override fun onPause(owner: LifecycleOwner) {
        surfaceReady = false
        renderView?.onPause()
    }

    override fun onDestroy(owner: LifecycleOwner) {
        dispose()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setMouth" -> enqueue(result) { handle ->
                Live2dNativeBridge.nativeSetMouth(
                    handle,
                    (call.argument<Double>("value") ?: 0.0).toFloat(),
                )
            }
            "setSpeaking" -> enqueue(result) { handle ->
                Live2dNativeBridge.nativeSetSpeaking(
                    handle,
                    call.argument<Boolean>("value") == true,
                )
            }
            "motion" -> enqueue(result) { handle ->
                Live2dNativeBridge.nativeMotion(
                    handle,
                    call.argument<String>("group").orEmpty(),
                    call.argument<Int>("index") ?: 0,
                )
            }
            "expression" -> enqueue(result) { handle ->
                Live2dNativeBridge.nativeExpression(
                    handle,
                    call.argument<String>("name").orEmpty(),
                )
            }
            "perform" -> perform(call.argument<String>("cue").orEmpty(), result)
            "resetExpression" -> enqueue(result) { handle ->
                Live2dNativeBridge.nativeResetExpression(handle)
            }
            "diagnostics" -> diagnostics(result)
            "getStatus" -> result.success(lastStatus)
            else -> result.notImplemented()
        }
    }

    private fun perform(name: String, result: MethodChannel.Result) {
        val cue = cues[name]
        if (cue == null) {
            result.success(null)
            return
        }
        enqueue(result) { handle ->
            cue.group?.let { Live2dNativeBridge.nativeMotion(handle, it, cue.index) }
            cue.expression?.let { Live2dNativeBridge.nativeExpression(handle, it) }
        }
    }

    private fun enqueue(result: MethodChannel.Result, action: (Long) -> Unit) {
        val handle = nativeHandle
        val view = renderView
        if (disposed || retired || failed || handle <= 0 || view == null) {
            result.error("live2d_unavailable", "Cubism Native renderer is unavailable", null)
            return
        }
        view.queueEvent {
            runCatching { action(handle) }.fold(
                onSuccess = { mainHandler.post { result.success(null) } },
                onFailure = { error ->
                    reportError(error, true)
                    mainHandler.post {
                        result.error(
                            "live2d_native_operation_failed",
                            error.message ?: error.javaClass.simpleName,
                            null,
                        )
                    }
                },
            )
        }
    }

    private fun diagnostics(result: MethodChannel.Result) {
        val handle = nativeHandle
        if (disposed || handle <= 0) {
            result.error("live2d_unavailable", "Cubism Native renderer is unavailable", null)
            return
        }
        runCatching { mergedDiagnostics(handle).toString() }.fold(
            onSuccess = result::success,
            onFailure = {
                result.error(
                    "live2d_diagnostics_failed",
                    it.message ?: it.javaClass.simpleName,
                    null,
                )
            },
        )
    }

    private fun mergedDiagnostics(handle: Long): JSONObject {
        val details = JSONObject(Live2dNativeBridge.nativeDiagnostics(handle))
        val rendererDetails = details.getJSONObject("renderer")
        val platform = rendererDetails.optJSONObject("platform") ?: JSONObject().also {
            rendererDetails.put("platform", it)
        }
        platform.put("nativeProbe", GpuBackendProbe.diagnostics())
        val resourceUsage = resourceUsageSampler.sample()
        val systemGpu = resourceUsage.getJSONObject("gpu")
        val glGpu = rendererDetails.optJSONObject("gpuTiming")
        val vulkanGpu = platform
            .optJSONObject("vulkanInterop")
            ?.optJSONObject("gpuTiming")
        val rendererGpu = when {
            glGpu?.optBoolean("available") == true -> glGpu
            vulkanGpu?.optBoolean("available") == true -> vulkanGpu
            else -> null
        }
        if (!systemGpu.optBoolean("available") && rendererGpu?.optBoolean("available") == true) {
            resourceUsage.put("gpu", rendererGpu)
        }
        details.put("resourceUsage", resourceUsage)
        return details
    }

    private fun reportReady(handle: Long) {
        runCatching { mergedDiagnostics(handle).toString() }.fold(
            onSuccess = { status ->
                lastStatus = status
                mainHandler.post {
                    if (!disposed && !retired) {
                        renderView?.alpha = 1f
                        channel.invokeMethod("status", status)
                    }
                }
            },
            onFailure = { reportError(it, true) },
        )
    }

    private fun reportError(error: Throwable, recoverable: Boolean) {
        Log.e("Talk2U.Live2D", "Cubism Native renderer failed", error)
        failed = true
        val status = JSONObject()
            .put("type", "error")
            .put("message", error.message ?: error.javaClass.simpleName)
            .put("failureCode", "cubism-native-renderer-failed")
            .put("recoverable", recoverable)
            .toString()
        lastStatus = status
        mainHandler.post {
            if (!disposed && !retired) channel.invokeMethod("status", status)
        }
    }

    override fun dispose() {
        if (disposed) return
        disposed = true
        Live2dViewCoordinator.release(this)
        lifecycleOwner?.lifecycle?.removeObserver(this)
        channel.setMethodCallHandler(null)
        destroyNativeRenderer(renderView)
        preparationExecutor.shutdownNow()
        renderView = null
        container.removeAllViews()
    }

    fun retireForReplacement() {
        if (disposed || retired) return
        retired = true
        channel.setMethodCallHandler(null)
        destroyNativeRenderer(renderView)
        preparationExecutor.shutdownNow()
        renderView = null
        container.removeAllViews()
    }

    private fun destroyNativeRenderer(view: ManagedLive2dVulkanTextureView?) {
        val handle = nativeHandle
        if (handle <= 0) return
        nativeHandle = 0
        surfaceReady = false
        if (view == null) {
            runCatching { Live2dNativeBridge.nativeDestroy(handle) }
                .onFailure { Log.w("Talk2U.Live2D", "Cubism session release failed", it) }
            return
        }
        val released = CountDownLatch(1)
        runCatching {
            view.queueEvent {
                try {
                    runCatching {
                        Live2dNativeBridge.nativeSurfaceDestroyed(handle)
                        Live2dNativeBridge.nativeDestroy(handle)
                    }.onFailure {
                        Log.w("Talk2U.Live2D", "Cubism session release failed", it)
                    }
                } finally {
                    released.countDown()
                }
            }
            check(released.await(3, TimeUnit.SECONDS)) {
                "Timed out while releasing the Cubism Vulkan resources"
            }
            view.onPause()
            view.shutdown()
        }.onFailure {
            Log.e("Talk2U.Live2D", "Cubism Vulkan-thread release failed", it)
        }
    }

    private fun prepareNativeRenderer() {
        var handle = 0L
        runCatching {
            handle = Live2dNativeBridge.nativeCreate(
                context.assets,
                modelPath,
                backgroundColor,
            )
            check(handle > 0) { "Cubism Native session creation failed" }
            Live2dNativeBridge.nativePrepare(handle)
        }.fold(
            onSuccess = {
                mainHandler.post {
                    if (disposed || retired) {
                        Live2dNativeBridge.nativeDestroy(handle)
                    } else {
                        nativeHandle = handle
                        attachGlView()
                    }
                }
            },
            onFailure = { error ->
                if (handle > 0) Live2dNativeBridge.nativeDestroy(handle)
                reportError(error, false)
            },
        )
    }

    private fun attachGlView() {
        val view = ManagedLive2dVulkanTextureView(
            context,
            object : ManagedLive2dVulkanTextureView.Callbacks {
            override fun onSurfaceCreated(surface: Surface, width: Int, height: Int) {
                val handle = nativeHandle
                if (disposed || handle <= 0) return
                runCatching {
                    Live2dNativeBridge.nativeSurfaceCreated(handle, surface, width, height)
                }
                    .onSuccess {
                        surfaceReady = true
                        failed = false
                    }
                    .onFailure { reportError(it, true) }
            }

            override fun onSurfaceChanged(width: Int, height: Int) {
                val handle = nativeHandle
                if (disposed || failed || handle <= 0) return
                runCatching { Live2dNativeBridge.nativeSurfaceChanged(handle, width, height) }
                    .onFailure { reportError(it, true) }
            }

            override fun onSurfaceDestroyed() {
                surfaceReady = false
                val handle = nativeHandle
                if (handle <= 0) return
                runCatching { Live2dNativeBridge.nativeSurfaceDestroyed(handle) }
                    .onFailure { reportError(it, true) }
            }

            override fun onDrawFrame() {
                val handle = nativeHandle
                if (disposed || failed || !surfaceReady || handle <= 0) return
                runCatching {
                    if (Live2dNativeBridge.nativeDrawFrame(handle)) reportReady(handle)
                }.onFailure { reportError(it, true) }
            }

            override fun onDetached() {
                // Detaching a hybrid PlatformView does not necessarily destroy
                // its SurfaceTexture. onSurfaceDestroyed is the only event
                // that invalidates the native EGL/Vulkan target.
            }
            },
        ).apply { alpha = 0f }
        renderView = view
        container.addView(
            view,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
    }

    private fun validateModelPath(value: String?): String {
        require(!value.isNullOrBlank()) { "Live2D model path is empty" }
        if (value.startsWith("asset:///")) {
            val relative = value.removePrefix("asset:///").replace('\\', '/')
            require(relative.endsWith(".model3.json", true)) {
                "Live2D asset must be a model3.json file"
            }
            require(relative.split('/').none { it == ".." }) {
                "Live2D asset path is unsafe"
            }
            return "asset:///$relative"
        }
        val uri = Uri.parse(value)
        val rawPath = if (uri.scheme.equals("file", true)) uri.path else value
        val modelFile = File(requireNotNull(rawPath)).canonicalFile
        val dataRoot = File(context.applicationInfo.dataDir).canonicalFile
        require(modelFile.isFile && modelFile.name.endsWith(".model3.json", true)) {
            "Live2D model3.json file is missing"
        }
        require(modelFile.path.startsWith(dataRoot.path + File.separator)) {
            "Live2D model must be stored in the application private directory"
        }
        return modelFile.path
    }

    private fun loadCues(path: String): Map<String, Live2dCue> {
        val raw = runCatching {
            if (path.startsWith("asset:///")) {
                val relative = path.removePrefix("asset:///")
                val directory = relative.substringBeforeLast('/', "")
                context.assets.open("flutter_assets/$directory/talk2u.avatar.json")
                    .bufferedReader(Charsets.UTF_8)
                    .use { it.readText() }
            } else {
                File(File(path).parentFile, "talk2u.avatar.json").readText(Charsets.UTF_8)
            }
        }.getOrNull() ?: return mapOf("neutral" to Live2dCue("Idle", 0, null))
        val root = runCatching { JSONObject(raw) }.getOrNull() ?: return emptyMap()
        val definitions = root.optJSONObject("cues") ?: return emptyMap()
        val output = LinkedHashMap<String, Live2dCue>()
        for (name in definitions.keys()) {
            val cue = definitions.optJSONObject(name) ?: continue
            val motion = cue.optJSONObject("motion")
            val group = motion?.optString("group")?.takeIf { it.isNotEmpty() || motion.has("group") }
            val index = motion?.optInt("index", 0) ?: 0
            val expression = cue.optString("expression").takeIf(String::isNotBlank)
            if (group != null || expression != null) {
                output[name] = Live2dCue(group, index, expression)
            }
        }
        return output
    }
}
