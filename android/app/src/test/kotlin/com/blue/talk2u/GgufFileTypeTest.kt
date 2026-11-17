package com.blue.talk2u

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Locks the HTP quantization whitelist.
 *
 * The comment in the app is not the contract; this test is. If a future
 * quantization is added, it must be added here with a real HTP kernel check, not
 * because the label is numerically close to Q4_0.
 */
class GgufFileTypeTest {
    @Test
    fun `labels the common file types`() {
        assertEquals("Q4_0", GgufFileType.label(2))
        assertEquals("Q8_0", GgufFileType.label(7))
        assertEquals("Q4_K_M", GgufFileType.label(15))
        assertEquals("unknown", GgufFileType.label(null))
        assertEquals("type 99", GgufFileType.label(99))
    }

    @Test
    fun `only q4_0 and q8_0 are clean on htp`() {
        assertTrue(GgufFileType.isCleanOnHtp(2))
        assertTrue(GgufFileType.isCleanOnHtp(7))
        assertFalse(GgufFileType.isCleanOnHtp(15))
        assertFalse(GgufFileType.isCleanOnHtp(14))
        assertFalse(GgufFileType.isCleanOnHtp(1))
        assertFalse(GgufFileType.isCleanOnHtp(null))
    }
}
