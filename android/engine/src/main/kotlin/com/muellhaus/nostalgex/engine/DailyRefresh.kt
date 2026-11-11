package com.muellhaus.nostalgex.engine

/**
 * A TV left on keeps a current library (#195), as the Apple TV's startDailyRefresh and
 * refreshLibraryIfChanged (AppState+Schedule.swift, AppState+Library.swift) and the Roku's
 * DailyRefresh.brs: every 15 minutes, once the library last loaded 6 hours ago or more and the
 * last check was as long ago, the library is read again behind the guide. On Plex one small
 * request per server comes first, and a library whose signature hasn't moved is not scanned
 * again until its scan is a day old. Jellyfin and Emby have no signature and are always scanned.
 */
object DailyRefresh {
    /** How often the timer looks (startDailyRefresh's 900 s sleep). */
    const val CHECK_SECONDS = 900L

    /** A library this old is checked (LibrarySnapshotStore.refreshAfterSeconds). */
    const val AFTER_SECONDS = 6 * 3600L

    /** Past this an unchanged signature no longer stands in for a scan (forceRefreshAfterSeconds). */
    const val FORCE_AFTER_SECONDS = 24 * 3600L

    /** Whether the 15-minute check reads the library again now (NxDailyRefreshDue). */
    fun due(nowSec: Long, lastLoadSec: Long, lastCheckSec: Long): Boolean =
        nowSec - lastLoadSec >= AFTER_SECONDS && nowSec - lastCheckSec >= AFTER_SECONDS

    /** A Plex section's change stamps, as /library/sections lists them. `scannedAt` is left out on purpose. */
    data class SectionStamp(val key: String, val updatedAt: Long?, val contentChangedAt: Long?)

    /**
     * One server's fingerprint (LibraryChangeSignature.signature), from each section's
     * `updatedAt` and `contentChangedAt`, which move only when something changed. `scannedAt`
     * is not in it: Plex's scheduled scans bump it every run. Null when a section carries
     * neither stamp, or there are none, so nothing is ever claimed unchanged that can't be seen.
     */
    fun signature(serverId: String, sections: List<SectionStamp>): String? {
        if (sections.isEmpty()) return null
        val parts = sections.map { s ->
            if (s.updatedAt == null && s.contentChangedAt == null) return null
            "${s.key}=u${s.updatedAt ?: 0}/c${s.contentChangedAt ?: 0}"
        }
        return "$serverId:" + parts.sorted().joinToString(",")
    }

    /** Every server's signature as one (LibraryChangeSignature.combine). */
    fun combine(perServer: List<String>): String = perServer.sorted().joinToString(";")

    /**
     * Skip the scan only when the library is provably unchanged and the day's cap hasn't passed
     * (shouldSkipRefresh). The cap is there because the stamps don't move for everything the
     * guide reads (watch counts, for one).
     */
    fun shouldSkip(ageSec: Long, stored: String?, current: String?, hardCapSec: Long = FORCE_AFTER_SECONDS): Boolean =
        ageSec < hardCapSec && stored != null && current != null && stored == current
}
