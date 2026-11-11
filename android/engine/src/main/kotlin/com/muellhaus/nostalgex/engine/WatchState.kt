package com.muellhaus.nostalgex.engine

/**
 * SHOW NOW PLAYING and MARK WATCHED without filling Continue Watching: the pure half of
 * scripts/nostalgex-watch-state.js, the web port of the Apple TV's WatchStateGuard.swift
 * (WatchCleanupPlan) and PulseBackoff. scripts/watch-cleanup-golden.json, which the Apple TV's
 * WatchStateGuardTests read too, holds the plans to the same answers (WatchStateTest).
 *
 * The rule: reporting keeps Now Playing and real watches flowing to the viewer's server, but a
 * programme the guide played must never be left in Continue Watching (Plex), Resume (Jellyfin,
 * Emby) or On Deck. Plex reports carry no position, so a surf needs no cleanup; a counted
 * episode's next-up entry is removed unless its show was already in Continue Watching.
 * Jellyfin and Emby reports keep the position (a stop without one marks the item played), so
 * the item's UserData is read before the first report and put back when the session ends.
 */
object WatchState {
    /**
     * What the server held before tune-in. `resumePosition` is Plex ms or Jellyfin/Emby 100 ns
     * ticks. Null where the read failed: then nothing is undone, rather than erase real progress.
     */
    data class Prior(
        val resumePosition: Long = 0,
        val playCount: Int = 0,
        val played: Boolean = false,
        val lastPlayedDate: String? = null,
        val showKey: String? = null,
        val showInContinueWatching: Boolean = false,
    )

    sealed class Step {
        data class RemoveShowFromContinueWatching(val show: String) : Step()
        object MarkUnplayed : Step() {
            override fun toString() = "MarkUnplayed"
        }
        data class UserData(val position: Long, val playCount: Int?, val played: Boolean?, val lastPlayedDate: String? = null) : Step()
    }

    /** plexPlan: only a counted episode, whose show wasn't already in Continue Watching, leaves something to undo. */
    fun plexPlan(prior: Prior?, counted: Boolean): List<Step> {
        if (!counted || prior == null || prior.showKey == null || prior.showInContinueWatching) return emptyList()
        return listOf(Step.RemoveShowFromContinueWatching(prior.showKey))
    }

    /** mediaServerPlan: put back what the server held, or count the watch with no resume point. */
    fun mediaServerPlan(prior: Prior?, counted: Boolean): List<Step> {
        if (prior == null) return emptyList()
        if (counted) return listOf(Step.UserData(0, prior.playCount + 1, true))
        if (prior.resumePosition == 0L && prior.playCount == 0 && !prior.played) return listOf(Step.MarkUnplayed)
        return listOf(Step.UserData(prior.resumePosition, prior.playCount, prior.played, prior.lastPlayedDate))
    }

    /** The golden file's compact form (describe). */
    fun describe(step: Step): String = when (step) {
        is Step.RemoveShowFromContinueWatching -> "removeShowFromContinueWatching ${step.show}"
        Step.MarkUnplayed -> "markUnplayed"
        is Step.UserData -> buildList {
            add("userData position=${step.position}")
            step.playCount?.let { add("playCount=$it") }
            step.played?.let { add("played=$it") }
            step.lastPlayedDate?.takeIf { it.isNotEmpty() }?.let { add("lastPlayedDate=$it") }
        }.joinToString(" ")
    }

    /**
     * PulseBackoff: a server that stops answering gets fewer 10 s pulses, never a changed
     * setting. Each failure skips 1, 2, 4 ... up to 30 pulses; any answered report resets it.
     * Starts, stops, scrobbles and cleanup always go out.
     */
    class PulseBackoff {
        private var failures = 0
        private var skip = 0

        @Synchronized
        fun allowPulse(): Boolean {
            if (skip > 0) {
                skip--
                return false
            }
            return true
        }

        @Synchronized
        fun record(success: Boolean) {
            if (success) {
                failures = 0
                skip = 0
                return
            }
            failures++
            skip = minOf(30, 1 shl minOf(failures - 1, 5))
        }
    }

    /**
     * The viewer's two choices, shared by every tracker (PlaybackReportingControlScope). Turning
     * one off bumps its epoch, which revokes work already queued by an earlier channel's tracker.
     */
    class ReportingScope(nowPlaying: Boolean, markWatched: Boolean) {
        private var nowPlaying = nowPlaying
        private var markWatched = markWatched
        @Volatile var activityEpoch = 0
            private set
        @Volatile var markEpoch = 0
            private set

        @Synchronized
        fun update(nowPlaying: Boolean, markWatched: Boolean) {
            if (this.nowPlaying != nowPlaying) { this.nowPlaying = nowPlaying; activityEpoch++ }
            if (this.markWatched != markWatched) { this.markWatched = markWatched; markEpoch++ }
        }

        @Synchronized fun allowsActivity(epoch: Int) = nowPlaying && epoch == activityEpoch
        @Synchronized fun allowsMark(epoch: Int) = markWatched && epoch == markEpoch
    }

    /** The scrobble's entry gate: tuned in during the first 15% of the programme. */
    fun eligibleEntry(seekOffsetSec: Long, totalSec: Long) = totalSec > 0 && seekOffsetSec.toDouble() / totalSec <= 0.15

    /** The scrobble's watch gate: 75% of the runtime actually watched while tuned in. */
    fun watchedEnough(activeWatchSeconds: Double, totalSec: Long) = totalSec > 0 && activeWatchSeconds / totalSec >= 0.75

    /**
     * A Jellyfin or Emby stop never claims more than 89% of the runtime, so a Now Playing
     * report alone never counts as a completed watch. In ticks.
     */
    fun stopTicks(positionTicks: Long, totalSec: Long): Long = minOf(positionTicks, Math.floor(totalSec * 0.89 * 10_000_000).toLong())
}
