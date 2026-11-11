package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What CollectionsVectorTest's vectors do not reach: the cases of
 * scripts/nostalgex-collections-smoke.mjs past them (the runtime channel's flags, paging past
 * 200, the index per server, members and representatives on their own, the scheduler over a
 * collection of episodes), the member-index cases of the Apple TV's CollectionShowsTests.swift,
 * and the franchise block of `materialize` with found franchises and FRANCHISES collections,
 * from the Apple TV's FranchiseNumberingTests as the Roku port transcribed them.
 */
class CollectionsTest {
    private val C = Collections

    private fun film(key: String, title: String = key, server: String = "srv") =
        MediaItem(ratingKey = key, title = title, type = "movie", duration = 100, serverID = server)

    private fun episodes(show: String, showKey: String, count: Int, stampShowKey: Boolean = true) = (1..count).map {
        MediaItem(
            ratingKey = "$showKey-e$it", title = show, type = "episode", duration = 22, serverID = "srv",
            showKey = if (stampShowKey) showKey else null, seTag = "S01E%02d".format(it),
        )
    }

    private fun index(items: List<MediaItem>) = C.indexLibrary(items) { it.serverID ?: "" }["srv"]

    // ── nostalgex-collections-smoke.mjs ──

    @Test fun materializedChannelsCarryNoRulesAndTheCollectionFlags() {
        val items = (1..4).map { film("$it") }
        val list = C.buildCandidates(
            listOf(ServerCollection("srv:c", "Alpha", listOf("1", "2", "3", "4"), "srv")),
            C.indexLibrary(items) { it.serverID!! },
            Collections.Context(enabledKeys = setOf("srv:c")),
        )
        val ch = C.materialize(list).channels.single()
        assertEquals(4, ch.itemPool.size)
        assertTrue(ch.collection)
        assertFalse(ch.stock)
        assertEquals(3, ch.minItems)
        assertTrue(ch.enabled)
        assertEquals(CollectionCategory.CUSTOM, ch.category)
    }

    @Test fun boxSetsPagePast200AndDedupe() {
        val calls = ArrayList<String>()
        val out = C.fetchBoxSetCollections("jellyfin", "u 1", { p ->
            calls.add(p)
            val doc = if (p.contains("IncludeItemTypes=BoxSet")) {
                """{"Items":[{"Id":"b1","Name":"Box"},{"Id":"b1","Name":"Box"}]}"""
            } else if (Regex("StartIndex=(\\d+)").find(p)!!.groupValues[1] == "0") {
                """{"Items":[${(0 until 200).joinToString(",") { "{\"Id\":\"m$it\"}" }}],"TotalRecordCount":201}"""
            } else {
                """{"Items":[{"Id":"m200"}],"TotalRecordCount":201}"""
            }
            Json.parseToJsonElement(doc)
        })
        assertEquals("/Items?userId=u%201&IncludeItemTypes=BoxSet&Recursive=true&Fields=ChildCount&SortBy=SortName", calls[0])
        assertEquals(
            "/Items?userId=u%201&ParentId=b1&Recursive=true&IncludeItemTypes=Movie,Series&StartIndex=0&Limit=200&SortBy=SortName",
            calls[1],
        )
        assertEquals(3, calls.size)
        assertEquals(1, out.size)
        assertEquals(201, out[0].childKeys.size)
        assertEquals("jellyfin:b1", out[0].id)
    }

    @Test fun indexIsOnePerServer() {
        val all = listOf(film("m1")) + episodes("Alpha Island", "s1", 2)
        assertEquals(listOf("srv"), C.indexLibrary(all) { it.serverID!! }.keys.toList())
        val two = listOf(film("1", server = "a"), film("1", server = "b"))
        assertEquals(listOf("a", "b"), C.indexLibrary(two) { it.serverID!! }.keys.toList())
    }

    @Test fun membersAndRepresentatives() {
        val films = listOf(film("m1", "Delta Run"), film("m2", "Echo Point"), film("m3", "Foxtrot Night"))
        val alpha = episodes("Alpha Island", "s1", 4)
        val bravo = episodes("Bravo Kitchen", "s2", 5)
        val charlie = episodes("Charlie Court", "s3", 3, stampShowKey = false)
        val idx = index(films + alpha + bravo + charlie)
        assertEquals((alpha + bravo).map { it.ratingKey }, C.resolveMembers(listOf("s1", "s2"), idx).map { it.ratingKey })
        assertEquals(3, C.resolveMembers(charlie.map { it.ratingKey }, idx).size)
        assertEquals(
            listOf("m1") + alpha.map { it.ratingKey },
            C.resolveMembers(listOf("m1", "m1", "s1", alpha[0].ratingKey, "zz"), idx).map { it.ratingKey },
        )
        assertEquals(listOf("m1", alpha[0].ratingKey), C.titleRepresentatives(films.take(1) + alpha).map { it.ratingKey })
    }

