package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import java.text.Normalizer
import java.util.Locale

/**
 * One server collection as the scan reads it: the web tuner's raw collection
 * `{ id, title, childKeys, serverKey }`. [id] is "<serverKey>:<collection key>", and
 * [childKeys] are the server's own keys for its children (films, shows or episodes), resolved
 * against the library by [Collections.resolveMembers]. [title] is null when the server gave
 * none.
 */
@kotlinx.serialization.Serializable
data class ServerCollection(
    val id: String,
    val title: String?,
    val childKeys: List<String>,
    val serverKey: String,
)

/**
 * Server collections as channels: scripts/nostalgex-collections.js, the web tuner's port of
 * the Apple TV's `scanCollections` and `materializeDynamicChannels` (AppState+Channels.swift),
 * CollectionMemberIndex.swift and DynamicChannelBlock. CollectionsVectorTest runs the JS over
 * the Roku port's fixtures and holds this to its answers.
 *
 * The network calls are here as path builders and response parsers, plus drivers that take
 * the fetch as a function, so the app layer brings the HTTP and this stays pure.
 */
object Collections {
    // ChannelIDSpace.dynamicBase and categoryStride: one id block per kind of runtime channel.
    const val DYNAMIC_BASE = 1_000_000
    const val CATEGORY_STRIDE = 10_000
    const val FOUND_ID_BASE = DYNAMIC_BASE
    const val FRANCHISE_COLLECTION_ID_BASE = DYNAMIC_BASE + CATEGORY_STRIDE
    const val ID_BASE = DYNAMIC_BASE + 2 * CATEGORY_STRIDE

    // Found franchises and franchise collections: one pool, CH 310-399.
    const val FRANCHISE_NUMBER_BASE = 310
    const val FRANCHISE_NUMBER_END = 399
    const val FRANCHISE_CAPACITY = FRANCHISE_NUMBER_END - FRANCHISE_NUMBER_BASE + 1

    // Other collections: CH 400-499.
    const val NUMBER_BASE = 400
    const val NUMBER_END = 499
    const val CAPACITY = NUMBER_END - NUMBER_BASE + 1
    const val MIN_MOVIES = 3
    const val MIN_ITEMS = 3
    const val OVERLAP_THRESHOLD = 60
    val COLORS = listOf(
        "#E74C3C", "#3498DB", "#2ECC71", "#F39C12", "#9B59B6",
        "#1ABC9C", "#E67E22", "#00CED1", "#FF6B81", "#A29BFE",
    )

    /**
     * A channel the collections are checked against: a stock channel for the name match and
     * the manifest overlap, or a stock franchise channel (with its [itemPool]) for the fold.
     * The JS takes the lineup's channel objects; only these fields are read.
     */
    data class StockChannel(
        val id: Int,
        val number: Int? = null,
        val name: String = "",
        val itemPool: List<MediaItem> = emptyList(),
    )

    /** `contentOverlap`'s answer: the channel the manifest claims most of a collection for. */
    data class ContentOverlap(
        val channelID: Int,
        val channelName: String,
        val overlapCount: Int,
        val totalCount: Int,
        val percent: Int,
    )

    /** A collection that resolved to 3+ playable items: one row in the collections list. */
    data class Candidate(
        val id: String,
        /** The server's title upper-cased, "UNTITLED" when it had none. */
        val title: String,
        val movieCount: Int,
        val showCount: Int,
        val episodeCount: Int,
        val items: List<MediaItem>,
        val enabled: Boolean,
        val matchedChannel: String?,
        val contentOverlap: ContentOverlap?,
        val foldedInto: String?,
        /** Null unless [Context.classify]; then [materialize] treats null as OTHER COLLECTIONS. */
        val category: CollectionCategory? = null,
    )

