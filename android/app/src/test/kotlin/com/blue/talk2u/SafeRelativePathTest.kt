package com.blue.talk2u

import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Covers the archive/tree path rules that keep imports inside the model root. */
class SafeRelativePathTest {
    @Test
    fun `nested paths are normalised to forward slashes`() {
        assertEquals("a/b/c.bin", SafeRelativePath.normalize("a/b/c.bin"))
        assertEquals("a/b/c.bin", SafeRelativePath.normalize("a\\b\\c.bin"))
    }

    @Test
    fun `empty and absolute paths are rejected`() {
        assertThrows(IllegalArgumentException::class.java) {
            SafeRelativePath.normalize("")
        }
        assertThrows(IllegalArgumentException::class.java) {
            SafeRelativePath.normalize("/etc/passwd")
        }
        assertThrows(IllegalArgumentException::class.java) {
            SafeRelativePath.normalize("\\windows\\system32")
        }
    }

    @Test
    fun `traversal segments are rejected`() {
        for (value in listOf("..", "../x", "a/../b", "a/./b", "a//b", "a/\u0000b")) {
            assertThrows(
                "expected rejection for $value",
                IllegalArgumentException::class.java,
            ) { SafeRelativePath.normalize(value) }
        }
    }

    @Test
    fun `resolveIn returns a child of the root`() {
        val root = Files.createTempDirectory("t2u-safe").toFile()
        try {
            val resolved = SafeRelativePath.resolveIn(root, "model/weights.bin")
            assertTrue(resolved.canonicalPath.startsWith(root.canonicalPath))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `resolveIn rejects a path that escapes the root`() {
        val root = Files.createTempDirectory("t2u-safe").toFile()
        try {
            assertThrows(IllegalArgumentException::class.java) {
                SafeRelativePath.resolveIn(root, "../outside.bin")
            }
        } finally {
            root.deleteRecursively()
        }
    }
}
