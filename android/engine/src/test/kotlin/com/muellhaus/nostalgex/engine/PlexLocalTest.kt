package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** I-057, LOCAL SERVER (NO PLEX.TV): the typed address and the rules a no-plex.tv sign-in follows (the Apple TV's LocalPlexSignInTests). */
class PlexLocalTest {
    @Test fun aTypedAddressGetsPlexsPortAndHttp() {
        assertEquals(listOf("http://192.168.1.10:32400"), PlexLocal.candidates("192.168.1.10"))
        assertEquals(listOf("http://192.168.1.10:32401"), PlexLocal.candidates("192.168.1.10:32401/"))
        assertEquals(listOf("https://plex.home:32400"), PlexLocal.candidates("https://plex.home"))
        assertEquals(listOf("http://plex.home:8443"), PlexLocal.candidates("HTTP://plex.home:8443"))
        assertEquals(listOf("http://192.168.1.10:32400"), PlexLocal.candidates("  192.168.1.10  "))
        // A path, query or fragment typed after the address is dropped.
        assertEquals(listOf("http://192.168.1.10:32400"), PlexLocal.candidates("192.168.1.10/web/index.html#!/"))
        assertEquals(listOf("http://192.168.1.10:32400"), PlexLocal.candidates("http://192.168.1.10?x=1"))
        assertEquals(listOf("http://[::1]:32400"), PlexLocal.candidates("[::1]"))
        assertEquals(listOf("http://[fe80::1]:32401"), PlexLocal.candidates("[fe80::1]:32401"))
    }

    @Test fun nothingUsableTypedGivesNoAddress() {
        for (bad in listOf("", "   ", "/", "http://", "192.168.1.10:abc", "192.168.1.10:0", "192.168.1.10:70000", "user@host", "two words", ":32400", "[::1")) {
            assertEquals("for \"$bad\"", emptyList<String>(), PlexLocal.candidates(bad))
        }
    }

    @Test fun anEmptyTokenIsNotSent() {
        assertFalse(PlexLocal.hasToken(""))
        assertFalse(PlexLocal.hasToken(null))
        assertTrue(PlexLocal.hasToken("abc"))
    }

    @Test fun aSignInWithNoPlexTvNeverAsksPlexTv() {
        assertFalse(PlexLocal.asksPlexTv(true))
        assertTrue(PlexLocal.asksPlexTv(false))
    }

    @Test fun signedInNeedsServersAndEitherATokenOrTheFlag() {
        // A plex.tv sign-in: the token and a server.
        assertTrue(PlexLocal.isSignedIn("account", false, 1))
        assertFalse(PlexLocal.isSignedIn(null, false, 1))
        assertFalse(PlexLocal.isSignedIn("account", false, 0))
        // No plex.tv: the empty token is a sign-in, with a server.
        assertTrue(PlexLocal.isSignedIn("", true, 1))
        assertTrue(PlexLocal.isSignedIn(null, true, 1))
        assertFalse(PlexLocal.isSignedIn("", true, 0))
        // The old rule stands for a plex.tv sign-in: any saved token with a server.
        assertTrue(PlexLocal.isSignedIn("", false, 1))
    }

    @Test fun the401MessageNamesPlexsSetting() {
        assertTrue(PlexLocal.NEEDS_AUTH_MESSAGE.contains("List of IP addresses and networks that are allowed without auth"))
        assertTrue(PlexLocal.NEEDS_AUTH_MESSAGE.contains("Settings, then Network"))
    }
}
