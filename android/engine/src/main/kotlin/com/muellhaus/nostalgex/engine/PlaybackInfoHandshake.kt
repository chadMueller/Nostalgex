package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.net.URI
import java.net.URLEncoder

/**
 * Jellyfin's and Emby's PlaybackInfo handshake, as the Apple TV's JellyfinPlaybackResolver: the
 * app says what it can play and the server decides between copying the video into HLS and
 * re-encoding it, and hands back a stream with its own PlaySessionId.
 *
 * Asked only where the Apple TV asks it, for a server stream: when the app skips direct play
 * (a container Media3 has no extractor for, or a file over the remote ceiling), and on the
 * retry after a direct play failed (`serverStreamOnly`). The capped 1080p retry stays the
 * hand-built request, as on the Apple TV.
 *
 * What differs from the Apple TV's device profile, because the player differs:
 * - No DirectPlayProfiles. Android decides direct play itself, by trying the stored file, and
 *   only asks this question once it has decided not to, so a server offering the file back
 *   would offer the one thing already ruled out. The Apple TV lists the containers AVPlayer
 *   opens; ExoPlayer opens far more (MKV, AVI, TS) and finds out about codecs by trying.
 * - The stream is the one Android's hand-built request already asks for, measured on Jellyfin
 *   12.4 and Emby 4.10.2: H.264 and AAC in MPEG-TS. The Apple TV's fMP4 and HEVC are for
 *   AVPlayer, which renders HEVC only from fMP4; Emby's TS is the Apple TV's own choice for
 *   H.264 (`embySegmentContainer`, sound in sync after a mid-programme join).
 * - No HEVC codec profile (hvc1 tag, dynamic ranges): HEVC is never offered for the stream.
 */
object PlaybackInfoHandshake {
    const val SEGMENT_CONTAINER = "ts"
    const val VIDEO_CODECS = "h264"
    const val AUDIO_CODECS = "aac"

    /**
     * No subtitle stream goes into the video (JellyfinPlaybackResolver.noSubtitleStream). Left
     * to itself the server picks a track by the account's subtitle mode and burns it in: a full
     * re-encode, subtitles in the guide preview, no way to turn them off (measured on the Apple
     * TV against Jellyfin 12.2.0 and Emby 4.10.1.0). Honoured only with a matching MediaSourceId.
     */
    const val NO_SUBTITLE_STREAM = -1

    /** Every subtitle format either server names (JellyfinPlaybackResolver.subtitleFormats). */
    val SUBTITLE_FORMATS = listOf(
        "srt", "subrip", "ass", "ssa", "vtt", "webvtt", "mov_text", "ttml", "sub", "smi", "sami",
        "pgs", "pgssub", "dvdsub", "vobsub", "dvbsub", "sup", "xsub",
    )

    /** "External" for every format, or "Encode" when burning the forced track. Image formats too: without them PGS was still burned. */
    fun subtitleProfiles(burning: Boolean): JsonArray = buildJsonArray {
        for (f in SUBTITLE_FORMATS) add(buildJsonObject { put("Format", f); put("Method", if (burning) "Encode" else "External") })
    }

    /**
     * What the server is told this device plays. The H.264 bit-depth cap is the Apple TV's: a
     * 10-bit H.264 source copied into the stream has no hardware decoder to play it, so it is
     * re-encoded to 8-bit. Not required, so a file with no reported depth is copied as before.
     */
    fun deviceProfile(maxBitrateBps: Long, burningSubtitle: Boolean = false): JsonObject = buildJsonObject {
        put("MaxStreamingBitrate", maxBitrateBps)
        put("MaxStaticBitrate", maxBitrateBps)
        put("DirectPlayProfiles", JsonArray(emptyList()))
        put("TranscodingProfiles", buildJsonArray {
            add(buildJsonObject {
                put("Container", SEGMENT_CONTAINER)
                put("Type", "Video")
                put("VideoCodec", VIDEO_CODECS)
                put("AudioCodec", AUDIO_CODECS)
                put("Context", "Streaming")
                put("MaxAudioChannels", "6")
                put("Protocol", "hls")
            })
        })
        put("CodecProfiles", buildJsonArray {
            add(buildJsonObject {
                put("Type", "Video")
                put("Codec", "h264")
                put("Conditions", buildJsonArray {
                    add(buildJsonObject {
                        put("Condition", "LessThanEqual"); put("Property", "VideoBitDepth"); put("Value", "8"); put("IsRequired", false)
                    })
                })
            })
        })
        put("SubtitleProfiles", subtitleProfiles(burningSubtitle))
    }

