package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.text.BreakIterator
import java.text.Normalizer
import java.util.Locale

/**
 * One entry of franchises.json, with the Swift decoder's defaults filled in: lists empty,
 * flags false, stockChannelID null. Mirrors the web tuner's `normalizeDefinitions` output.
 */
class FranchiseDefinition(
    val canonicalName: String,
    val stockChannelID: Int? = null,
    val tmdbCollectionIDs: List<Long> = emptyList(),
    val nameMatchTokens: List<String> = emptyList(),
    val tvShowTitles: List<String> = emptyList(),
    val filmTitles: List<String> = emptyList(),
    val studioRuled: Boolean = false,
    val defaultOn: Boolean = false,
) {
    /** Mirrors `definitionStableID`, and FranchiseGrouping.stableID on the Apple TV. */
    val stableID: String get() = "dict:$canonicalName"

    // The explicit lists as keys, worked out once per definition, as the JS `explicitKeys`
    // cache does: every episode of a show asks the same question. Only skips repeats.
    internal val filmTitleKeys: Set<String> by lazy { filmTitles.mapTo(HashSet(), FranchiseBuilder::explicitTitleKey) }
    internal val tvShowTitleKeys: Set<String> by lazy { tvShowTitles.mapTo(HashSet(), FranchiseBuilder::explicitTitleKey) }
}

/** Where a franchise channel airs: folded into a stock channel, or a channel of its own. */
sealed class FranchisePlacement {
    data class Stock(val channelID: Int) : FranchisePlacement()
    object Dynamic : FranchisePlacement() {
        override fun toString() = "Dynamic"
    }
}

/**
 * One franchise channel. `movies` and `tvItems` are the caller's own items, in input order.
 * Mirrors the object the JS `grouping` returns and FranchiseGrouping on the Apple TV.
 */
data class FranchiseGrouping(
    val name: String,
    val stableID: String,
    val placement: FranchisePlacement,
    val movies: List<MediaItem>,
    val tvItems: List<MediaItem>,
    val mergedFranchiseIDs: List<Long>,
    val fromDictionary: Boolean,
)

/**
 * Franchise channel grouping, ported function for function from the web tuner's
 * scripts/nostalgex-franchise-builder.js, itself the port of the Apple TV's
 * FranchiseChannelBuilder.swift and FranchiseDictionary.swift. Every rule and the order
 * the rules run in is the JS's, checked against upstream's scripts/franchise-golden.json
 * (FranchiseGoldenTest) and the Roku port's text edge cases (FranchiseVectorTest). Change
 * grouping upstream, not here.
 *
 * Text handling matches the JS directly rather than approximating it, as the Roku port has
 * to: grapheme clusters come from java.text.BreakIterator (extended clusters on JDK 20+ and
 * on Android, whose BreakIterator is ICU), letters and numbers from
 * Character.isAlphabetic and the N categories, case from toLowerCase/toUpperCase with
 * Locale.ROOT (JS's locale-free mapping, final sigma and ß to SS included), and name order
 * from NFC via java.text.Normalizer.
 */
object FranchiseBuilder {
    const val DEFAULT_MINIMUM_FILMS = 3

    // MARK: - Unicode helpers

    /** Grapheme clusters, the stand-in for Swift's Character iteration. Mirrors `graphemes`. */
    internal fun graphemes(s: String): List<String> {
        if (s.isEmpty()) return emptyList()
        val it = BreakIterator.getCharacterInstance()
        it.setText(s)
        val out = ArrayList<String>()
        var start = it.first()
        var end = it.next()
        while (end != BreakIterator.DONE) {
            out.add(s.substring(start, end))
            start = end
            end = it.next()
        }
        return out
    }

    /**
     * `[\p{Alphabetic}\p{N}]` on the first code point, as the JS `isLetterOrNumber` tests a
     * grapheme. The JS's own stand-in for Swift's `Character.isLetter || isNumber`.
     */
    internal fun isLetterOrNumber(ch: String): Boolean {
        if (ch.isEmpty()) return false
        val cp = ch.codePointAt(0)
        if (Character.isAlphabetic(cp)) return true
        return when (Character.getType(cp)) {
            Character.DECIMAL_DIGIT_NUMBER.toInt(), Character.LETTER_NUMBER.toInt(), Character.OTHER_NUMBER.toInt() -> true
            else -> false
        }
    }

