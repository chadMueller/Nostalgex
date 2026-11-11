package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull
import java.util.Locale

/**
 * The FRANCHISES package in a lineup: what the franchise builder found, which of it airs,
 * how it joins the stock classics, which server collections are the same franchise and fold
 * away, and where every franchise channel is numbered. A port of
 * scripts/nostalgex-franchise-lineup.js, itself the web port of the Apple TV's
 * AppState+Franchises.swift (rebuildFoundFranchises, franchiseListRows, stockPools,
 * applyFranchiseFolds), FranchiseCollectionFold.swift and the franchise half of
 * AppState+Channels.swift (materializeDynamicChannels, applyBundleFilter).
 *
 * scripts/franchise-lineup-golden.json, written by the Apple TV's own tests, holds this to the
 * same rows, folds, channels and numbers (FranchiseLineupGoldenTest). In the Apple TV's order:
 *   1. the builder groups the library into franchises (found);
 *   2. while the package is on, what a classic covers joins that classic's pool;
 *   3. the server's collections are classified and folded against the classics and the
 *      found franchises that are left;
 *   4. the found franchises and the franchise collections that are on share CH 310-399.
 */
object FranchiseLineup {
    /** A franchise the builder found, as Settings lists it (FoundFranchise). */
    data class Found(
        /** FranchiseGrouping.stableID: "dict:STAR WARS", "tmdb:2806". */
        val id: String,
        val name: String,
        val movies: List<MediaItem>,
        val tvItems: List<MediaItem>,
        /** The stock channel (ids 100-106, CH 300-306) this franchise folds into, if any. */
        val coveredByChannelID: Int?,
        val fromDictionary: Boolean,
        val enabled: Boolean,
    ) {
        val isCovered get() = coveredByChannelID != null
        val items get() = movies + tvItems
    }

    /** One row of the single franchise list in Settings (FranchiseListRow). */
    data class Row(
        val id: String,
        val name: String,
        val countLabel: String,
        /** The stock channel this row switches, null for a found franchise. */
        val stockChannelID: Int?,
        /** The number Settings shows for a stock row ("CH 300"). */
        val channelNumber: Int?,
        val enabled: Boolean,
    )

    /** A stock classic in the lineup, with the pool its rule built. */
    data class Stock(val id: Int, val number: Int, val name: String, val itemPool: List<MediaItem>)

    /** Server collections, as Collections.buildCandidates takes them. */
    class CollectionInput(
        val raw: List<ServerCollection>,
        val indexByServer: Map<String, Collections.LibraryIndex>,
        /** Every rule-built channel in the lineup, for the name match ("CH 300 STAR WARS"). */
        val staticChannels: List<Collections.StockChannel>,
        val enabledKeys: Set<String>,
    )

    class Result(
        val found: List<Found>,
        /** What each classic's pool gains while the package is on, in order (stockPools). */
        val stockAdditions: Map<Int, List<MediaItem>>,
        /** The classics the viewer switched off in the franchise list. */
        val switchedOffStock: Set<Int>,
        val rows: List<Row>,
        val candidates: List<Collections.Candidate>,
        /** Every runtime channel, in number order. */
        val channels: List<Collections.CollectionChannel>,
        val overCapFound: Int,
        val overCapFranchises: Int,
        val overCapCustom: Int,
    )

    // ── Choices ──────────────────────────────────────────────────────────

    /** FranchiseDictionary.isOn(defaultOn:): an explicit choice wins, else the default. */
    fun isOn(id: String, enabledIDs: Set<String>, disabledIDs: Set<String>, defaultOn: Boolean): Boolean = when {
        id in enabledIDs -> true
        id in disabledIDs -> false
        else -> defaultOn
    }

    /** A stock classic is on unless the viewer switched it off. */
    fun stockFranchiseOn(id: String, enabledIDs: Set<String>, disabledIDs: Set<String>) = isOn(id, enabledIDs, disabledIDs, true)

