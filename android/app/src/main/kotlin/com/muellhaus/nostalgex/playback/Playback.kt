package com.muellhaus.nostalgex.playback

import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem as ExoItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import com.muellhaus.nostalgex.engine.MediaItem
import com.muellhaus.nostalgex.engine.PlaybackFailure
import com.muellhaus.nostalgex.engine.StreamQuality
import com.muellhaus.nostalgex.mediabrowser.MediaBrowserClient
import com.muellhaus.nostalgex.mediabrowser.MediaBrowserServer
import com.muellhaus.nostalgex.plex.PlexClient
import java.util.UUID

/** How a programme reached the screen. */
enum class Delivery(val label: String) { DIRECT_PLAY("DIRECT PLAY"), TRANSCODE("TRANSCODE") }

/**
 * One ExoPlayer for the whole session. Each programme tries direct play first, the file as
 * the server stores it, and falls back to the server's HLS transcode when the player fails or
 * a track it needs has no decoder here. Plex, Jellyfin and Emby take the same path; only the
 * URLs and the way a transcode is stopped differ. The web tuner can only direct play MP4, WebM and MOV;
 * finding out how much more a SHIELD plays directly is what this spike is for, so every
 * decision is logged under the "Nostalgex" tag (`adb logcat -s Nostalgex`).
 */
