package com.blue.talk2u

import org.json.JSONArray
import org.json.JSONObject

/**
 * The JNI entry points implemented in `rust/src/android_bridge.rs`.
 *
 * These functions are called on the import path (GGUF header validation), once
 * per generated turn (ChatML rendering), and once after a llama.cpp NPU session
 * is opened (GGML registry probe). They return a JSON envelope so a rejected file
 * or a missing backend never turns into a Java exception that unwinds through the
 * model transaction.
 */
internal class OnDeviceAiNative private constructor() {
    companion object {
        init {
            System.loadLibrary("rust_lib_talk2u")
        }

        /** Reads a GGUF header; returns `null` only if the JVM cannot allocate. */
        @JvmStatic
        external fun inspectGguf(path: String): String?

        /** Renders the ChatML prompt for a JSON array of `{role, content}`. */
        @JvmStatic
        external fun buildChatMlPrompt(messagesJson: String): String?

        /** Reports whether a reply still carries Qwen chat control tokens. */
        @JvmStatic
        external fun containsControlToken(text: String): String?

        /**
         * Reads the GGML backend registry the llama.cpp plugin registered.
         *
         * Passive: the Rust side opens the already-mapped `libggml.so` with
         * `RTLD_NOLOAD` and never calls `ggml_backend_load_all_from_path`, so
         * the probe cannot register a second copy of a backend.
         */
        @JvmStatic
        external fun probeGgmlBackends(directory: String): String?
    }
}

/** One passive GGML registry snapshot. */
internal data class GgmlSnapshot(
    val loaded: Boolean,
    val htpRegistered: Boolean,
    val htpDevice: Boolean,
    val devices: List<String>,
    val error: String?,
) {
    /** True only when the HTP backend is actually registered in this process. */
    val htpReady: Boolean
        get() = loaded && htpRegistered
}

/**
 * Kotlin view over the Rust GGML probe.
 *
 * A failure to answer is not an exception: the caller records the reason and
 * treats the accelerator as unverified. That keeps a broken probe from turning
 * into a crash on the generation path.
 */
internal object GgmlProbe {
    fun snapshot(directory: String): GgmlSnapshot {
        val raw = runCatching { OnDeviceAiNative.probeGgmlBackends(directory) }
            .getOrNull()
            ?: return GgmlSnapshot(
                loaded = false,
                htpRegistered = false,
                htpDevice = false,
                devices = emptyList(),
                error = "the Rust GGML probe is unavailable",
            )
        val json = runCatching { JSONObject(raw) }.getOrNull()
            ?: return GgmlSnapshot(
                loaded = false,
                htpRegistered = false,
                htpDevice = false,
                devices = emptyList(),
                error = "the Rust GGML probe returned malformed JSON",
            )
        val devices = json.optJSONArray("devices")?.let { array ->
            buildList {
                for (index in 0 until array.length()) {
                    val name = array.optJSONObject(index)?.optString("name").orEmpty()
                    if (name.isNotBlank()) add(name)
                }
            }
        }.orEmpty()
        return GgmlSnapshot(
            loaded = json.optBoolean("loaded"),
            htpRegistered = json.optBoolean("htpRegistered"),
            htpDevice = json.optBoolean("htpDevice"),
            devices = devices,
            error = null,
        )
    }
}

/**
 * ChatML prompt construction, delegated to Rust.
 *
 * One implementation serves both engines: the QAIRT bundle and a llama.cpp GGUF
 * are the same Qwen3 checkpoint, so the template must not be duplicated in
 * Kotlin. See `rust/src/api/chatml.rs` for the markup and the stripping rules.
 */
internal object ChatMlPrompt {
    /** Builds a complete prompt ending with the assistant header. */
    fun build(messages: List<Pair<String, String>>): String {
        val payload = JSONArray()
        messages.forEach { (role, content) ->
            payload.put(JSONObject().put("role", role).put("content", content))
        }
        val raw = OnDeviceAiNative.buildChatMlPrompt(payload.toString())
            ?: throw IllegalStateException("The Rust prompt builder returned no result")
        val response = JSONObject(raw)
        if (!response.optBoolean("ok")) {
            throw IllegalArgumentException(
                response.optString("error").ifBlank {
                    "The Rust prompt builder rejected the conversation"
                },
            )
        }
        return response.optString("prompt")
    }

    /**
     * True when the model emitted ChatML markup instead of text.
     *
     * A reply containing `<|im_end|>` means the sampler escaped the assistant
     * turn. Rendering it would show raw control tokens in the bubble and, worse,
     * prime the next turn with markup.
     */
    fun leaksControlToken(text: String): Boolean {
        val raw = OnDeviceAiNative.containsControlToken(text) ?: return true
        return JSONObject(raw).optBoolean("leaked", true)
    }
}
