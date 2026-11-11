package com.muellhaus.nostalgex.engine

/**
 * How long a plex.tv/link code is waited for (#284): as long as plex.tv keeps it, the PIN's
 * `expiresIn` (900 seconds when measured), where 150 polls gave up after 5 minutes. 300 when
 * plex.tv doesn't say, and never more than 1,800, as the Apple TV's plexPINLifetime and the
 * Roku's NxPlexPinWaitSeconds.
 */
object PlexPinWait {
    const val FALLBACK_SECONDS = 300L
    const val MAX_SECONDS = 1800L

    /** The poll interval, unchanged. */
    const val POLL_MS = 2000L

    fun seconds(expiresIn: Long?): Long = when {
        expiresIn == null || expiresIn <= 0 -> FALLBACK_SECONDS
        expiresIn > MAX_SECONDS -> MAX_SECONDS
        else -> expiresIn
    }
}