    /**
     * The POST body (PlaybackInfoBody). `serverStreamOnly` is the retry after a direct play that
     * failed: both flags false, because Emby with only `EnableDirectPlay=false` still reported
     * `SupportsDirectStream` and no TranscodingUrl (measured on the Apple TV, 2026-10-13). On
     * the first attempt the keys are left out and the server decides as it always has.
     */
    fun body(mediaSourceId: String, maxBitrateBps: Long, serverStreamOnly: Boolean, burningSubtitle: Int? = null): JsonObject = buildJsonObject {
        put("DeviceProfile", deviceProfile(maxBitrateBps, burningSubtitle != null))
        put("MediaSourceId", mediaSourceId)
        put("MaxStreamingBitrate", maxBitrateBps)
        put("SubtitleStreamIndex", burningSubtitle ?: NO_SUBTITLE_STREAM)
        if (serverStreamOnly) {
            put("EnableDirectPlay", false)
            put("EnableDirectStream", false)
        }
    }

    data class Stream(
        val index: Int?, val type: String?, val language: String?, val isDefault: Boolean,
        val isForced: Boolean, val channels: Int?, val codec: String?,
        /** Title and DisplayTitle, for the commentary rule (#286). */
        val title: String? = null, val displayTitle: String? = null,
    )

    data class Source(
        val id: String?, val supportsDirectPlay: Boolean, val transcodingUrl: String?, val streams: List<Stream>,
    )

    data class Response(val playSessionId: String?, val sources: List<Source>)

    private val json = Json { ignoreUnknownKeys = true }