    @Test fun summaryWording() {
        assertEquals("12 movies", C.memberSummary(12, 0, 0))
        assertEquals("1 show · 1 episode", C.memberSummary(0, 1, 1))
        assertEquals("1 movie · 2 shows", C.memberSummary(1, 2, 9))
    }

    /** A collection channel of episodes through the shared scheduler: each once, shows spread out. */
    @Test fun aCollectionOfEpisodesSchedulesThroughInterleaveByShow() {
        val eps = listOf(Triple("Alpha Island", "s1", 8), Triple("Bravo Kitchen", "s2", 6), Triple("Charlie Court", "s3", 5))
            .flatMap { (show, key, n) -> episodes(show, key, n) }
        val order = DailyManifest.interleaveByShow(eps, C.ID_BASE.toLong(), 20375)
        assertEquals(19, order.map { it.ratingKey }.toSet().size)
        var run = 1
        var maxRun = 1
        for (i in 1 until order.size) {
            run = if (order[i].title == order[i - 1].title) run + 1 else 1
            maxRun = maxOf(maxRun, run)
        }
        assertTrue("at most two of a show in a row", maxRun <= 2)
        val alphaTags = order.filter { it.title == "Alpha Island" }.map { it.seTag }
        assertTrue("shuffled, not S/E order", alphaTags != alphaTags.sortedBy { it })
    }

    // ── CollectionShowsTests.swift, CollectionMemberIndex ──

    /** testShowKeysExpandToEveryEpisode */
    @Test fun showKeysExpandToEveryEpisode() {
        val alpha = episodes("Alpha Island", "s1", 4)
        val bravo = episodes("Bravo Kitchen", "s2", 5)
        val members = C.resolveMembers(listOf("s1", "s2"), index(alpha + bravo + film("m1", "Delta Run")))
        assertEquals((alpha + bravo).map { it.ratingKey }, members.map { it.ratingKey })
        val c = C.buildCandidates(listOf(ServerCollection("srv:c", "Shows", listOf("s1", "s2"), "srv")),
            C.indexLibrary(alpha + bravo) { it.serverID!! }).single()
        assertEquals(0, c.movieCount)
        assertEquals(2, c.showCount)
    }

    /** testEpisodeChildrenMatchByKeyWithoutShowKey: Emby lists the episodes themselves. */
    @Test fun episodeChildrenMatchByKeyWithoutShowKey() {
        val alpha = episodes("Alpha Island", "s1", 4, stampShowKey = false)
        val c = C.buildCandidates(listOf(ServerCollection("srv:c", "Shows", alpha.map { it.ratingKey }, "srv")),
            C.indexLibrary(alpha) { it.serverID!! }).single()
        assertEquals(alpha.map { it.ratingKey }, c.items.map { it.ratingKey })
        assertEquals("falls back to the show title", 1, c.showCount)
    }

    /** testMixedCollectionHoldsFilmsAndEpisodes */
    @Test fun mixedCollectionHoldsFilmsAndEpisodes() {
        val films = listOf(film("m1", "Delta Run"), film("m2", "Echo Point"))
        val lima = episodes("Hotel Lima", "s4", 2)
        val c = C.buildCandidates(listOf(ServerCollection("srv:c", "Mix", listOf("m1", "m2", "s4"), "srv")),
            C.indexLibrary(films + lima) { it.serverID!! }).single()
        assertEquals((films + lima).map { it.ratingKey }, c.items.map { it.ratingKey })
        assertEquals("2 movies · 1 show", C.memberSummary(c))
    }

    /** testEachItemOnceAndUnknownKeysIgnored */
    @Test fun eachItemOnceAndUnknownKeysIgnored() {
        val alpha = episodes("Alpha Island", "s1", 3)
        val members = C.resolveMembers(listOf("m1", "m1", "s1", alpha[0].ratingKey, "nope", "s9"), index(alpha + film("m1", "Delta Run")))
        assertEquals(listOf("m1") + alpha.map { it.ratingKey }, members.map { it.ratingKey })
    }

