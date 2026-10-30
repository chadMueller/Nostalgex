package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.time.LocalDate
import java.time.ZonedDateTime

/**
 * Which titles a channel airs: a port of scripts/nostalgex-channel-filter.cjs, which mirrors
 * the Apple TV's `filterItems` (AppState+Channels.swift) and reads channels.json.
 * scripts/filter-golden.json, read by the Apple TV and web too, holds this file to the same
 * answers (FilterGoldenTest).
 *
 * Rules stay the JSON objects channels.json writes, read with JavaScript's truthiness, so
 * this file can follow the JS line for line.
 *
 * Enrichment-gated rules behave as the Apple TV's do with no enrichment record: keywords,
 * networks and production companies don't match, keywordsExclude lets the item through, and
 * the OMDb gates reject it.
 */
object ChannelFilter {
    private val HORROR = setOf("horror")
    private val REALITY = setOf("reality", "game show", "game-show", "reality-tv")
    private val ANIMATION = setOf("animation", "animated", "cartoon")
    // "history" is deliberately not locked: Plex tags dramas as History and no channel includes it.
    private val DOCUMENTARY = setOf("documentary", "docuseries")
    private val WAR = setOf("war", "war & politics")
    private val WESTERN = setOf("western")
    private val TALKSHOW = setOf("talk show", "talk", "news")
    private val ADULT_RATINGS = setOf("R", "NC-17", "TV-MA", "18", "18+", "X", "NR")

    // Ratings from other countries, mapped to the US label of the same age band. Keep in sync
    // with ContentRating.swift and ChannelFilter.brs; all read scripts/rating-golden.json.
    private val RATING_BANDS = mapOf(
        "all" to listOf("G", "TV-G"),
        "pg" to listOf("PG", "TV-PG"),
        "teen" to listOf("PG-13", "TV-14"),
        "mature" to listOf("R", "TV-MA"),
        "adult" to listOf("NC-17", "TV-MA"),
    )
    private val US_RATINGS = setOf("G", "PG", "PG-13", "R", "NC-17", "NR", "TV-Y", "TV-Y7", "TV-Y7-FV", "TV-G", "TV-PG", "TV-14", "TV-MA")
    private val RATING_WORDS = mapOf(
        "GB" to mapOf("U" to "all", "UC" to "all", "PG" to "pg", "12A" to "teen", "12PG" to "teen", "R18" to "adult"),
        "IE" to mapOf("G" to "all", "PG" to "pg", "12A" to "teen", "12PG" to "teen", "15A" to "mature", "15PG" to "mature"),
        "AU" to mapOf("P" to "all", "C" to "all", "G" to "all", "PG" to "pg", "M" to "mature", "MA15+" to "mature", "AV15+" to "mature", "R18+" to "mature", "X18+" to "adult"),
        "NZ" to mapOf("G" to "all", "PG" to "pg", "R13" to "teen", "RP13" to "teen", "M" to "mature", "R15" to "mature", "R16" to "mature", "RP16" to "mature", "R18" to "mature", "RP18" to "mature", "R" to "adult"),
        "CA" to mapOf("C" to "all", "G" to "all", "C8" to "pg", "PG" to "pg", "14A" to "teen", "18A" to "mature", "R" to "adult", "A" to "adult"),
        "FR" to mapOf("U" to "all", "TP" to "all"),
        "NL" to mapOf("AL" to "all", "MG6" to "pg"),
    )
    private val RATING_BARE = mapOf(
        "U" to "all", "UC" to "all", "12A" to "teen", "12PG" to "teen", "14A" to "teen", "15A" to "mature", "18A" to "mature",
        "MA15+" to "mature", "R18+" to "mature", "R18" to "adult", "X18+" to "adult",
    )

    private val WS_RUN = Regex("[${JsText.WS}]+")
    private val AGE_LABEL = Regex("(\\d{1,2})\\+?")
    private val COUNTRY_LABEL = Regex("([A-Z]{2})[-/](${JsText.DOT}+)")
    private val DATE_PREFIX = Regex("^(\\d{4})-(\\d{2})-(\\d{2})")
    private val MONTH_DAY = Regex("(\\d{1,2})-(\\d{1,2})")

