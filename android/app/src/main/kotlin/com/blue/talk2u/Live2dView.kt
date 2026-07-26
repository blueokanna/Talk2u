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
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.plugin.common.StandardMessageCodec
import org.json.JSONObject

internal object GpuBackendProbe {
    private val loadError: String?
    private val loaded: Boolean
    private val cachedResult: JSONObject by lazy {
        if (!loaded) {
            JSONObject()
                .put("schemaVersion", 1)
                .put("preferredNativeBackend", "none")
                .put("error", loadError ?: "GPU probe library is unavailable")
        } else {
            runCatching { JSONObject(nativeProbe()) }.getOrElse { error ->
                JSONObject()
                    .put("schemaVersion", 1)
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
    private val channel = MethodChannel(messenger, "talk2u/live2d_$viewId")
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
        webView.webChromeClient = WebChromeClient()
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
                "file:///android_asset/flutter_assets/${modelPath.removePrefix("asset:///")}"
            modelPath.startsWith("http://") ||
                modelPath.startsWith("https://") ||
                modelPath.startsWith("file://") -> modelPath
            else -> Uri.fromFile(java.io.File(modelPath)).toString()
        }
        val page = "file:///android_asset/flutter_assets/assets/live2d/index.html" +
            "?model=${Uri.encode(modelUri)}"
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
