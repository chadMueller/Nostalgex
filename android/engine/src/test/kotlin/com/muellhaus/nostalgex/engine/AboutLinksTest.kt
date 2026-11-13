package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** ABOUT > LINKS as the Apple TV 1.0.32's AboutLinks.swift lists them. */
class AboutLinksTest {
    @Test fun theLinksAreListedInTheAppleTvOrder() =
        assertEquals(listOf("DISCORD", "WEBSITE", "WEB TUNER", "ROKU", "GITHUB"), AboutLinks.all.map { it.title })

    @Test fun theAddressesAreTheOnesTheSiteAndTheListingsPublish() =
        assertEquals(
            listOf("discord.gg/FgnZcr5bDT", "nostalgex.app", "nostalgex.app/web-tuner", "my.roku.com/account/add/NOSTALGEX", "github.com/chadMueller/Nostalgex"),
            AboutLinks.all.map { it.address },
        )

    @Test fun anAddressIsPlainTextToReadAndRowIdsAreUnique() {
        assertTrue(AboutLinks.all.none { it.address.startsWith("http") })
        assertEquals(AboutLinks.all.size, AboutLinks.all.map { it.rowId }.toSet().size)
        assertEquals("about_web_tuner", AboutLinks.webTuner.rowId)
        assertFalse(AboutLinks.all.any { "—" in it.subtitle || "–" in it.subtitle })
    }
}