    data class ExclusiveRule(
        val channelIDs: List<Int>,
        val genres: List<String>,
        val titleContains: List<String>,
        val editorialTitles: List<String>,
        val manifestExclusive: Boolean,
        val type: String?,
        val source: String?,
    ) {
        internal val editorialTitlesLower = editorialTitles.map { it.lowercase() }
        internal val titleContainsLower = titleContains.map { it.lowercase() }
        internal val genresLower = genres.map { it.lowercase() }

        companion object {
            /** Same normalisation as plex-tuner.html loadStockChannelsFromJSON. */
            fun fromJson(r: JsonObject) = ExclusiveRule(
                channelIDs = r.ints("channelIDs") ?: r.int("channelID")?.let { listOf(it) } ?: emptyList(),
                genres = r.strings("genres") ?: emptyList(),
                titleContains = r.strings("titleContains") ?: emptyList(),
                editorialTitles = r.strings("editorialTitles") ?: emptyList(),
                manifestExclusive = truthy(r["manifestExclusive"]),
                type = r.string("type")?.ifEmpty { null },
                source = r.string("source")?.ifEmpty { null },
            )
        }
    }

    data class Channel(val id: Int, val rules: JsonObject?, val category: String?)

    data class Options(
        /** channels-memberships.json, or null. */
        val manifest: JsonObject? = null,
        val exclusiveRules: List<ExclusiveRule> = emptyList(),
        /** "plex", "jellyfin" or "emby". */
        val backend: String? = null,
        val now: ZonedDateTime = ZonedDateTime.now(),
    ) {
        private val itemFacts = java.util.IdentityHashMap<MediaItem, ItemFacts>()

        /** Content ratings mapped once per distinct label: a library has a handful, not one per item. */
        internal val ratings = java.util.concurrent.ConcurrentHashMap<String, String>()

        /**
         * Works out every item's facts up front, on every core, so channels can then be filtered
         * on several threads with nothing left to compute.
         */
        fun prepare(items: List<MediaItem>) {
            // IntStream rather than Stream.toList(), which Android only has from API 34.
            val computed = arrayOfNulls<ItemFacts>(items.size)
            java.util.stream.IntStream.range(0, items.size).parallel().forEach { computed[it] = ItemFacts(items[it], this) }
            synchronized(itemFacts) { items.forEachIndexed { i, item -> itemFacts.putIfAbsent(item, computed[i]!!) } }
        }

        internal fun facts(item: MediaItem): ItemFacts = itemFacts[item] ?: synchronized(itemFacts) {
            itemFacts.getOrPut(item) { ItemFacts(item, this) }
        }
    }

    // ── Ratings ──────────────────────────────────────────────────────────

    private fun ratingAgeBand(label: String): String? {
        val m = AGE_LABEL.matchEntire(label) ?: return null
        val age = m.groupValues[1].toInt()
        return when {
            age == 0 -> "all"
            age <= 10 -> "pg"
            age <= 14 -> "teen"
            else -> "mature"
        }
    }

