package com.muellhaus.nostalgex.playback

import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.muellhaus.nostalgex.engine.MediaItem
import com.muellhaus.nostalgex.engine.WatchState
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * SHOW NOW PLAYING and MARK WATCHED (PlaybackTracker.swift, plex-tuner.html makePlaybackTracker):
 * what the viewer's server is told about what plays, off unless switched on.
 *
 * - Now Playing: Plex gets a position-free `/:/timeline` every 10 s, so it lists the title and
 *   stores nothing; Jellyfin and Emby get `/Sessions/Playing`, `Progress` and `Stopped`, which
 *   carry the position, so the item's UserData is read first and put back when the session ends.
 * - Mark Watched: tuned in during the first 15% and 75% of the runtime watched (WatchState's
 *   gates) counts once: Plex `/:/scrobble`, Jellyfin and Emby `PlayedItems`.
 * Nothing is left in Continue Watching, Resume or On Deck (WatchState's plans). Every request
 * goes through one queue in order, so a restore always lands after the last report; a server
 * that stops answering gets fewer pulses, and nothing here ever changes the viewer's choice.
 */
class WatchReporter(private val plexHeaders: Map<String, String>, private val mediaBrowserAuth: (token: String) -> String) {
    /** Where an item's reports go: the server it came from. */
    sealed class Server {
        data class Plex(val url: String, val token: String) : Server()
        data class MediaBrowser(val url: String, val userId: String, val token: String) : Server()
    }

    /** The viewer's choices, shared by every tracker so turning one off revokes queued work too. */
    val scope = WatchState.ReportingScope(nowPlaying = false, markWatched = false)
    private var nowPlaying = false
    private var markWatched = false

    private val queue = Executors.newSingleThreadExecutor()
    private val http = OkHttpClient.Builder().connectTimeout(10, TimeUnit.SECONDS).readTimeout(15, TimeUnit.SECONDS).build()
    private val json = Json { ignoreUnknownKeys = true }
    private val main = Handler(Looper.getMainLooper())

    private var current: Tracker? = null

    /** The two switches, applied to the programme playing as well as the next (updateReporting). */
    fun setChoices(nowPlaying: Boolean, markWatched: Boolean) {
        this.nowPlaying = nowPlaying
        this.markWatched = markWatched
        scope.update(nowPlaying, markWatched)
        current?.updateReporting(nowPlaying, markWatched)
    }

    /** A new programme: the last one's tracker stops and this one's starts (on ready). */
    fun begin(item: MediaItem, seekOffsetSec: Long, server: Server?) {
        current?.stop()
        current = server?.let { Tracker(item, seekOffsetSec, it) }
    }

    /** The player reached ready for the programme on: start the clock and the reports. */
    fun onReady() = current?.onReady()
    fun onPause() = current?.onPause()
    fun onResume() = current?.onResume()

    /** Playback stopped (the app left, or nothing plays now): end the session and clean up. */
    fun stop() {
        current?.stop()
        current = null
    }

    private class Response(val status: Int, val body: String?) {
        val ok get() = status in 200..299
    }

    /** One request, blocking, on the queue's thread. A network error is null. */
    private fun send(method: String, url: String, headers: Map<String, String> = emptyMap(), body: String? = null): Response? = try {
        val b = Request.Builder().url(url).header("Accept", "application/json")
        headers.forEach { (k, v) -> b.header(k, v) }
        when {
            body != null -> b.method(method, body.toRequestBody("application/json".toMediaType()))
            method == "PUT" || method == "POST" -> b.method(method, ByteArray(0).toRequestBody(null))
            else -> b.method(method, null)
        }
        http.newCall(b.build()).execute().use { Response(it.code, it.body.string()) }
    } catch (e: Exception) {
        null
    }

    private fun enqueue(op: () -> Unit) {
        queue.execute { runCatching(op).onFailure { Log.w(TAG, "WATCH report failed", it) } }
    }

    // ── The guards (nostalgex-watch-state.js plexGuard, mediaServerGuard) ─────────

    private fun plexUrl(s: Server.Plex, path: String, params: Map<String, String> = emptyMap()): String {
        val b = Uri.parse(s.url + path).buildUpon()
        params.forEach { (k, v) -> b.appendQueryParameter(k, v) }
        b.appendQueryParameter("X-Plex-Token", s.token)
        b.appendQueryParameter("X-Plex-Client-Identifier", plexHeaders["X-Plex-Client-Identifier"] ?: "")
        b.appendQueryParameter("X-Plex-Product", "Nostalgex")
        b.appendQueryParameter("X-Plex-Platform", "Android")
        return b.build().toString()
    }

    private fun obj(body: String?) = body?.let { runCatching { json.parseToJsonElement(it) as? JsonObject }.getOrNull() }
    private fun JsonObject.str(k: String) = (this[k] as? JsonPrimitive)?.content

    private fun plexContinueWatching(s: Server.Plex): List<JsonObject>? {
        val r = send("GET", plexUrl(s, "/hubs/continueWatching/items", mapOf("count" to "200"))) ?: return null
        if (!r.ok) return null
        val mc = obj(r.body)?.get("MediaContainer") as? JsonObject ?: return null
        return (mc["Metadata"] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()
    }

    /** Episodes only: is the show already in Continue Watching? Films cost no request. */
    private fun capture(item: MediaItem, s: Server): WatchState.Prior? = when (s) {
        is Server.Plex -> {
            if (item.type != "episode") null
            else {
                val r = send("GET", plexUrl(s, "/library/metadata/${Uri.encode(item.ratingKey)}"))
                val meta = r?.takeIf { it.ok }?.let { obj(it.body)?.get("MediaContainer") as? JsonObject }
                    ?.let { (it["Metadata"] as? JsonArray)?.firstOrNull() as? JsonObject }
                val show = meta?.takeIf { it.str("type") == "episode" }?.str("grandparentRatingKey")
                if (show == null) null else {
                    val row = plexContinueWatching(s)
                    // Unreadable row: assume the show was there, so a real entry is never removed.
                    WatchState.Prior(showKey = show, showInContinueWatching = row?.any { it.str("grandparentRatingKey") == show || it.str("ratingKey") == show } ?: true)
                }
            }
        }
        is Server.MediaBrowser -> {
            val r = send("GET", "${s.url}/Users/${Uri.encode(s.userId)}/Items/${Uri.encode(item.ratingKey)}", mapOf("Authorization" to mediaBrowserAuth(s.token)))
            val data = r?.takeIf { it.ok }?.let { obj(it.body)?.get("UserData") as? JsonObject }
            data?.let {
                WatchState.Prior(
                    resumePosition = (it["PlaybackPositionTicks"] as? JsonPrimitive)?.longOrNull ?: 0,
                    playCount = ((it["PlayCount"] as? JsonPrimitive)?.longOrNull ?: 0).toInt(),
                    played = (it["Played"] as? JsonPrimitive)?.booleanOrNull == true,
                    lastPlayedDate = (it["LastPlayedDate"] as? JsonPrimitive)?.content,
                )
            }
        }
    }

    private fun restore(item: MediaItem, s: Server, prior: WatchState.Prior?, counted: Boolean) {
        when (s) {
            is Server.Plex -> for (step in WatchState.plexPlan(prior, counted)) {
                if (step !is WatchState.Step.RemoveShowFromContinueWatching) continue
                // Plex adds the next episode about a second after the scrobble: look up to three times.
                for (attempt in 0 until 3) {
                    val added = (plexContinueWatching(s) ?: emptyList()).filter { it.str("grandparentRatingKey") == step.show }
                    for (e in added) {
                        val r = send("PUT", plexUrl(s, "/actions/removeFromContinueWatching", mapOf("ratingKey" to (e.str("ratingKey") ?: ""))))
                        Log.i(TAG, "WATCH cleanup ${item.ratingKey}: removeFromContinueWatching next-up ${e.str("ratingKey")} ${r?.status ?: "failed"}")
                    }
                    if (added.isNotEmpty() || attempt == 2) break
                    Thread.sleep(1000)
                }
            }
            is Server.MediaBrowser -> for (step in WatchState.mediaServerPlan(prior, counted)) {
                val base = "${s.url}/Users/${Uri.encode(s.userId)}"
                val auth = mapOf("Authorization" to mediaBrowserAuth(s.token))
                val r = when (step) {
                    WatchState.Step.MarkUnplayed -> send("DELETE", "$base/PlayedItems/${Uri.encode(item.ratingKey)}", auth)
                    is WatchState.Step.UserData -> send("POST", "$base/Items/${Uri.encode(item.ratingKey)}/UserData", auth, buildJsonObject {
                        put("PlaybackPositionTicks", step.position)
                        step.playCount?.let { put("PlayCount", it) }
                        step.played?.let { put("Played", it) }
                        step.lastPlayedDate?.takeIf { it.isNotEmpty() }?.let { put("LastPlayedDate", it) }
                    }.toString())
                    else -> null
                }
                Log.i(TAG, "WATCH cleanup ${item.ratingKey}: ${WatchState.describe(step)} ${r?.status ?: "failed"}")
            }
        }
    }

    // ── One programme (makePlaybackTracker) ────────────────────────────────────

    private inner class Tracker(val item: MediaItem, val seekOffset: Long, val server: Server) {
        private val totalSec = item.duration.toLong() * 60
        private val isPlex = server is Server.Plex
        private val eligibleEntry = WatchState.eligibleEntry(seekOffset, totalSec)
        private val backoff = WatchState.PulseBackoff()
        // Changed on the main thread, read again by queued work before it sends.
        @Volatile private var options = nowPlaying to markWatched
        @Volatile private var activityEpoch = 0
        @Volatile private var watchedEpoch = 0
        private var leg: Leg? = null
        private var activeWatchSeconds = 0.0
        private var watchStart: Double? = null
        private var stopped = false
        private var ready = false
        private var paused = false
        // Read and written on the queue's thread only.
        @Volatile private var prior: WatchState.Prior? = null
        @Volatile private var captured = false
        @Volatile private var dirty = false
        @Volatile private var counted = false
        private var captureQueued = false
        private var pendingMarkEpoch: Int? = null

        private inner class Leg(val id: String = UUID.randomUUID().toString()) {
            @Volatile var started = false
        }

        private fun now() = SystemClock.elapsedRealtime() / 1000.0

        private val tick = object : Runnable {
            override fun run() {
                if (stopped) return
                accumulate()
                if (!paused) watchStart = now()
                activity("playing", pulse = true)
                evaluateAndScrobble()
                main.postDelayed(this, 10_000)
            }
        }

        private fun accumulate() {
            val start = watchStart ?: return
            activeWatchSeconds += maxOf(0.0, now() - start)
            watchStart = null
        }

        private fun positionTicks() = (seekOffset * 1000 + Math.round(activeWatchSeconds * 1000)) * 10_000

        private fun captureOnce() {
            if (captureQueued) return
            captureQueued = true
            enqueue {
                prior = capture(item, server)
                captured = true
            }
        }

        private fun cleanup() = enqueue {
            if (dirty) restore(item, server, if (captured) prior else null, counted)
        }

        private fun activity(state: String, pulse: Boolean = false) {
            val stopping = state == "stopped"
            val l = leg ?: return
            if (!stopping && !options.first) return
            if (pulse && !backoff.allowPulse()) return
            // A Jellyfin or Emby start needs the baseline first, and so may a Plex episode scrobble.
            if (!isPlex || options.second) captureOnce()
            val epoch = activityEpoch
            val scopeEpoch = scope.activityEpoch
            val reported = if (state == "playing" && paused) "paused" else state
            val position = positionTicks()
            val pausedNow = paused
            enqueue {
                if (!stopping && (epoch != activityEpoch || !options.first || !scope.allowsActivity(scopeEpoch))) return@enqueue
                if (stopping && !l.started) return@enqueue
                if (!isPlex && prior == null) return@enqueue // No safe restoration baseline: no session.
                val r = when (server) {
                    is Server.Plex -> send("PUT", plexUrl(server, "/:/timeline", mapOf(
                        "ratingKey" to item.ratingKey, "key" to "/library/metadata/${item.ratingKey}", "state" to reported,
                        "X-Plex-Session-Identifier" to l.id,
                    )))
                    is Server.MediaBrowser -> {
                        dirty = true
                        val path = if (stopping) "/Sessions/Playing/Stopped" else if (l.started) "/Sessions/Playing/Progress" else "/Sessions/Playing"
                        // A Now Playing stop never claims a completed watch.
                        val ticks = if (stopping) WatchState.stopTicks(position, totalSec) else position
                        send("POST", server.url + path, mapOf("Authorization" to mediaBrowserAuth(server.token)), buildJsonObject {
                            put("ItemId", item.ratingKey)
                            put("PlaySessionId", l.id)
                            put("MediaSourceId", item.partKey ?: item.ratingKey)
                            put("PositionTicks", ticks)
                            put("IsPaused", pausedNow)
                        }.toString())
                    }
                }
                l.started = !stopping
                backoff.record(r?.ok == true)
                if (!pulse) Log.i(TAG, "WATCH ${if (isPlex) "timeline" else "session"} $reported \"${item.title}\" ${r?.status ?: "failed"}")
            }
        }

        private fun beginActivity() {
            if (!options.first || !ready || leg != null) return
            leg = Leg()
            activity("playing")
        }

        private fun endActivity() {
            if (leg == null) return
            activity("stopped")
            leg = null
        }

        private fun evaluateAndScrobble() {
            if (!options.second || counted || pendingMarkEpoch == watchedEpoch) return
            if (!eligibleEntry || !WatchState.watchedEnough(activeWatchSeconds, totalSec)) return
            captureOnce()
            val epoch = watchedEpoch
            val scopeEpoch = scope.markEpoch
            pendingMarkEpoch = epoch
            enqueue {
                if (!options.second || epoch != watchedEpoch || !scope.allowsMark(scopeEpoch)) return@enqueue
                if (!isPlex && prior == null) return@enqueue // A failed baseline read skips Mark Watched too.
                counted = true
                dirty = true
                val r = when (server) {
                    is Server.Plex -> send("GET", plexUrl(server, "/:/scrobble", mapOf("key" to item.ratingKey, "identifier" to "com.plexapp.plugins.library")))
                    is Server.MediaBrowser -> send("POST", "${server.url}/Users/${Uri.encode(server.userId)}/PlayedItems/${Uri.encode(item.ratingKey)}",
                        mapOf("Authorization" to mediaBrowserAuth(server.token)))
                }
                Log.i(TAG, "WATCH marked watched \"${item.title}\" after ${activeWatchSeconds.toInt()} s of ${totalSec} s: ${r?.status ?: "failed"}")
            }
        }

        fun onReady() {
            if (stopped || ready) return
            ready = true
            watchStart = now()
            if (options.second) captureOnce()
            beginActivity()
            main.postDelayed(tick, 10_000)
        }

        fun onPause() {
            if (stopped || paused) return
            accumulate()
            paused = true
            activity("paused")
        }

        fun onResume() {
            if (stopped || !ready || !paused) return
            watchStart = now()
            paused = false
            activity("playing")
        }

        fun updateReporting(nowOn: Boolean, markOn: Boolean) {
            if (stopped) return
            val nowChanged = options.first != nowOn
            val markChanged = options.second != markOn
            if (!nowChanged && !markChanged) return
            if (nowChanged) activityEpoch++
            if (markChanged) {
                watchedEpoch++
                pendingMarkEpoch = null
            }
            if (nowChanged && options.first) endActivity()
            options = nowOn to markOn
            if (nowChanged && !options.first) cleanup()
            if (options.second && ready) captureOnce()
            if (nowChanged && options.first) beginActivity()
        }

        fun stop() {
            if (stopped) return
            stopped = true
            main.removeCallbacks(tick)
            accumulate()
            endActivity()
            evaluateAndScrobble()
            cleanup()
        }
    }

    companion object {
        private const val TAG = "Nostalgex"
    }
}
