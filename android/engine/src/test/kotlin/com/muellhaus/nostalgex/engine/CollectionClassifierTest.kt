package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * CollectionClassifier, case by case from the Apple TV's CollectionClassifierTests.swift and
 * the classification cases of CollectionShowsTests.swift, plus the extra rule cases the Roku
 * port added (roku/tests/CollectionTests.brs), then the `classifier` and `blocks` vectors of
 * scripts/franchise-lineup-golden.json, whose answers the Swift app wrote.
 */
class CollectionClassifierTest {
    private val custom = CollectionCategory.CUSTOM
    private val franchises = CollectionCategory.FRANCHISES

    private fun item(title: String) = MediaItem(ratingKey = title, title = title, type = "movie", duration = 90)

    private fun films(vararg titles: String) = titles.map(::item)

    /** `count` episodes of one show, keys "<showKey>-e<n>", each titled with the show. */
    private fun episodes(show: String, showKey: String, count: Int) = (1..count).map {
        MediaItem(ratingKey = "$showKey-e$it", title = show, type = "episode", duration = 22, showKey = showKey)
    }

    private fun enrichment(franchiseID: Int?) = Enrichment(mediaType = "movie", franchiseID = franchiseID?.toDouble())

    private fun classify(title: String, items: List<MediaItem>, look: ((MediaItem) -> Enrichment?)? = null) =
        CollectionClassifier.classify(title, items, look)

    // ── CollectionClassifierTests.swift ──

    /** testGeneratedListCollectionsAreCustom */
    @Test fun generatedListCollectionsAreCustom() {
        val names = listOf(
            "Anilist Popular", "IMDb Popular", "TMDb Popular", "Plex Popular",
            "MyAnimeList Favorited", "MyAnimeList Top Rated", "Anilist Top Rated",
            "Trakt Trending", "Letterboxd Top 250", "Recently Added",
        )
        for (name in names) assertEquals("$name should be Custom", custom, classify(name, emptyList()))
    }

    /** testPersonNamesAreCustom: NOTABLE STARS is gone, a person is OTHER COLLECTIONS. */
    @Test fun personNamesAreCustom() {
        assertEquals(custom, classify("Tom Hanks", emptyList()))
        assertEquals(custom, classify("Christopher Nolan", emptyList()))
    }

    /** testFranchisesStillDetected */
    @Test fun franchisesStillDetected() {
        assertEquals(franchises, classify("James Bond Collection", emptyList()))
        assertEquals(franchises, classify("Top Gun Collection", films("Top Gun", "Top Gun: Maverick", "Top Gun II")))
    }

    /** testFranchiseNamedLikeAPersonIsAFranchise: the third John Wick film is just "Parabellum". */
    @Test fun franchiseNamedLikeAPersonIsAFranchise() {
        assertEquals(franchises, classify("John Wick", films("John Wick", "John Wick: Chapter 2", "Parabellum")))
        assertEquals(
            franchises,
            classify("Hunger Games", films("The Hunger Games", "Catching Fire", "The Hunger Games: Mockingjay - Part 1")),
        )
    }

    /** testPersonCollectionsAreNotFranchises: a name once in a title is not enough. */
    @Test fun personCollectionsAreNotFranchises() {
        assertEquals(custom, classify("Tom Hanks", films("Big", "Cast Away", "Forrest Gump")))
        assertEquals(
            custom,
            classify("Michael Jackson Collection", films("Michael Jackson's This Is It", "Thriller", "Moonwalker")),
        )
    }

    /** testSharedFranchiseIDForcesFranchise */
    @Test fun sharedFranchiseIDForcesFranchise() {
        val night = films("Alpha", "Bravo", "Charlie")
        val fids = mapOf("Alpha" to 777, "Bravo" to 777, "Charlie" to 777)
        val look = { it: MediaItem -> enrichment(fids[it.ratingKey]) }
        assertEquals(franchises, classify("Movie Night", night, look))
        // Without the lookup (Swift's default), the title rules run and it stays Custom.
        assertEquals(custom, classify("Movie Night", night))
    }

    /** testGeneratedListBeatsFranchiseID */
    @Test fun generatedListBeatsFranchiseID() {
        val fids = mapOf("Batman Begins" to 263, "The Dark Knight" to 263)
        val look = { it: MediaItem -> enrichment(fids[it.ratingKey]) }
        assertEquals(custom, classify("IMDb Popular", films("Batman Begins", "The Dark Knight"), look))
    }

    /** testSingleFranchiseIDItemIsNotEnoughForFranchise */
    @Test fun singleFranchiseIDItemIsNotEnoughForFranchise() {
        val fids = mapOf("Solo Outing" to 500)
        val look = { it: MediaItem -> enrichment(fids[it.ratingKey]) }
        assertEquals(custom, classify("Random Set", films("Solo Outing", "Different Movie"), look))
    }

    // ── CollectionShowsTests.swift, classification ──

