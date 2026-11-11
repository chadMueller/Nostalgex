package com.muellhaus.nostalgex.engine

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/** The server token stays out of what is saved, and comes back from the signed-in servers. */
class ServerTokensTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    private val item = MediaItem(ratingKey = "1", title = "A", serverUrl = "http://a:32400", serverToken = "secret-token")

    @Test fun theTokenIsNeverWritten() {
        val text = json.encodeToString(item)
        assertFalse(text, text.contains("secret-token"))
        assertFalse(text, text.contains("serverToken"))
        assertEquals("http://a:32400", json.decodeFromString<MediaItem>(text).serverUrl)
    }

    /** A copy saved by an older build still names it; reading it doesn't bring the token back. */
    @Test fun anOldCopysTokenIsNotRead() =
        assertNull(json.decodeFromString<MediaItem>("""{"ratingKey":"1","serverUrl":"http://a:32400","serverToken":"old"}""").serverToken)

    @Test fun eachItemGetsItsOwnServersToken() {
        val items = listOf(
            MediaItem(ratingKey = "1", serverUrl = "http://a:32400"),
            MediaItem(ratingKey = "2", serverUrl = "http://b:8096"),
            MediaItem(ratingKey = "3", serverUrl = "http://gone:32400"),
            MediaItem(ratingKey = "4"),
        )
        val filled = ServerTokens.fill(items, mapOf("http://a:32400" to "ta", "http://b:8096" to "tb"))
        assertEquals(listOf("ta", "tb", null, null), filled.map { it.serverToken })
        assertEquals(items.map { it.copy(serverToken = null) }, filled.map { it.copy(serverToken = null) })
    }
}