    /** testFilmsOnlyCollectionUnchanged */
    @Test fun filmsOnlyCollectionUnchanged() {
        val films = listOf(film("m1", "Big"), film("m2", "Cast Away"), film("m3", "Forrest Gump"))
        val c = C.buildCandidates(listOf(ServerCollection("srv:c", "Tom Hanks", listOf("m1", "m2", "m3"), "srv")),
            C.indexLibrary(films) { it.serverID!! }).single()
        assertEquals(films.map { it.ratingKey }, c.items.map { it.ratingKey })
        assertEquals("3 movies", C.memberSummary(c))
        assertEquals(0, c.showCount)
        assertEquals(3, C.MIN_ITEMS)
    }

    /** testTitleRepresentativesWeighAShowOnce */
    @Test fun titleRepresentativesWeighAShowOnce() {
        val alpha = episodes("Alpha Island", "s1", 30)
        assertEquals(listOf("m1", alpha[0].ratingKey), C.titleRepresentatives(listOf(film("m1", "Delta Run")) + alpha).map { it.ratingKey })
    }

    /** testMemberSummaryWording */
    @Test fun memberSummaryWording() {
        assertEquals("12 movies", C.memberSummary(12, 0, 0))
        assertEquals("3 shows · 47 episodes", C.memberSummary(0, 3, 47))
        assertEquals("1 show · 1 episode", C.memberSummary(0, 1, 1))
        assertEquals("1 movie · 2 shows", C.memberSummary(1, 2, 9))
    }

    // ── The franchise block (FranchiseNumberingTests.swift, via roku/tests/CollectionTests.brs) ──

    private fun found(i: Int, films: Int = 3) = Collections.FoundFranchiseEntry(
        id = "tmdb:${10000 + i}", name = "FRANCHISE %03d".format(i),
        movies = (1..films).map { film("f$i-$it", "f$i $it") },
    )

    private fun candidate(id: String, category: CollectionCategory, enabled: Boolean = true, films: Int = 3) =
        Collections.Candidate(
            id = id, title = id.uppercase(), movieCount = films, showCount = 0, episodeCount = 0,
            items = (1..films).map { film("$id-$it", "$id $it") }, enabled = enabled, matchedChannel = null,
            contentOverlap = null, foldedInto = null, category = category,
        )

    private fun numbers(m: Collections.Materialized, cat: CollectionCategory, collection: Boolean? = null) =
        m.channels.filter { it.category == cat && (collection == null || it.collection == collection) }.map { it.number }

    private fun ids(m: Collections.Materialized, cat: CollectionCategory, collection: Boolean? = null) =
        m.channels.filter { it.category == cat && (collection == null || it.collection == collection) }.map { it.id }

    @Test fun eachKindHasItsOwnRangeAndIDBase() {
        assertEquals(310, C.FRANCHISE_NUMBER_BASE)
        assertEquals(399, C.FRANCHISE_NUMBER_BASE + C.FRANCHISE_CAPACITY - 1)
        assertEquals(1_000_000, C.FOUND_ID_BASE)
        assertEquals(1_010_000, C.FRANCHISE_COLLECTION_ID_BASE)
        assertEquals(400, C.NUMBER_BASE)
        assertEquals(499, C.NUMBER_BASE + C.CAPACITY - 1)
        assertEquals(1_020_000, C.ID_BASE)
    }

    /** testEightySixFranchisesAndTwoFranchiseCollectionsShareCH310Through397 */
    @Test fun eightySixFoundAndTwoFranchiseCollectionsShareTheBlock() {
        val cands = listOf(
            candidate("saga-a", CollectionCategory.FRANCHISES), candidate("saga-b", CollectionCategory.FRANCHISES),
            candidate("hanks", CollectionCategory.CUSTOM), candidate("nolan", CollectionCategory.CUSTOM),
            candidate("off", CollectionCategory.CUSTOM, enabled = false),
        )
        val m = C.materialize(cands, (0..85).map { found(it) })
        assertEquals((310..395).toList(), numbers(m, CollectionCategory.FRANCHISES, collection = false))
        assertEquals(0, m.overCapFound)
        assertEquals(listOf(396, 397), numbers(m, CollectionCategory.FRANCHISES, collection = true))
        assertEquals(listOf(1_010_000, 1_010_001), ids(m, CollectionCategory.FRANCHISES, collection = true))
        assertEquals(listOf(400, 401), numbers(m, CollectionCategory.CUSTOM))
        assertEquals(listOf(1_020_000, 1_020_001), ids(m, CollectionCategory.CUSTOM))
        assertEquals(0, m.overCap)
    }

