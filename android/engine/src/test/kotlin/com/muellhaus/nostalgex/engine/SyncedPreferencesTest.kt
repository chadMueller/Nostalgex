package com.muellhaus.nostalgex.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncedPreferencesTest {
    @Test fun thirteenDistinctKeys() {
        assertEquals(13, SyncedPreferences.keys.size)
        assertEquals(13, SyncedPreferences.keys.map { it.name }.toSet().size)
    }

    /** The list is settings only: nothing that holds a token, a server, an address, an id or a cache. */
    @Test fun noKeyHoldsASecretOrAnAddress() {
        for (k in SyncedPreferences.keys) for (bad in listOf("token", "server", "plexToken", "mediaBrowser", "clientId", "url", "address", "library", "signature", "manifest", "scan"))
            assertFalse("${k.name} looks like $bad", k.name.lowercase().contains(bad.lowercase()))
    }

    @Test fun theAppleTVsKeysThatHaveAnAndroidCounterpartAreAllThere() {
        val names = SyncedPreferences.keys.map { it.name }
        for (k in listOf("nostalgex_guide_text_size", StreamQuality.STORAGE_KEY, "nostalgex_enabled_franchises", "nostalgex_disabled_franchises",
            "nostalgex_enabled_collections", "nostalgex_show_now_playing_v2", "nostalgex_mark_watched_v2")) assertTrue(k, k in names)
    }

    @Test fun pickTakesOnlyTheListedKeysWithTheRightKind() {
        val all = mapOf<String, Any?>(
            "plexToken" to "secret", "servers" to "[{\"url\":\"http://10.0.0.5\"}]", "mediaBrowser" to "{...}", "clientId" to "abc",
            "retroMode" to false, "subtitleLanguage" to "es", "enabledBundles" to setOf("nostalgex", "scream"),
            "autoSubtitles" to "yes",              // wrong kind: not taken
            "nostalgex_library_signature" to "sig",
        )
        val picked = SyncedPreferences.pick(all)
        assertEquals(setOf("retroMode", "subtitleLanguage", "enabledBundles"), picked.keys)
        assertEquals(false, picked["retroMode"])
    }

    @Test fun anEmptyLineupIsNeverCarried() {
        assertTrue(SyncedPreferences.pick(mapOf("enabledBundles" to emptySet<String>())).isEmpty())
        assertEquals(setOf<String>(), SyncedPreferences.pick(mapOf("nostalgex_enabled_collections" to emptySet<String>()))["nostalgex_enabled_collections"])
    }
}