    private fun stockDefinitions(definitions: List<FranchiseDefinition>): Map<Int, FranchiseDefinition> {
        val out = LinkedHashMap<Int, FranchiseDefinition>()
        for (def in definitions) def.stockChannelID?.let { out[it] = def }
        return out
    }

    /** switchedOffStockFranchiseChannelIDs: the classics the viewer took out of the guide. */
    fun switchedOffStockChannelIDs(definitions: List<FranchiseDefinition>, enabledIDs: Set<String>, disabledIDs: Set<String>): Set<Int> =
        stockDefinitions(definitions).filter { (_, def) -> !stockFranchiseOn("dict:" + def.canonicalName, enabledIDs, disabledIDs) }.keys.toSortedSet()

    // ── Found franchises ─────────────────────────────────────────────────

    /** rebuildFoundFranchises, after the builder. A franchise a classic covers has no switch, so is never enabled. */
    fun foundFromGroupings(groupings: List<FranchiseGrouping>, enabledIDs: Set<String>, disabledIDs: Set<String>, definitions: List<FranchiseDefinition>) =
        groupings.map { g ->
            val covered = (g.placement as? FranchisePlacement.Stock)?.channelID
            Found(g.stableID, g.name, g.movies, g.tvItems, covered, g.fromDictionary,
                covered == null && FranchiseBuilder.isOn(g.stableID, enabledIDs, disabledIDs, definitions))
        }

    private fun showCount(items: List<MediaItem>) = items.map { it.title }.toSet().size

    private fun plural(n: Int, one: String, many: String) = "$n ${if (n == 1) one else many}"

    /** FoundFranchise.countLabel and FranchiseListRow.countLabel(movies:shows:). */
    fun countLabel(movies: Int, shows: Int, emptyLabel: String): String {
        val parts = ArrayList<String>()
        if (movies > 0) parts += plural(movies, "movie", "movies")
        if (shows > 0) parts += plural(shows, "show", "shows")
        return if (parts.isEmpty()) emptyLabel else parts.joinToString(", ")
    }

    // ── Settings rows ────────────────────────────────────────────────────

    /**
     * Case-insensitive, digit runs compared as numbers: Swift's localizedStandardCompare for
     * these names, as the JS approximates it (UTF-16 units compared, as JS `<` does).
     */
    fun naturalCompare(a: String, b: String): Int {
        val x = a.lowercase(Locale.ROOT)
        val y = b.lowercase(Locale.ROOT)
        fun digit(c: Char) = c in '0'..'9'
        var i = 0
        var j = 0
        while (i < x.length && j < y.length) {
            if (digit(x[i]) && digit(y[j])) {
                val si = i
                while (i < x.length && digit(x[i])) i++
                val sj = j
                while (j < y.length && digit(y[j])) j++
                // Number() of a digit run: as a double, so a very long run compares as JS does.
                val nx = x.substring(si, i).toDouble()
                val ny = y.substring(sj, j).toDouble()
                if (nx != ny) return if (nx < ny) -1 else 1
            } else {
                if (x[i] != y[j]) return if (x[i] < y[j]) -1 else 1
                i++
                j++
            }
        }
        val left = x.length - i
        val right = y.length - j
        return left.compareTo(right).coerceIn(-1, 1)
    }