    /** testFoundFranchisesKeepTheirIDs */
    @Test fun foundFranchisesKeepTheirIDs() {
        val m = C.materialize(emptyList(), (0..2).map { found(it) })
        assertEquals(listOf(1_000_000, 1_000_001, 1_000_002), m.channels.map { it.id })
        assertEquals(listOf("tmdb:10000", "tmdb:10001", "tmdb:10002"), m.channels.map { it.franchiseID })
    }

    /** testFranchiseBlockIsCappedAt399AndKeepsTheBiggestOfBothKinds */
    @Test fun theFranchiseBlockKeepsTheBiggestOfBothKinds() {
        val f = (0..93).map { found(it, films = if (it < 5) 3 else 4) }
        val cands = listOf(
            candidate("saga-a", CollectionCategory.FRANCHISES, films = 5),
            candidate("saga-b", CollectionCategory.FRANCHISES, films = 3),
            candidate("hanks", CollectionCategory.CUSTOM),
        )
        val m = C.materialize(cands, f)
        val foundChannels = m.channels.filter { it.foundFranchise }
        assertEquals(89, foundChannels.size)
        assertEquals(310, foundChannels.first().number)
        assertEquals(398, foundChannels.last().number)
        val names = foundChannels.map { it.name }
        assertEquals(names.sortedWith(Comparator(C::compareStrings)), names)
        assertFalse(names.contains("FRANCHISE 000") || names.contains("FRANCHISE 004"))
        assertEquals(listOf("SAGA-A"), m.channels.filter { it.category == CollectionCategory.FRANCHISES && it.collection }.map { it.name })
        assertEquals(listOf(399), numbers(m, CollectionCategory.FRANCHISES, collection = true))
        assertEquals(5, m.overCapFound)
        assertEquals(1, m.overCapFranchises)
        assertEquals(listOf(400), numbers(m, CollectionCategory.CUSTOM))

        // Switching six found franchises off frees the block.
        val m2 = C.materialize(cands, f.filterIndexed { i, _ -> i !in 5..10 })
        assertEquals(0, m2.overCapFound + m2.overCapFranchises)
        assertEquals(90, m2.channels.count { it.category == CollectionCategory.FRANCHISES })
        assertEquals(listOf(398, 399), numbers(m2, CollectionCategory.FRANCHISES, collection = true))
    }

    /** testFranchiseCollectionsAloneFillTheBlockAndKeepTheBiggest */
    @Test fun franchiseCollectionsAloneFillTheBlock() {
        val cands = (0..92).map {
            candidate("saga-%02d".format(it), CollectionCategory.FRANCHISES, films = if (it == 7 || it == 20 || it == 41) 3 else 5)
        }
        val m = C.materialize(cands)
        assertEquals((310..399).toList(), numbers(m, CollectionCategory.FRANCHISES))
        assertEquals((1_010_000..1_010_089).toList(), ids(m, CollectionCategory.FRANCHISES))
        val kept = m.channels.map { it.name }
        assertFalse(kept.contains("SAGA-07") || kept.contains("SAGA-20") || kept.contains("SAGA-41"))
        assertEquals(kept.sortedWith(Comparator(C::compareStrings)), kept)
        assertEquals(3, m.overCapFranchises)
        assertEquals(0, m.overCapCustom)
        assertEquals(emptyList<Int>(), numbers(m, CollectionCategory.CUSTOM))
    }

    /** Swift's `<`: by code point, upper case before lower, digits as characters; input order never matters. */
    @Test fun blockOrderIsSwiftsStringOrder() {
        fun kept(vararg e: Triple<String, String, Int>, capacity: Int = 10): String {
            val k = C.keptInDisplayOrder(e.map { Collections.BlockEntry(it.second, it.first, it.third, it.first) }, capacity)
            return k.kept.joinToString(",") { it.value } + " skipped ${k.skipped}"
        }
        val entries = arrayOf(
            Triple("b", "SAME", 4), Triple("a", "SAME", 4), Triple("z", "ZED", 9), Triple("c", "ALPHA", 4), Triple("d", "SMALL", 2),
        )
        assertEquals("c,a,z skipped 2", kept(*entries, capacity = 3))
        assertEquals("c,a,z skipped 2", kept(*entries.reversedArray(), capacity = 3))
        assertEquals(
            "4,3,5,2,1 skipped 0",
            kept(Triple("1", "alpha", 3), Triple("2", "Zed", 3), Triple("3", "SAW 2", 3), Triple("4", "SAW 10", 3), Triple("5", "ZED", 3)),
        )
    }
}