    fun parse(text: String): Response {
        val o = json.parseToJsonElement(text).jsonObject
        fun JsonObject.s(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
        fun JsonObject.b(k: String) = (this[k] as? JsonPrimitive)?.booleanOrNull == true
        fun JsonObject.i(k: String) = (this[k] as? JsonPrimitive)?.intOrNull
        val sources = (o["MediaSources"] as? JsonArray)?.map { it.jsonObject }?.map { s ->
            Source(
                id = s.s("Id"),
                supportsDirectPlay = s.b("SupportsDirectPlay"),
                transcodingUrl = s.s("TranscodingUrl"),
                streams = (s["MediaStreams"] as? JsonArray)?.map { it.jsonObject }?.map { m ->
                    Stream(m.i("Index"), m.s("Type"), m.s("Language"), m.b("IsDefault"), m.b("IsForced"), m.i("Channels"), m.s("Codec"), m.s("Title"), m.s("DisplayTitle"))
                } ?: emptyList(),
            )
        } ?: emptyList()
        return Response(o.s("PlaySessionId"), sources)
    }

    /** The source answered for: the one asked about, else the first. */
    fun source(info: Response, mediaSourceId: String?): Source? =
        info.sources.firstOrNull { it.id == mediaSourceId } ?: info.sources.firstOrNull()

    /**
     * The forced subtitle track to burn in, or null (forcedSubtitleToBurn): a track flagged
     * forced, in the viewer's subtitle language, is always shown, as the lines a film means to
     * be read. Neither server puts a subtitle track into its HLS stream, so the server burns it
     * in, at the cost of a re-encode for these files only. A default-only track never is.
     */
    fun forcedSubtitleToBurn(streams: List<Stream>?, preferredLanguage: String): Int? =
        streams?.firstOrNull {
            it.type?.lowercase() == "subtitle" && it.isForced && LanguageChoice.sameLanguage(it.language, preferredLanguage)
        }?.index

    /** The source's audio tracks, for [LanguageChoice.preferredAudioIndex]. */
    fun audioStreams(streams: List<Stream>?): List<AudioStream> =
        streams.orEmpty().filter { it.type?.lowercase() == "audio" && it.index != null }.map {
            AudioStream(index = it.index!!, lang = it.language?.lowercase() ?: "", codec = it.codec ?: "", channels = it.channels ?: 0, isDefault = it.isDefault,
                title = it.displayTitle ?: "", rawTitle = it.title ?: "")
        }

    data class Resolution(val url: String, val playSessionId: String?, val isDirectPlay: Boolean)

    /**
     * The stream to play from an answer (JellyfinPlaybackResolver.resolve): the server's
     * TranscodingUrl as it built it, with an api_key for servers older than ApiKey and the audio
     * track pinned; else the stored file when the server offers it and this is not the retry
     * after it failed; else null, and the caller uses its hand-built stream.
     */
    fun resolve(
        info: Response, serverUrl: String, apiKey: String, itemId: String, mediaSourceId: String?,
        serverStreamOnly: Boolean, audioLanguages: List<String>,
    ): Resolution? {
        val source = source(info, mediaSourceId)
        val relative = source?.transcodingUrl
        if (!relative.isNullOrEmpty()) {
            val absolute = if (relative.startsWith("http")) relative else serverUrl + relative
            var url = withParam(absolute, "api_key", apiKey, replace = false)
            LanguageChoice.preferredAudioIndex(audioStreams(source.streams), audioLanguages)?.let {
                url = withParam(url, "AudioStreamIndex", it.toString(), replace = true)
            }
            return Resolution(url, info.playSessionId, isDirectPlay = false)
        }
        if (!serverStreamOnly && source?.supportsDirectPlay == true) {
            return Resolution(staticStreamUrl(serverUrl, itemId, source.id ?: mediaSourceId ?: itemId, apiKey), info.playSessionId, isDirectPlay = true)
        }
        return null
    }

    /** The stored file, served whole and labelled `video/mp4` (staticStreamURL), with ApiKey for Jellyfin 12 without legacy authorization. */
    fun staticStreamUrl(serverUrl: String, itemId: String, mediaSourceId: String, apiKey: String): String =
        "$serverUrl/Videos/$itemId/stream.mp4?Static=true&MediaSourceId=${enc(mediaSourceId)}&api_key=${enc(apiKey)}&ApiKey=${enc(apiKey)}"

    /**
     * The exchange (JellyfinPlaybackResolver.negotiate): the usual question, then a second one
     * only when the answer lists a forced track in the viewer's language. If the second fails
     * or offers nothing playable, the first answer is used: the film without its forced lines
     * beats no film. Throws only when the first request does. `send` posts a body and returns
     * the answer's text, throwing on an HTTP error.
     *
     * A burned stream is chosen only once its first segment is served (`burnedStreamServes`
     * through `probe`). A server that can't burn says so there, not in PlaybackInfo: Chad's Emby
     * 4.10.1 serves both playlists, then answers every segment with HTTP 500, and without this
     * the player only finds out when the startup watchdog gives up. The session refused is
     * stopped through `stopRefused`, since nothing else will ever see it.
     */
    fun negotiate(
        send: (JsonObject) -> String,
        serverUrl: String, apiKey: String, itemId: String, mediaSourceId: String,
        maxBitrateBps: Long, serverStreamOnly: Boolean, subtitleLanguage: String, audioLanguages: List<String>,
        log: (String) -> Unit = {},
        probe: Probe? = null,
        stopRefused: (String) -> Unit = {},
    ): Resolution? {
        val info = parse(send(body(mediaSourceId, maxBitrateBps, serverStreamOnly)))
        fun resolved(i: Response) = resolve(i, serverUrl, apiKey, itemId, mediaSourceId, serverStreamOnly, audioLanguages)
        val forced = forcedSubtitleToBurn(source(info, mediaSourceId)?.streams, subtitleLanguage)
        if (forced != null) {
            val burned = runCatching { resolved(parse(send(body(mediaSourceId, maxBitrateBps, serverStreamOnly, forced)))) }
                .onFailure { log("burning forced subtitle $forced failed: $it") }.getOrNull()
            if (burned != null) {
                if (burned.isDirectPlay || probe == null || burnedStreamServes(burned.url, probe)) return burned
                log("the server refused the burned-in stream's first segment, playing without the forced subtitle")
                burned.playSessionId?.let(stopRefused)
            }
        }
        return resolved(info)
    }

    /** One GET with no header added, as the player asks: the status and the body's text, or null when it timed out or failed. */
    fun interface Probe {
        fun get(url: String): Pair<Int, String?>?
    }

    /** Longest the check waits on one request, as the PlaybackInfo requests: a slow first segment is not a refusal. */
    const val BURN_PROBE_TIMEOUT_MS = 12_000L

    /**
     * Fetches what the player fetches first (burnedStreamServes): the master playlist, its first
     * variant, that playlist's first segment. False only when the server answers one of them
     * with an HTTP error. A timeout, a dropped connection or a playlist this can't read prove
     * nothing, so they count as served. URLs are the ones the playlists give, resolved against
     * the playlist they came from, queries kept.
     */
    fun burnedStreamServes(url: String, probe: Probe): Boolean {
        fun firstEntry(text: String, base: String): String? =
            text.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() && !it.startsWith("#") }
                ?.let { runCatching { URI(base).resolve(it).toString() }.getOrNull() }
        val master = probe.get(url) ?: return true
        if (master.first !in 200..299) return false
        val masterText = master.second?.takeIf { it.startsWith("#EXTM3U") } ?: return true
        var playlistUrl = url
        var playlistText = masterText
        if (masterText.contains("#EXT-X-STREAM-INF")) {
            val variantUrl = firstEntry(masterText, url) ?: return true
            val variant = probe.get(variantUrl) ?: return true
            if (variant.first !in 200..299) return false
            playlistText = variant.second?.takeIf { it.startsWith("#EXTM3U") } ?: return true
            playlistUrl = variantUrl
        }
        if (!playlistText.contains("#EXTINF")) return true
        val segmentUrl = firstEntry(playlistText, playlistUrl) ?: return true
        val segment = probe.get(segmentUrl) ?: return true
        return segment.first in 200..299
    }

    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8").replace("+", "%20")

    /** Adds `name=value` to a URL's query; `replace` drops any value already there, otherwise an existing one is kept. */
    fun withParam(url: String, name: String, value: String, replace: Boolean): String {
        val q = url.indexOf('?')
        val base = if (q < 0) url else url.substring(0, q)
        val params = if (q < 0) mutableListOf() else url.substring(q + 1).split('&').filter { it.isNotEmpty() }.toMutableList()
        val present = params.any { it.substringBefore('=') == name }
        if (present && !replace) return url
        params.removeAll { it.substringBefore('=') == name }
        params += "$name=${enc(value)}"
        return base + "?" + params.joinToString("&")
    }
}