    /** `buildCandidates`' ctx. */
    class Context(
        val staticChannels: List<StockChannel> = emptyList(),
        /** For naming the manifest overlap's channel; defaults to [staticChannels] by id. */
        val channelsByID: Map<Int, StockChannel>? = null,
        val franchiseChannels: List<StockChannel> = emptyList(),
        val itemKey: (MediaItem) -> String = { it.ratingKey },
        val enabledKeys: Set<String> = emptySet(),
        /** channels-memberships.json, or null. */
        val manifest: JsonObject? = null,
        val classify: Boolean = false,
        val enrichmentFor: ((MediaItem) -> Enrichment?)? = { it.enrichment },
        /** The franchise fold of nostalgex-franchise-lineup.js; without it, [foldTarget]. */
        val fold: ((Candidate) -> String?)? = null,
    )

    /** One server's library, by key: `indexLibrary`'s `{ byKey, byShow }`. */
    class LibraryIndex internal constructor(
        val byKey: Map<String, MediaItem>,
        val byShow: Map<String, List<MediaItem>>,
    )

    /** A found franchise for the CH 310-399 pool, `materialize`'s `opts.found` entry. */
    data class FoundFranchiseEntry(
        val id: String,
        val name: String,
        val movies: List<MediaItem> = emptyList(),
        val tvItems: List<MediaItem> = emptyList(),
    )

    /** One runtime channel `materialize` builds (`runtimeChannel`). No rules: the pool is the channel. */
    data class CollectionChannel(
        val id: Int,
        val number: Int,
        val name: String,
        val colorHex: String,
        val category: CollectionCategory,
        /** True for a server collection, false for a found franchise. */
        val collection: Boolean,
        val foundFranchise: Boolean = false,
        val franchiseID: String? = null,
        val collectionID: String? = null,
        val itemPool: List<MediaItem>,
        val minItems: Int = MIN_ITEMS,
        val stock: Boolean = false,
        val enabled: Boolean = itemPool.size >= MIN_ITEMS,
    )

    class Materialized(
        val channels: List<CollectionChannel>,
        /** Collections past their block. */
        val overCap: Int,
        val overCapFranchises: Int,
        val overCapCustom: Int,
        /** Found franchises past the franchise block. */
        val overCapFound: Int,
    )

    /** One entry for [keptInDisplayOrder]. */
    data class BlockEntry<T>(val name: String, val stableID: String, val films: Int, val value: T)

    class Kept<T>(val kept: List<BlockEntry<T>>, val skipped: Int)

    // ── Duplicate detection ──

    /** Swift `collectionClean`: lowercased, "collection" removed, "'s" -> "s". */
    fun cleanTitle(title: String?): String = JsText.trim(
        (title ?: "").lowercase(Locale.ROOT)
            .replace(" collection", "")
            .replace("collection", "")
            .replace("'s", "s")
            .replace("’s", "s"),
    )

    /** Swift `decadeNormalized`: "2000s" -> "00s", "80s" -> "80s", else null. */
    fun decadeNormalized(clean: String): String? {
        val digits = clean.filter { it in '0'..'9' }
        if (digits.length == 4) return "${(digits.toInt() % 100).toString().padStart(2, '0')}s"
        if (digits.length == 2) return "${digits}s"
        return null
    }

    fun channelLabel(ch: StockChannel) = "CH ${ch.number ?: ch.id} ${ch.name}"

    /** Name-similarity match against the stock lineup (Swift `staticChannelLookup`). */
    fun matchStaticChannel(title: String?, staticChannels: List<StockChannel>): String? {
        val clean = cleanTitle(title)
        if (clean.isEmpty()) return null
        val decade = decadeNormalized(clean)
        for (ch in staticChannels) {
            val name = ch.name.lowercase(Locale.ROOT)
            if (name.contains(clean) || clean.contains(name)) return channelLabel(ch)
            if (decade != null && name.contains(decade)) return channelLabel(ch)
        }
        return null
    }

