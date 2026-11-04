package com.muellhaus.nostalgex.engine

/**
 * When a load that has not produced picture should be given up on (PlaybackWatchdog.swift).
 *
 * Judged by whether the playhead moved and a frame was decoded, not by the player's buffer
 * state: a playhead that advances with a frame on screen is the only thing that means the
 * viewer is watching something.
 */
object PlaybackWatchdog {
    /**
     * 15 s for a direct play. A transcode needs the server's encoder spun up and a first
     * segment, 20 s; a 4K source, 40 s (width as well as height: a 2.39:1 UHD frame is 3840
     * wide and only 1606 tall).
     */
    fun deadlineSeconds(isDirectPlay: Boolean, videoWidth: Int?, videoHeight: Int?): Int {
        if (isDirectPlay) return 15
        val uhd = (videoHeight ?: 0) >= 2000 || (videoWidth ?: 0) >= 3000
        return if (uhd) 40 else 20
    }

    /** Seconds between the two playhead samples taken just before the deadline. */
    const val PROGRESS_WINDOW_SECONDS = 2

    /** The playhead has to move this much across the window to count as alive. */
    const val MINIMUM_PROGRESS_SECONDS = 0.25

    fun shouldSkip(reachedReady: Boolean, progressedSeconds: Double): Boolean {
        if (!reachedReady) return true
        if (!progressedSeconds.isFinite()) return true
        return progressedSeconds < MINIMUM_PROGRESS_SECONDS
    }

    /** A moving playhead with no decoded frame is sound over a black picture: a failure, not a pass. */
    fun hasPicture(reachedReady: Boolean, progressedSeconds: Double, decodedFrame: Boolean): Boolean =
        !shouldSkip(reachedReady, progressedSeconds) && decodedFrame

    /**
     * A transcode the server started at `requested` seconds reports a clock that starts near
     * zero (the server rebased it) or near the offset (copyts kept source time). The first
     * needs the offset added to every position.
     */
    fun hlsBaseOffset(requested: Long, observedStart: Double): Double {
        if (requested <= 0 || !observedStart.isFinite()) return 0.0
        return if (observedStart < 2) requested.toDouble() else 0.0
    }
}

/**
 * Whether a stream that *was* playing is being starved by its source (PlaybackStarvation.swift).
 * Fed one sample a second. A playhead that stops moving while the player is not paused is a
 * stall, whatever the buffer state says. Three stalls inside two minutes, or one that never
 * ends, means the source can't keep up: the ladder asks for something smaller from where the
 * viewer is, rather than skipping.
 *
 * [stallSeconds] is the Apple TV's 3 s unless the caller says otherwise. The Apple TV's
 * AVPlayer froze for good on a starving source; ExoPlayer instead stops for a moment and
 * carries on, so the Android player passes its own threshold (see Playback.kt).
 */
class PlaybackStarvation(private val stallSeconds: Double = STALL_SECONDS) {
    data class Starving(val stalls: Int, val longestStallSeconds: Double)

    var armed = false
        private set
    var longestStall = 0.0
        private set
    private var firstPlayhead: Double? = null
    private var lastPlayhead: Double? = null
    private var stallStartedAt: Double? = null
    private val stallsEndedAt = ArrayList<Double>()

    /** Stalls counted inside the window so far, for the log. */
    val recentStalls: Int get() = stallsEndedAt.size

    /**
     * @param playhead player time in seconds (only deltas matter).
     * @param wall monotonic wall-clock seconds.
     * @param paused deliberately paused, not buffering. Paused samples are ignored.
     * @param remaining seconds to the end of the item, or null when unknown.
     */
    fun observe(playhead: Double, wall: Double, paused: Boolean, remaining: Double?): Starving? {
        if (!playhead.isFinite() || paused) return null
        // Inside the tail a stopped playhead is the end of the file, not starvation.
        if (remaining != null && remaining.isFinite() && remaining <= TAIL_SECONDS) return null

        if (firstPlayhead == null) firstPlayhead = playhead
        try {
            if (!armed) {
                if (playhead - firstPlayhead!! >= ARM_AFTER_PROGRESS_SECONDS) armed = true
                return null
            }
            val last = lastPlayhead ?: return null

            if (playhead - last >= MINIMUM_PROGRESS_SECONDS) {
                stallStartedAt?.let { start ->
                    if (wall - start >= stallSeconds) {
                        stallsEndedAt += wall
                        longestStall = maxOf(longestStall, wall - start)
                    }
                }
                stallStartedAt = null
            } else {
                if (stallStartedAt == null) stallStartedAt = wall
                val length = wall - stallStartedAt!!
                longestStall = maxOf(longestStall, length)
                if (length >= HARD_STALL_SECONDS) return Starving(stallsEndedAt.size + 1, longestStall)
            }

            stallsEndedAt.removeAll { wall - it > WINDOW_SECONDS }
            if (stallsEndedAt.size >= STALLS_TO_STARVE) return Starving(stallsEndedAt.size, longestStall)
            return null
        } finally {
            lastPlayhead = playhead
        }
    }

    companion object {
        /** Seconds the playhead must sit still to count as a stall, on the Apple TV. */
        const val STALL_SECONDS = 3.0
        /** A single stall this long is a frozen picture, whatever came before it. */
        const val HARD_STALL_SECONDS = 20.0
        const val STALLS_TO_STARVE = 3
        const val WINDOW_SECONDS = 120.0
        /** Arms only once playback has genuinely run; startup is the watchdog's job. */
        const val ARM_AFTER_PROGRESS_SECONDS = 1.0
        const val MINIMUM_PROGRESS_SECONDS = 0.25
        const val TAIL_SECONDS = 5.0
    }
}
