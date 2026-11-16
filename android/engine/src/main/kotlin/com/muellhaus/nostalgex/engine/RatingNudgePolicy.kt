package com.muellhaus.nostalgex.engine

/**
 * Decides whether the "Enjoying Nostalgex?" banner may appear: the Apple TV's `RatingNudgePolicy.swift`. Holds every
 * rule and no side effects, so the rules are tested directly. The banner is only ever considered at one moment: when
 * the viewer leaves full screen and lands back on the guide. Everything else here is a gate on that moment.
 */
object RatingNudgePolicy {
    /** One continuous watch of a programme has to reach this to count as a viewing session. */
    const val MINIMUM_SESSION_SECONDS = 10 * 60.0

    /** Qualifying sessions needed, cumulative across launches. */
    const val REQUIRED_SESSIONS = 3

    /** Untouched, the banner leaves on its own after this long. */
    const val AUTO_DISMISS_SECONDS = 8.0

    /** What survives between launches. */
    data class Persisted(
        val qualifyingSessions: Int = 0,
        /** The version name the banner was last shown on, whatever the viewer chose. */
        val lastShownVersion: String? = null,
        /** The viewer pressed RATE (banner or Settings): never ask again. */
        val rated: Boolean = false,
    )

    /** Facts about the current app launch only. */
    data class Launch(
        val appVersion: String,
        val isFirstLaunch: Boolean = false,
        val hadPlaybackFailure: Boolean = false,
        val hadConnectError: Boolean = false,
        /** Already appeared during this launch. */
        val shownThisLaunch: Boolean = false,
        val forced: Boolean = false,
    )

    fun countsAsViewingSession(watchedSeconds: Double) = watchedSeconds >= MINIMUM_SESSION_SECONDS

    fun shouldShow(persisted: Persisted, launch: Launch): Boolean {
        if (launch.shownThisLaunch) return false
        if (launch.forced) return true
        if (persisted.rated) return false
        if (launch.isFirstLaunch) return false
        if (launch.hadPlaybackFailure || launch.hadConnectError) return false
        if (persisted.lastShownVersion == launch.appVersion) return false
        return persisted.qualifyingSessions >= REQUIRED_SESSIONS
    }
}