    /**
     * Swift `computeContentOverlap`: the channel the membership manifest claims the most of
     * these items for, when that is [threshold]% or more of them. The percent is JS's
     * `Math.round((count / total) * 100)` in doubles, so 23 of 40 is 57.49999999999999 and 57.
     */
    fun contentOverlap(
        items: List<MediaItem>,
        manifest: JsonObject?,
        channelsByID: Map<Int, StockChannel>,
        threshold: Int = OVERLAP_THRESHOLD,
    ): ContentOverlap? {
        val total = items.size
        val entries = manifest?.get("items") as? JsonObject
        if (total == 0 || entries == null) return null
        val perChannel = LinkedHashMap<Int, Int>()
        for (item in items) {
            val tmdb = item.tmdbID ?: continue
            val mediaType = if (item.type == "episode") "tv" else "movie"
            val channels = ((entries["$mediaType:$tmdb"] as? JsonObject)?.get("channels") as? JsonArray) ?: continue
            for (c in channels) {
                val cid = (c as? JsonPrimitive)?.doubleOrNull?.toInt() ?: continue
                perChannel[cid] = (perChannel[cid] ?: 0) + 1
            }
        }
        var bestID: Int? = null
        var bestCount = 0
        for ((cid, count) in perChannel) {
            if (bestID == null || count > bestCount) {
                bestID = cid
                bestCount = count
            }
        }
        if (bestID == null) return null
        val percent = jsRoundPercent(bestCount, total)
        if (percent < threshold) return null
        val ch = channelsByID[bestID]
        return ContentOverlap(bestID, if (ch != null) channelLabel(ch) else "CH $bestID", bestCount, total, percent)
    }

    /** `Math.round((count / total) * 100)`. Java's Math.round rounds half up, as JS's does for positives. */
    private fun jsRoundPercent(count: Int, total: Int): Int = Math.round((count.toDouble() / total) * 100).toInt()

    /**
     * FranchiseCollectionFold steps 3 and 4 against the stock franchise channels: the name
     * match or manifest overlap points at one, or 60%+ of the collection's items already sit
     * in one's pool. Returns the target label or null.
     *
     * A folded collection is hidden, so one that holds shows folds only into a channel already
     * airing an episode of each of them (Swift `carriesEveryShow`).
     */
    fun foldTarget(
        collection: Candidate,
        franchiseChannels: List<StockChannel>,
        itemKey: (MediaItem) -> String = { it.ratingKey },
        threshold: Int = OVERLAP_THRESHOLD,
    ): String? {
        if (franchiseChannels.isEmpty()) return null
        val ch = pickFoldChannel(collection, franchiseChannels, itemKey, threshold) ?: return null
        if (!carriesEveryShow(collection, ch, itemKey)) return null
        return channelLabel(ch)
    }

    private fun pickFoldChannel(
        collection: Candidate,
        franchiseChannels: List<StockChannel>,
        itemKey: (MediaItem) -> String,
        threshold: Int,
    ): StockChannel? {
        // A JS Map built from pairs keeps the last channel for a repeated label.
        val labels = franchiseChannels.associateBy(::channelLabel)
        collection.matchedChannel?.let { m -> labels[m]?.let { return it } }
        collection.contentOverlap?.let { o -> franchiseChannels.firstOrNull { it.id == o.channelID }?.let { return it } }
        val total = collection.items.size
        if (total == 0) return null
        val keys = collection.items.mapTo(HashSet(), itemKey)
        var best: StockChannel? = null
        var bestCount = 0
        for (ch in franchiseChannels) {
            val count = ch.itemPool.count { keys.contains(itemKey(it)) }
            if (count > bestCount) {
                best = ch
                bestCount = count
            }
        }
        if (best != null && jsRoundPercent(bestCount, total) >= threshold) return best
        return null
    }

    private fun carriesEveryShow(collection: Candidate, ch: StockChannel, itemKey: (MediaItem) -> String): Boolean {
        val pool = ch.itemPool.mapTo(HashSet(), itemKey)
        // As the JS: a show is covered once any of its episodes is in the pool.
        val covered = LinkedHashMap<String, Boolean>()
        for (it in collection.items) {
            if (it.type != "episode") continue
            val show = showIdentity(it)
            if (covered[show] == true) continue
            covered[show] = pool.contains(itemKey(it))
        }
        return covered.values.all { it }
    }

