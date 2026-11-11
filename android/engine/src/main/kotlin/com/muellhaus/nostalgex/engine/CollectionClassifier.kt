package com.muellhaus.nostalgex.engine

import java.text.BreakIterator
import java.text.Normalizer
import java.util.Locale

/**
 * Which of the two categories a server collection belongs in, as Models/Channel.swift
 * `CollectionCategory`. [wire] is the web tuner's and the Roku port's string.
 */
enum class CollectionCategory(val wire: String) {
    /** FRANCHISES: movie series and sequels, CH 310-399 with the found franchises. */
    FRANCHISES("franchises"),
    /** OTHER COLLECTIONS: actors, directors and the viewer's own sets, CH 400-499. */
    CUSTOM("custom"),
}

/**
 * The Apple TV's Services/CollectionClassifier.swift. The Roku port is
 * roku/source/collections/CollectionClassifier.brs, and the web tuner carries the same
 * rules as `classify` in scripts/nostalgex-collections.js.
 *
 * Swift counts and compares Characters (grapheme clusters, canonically equivalent), so this
 * NFC-normalizes the titles it compares and counts with BreakIterator's character instance.
 */
object CollectionClassifier {

    /**
     * `CollectionClassifier.classify(title:items:enrichmentFor:)`.
     *
     * [enrichmentFor] defaults to the item's own [MediaItem.enrichment], as the web tuner's and
     * the Roku port's do; Swift's defaults to no lookup. Pass null for Swift's default, which
     * leaves the TMDB collection id out and the title rules alone decide.
     */
    fun classify(
        title: String?,
        items: List<MediaItem>,
        enrichmentFor: ((MediaItem) -> Enrichment?)? = { it.enrichment },
    ): CollectionCategory {
        // Shows. Every episode carries its show's title, so the repeated-word and
        // name-in-titles rules below would call any collection of shows a franchise. FRANCHISES
        // is movie series, so the films alone decide; a collection with no films is the
        // viewer's own set. Swift's filter is `type == .movie`, kept here.
        val films = items.filter { it.type == "movie" }
        if (films.size < items.size) {
            if (films.isEmpty()) return CollectionCategory.CUSTOM
            return classify(title, films, enrichmentFor)
        }

        val cleaned = trimWhitespaces(
            (title ?: "")
                .replace(" Collection", "", ignoreCase = true)
                .replace("Collection", "", ignoreCase = true)
                .replace("'s", "")
                .replace("’s", ""),
        )
        val lower = nfc(cleaned.lowercase(Locale.ROOT))

        // 0. Service-generated lists ("IMDb Popular"), before the franchise id so a popular
        //    list that holds two films of one series still lands in OTHER COLLECTIONS.
        if (isGeneratedListCollection(lower)) return CollectionCategory.CUSTOM
        // 0.5 Two or more films sharing a TMDB collection: the authoritative signal when the
        //     library is enriched; the title rules below are the fallback.
        if (enrichmentFor != null && sharesFranchiseID(items, enrichmentFor)) return CollectionCategory.FRANCHISES
        // 1. Known franchise names, for the ones whose titles do not repeat.
        if (KNOWN_FRANCHISES.any { lower.contains(it) }) return CollectionCategory.FRANCHISES
        // 2. Franchise keywords in the title.
        if (FRANCHISE_KEYWORDS.any { lower.contains(it) }) return CollectionCategory.FRANCHISES
        // 3. A word or a title prefix shared by 3 or more titles.
        if (items.size >= 3 && hasRepeatingNames(items)) return CollectionCategory.FRANCHISES
        // 4. The collection's own name in 2 or more of its titles ("John Wick" when a sequel
        //    is "Parabellum"). A person's name almost never appears in their films' titles twice.
        if (nameAppearsInTitles(lower, items)) return CollectionCategory.FRANCHISES
        // 5. Everything else, actor and director sets included.
        return CollectionCategory.CUSTOM
    }

    /** Source names (safe as substrings) of service-generated collections. */
    private val LIST_SOURCES = listOf(
        "anilist", "myanimelist", "mal ", "imdb", "tmdb", "themoviedb",
        "letterboxd", "trakt", "tvdb", "rotten tomatoes", "metacritic",
    )

    /** List and quality phrases, not bare words like "top", so "Top Gun" is not caught. */
    private val LIST_PHRASES = listOf(
        "popular", "trending", "top rated", "highest rated", "best rated",
        "most watched", "most popular", "recently added", "recently released",
        "newly added", "new releases", "favorited", "recommended", "watchlist",
        "top 250", "top 100", "top 50", "top 10",
    )

    /** Franchises that are hard to detect by name repetition. */
    private val KNOWN_FRANCHISES = listOf(
        // Superheroes (titles vary a lot: Batman Begins, The Dark Knight, The Batman)
        "batman", "superman", "spider-man", "spiderman",
        "wolverine", "x-men", "deadpool", "venom",
        "wonder woman", "aquaman", "the flash",
        "iron man", "captain america", "thor", "ant-man",
        "black panther", "hulk", "avengers",
        "guardians of the galaxy",
        "fantastic four", "blade",
        "hellboy", "spawn", "the crow",
        "teenage mutant ninja turtles", "tmnt",
        // Spy and action
        "james bond", "007",
        "jack ryan", "jack reacher",
        "the equalizer",
        // Horror
        "the conjuring", "conjuring", "annabelle",
        "final destination",
        "a nightmare on elm street", "elm street",
        "friday the 13th",
        "child's play", "chucky",
        "the exorcist", "the omen",
        "evil dead",
        // Comedy
        "national lampoon",
        "monty python",
        "ocean", // Ocean's Eleven, Twelve, Thirteen
        "naked gun",
        "scary movie",
        "hot shots",
        // Misc
        "planet of the apes",
        "the karate kid", "karate kid",
        "the chronicles of narnia", "narnia",
    )