@OptIn(UnstableApi::class)
class Playback(
    context: Context,
    private val plex: PlexClient,
    private val mediaBrowser: MediaBrowserClient,
    private val listener: Listener,
) {
    /** The Jellyfin or Emby server signed in to; null on Plex. */
    var mediaBrowserServer: MediaBrowserServer? = null

    /** The server's name in failure cards, as the Apple TV's backendDisplayName. */
    private val serverName get() = mediaBrowserServer?.let { MediaBrowserClient.displayName(it.kind) } ?: "Plex"

    interface Listener {
        fun onStarted(item: MediaItem, delivery: Delivery)
        /** The programme played to its end. */
        fun onEnded(item: MediaItem)
        /** Neither direct play nor a transcode worked, and why (PlaybackFailure.classify). */
        fun onFailed(item: MediaItem, failure: PlaybackFailure)
        /** What PLAYBACK INFORMATION shows changed. */
        fun onInfo(info: PlaybackInfo)
    }

    /** STREAM QUALITY, read when each programme starts (it never reaches a stream already playing). */
    var quality: StreamQuality = StreamQuality.AUTO

    private var info: PlaybackInfo? = null
        set(value) {
            field = value
            value?.let(listener::onInfo)
        }

    private data class Current(val item: MediaItem, val offsetSec: Long, val delivery: Delivery, val session: String?, val startedAtMs: Long)

    private var current: Current? = null
    private var started = false
    /** A frame reached the screen for the programme on: proof the device can decode it. */
    private var firstFrame = false

    private val http = DefaultHttpDataSource.Factory()
        .setDefaultRequestProperties(plex.headers)
        .setAllowCrossProtocolRedirects(true)

    val player: ExoPlayer = ExoPlayer.Builder(context)
        .setMediaSourceFactory(DefaultMediaSourceFactory(http).setLoadErrorHandlingPolicy(NoRetryOnHttpError))
        .build()
        .apply {
            playWhenReady = true
            addListener(object : Player.Listener {
                override fun onPlaybackStateChanged(state: Int) {
                    val c = current ?: return
                    when (state) {
                        Player.STATE_READY -> if (!started) {
                            started = true
                            info = info?.copy(ready = true)
                            Log.i(TAG, "STARTED ${c.delivery.label} ${describe(c.item)} in ${System.currentTimeMillis() - c.startedAtMs} ms at ${currentPosition / 1000}s of ${duration / 1000}s")
                            listener.onStarted(c.item, c.delivery)
                        }
                        Player.STATE_ENDED -> listener.onEnded(c.item)
                    }
                }

                override fun onTracksChanged(tracks: Tracks) {
                    val c = current ?: return
                    if (c.delivery != Delivery.DIRECT_PLAY) return
                    // A track the device can't decode is skipped without an error: a film with
                    // DTS and no receiver would play silent. That counts as a failure here.
                    for (type in listOf(C.TRACK_TYPE_VIDEO, C.TRACK_TYPE_AUDIO)) {
                        val groups = tracks.groups.filter { it.type == type }
                        if (groups.isNotEmpty() && groups.none { it.isSupported }) {
                            val formats = groups.flatMap { g -> (0 until g.length).map { g.getTrackFormat(it).sampleMimeType } }
                            fallBack(c, "no decoder for ${if (type == C.TRACK_TYPE_VIDEO) "video" else "audio"} $formats")
                            return
                        }
                    }
                }

                override fun onRenderedFirstFrame() {
                    firstFrame = true
                }

                override fun onPlayerError(error: PlaybackException) {
                    val c = current ?: return
                    if (c.delivery == Delivery.DIRECT_PLAY) {
                        fallBack(c, "${error.errorCodeName}: ${error.message}")
                    } else {
                        val failure = PlaybackFailure.classify(serverName, evidence(error, c.item))
                        Log.w(TAG, "FAILED TRANSCODE ${describe(c.item)}: ${error.errorCodeName}; ${failure.headline}", error)
                        stopSession()
                        listener.onFailed(c.item, failure)
                    }
                }
            })
        }

    fun play(item: MediaItem, offsetSec: Long) {
        stopSession()
        val q = quality
        info = PlaybackInfo(qualityAtTune = q, videoCodec = item.videoCodec, audioCodec = item.audioCodec)
        // Away from home a file over the level's ceiling is transcoded: direct play can't step
        // down when the connection can't carry it (PlexAPIService.buildDirectPlayURL).
        val overCeiling = !StreamQuality.isLikelyLocalServer(item.serverUrl) && (item.bitrate ?: 0) > q.remoteDirectPlayCeilingKbps
        if (overCeiling) Log.i(TAG, "SKIP DIRECT PLAY ${describe(item)}: ${item.bitrate} kbps over the remote ceiling of ${q.remoteDirectPlayCeilingKbps}")
        val delivery = if (canTryDirectPlay(item) && !overCeiling) Delivery.DIRECT_PLAY else Delivery.TRANSCODE
        start(item, offsetSec, delivery, if (delivery == Delivery.TRANSCODE) PlaybackInfo.Reason.SERVER_STREAM_SELECTED else PlaybackInfo.Reason.NONE)
    }

    private fun fallBack(c: Current, reason: String) {
        // Resume where the direct play got to, or the planned offset if it never started.
        val at = if (started) player.currentPosition / 1000 else c.offsetSec
        Log.i(TAG, "DIRECT PLAY FAILED ${describe(c.item)}: $reason; transcoding from ${at}s")
        start(c.item, at, Delivery.TRANSCODE, PlaybackInfo.Reason.DIRECT_PLAY_FAILED)
    }

    private fun start(item: MediaItem, offsetSec: Long, delivery: Delivery, reason: PlaybackInfo.Reason) {
        val server = item.serverUrl ?: return listener.onFailed(item, PlaybackFailure.NoPlayableSource(serverName))
        val token = item.serverToken ?: ""
        started = false
        firstFrame = false
        info = info?.copy(delivery = delivery, reason = reason, ready = false)
        val q = info?.qualityAtTune ?: quality
        val mb = mediaBrowserServer
        val exo = if (mb != null) mediaBrowserItem(mb, item, offsetSec, delivery, q) else when (delivery) {
            Delivery.DIRECT_PLAY -> {
                current = Current(item, offsetSec, delivery, null, System.currentTimeMillis())
                ExoItem.Builder().setUri("$server${item.partKey}?X-Plex-Token=${Uri.encode(token)}").build()
            }
            Delivery.TRANSCODE -> {
                // The web tuner's request (plex-tuner.html playCurrentItem), with its own session
                // id so a channel change can stop exactly this transcode and no other.
                val session = UUID.randomUUID().toString()
                current = Current(item, offsetSec, delivery, session, System.currentTimeMillis())
                val url = Uri.parse("$server/video/:/transcode/universal/start.m3u8").buildUpon()
                    .appendQueryParameter("path", "/library/metadata/${item.ratingKey}")
                    .appendQueryParameter("mediaIndex", "0")
                    .appendQueryParameter("partIndex", "0")
                    .appendQueryParameter("protocol", "hls")
                    .appendQueryParameter("offset", offsetSec.toString())
                    .appendQueryParameter("copyts", "1")
                    .appendQueryParameter("X-Plex-Token", token)
                    .appendQueryParameter("session", session)
                    .appendQueryParameter("X-Plex-Session-Identifier", session)
                    .appendQueryParameter("X-Plex-Client-Identifier", plex.headers.getValue("X-Plex-Client-Identifier"))
                    .appendQueryParameter("X-Plex-Product", "Nostalgex")
                    .appendQueryParameter("X-Plex-Platform", "Android")
                    .appendQueryParameter("X-Plex-Device", "Android TV")
                    // STREAM QUALITY, as the Apple TV asks for it; quality stepping stays off
                    // (StreamQuality.allowsAutoAdjust: it starved segments on Plex, measured).
                    .appendQueryParameter("location", if (StreamQuality.isLikelyLocalServer(server)) "lan" else "wan")
                    .appendQueryParameter("maxVideoBitrate", q.maxBitrateKbps.toString())
                    .appendQueryParameter("videoQuality", q.videoQualityIndex.toString())
                    .appendQueryParameter("videoResolution", q.resolutionString)
                    .appendQueryParameter("autoAdjustQuality", "0")
                    .build()
                ExoItem.Builder().setUri(url).setMimeType(MimeTypes.APPLICATION_M3U8).build()
            }
        }
        Log.i(TAG, "TRY ${delivery.label} ${describe(item)} from ${offsetSec}s")
        player.playWhenReady = true
        player.setMediaItem(exo, offsetSec * 1000)
        player.prepare()
    }

    /**
     * Jellyfin and Emby, as the web tuner's nostalgex-jellyfin-urls.js. Direct play is the file
     * as stored (`Static=true`), labelled `stream.mp4` for the MP4 family so the server sends
     * `video/mp4` rather than going by the file's name. The transcode is the hand-built HLS
     * request in MPEG-TS, H.264 and AAC, with its own PlaySessionId so a channel change stops
     * exactly this encode. It carries no start time: Jellyfin copies the query onto every
     * segment URL and refuses `StartTimeTicks` there with HTTP 400, so the player seeks
     * instead (JellyfinPlaybackResolver.offsetPlayback), which `setMediaItem` does.
     */
    private fun mediaBrowserItem(mb: MediaBrowserServer, item: MediaItem, offsetSec: Long, delivery: Delivery, q: StreamQuality): ExoItem {
        val source = item.partKey ?: item.ratingKey
        return when (delivery) {
            Delivery.DIRECT_PLAY -> {
                current = Current(item, offsetSec, delivery, null, System.currentTimeMillis())
                val path = if (isMp4Family(item.container)) "stream.mp4" else "stream"
                val url = Uri.parse("${mb.url}/Videos/${item.ratingKey}/$path").buildUpon()
                    .appendQueryParameter("Static", "true")
                    .appendQueryParameter("MediaSourceId", source)
                    // Jellyfin 12 with legacy authorization off (a new install) answers 401
                    // to api_key alone; api_key stays for servers older than ApiKey.
                    .appendQueryParameter("api_key", mb.token)
                    .appendQueryParameter("ApiKey", mb.token)
                    .build()
                ExoItem.Builder().setUri(url).build()
            }
            Delivery.TRANSCODE -> {
                val session = UUID.randomUUID().toString().replace("-", "")
                current = Current(item, offsetSec, delivery, session, System.currentTimeMillis())
                val url = Uri.parse("${mb.url}/Videos/${item.ratingKey}/master.m3u8").buildUpon()
                    .appendQueryParameter("MediaSourceId", source)
                    .appendQueryParameter("api_key", mb.token)
                    .appendQueryParameter("ApiKey", mb.token)
                    .appendQueryParameter("VideoCodec", "h264")
                    .appendQueryParameter("AudioCodec", "aac")
                    .appendQueryParameter("MaxWidth", q.width.toString())
                    .appendQueryParameter("VideoBitrate", (q.maxBitrateKbps * 1000L).toString())
                    .appendQueryParameter("SegmentContainer", "ts")
                    .appendQueryParameter("DeviceId", mediaBrowser.deviceId)
                    .appendQueryParameter("PlaySessionId", session)
                    .build()
                ExoItem.Builder().setUri(url).setMimeType(MimeTypes.APPLICATION_M3U8).build()
            }
        }
    }

    /** Ends this app's transcode, once: the session is forgotten as soon as its stop is sent. */
    private fun stopSession() {
        val c = current ?: return
        val session = c.session ?: return
        current = c.copy(session = null)
        val mb = mediaBrowserServer
        if (mb != null) mediaBrowser.stopEncoding(mb, session)
        else plex.stopTranscode(c.item.serverUrl ?: return, c.item.serverToken ?: "", session)
    }

    /** Pauses on the picture and ends any transcode, for the sleep timer; the next tune plays again. */
    fun pause() {
        stopSession()
        player.pause()
    }

    fun stop() {
        stopSession()
        current = null
        info = null
        player.stop()
    }

    fun release() {
        stop()
        player.release()
    }

    /** What the player saw, in PlaybackFailure's terms. */
    private fun evidence(error: PlaybackException, item: MediaItem): PlaybackFailure.Evidence {
        var status: Int? = null
        var cause: Throwable? = error
        while (cause != null && status == null) {
            if (cause is HttpDataSource.InvalidResponseCodeException) status = cause.responseCode
            cause = cause.cause
        }
        val code = error.errorCode
        return PlaybackFailure.Evidence(
            httpStatuses = listOfNotNull(status ?: if (code == PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND) 404 else null),
            unreachable = code == PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED ||
                code == PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
            decoderFailed = code in 4001..4005,
            everShowedPicture = started,
            decodedAFrame = firstFrame,
            sourceCodec = item.videoCodec,
        )
    }

    /**
     * A server that answered with an HTTP error has said no: the load fails at once and the
     * card shows, as the Apple TV ends a load early when the server already refused. Left to
     * ExoPlayer's default, each refused request was asked again until it gave up: measured
     * against a server answering HTTP 500, 30 transcode requests for 5 programmes. Network
     * errors keep the default retries.
     */
    private object NoRetryOnHttpError : DefaultLoadErrorHandlingPolicy() {
        override fun getRetryDelayMsFor(info: LoadErrorHandlingPolicy.LoadErrorInfo): Long =
            if (info.exception is HttpDataSource.InvalidResponseCodeException) C.TIME_UNSET else super.getRetryDelayMsFor(info)
    }

    companion object {
        private const val TAG = "Nostalgex"

        /** Containers Media3 has an extractor for. The codecs are the device's question; tracks tell. */
        private val DIRECT_CONTAINERS = setOf("mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "mpegts", "flv", "ogg")

        /** Jellyfin can report ffprobe's comma list ("mov,mp4,m4a,3gp,3g2,mj2"). */
        private fun containers(item: MediaItem) = item.container?.lowercase()?.split(',')?.map { it.trim() } ?: emptyList()

        fun canTryDirectPlay(item: MediaItem) =
            item.partKey != null && containers(item).any { it in DIRECT_CONTAINERS }

        private fun isMp4Family(container: String?) =
            container?.lowercase()?.split(',')?.any { it.trim() in setOf("mp4", "m4v", "mov") } == true

        fun describe(item: MediaItem) =
            "\"${item.title}${item.episodeTitle?.let { " / $it" } ?: ""}\" [${item.container}/${item.videoCodec}/${item.audioCodec}] key=${item.ratingKey}"
    }
}