    // ── Members (CollectionMemberIndex.swift) ──

    /** Which show an episode belongs to: its show key, else its show title. */
    fun showIdentity(it: MediaItem): String =
        if (!it.showKey.isNullOrEmpty()) "key:${it.showKey}" else "title:${it.title}"

    /**
     * Index the library per server: every item by ratingKey (the first wins), and episodes
     * grouped by their show key, in library order.
     */
    fun indexLibrary(items: List<MediaItem>, serverKeyFor: (MediaItem) -> String): Map<String, LibraryIndex> {
        val byKey = LinkedHashMap<String, LinkedHashMap<String, MediaItem>>()
        val byShow = LinkedHashMap<String, LinkedHashMap<String, MutableList<MediaItem>>>()
        for (it in items) {
            val sk = serverKeyFor(it)
            val keys = byKey.getOrPut(sk) { LinkedHashMap() }
            val shows = byShow.getOrPut(sk) { LinkedHashMap() }
            if (!keys.containsKey(it.ratingKey)) keys[it.ratingKey] = it
            if (it.type == "episode" && !it.showKey.isNullOrEmpty()) shows.getOrPut(it.showKey) { ArrayList() }.add(it)
        }
        val out = LinkedHashMap<String, LibraryIndex>()
        for ((sk, keys) in byKey) out[sk] = LibraryIndex(keys, byShow[sk]!!)
        return out
    }

    /**
     * Child keys to library items, each once, in child order. A film or episode key is that
     * item; a show key is every episode of that show. Unknown keys are dropped.
     */
    fun resolveMembers(childKeys: List<String>, index: LibraryIndex?): List<MediaItem> {
        if (index == null) return emptyList()
        val items = ArrayList<MediaItem>()
        // One index is one server, where a ratingKey is unique.
        val seen = HashSet<String>()
        fun add(it: MediaItem) {
            if (seen.add(it.ratingKey)) items.add(it)
        }
        for (key in childKeys) {
            val it = index.byKey[key]
            if (it != null) add(it) else index.byShow[key]?.forEach(::add)
        }
        return items
    }

    private class Counts(val movies: Int, val shows: Int, val episodes: Int)

    private fun countMembers(items: List<MediaItem>): Counts {
        var movies = 0
        val shows = HashSet<String>()
        for (it in items) if (it.type == "episode") shows.add(showIdentity(it)) else movies++
        return Counts(movies, shows.size, items.size - movies)
    }

    /** Films plus the first episode of each show: one entry per title. */
    fun titleRepresentatives(items: List<MediaItem>): List<MediaItem> {
        val seen = HashSet<String>()
        return items.filter { it.type != "episode" || seen.add(showIdentity(it)) }
    }

    /** Swift `DiscoveredCollection.memberSummary`. */
    fun memberSummary(movies: Int, shows: Int, episodes: Int): String {
        fun plural(n: Int, one: String, many: String) = "$n ${if (n == 1) one else many}"
        if (shows == 0) return "$movies movies"
        if (movies == 0) return "${plural(shows, "show", "shows")} · ${plural(episodes, "episode", "episodes")}"
        return "${plural(movies, "movie", "movies")} · ${plural(shows, "show", "shows")}"
    }

    fun memberSummary(c: Candidate) = memberSummary(c.movieCount, c.showCount, c.episodeCount)

    // ── The runtime blocks (DynamicChannelBlock.keptInDisplayOrder) ──

    /** Swift String `<` for these names: NFC-normalized, then by code point. */
    fun compareStrings(a: String, b: String): Int {
        val x = Normalizer.normalize(a, Normalizer.Form.NFC)
        val y = Normalizer.normalize(b, Normalizer.Form.NFC)
        var i = 0
        var j = 0
        while (i < x.length && j < y.length) {
            val cx = x.codePointAt(i)
            val cy = y.codePointAt(j)
            if (cx != cy) return if (cx < cy) -1 else 1
            i += Character.charCount(cx)
            j += Character.charCount(cy)
        }
        val restX = i < x.length
        val restY = j < y.length
        return if (restX == restY) 0 else if (restY) -1 else 1
    }

