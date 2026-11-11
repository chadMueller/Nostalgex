package com.muellhaus.nostalgex.engine

import kotlinx.serialization.Serializable

/**
 * A first setup killed part way resumes where it stopped (#288, the Apple TV 1.0.32's
 * LibraryScanProgressStore, I-076): each library section is kept on its own as soon as it has
 * been read in full, and the next scan reuses a kept section instead of reading it again, when
 * it may.
 */
object ScanResume {
    /** A kept section is used for this long: the Apple TV's snapshot age (refreshAfterSeconds). */
    const val MAX_AGE_SECONDS = 6 * 3600L

    /** One library section as read in full. Never the library snapshot. */
    @Serializable
    data class Kept(
        val serverId: String,
        val key: String,
        val savedAtSec: Long,
        /** The app's versionCode that read it: a kept section from another build is read again. */
        val build: Int,
        /** Plex's change stamp for the section when it was read; null on Jellyfin and Emby. */
        val stamp: String? = null,
        val items: List<MediaItem>,
    )

    /** A Plex section's change stamp (`updatedAt`, `contentChangedAt`), as DailyRefresh reads it; null with neither. */
    fun plexStamp(updatedAt: Long?, contentChangedAt: Long?): String? =
        if (updatedAt == null && contentChangedAt == null) null else "u${updatedAt ?: 0}/c${contentChangedAt ?: 0}"

    /**
     * Whether a kept section may stand in for reading it: young, from this build, and on Plex
     * (`stampRequired`) unchanged on the server. A section with no stamp on Plex is read again,
     * so nothing is claimed unchanged that can't be seen.
     */
    fun reusable(kept: Kept, nowSec: Long, build: Int, currentStamp: String?, stampRequired: Boolean): Boolean {
        val age = nowSec - kept.savedAtSec
        if (age < 0 || age >= MAX_AGE_SECONDS) return false
        if (kept.build != build) return false
        if (stampRequired && (kept.stamp == null || kept.stamp != currentStamp)) return false
        return true
    }
}

/**
 * What a scan asks about each section (#288): `kept` gives the items to use instead of reading
 * it (or null to read it), and `done` hands over a section read in full, to keep.
 */
interface SectionKeep {
    fun kept(key: String, stamp: String?): List<MediaItem>?
    fun done(key: String, stamp: String?, items: List<MediaItem>)

    companion object {
        val NONE = object : SectionKeep {
            override fun kept(key: String, stamp: String?): List<MediaItem>? = null
            override fun done(key: String, stamp: String?, items: List<MediaItem>) {}
        }
    }
}
