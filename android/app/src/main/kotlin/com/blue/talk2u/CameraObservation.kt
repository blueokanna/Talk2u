package com.blue.talk2u

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.Rect
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.view.Surface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** Local, opt-in face presence only. This does not identify people or establish liveness.
 * All state and camera callbacks belong to the main looper. Image buffers are only drained
 * and closed on a worker; pixels are never read, persisted, or sent through Flutter.
 */
class CameraObservation(private val activity: Activity, messenger: BinaryMessenger) {
    companion object {
        const val PERMISSION_REQUEST = 48120
        private const val EVENT_INTERVAL_MS = 200L
        private const val START_TIMEOUT_MS = 10_000L
        private const val METADATA_TIMEOUT_MS = 5_000L
    }

    private val main = Handler(Looper.getMainLooper())
    private val methods = MethodChannel(messenger, "talk2u/camera_observation")
    private val events = EventChannel(messenger, "talk2u/camera_observation/events")
    private var sink: EventChannel.EventSink? = null
    private var foreground = false
    private var closed = false
    private var desired = false
    private var permissionPending = false
    private var generation = 0
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null
    private var imageThread: HandlerThread? = null
    private var lastEventAt = 0L
    private var lastMetadataAt = 0L
    private var timeout: Runnable? = null
    private var sequence = 0L
    private var latest: Map<String, Any?> = state("idle")