    /** testShowCollectionsAreNeverFranchises: 30 episodes of one show are not "30 titles sharing a word". */
    @Test fun showCollectionsAreNeverFranchises() {
        assertEquals(custom, classify("Reality TV", episodes("Survivor", "s1", 30)))
        val trek = episodes("Star Trek: The Next Generation", "s2", 8) + episodes("Star Trek: Voyager", "s3", 8)
        assertEquals(custom, classify("Star Trek Saga", trek))
    }

    /** testMixedCollectionClassifiesOnItsFilms */
    @Test fun mixedCollectionClassifiesOnItsFilms() {
        val wick = films("John Wick", "John Wick: Chapter 2", "Parabellum")
        assertEquals(franchises, classify("John Wick", wick + episodes("The Continental", "s1", 3)))
        val hanks = films("Big", "Cast Away")
        assertEquals(custom, classify("Tom Hanks", hanks + episodes("Band of Brothers", "s2", 10)))
    }

    // ── The Roku port's extra cases, one per rule ──

    @Test fun theRestOfTheRulesOneCaseEach() {
        assertEquals("a franchise keyword", franchises, classify("The Godfather Trilogy", films("The Godfather", "Part II", "Part III")))
        assertEquals("a shared title prefix", franchises, classify("Go", films("Go Go", "Go Gone", "Go Goal")))
        assertEquals("punctuation trimmed from words", franchises, classify("Set", films("Rocky", "Rocky II", "Rocky...", "Creed")))
        assertEquals("a curly 's is dropped", franchises, classify("Rocky’s Story", films("Rocky Story", "Rocky Story II", "Other")))
        // "'s" is dropped before the known list is read, so this misses "child's play".
        assertEquals("Child's Play Collection", custom, classify("Child's Play Collection", emptyList()))
        assertEquals("stop words don't count", custom, classify("Mixed", films("The One", "The Two", "The Three")))
    }

    /** The default lookup reads the item's own enrichment, as the web tuner's and the Roku port's do. */
    @Test fun theDefaultLookupIsTheItemsOwnEnrichment() {
        val night = films("Alpha", "Bravo", "Charlie").map { it.copy(enrichment = enrichment(777)) }
        assertEquals(franchises, CollectionClassifier.classify("Movie Night", night))
        assertEquals(custom, CollectionClassifier.classify("Movie Night", night, null))
    }

    // ── scripts/franchise-lineup-golden.json ──

    private val golden by lazy {
        val root = File(System.getProperty("nostalgex.repoRoot") ?: "..")
        Json.parseToJsonElement(root.resolve("scripts/franchise-lineup-golden.json").readText()).jsonObject
    }

    /** A golden item. A string `franchiseID` that reads as a whole number counts, as the web tuner reads it. */
    private fun goldenItem(o: JsonObject): MediaItem {
        fun s(k: String) = (o[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
        val e = o["enrichment"] as? JsonObject
        val fid = (e?.get("franchiseID") as? JsonPrimitive)?.let { p ->
            if (p.isString) p.content.trim().takeIf { Regex("^-?\\d+$").matches(it) }?.toDouble() else p.doubleOrNull
        }
        return MediaItem(
            ratingKey = s("id")!!, title = s("title") ?: "", type = s("type") ?: "movie",
            episodeTitle = s("episodeTitle"), showKey = s("showKey"),
            enrichment = e?.let { Enrichment(franchiseID = fid, franchiseName = (it["franchiseName"] as? JsonPrimitive)?.content) },
        )
    }

    @Test fun classifierGoldenVectors() {
        val cases = golden["classifier"]!!.jsonArray.map { it.jsonObject }
        for (c in cases) {
            val items = c["items"]!!.jsonArray.map { goldenItem(it.jsonObject) }
            val got = CollectionClassifier.classify(c["title"]!!.jsonPrimitive.content, items)
            assertEquals(c["name"]!!.jsonPrimitive.content, c["expected"]!!.jsonPrimitive.content, got.wire)
        }
        assertEquals(65, cases.size)
    }

    @Test fun blockGoldenVectors() {
        for (c in golden["blocks"]!!.jsonArray.map { it.jsonObject }) {
            val entries = c["entries"]!!.jsonArray.map {
                val o = it.jsonObject
                val id = o["id"]!!.jsonPrimitive.content
                Collections.BlockEntry(o["name"]!!.jsonPrimitive.content, id, o["films"]!!.jsonPrimitive.content.toInt(), id)
            }
            val k = Collections.keptInDisplayOrder(entries, c["capacity"]!!.jsonPrimitive.content.toInt())
            val name = c["name"]!!.jsonPrimitive.content
            assertEquals(name, c["kept"]!!.jsonArray.map { it.jsonPrimitive.content }, k.kept.map { it.value })
            assertEquals("$name: skipped", c["skipped"]!!.jsonPrimitive.content.toInt(), k.skipped)
        }
    }
}