    /** Code-point order after NFC, Swift's String `<` for these names. Mirrors `compareStrings`. */
    internal fun compareStrings(a: String, b: String): Int {
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
        return if (restX == restY) 0 else if (!restX) -1 else 1
    }

    /** JS `toLowerCase()`: locale-free full case mapping, final sigma included. */
    private fun lower(s: String) = s.lowercase(Locale.ROOT)

    // MARK: - Title normalization (mirrors FranchiseChannelBuilder helpers)

    // `\z`, not `$`: Java's `$` also matches before a trailing line terminator, JS's does not.
    private val YEAR_SUFFIX = Regex(" \\(\\p{N}\\p{N}\\p{N}\\p{N}\\)\\z")

    /** Lowercased, with any trailing " (YYYY)" dropped. Mirrors `normalizedTitle`. */
    fun normalizedTitle(raw: String?): String {
        val s = lower(raw ?: "")
        val m = YEAR_SUFFIX.find(s) ?: return s
        return s.substring(0, s.length - m.value.length)
    }

    /**
     * Key for EXACT title lists. Mirrors `explicitTitleKey`: normalizedTitle, then every run
     * of punctuation and whitespace collapsed to one space; apostrophes (straight or curly)
     * never split a word. "What If...?" and "What If" are one key.
     */
    fun explicitTitleKey(raw: String?): String {
        val out = StringBuilder()
        var pendingSpace = false
        for (ch in graphemes(normalizedTitle(raw))) {
            if (isLetterOrNumber(ch)) {
                if (pendingSpace && out.isNotEmpty()) out.append(' ')
                pendingSpace = false
                out.append(ch)
            } else if (ch == "'" || ch == "’") {
                continue
            } else {
                pendingSpace = true
            }
        }
        return out.toString()
    }

    /**
     * Word-boundary containment, both inputs already lowercased. Mirrors
     * `titleContainsToken`: "star wars" matches "Star Wars Rebels", "men" does not match
     * "Mentalist". The neighbours are the last grapheme of the text before the hit and the
     * first of the text after it, each segmented on its own, as the JS slices them.
     */
    fun titleContainsToken(titleLower: String, tokenLower: String): Boolean {
        if (tokenLower.isEmpty()) return false
        var from = 0
        while (true) {
            val at = titleLower.indexOf(tokenLower, from)
            if (at < 0) return false
            val end = at + tokenLower.length
            val prev = if (at == 0) null else graphemes(titleLower.substring(0, at)).lastOrNull()
            val next = if (end >= titleLower.length) null else graphemes(titleLower.substring(end)).firstOrNull()
            val leftOK = prev == null || !isLetterOrNumber(prev)
            val rightOK = next == null || !isLetterOrNumber(next)
            if (leftOK && rightOK) return true
            from = at + 1
        }
    }

    private const val COLLECTION_SUFFIX = " collection"

    /** "John Wick Collection" -> "John Wick". Mirrors `FranchiseDictionary.cleanFranchiseName`. */
    fun cleanFranchiseName(raw: String?): String {
        var name = raw ?: ""
        // The JS tests the lowercased name but cuts the original by the suffix's length.
        if (lower(name).endsWith(COLLECTION_SUFFIX)) name = name.substring(0, (name.length - COLLECTION_SUFFIX.length).coerceAtLeast(0))
        return JsText.trim(name)
    }

    /**
     * "Spider-Man (MCU)" -> "Spider-Man". Drops trailing parenthetical suffixes, one or more,
     * never the whole name. Mirrors `FranchiseChannelBuilder.stripParentheticalSuffix`.
     */
    fun stripParentheticalSuffix(raw: String?): String {
        var s = JsText.trim(raw ?: "")
        while (s.endsWith(")")) {
            val open = s.lastIndexOf('(')
            if (open <= 0) break
            s = JsText.trim(s.substring(0, open))
        }
        return s
    }

    /**
     * Found franchises with the same merge key are one channel. Mirrors
     * `FranchiseChannelBuilder.franchiseMergeKey`: drop " Collection" and any trailing
     * parenthetical, compare by `explicitTitleKey`, and ignore a leading "The".
     */
    fun franchiseMergeKey(raw: String?): String {
        val key = explicitTitleKey(cleanFranchiseName(stripParentheticalSuffix(cleanFranchiseName(raw))))
        return if (key.startsWith("the ")) key.substring(4) else key
    }

    // MARK: - Dictionary

