package com.blue.talk2u

/**
 * Qualcomm AI Hub addresses precompiled bundles by SoC code, while device
 * firmware often reports a marketing name ("Snapdragon 8 Elite Gen 5 QRD").
 * Pulling with the marketing name fails with a generic rc=-100005, so the
 * mapping lives here as pure logic that JVM tests can cover without a phone.
 */
internal object Chipset {
    val supported: Set<String> = setOf("SM8750", "SM8850")

    private val socPattern = Regex("SM[0-9]{4}")

    /** Returns an SoC code such as `SM8850`, or an empty string when unknown. */
    fun normalize(value: String): String {
        val upper = value.trim().uppercase()
        if (upper.isEmpty()) return ""
        socPattern.find(upper)?.let { return it.value }
        return when {
            upper.contains("8 ELITE GEN 5") -> "SM8850"
            upper.contains("8 ELITE") -> "SM8750"
            else -> ""
        }
    }

    /**
     * Resolves the pull chipset, preferring the platform SoC code and falling
     * back to the SDK-detected name. Throws instead of sending an invalid value.
     */
    fun requireSupported(socModel: String, detected: String): String {
        val code = normalize(socModel).ifBlank { normalize(detected) }
        check(code in supported) {
            val current = detected.ifBlank { socModel }.ifBlank { "未知" }
            "无法确定可用的 AI Hub 芯片代号（当前: $current）；" +
                "仅支持 ${supported.joinToString("/")}"
        }
        return code
    }
}
