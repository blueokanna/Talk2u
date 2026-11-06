package com.blue.talk2u

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.io.Closeable

/**
 * Capture path built for simultaneous playback and recording.
 *
 * The `record` plugin opens a generic microphone source and never attaches an
 * echo canceller, so anything the speaker emits is fed straight back into the
 * recognizer. This engine uses [MediaRecorder.AudioSource.VOICE_COMMUNICATION],
 * the source Android tunes for call routing, and attaches the platform's
 * hardware [AcousticEchoCanceler] to the real audio session id. Whether the
 * canceller exists, and whether it actually reported `enabled`, is measured
 * rather than assumed; callers use that to decide if full-duplex barge-in is
 * safe.
 */
class FullDuplexAudioCapture(private val context: Context) : Closeable {
    private companion object {
        const val TAG = "Talk2U/FullDuplex"
        const val SAMPLE_RATE = 16_000
        const val FRAME_MILLIS = 20
    }

    private var record: AudioRecord? = null
    private var echoCanceler: AcousticEchoCanceler? = null
    private var noiseSuppressor: NoiseSuppressor? = null
    private var gainControl: AutomaticGainControl? = null
    private var captureThread: Thread? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var running = false
    @Volatile private var sink: EventChannel.EventSink? = null
    @Volatile private var aecEnabled = false
    @Volatile private var nsEnabled = false
    @Volatile private var agcEnabled = false
    @Volatile private var lastError: String? = null

    fun attachSink(value: EventChannel.EventSink?) {
        sink = value
        if (value == null && running) stop()
    }

    fun capabilities(): Map<String, Any?> = mapOf(
        "supported" to true,
        "apiLevel" to Build.VERSION.SDK_INT,
        "sampleRate" to SAMPLE_RATE,
        "frameMillis" to FRAME_MILLIS,
        "source" to "VOICE_COMMUNICATION",
        "echoCancelerAvailable" to AcousticEchoCanceler.isAvailable(),
        "noiseSuppressorAvailable" to NoiseSuppressor.isAvailable(),
        "gainControlAvailable" to AutomaticGainControl.isAvailable(),
        "echoCancelerEnabled" to aecEnabled,
        "noiseSuppressorEnabled" to nsEnabled,
        "gainControlEnabled" to agcEnabled,
        "lastError" to lastError,
    )

    @SuppressLint("MissingPermission")
    @Synchronized
    fun start(): Map<String, Any?> {
        if (running) return capabilities()
        lastError = null
        val frameSamples = SAMPLE_RATE * FRAME_MILLIS / 1000
        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) {
            lastError = "AudioRecord rejected 16 kHz mono PCM16"
            return capabilities()
        }
        val bufferBytes = maxOf(minBuffer, frameSamples * 2 * 4)
        val created = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferBytes,
            )
        } catch (error: Throwable) {
            lastError = error.message ?: error.javaClass.simpleName
            Log.e(TAG, "AudioRecord creation failed", error)
            return capabilities()
        }
        if (created.state != AudioRecord.STATE_INITIALIZED) {
            created.release()
            lastError = "AudioRecord state=${created.state}"
            return capabilities()
        }
        record = created
        attachEffects(created.audioSessionId)
        created.startRecording()
        if (created.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            lastError = "AudioRecord did not enter the recording state"
            releaseResources()
            return capabilities()
        }
        running = true
        captureThread = Thread({ drain(frameSamples) }, "talk2u-full-duplex-capture").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
        return capabilities()
    }

    @Synchronized
    fun stop() {
        if (!running) {
            releaseResources()
            return
        }
        running = false
        // Stop the recorder first: it unblocks the pending read on the capture
        // thread so the join below cannot stall the platform thread.
        record?.let { active ->
            runCatching { if (active.recordingState == AudioRecord.RECORDSTATE_RECORDING) active.stop() }
        }
        captureThread?.let { thread -> runCatching { thread.join(500) } }
        captureThread = null
        releaseResources()
    }

    private fun attachEffects(sessionId: Int) {
        aecEnabled = false
        nsEnabled = false
        agcEnabled = false
        if (sessionId <= 0) return
        if (AcousticEchoCanceler.isAvailable()) {
            echoCanceler = runCatching { AcousticEchoCanceler.create(sessionId) }.getOrNull()
            aecEnabled = echoCanceler?.let { effect ->
                runCatching {
                    effect.enabled = true
                    effect.enabled
                }.getOrDefault(false)
            } == true
        }
        if (NoiseSuppressor.isAvailable()) {
            noiseSuppressor = runCatching { NoiseSuppressor.create(sessionId) }.getOrNull()
            nsEnabled = noiseSuppressor?.let { effect ->
                runCatching {
                    effect.enabled = true
                    effect.enabled
                }.getOrDefault(false)
            } == true
        }
        if (AutomaticGainControl.isAvailable()) {
            gainControl = runCatching { AutomaticGainControl.create(sessionId) }.getOrNull()
            agcEnabled = gainControl?.let { effect ->
                runCatching {
                    effect.enabled = true
                    effect.enabled
                }.getOrDefault(false)
            } == true
        }
        Log.i(
            TAG,
            "audio session=$sessionId aec=$aecEnabled ns=$nsEnabled agc=$agcEnabled",
        )
    }

    private fun drain(frameSamples: Int) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val buffer = ShortArray(frameSamples)
        val bytes = ByteArray(frameSamples * 2)
        while (running) {
            val active = record ?: break
            val read = try {
                active.read(buffer, 0, frameSamples)
            } catch (error: Throwable) {
                lastError = error.message ?: error.javaClass.simpleName
                break
            }
            if (read <= 0) {
                if (read == AudioRecord.ERROR_INVALID_OPERATION || read == AudioRecord.ERROR_DEAD_OBJECT) {
                    lastError = "AudioRecord read error $read"
                    break
                }
                continue
            }
            for (index in 0 until read) {
                val sample = buffer[index].toInt()
                bytes[index * 2] = (sample and 0xFF).toByte()
                bytes[index * 2 + 1] = ((sample shr 8) and 0xFF).toByte()
            }
            if (sink == null) continue
            val payload = bytes.copyOf(read * 2)
            // Platform-channel replies are main-thread-only: calling success()
            // from this capture thread aborts the process with "Methods marked
            // with @UiThread must be executed on the main thread". Frames are
            // posted in arrival order and never dropped, because the recognizer
            // needs every sample; one 20 ms frame is 640 bytes, so even a long
            // main-thread stall cannot grow the queue into a memory problem.
            mainHandler.post {
                if (!running) return@post
                val target = sink ?: return@post
                runCatching { target.success(payload) }
            }
        }
    }

    private fun releaseResources() {
        echoCanceler?.let { runCatching { it.enabled = false; it.release() } }
        noiseSuppressor?.let { runCatching { it.enabled = false; it.release() } }
        gainControl?.let { runCatching { it.enabled = false; it.release() } }
        echoCanceler = null
        noiseSuppressor = null
        gainControl = null
        aecEnabled = false
        nsEnabled = false
        agcEnabled = false
        record?.let { active ->
            runCatching { if (active.recordingState == AudioRecord.RECORDSTATE_RECORDING) active.stop() }
            runCatching { active.release() }
        }
        record = null
    }

    override fun close() {
        stop()
        sink = null
    }
}