    /**
     * Mirrors the JS `intOrNull`: an integral JSON number, or a string of digits (after JS
     * trim). Anything else is null.
     */
    fun intOrNull(v: JsonElement?): Long? {
        if (v !is JsonPrimitive || v is JsonNull) return null
        if (v.isString) {
            val t = JsText.trim(v.content)
            if (!Regex("-?[0-9]+").matches(t)) return null
            return t.toDouble().toLong()
        }
        return intOrNull(v.content.toDoubleOrNull())
    }

    /** `Number.isInteger` on a typed number, as the enrichment record carries franchiseID. */
    fun intOrNull(d: Double?): Long? =
        if (d == null || d.isNaN() || d.isInfinite() || d != Math.floor(d)) null else d.toLong()

    private fun stringList(v: JsonElement?): List<String> =
        (v as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content } ?: emptyList()

    /**
     * Accepts the franchises.json document or its `franchises` array and fills the same
     * defaults as the Swift decoder. Mirrors `normalizeDefinitions`.
     */
    fun parseDefinitions(input: JsonElement?): List<FranchiseDefinition> {
        val list = when (input) {
            is JsonArray -> input
            is JsonObject -> input["franchises"] as? JsonArray ?: JsonArray(emptyList())
            else -> JsonArray(emptyList())
        }
        return list.mapNotNull { e ->
            val d = e as? JsonObject ?: return@mapNotNull null
            val name = (d["canonicalName"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return@mapNotNull null
            FranchiseDefinition(
                canonicalName = name,
                stockChannelID = intOrNull(d["stockChannelID"])?.toInt(),
                tmdbCollectionIDs = (d["tmdbCollectionIDs"] as? JsonArray)?.mapNotNull(::intOrNull) ?: emptyList(),
                nameMatchTokens = stringList(d["nameMatchTokens"]),
                tvShowTitles = stringList(d["tvShowTitles"]),
                filmTitles = stringList(d["filmTitles"]),
                studioRuled = d.isTrue("studioRuled"),
                defaultOn = d.isTrue("defaultOn"),
            )
        }
    }

    /** franchises.json as text, the asset or the repo file. */
    fun parseDefinitions(json: String): List<FranchiseDefinition> = parseDefinitions(Json.parseToJsonElement(json))

    // JS `=== true`: only a JSON boolean true, never the string "true".
    private fun JsonObject.isTrue(k: String): Boolean {
        val p = this[k] as? JsonPrimitive ?: return false
        return !p.isString && p.content == "true"
    }

    /** Stable ids of the franchises that start switched on. Mirrors `defaultOnIDs`. */
    fun defaultOnIDs(definitions: List<FranchiseDefinition>): Set<String> =
        definitions.filter { it.defaultOn }.mapTo(LinkedHashSet()) { it.stableID }

    /** Mirrors `FranchiseDictionary.isOn`: an explicit choice wins, else the default. */
    fun isOn(id: String, enabledIDs: Set<String>?, disabledIDs: Set<String>?, definitions: List<FranchiseDefinition>): Boolean {
        if (enabledIDs != null && id in enabledIDs) return true
        if (disabledIDs != null && id in disabledIDs) return false
        return id in defaultOnIDs(definitions)
    }

    private fun collectionMap(definitions: List<FranchiseDefinition>): Map<Long, FranchiseDefinition> {
        val map = HashMap<Long, FranchiseDefinition>()
        for (def in definitions) {
            if (def.studioRuled) continue
            for (id in def.tmdbCollectionIDs) map[id] = def
        }
        return map
    }

    /**
     * Shared matcher for films and TV. Mirrors the JS `dictionaryMatchTitle` and the private
     * Swift `dictionaryMatch`: an exact hit on the explicit list wins across every
     * definition before any token is tried. `includeStudioRuled` lets a studio-ruled
     * franchise answer the exact pass only (TV); its tokens are never tried.
     */
    private fun dictionaryMatchTitle(title: String, tv: Boolean, definitions: List<FranchiseDefinition>, includeStudioRuled: Boolean): FranchiseDefinition? {
        val key = explicitTitleKey(title)
        for (def in definitions) {
            if (!includeStudioRuled && def.studioRuled) continue
            if (key in (if (tv) def.tvShowTitleKeys else def.filmTitleKeys)) return def
        }
        val titleLower = normalizedTitle(title)
        for (def in definitions) {
            if (def.studioRuled) continue
            if (def.nameMatchTokens.any { titleContainsToken(titleLower, it) }) return def
        }
        return null
    }

    /** The dictionary franchise a film title belongs to, or null. Mirrors `dictionaryMatch(forFilmTitle:)`. */
    fun dictionaryMatchForFilmTitle(title: String, definitions: List<FranchiseDefinition>): FranchiseDefinition? =
        dictionaryMatchTitle(title, tv = false, definitions = definitions, includeStudioRuled = false)

    // MARK: - Enrichment

    private class Read(val fid: Long?, val name: String?)

    private fun readEnrichment(enrichmentFor: (MediaItem) -> Enrichment?, item: MediaItem): Read {
        val e = enrichmentFor(item) ?: return Read(null, null)
        return Read(intOrNull(e.franchiseID), e.franchiseName)
    }

    // MARK: - Build (mirrors FranchiseChannelBuilder.build)

    private class Bucket(var name: String, val definition: FranchiseDefinition?) {
        val movies = ArrayList<MediaItem>()
        val tvItems = ArrayList<MediaItem>()
        val franchiseIDs = LinkedHashSet<Long>()
    }

    /** A TV title's answer: a dictionary franchise, or a found bucket. */
    private class Place(val def: FranchiseDefinition?, val found: Bucket?)

    /**
     * The franchise channels a library makes. Mirrors the JS `build`. `tvItems` are shows
     * or episodes whose `title` is the show's; `availableStockChannelIDs` are the stock
     * channels in the lineup; `enrichmentFor` defaults to `item.enrichment`.
     */
    fun build(
        movies: List<MediaItem>,
        tvItems: List<MediaItem>,
        definitions: List<FranchiseDefinition>,
        availableStockChannelIDs: Collection<Int>,
        minimumFilms: Int = DEFAULT_MINIMUM_FILMS,
        enrichmentFor: (MediaItem) -> Enrichment? = { it.enrichment },
    ): List<FranchiseGrouping> {
        val available = availableStockChannelIDs.toHashSet()
        val byCollectionID = collectionMap(definitions)
        val buckets = LinkedHashMap<String, Bucket>()
        fun keyForDefinition(def: FranchiseDefinition) = "dict:" + def.canonicalName
        fun bucketFor(key: String, name: String, def: FranchiseDefinition?): Bucket =
            buckets.getOrPut(key) { Bucket(name, def) }

        // 1. Movies, placed once each: dictionary by collection id, dictionary by title
        //    (explicit beats token), auto-found by collection id, otherwise skipped.
        //    Auto-found films are held back until every collection has a name, then go
        //    into one bucket per merge key (see franchiseMergeKey), in input order.
        val autoFoundNames = HashMap<Long, String>()
        val autoFoundFilms = ArrayList<Pair<MediaItem, Long>>()
        for (movie in movies) {
            val r = readEnrichment(enrichmentFor, movie)
            val fid = r.fid

            val collectionDef = if (fid != null) byCollectionID[fid] else null
            if (fid != null && collectionDef != null) {
                val b = bucketFor(keyForDefinition(collectionDef), collectionDef.canonicalName, collectionDef)
                b.movies.add(movie)
                b.franchiseIDs.add(fid)
                continue
            }

            val titleDef = dictionaryMatchTitle(movie.title, tv = false, definitions = definitions, includeStudioRuled = false)
            if (titleDef != null) {
                bucketFor(keyForDefinition(titleDef), titleDef.canonicalName, titleDef).movies.add(movie)
                continue
            }

            if (fid != null) {
                if (fid !in autoFoundNames && r.name != null) {
                    autoFoundNames[fid] = cleanFranchiseName(r.name).uppercase(Locale.ROOT)
                }
                autoFoundFilms.add(movie to fid)
            }
        }
        // A collection whose films never carried a franchiseName (or whose name cleans to
        // nothing, falsy in the JS) cannot be named, so it is dropped. Named ones whose
        // names match after franchiseMergeKey share one bucket.
        fun foundKeyFor(fid: Long): String? {
            val name = autoFoundNames[fid]
            if (name.isNullOrEmpty()) return null
            val mk = franchiseMergeKey(name)
            return if (mk.isNotEmpty()) "found:$mk" else "found:#$fid"
        }
        for ((movie, fid) in autoFoundFilms) {
            val key = foundKeyFor(fid) ?: continue
            val b = bucketFor(key, "", null)
            b.movies.add(movie)
            b.franchiseIDs.add(fid)
        }
        // Named after the lowest collection id; a merged bucket drops its "(MCU)" suffix.
        for (b in buckets.values) {
            if (b.definition != null) continue
            val name = autoFoundNames[b.franchiseIDs.min()]!!
            b.name = if (b.franchiseIDs.size > 1) stripParentheticalSuffix(name) else name
        }

        // Found buckets in ascending collection id, the fixed order TV tries them in.
        val foundKeys = buckets.entries
            .filter { it.value.definition == null }
            .map { it.key to it.value.franchiseIDs.min() }
            .sortedBy { it.second }
            .map { it.first }

        // 2. TV: dictionary (explicit titles, studio-ruled included, then tokens), else a
        //    found franchise whose name the show title contains. The answer depends on the
        //    title alone, so an episode takes the answer its show's first episode got.
        val placeTV = HashMap<String, Place?>()
        fun placeFor(title: String): Place? {
            val def = dictionaryMatchTitle(title, tv = true, definitions = definitions, includeStudioRuled = true)
            if (def != null) return Place(def, null)
            val titleLower = normalizedTitle(title)
            for (key in foundKeys) {
                val b = buckets[key]
                if (b != null && titleContainsToken(titleLower, lower(b.name))) return Place(null, b)
            }
            return null
        }
        for (tv in tvItems) {
            val place = if (placeTV.containsKey(tv.title)) placeTV[tv.title] else placeFor(tv.title).also { placeTV[tv.title] = it }
            if (place == null) continue
            if (place.def != null) bucketFor(keyForDefinition(place.def), place.def.canonicalName, place.def).tvItems.add(tv)
            else place.found!!.tvItems.add(tv)
        }

        // 3. Resolve: stock fold (needs one item, not gated on films) or dynamic (gated).
        val groupings = ArrayList<FranchiseGrouping>()
        for (b in buckets.values) {
            val merged = b.franchiseIDs.sorted()
            val fromDictionary = b.definition != null
            val def = b.definition
            val stockID = def?.stockChannelID
            if (stockID != null && stockID in available) {
                if (b.movies.size + b.tvItems.size < 1) continue
                groupings.add(grouping(def.canonicalName, FranchisePlacement.Stock(stockID), b, merged, fromDictionary))
            } else {
                if (b.movies.size < minimumFilms) continue
                groupings.add(grouping(b.name, FranchisePlacement.Dynamic, b, merged, fromDictionary))
            }
        }

        // Stock folds by channel, then dynamic by name, then stableID. Stable, as JS sort is.
        return groupings.sortedWith(Comparator { a, b ->
            val ap = a.placement
            val bp = b.placement
            when {
                ap is FranchisePlacement.Stock && bp is FranchisePlacement.Stock -> ap.channelID.compareTo(bp.channelID)
                ap is FranchisePlacement.Stock -> -1
                bp is FranchisePlacement.Stock -> 1
                else -> compareStrings(a.name, b.name).takeIf { it != 0 } ?: compareStrings(a.stableID, b.stableID)
            }
        })
    }

    private fun grouping(name: String, placement: FranchisePlacement, bucket: Bucket, merged: List<Long>, fromDictionary: Boolean) =
        FranchiseGrouping(
            name = name,
            // Mirrors FranchiseGrouping.stableID.
            stableID = if (fromDictionary) "dict:$name" else "tmdb:${merged.firstOrNull() ?: 0}",
            placement = placement,
            movies = bucket.movies.toList(),
            tvItems = bucket.tvItems.toList(),
            mergedFranchiseIDs = merged,
            fromDictionary = fromDictionary,
        )

    /**
     * The stock channel a server collection maps to: the lowest stock channel id that 2+
     * members reach through a dictionary collection id, or null. Mirrors
     * `FranchiseChannelBuilder.stockChannel(forCollectionItems:)`.
     */
    fun stockChannelForCollectionItems(
        items: List<MediaItem>,
        definitions: List<FranchiseDefinition>,
        availableStockChannelIDs: Collection<Int>,
        enrichmentFor: (MediaItem) -> Enrichment? = { it.enrichment },
    ): Int? {
        val available = availableStockChannelIDs.toHashSet()
        val byCollectionID = collectionMap(definitions)
        val hits = LinkedHashMap<Int, Int>()
        for (item in items) {
            val fid = readEnrichment(enrichmentFor, item).fid ?: continue
            val stock = byCollectionID[fid]?.stockChannelID ?: continue
            if (stock !in available) continue
            hits[stock] = (hits[stock] ?: 0) + 1
        }
        return hits.filter { it.value >= 2 }.keys.minOrNull()
    }
}