    /**
     * franchiseListRows: every classic in the package and every found franchise no classic
     * covers, alphabetical, each with its own switch. A classic counts its channel's pool,
     * less the films a non-stock dictionary franchise owns (Spider-Man's MCU films also pass
     * MARVEL's studio rule): they are counted once, on their own row.
     */
    fun listRows(
        definitions: List<FranchiseDefinition>, bundleChannelIDs: List<Int>, stockChannels: List<Stock>, found: List<Found>,
        enabledIDs: Set<String>, disabledIDs: Set<String>, itemKey: (MediaItem) -> String,
    ): List<Row> {
        val claimed = HashSet<String>()
        for (f in found) if (f.fromDictionary && !f.isCovered) f.items.forEach { claimed += itemKey(it) }
        val byStock = stockDefinitions(definitions)
        val rows = ArrayList<Row>()
        val seen = HashSet<String>()
        for (channelID in bundleChannelIDs) {
            val def = byStock[channelID] ?: continue
            val channel = stockChannels.firstOrNull { it.id == channelID }
            val pool = (channel?.itemPool ?: emptyList()).filter { itemKey(it) !in claimed }
            val id = "dict:" + def.canonicalName
            rows += Row(
                id, def.canonicalName,
                countLabel(pool.count { it.type == "movie" }, showCount(pool.filter { it.type == "episode" }), "None in your library yet"),
                channelID, channel?.number ?: channelID, stockFranchiseOn(id, enabledIDs, disabledIDs),
            )
            seen += id
        }
        for (f in found) {
            if (f.isCovered || f.id in seen) continue
            rows += Row(f.id, f.name, countLabel(f.movies.size, showCount(f.tvItems), ""), null, null, f.enabled)
        }
        return rows.sortedWith { a, b -> naturalCompare(a.name, b.name).takeIf { it != 0 } ?: a.id.compareTo(b.id).coerceIn(-1, 1) }
    }

    // ── Stock pools ──────────────────────────────────────────────────────

    /**
     * isLockedElsewhere: true when `item` belongs to a channel other than `channelID` by a
     * manifest lock or an exclusive rule. The same two locks the channel filter honours.
     */
    fun isLockedElsewhere(item: MediaItem, channelID: Int, manifest: JsonObject?, exclusiveRules: List<ChannelFilter.ExclusiveRule>): Boolean {
        val entry = ChannelFilter.manifestEntry(item, manifest)
        val exclusive = (entry?.get("exclusive") as? JsonPrimitive)?.intOrNull
        if (exclusive != null && exclusive != channelID) return true
        val genres = item.genres.map { it.lowercase() }
        for (rule in exclusiveRules) {
            if (channelID in rule.channelIDs) continue
            if (!ChannelFilter.exclusiveRuleApplies(item, rule)) continue
            if (ChannelFilter.exclusiveRuleMatches(item, genres, rule)) return true
            val claims = (entry?.get("channels") as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.intOrNull } ?: emptyList()
            if (rule.manifestExclusive && entry != null && claims.any { it in rule.channelIDs }) return true
        }
        return false
    }

    /**
     * stockPools: what each covered franchise adds to its classic's pool. A classic's pool is
     * what its channels.json rule passes UNION the items the builder placed on it: six of the
     * seven rules say `type: movie`, so without this The Mandalorian would be labelled "on CH
     * 300" in Settings and never air there. Items already in the pool, and anything another
     * channel owns, are skipped.
     */
    fun stockPoolAdditions(
        found: List<Found>, stockChannels: List<Stock>, itemKey: (MediaItem) -> String,
        manifest: JsonObject?, exclusiveRules: List<ChannelFilter.ExclusiveRule>,
    ): Map<Int, List<MediaItem>> {
        val extras = LinkedHashMap<Int, MutableList<MediaItem>>()
        for (f in found) {
            val id = f.coveredByChannelID ?: continue
            extras.getOrPut(id) { ArrayList() }.addAll(f.movies + f.tvItems)
        }
        val out = LinkedHashMap<Int, List<MediaItem>>()
        for (channel in stockChannels) {
            val additions = extras[channel.id] ?: continue
            val seen = channel.itemPool.mapTo(HashSet(), itemKey)
            val add = ArrayList<MediaItem>()
            for (item in additions) {
                val key = itemKey(item)
                if (key in seen) continue
                if (isLockedElsewhere(item, channel.id, manifest, exclusiveRules)) continue
                add += item
                seen += key
            }
            if (add.isNotEmpty()) out[channel.id] = add
        }
        return out
    }

    // ── The fold (FranchiseCollectionFold.swift) ─────────────────────────

    class Target(val label: String, val itemKeys: Set<String>, val dictionaryName: String?, val stockChannelID: Int?)