    /**
     * The switched-on entries a block keeps, in the order they are numbered. When more are on
     * than fit, the ones with the most films stay; ties go to the name, then the stable id, so
     * every platform drops the same ones. The kept ones are then numbered A to Z.
     */
    fun <T> keptInDisplayOrder(entries: List<BlockEntry<T>>, capacity: Int): Kept<T> {
        val alphabetical = Comparator<BlockEntry<T>> { a, b ->
            compareStrings(a.name, b.name).takeIf { it != 0 } ?: compareStrings(a.stableID, b.stableID)
        }
        if (entries.size <= capacity) return Kept(entries.sortedWith(alphabetical), 0)
        val kept = entries
            .sortedWith(Comparator { a, b -> if (a.films != b.films) b.films.compareTo(a.films) else alphabetical.compare(a, b) })
            .take(capacity)
        return Kept(kept.sortedWith(alphabetical), entries.size - capacity)
    }

    // ── Candidates and channels ──

    /**
     * `buildCandidates`: each raw collection resolved on its own server's [index], kept when it
     * has 3+ items, sorted by upper-cased title (Swift `<`, here UTF-16 code units as the JS
     * compares, stable for equal titles).
     */
    fun buildCandidates(raw: List<ServerCollection>, index: Map<String, LibraryIndex>, ctx: Context = Context()): List<Candidate> {
        val channelsByID = ctx.channelsByID ?: ctx.staticChannels.associateBy { it.id }
        val out = ArrayList<Candidate>()
        for (c in raw) {
            val items = resolveMembers(c.childKeys, index[c.serverKey])
            if (items.size < MIN_ITEMS) continue
            val counts = countMembers(items)
            var candidate = Candidate(
                id = c.id,
                title = (c.title?.takeIf { it.isNotEmpty() } ?: "Untitled").uppercase(Locale.ROOT),
                movieCount = counts.movies,
                showCount = counts.shows,
                episodeCount = counts.episodes,
                items = items,
                enabled = c.id in ctx.enabledKeys,
                matchedChannel = matchStaticChannel(c.title, ctx.staticChannels),
                // One entry per show, so a long show does not outweigh the rest of the set.
                contentOverlap = contentOverlap(titleRepresentatives(items), ctx.manifest, channelsByID),
                foldedInto = null,
            )
            // The classifier reads the server's own title, not the upper-cased one.
            if (ctx.classify) candidate = candidate.copy(category = CollectionClassifier.classify(c.title, items, ctx.enrichmentFor))
            val fold = ctx.fold
            candidate = candidate.copy(
                foldedInto = if (fold != null) fold(candidate) else foldTarget(candidate, ctx.franchiseChannels, ctx.itemKey),
            )
            out.add(candidate)
        }
        return out.sortedWith(Comparator { a, b -> a.title.compareTo(b.title) })
    }

    /** Swift `duplicateWarning`, without the warning glyph. */
    fun duplicateWarning(c: Candidate): String? {
        c.contentOverlap?.let { return "${it.percent}% already on ${it.channelName}" }
        c.matchedChannel?.let { return "Exists: $it" }
        return null
    }

