package com.muellhaus.nostalgex.engine

import java.text.NumberFormat
import java.util.IdentityHashMap

/**
 * The coverage line under RESCAN LIBRARY (LibraryDiagnostics.coverageLine): how many of the
 * loaded titles sit on a channel with every package on, how many on none, and how many the
 * scan dropped for having no runtime. "1,788 OF 1,792 ON CHANNELS · 4 ON NO CHANNEL · 12 SKIPPED
 * (NO RUNTIME)". A title on no channel is one nothing in channels.json takes, so switching
 * packages on would not bring it back.
 */
object LibraryDiagnostics {
    enum class Kind(val label: String) { MOVIE("MOVIES"), EPISODE("EPISODES"), MUSIC_VIDEO("MUSIC VIDEOS") }

    fun kind(item: MediaItem): Kind = when {
        item.type == "episode" -> Kind.EPISODE
        item.librarySource == "musicVideo" -> Kind.MUSIC_VIDEO
        else -> Kind.MOVIE
    }

    data class Coverage(val loaded: Map<Kind, Int>, val onChannels: Map<Kind, Int>) {
        val totalLoaded get() = loaded.values.sum()
        val totalOnChannels get() = onChannels.values.sum()
        val totalOnNoChannel get() = totalLoaded - totalOnChannels
        fun orphans(kind: Kind) = (loaded[kind] ?: 0) - (onChannels[kind] ?: 0)
    }

    /** Where `items` land, given the pools of every channel that would show with its package on. Titles are told apart by identity. */
    fun coverage(items: List<MediaItem>, pools: List<List<MediaItem>>): Coverage {
        val covered = java.util.Collections.newSetFromMap(IdentityHashMap<MediaItem, Boolean>())
        for (pool in pools) covered.addAll(pool)
        val loaded = HashMap<Kind, Int>()
        val on = HashMap<Kind, Int>()
        for (item in items) {
            val k = kind(item)
            loaded[k] = (loaded[k] ?: 0) + 1
            if (item in covered) on[k] = (on[k] ?: 0) + 1
        }
        return Coverage(loaded, on)
    }

    /**
     * The line itself: "ON NO CHANNEL" split by kind when more than one kind has some and left
     * out at zero; "SKIPPED (NO RUNTIME)" left out at zero. Null when there is nothing to say.
     */
    fun coverageLine(coverage: Coverage?, skippedNoRuntime: Int): String? {
        val fmt = NumberFormat.getIntegerInstance(java.util.Locale.US)
        val parts = ArrayList<String>()
        if (coverage != null && coverage.totalLoaded > 0) {
            parts += "${fmt.format(coverage.totalOnChannels)} OF ${fmt.format(coverage.totalLoaded)} ON CHANNELS"
            if (coverage.totalOnNoChannel > 0) {
                var orphans = "${fmt.format(coverage.totalOnNoChannel)} ON NO CHANNEL"
                val byKind = Kind.values().mapNotNull { k -> coverage.orphans(k).takeIf { it > 0 }?.let { "${fmt.format(it)} ${k.label}" } }
                if (byKind.size > 1) orphans += " (${byKind.joinToString(", ")})"
                parts += orphans
            }
        }
        if (skippedNoRuntime > 0) parts += "${fmt.format(skippedNoRuntime)} SKIPPED (NO RUNTIME)"
        return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
    }
}
