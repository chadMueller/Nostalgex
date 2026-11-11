package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

/** The cases of the Apple TV's JellyfinPlaybackInfoTests that apply to this player, and the profile's Android differences. */
class PlaybackInfoHandshakeTest {
    private val h = PlaybackInfoHandshake
    private val server = "http://jelly.local:8096"

    private fun streams(vararg s: PlaybackInfoHandshake.Stream) = s.toList()
    private fun sub(index: Int, lang: String?, forced: Boolean = false, default: Boolean = false) =
        PlaybackInfoHandshake.Stream(index, "Subtitle", lang, default, forced, null, null)
    private fun audio(index: Int, lang: String?, channels: Int = 2, default: Boolean = false) =
        PlaybackInfoHandshake.Stream(index, "Audio", lang, default, false, channels, "ac3")
    private fun methods(body: JsonObject) =
        body["DeviceProfile"]!!.jsonObject["SubtitleProfiles"]!!.jsonArray.map { it.jsonObject["Method"]!!.jsonPrimitive.content }.toSet()

    // ── The body ──

    @Test fun everyAttemptAsksForNoSubtitleStreamWithTheSourceId() {
        for (only in listOf(false, true)) {
            val b = h.body("src1", 20_000_000, only)
            assertEquals(-1, b["SubtitleStreamIndex"]!!.jsonPrimitive.int)
            assertEquals("src1", b["MediaSourceId"]!!.jsonPrimitive.content)
            assertEquals(setOf("External"), methods(b))
        }
    }

    @Test fun theRetryTurnsOffDirectPlayAndDirectStreamTheFirstAttemptLeavesThemOut() {
        val first = h.body("src1", 1, serverStreamOnly = false)
        assertFalse("EnableDirectPlay" in first || "EnableDirectStream" in first)
        val retry = h.body("src1", 1, serverStreamOnly = true)
        assertEquals(false, (retry["EnableDirectPlay"] as JsonPrimitive).booleanOrNull)
        assertEquals(false, (retry["EnableDirectStream"] as JsonPrimitive).booleanOrNull)
    }

    @Test fun theBurnBodyNamesTheTrackAndAsksForEncode() {
        val b = h.body("src1", 1, false, burningSubtitle = 5)
        assertEquals(5, b["SubtitleStreamIndex"]!!.jsonPrimitive.int)
        assertEquals(setOf("Encode"), methods(b))
    }

    @Test fun theProfileListsImageFormatsAsWellAsText() {
        val formats = h.subtitleProfiles(false).map { it.jsonObject["Format"]!!.jsonPrimitive.content }.toSet()
        for (f in listOf("srt", "subrip", "ass", "ssa", "mov_text", "webvtt", "pgssub", "dvdsub", "dvbsub")) assertTrue(f, f in formats)
    }

    /** Android's differences: no direct play offered back, the hand-built request's TS H.264 AAC, the 10-bit H.264 cap kept. */
    @Test fun theProfileAsksForTheStreamAndroidAlreadyPlays() {
        val p = h.deviceProfile(8_000_000)
        assertEquals(JsonArray(emptyList()), p["DirectPlayProfiles"])
        val t = p["TranscodingProfiles"]!!.jsonArray.single().jsonObject
        assertEquals("ts", t["Container"]!!.jsonPrimitive.content)
        assertEquals("h264", t["VideoCodec"]!!.jsonPrimitive.content)
        assertEquals("aac", t["AudioCodec"]!!.jsonPrimitive.content)
        assertEquals("hls", t["Protocol"]!!.jsonPrimitive.content)
        assertFalse(p.toString().contains("hevc"))
        assertTrue(p.toString().contains("\"Property\":\"VideoBitDepth\""))
        assertEquals(8_000_000L, p["MaxStreamingBitrate"]!!.jsonPrimitive.content.toLong())
    }

    // ── The forced track ──

    @Test fun aForcedTrackInTheViewersLanguageIsBurned() {
        val s = streams(PlaybackInfoHandshake.Stream(0, "Video", null, false, false, null, null), audio(1, "eng"), sub(2, "eng", forced = true))
        assertEquals(2, h.forcedSubtitleToBurn(s, "en"))
    }

    @Test fun aDefaultOnlyTrackIsNeverBurned() = assertNull(h.forcedSubtitleToBurn(streams(sub(2, "eng", default = true)), "en"))

    @Test fun noSubtitlesNothingBurned() {
        assertNull(h.forcedSubtitleToBurn(emptyList(), "en"))
        assertNull(h.forcedSubtitleToBurn(null, "en"))
    }