    /**
     * Swift `materializeDynamicChannels`: every runtime channel, in number order.
     *
     * The franchise pool (CH 310-399): the [found] franchises (switched on, no stock channel
     * covering them) and the enabled, unfolded candidates classified FRANCHISES. When more than
     * 90 are on, the ones with the most films stay, then the kept ones are numbered by name,
     * then stable id (`f:` found, `c:` collection). Ids stay per kind, in numbering order.
     *
     * OTHER COLLECTIONS (CH 400-499): the other enabled, unfolded candidates in list order,
     * the first 100. Anything switched on past a block is not built.
     */
    fun materialize(candidates: List<Candidate>, found: List<FoundFranchiseEntry> = emptyList()): Materialized {
        val entries = ArrayList<BlockEntry<Any>>()
        for (f in found) entries.add(BlockEntry(f.name, "f:${f.id}", f.movies.size, f))
        val others = ArrayList<Candidate>()
        for (c in candidates) {
            if (!c.enabled || c.foldedInto != null) continue
            if (c.category == CollectionCategory.FRANCHISES) {
                entries.add(BlockEntry(c.title, "c:${c.id}", c.movieCount, c))
            } else {
                others.add(c)
            }
        }

        val channels = ArrayList<CollectionChannel>()
        val pool = keptInDisplayOrder(entries, FRANCHISE_CAPACITY)
        var foundCount = 0
        var collectionCount = 0
        pool.kept.forEachIndexed { slot, e ->
            val number = FRANCHISE_NUMBER_BASE + slot
            val color = COLORS[slot % COLORS.size]
            when (val v = e.value) {
                is FoundFranchiseEntry -> channels.add(CollectionChannel(
                    id = FOUND_ID_BASE + foundCount++, number = number, name = v.name, colorHex = color,
                    category = CollectionCategory.FRANCHISES, collection = false, foundFranchise = true,
                    franchiseID = v.id, itemPool = v.movies + v.tvItems,
                ))
                is Candidate -> channels.add(CollectionChannel(
                    id = FRANCHISE_COLLECTION_ID_BASE + collectionCount++, number = number, name = v.title,
                    colorHex = color, category = CollectionCategory.FRANCHISES, collection = true,
                    collectionID = v.id, itemPool = v.items.toList(),
                ))
            }
        }
        val keptStable = pool.kept.mapTo(HashSet()) { it.stableID }
        val waiting = entries.filter { it.stableID !in keptStable }
        val overCapFound = waiting.count { it.value is FoundFranchiseEntry }
        val overCapFranchises = waiting.size - overCapFound

        var overCapCustom = 0
        var slot = 0
        for (c in others) {
            if (slot >= CAPACITY) {
                overCapCustom++
                continue
            }
            channels.add(CollectionChannel(
                id = ID_BASE + slot, number = NUMBER_BASE + slot, name = c.title, colorHex = COLORS[slot % COLORS.size],
                category = CollectionCategory.CUSTOM, collection = true, collectionID = c.id, itemPool = c.items.toList(),
            ))
            slot++
        }
        return Materialized(channels, overCapFranchises + overCapCustom, overCapFranchises, overCapCustom, overCapFound)
    }

    // ── Network: Plex ──
    //
    // /library/sections, then /library/sections/{key}/collections per movie and TV section (a
    // Plex collection of shows lives in the TV library), then /library/collections/{key}/children
    // for each collection's ratingKeys.

    const val PLEX_SECTIONS_PATH = "/library/sections"

    fun plexSectionCollectionsPath(sectionKey: String) = "/library/sections/$sectionKey/collections"

    fun plexCollectionChildrenPath(collectionKey: String) = "/library/collections/$collectionKey/children"

    /** The keys of the movie and TV sections in a /library/sections answer, in order. */
    fun parsePlexSections(doc: JsonElement): List<String> =
        metadataRows(doc, "Directory")
            .filter { val t = (it["type"] as? JsonPrimitive)?.takeIf { p -> p.isString }?.content; t == "movie" || t == "show" }
            .map { jsString(it["key"]) }

    /** One row of a section's collections: its ratingKey, as JS's `String(ratingKey)`, and title. */
    data class PlexCollectionRow(val ratingKey: String, val title: String?)

    /** The collections in a /library/sections/{key}/collections answer, rows without a ratingKey dropped. */
    fun parsePlexSectionCollections(doc: JsonElement): List<PlexCollectionRow> =
        metadataRows(doc, "Metadata").mapNotNull { c ->
            val key = c["ratingKey"]
            if (key == null || key is JsonNull) null else PlexCollectionRow(jsString(key), jsTitle(c["title"]))
        }

    /** The child ratingKeys in a /library/collections/{key}/children answer. */
    fun parsePlexCollectionChildren(doc: JsonElement): List<String> =
        metadataRowElements(doc, "Metadata").map { jsString((it as? JsonObject)?.get("ratingKey")) }

