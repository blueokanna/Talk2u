package com.blue.talk2u

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * Regression cover for the failure that shipped as `geniex_model_pull failed
 * (rc=-100005)`: a marketing chipset name reached Qualcomm AI Hub where an SoC
 * code is mandatory.
 */
class ChipsetTest {
    @Test
    fun `soc codes pass through unchanged`() {
        assertEquals("SM8850", Chipset.normalize("SM8850"))
        assertEquals("SM8850", Chipset.normalize(" sm8850 "))
    }

    @Test
    fun `marketing names map to the matching soc`() {
        assertEquals("SM8850", Chipset.normalize("Snapdragon 8 Elite Gen 5 QRD"))
        assertEquals("SM8750", Chipset.normalize("Snapdragon 8 Elite"))
        assertEquals("SM8750", Chipset.normalize("Snapdragon 8 Elite for Galaxy"))
    }

    @Test
    fun `an embedded code wins over prose`() {
        assertEquals("SM8850", Chipset.normalize("Qualcomm SM8850 QRD"))
    }

    @Test
    fun `unknown hardware is not guessed`() {
        assertEquals("", Chipset.normalize(""))
        assertEquals("", Chipset.normalize("   "))
        assertEquals("", Chipset.normalize("Tensor G3"))
        assertEquals("", Chipset.normalize("MT6989"))
    }

    @Test
    fun `pull prefers the platform soc code`() {
        assertEquals("SM8850", Chipset.requireSupported("SM8850", "Snapdragon 8 Elite"))
    }

    @Test
    fun `pull falls back to the detected marketing name`() {
        assertEquals("SM8850", Chipset.requireSupported("", "Snapdragon 8 Elite Gen 5"))
        assertEquals("SM8750", Chipset.requireSupported("", "Snapdragon 8 Elite"))
    }

    @Test
    fun `unsupported chipsets fail before the hub rejects them`() {
        assertThrows(IllegalStateException::class.java) {
            Chipset.requireSupported("SM8650", "")
        }
        assertThrows(IllegalStateException::class.java) {
            Chipset.requireSupported("", "Tensor G3")
        }
        assertThrows(IllegalStateException::class.java) {
            Chipset.requireSupported("", "")
        }
    }
}