    /**
     * What a server collection can fold into: each classic in the lineup (label "CH 300 STAR
     * WARS", the pool it airs), then each found franchise no classic covers. Classics first,
     * in number order.
     */
    fun foldTargets(definitions: List<FranchiseDefinition>, stockChannels: List<Stock>, found: List<Found>, itemKey: (MediaItem) -> String): List<Target> {
        val targets = ArrayList<Target>()
        for (ch in stockChannels.sortedBy { it.number }) {
            val def = definitions.firstOrNull { it.stockChannelID == ch.id }
            targets += Target("CH ${ch.number} ${ch.name}", ch.itemPool.mapTo(HashSet(), itemKey), def?.canonicalName, ch.id)
        }
        for (f in found) {
            if (f.isCovered) continue
            targets += Target(f.name, f.items.mapTo(HashSet(), itemKey), if (f.fromDictionary) f.name else null, null)
        }
        return targets
    }

    /**
     * A folded collection is hidden and never built, so folding is only safe when the
     * franchise already airs everything in it: a collection that holds shows folds only into
     * a franchise with at least one episode of each of them.
     */
    fun carriesEveryShow(collection: Collections.Candidate, target: Target, itemKey: (MediaItem) -> String): Boolean {
        val covered = LinkedHashMap<String, Boolean>()
        for (it in collection.items) {
            if (it.type != "episode") continue
            val show = Collections.showIdentity(it)
            if (covered[show] == true) continue
            covered[show] = itemKey(it) in target.itemKeys
        }
        return covered.values.all { it }
    }

    private fun pickTarget(
        collection: Collections.Candidate, targets: List<Target>, definitions: List<FranchiseDefinition>,
        enrichmentFor: (MediaItem) -> Enrichment?, itemKey: (MediaItem) -> String, threshold: Int,
    ): Target? {
        val stockByID = LinkedHashMap<Int, Target>()
        for (t in targets) t.stockChannelID?.let { stockByID[it] = t }

        // 1. Dictionary truth from enrichment: 2+ members share a franchiseID the dictionary maps to a classic here.
        FranchiseBuilder.stockChannelForCollectionItems(collection.items, definitions, stockByID.keys, enrichmentFor)
            ?.let { sid -> stockByID[sid]?.let { return it } }

        // 2. Dictionary by title, into the classic or else the found franchise the same entry made.
        FranchiseBuilder.dictionaryMatchForFilmTitle(collection.title, definitions)?.let { def ->
            def.stockChannelID?.let { sid -> stockByID[sid]?.let { return it } }
            targets.firstOrNull { it.dictionaryName == def.canonicalName }?.let { return it }
        }

        // 3. The scan's own duplicate signals, when they point at a stock franchise channel.
        collection.matchedChannel?.let { m -> targets.firstOrNull { it.stockChannelID != null && it.label == m }?.let { return it } }
        collection.contentOverlap?.let { o -> stockByID[o.channelID]?.let { return it } }

        // 4. Plain item overlap: most of this collection is already in one franchise's pool.
        val total = collection.items.size
        if (total == 0) return null
        val keys = collection.items.mapTo(LinkedHashSet(), itemKey)
        var best: Target? = null
        var bestCount = 0
        for (t in targets) {
            val count = keys.count { it in t.itemKeys }
            if (count > bestCount) {
                best = t
                bestCount = count
            }
        }
        // Math.round of the JS: halves round up.
        return best?.takeIf { Math.floor(bestCount.toDouble() / total * 100 + 0.5).toInt() >= threshold }
    }

    /** FranchiseCollectionFold.folds, one collection at a time: the franchise label a candidate folds into, or null. */
    fun foldFor(
        targets: List<Target>, definitions: List<FranchiseDefinition>, enrichmentFor: (MediaItem) -> Enrichment?,
        itemKey: (MediaItem) -> String, threshold: Int = 60,
    ): (Collections.Candidate) -> String? = { candidate ->
        if (targets.isEmpty()) null
        else pickTarget(candidate, targets, definitions, enrichmentFor, itemKey, threshold)
            ?.takeIf { carriesEveryShow(candidate, it, itemKey) }?.label
    }

