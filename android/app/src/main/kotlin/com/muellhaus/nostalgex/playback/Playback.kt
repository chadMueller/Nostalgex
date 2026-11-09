package com.muellhaus.nostalgex.playback

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
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
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.LoadEventInfo
import androidx.media3.exoplayer.source.MediaLoadData
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import com.muellhaus.nostalgex.engine.DemoData
import com.muellhaus.nostalgex.engine.LanguageChoice
import com.muellhaus.nostalgex.engine.MediaItem
import com.muellhaus.nostalgex.engine.PlaybackFailure
import com.muellhaus.nostalgex.engine.PlaybackInfoHandshake
import com.muellhaus.nostalgex.engine.PlaybackStarvation
import com.muellhaus.nostalgex.engine.PlaybackWatchdog
import com.muellhaus.nostalgex.engine.StreamQuality
import com.muellhaus.nostalgex.mediabrowser.MediaBrowserClient
import com.muellhaus.nostalgex.mediabrowser.MediaBrowserServer
import com.muellhaus.nostalgex.plex.PlexClient
import java.io.IOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.UUID

/** How a programme reached the screen. */
enum class Delivery(val label: String) { DIRECT_PLAY("DIRECT PLAY"), TRANSCODE("TRANSCODE") }

/**
 * One ExoPlayer for the whole session. Each programme tries direct play first, the file as
 * the server stores it, and falls back to the server's HLS transcode when the player fails or
 * a track it needs has no decoder here. Plex, Jellyfin and Emby take the same path; only the
 * URLs and the way a transcode is stopped differ. Every decision is logged under the
 * "Nostalgex" tag (`adb logcat -s Nostalgex`).
 *
 * The Apple TV's recovery ladder (AppState+Playback.swift) watches every attempt:
 * - The startup watchdog ([PlaybackWatchdog]): no picture by the deadline (15 s direct, 20 s
 *   a transcode) moves a direct play to the server stream, and a transcode to one retry capped
 *   at 1080p, then to the failure card.
 * - The starvation monitor ([PlaybackStarvation]), once a second after picture: a source that
 *   can't keep up moves a direct play to the server stream and a transcode to the capped
 *   retry, from where the viewer is; a capped stream that starves too ends in "Your server
 *   couldn't keep up".
 * Each attempt has a number; a callback from an earlier one does nothing.
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
        /** The watchdog saw a picture: a decoded frame and a moving playhead (PlaybackWatchdog.hasPicture). */
        fun onPicture(item: MediaItem)
        /** The programme played to its end. */
        fun onEnded(item: MediaItem)
        /** Nothing on the ladder worked, and why (PlaybackFailure.classify). */
        fun onFailed(item: MediaItem, failure: PlaybackFailure)
        /** What PLAYBACK INFORMATION shows changed. */
        fun onInfo(info: PlaybackInfo)
    }

    /** The viewer's languages (AUDIO LANGUAGE, resolved), for the track a Jellyfin or Emby transcode carries. */
    var audioLanguages: List<String> = emptyList()

    /** The viewer's subtitle language (SUBTITLE LANGUAGE, resolved), for a forced track a server stream burns in. */
    var subtitleLanguage: String = "en"

    /** PlaybackInfo requests, off the main thread; a pool, so one hung request never holds up the next tune. */
    private val handshakes = java.util.concurrent.Executors.newCachedThreadPool()

    /**
     * Demo mode (AppState.isDemoMode): every programme plays [DemoData.STREAM_URL], seeked to the
     * clock modulo the clip, as the Apple TV's demo. No server is asked anything.
     */
    var demo = false

    /** STREAM QUALITY, read when each programme starts (it never reaches a stream already playing). */
    var quality: StreamQuality = StreamQuality.AUTO

    private var info: PlaybackInfo? = null
        set(value) {
            field = value
            value?.let(listener::onInfo)
        }

    /**
     * The attempt on screen. `capped` is the ladder's 1080p retry, the last rung. `requestedOffsetSec`
     * is the start time the request itself carried (Plex's `offset`), for [PlaybackWatchdog.hlsBaseOffset].
     */
    private data class Current(
        val item: MediaItem, val offsetSec: Long, val delivery: Delivery, val session: String?, val startedAtMs: Long,
        val capped: Boolean = false, val requestedOffsetSec: Long = 0,
        /** Demo mode's sample clip: nothing to fall back to, so the ladder's next step is the card. */
        val demo: Boolean = false,
    )

    private var current: Current? = null
    private var started = false
    /** A frame reached the screen for the programme on: proof the device can decode it. */
    private var firstFrame = false
    private var bufferingSinceMs = 0L
    /** Seconds to add to the player's clock for a transcode whose server rebased it to zero. */
    private var hlsBase = 0.0
    /** What the loads of this attempt saw, for the card when the watchdog gives up without a player error. */
    private var loadStatus: Int? = null
    private var loadUnreachable = false
    private var loadedBytes = false

    private val main = Handler(Looper.getMainLooper())

    /**
     * How much the player may buffer, in bytes: a quarter of the Java heap the app may grow to.
     * Media3's default for a network video is 2,000 x 64 KB (about 128 MB), held as Java byte
     * arrays, and a high-bitrate file fills it in seconds. Measured on an Android 16 Google TV
     * emulator, an 80 Mbps file took the heap from 39 MB to 167 MB. With a large library on
     * top, a Google TV that caps an app at 192 MB ran out of memory 15 seconds into a 4K film.
     * A quarter is 48 MB at 192 MB (about 5 s of 80 Mbps, 13 s of 30 Mbps), 96 MB at 384 MB and
     * 128 MB at 512 MB, never more than the default video and audio buffers together.
     */
    private fun bufferBytes(context: Context): Int {
        val max = Runtime.getRuntime().maxMemory()
        val cap = (max / 4).coerceIn(16L * 1024 * 1024, DefaultLoadControl.DEFAULT_VIDEO_BUFFER_SIZE.toLong() + DefaultLoadControl.DEFAULT_AUDIO_BUFFER_SIZE).toInt()
        // Once, as the player is made, so a log says whether largeHeap took on this TV: the heap
        // limit matches the large class when it did, the standard class when it didn't.
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? android.app.ActivityManager
        Log.i(TAG, "PLAYER BUFFER cap ${cap / MIB} MiB, a quarter of a ${max / MIB} MiB heap limit " +
            "(this TV: ${am?.memoryClass ?: "?"} MiB standard, ${am?.largeMemoryClass ?: "?"} MiB with largeHeap)")
        return cap
    }

    private var attempt = 0

    private val http = DefaultHttpDataSource.Factory()
        .setDefaultRequestProperties(plex.headers)
        .setAllowCrossProtocolRedirects(true)

    val player: ExoPlayer = ExoPlayer.Builder(context)
        .setMediaSourceFactory(DefaultMediaSourceFactory(http).setLoadErrorHandlingPolicy(NoRetryOnHttpError))
        .setLoadControl(DefaultLoadControl.Builder().setTargetBufferBytes(bufferBytes(context)).build())
        .build()
        .apply {
            playWhenReady = true
            addListener(object : Player.Listener {
                override fun onPlaybackStateChanged(state: Int) {
                    val c = current ?: return
                    // Every rebuffer once a programme is on, so a stall can be counted from the log.
                    if (started && state == Player.STATE_BUFFERING) {
                        bufferingSinceMs = System.currentTimeMillis()
                        Log.i(TAG, "BUFFERING at ${currentPosition / 1000}s")
                    } else if (started && state == Player.STATE_READY && bufferingSinceMs > 0) {
                        Log.i(TAG, "PLAYING again after ${System.currentTimeMillis() - bufferingSinceMs} ms")
                        bufferingSinceMs = 0
                    }
                    when (state) {
                        Player.STATE_READY -> if (!started) {
                            started = true
                            if (c.delivery == Delivery.TRANSCODE) hlsBase = PlaybackWatchdog.hlsBaseOffset(c.requestedOffsetSec, currentPosition / 1000.0)
                            info = info?.copy(ready = true)
                            Log.i(TAG, "STARTED ${c.delivery.label}${if (c.capped) " (capped at 1080p)" else ""} ${describe(c.item)} in " +
                                "${System.currentTimeMillis() - c.startedAtMs} ms at ${currentPosition / 1000}s of ${duration / 1000}s")
                            listener.onStarted(c.item, c.delivery)
                        }
                        Player.STATE_ENDED -> {
                            endAttempt()
                            listener.onEnded(c.item)
                        }
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
                            fallBack(c, "no decoder for ${if (type == C.TRACK_TYPE_VIDEO) "video" else "audio"} $formats", PlaybackInfo.Reason.DIRECT_PLAY_FAILED)
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
                        fallBack(c, "${error.errorCodeName}: ${error.message}", PlaybackInfo.Reason.DIRECT_PLAY_FAILED)
                    } else {
                        val failure = PlaybackFailure.classify(serverName, evidence(error, c.item))
                        Log.w(TAG, "FAILED TRANSCODE ${describe(c.item)}: ${error.errorCodeName}; ${failure.headline}", error)
                        fail(c, failure)
                    }
                }
            })
            // What each request answered, for a card the watchdog has to write without a player error.
            addAnalyticsListener(object : AnalyticsListener {
                override fun onLoadCompleted(eventTime: AnalyticsListener.EventTime, loadEventInfo: LoadEventInfo, mediaLoadData: MediaLoadData) {
                    if (loadEventInfo.bytesLoaded > 0) loadedBytes = true
                }

                override fun onLoadError(
                    eventTime: AnalyticsListener.EventTime, loadEventInfo: LoadEventInfo, mediaLoadData: MediaLoadData,
                    error: IOException, wasCanceled: Boolean,
                ) {
                    if (loadEventInfo.bytesLoaded > 0) loadedBytes = true
                    var cause: Throwable? = error
                    while (cause != null) {
                        if (cause is HttpDataSource.InvalidResponseCodeException) loadStatus = cause.responseCode
                        if (cause is SocketTimeoutException || cause is UnknownHostException || cause is java.net.ConnectException) loadUnreachable = true
                        cause = cause.cause
                    }
                }
            })
        }

    fun play(item: MediaItem, offsetSec: Long) {
        stopSession()
        val q = quality
        if (demo) {
            // The demo's PLAYBACK INFORMATION: backend Demo, no source codecs (beginPlaybackInformation).
            info = PlaybackInfo(qualityAtTune = q, videoCodec = null, audioCodec = null, backend = "Demo")
            return start(item, offsetSec, Delivery.TRANSCODE, PlaybackInfo.Reason.NONE)
        }
        info = PlaybackInfo(qualityAtTune = q, videoCodec = item.videoCodec, audioCodec = item.audioCodec, backend = serverName)
        // Away from home a file over the level's ceiling is transcoded: direct play can't step
        // down when the connection can't carry it (PlexAPIService.buildDirectPlayURL).
        val overCeiling = !StreamQuality.isLikelyLocalServer(item.serverUrl) && (item.bitrate ?: 0) > q.remoteDirectPlayCeilingKbps
        if (overCeiling) Log.i(TAG, "SKIP DIRECT PLAY ${describe(item)}: ${item.bitrate} kbps over the remote ceiling of ${q.remoteDirectPlayCeilingKbps}")
        val delivery = if (canTryDirectPlay(item) && !overCeiling) Delivery.DIRECT_PLAY else Delivery.TRANSCODE
        start(item, offsetSec, delivery, if (delivery == Delivery.TRANSCODE) PlaybackInfo.Reason.SERVER_STREAM_SELECTED else PlaybackInfo.Reason.NONE)
    }

    /** Where the viewer is in the programme, on the file's own clock. */
    private fun positionSec(): Long = maxOf(0L, (player.currentPosition / 1000.0 + hlsBase).toLong())

    /**
     * Resume where the direct play got to, or the planned offset if it never started. The
     * startup watchdog passes the planned offset (`atOffset`), as the Apple TV's does
     * (`beginServerFallback(position: seekOffset)`): a direct play that gave no picture may
     * still report a playhead, and it is not where the viewer is. Measured on the emulator: an
     * MKV whose video Media3 could not read went ready without its seek, played sound from 0 s
     * for 15 s, and the server stream then started at 14 s on a programme 137 s in.
     */
    private fun fallBack(c: Current, reason: String, infoReason: PlaybackInfo.Reason, atOffset: Boolean = false) {
        val at = if (started && !atOffset) positionSec() else c.offsetSec
        Log.i(TAG, "DIRECT PLAY FAILED ${describe(c.item)}: $reason; transcoding from ${at}s")
        start(c.item, at, Delivery.TRANSCODE, infoReason, serverStreamOnly = true)
    }

    /** The last rung: the server stream again, asked for no more than 1080p (cappedTranscodeURL). */
    private fun capped(c: Current, at: Long, why: String, infoReason: PlaybackInfo.Reason) {
        Log.i(TAG, "CAPPED RETRY ${describe(c.item)}: $why; transcoding at up to 1080p from ${at}s")
        stopSession()
        start(c.item, at, Delivery.TRANSCODE, infoReason, capped = true)
    }

    /** Gives up on this programme: its transcode stopped, its timers off, the card shown. */
    private fun fail(c: Current, failure: PlaybackFailure) {
        endAttempt()
        stopSession()
        listener.onFailed(c.item, failure)
    }

    /** Callbacks from the attempt on screen stop counting. */
    private fun endAttempt() {
        attempt++
        main.removeCallbacksAndMessages(null)
    }

    /**
     * One attempt. `serverStreamOnly` is the retry after a direct play failed: on Jellyfin and
     * Emby the PlaybackInfo handshake is then asked not to offer the stored file again.
     */
    private fun start(
        item: MediaItem, offsetSec: Long, delivery: Delivery, reason: PlaybackInfo.Reason,
        capped: Boolean = false, serverStreamOnly: Boolean = false,
    ) {
        endAttempt()
        started = false
        firstFrame = false
        bufferingSinceMs = 0
        hlsBase = 0.0
        loadStatus = null
        loadUnreachable = false
        loadedBytes = false
        info = info?.copy(delivery = delivery, reason = reason, ready = false, capped = capped)
        if (demo) return startDemo(item, offsetSec)
        val server = item.serverUrl ?: return listener.onFailed(item, PlaybackFailure.NoPlayableSource(serverName))
        val token = item.serverToken ?: ""
        // The capped retry is the Apple TV's `.high` preset whatever was chosen: 1080p, 12 Mbps.
        val q = if (capped) StreamQuality.HIGH else info?.qualityAtTune ?: quality
        val mb = mediaBrowserServer
        if (mb != null && delivery == Delivery.TRANSCODE && !capped) return handshake(mb, item, offsetSec, q, serverStreamOnly)
        val exo = if (mb != null) mediaBrowserItem(mb, item, offsetSec, delivery, q, capped) else when (delivery) {
            Delivery.DIRECT_PLAY -> {
                current = Current(item, offsetSec, delivery, null, System.currentTimeMillis())
                ExoItem.Builder().setUri("$server${item.partKey}?X-Plex-Token=${Uri.encode(token)}").build()
            }
            Delivery.TRANSCODE -> {
                // The web tuner's request (plex-tuner.html playCurrentItem), with its own session
                // id so a channel change can stop exactly this transcode and no other.
                val session = UUID.randomUUID().toString()
                current = Current(item, offsetSec, delivery, session, System.currentTimeMillis(), capped, requestedOffsetSec = offsetSec)
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
        load(exo, item, offsetSec, delivery, capped)
    }

    /**
     * The demo clip, through a data source with no headers of this app's: Apple's CDN gets
     * nothing that identifies this install. It seeks to the clock modulo the clip's 600 s, since
     * most tune-ins land further into a block than the clip runs (playerSeekSeconds).
     */
    private fun startDemo(item: MediaItem, offsetSec: Long) {
        current = Current(item, offsetSec, Delivery.TRANSCODE, null, System.currentTimeMillis(), demo = true)
        val at = DemoData.clipOffset(offsetSec)
        Log.i(TAG, "TRY DEMO ${describe(item)} at ${offsetSec}s of the programme, ${at}s into the clip")
        val source = demoSources.createMediaSource(ExoItem.Builder().setUri(DemoData.STREAM_URL).setMimeType(MimeTypes.APPLICATION_M3U8).build())
        player.playWhenReady = true
        player.setMediaSource(source, at * 1000)
        player.prepare()
        current?.let { watch(attempt, it) }
    }

    private val demoSources by lazy {
        DefaultMediaSourceFactory(DefaultHttpDataSource.Factory().setAllowCrossProtocolRedirects(true))
            .setLoadErrorHandlingPolicy(NoRetryOnHttpError)
    }

    private fun load(exo: ExoItem, item: MediaItem, offsetSec: Long, delivery: Delivery, capped: Boolean) {
        Log.i(TAG, "TRY ${delivery.label}${if (capped) " (capped at 1080p)" else ""} ${describe(item)} from ${offsetSec}s")
        player.playWhenReady = true
        player.setMediaItem(exo, offsetSec * 1000)
        player.prepare()
        current?.let { watch(attempt, it) }
    }

    /**
     * Jellyfin and Emby: ask the server how to stream this (PlaybackInfoHandshake, the Apple TV's
     * resolveTranscodePlayback and resolveServerStream), off the main thread. The answer is
     * played as the server built it, with the server's PlaySessionId, so a channel change stops
     * exactly that encode. A failed or empty answer falls through to the hand-built stream, as
     * on the Apple TV. An answer for an attempt already replaced is dropped and its encode
     * stopped: the server opened it, and nothing else knows its id.
     */
    private fun handshake(mb: MediaBrowserServer, item: MediaItem, offsetSec: Long, q: StreamQuality, serverStreamOnly: Boolean) {
        val a = attempt
        val askedAt = System.currentTimeMillis()
        current = Current(item, offsetSec, Delivery.TRANSCODE, null, askedAt)
        // The old programme stops now, not when the answer comes (replaceCurrentItem(with: nil)).
        player.stop()
        val subtitleLanguage = subtitleLanguage
        val languages = audioLanguages
        handshakes.execute {
            val r = runCatching {
                PlaybackInfoHandshake.negotiate(
                    send = { body -> mediaBrowser.playbackInfo(mb, item.ratingKey, body) },
                    serverUrl = mb.url, apiKey = mb.token, itemId = item.ratingKey, mediaSourceId = item.partKey ?: item.ratingKey,
                    maxBitrateBps = q.maxBitrateKbps * 1000L, serverStreamOnly = serverStreamOnly,
                    subtitleLanguage = subtitleLanguage, audioLanguages = languages,
                    log = { Log.i(TAG, "PLAYBACK INFO ${describe(item)}: $it") },
                    probe = { url -> mediaBrowser.probe(url) },
                    stopRefused = { session -> mediaBrowser.stopEncoding(mb, session) },
                )
            }
            main.post {
                val ms = System.currentTimeMillis() - askedAt
                if (a != attempt) {
                    r.getOrNull()?.playSessionId?.let { mediaBrowser.stopEncoding(mb, it) }
                    Log.i(TAG, "PLAYBACK INFO answered after the tune moved on (${ms} ms); its session stopped")
                    return@post
                }
                val res = r.getOrNull()
                when {
                    r.isFailure -> Log.i(TAG, "PLAYBACK INFO failed in $ms ms (${r.exceptionOrNull()}); using the hand-built stream")
                    res == null -> Log.i(TAG, "PLAYBACK INFO offered nothing playable in $ms ms; using the hand-built stream")
                    else -> Log.i(TAG, "PLAYBACK INFO in $ms ms: ${if (res.isDirectPlay) "the stored file" else "server stream"}" +
                        "${if (serverStreamOnly) " (direct play off)" else ""}, session ${res.playSessionId}" +
                        "${Regex("[?&]SubtitleStreamIndex=(\\d+)").find(res.url)?.let { m -> ", burning subtitle ${m.groupValues[1]}" } ?: ""}" +
                        "${Regex("[?&]AudioStreamIndex=(\\d+)").find(res.url)?.let { m -> ", audio ${m.groupValues[1]}" } ?: ""}")
                }
                if (res == null) {
                    val exo = mediaBrowserItem(mb, item, offsetSec, Delivery.TRANSCODE, q, false)
                    return@post load(exo, item, offsetSec, Delivery.TRANSCODE, false)
                }
                val delivery = if (res.isDirectPlay) Delivery.DIRECT_PLAY else Delivery.TRANSCODE
                current = Current(item, offsetSec, delivery, res.playSessionId, askedAt)
                if (res.isDirectPlay) info = info?.copy(delivery = delivery)
                val exo = ExoItem.Builder().setUri(res.url).apply { if (!res.isDirectPlay) setMimeType(MimeTypes.APPLICATION_M3U8) }.build()
                load(exo, item, offsetSec, delivery, false)
            }
        }
    }

    // ── The ladder ──────────────────────────────────────────────────────────

    private fun watch(a: Int, c: Current) {
        val deadline = PlaybackWatchdog.deadlineSeconds(c.delivery == Delivery.DIRECT_PLAY, c.item.videoWidth, c.item.videoHeight)
        val window = PlaybackWatchdog.PROGRESS_WINDOW_SECONDS
        var sampleA = 0L
        main.postDelayed({ if (a == attempt) sampleA = player.currentPosition }, (deadline - window) * 1000L)
        main.postDelayed({ if (a == attempt) judgeStartup(c, deadline, (player.currentPosition - sampleA) / 1000.0) }, deadline * 1000L)
        val monitor = PlaybackStarvation(STALL_SECONDS)
        main.postDelayed(object : Runnable {
            override fun run() {
                if (a != attempt) return
                if (started && sample(c, monitor)) return
                main.postDelayed(this, 1000)
            }
        }, 1000)
    }

    /** PlaybackWatchdog at the deadline: a picture, or the next rung. */
    private fun judgeStartup(c: Current, deadline: Int, progressed: Double) {
        if (PlaybackWatchdog.hasPicture(started, progressed, firstFrame)) {
            listener.onPicture(c.item)
            return
        }
        val detail = "ready=$started, playhead moved ${"%.1f".format(progressed)}s, frame=$firstFrame, bytes=$loadedBytes"
        when {
            c.delivery == Delivery.DIRECT_PLAY -> {
                Log.i(TAG, "WATCHDOG ${deadline}s, direct play gave no picture ($detail)")
                fallBack(c, "no picture after ${deadline}s", PlaybackInfo.Reason.STARTUP_NO_PICTURE, atOffset = true)
            }
            !c.capped && !c.demo -> capped(c, c.offsetSec, "no picture after ${deadline}s ($detail)", PlaybackInfo.Reason.STARTUP_NO_PICTURE)
            else -> {
                val failure = PlaybackFailure.classify(serverName, evidence(null, c.item))
                Log.w(TAG, "WATCHDOG ${deadline}s, capped stream gave no picture ($detail); ${failure.headline}")
                fail(c, failure)
            }
        }
    }

    /** One starvation sample. True when the attempt was replaced or given up. */
    private fun sample(c: Current, monitor: PlaybackStarvation): Boolean {
        val durationMs = player.duration
        val remaining = if (durationMs == C.TIME_UNSET) null else (durationMs - player.currentPosition) / 1000.0
        val before = monitor.recentStalls
        val verdict = monitor.observe(player.currentPosition / 1000.0, SystemClock.elapsedRealtime() / 1000.0, !player.playWhenReady, remaining)
        if (monitor.recentStalls > before) Log.i(TAG, "STALL counted: ${monitor.recentStalls} in the last 2 min, longest ${"%.0f".format(monitor.longestStall)}s")
        verdict ?: return false
        val at = positionSec()
        val detail = "stalls=${verdict.stalls} longest=${"%.0f".format(verdict.longestStallSeconds)}s at ${at}s"
        when {
            c.delivery == Delivery.DIRECT_PLAY -> {
                Log.i(TAG, "STARVED on direct play ($detail)")
                fallBack(c, "starved", PlaybackInfo.Reason.STREAM_STALLED)
            }
            !c.capped && !c.demo -> capped(c, at, "starved ($detail)", PlaybackInfo.Reason.STREAM_STALLED)
            else -> {
                // The server answered and still couldn't be watched: a different sentence from "refused".
                Log.w(TAG, "STARVED at 1080p too ($detail); nothing smaller to ask for")
                fail(c, PlaybackFailure.classify(serverName, PlaybackFailure.Evidence(starvedAfterCappedRetry = true)))
            }
        }
        return true
    }

    /**
     * Jellyfin and Emby, as the web tuner's nostalgex-jellyfin-urls.js. Direct play is the file
     * as stored (`Static=true`), labelled `stream.mp4` for the MP4 family so the server sends
     * `video/mp4` rather than going by the file's name. A server stream is first asked of the
     * server ([handshake]); this hand-built HLS request is what plays when that fails or offers
     * nothing, and the capped retry, as on the Apple TV. MPEG-TS, H.264 and AAC, with its own PlaySessionId so a channel change stops
     * exactly this encode. It carries no start time: Jellyfin copies the query onto every
     * segment URL and refuses `StartTimeTicks` there with HTTP 400, so the player seeks
     * instead (JellyfinPlaybackResolver.offsetPlayback), which `setMediaItem` does. The capped
     * retry is JellyfinPlaybackResolver.cappedTranscodeURL's 1920 wide at 8 Mbps.
     */
    private fun mediaBrowserItem(mb: MediaBrowserServer, item: MediaItem, offsetSec: Long, delivery: Delivery, q: StreamQuality, capped: Boolean): ExoItem {
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
                current = Current(item, offsetSec, delivery, session, System.currentTimeMillis(), capped)
                val url = Uri.parse("${mb.url}/Videos/${item.ratingKey}/master.m3u8").buildUpon()
                    .appendQueryParameter("MediaSourceId", source)
                    .appendQueryParameter("api_key", mb.token)
                    .appendQueryParameter("ApiKey", mb.token)
                    .appendQueryParameter("VideoCodec", "h264")
                    .appendQueryParameter("AudioCodec", "aac")
                    .appendQueryParameter("MaxWidth", (if (capped) 1920 else q.width).toString())
                    .appendQueryParameter("VideoBitrate", (if (capped) CAPPED_MEDIA_BROWSER_BPS else q.maxBitrateKbps * 1000L).toString())
                    .appendQueryParameter("SegmentContainer", "ts")
                    .appendQueryParameter("DeviceId", mediaBrowser.deviceId)
                    .appendQueryParameter("PlaySessionId", session)
                    // The server would send the file's default track, often a dub: ask for the
                    // viewer's language (JellyfinPlaybackResolver.pinningAudioStream). Only when
                    // there is a choice, so a one-track file's request is unchanged.
                    .apply {
                        LanguageChoice.preferredAudioIndex(item.audioStreams, audioLanguages)?.let { index ->
                            appendQueryParameter("AudioStreamIndex", index.toString())
                            Log.i(TAG, "AUDIO TRACK $index (${item.audioStreams.firstOrNull { it.index == index }?.lang}) of ${item.audioStreams.size} for ${describe(item)}")
                        }
                    }
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
        endAttempt()
        stopSession()
        player.pause()
    }

    fun stop() {
        endAttempt()
        stopSession()
        current = null
        info = null
        player.stop()
    }

    fun release() {
        stop()
        handshakes.shutdown()
        player.release()
    }

    /** What the player saw, in PlaybackFailure's terms; with no error, what the loads saw. */
    private fun evidence(error: PlaybackException?, item: MediaItem): PlaybackFailure.Evidence {
        var status: Int? = null
        var cause: Throwable? = error
        while (cause != null && status == null) {
            if (cause is HttpDataSource.InvalidResponseCodeException) status = cause.responseCode
            cause = cause.cause
        }
        val code = error?.errorCode
        return PlaybackFailure.Evidence(
            httpStatuses = listOfNotNull(status ?: loadStatus ?: if (code == PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND) 404 else null),
            unreachable = code == PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED ||
                code == PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT || (error == null && loadUnreachable),
            decoderFailed = code != null && code in 4001..4005,
            everShowedPicture = started,
            decodedAFrame = firstFrame,
            sourceCodec = item.videoCodec,
            serverDeliveredBytes = loadedBytes,
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
        private const val MIB = 1024L * 1024

        /**
         * The starvation monitor's stall length: 2 s where the Apple TV uses 3. Measured on the
         * emulator through a throttling proxy (2026-11-02): direct play at 0.67x real time
         * stopped for 2.6 to 2.9 s every 8 to 9 s and carried on, so 3 s counted none of 20
         * freezes in 120 s; healthy rebuffers peaked at 0.5 s (31 in 200 s). AVPlayer froze for
         * good instead. `PlaybackRecoveryTest` holds both shapes at every sampling phase.
         */
        private const val STALL_SECONDS = 2.0

        /** JellyfinPlaybackResolver.cappedTranscodeURL's VideoBitrate. */
        private const val CAPPED_MEDIA_BROWSER_BPS = 8_000_000L

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
