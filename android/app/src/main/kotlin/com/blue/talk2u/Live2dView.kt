package com.blue.talk2u

import android.annotation.SuppressLint
import android.app.ActivityManager
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.WebViewAssetLoader
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.plugin.common.StandardMessageCodec
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

private const val LIVE2D_CORE_URL =
    "https://cubism.live2d.com/sdk-web/cubismcore/live2dcubismcore.min.js"

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

class Live2dViewFactory(
    private val context: Context,
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context?, viewId: Int, args: Any?): PlatformView {
        val creationParams = args as? Map<*, *> ?: emptyMap<String, Any>()
        return Live2dView(this.context, messenger, viewId, creationParams)
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Suppress("DEPRECATION")
private class Live2dView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
    creationParams: Map<*, *>,
) : PlatformView, MethodChannel.MethodCallHandler {
    private val webView = WebView(context)
    private val userAgent = webView.settings.userAgentString
    private val coreCacheFile = File(context.filesDir, "live2d_runtime/live2dcubismcore.min.js")
    private val channel = MethodChannel(messenger, "talk2u/live2d_$viewId")
    private val assetLoader = WebViewAssetLoader.Builder()
        .addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(context))
        .addPathHandler("/files/", WebViewAssetLoader.InternalStoragePathHandler(context, context.filesDir))
        .build()
    private var lastStatus: String? = null
    private var disposed = false

    init {
        webView.setBackgroundColor(android.graphics.Color.TRANSPARENT)
        webView.setLayerType(View.LAYER_TYPE_HARDWARE, null)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            webView.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, false)
        }
        webView.settings.javaScriptEnabled = true
        webView.settings.allowFileAccess = true
        webView.settings.allowContentAccess = true
        webView.settings.domStorageEnabled = true
        webView.settings.mediaPlaybackRequiresUserGesture = false
        webView.settings.allowFileAccessFromFileURLs = true
        webView.settings.allowUniversalAccessFromFileURLs = true
        webView.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(
                view: WebView?,
                request: WebResourceRequest,
            ): WebResourceResponse? {
                if (request.url.toString() == LIVE2D_CORE_URL) {
                    return fetchLive2dCore()
                }
                return assetLoader.shouldInterceptRequest(request.url)
            }

            override fun onReceivedError(
                view: WebView?,
                request: WebResourceRequest?,
                error: WebResourceError?,
            ) {
                Log.e(
                    "Talk2U.Live2D",
                    "Resource failed: ${request?.url} (${error?.errorCode}) ${error?.description}",
                )
            }

            override fun onReceivedHttpError(
                view: WebView?,
                request: WebResourceRequest?,
                errorResponse: WebResourceResponse?,
            ) {
                Log.e(
                    "Talk2U.Live2D",
                    "HTTP failed: ${request?.url} (${errorResponse?.statusCode}) ${errorResponse?.reasonPhrase}",
                )
            }

            override fun onRenderProcessGone(
                view: WebView?,
                detail: RenderProcessGoneDetail?,
            ): Boolean {
                val reason = if (detail?.didCrash() == true) {
                    "Live2D 渲染进程异常退出"
                } else {
                    "设备内存不足，Live2D 渲染进程已被系统回收"
                }
                reportError(
                    message = reason,
                    failureCode = "webview-render-process-gone",
                    recoverable = true,
                )
                disposed = true
                view?.destroy()
                return true
            }
        }
        webView.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(consoleMessage: ConsoleMessage?): Boolean {
                Log.i(
                    "Talk2U.Live2D",
                    "${consoleMessage?.messageLevel()} ${consoleMessage?.sourceId()}:" +
                        "${consoleMessage?.lineNumber()} ${consoleMessage?.message()}",
                )
                return true
            }
        }
        webView.addJavascriptInterface(
            StatusBridge(
                onStatus = { message ->
                    lastStatus = message
                    channel.invokeMethod("status", message)
                },
                rendererCapabilities = { rendererCapabilities(context).toString() },
            ),
            "Talk2uNative",
        )
        channel.setMethodCallHandler(this)

        val modelPath = creationParams["modelPath"] as? String ?: ""
        val modelUri = when {
            modelPath.startsWith("asset:///") ->
                "https://${WebViewAssetLoader.DEFAULT_DOMAIN}/assets/flutter_assets/" +
                    modelPath.removePrefix("asset:///")
            modelPath.startsWith("http://") ||
                modelPath.startsWith("https://") ||
                modelPath.startsWith("file://") -> modelPath
            else -> {
                val modelFile = java.io.File(modelPath).canonicalFile
                val filesRoot = context.filesDir.canonicalFile
                if (modelFile.path.startsWith(filesRoot.path + java.io.File.separator)) {
                    val relative = modelFile.relativeTo(filesRoot).invariantSeparatorsPath
                    "https://${WebViewAssetLoader.DEFAULT_DOMAIN}/files/$relative"
                } else {
                    Uri.fromFile(modelFile).toString()
                }
            }
        }
        val hasLocalCore = runCatching {
            context.assets.open(
                "flutter_assets/assets/live2d/vendor/live2dcubismcore.min.js",
            ).use { }
            true
        }.getOrDefault(false)
        val page = "https://${WebViewAssetLoader.DEFAULT_DOMAIN}/assets/flutter_assets/" +
            "assets/live2d/index.html" +
            "?model=${Uri.encode(modelUri)}&localCore=${if (hasLocalCore) 1 else 0}"
        webView.loadUrl(page)
    }

    override fun getView(): View = webView

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setMouth" -> evaluate("Talk2UAvatar.setMouth(${call.argument<Double>("value") ?: 0.0})", result)
            "setSpeaking" -> {
                val value = call.argument<Boolean>("value") == true
                evaluate("Talk2UAvatar.setSpeaking($value)", result)
            }
            "motion" -> {
                val group = JSONObject.quote(call.argument<String>("group") ?: "TapBody")
                val index = call.argument<Int>("index") ?: 0
                evaluate("Talk2UAvatar.motion($group,$index)", result)
            }
            "expression" -> {
                val name = JSONObject.quote(call.argument<String>("name") ?: "")
                evaluate("Talk2UAvatar.expression($name)", result)
            }
            "perform" -> {
                val cue = JSONObject.quote(call.argument<String>("cue") ?: "neutral")
                evaluate("Talk2UAvatar.perform($cue)", result)
            }
            "resetExpression" -> evaluate("Talk2UAvatar.resetExpression()", result)
            "diagnostics" -> evaluate("Talk2UAvatar.diagnostics()", result)
            "getStatus" -> result.success(lastStatus)
            else -> result.notImplemented()
        }
    }

    private fun evaluate(script: String, result: MethodChannel.Result) {
        if (disposed) {
            result.error("live2d_unavailable", "Live2D 视图已经停止", null)
            return
        }
        try {
            webView.evaluateJavascript(script) { value -> result.success(value) }
        } catch (error: RuntimeException) {
            reportError(error.message ?: "Live2D 脚本执行失败")
            result.error("live2d_javascript_failed", error.message, null)
        }
    }

    private fun fetchLive2dCore(): WebResourceResponse {
        readCoreCache()?.let {
            Log.i("Talk2U.Live2D", "Cubism Core served from app-private cache")
            return coreResponse(it, "app-private-cache")
        }
        var lastFailure = "unknown error"
        repeat(2) { attempt ->
            var connection: HttpURLConnection? = null
            try {
                connection = URL(LIVE2D_CORE_URL).openConnection() as HttpURLConnection
                connection.connectTimeout = 7000
                connection.readTimeout = 12000
                connection.instanceFollowRedirects = true
                connection.useCaches = false
                connection.setRequestProperty("Accept", "application/javascript,text/javascript,*/*;q=0.8")
                connection.setRequestProperty("User-Agent", userAgent)
                val statusCode = connection.responseCode
                val response = if (statusCode in 200..299) {
                    connection.inputStream
                } else {
                    connection.errorStream
                }
                val bytes = response?.use { it.readBytes() } ?: ByteArray(0)
                if (statusCode in 200..299 && isValidCore(bytes)) {
                    writeCoreCache(bytes)
                    Log.i("Talk2U.Live2D", "Cubism Core fetched and cached on attempt ${attempt + 1}")
                    return coreResponse(bytes, "official-live2d-cdn")
                }
                lastFailure = "HTTP $statusCode ${connection.responseMessage.orEmpty()}"
            } catch (error: Exception) {
                lastFailure = error.message ?: error.javaClass.simpleName
                Log.w("Talk2U.Live2D", "Cubism Core fetch attempt ${attempt + 1} failed", error)
            } finally {
                connection?.disconnect()
            }
        }
        val message = "Android HTTPS fallback failed after retry: $lastFailure"
        Log.e("Talk2U.Live2D", message)
        return WebResourceResponse(
            "text/plain",
            "UTF-8",
            502,
            "Bad Gateway",
            emptyMap(),
            ByteArrayInputStream(message.toByteArray(Charsets.UTF_8)),
        )
    }

    private fun readCoreCache(): ByteArray? = runCatching {
        if (!coreCacheFile.isFile) return@runCatching null
        coreCacheFile.readBytes().takeIf(::isValidCore)
    }.getOrNull()

    private fun writeCoreCache(bytes: ByteArray) {
        runCatching {
            coreCacheFile.parentFile?.mkdirs()
            val temporary = File(coreCacheFile.parentFile, "${coreCacheFile.name}.tmp")
            temporary.writeBytes(bytes)
            if (!temporary.renameTo(coreCacheFile)) {
                temporary.copyTo(coreCacheFile, overwrite = true)
                temporary.delete()
            }
        }.onFailure { Log.w("Talk2U.Live2D", "Unable to persist Cubism Core cache", it) }
    }

    private fun isValidCore(bytes: ByteArray): Boolean =
        bytes.size > 1024 && bytes.toString(Charsets.UTF_8).contains("Live2DCubismCore")

    private fun coreResponse(bytes: ByteArray, source: String): WebResourceResponse =
        WebResourceResponse(
            "application/javascript",
            "UTF-8",
            200,
            "OK",
            mapOf(
                "Access-Control-Allow-Origin" to "*",
                "Cache-Control" to "private, max-age=31536000, immutable",
                "X-Talk2U-Core-Source" to source,
            ),
            ByteArrayInputStream(bytes),
        )

    private fun reportError(
        message: String,
        failureCode: String? = null,
        recoverable: Boolean = false,
    ) {
        val status = JSONObject()
            .put("type", "error")
            .put("message", message)
            .put("recoverable", recoverable)
        if (failureCode != null) status.put("failureCode", failureCode)
        val payload = status
            .toString()
        lastStatus = payload
        channel.invokeMethod("status", payload)
    }

    private fun rendererCapabilities(context: Context): JSONObject {
        val packageManager = context.packageManager
        val features = packageManager.systemAvailableFeatures.orEmpty()
        val vulkanLevel = features.firstOrNull {
            it.name == PackageManager.FEATURE_VULKAN_HARDWARE_LEVEL
        }?.version ?: 0
        val vulkanVersion = features.firstOrNull {
            it.name == PackageManager.FEATURE_VULKAN_HARDWARE_VERSION
        }?.version ?: 0
        val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val webViewVersion = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WebView.getCurrentWebViewPackage()?.versionName.orEmpty()
        } else {
            ""
        }
        return JSONObject()
            .put("viewHardwareAccelerated", webView.isHardwareAccelerated)
            .put(
                "applicationHardwareAccelerationRequested",
                context.applicationInfo.flags and ApplicationInfo.FLAG_HARDWARE_ACCELERATED != 0,
            )
            .put("vulkanAdvertised", vulkanLevel > 0 || vulkanVersion > 0)
            .put("vulkanLevel", vulkanLevel)
            .put("vulkanVersion", vulkanVersion)
            .put("requiredGlEsVersion", activityManager?.deviceConfigurationInfo?.reqGlEsVersion ?: 0)
            .put("webViewVersion", webViewVersion)
            .put("nativeProbe", GpuBackendProbe.diagnostics())
    }

    override fun dispose() {
        channel.setMethodCallHandler(null)
        webView.removeJavascriptInterface("Talk2uNative")
        if (!disposed) {
            disposed = true
            webView.onPause()
            webView.stopLoading()
            webView.loadUrl("about:blank")
            webView.destroy()
        }
    }
}

private class StatusBridge(
    private val onStatus: (String) -> Unit,
    private val rendererCapabilities: () -> String,
) {
    private val mainHandler = Handler(Looper.getMainLooper())

    @JavascriptInterface
    fun postMessage(message: String) {
        mainHandler.post { onStatus(message) }
    }

    @JavascriptInterface
    fun getRendererCapabilities(): String = rendererCapabilities()
}