    // ── The guide ────────────────────────────────────────────────────────

    /**
     * Whether a channel is in the guide, as far as the FRANCHISES package decides it
     * (applyBundleFilter). A classic switched off in the franchise list leaves on its own;
     * runtime franchise channels all go with the package; anything else isn't its to decide.
     */
    fun stockVisible(channelID: Int, packageOn: Boolean, bundleChannelIDs: List<Int>, switchedOffStock: Set<Int>) =
        channelID !in bundleChannelIDs || (packageOn && channelID !in switchedOffStock)

    fun runtimeVisible(channel: Collections.CollectionChannel, packageOn: Boolean) =
        channel.category != CollectionCategory.FRANCHISES || packageOn

    // ── Everything together ──────────────────────────────────────────────

    /**
     * What the FRANCHISES package and the server collections add to a lineup. `items` are the
     * library's channel-eligible items, enrichment attached; `stockChannels` the classics in the
     * lineup with their rule-built pools; `bundleChannelIDs` the package's ids (100-106). The
     * caller appends `stockAdditions` to the classics' pools.
     */
    fun build(
        definitions: List<FranchiseDefinition>,
        packageOn: Boolean,
        enabledIDs: Set<String>,
        disabledIDs: Set<String>,
        items: List<MediaItem>,
        stockChannels: List<Stock>,
        bundleChannelIDs: List<Int>,
        manifest: JsonObject?,
        exclusiveRules: List<ChannelFilter.ExclusiveRule>,
        collections: CollectionInput?,
        itemKey: (MediaItem) -> String = { it.ratingKey },
        enrichmentFor: (MediaItem) -> Enrichment? = { it.enrichment },
    ): Result {
        // Music videos live in a movie-typed library and are never franchise films.
        val movies = items.filter { it.type == "movie" && it.librarySource.ifEmpty { "movie" } == "movie" }
        val tvItems = items.filter { it.type == "episode" }
        val groupings = FranchiseBuilder.build(
            movies, tvItems, definitions, stockChannels.filter { it.id in bundleChannelIDs }.map { it.id }, enrichmentFor = enrichmentFor,
        )
        val found = foundFromGroupings(groupings, enabledIDs, disabledIDs, definitions)

        // The union is only made while the package is on. The fold then reads the pools as they air.
        val stockAdditions = if (packageOn) stockPoolAdditions(found, stockChannels, itemKey, manifest, exclusiveRules) else emptyMap()
        val unioned = stockChannels.map { c -> stockAdditions[c.id]?.let { c.copy(itemPool = c.itemPool + it) } ?: c }
        val franchiseStock = unioned.filter { it.id in bundleChannelIDs }

        val rows = listRows(definitions, bundleChannelIDs, unioned, found, enabledIDs, disabledIDs, itemKey)
        val switchedOffStock = switchedOffStockChannelIDs(definitions, enabledIDs, disabledIDs)

        val candidates = collections?.let { col ->
            val targets = foldTargets(definitions, franchiseStock, found, itemKey)
            Collections.buildCandidates(
                col.raw, col.indexByServer,
                Collections.Context(
                    staticChannels = col.staticChannels,
                    itemKey = itemKey,
                    enabledKeys = col.enabledKeys,
                    manifest = manifest,
                    classify = true,
                    enrichmentFor = enrichmentFor,
                    fold = foldFor(targets, definitions, enrichmentFor, itemKey),
                ),
            )
        } ?: emptyList()

        val dynamicFound = if (packageOn) found.filter { !it.isCovered && it.enabled } else emptyList()
        val materialized = Collections.materialize(candidates, dynamicFound.map { Collections.FoundFranchiseEntry(it.id, it.name, it.movies, it.tvItems) })
        return Result(
            found, stockAdditions, switchedOffStock, rows, candidates, materialized.channels,
            materialized.overCapFound, materialized.overCapFranchises, materialized.overCapCustom,
        )
    }
}