    @Test fun aForcedTrackInAnotherLanguageIsNotBurned() {
        val s = streams(sub(2, "ger", forced = true))
        assertNull(h.forcedSubtitleToBurn(s, "en"))
        assertNull(h.forcedSubtitleToBurn(s, "es"))
    }

    /** Emby kept "ger" from the file, Jellyfin 12.2.0 reported the same track as "deu". */
    @Test fun bothIsoCodesForTheViewersLanguageCount() {
        for (code in listOf("ger", "deu")) assertEquals(code, 2, h.forcedSubtitleToBurn(streams(sub(2, code, forced = true)), "de"))
    }

    @Test fun onABluRayLayoutTheForcedImageTrackIsTheOneBurned() {
        val s = streams(audio(1, "eng"), sub(2, "eng", default = true), sub(3, "eng"), sub(4, "eng"), sub(5, "eng", forced = true))
        assertEquals(5, h.forcedSubtitleToBurn(s, "en"))
    }

    @Test fun onlySubtitleTracksCount() {
        val s = listOf(PlaybackInfoHandshake.Stream(1, "Audio", "eng", false, true, 2, null))
        assertNull(h.forcedSubtitleToBurn(s, "en"))
    }

    // ── resolve ──

    private fun resolve(json: String, only: Boolean = false, langs: List<String> = listOf("en")) =
        h.resolve(h.parse(json), server, "TKN", "m1", "src1", only, langs)

    @Test fun resolveSelectsTheTranscodingUrlAndSession() {
        val r = resolve("""{ "PlaySessionId": "PS123", "MediaSources": [ { "Id": "src1", "TranscodingUrl": "/Videos/m1/master.m3u8?MediaSourceId=src1&api_key=TKN" } ] }""")!!
        assertFalse(r.isDirectPlay)
        assertEquals("PS123", r.playSessionId)
        assertEquals("$server/Videos/m1/master.m3u8?MediaSourceId=src1&api_key=TKN", r.url)
    }

    @Test fun resolveAppendsApiKeyOnceWhenMissing() {
        val r = resolve("""{ "MediaSources": [ { "Id": "src1", "TranscodingUrl": "/Videos/m1/master.m3u8?MediaSourceId=src1" } ] }""")!!
        assertEquals(1, r.url.split("api_key=").size - 1)
        val again = resolve("""{ "MediaSources": [ { "Id": "src1", "TranscodingUrl": "/Videos/m1/master.m3u8?api_key=TKN" } ] }""")!!
        assertEquals(1, again.url.split("api_key=").size - 1)
    }

    @Test fun anAbsoluteTranscodingUrlIsKept() {
        val r = resolve("""{ "MediaSources": [ { "Id": "src1", "TranscodingUrl": "http://other:8096/Videos/m1/master.m3u8?ApiKey=TKN" } ] }""")!!
        assertTrue(r.url.startsWith("http://other:8096/Videos/m1/master.m3u8?ApiKey=TKN"))
    }

    @Test fun resolveFallsBackToTheStoredFileExceptOnTheRetry() {
        val json = """{ "PlaySessionId": "PS9", "MediaSources": [ { "Id": "src1", "SupportsDirectPlay": true } ] }"""
        val r = resolve(json)!!
        assertTrue(r.isDirectPlay)
        assertTrue(r.url.contains("/Videos/m1/stream.mp4") && r.url.contains("Static=true") && r.url.contains("ApiKey=TKN"))
        assertEquals("PS9", r.playSessionId)
        assertNull("the retry never gets the file that just failed", resolve(json, only = true))
    }

    @Test fun resolveReturnsNullWithNothingPlayable() =
        assertNull(resolve("""{ "MediaSources": [ { "Id": "src1", "SupportsDirectPlay": false, "SupportsTranscoding": false } ] }"""))

    @Test fun resolvePicksTheMatchingMediaSource() {
        val r = resolve("""{ "MediaSources": [
            { "Id": "other", "TranscodingUrl": "/Videos/m1/master.m3u8?MediaSourceId=other&api_key=TKN" },
            { "Id": "src1",  "TranscodingUrl": "/Videos/m1/master.m3u8?MediaSourceId=src1&api_key=TKN" } ] }""")!!
        assertTrue(r.url.contains("MediaSourceId=src1"))
    }

    /** The recorded Jellyfin 12.2.0 answer: no StartTimeTicks goes on, the player seeks (offsetPlayback). */
    @Test fun theTranscodingUrlGoesToThePlayerAsBuilt() {
        val url = "/videos/c785/master.m3u8?DeviceId=atv&MediaSourceId=src1&VideoCodec=h264&AudioCodec=aac&SegmentContainer=ts&PlaySessionId=040049&ApiKey=TKN&TranscodeReasons=ContainerNotSupported"
        val r = resolve("""{ "PlaySessionId": "040049", "MediaSources": [ { "Id": "src1", "TranscodingUrl": "$url" } ] }""")!!
        assertEquals("$server$url&api_key=TKN", r.url)
        assertFalse(r.url.contains("StartTimeTicks"))
    }

