package com.blue.talk2u

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Host-side coverage for the QAIRT bundle contract.
 *
 * These rules decide whether a 3 GB archive is accepted, so they run in a plain
 * JVM test rather than only on a device: a regression here is an import that
 * fails after twenty minutes of copying.
 */
class QairtBundleValidatorTest {
    @get:Rule
    val folder = TemporaryFolder()

    private fun writeBundle(
        contextSize: Int = 4096,
        backendType: String = "QnnHtp",
        tokenizerPath: String = "tokenizer.json",
        precision: String = "w4a16",
        runtime: String = "genie",
        ctxBins: List<String> = listOf("model.bin"),
        extraFiles: List<String> = listOf("tokenizer.json", "model.bin"),
    ): File {
        val root = folder.newFolder()
        File(root, "genie_config.json").writeText(
            """
            {
              "dialog": {
                "context": { "size": $contextSize },
                "tokenizer": { "path": "$tokenizerPath" },
                "engine": {
                  "backend": { "type": "$backendType" },
                  "model": {
                    "type": "binary",
                    "binary": { "ctx-bins": [${ctxBins.joinToString(",") { "\"$it\"" }}] }
                  }
                }
              }
            }
            """.trimIndent(),
        )
        File(root, "metadata.json").writeText(
            """
            { "runtime": "$runtime", "precision": "$precision", "model_id": "qwen3_4b_abliterated" }
            """.trimIndent(),
        )
        extraFiles.forEach { File(root, it).writeText("payload") }
        return root
    }

    @Test
    fun accepts_a_hardware_bundle() {
        val bundle = QairtBundleValidator.load(writeBundle(), 4096)
        assertEquals(4096, bundle.contextSize)
        assertEquals("qwen3_4b_abliterated", bundle.modelId)
        assertEquals("w4a16", bundle.precision)
        assertEquals("model.bin", bundle.entryPoint.name)
        assertEquals("tokenizer.json", bundle.tokenizer.name)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejects_a_context_size_the_runtime_cannot_request() {
        QairtBundleValidator.load(writeBundle(contextSize = 2048), 4096)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejects_a_non_htp_backend() {
        QairtBundleValidator.load(writeBundle(backendType = "QnnGpu"), 4096)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejects_a_path_outside_the_bundle() {
        QairtBundleValidator.load(
            writeBundle(tokenizerPath = "../../databases/talk2u.db"),
            4096,
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejects_the_wrong_quantization() {
        QairtBundleValidator.load(writeBundle(precision = "w8a16"), 4096)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejects_a_non_genie_runtime() {
        QairtBundleValidator.load(writeBundle(runtime = "tflite"), 4096)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejects_a_missing_context_binary() {
        QairtBundleValidator.load(writeBundle(ctxBins = listOf("absent.bin")), 4096)
    }

    @Test
    fun resolves_a_config_wrapped_in_one_directory() {
        val parent = folder.newFolder()
        val inner = File(parent, "Qwen3-4B-abliterated").apply { mkdirs() }
        File(inner, "genie_config.json").writeText("{}")
        assertEquals(inner.canonicalFile, QairtBundleValidator.findRoot(parent))
    }

    @Test
    fun tolerates_a_leading_dot_segment_in_declared_paths() {
        val root = writeBundle(tokenizerPath = "./tokenizer.json")
        val bundle = QairtBundleValidator.load(root, 4096)
        assertEquals("tokenizer.json", bundle.tokenizer.name)
    }

    @Test
    fun rejects_an_archive_without_a_config() {
        val empty = folder.newFolder()
        val failed = runCatching { QairtBundleValidator.findRoot(empty) }
        assertTrue(failed.isFailure)
    }
}