    /** The US label the channel rules read for this rating, or `raw` when there is nothing to map. */
    fun usContentRating(raw: String?, type: String): String? {
        if (raw == null) return null
        val key = raw.uppercase().replace(WS_RUN, "")
        if (key.isEmpty() || key in US_RATINGS) return raw
        var country: String? = null
        var label = key
        if (key.startsWith("FSK")) {
            country = "DE"
            label = key.substring(3).removePrefix("-")
        } else {
            COUNTRY_LABEL.matchEntire(key)?.let { m ->
                // "TV-12A" is a bare 12A, not a country called TV.
                if (m.groupValues[1] != "TV") country = if (m.groupValues[1] == "UK") "GB" else m.groupValues[1]
                label = m.groupValues[2]
            }
        }
        var band = ratingAgeBand(label)
        if (band == null) {
            band = if (country != null) RATING_WORDS[country]?.get(label) ?: (if (label == "X") "adult" else null)
            else RATING_BARE[label]
        }
        if (band == null) return raw
        return RATING_BANDS.getValue(band)[if (type == "episode") 1 else 0]
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    fun titleContainsWord(haystack: String, needle: String) = JsText.containsWord(haystack, needle.lowercase())

    /** Lowercased, without a trailing " (YYYY)": the JS's `/ \(\d{4}\)$/`, without a regex per call. */
    private fun stripYearSuffix(s: String): String {
        val l = s.lowercase()
        val n = l.length
        if (n >= 7 && l[n - 1] == ')' && l[n - 6] == '(' && l[n - 7] == ' ' && (n - 5 until n - 1).all { l[it] in '0'..'9' }) {
            return l.substring(0, n - 7)
        }
        return l
    }

    /** Plex `year`, else the year of `originallyAvailableAt`. */
    fun releaseYear(item: MediaItem): Int? =
        item.year ?: item.originallyAvailableAt?.let { DATE_PREFIX.find(it)?.groupValues?.get(1)?.toInt() }

    private fun manifestEntry(item: MediaItem, manifest: JsonObject?): JsonObject? {
        val items = manifest?.obj("items") ?: return null
        val tmdb = item.tmdbID ?: return null
        if (tmdb == 0L) return null
        val mediaType = if (item.type == "episode") "tv" else "movie"
        return items["$mediaType:$tmdb"] as? JsonObject
    }

    fun exclusiveRuleApplies(item: MediaItem, rule: ExclusiveRule): Boolean {
        if (rule.type != null && item.type.ifEmpty { "movie" } != rule.type) return false
        if (rule.source != null && item.librarySource.ifEmpty { "movie" } != rule.source) return false
        return true
    }

    fun exclusiveRuleMatches(item: MediaItem, itemGenres: List<String>, rule: ExclusiveRule): Boolean {
        if (!exclusiveRuleApplies(item, rule)) return false
        val raw = item.title.lowercase()
        return exclusiveRuleMatches(raw, JsText.trim(stripYearSuffix(raw)), itemGenres, rule)
    }

    /** The same test with the item's lowercased title (`raw`) and that title stripped and trimmed already worked out. */
    private fun exclusiveRuleMatches(raw: String, title: String, itemGenres: List<String>, rule: ExclusiveRule): Boolean {
        if (rule.editorialTitlesLower.any { title == it || raw == it }) return true
        if (rule.titleContainsLower.any { JsText.containsWord(title, it) }) return true
        val g = rule.genresLower
        if (g.isNotEmpty() && itemGenres.any { ig -> g.any { ig.contains(it) } }) return true
        return false
    }

    /** Emby Dolby Vision profile 5: on no channel, whatever the rules say (ChannelEligibility.swift). */
    fun isLeftOffChannels(item: MediaItem, backend: String?) = backend == "emby" && item.doviProfile == 5

    private fun hasEpisodeRules(r: JsonObject) =
        listOf("episodeTitleContains", "episodeSummaryContains", "episodeSeasonalTitleContains")
            .any { (r[it] as? JsonArray)?.isNotEmpty() == true }

    private fun parseMonthDay(s: String?): Int? {
        val m = MONTH_DAY.matchEntire(JsText.trim(s ?: "")) ?: return null
        return m.groupValues[1].toInt() * 100 + m.groupValues[2].toInt()
    }

    private fun airMonthDay(item: MediaItem): Int? {
        val m = DATE_PREFIX.find(item.originallyAvailableAt ?: "") ?: return null
        return m.groupValues[2].toInt() * 100 + m.groupValues[3].toInt()
    }

    /** Inclusive, wrapping the new year when `from` is after `to`. */
    private fun inAirWindow(md: Int?, from: Int?, to: Int?): Boolean {
        if (from == null || to == null || md == null) return false
        return if (from <= to) md in from..to else md >= from || md <= to
    }

    /** `new Date(y, m - 1, d)` < (now with `setMonth(getMonth() - months)`), with JS's day overflow. */
    private fun releasedBefore(y: Int, m: Int, d: Int, months: Int, now: ZonedDateTime): Boolean {
        val released = LocalDate.of(y, 1, 1).plusMonths((m - 1).toLong()).plusDays((d - 1).toLong()).atStartOfDay()
        val shifted = now.toLocalDateTime().withDayOfMonth(1).minusMonths(months.toLong())
        val cutoff = shifted.plusDays((now.dayOfMonth - 1).toLong())
        return released < cutoff
    }

    // ── The filter ───────────────────────────────────────────────────────
    //
    // A library load asks every item about every channel (139 channels), so what depends on
    // the channel alone is read once per channel (ChannelFacts) and what depends on the item
    // alone once per item (ItemFacts, kept in Options). The decisions below run in the JS's
    // order and read the same values.

    /** A channel's rules, read and lowercased once. */
    internal class ChannelFacts(val channel: Channel) {
        val id = channel.id
        private val r = channel.rules ?: JsonObject(emptyMap())
        val isKids = channel.category == "kids"
        private val include = r.obj("genres")?.strings("include") ?: emptyList()
        val hasGenreInclude = include.isNotEmpty()
        val includeLower = include.map { it.lowercase() }
        val genreExclude = r.obj("genres")?.strings("exclude")?.map { it.lowercase() } ?: emptyList()
        val genreRequireAll = r.obj("genres")?.strings("requireAll")?.map { it.lowercase() } ?: emptyList()
        val matchTmdbGenres = truthy(r["matchTmdbGenres"])

        val titleContains = r.strings("titleContains")?.map { it.lowercase() }
        val hasTitleRule = !titleContains.isNullOrEmpty()
        val titleExcludes = r.strings("titleExcludes")?.map { it.lowercase() } ?: emptyList()
        val editorialOverrides = r.strings("editorialOverrides")?.map { it.lowercase() }

        val episodeTitleExcludes = r.strings("episodeTitleExcludes")?.map { it.lowercase() }
        val episodeTitleContains = r.strings("episodeTitleContains")?.map { it.lowercase() }
        val episodeSummaryContains = r.strings("episodeSummaryContains")?.map { it.lowercase() }
        val episodeSeasonalTitleContains = r.strings("episodeSeasonalTitleContains")?.map { it.lowercase() }
        val airFrom = parseMonthDay(r.obj("episodeAirWindow")?.jsString("from"))
        val airTo = parseMonthDay(r.obj("episodeAirWindow")?.jsString("to"))
        val isEpisodeCurated = hasEpisodeRules(r)

        val hasSource = truthy(r["source"])
        val source = r.string("source")
        val hasType = truthy(r["type"])
        val type = r.string("type")
        val manifestOnly = truthy(r["manifestOnly"])
        val manifestOnlyGenreFallback = truthy(r["manifestOnlyGenreFallback"])
        private val yearRange = r.obj("yearRange")?.takeIf { truthy(r["yearRange"]) }
        val yearMin = yearRange?.num("min")
        val yearMax = yearRange?.num("max")
        val contentRatings = r.strings("contentRatings")?.takeIf { it.isNotEmpty() }
        val allowUnrated = truthy(r["allowUnrated"])
        private val durationRange = r.obj("durationRange")
        val durMin = durationRange?.let { it.num("min") ?: it.num("minMinutes") }
        val durMax = durationRange?.let { it.num("max") ?: it.num("maxMinutes") }
        val watchedOnly = truthy(r["watchedOnly"])
        val unwatchedOnly = truthy(r["unwatchedOnly"])
        val rewatched = truthy(r["rewatched"])
        val keywordsExclude = r.strings("keywordsExclude")?.map { it.lowercase() }
        val imdbRatingMin = r.num("imdbRatingMin")
        val imdbVotesMin = r.num("imdbVotesMin")
        val rtScoreMin = r.num("rtScoreMin")
        val metacriticMin = r.num("metacriticMin")
        val wonOscar = truthy(r["wonOscar"])
        val addedWithinDays = r.num("addedWithinDays")?.takeIf { it > 0 }
        val releasedWithinMonths = r.num("releasedWithinMonths")?.takeIf { it > 0 }?.toInt()
        val ratingMin = r.num("ratingMin")

        val studios = r.strings("studios")?.map { it.lowercase() }
        val hasStudioRule = !studios.isNullOrEmpty()
        val prodCos = r.strings("productionCompanies")?.map { it.lowercase() }
        val hasProdCoRule = !prodCos.isNullOrEmpty()
        val keywords = r.strings("keywords")?.map { it.lowercase() }
        val hasKeywordRule = !keywords.isNullOrEmpty()
        val keywordsRequireAnyGenre = r.strings("keywordsRequireAnyGenre")?.map { it.lowercase() }
        val networks = r.strings("networks")?.map { it.lowercase() }
        val hasNetworkRule = !networks.isNullOrEmpty()
        val keywordGatedGenres = r.strings("keywordGatedGenres")?.map { it.lowercase() }

        private fun includes(set: Set<String>) = includeLower.any { it in set }
        val hasFamilyGenre = includeLower.any { it == "family" }
        private val isStudioChannel = hasStudioRule && !hasGenreInclude
        private val hasTitleCurated = hasTitleRule || isEpisodeCurated
        val allowsAnimation = isStudioChannel || includes(ANIMATION) || isKids || hasTitleCurated
        val allowsHorror = isStudioChannel || includes(HORROR)
        val allowsReality = isStudioChannel || includes(REALITY)
        val allowsDocumentary = isStudioChannel || includes(DOCUMENTARY)
        val allowsWar = isStudioChannel || includes(WAR)
        val allowsWestern = isStudioChannel || includes(WESTERN)
        val allowsTalkShow = isStudioChannel || includes(TALKSHOW)
        val isExplicitReality = includes(REALITY)
        val isTitleCuratedChannel = hasTitleRule && !hasKeywordRule && !hasNetworkRule && !hasProdCoRule && !hasStudioRule
        val hasAnyContentRule = hasTitleRule || hasStudioRule || hasGenreInclude || hasProdCoRule || hasKeywordRule || hasNetworkRule
    }

    /** What the rules read off an item, worked out once per item. */
    internal class ItemFacts(item: MediaItem, opts: Options) {
        // Artist first, then title, as AppState+Channels.swift `filterTitleHaystack`.
        val titleLower = stripYearSuffix(listOf(item.artist ?: "", item.title).filter { it.isNotEmpty() }.joinToString(" "))
        val plexGenres = item.genres.map { it.lowercase() }
        val genresWithTmdb = LinkedHashSet(plexGenres + (item.enrichment?.tmdbGenres?.map { it.lowercase() } ?: emptyList())).toList()
        val ownTitleLower = if (item.type == "episode") (item.episodeTitle ?: "").lowercase() else stripYearSuffix(item.title)
        val summaryLower = item.summary.lowercase()
        val airMonthDay = airMonthDay(item)
        val usRating = item.contentRating?.let { raw ->
            opts.ratings.getOrPut("${item.type}|$raw") { usContentRating(raw, item.type) ?: raw }
        }
        val source = item.librarySource.ifEmpty { "movie" }
        val manifestEntry = manifestEntry(item, opts.manifest)
        val claims: Set<Int> = manifestEntry?.ints("channels")?.toSet() ?: emptySet()
        val exclusive: Int? = manifestEntry?.get("exclusive")?.takeIf { it !is JsonNull }?.let { it.jsonPrimitive.intOrNull ?: Int.MIN_VALUE }
        val keywords = item.enrichment?.keywords?.map { it.lowercase() } ?: emptyList()
        val companies = item.enrichment?.productionCompanies?.map { it.lowercase() } ?: emptyList()
        val networks = item.enrichment?.networks?.map { it.lowercase() } ?: emptyList()
        val studioLower = item.studio?.lowercase() ?: ""
        val prodCoHaystack = if (!item.studio.isNullOrEmpty()) companies + studioLower else companies
        /** The exclusive rules that lock this item to their own channels. Server genres only, as Swift's ExclusiveRule.matches. */
        private val rawTitleLower = item.title.lowercase()
        private val exclusiveTitle = JsText.trim(stripYearSuffix(rawTitleLower))
        val exclusiveHits = opts.exclusiveRules.filter { rule ->
            exclusiveRuleApplies(item, rule) && (
                exclusiveRuleMatches(rawTitleLower, exclusiveTitle, plexGenres, rule) ||
                    (rule.manifestExclusive && opts.manifest != null && rule.channelIDs.any { it in claims })
                )
        }
    }

    private fun hasWord(list: List<String>?, hay: String) = list != null && hay.isNotEmpty() && list.any { JsText.containsWord(hay, it) }

    private fun episodeRulesMatch(item: MediaItem, f: ItemFacts, c: ChannelFacts): Boolean {
        val own = f.ownTitleLower
        if (hasWord(c.episodeTitleExcludes, own)) return false
        if (hasWord(c.episodeTitleContains, own)) return true
        if (!c.episodeSummaryContains.isNullOrEmpty() && hasWord(c.episodeSummaryContains, f.summaryLower)) return true
        if (item.type == "episode" && !c.episodeSeasonalTitleContains.isNullOrEmpty() && inAirWindow(f.airMonthDay, c.airFrom, c.airTo) &&
            hasWord(c.episodeSeasonalTitleContains, own)
        ) return true
        return false
    }

    private fun passesYearRange(item: MediaItem, c: ChannelFacts): Boolean {
        if (c.yearMin == null && c.yearMax == null) return true
        val year = releaseYear(item) ?: return true
        if (c.yearMin != null && year < c.yearMin) return false
        if (c.yearMax != null && year > c.yearMax) return false
        return true
    }

    /** Null when the channel doesn't take the item, otherwise how it got in. */
    fun itemPasses(item: MediaItem, channel: Channel, opts: Options = Options()): String? =
        itemPasses(item, ChannelFacts(channel), opts)

    private fun itemPasses(item: MediaItem, c: ChannelFacts, opts: Options): String? {
        if (isLeftOffChannels(item, opts.backend)) return null
        val f = opts.facts(item)
        val manifest = opts.manifest
        val titleLower = f.titleLower
        val itemGenres = if (c.matchTmdbGenres) f.genresWithTmdb else f.plexGenres

        val matchesEpisodeRules = c.isEpisodeCurated && episodeRulesMatch(item, f, c)
        val matchesTitleRule = c.titleContains.isNullOrEmpty() || c.titleContains.any { JsText.containsWord(titleLower, it) }

        if (c.hasSource) {
            if (f.source != c.source) return null
        } else if (f.source == "musicVideo") {
            return null
        }

        if ((c.isKids || c.hasFamilyGenre) && !item.contentRating.isNullOrEmpty() && f.usRating in ADULT_RATINGS) return null

        if (itemGenres.any { it in HORROR } && !c.allowsHorror) return null
        if (itemGenres.any { it in REALITY } && !c.allowsReality) return null
        if (itemGenres.any { it in ANIMATION } && !c.allowsAnimation) return null
        if (itemGenres.any { it in DOCUMENTARY } && !c.allowsDocumentary) return null
        // Sport and music are not locked: sports and music films air wherever their other genres fit.
        if (itemGenres.any { it in WAR } && !c.allowsWar) return null
        if (itemGenres.any { it in WESTERN } && !c.allowsWestern) return null
        if (itemGenres.any { it in TALKSHOW } && !c.allowsTalkShow) return null

        if (c.isExplicitReality && itemGenres.none { it in REALITY }) return null

        if (c.editorialOverrides != null && c.editorialOverrides.any { titleLower == it }) return "editorial"

        // Manifest-level exclusivity: an item locked to one channel airs nowhere else.
        if (f.exclusive != null && f.exclusive != c.id) return null

        if (manifest != null && c.id in f.claims) {
            if (c.hasType && item.type != c.type) return null
            if (!passesYearRange(item, c)) return null
            if (!c.titleContains.isNullOrEmpty() && !matchesTitleRule) return null
            if (c.isEpisodeCurated && !matchesEpisodeRules) return null
            if (c.titleExcludes.any { JsText.containsWord(titleLower, it) }) return null
            // genres.exclude outranks a manifest claim; includes stay bypassed on purpose.
            if (c.genreExclude.any { e -> itemGenres.any { it.contains(e) } }) return null
            return "manifest"
        }

        // manifestOnly: membership comes solely from the manifest, unless the channel opts in
        // to the content rules below as well (manifestOnlyGenreFallback: STAND-UP, ANIME).
        if (c.manifestOnly && !c.manifestOnlyGenreFallback) return null

        if (c.titleExcludes.any { JsText.containsWord(titleLower, it) }) return null

        // Channel exclusivity: an item another channel owns.
        if (f.exclusiveHits.any { c.id !in it.channelIDs }) return null

        if (c.hasType && item.type != c.type) return null

        if (!passesYearRange(item, c)) return null

        c.contentRatings?.let { allowed ->
            val rating = f.usRating ?: ""
            if (!(rating.isEmpty() && c.allowUnrated) && rating !in allowed) return null
        }

        if (c.durMin != null && item.duration < c.durMin) return null
        if (c.durMax != null && item.duration > c.durMax) return null

        val isNewRelease = (item.year ?: 0) >= opts.now.year - 1
        if (c.watchedOnly && item.viewCount < 1 && !isNewRelease) return null
        if (c.unwatchedOnly && (item.viewCount > 0 || isNewRelease)) return null
        if (c.rewatched && item.viewCount < 3) return null

        // Episode-curated channels: the episode rules are the allowlist.
        if (c.isEpisodeCurated && !matchesEpisodeRules) return null

        if (c.genreExclude.any { e -> itemGenres.any { it.contains(e) } }) return null

        // Soft exclude: unenriched items pass. Exact keyword equality, as Swift.
        if (!c.keywordsExclude.isNullOrEmpty() && f.keywords.isNotEmpty() && c.keywordsExclude.any { it in f.keywords }) return null

        // OMDb gates are HARD: a missing value rejects the item, as Swift's `guard let`.
        val e = item.enrichment
        if (c.imdbRatingMin != null && (e?.imdbRating == null || e.imdbRating < c.imdbRatingMin)) return null
        if (c.imdbVotesMin != null && (e?.imdbVotes == null || e.imdbVotes < c.imdbVotesMin)) return null
        if (c.rtScoreMin != null && (e?.rtScore == null || e.rtScore < c.rtScoreMin)) return null
        if (c.metacriticMin != null && (e?.metacriticScore == null || e.metacriticScore < c.metacriticMin)) return null
        if (c.wonOscar) {
            val a = e?.awards?.lowercase() ?: return null
            if (!(a.contains("won") && a.contains("oscar"))) return null
        }

        // An item with no addedAt (0) is rejected, as Swift's `item.addedAt < cutoff`.
        if (c.addedWithinDays != null && item.addedAt < opts.now.toEpochSecond() - c.addedWithinDays * 86_400) return null

        c.releasedWithinMonths?.let { months ->
            val m = item.originallyAvailableAt?.let { DATE_PREFIX.find(it) }
            if (m != null) {
                val (y, mo, d) = m.destructured
                if (releasedBefore(y.toInt(), mo.toInt(), d.toInt(), months, opts.now)) return null
            } else {
                item.year?.let { year -> if (year < opts.now.year - ((months + 11) / 12 - 1)) return null }
            }
        }

        // ratingMin: the star rating or the user's rating clears the bar, else the OMDb rating
        // at the same threshold. Emby sends no CommunityRating on most titles, which emptied
        // every plain ratingMin channel there.
        if (c.ratingMin != null && item.rating < c.ratingMin && item.userRating < c.ratingMin) {
            val omdb = e?.imdbRating
            if (omdb == null || omdb < c.ratingMin) return null
        }

        val matchesGenre = c.hasGenreInclude && itemGenres.any { g -> c.includeLower.any { g.contains(it) } }
        if (c.genreRequireAll.isNotEmpty() && !c.genreRequireAll.all { m -> itemGenres.any { it.contains(m) } }) return null

        // Plex studio first, then TMDB production companies and networks.
        val matchesStudio = c.studios != null && c.hasStudioRule && (
            (f.studioLower.isNotEmpty() && c.studios.any { f.studioLower.contains(it) }) ||
                f.companies.any { pc -> c.studios.any { pc.contains(it) } } ||
                f.networks.any { n -> c.studios.any { n.contains(it) } }
            )

        // Plex `studio` is the partial stand-in when no enrichment record exists.
        val matchesProdCo = c.prodCos != null && c.hasProdCoRule && f.prodCoHaystack.isNotEmpty() &&
            c.prodCos.any { co -> f.prodCoHaystack.any { it.contains(co) } }

        if (c.isEpisodeCurated) return "episode"

        if (c.isTitleCuratedChannel) return if (matchesTitleRule) "rules" else null

        // Keywords broaden membership, never gate it. Exact equality, as Swift.
        var matchesKeyword = false
        if (c.keywords != null && c.hasKeywordRule && f.keywords.isNotEmpty() && c.keywords.any { it in f.keywords }) {
            val gate = c.keywordsRequireAnyGenre
            matchesKeyword = gate.isNullOrEmpty() || gate.any { g -> itemGenres.any { it.contains(g) } }
        }

        val matchesNetwork = c.networks != null && c.hasNetworkRule && f.networks.isNotEmpty() &&
            c.networks.any { n -> f.networks.any { it.contains(n) } }

        if (c.hasAnyContentRule) {
            if (c.hasTitleRule && matchesTitleRule) return "title"
            if (matchesKeyword) return "keyword"
            if (matchesNetwork) return "network"
            if (matchesProdCo) return "prodco"
            if (c.hasStudioRule && c.hasGenreInclude) {
                if (!matchesStudio || !matchesGenre) return null
            } else if (c.hasStudioRule) {
                if (!matchesStudio) return null
            } else if (c.hasGenreInclude) {
                if (!matchesGenre) return null
                // Broad genres also need a keyword. Exact genre match, so "Music" doesn't gate "Musical".
                val gated = c.keywordGatedGenres
                if (!gated.isNullOrEmpty() && gated.any { g -> itemGenres.any { it.lowercase() == g } } && !matchesKeyword) return null
            } else {
                return null
            }
            return "rules"
        }
        return "rules"
    }

    /** The items a channel takes, in library order. */
    fun filterPool(items: List<MediaItem>, channel: Channel, opts: Options = Options()): List<MediaItem> {
        if (channel.rules == null) return items.filterNot { isLeftOffChannels(it, opts.backend) }
        val facts = ChannelFacts(channel)
        return items.filter { itemPasses(it, facts, opts) != null }
    }
    // ── JSON read the way JavaScript reads it ────────────────────────────

    /** JavaScript truthiness of a JSON value. */
    fun truthy(e: JsonElement?): Boolean = when (e) {
        null, JsonNull -> false
        is JsonPrimitive -> when {
            e.isString -> e.content.isNotEmpty()
            e.booleanOrNull != null -> e.booleanOrNull!!
            else -> e.doubleOrNull.let { it != null && it != 0.0 && !it.isNaN() }
        }
        else -> true
    }

    internal fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject

    /** A JSON number; null for a string, boolean or anything else (`typeof x === "number"`). */
    internal fun JsonObject.num(key: String): Double? =
        (this[key] as? JsonPrimitive)?.takeIf { !it.isString && it.booleanOrNull == null }?.doubleOrNull

    internal fun JsonObject.int(key: String): Int? = num(key)?.toInt()

    internal fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    /** `String(x ?? "")`. */
    internal fun JsonObject.jsString(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content

    internal fun JsonObject.strings(key: String): List<String>? =
        (this[key] as? JsonArray)?.map { (it as? JsonPrimitive)?.content ?: it.toString() }

    internal fun JsonObject.ints(key: String): List<Int>? =
        (this[key] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.intOrNull }
}

/** channels.json, read once: the channels, bundles and exclusive rules every surface shares. */
class ChannelConfig(root: JsonObject) {
    data class StockChannel(
        val id: Int,
        val number: Int,
        val name: String,
        val colorHex: String?,
        val category: String?,
        val minItems: Int,
        val rules: JsonObject?,
        val timeRestrictions: JsonObject?,
        val isPremiereChannel: Boolean,
    )

    data class Bundle(
        val id: String,
        val name: String,
        val channelIDs: List<Int>,
        val activeMonths: List<Int>?,
        val description: String = "",
        /** A season that starts early: `days` from `relativeTo` (only "usThanksgiving" is known). */
        val seasonStart: Pair<String, Int>? = null,
    ) {
        companion object {
            fun fromJson(b: JsonObject) = with(ChannelFilter) {
                Bundle(
                    b.string("id")!!, b.string("name") ?: "", b.ints("channelIDs") ?: emptyList(), b.ints("activeMonths"),
                    b.string("description") ?: "",
                    b.obj("seasonStart")?.let { (it.string("relativeTo") ?: "") to (it.int("days") ?: 0) },
                )
            }
        }
    }

    val version: Int?
    val channels: List<StockChannel>
    val bundles: List<Bundle>
    val exclusiveRules: List<ChannelFilter.ExclusiveRule>

    init {
        with(ChannelFilter) {
            version = root.int("version")
            channels = (root["channels"]?.jsonArray ?: JsonArray(emptyList())).map { e ->
                val c = e.jsonObject
                StockChannel(
                    id = c.int("id")!!,
                    number = c.int("number") ?: c.int("id")!!,
                    name = c.string("name") ?: "",
                    colorHex = c.string("colorHex"),
                    category = c.string("category"),
                    // `def.minItems || 50`
                    minItems = c.int("minItems")?.takeIf { it != 0 } ?: 50,
                    rules = c.obj("rules"),
                    timeRestrictions = c.obj("timeRestrictions"),
                    isPremiereChannel = truthy(c["isPremiereChannel"]),
                )
            }
            bundles = (root["bundles"]?.jsonArray ?: JsonArray(emptyList())).map { e ->
                val b = e.jsonObject
                Bundle.fromJson(b)
            }
            exclusiveRules = (root["exclusiveRules"]?.jsonArray ?: JsonArray(emptyList())).map { ChannelFilter.ExclusiveRule.fromJson(it.jsonObject) }
        }
    }

    /**
     * The pool a channel airs from at `hour` (local), as plex-tuner.html getTimeFilteredPool and
     * Channel.filteredPool() in Channel.swift: three branches, in this order, each keeping at
     * least two items.
     */
    fun timeFilteredPool(channel: StockChannel, pool: List<MediaItem>, hour: Int): List<MediaItem> {
        val tr = channel.timeRestrictions ?: return pool
        var out = pool
        with(ChannelFilter) {
            tr.obj("blockRatings")?.let { br ->
                val before = br.num("blockBefore")
                val after = br.num("blockAfter")
                val blocked = (before != null && hour < before) || (after != null && hour >= after)
                if (blocked) {
                    val ratings = br.strings("ratings") ?: emptyList()
                    val filtered = out.filter { usContentRating(it.contentRating, it.type) !in ratings }
                    if (filtered.size >= 2) out = filtered
                }
            }
            tr.num("tvOnlyBefore")?.let { h ->
                if (hour < h) {
                    val episodes = out.filter { it.type == "episode" }
                    if (episodes.size >= 2) out = episodes
                }
            }
            tr.num("onlyAfterHour")?.let { h -> if (hour < h) return emptyList() }
        }
        return out
    }
}
