package com.blue.talk2u

import android.os.SystemClock

internal object AcceleratorTelemetry {
    class Sampler {
        private var lastWallNanos = 0L
        private var lastMossBusyNanos = 0L
        private var lastMossInvocations = 0L
        private var observedMossInvocations = 0L

        @Synchronized
        fun sample(
            qnnReady: Boolean,
            moss: NativeMossRuntime.Telemetry?,
        ): Map<String, Any?> {
            val now = SystemClock.elapsedRealtimeNanos()
            val mossBusy = moss?.htpBusyNanos ?: 0L
            val mossInvocations = moss?.htpInvocations ?: 0L
            if (lastWallNanos == 0L) {
                lastWallNanos = now
                lastMossBusyNanos = mossBusy
                lastMossInvocations = mossInvocations
            }

            val elapsed = (now - lastWallNanos).coerceAtLeast(1L)
            val mossBusyDelta = counterDelta(mossBusy, lastMossBusyNanos)
            val mossInvocationDelta = counterDelta(mossInvocations, lastMossInvocations)
            observedMossInvocations += mossInvocationDelta

            lastWallNanos = now
            lastMossBusyNanos = mossBusy
            lastMossInvocations = mossInvocations
            val duty = (mossBusyDelta * 100.0 / elapsed)
                .coerceIn(0.0, 100.0)
            return mapOf(
                "available" to qnnReady,
                "percent" to if (qnnReady) duty else null,
                "active" to (moss?.htpInFlight == true),
                "intervalMillis" to elapsed / 1_000_000L,
                "invocations" to observedMossInvocations,
                "mossInvocations" to observedMossInvocations,
                "scope" to "app_qnn_htp_call_duty",
                "source" to "MOSS ORT QNN EP invocation wall time",
                "globalChipUtilization" to false,
            )
        }

        private fun counterDelta(current: Long, previous: Long): Long =
            if (current >= previous) current - previous else current.coerceAtLeast(0L)
    }
}