    fun plexCollection(serverKey: String, row: PlexCollectionRow, childKeys: List<String>) =
        ServerCollection("$serverKey:${row.ratingKey}", row.title ?: "Untitled", childKeys, serverKey)

    /**
     * `fetchPlexCollections`, with the fetch passed in: [getJSON] fetches one server path and
     * returns the parsed answer, or throws. The section list failing throws; a section that
     * fails is skipped; a collection whose children fail is dropped. One call at a time,
     * where the JS has four children calls in flight; the answer is the same.
     */
    fun fetchPlexCollections(
        serverKey: String,
        getJSON: (String) -> JsonElement,
        onProgress: ((Int, Int) -> Unit)? = null,
    ): List<ServerCollection> {
        val sections = parsePlexSections(getJSON(PLEX_SECTIONS_PATH))
        val list = ArrayList<PlexCollectionRow>()
        val seen = HashSet<String>()
        for (key in sections) {
            try {
                for (row in parsePlexSectionCollections(getJSON(plexSectionCollectionsPath(key)))) {
                    if (seen.add(row.ratingKey)) list.add(row)
                }
            } catch (e: Exception) {
                // The JS warns on the console and goes on to the next section.
            }
        }
        val out = ArrayList<ServerCollection>()
        list.forEachIndexed { i, row ->
            val childKeys = try {
                parsePlexCollectionChildren(getJSON(plexCollectionChildrenPath(row.ratingKey)))
            } catch (e: Exception) {
                null
            }
            onProgress?.invoke(i + 1, list.size)
            if (childKeys != null) out.add(plexCollection(serverKey, row, childKeys))
        }
        return out
    }

    // ── Network: Jellyfin and Emby ──
    //
    // BoxSet items from /Items (one global list, deduped by id), then the Movie and Series
    // children of each BoxSet, 200 a page. Jellyfin answers with the series ids, Emby with the
    // series' episodes; resolveMembers takes either.

    const val BOXSET_PAGE_SIZE = 200

    fun boxSetListPath(userId: String) =
        "/Items?userId=${encodeURIComponent(userId)}&IncludeItemTypes=BoxSet&Recursive=true&Fields=ChildCount&SortBy=SortName"

    fun boxSetChildrenPath(userId: String, boxSetId: String, startIndex: Int) =
        "/Items?userId=${encodeURIComponent(userId)}&ParentId=${encodeURIComponent(boxSetId)}&Recursive=true" +
            "&IncludeItemTypes=Movie,Series&StartIndex=$startIndex&Limit=$BOXSET_PAGE_SIZE&SortBy=SortName"

    /** One BoxSet from the list: its id, as JS's `String(Id)`, and name. */
    data class BoxSetRow(val id: String, val name: String?)

    /**
     * The BoxSets in the list answer, in order, deduped by id, rows with no id (or an empty
     * or zero one, which JS reads as false) dropped.
     */
    fun parseBoxSetList(doc: JsonElement): List<BoxSetRow> {
        val seen = HashSet<JsonPrimitive>()
        val out = ArrayList<BoxSetRow>()
        for (el in itemsOf(doc)) {
            val b = el as? JsonObject ?: continue
            val id = b["Id"] as? JsonPrimitive ?: continue
            if (!jsTruthy(id) || !seen.add(id)) continue
            out.add(BoxSetRow(jsString(id), jsTitle(b["Name"])))
        }
        return out
    }

    /** One page of a BoxSet's children: their ids and the server's TotalRecordCount, if it sent one. */
    class BoxSetPage(val childKeys: List<String>, val totalRecordCount: Double?)

