package com.muellhaus.nostalgex.engine

/** What a library load does once it has read, one effect at a time, so the order and the guards are testable without a device. */
interface LoadCommitEffects<L> {
    /** Holds the read and writes it: the library store, the kept sections, the load clock. Only ever for the library in use. */
    suspend fun save(items: List<MediaItem>, collections: List<ServerCollection>)

    /** The items with their enrichment attached (`remote` false: the local cache only). */
    suspend fun enrich(items: List<MediaItem>, remote: Boolean): List<MediaItem>

    suspend fun build(items: List<MediaItem>): L

    /** Brings the guide up from [built]; false when it has no channels (NO CHANNELS FOUND). */
    suspend fun show(built: L): Boolean
}

enum class LoadResult {
    /** The library changed (signed out, another server or backend, a new load) while the load ran: nothing it read was kept or shown. */
    STALE,
    SHOWN,
    NO_CHANNELS,
}

/**
 * The end of a library load. A load takes minutes on a big library, and with the guide kept up behind it the viewer can reach Settings
 * and DISCONNECT in that time. [current] says whether the library the load began on is still the one in use; it is asked before the
 * library store is written and before the guide is shown, so a load that outlived its library saves nothing of it and puts the viewer
 * back into nothing (release 9 review: the load saved the old servers, showed, and returned the viewer to the server just left).
 */
class LibraryLoadCommit<L>(private val current: () -> Boolean, private val fx: LoadCommitEffects<L>) {
    /** A full load's read, to the guide: save, enrich over the network, build, show. */
    suspend fun run(items: List<MediaItem>, collections: List<ServerCollection>): LoadResult {
        if (!current()) return LoadResult.STALE
        fx.save(items, collections)
        return buildAndShow(items, remote = true)
    }

    /** The saved library, to the guide at once: the local enrichment cache only. */
    suspend fun runSaved(items: List<MediaItem>): LoadResult {
        if (!current()) return LoadResult.STALE
        return buildAndShow(items, remote = false)
    }

    private suspend fun buildAndShow(items: List<MediaItem>, remote: Boolean): LoadResult {
        val enriched = fx.enrich(items, remote)
        if (!current()) return LoadResult.STALE
        val built = fx.build(enriched)
        if (!current()) return LoadResult.STALE
        return if (fx.show(built)) LoadResult.SHOWN else LoadResult.NO_CHANNELS
    }
}