    /** The audio track is pinned by the Roku's rule (LanguageChoice.preferredAudioIndex), replacing the server's. */
    @Test fun theAudioTrackIsPinnedOnlyWhenThereIsAChoice() {
        fun answer(streams: String) = """{ "MediaSources": [ { "Id": "src1", "TranscodingUrl": "/Videos/m1/master.m3u8?AudioStreamIndex=1&ApiKey=TKN", "MediaStreams": [ $streams ] } ] }"""
        val two = """{ "Index": 1, "Type": "Audio", "Language": "spa", "Channels": 2, "IsDefault": true }, { "Index": 2, "Type": "Audio", "Language": "eng", "Channels": 6 }"""
        val r = resolve(answer(two))!!
        assertTrue(r.url, r.url.endsWith("&AudioStreamIndex=2"))
        assertEquals(1, r.url.split("AudioStreamIndex=").size - 1)
        assertTrue(resolve(answer(two), langs = listOf("es"))!!.url.endsWith("&AudioStreamIndex=1"))
        val one = resolve(answer("""{ "Index": 1, "Type": "Audio", "Language": "spa" }"""))!!
        assertEquals("$server/Videos/m1/master.m3u8?AudioStreamIndex=1&ApiKey=TKN&api_key=TKN", one.url)
    }

    // ── negotiate: the two requests ──

    private class FakeServer(val first: String, val burned: String?) {
        val sent = ArrayList<JsonObject>()
        fun send(b: JsonObject): String {
            sent += b
            if (b["SubtitleStreamIndex"]!!.jsonPrimitive.int == -1) return first
            return burned ?: throw IOException("timed out")
        }
        val indexes get() = sent.map { it["SubtitleStreamIndex"]!!.jsonPrimitive.int }
    }

    private fun answer(session: String, forced: Boolean) = """
        { "PlaySessionId": "$session",
          "MediaSources": [ { "Id": "mediasource_4242", "SupportsDirectPlay": false, "SupportsTranscoding": true,
            "TranscodingUrl": "/videos/4242/master.m3u8?MediaSourceId=mediasource_4242&PlaySessionId=$session&ApiKey=TKN",
            "MediaStreams": [ { "Index": 0, "Type": "Video" }, { "Index": 1, "Type": "Audio", "Language": "eng" },
              { "Index": 2, "Type": "Subtitle", "Language": "eng", "IsDefault": true },
              { "Index": 5, "Type": "Subtitle", "Language": "eng", "IsForced": $forced } ] } ] }
    """

    private fun negotiate(s: FakeServer) = h.negotiate(s::send, server, "TKN", "4242", "mediasource_4242", 20_000_000, false, "en", listOf("en"))

    @Test fun aFileWithAForcedTrackAsksASecondTimeAndPlaysTheBurnedStream() {
        val s = FakeServer(answer("plain", true), answer("burned", true))
        val r = negotiate(s)!!
        assertEquals("burned", r.playSessionId)
        assertTrue(r.url.contains("PlaySessionId=burned"))
        assertEquals(listOf(-1, 5), s.indexes)
        assertEquals(listOf(setOf("External"), setOf("Encode")), s.sent.map { methods(it) })
    }

    @Test fun aFileWithOnlyADefaultTrackAsksOnce() {
        val s = FakeServer(answer("plain", false), null)
        assertEquals("plain", negotiate(s)!!.playSessionId)
        assertEquals(listOf(-1), s.indexes)
    }

    @Test fun whenTheBurnRequestFailsTheFilmStillPlaysWithoutIt() {
        val s = FakeServer(answer("plain", true), null)
        assertEquals("plain", negotiate(s)!!.playSessionId)
        assertEquals(listOf(-1, 5), s.indexes)
    }

    @Test(expected = IOException::class)
    fun aFailedFirstRequestThrowsSoTheCallerUsesItsOwnStream() {
        h.negotiate({ throw IOException("refused") }, server, "TKN", "4242", "m", 1, false, "en", listOf("en"))
    }

    // ── negotiate: the burned stream's first segment (JellyfinPlaybackInfoTests, q106) ──

    /**
     * The burned stream's playlists and first segment, as the probe fetches them. `answers` maps a
     * path's last part to a status and body; a missing entry is a timeout (null).
     */
    private class FakeStream(val answers: Map<String, Pair<Int, String?>>) : PlaybackInfoHandshake.Probe {
        val fetched = ArrayList<String>()
        override fun get(url: String): Pair<Int, String?>? {
            fetched += url
            return answers[url.substringBefore('?').substringAfterLast('/')]
        }
    }