    fun parseBoxSetPage(doc: JsonElement): BoxSetPage {
        val total = ((doc as? JsonObject)?.get("TotalRecordCount") as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull
        return BoxSetPage(itemsOf(doc).map { jsString((it as? JsonObject)?.get("Id")) }, total)
    }

    /**
     * Whether to stop paging a BoxSet after a page: it was empty, or the keys so far reach
     * TotalRecordCount (the keys so far when the server sent none).
     */
    fun boxSetPagingDone(page: BoxSetPage, keysSoFar: Int): Boolean =
        page.childKeys.isEmpty() || keysSoFar >= (page.totalRecordCount ?: keysSoFar.toDouble())

    fun boxSetCollection(serverKey: String, row: BoxSetRow, childKeys: List<String>) =
        ServerCollection("$serverKey:${row.id}", row.name ?: "Untitled", childKeys, serverKey)

    /**
     * `fetchBoxSetCollections`, with the fetch passed in as for [fetchPlexCollections]. The
     * list failing throws; a BoxSet with any page failing is dropped. One call at a time,
     * where the JS reads four BoxSets at once.
     */
    fun fetchBoxSetCollections(
        serverKey: String,
        userId: String,
        getJSON: (String) -> JsonElement,
        onProgress: ((Int, Int) -> Unit)? = null,
    ): List<ServerCollection> {
        val boxSets = parseBoxSetList(getJSON(boxSetListPath(userId)))
        val out = ArrayList<ServerCollection>()
        boxSets.forEachIndexed { i, b ->
            val childKeys = try {
                val keys = ArrayList<String>()
                var start = 0
                while (true) {
                    val page = parseBoxSetPage(getJSON(boxSetChildrenPath(userId, b.id, start)))
                    keys.addAll(page.childKeys)
                    start += page.childKeys.size
                    if (boxSetPagingDone(page, keys.size)) break
                }
                keys
            } catch (e: Exception) {
                null
            }
            onProgress?.invoke(i + 1, boxSets.size)
            if (childKeys != null) out.add(boxSetCollection(serverKey, b, childKeys))
        }
        return out
    }

    // ── JS's reading of JSON ──

    private fun metadataRowElements(doc: JsonElement, key: String): List<JsonElement> =
        (((doc as? JsonObject)?.get("MediaContainer") as? JsonObject)?.get(key) as? JsonArray) ?: emptyList()

    private fun metadataRows(doc: JsonElement, key: String): List<JsonObject> =
        metadataRowElements(doc, key).mapNotNull { it as? JsonObject }

    private fun itemsOf(doc: JsonElement): List<JsonElement> = ((doc as? JsonObject)?.get("Items") as? JsonArray) ?: emptyList()

    /** `x || 'Untitled'` reads an empty or missing title as none; null here, the caller substitutes. */
    private fun jsTitle(v: JsonElement?): String? {
        val p = v as? JsonPrimitive ?: return null
        if (!jsTruthy(p)) return null
        return jsString(p)
    }

    private fun jsTruthy(p: JsonPrimitive): Boolean = when {
        p is JsonNull -> false
        p.isString -> p.content.isNotEmpty()
        p.booleanOrNull != null -> p.booleanOrNull!!
        else -> p.doubleOrNull.let { it != null && it != 0.0 && !it.isNaN() }
    }

    /** JavaScript's `String(v)` for a JSON value: whole numbers without ".0", a missing one "undefined". */
    internal fun jsString(v: JsonElement?): String = when (v) {
        null -> "undefined"
        is JsonNull -> "null"
        is JsonPrimitive -> when {
            v.isString -> v.content
            v.booleanOrNull != null -> v.content
            else -> {
                val d = v.doubleOrNull
                if (d != null && d == Math.floor(d) && Math.abs(d) < 1e21) d.toLong().toString() else v.content
            }
        }
        else -> v.toString()
    }

    /** JavaScript's `encodeURIComponent`: UTF-8, everything but A-Z a-z 0-9 - _ . ! ~ * ' ( ) escaped. */
    fun encodeURIComponent(s: String): String {
        val sb = StringBuilder()
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val c = b.toInt() and 0xff
            val ch = c.toChar()
            if (ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || "-_.!~*'()".indexOf(ch) >= 0) sb.append(ch)
            else sb.append('%').append("0123456789ABCDEF"[c shr 4]).append("0123456789ABCDEF"[c and 15])
        }
        return sb.toString()
    }
}
