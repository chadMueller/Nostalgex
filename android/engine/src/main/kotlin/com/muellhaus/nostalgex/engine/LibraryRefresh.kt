package com.muellhaus.nostalgex.engine

/** What a background refresh read: the items, whether the scan was cut short (STOP WAITING, a stall), and how long it took. */
class RefreshRead(val items: List<MediaItem>, val abandoned: Boolean, val tookMs: Long)

/** What a refresh does to the app, one effect at a time, so the order and the guards are testable without a device. */
interface RefreshEffects {
    /** What the app has saved, and the collections it holds: what the new read is compared with. */
    val savedItems: List<MediaItem>
    val heldCollections: List<ServerCollection>

    /** What the guide was built from, enrichment attached. */
    val currentItems: List<MediaItem>

    suspend fun scan(): RefreshRead
    suspend fun markLoaded(abandoned: Boolean)

    /** A whole library was read: the kept sections have done their job, and the read's own figures are noted. */
    suspend fun readComplete(read: RefreshRead)

    suspend fun readCollections(): List<ServerCollection>

    /** Holds the new items and collections and writes the library store. */
    suspend fun save(items: List<MediaItem>, collections: List<ServerCollection>)

    suspend fun enrich(items: List<MediaItem>): List<MediaItem>

    /** Builds the lineup from [enriched] and swaps it in. */
    suspend fun adopt(enriched: List<MediaItem>)

    fun note(line: String)
}

enum class RefreshResult {
    /** The library changed (signed out, another server, a new load) while the refresh ran: nothing it read was kept. */
    STALE,
    ABANDONED,
    UNCHANGED,
    ADOPTED,
}

/**
 * Reads every server again while the guide is up, then asks for the enrichment the local cache didn't have. The guide changes
 * only if the library or its enrichment did.
 *
 * The refresh takes minutes on a big library, and the viewer can sign out, switch server or backend, or load another library in that
 * time. [current] says whether the library it began on is still the one in use; it is asked before every write (the load clock, the
 * kept sections, the library store, the lineup), so a refresh that outlived its library writes nothing of it.
 */
class LibraryRefresh(private val current: () -> Boolean, private val fx: RefreshEffects, private val alwaysSave: Boolean = false) {
    suspend fun run(): RefreshResult {
        val read = fx.scan()
        if (!current()) return RefreshResult.STALE
        // An abandoned refresh is a subset of what is on screen: keep the guide (isLibraryStale).
        if (read.abandoned) {
            fx.note("REFRESH abandoned mid-scan; keeping the loaded lineup")
            fx.markLoaded(abandoned = true)
            return RefreshResult.ABANDONED
        }
        val items = read.items
        fx.markLoaded(abandoned = false)
        if (!current()) return RefreshResult.STALE
        fx.readComplete(read)
        val collections = fx.readCollections()
        if (!current()) return RefreshResult.STALE
        // Members in a new order (a smart collection after a play) are saved, so the next build follows the server's order, but
        // don't rebuild the guide: the stored day stays put either way.
        val collectionsChanged = !Collections.sameMembers(collections, fx.heldCollections)
        val reordered = !collectionsChanged && collections != fx.heldCollections
        val libraryChanged = items != fx.savedItems
        if (libraryChanged || collections != fx.heldCollections || alwaysSave) fx.save(items, collections)
        val enriched = fx.enrich(items)
        if (!current()) return RefreshResult.STALE
        if (enriched == fx.currentItems && !collectionsChanged) {
            fx.note("REFRESH ${items.size} items read in ${read.tookMs} ms; unchanged" +
                if (reordered) " (collection members in a new order, saved)" else "")
            return RefreshResult.UNCHANGED
        }
        val why = when {
            libraryChanged -> "library changed (was ${fx.savedItems.size})"
            collectionsChanged -> "collections changed"
            else -> "enrichment changed"
        }
        fx.note("REFRESH ${items.size} items read in ${read.tookMs} ms; $why, rebuilding")
        fx.adopt(enriched)
        return RefreshResult.ADOPTED
    }
}
