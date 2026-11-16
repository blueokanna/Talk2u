package com.blue.talk2u

/**
 * Builds the ChatML prompt that Qwen3-Instruct expects.
 *
 * GenieX 0.3.17 does ship the model's Jinja `chat_template`, but its renderer
 * returns an empty string for the AI Hub Qwen3 bundle, which failed every turn
 * with "empty Qwen3 chat template". The markup produced here matches the bundle's
 * own `sample_prompt.txt` (`<|im_start|>role\ncontent<|im_end|>\n` followed by the
 * assistant header), so prompting no longer depends on the renderer.
 */
internal object Qwen3Prompt {
    private const val START = "<|im_start|>"
    private const val END = "<|im_end|>"
    private const val ASSISTANT_HEADER = START + "assistant\n"

    /** Returns a complete prompt ending with the assistant header. */
    fun build(messages: List<Pair<String, String>>): String = buildString {
        for ((role, content) in messages) {
            val text = sanitize(content)
            if (text.isEmpty()) continue
            append(START)
            append(normalize(role))
            append('\n')
            append(text)
            append(END)
            append('\n')
        }
        append(ASSISTANT_HEADER)
    }

    /** Maps any role onto the three roles ChatML defines. */
    fun normalize(role: String): String = when (role.lowercase()) {
        "system" -> "system"
        "assistant" -> "assistant"
        else -> "user"
    }

    /** Drops markup tokens so user text cannot open or close a turn. */
    private fun sanitize(content: String): String =
        content.replace(START, "").replace(END, "").trim()
}