    private val FRANCHISE_KEYWORDS = listOf("saga", "trilogy", "universe", "chronicles", "franchise", "cinematic")

    private val STOP_WORDS = setOf(
        "the", "a", "an", "of", "and", "in", "on", "to", "for", "is", "it",
        "at", "by", "or", "as", "no", "not", "but", "be", "was", "with", "from",
    )

    private fun isGeneratedListCollection(lower: String): Boolean =
        LIST_SOURCES.any { lower.contains(it) } || LIST_PHRASES.any { lower.contains(it) }

    /**
     * True when 2+ items share the same TMDB collection id. One film alone is not a series.
     * Swift's `franchiseID` is an Int; [Enrichment.franchiseID] is a Double, so only whole
     * numbers count, as the web tuner's `franchiseIDOf` does.
     */
    private fun sharesFranchiseID(items: List<MediaItem>, enrichmentFor: (MediaItem) -> Enrichment?): Boolean {
        val counts = HashMap<Long, Int>()
        for (item in items) {
            val v = enrichmentFor(item)?.franchiseID ?: continue
            if (v.isNaN() || v.isInfinite() || v != Math.floor(v)) continue
            val n = (counts[v.toLong()] ?: 0) + 1
            counts[v.toLong()] = n
            if (n >= 2) return true
        }
        return false
    }

    private fun nameAppearsInTitles(lowerName: String, items: List<MediaItem>): Boolean {
        if (graphemes(lowerName).size < 3) return false
        return items.count { nfc(it.title.lowercase(Locale.ROOT)).contains(lowerName) } >= 2
    }

    /**
     * hasRepeatingNames: a meaningful word (3+ Characters, not a stop word) in
     * max(3, 60% of the titles) titles, or a title prefix of 4+ Characters that many titles
     * start with ("High School Musical" and "High School Musical 2").
     */
    private fun hasRepeatingNames(items: List<MediaItem>): Boolean {
        val titles = items.map { nfc(it.title.lowercase(Locale.ROOT)) }
        val wordHits = LinkedHashMap<String, Int>()
        for (title in titles) {
            // Swift's split(separator: " ") drops the empty pieces.
            val unique = LinkedHashSet<String>()
            for (part in title.split(" ")) {
                if (part.isEmpty()) continue
                val word = trimPunctuation(part)
                if (graphemes(word).size >= 3 && word !in STOP_WORDS) unique.add(word)
            }
            for (word in unique) wordHits[word] = (wordHits[word] ?: 0) + 1
        }
        val threshold = maxOf(3, items.size * 6 / 10)
        if (wordHits.values.any { it >= threshold }) return true

        // longestCommonPrefix, Character by Character, then trimmed of whitespace and punctuation.
        val chars = titles.map(::graphemes)
        if (chars.isEmpty()) return false
        var prefix = chars[0]
        for (other in chars.drop(1)) {
            var i = 0
            while (i < prefix.size && i < other.size && prefix[i] == other[i]) i++
            prefix = prefix.subList(0, i)
        }
        val trimmed = trimWhitespacesAndPunctuation(prefix.joinToString(""))
        if (trimmed.isEmpty()) return false
        val trimmedChars = graphemes(trimmed)
        if (trimmedChars.size >= 4) {
            val matches = chars.count { it.size >= trimmedChars.size && it.subList(0, trimmedChars.size) == trimmedChars }
            if (matches >= threshold) return true
        }
        return false
    }

    // ── Text, as Swift reads it ──

    internal fun nfc(s: String): String = Normalizer.normalize(s, Normalizer.Form.NFC)

    /** A string's Characters (grapheme clusters), as Swift counts them. */
    internal fun graphemes(s: String): List<String> {
        if (s.isEmpty()) return emptyList()
        val it = BreakIterator.getCharacterInstance(Locale.ROOT)
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

    /** CharacterSet.whitespaces: tab and the Zs category, not line breaks. */
    private fun isWhitespace(cp: Int) = cp == '\t'.code || Character.getType(cp) == Character.SPACE_SEPARATOR.toInt()

    /** CharacterSet.punctuationCharacters: the Unicode P categories. */
    private fun isPunctuation(cp: Int): Boolean = when (Character.getType(cp).toByte()) {
        Character.CONNECTOR_PUNCTUATION, Character.DASH_PUNCTUATION, Character.START_PUNCTUATION,
        Character.END_PUNCTUATION, Character.INITIAL_QUOTE_PUNCTUATION, Character.FINAL_QUOTE_PUNCTUATION,
        Character.OTHER_PUNCTUATION,
        -> true
        else -> false
    }

    /** `trimmingCharacters(in:)`, over Unicode scalars as Foundation trims. */
    private fun trimScalars(s: String, drop: (Int) -> Boolean): String {
        var start = 0
        var end = s.length
        while (start < end) {
            val cp = s.codePointAt(start)
            if (!drop(cp)) break
            start += Character.charCount(cp)
        }
        while (end > start) {
            val cp = s.codePointBefore(end)
            if (!drop(cp)) break
            end -= Character.charCount(cp)
        }
        return s.substring(start, end)
    }

    private fun trimWhitespaces(s: String) = trimScalars(s, ::isWhitespace)
    private fun trimPunctuation(s: String) = trimScalars(s, ::isPunctuation)
    private fun trimWhitespacesAndPunctuation(s: String) = trimScalars(s) { isWhitespace(it) || isPunctuation(it) }
}