    init {
        methods.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> result.success(start())
                "stop" -> result.success(stop())
                else -> result.notImplemented()
            }
        }
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sink = events
                events?.success(latest)
            }
            override fun onCancel(arguments: Any?) {
                sink = null
                stop("listener_detached")
            }
        })
    }

    fun onResume() { if (!closed) foreground = true }

    /** Never restarts automatically on resume, including after a permission dialog. */
    fun onPause() {
        foreground = false
        stop("background")
    }

    fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        if (!permissionPending) return true
        permissionPending = false
        if (closed) return true
        val index = permissions.indexOf(Manifest.permission.CAMERA)
        val granted = index >= 0 && grantResults.getOrNull(index) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            desired = false
            releaseCamera()
            publish(state("permissionDenied", "camera_permission_denied"))
        } else if (desired && foreground) {
            openCamera()
        } else {
            publish(state("stopped", "permission_granted_tap_to_start"))
        }
        return true
    }

    fun start(): Map<String, Any?> {
        if (closed) return state("error", "closed")
        if (!foreground || activity.isFinishing || activity.isDestroyed) {
            publish(state("stopped", "background"))
            return latest
        }
        if (desired) return latest
        desired = true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            activity.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            publish(state("requestingPermission"))
            if (!permissionPending) {
                permissionPending = true
                try {
                    activity.requestPermissions(arrayOf(Manifest.permission.CAMERA), PERMISSION_REQUEST)
                } catch (_: RuntimeException) {
                    permissionPending = false
                    fail("error", "permission_request_failed")
                }
            }
        } else {
            openCamera()
        }
        return latest
    }

    fun stop(reason: String = "user"): Map<String, Any?> {
        desired = false
        releaseCamera()
        if (!closed) publish(state("stopped", reason))
        return latest
    }

    fun close() {
        if (closed) return
        stop("closed")
        closed = true
        sink = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    private fun openCamera() {
        if (!desired || !foreground || closed) return
        releaseCamera()
        val token = generation
        publish(state("starting"))
        try {
            val manager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            // Do not silently use the rear camera: this feature observes the consenting user.
            val candidate = manager.cameraIdList.map { it to manager.getCameraCharacteristics(it) }
                .firstOrNull { (_, c) ->
                    c.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT &&
                        (c.get(CameraCharacteristics.STATISTICS_INFO_MAX_FACE_COUNT) ?: 0) > 0 &&
                        c.get(CameraCharacteristics.STATISTICS_INFO_AVAILABLE_FACE_DETECT_MODES)
                            ?.any { it == CaptureRequest.STATISTICS_FACE_DETECT_MODE_SIMPLE ||
                                it == CaptureRequest.STATISTICS_FACE_DETECT_MODE_FULL } == true
                }
            if (candidate == null) {
                fail("unsupported", "front_camera_hardware_face_detection_unavailable")
                return
            }
            val (id, characteristics) = candidate
            val modes = characteristics.get(CameraCharacteristics.STATISTICS_INFO_AVAILABLE_FACE_DETECT_MODES)!!
            // SIMPLE supplies bounds without tracking identifiers or face landmarks.
            val mode = if (modes.contains(CaptureRequest.STATISTICS_FACE_DETECT_MODE_SIMPLE))
                CaptureRequest.STATISTICS_FACE_DETECT_MODE_SIMPLE else CaptureRequest.STATISTICS_FACE_DETECT_MODE_FULL
            val activeArray = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
            val sizes = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                ?.getOutputSizes(ImageFormat.YUV_420_888)
            val size = sizes?.filter { it.width > 0 && it.height > 0 }?.minByOrNull { it.width.toLong() * it.height }
            if (activeArray == null || size == null) {
                fail("unsupported", "camera_metadata_or_output_unavailable")
                return
            }
            val sensorOrientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
            val worker = HandlerThread("talk2u-camera-drain").also { it.start() }
            imageThread = worker
            val output = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 2)
            reader = output
            output.setOnImageAvailableListener({ images ->
                // A close may race this callback. No image plane is accessed.
                try { images.acquireLatestImage()?.close() } catch (_: IllegalStateException) { }
            }, Handler(worker.looper))
            val openingTimeout = Runnable {
                if (isCurrent(token)) fail("error", "camera_start_timeout")
            }
            timeout = openingTimeout
            main.postDelayed(openingTimeout, START_TIMEOUT_MS)
            manager.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    if (!isCurrent(token)) { camera.close(); return }
                    device = camera
                    try {
                        @Suppress("DEPRECATION")
                        camera.createCaptureSession(listOf(output.surface), object : CameraCaptureSession.StateCallback() {
                            override fun onConfigured(configured: CameraCaptureSession) {
                                if (!isCurrent(token)) { configured.close(); return }
                                session = configured
                                try {
                                    val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                                        addTarget(output.surface)
                                        set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                                        set(CaptureRequest.STATISTICS_FACE_DETECT_MODE, mode)
                                        set(CaptureRequest.SCALER_CROP_REGION, activeArray)
                                    }.build()
                                    configured.setRepeatingRequest(request, object : CameraCaptureSession.CaptureCallback() {
                                        override fun onCaptureCompleted(s: CameraCaptureSession, r: CaptureRequest, result: TotalCaptureResult) {
                                            if (!isCurrent(token)) return
                                            observe(result, activeArray, sensorOrientation)
                                        }
                                    }, main)
                                    timeout?.let(main::removeCallbacks)
                                    lastMetadataAt = SystemClock.elapsedRealtime()
                                    armMetadataWatchdog(token)
                                } catch (_: Exception) {
                                    if (isCurrent(token)) fail("error", "capture_start_failed")
                                }
                            }
                            override fun onConfigureFailed(configured: CameraCaptureSession) {
                                configured.close()
                                if (isCurrent(token)) fail("error", "camera_session_failed")
                            }
                        }, main)
                    } catch (_: Exception) {
                        if (isCurrent(token)) fail("error", "camera_session_failed")
                    }
                }
                override fun onDisconnected(camera: CameraDevice) {
                    camera.close()
                    if (isCurrent(token)) fail("error", "camera_disconnected")
                }
                override fun onError(camera: CameraDevice, error: Int) {
                    camera.close()
                    if (isCurrent(token)) fail("error", "camera_device_error_$error")
                }
            }, main)
        } catch (_: SecurityException) {
            fail("permissionDenied", "camera_permission_denied")
        } catch (_: Exception) {
            fail("error", "camera_unavailable")
        }
    }

    private fun armMetadataWatchdog(token: Int) {
        val watchdog = object : Runnable {
            override fun run() {
                if (!isCurrent(token)) return
                if (SystemClock.elapsedRealtime() - lastMetadataAt >= METADATA_TIMEOUT_MS) {
                    fail("unsupported", "hardware_face_metadata_unavailable")
                } else main.postDelayed(this, 1_000L)
            }
        }
        timeout = watchdog
        main.postDelayed(watchdog, 1_000L)
    }

    private fun observe(result: TotalCaptureResult, activeArray: Rect, sensorOrientation: Int) {
        val now = SystemClock.elapsedRealtime()
        val faces = result.get(CaptureResult.STATISTICS_FACES) ?: return
        val appliedMode = result.get(CaptureResult.STATISTICS_FACE_DETECT_MODE)
        if (appliedMode != CaptureResult.STATISTICS_FACE_DETECT_MODE_SIMPLE &&
            appliedMode != CaptureResult.STATISTICS_FACE_DETECT_MODE_FULL) return
        lastMetadataAt = now
        if (lastEventAt != 0L && now - lastEventAt < EVENT_INTERVAL_MS) return
        lastEventAt = now
        val crop = result.get(CaptureResult.SCALER_CROP_REGION) ?: activeArray
        if (crop.width() <= 0 || crop.height() <= 0) return
        val visible = faces.filter { it.score > 0 && Rect.intersects(it.bounds, crop) }
        val largest = visible.maxByOrNull { it.bounds.width().toLong() * it.bounds.height() }
        val primary = largest?.let {
            val bounds = it.bounds
            val x = ((bounds.exactCenterX() - crop.left) / crop.width()).toDouble().coerceIn(0.0, 1.0)
            val y = ((bounds.exactCenterY() - crop.top) / crop.height()).toDouble().coerceIn(0.0, 1.0)
            @Suppress("DEPRECATION")
            val rotation = activity.windowManager.defaultDisplay.rotation
            val degrees = when (rotation) { Surface.ROTATION_90 -> 90; Surface.ROTATION_180 -> 180; Surface.ROTATION_270 -> 270; else -> 0 }
            // Front-facing preview: rotate to display orientation, then mirror horizontally.
            val angle = (sensorOrientation + degrees) % 360
            val point = when (angle) {
                90 -> (1.0 - y) to x
                180 -> (1.0 - x) to (1.0 - y)
                270 -> y to (1.0 - x)
                else -> x to y
            }
            mapOf("centerX" to (1.0 - point.first), "centerY" to point.second)
        }
        publish(state("observing") + mapOf("faceCount" to visible.size, "primaryFace" to primary))
    }

    private fun isCurrent(token: Int) = !closed && foreground && desired && token == generation

    private fun releaseCamera() {
        generation++
        timeout?.let(main::removeCallbacks)
        timeout = null
        val oldSession = session
        session = null
        runCatching { oldSession?.stopRepeating() }
        runCatching { oldSession?.abortCaptures() }
        runCatching { oldSession?.close() }
        runCatching { device?.close() }
        device = null
        runCatching { reader?.close() }
        reader = null
        imageThread?.quitSafely()
        imageThread = null
        lastEventAt = 0L
    }

    private fun fail(status: String, reason: String) {
        desired = false
        releaseCamera()
        publish(state(status, reason))
    }

    private fun state(status: String, reason: String? = null): Map<String, Any?> = mapOf(
        "status" to status,
        "sequence" to ++sequence,
        "reason" to reason,
        "faceCount" to 0,
        "primaryFace" to null,
        "timestampMillis" to SystemClock.elapsedRealtime(),
        "source" to "android_camera2_hardware_face_detection",
        "livenessVerified" to false,
    )

    private fun publish(value: Map<String, Any?>) {
        latest = value
        sink?.success(value)
    }
}
