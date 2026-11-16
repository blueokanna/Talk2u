package com.blue.talk2u

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * Manifest rules for the 684 MB MOSS deployment. These used to be reachable only
 * by importing a real archive, so a regression would surface as a failed import
 * on a phone instead of a red test.
 */
class MossDeploymentParserTest {
    private val validHash = "a".repeat(64)

    private fun files(patch: (JSONArray) -> Unit = {}): JSONArray {
        val array = JSONArray()
        MossDeploymentParser.requiredPaths.sorted().forEachIndexed { index, path ->
            array.put(
                JSONObject()
                    .put("path", path)
                    .put("size", 1024 + index)
                    .put("sha256", validHash),
            )
        }
        patch(array)
        return array
    }

    private fun manifest(array: JSONArray = files()): JSONObject = JSONObject()
        .put("schemaVersion", 1)
        .put("runtime", "onnxruntime-qnn-plugin-ep")
        .put("qnnSdkVersion", "2.48.0")
        .put("ortVersion", "1.26.0")
        .put("onnxruntimeQnnVersion", "2.4.0")
        .put(
            "target",
            JSONObject().put("soc", "SM8850").put("htpArchitecture", "v81"),
        )
        .put(
            "providerPlan",
            JSONObject()
                .put("prefill", "QNN_HTP")
                .put("decode", "QNN_HTP")
                .put("sampler", "ORT_CPU")
                .put("codec", "ORT_CPU"),
        )
        .put("files", array)

    @Test
    fun `a complete deployment parses`() {
        val deployment = MossDeploymentParser.parse(manifest())
        assertEquals(MossDeploymentParser.requiredPaths.size, deployment.files.size)
        assertEquals("SM8850", deployment.soc)
        assertEquals("v81", deployment.htpArchitecture)
        assertEquals("2.48.0", deployment.qnnSdkVersion)
        assertEquals("1.26.0", deployment.ortVersion)
        assertEquals(validHash, deployment.files.first().sha256)
    }

    @Test
    fun `the codec may still be declared as QNN_HTP`() {
        val json = manifest()
        json.getJSONObject("providerPlan").put("codec", "QNN_HTP")
        assertEquals(MossDeploymentParser.requiredPaths.size, MossDeploymentParser.parse(json).files.size)
    }

    @Test
    fun `schema runtime sdk and plan are enforced`() {
        val mutations = listOf<JSONObject.() -> Unit>(
            { put("schemaVersion", 2) },
            { put("runtime", "onnxruntime-cpu") },
            { put("qnnSdkVersion", "2.47.0") },
            { put("ortVersion", "1.25.0") },
            { put("onnxruntimeQnnVersion", "2.3.0") },
            { getJSONObject("target").put("soc", "SM8750") },
            { getJSONObject("target").put("htpArchitecture", "v69") },
            { getJSONObject("providerPlan").put("sampler", "QNN_HTP") },
            { getJSONObject("providerPlan").put("codec", "CPU") },
        )
        for (mutation in mutations) {
            val json = manifest()
            json.mutation()
            assertThrows(IllegalArgumentException::class.java) {
                MossDeploymentParser.parse(json)
            }
        }
    }

    @Test
    fun `duplicate paths are rejected`() {
        val json = manifest(
            files { array ->
                val first = array.getJSONObject(0).getString("path")
                array.getJSONObject(1).put("path", first)
            },
        )
        assertThrows(IllegalArgumentException::class.java) {
            MossDeploymentParser.parse(json)
        }
    }

    @Test
    fun `path traversal is rejected`() {
        val json = manifest(
            files { array -> array.getJSONObject(0).put("path", "../escape.bin") },
        )
        assertThrows(IllegalArgumentException::class.java) {
            MossDeploymentParser.parse(json)
        }
    }

    @Test
    fun `invalid size or digest is rejected`() {
        for (patch in listOf<(JSONArray) -> Unit>(
            { array -> array.getJSONObject(0).put("size", 0) },
            { array -> array.getJSONObject(0).put("size", MossDeploymentParser.MAX_FILE_BYTES + 1) },
            { array -> array.getJSONObject(0).put("sha256", "zz".repeat(32)) },
            { array -> array.getJSONObject(0).put("sha256", "abc") },
        )) {
            assertThrows(IllegalArgumentException::class.java) {
                MossDeploymentParser.parse(manifest(files(patch)))
            }
        }
    }

    @Test
    fun `missing required files are reported even when the count is plausible`() {
        val json = manifest(
            files { array ->
                array.remove(0)
                array.put(
                    JSONObject()
                        .put("path", "extra/not-required.bin")
                        .put("size", 1)
                        .put("sha256", validHash),
                )
            },
        )
        assertThrows(IllegalArgumentException::class.java) {
            MossDeploymentParser.parse(json)
        }
    }

    @Test
    fun `file count is bounded`() {
        val json = manifest(
            files { array ->
                repeat(MossDeploymentParser.MAX_FILE_COUNT) {
                    array.put(
                        JSONObject()
                            .put("path", "extra/file-$it.bin")
                            .put("size", 1)
                            .put("sha256", validHash),
                    )
                }
            },
        )
        assertThrows(IllegalArgumentException::class.java) {
            MossDeploymentParser.parse(json)
        }
    }
}