    private val masterText = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=20000000\nmain.m3u8?PlaySessionId=burned\n"
    private val variantText = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nhls1/main/0.ts?PlaySessionId=burned\n#EXT-X-ENDLIST\n"

    private fun burnNegotiate(stream: FakeStream, stopped: MutableList<String>) =
        h.negotiate(FakeServer(answer("plain", true), answer("burned", true))::send, server, "TKN", "4242", "mediasource_4242",
            20_000_000, false, "en", listOf("en"), probe = stream, stopRefused = { stopped += it })

    @Test fun theBurnedStreamsFirstSegmentIsFetchedBeforeItIsChosen() {
        val stream = FakeStream(mapOf("master.m3u8" to (200 to masterText), "main.m3u8" to (200 to variantText), "0.ts" to (200 to null)))
        val stopped = ArrayList<String>()
        assertEquals("burned", burnNegotiate(stream, stopped)!!.playSessionId)
        assertEquals(3, stream.fetched.size)
        assertTrue(stream.fetched[0], stream.fetched[0].startsWith("$server/videos/4242/master.m3u8?"))
        assertEquals("the variant, relative to the master", "$server/videos/4242/main.m3u8?PlaySessionId=burned", stream.fetched[1])
        assertEquals("the segment, relative to the variant, its own query kept", "$server/videos/4242/hls1/main/0.ts?PlaySessionId=burned", stream.fetched[2])
        assertTrue("an accepted burned stream is not stopped", stopped.isEmpty())
    }

    /** Chad's Emby 4.10.1: playlists fine, every segment of a burned-in stream HTTP 500. */
    @Test fun aServerThatRefusesTheBurnedSegmentGetsThePlainStream() {
        val stream = FakeStream(mapOf("master.m3u8" to (200 to masterText), "main.m3u8" to (200 to variantText), "0.ts" to (500 to null)))
        val stopped = ArrayList<String>()
        val r = burnNegotiate(stream, stopped)!!
        assertEquals("plain", r.playSessionId)
        assertTrue(!r.url.contains("burned"))
        assertEquals("nothing else will ever see that session", listOf("burned"), stopped)
    }

    @Test fun aServerThatRefusesTheBurnedPlaylistGetsThePlainStream() {
        val stream = FakeStream(mapOf("master.m3u8" to (500 to null)))
        val stopped = ArrayList<String>()
        assertEquals("plain", burnNegotiate(stream, stopped)!!.playSessionId)
        assertEquals("it stops at the first refusal", 1, stream.fetched.size)
        assertEquals(listOf("burned"), stopped)
    }

    /** A master that is already a media playlist: its own first entry is the segment, no variant hop. */
    @Test fun aMasterThatIsAMediaPlaylistNeedsNoVariantRequest() {
        val stream = FakeStream(mapOf("master.m3u8" to (200 to "#EXTM3U\n#EXTINF:6.0,\nhls1/main/0.ts?PlaySessionId=burned&api_key=TKN\n"), "0.ts" to (200 to null)))
        assertEquals("burned", burnNegotiate(stream, ArrayList())!!.playSessionId)
        assertEquals(2, stream.fetched.size)
        assertEquals("$server/videos/4242/hls1/main/0.ts?PlaySessionId=burned&api_key=TKN", stream.fetched[1])
    }

    /** A slow or dropped probe, or a playlist it can't read, proves nothing: the burned-in subtitles stay. */
    @Test fun aTimeoutOrAnUnreadablePlaylistKeepsTheBurnedStream() {
        val stopped = ArrayList<String>()
        assertEquals("burned", burnNegotiate(FakeStream(emptyMap()), stopped)!!.playSessionId)
        assertEquals("burned", burnNegotiate(FakeStream(mapOf("master.m3u8" to (200 to "not a playlist"))), stopped)!!.playSessionId)
        assertEquals("burned", burnNegotiate(FakeStream(mapOf("master.m3u8" to (200 to masterText), "main.m3u8" to (200 to variantText))), stopped)!!.playSessionId)
        assertTrue(stopped.isEmpty())
        assertEquals(12_000L, PlaybackInfoHandshake.BURN_PROBE_TIMEOUT_MS)
    }

    @Test fun aFileWithNoForcedTrackMakesNoExtraRequest() {
        val stream = FakeStream(emptyMap())
        val s = FakeServer(answer("plain", false), null)
        assertEquals("plain", h.negotiate(s::send, server, "TKN", "4242", "mediasource_4242", 20_000_000, false, "en", listOf("en"), probe = stream)!!.playSessionId)
        assertTrue(stream.fetched.isEmpty())
    }
}
