package com.muellhaus.nostalgex.engine

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.ZoneId
import java.time.ZonedDateTime

/** The library to guide path the app runs, on the real channels.json, with a made-up library. */
class LineupTest {
    private val repoRoot = File(System.getProperty("nostalgex.repoRoot") ?: "..")
    private fun read(path: String) = Json.parseToJsonElement(repoRoot.resolve(path).readText()).jsonObject
    private val config = ChannelConfig(read("channels.json"))
    private val memberships = read("channels-memberships.json")
    private val zone = ZoneId.of("America/New_York")

    private val genres = listOf("Comedy", "Drama", "Action", "Adventure", "Thriller", "Romance", "Crime", "Science Fiction", "Family", "Fantasy")

    /** `films` films from 1975 to 2004 and `shows` shows of 20 episodes, in a fixed order. */
    private fun library(films: Int, shows: Int): List<MediaItem> {
        val out = ArrayList<MediaItem>()
        for (i in 0 until films) {
            out += MediaItem(
                ratingKey = "m$i", title = "Film $i", type = "movie", duration = 85 + i % 60,
                year = 1975 + i % 30, genres = listOf(genres[i % genres.size], genres[(i * 7 + 3) % genres.size]),
                contentRating = listOf("G", "PG", "PG-13", "R")[i % 4], viewCount = i % 5, librarySource = "movie",
            )
        }
        for (s in 0 until shows) for (e in 0 until 20) {
            out += MediaItem(
                ratingKey = "s${s}e$e", title = "Show $s", type = "episode", episodeTitle = "Episode $e", duration = 22 + s % 3 * 20,
                year = 1980 + s % 25, genres = listOf(genres[s % genres.size]), contentRating = "TV-PG", librarySource = "tv",
            )
        }
        return out
    }

    private fun lineup() = Lineup(config, memberships, DailyManifest(zone, InMemoryManifestStore()), "test")

    /**
     * Server collections in the guide: a franchise collection at CH 310 while FRANCHISES is on,
     * another collection at CH 400 whatever the package, both scheduled and in the sidebar, and
     * each gone when its switch is (materializeDynamicChannels, applyBundleFilter).
     */
    @Test
    fun serverCollectionsBecomeChannelsAt310And400() {
        val definitions = FranchiseBuilder.parseDefinitions(repoRoot.resolve("franchises.json").readText())
        // Unrelated titles, as on the emulator's Jellyfin: "Film 1, 2, 3" would read as a numbered series.
        val titles = mapOf("m1" to "Night of the Living Dead", "m2" to "Carnival of Souls", "m3" to "House on Haunted Hill",
            "m4" to "Big Buck Bunny", "m5" to "Sintel", "m6" to "Tears of Steel")
        val items = library(300, 6).map { it.copy(serverUrl = "srv", title = titles[it.ratingKey] ?: it.title) }
        val collections = listOf(
            ServerCollection("srv:1", "Night Horrors", listOf("m1", "m2", "m3"), "srv"),
            ServerCollection("srv:2", "Blender Open Movie Trilogy", listOf("m4", "m5", "m6"), "srv"),
        )
        val l = Lineup(config, memberships, DailyManifest(zone, InMemoryManifestStore()), "test", "plex", definitions)
        val both = Lineup.FranchiseChoices(enabledCollections = setOf("srv:1", "srv:2"))
        l.franchiseChoices = both
        val bundles = setOf("nostalgex", "franchises")
        l.build(items, bundles, collections)
        val categories = l.franchises!!.candidates.associate { it.title to it.category }
        assertEquals(CollectionCategory.CUSTOM, categories["NIGHT HORRORS"])
        assertEquals(CollectionCategory.FRANCHISES, categories["BLENDER OPEN MOVIE TRILOGY"])
        val byNumber = l.channels.associateBy { it.number }
        assertEquals("NIGHT HORRORS", byNumber[400]?.name)
        assertEquals("BLENDER OPEN MOVIE TRILOGY", byNumber[310]?.name)
        assertEquals(listOf("m1", "m2", "m3"), byNumber.getValue(400).pool.map { it.ratingKey })
        assertEquals(l.channels.sortedBy { it.number }.map { it.id }, l.channels.map { it.id })
        l.rebuildSchedules(ZonedDateTime.of(2026, 10, 29, 20, 15, 0, 0, zone))
        assertTrue("CH 400 has a programme now", l.schedules[byNumber.getValue(400).id]?.nowPlaying != null)
        val sidebar = l.jumpTargets(bundles).map { it.first.id }
        assertTrue(sidebar.toString(), "franchises" in sidebar && Lineup.OTHER_COLLECTIONS_BUNDLE in sidebar)

        // FRANCHISES off: the franchise collection goes with it, the other collection stays.
        l.setBundles(setOf("nostalgex"))
        assertEquals(listOf(400), l.channels.map { it.number }.filter { it >= 300 })
        // Its own switch off: gone too.
        l.setFranchiseChoices(Lineup.FranchiseChoices(), setOf("nostalgex"))
        assertEquals(emptyList<Int>(), l.channels.map { it.number }.filter { it >= 300 })
    }

    @Test
    fun aLibraryFillsTheNostalgexPackageAndEveryChannelHasAProgrammeNow() {
        val l = lineup()
        val t0 = System.nanoTime()
        val switchedOn = l.build(library(3000, 60), setOf("nostalgex"))
        val buildMs = (System.nanoTime() - t0) / 1_000_000
        val now = ZonedDateTime.of(2026, 10, 29, 20, 15, 0, 0, zone)
        val t1 = System.nanoTime()
        l.rebuildSchedules(now)
        val scheduleMs = (System.nanoTime() - t1) / 1_000_000
        println("LineupTest: 4,200 items, ${config.channels.size} channels filtered in $buildMs ms; " +
            "${l.channels.size} in the guide, schedules in $scheduleMs ms (JVM on the build machine, not a TV)")

        assertTrue("nothing extra switched on: $switchedOn", switchedOn.isEmpty())
        assertTrue("some NOSTALGEX channels fill", l.channels.isNotEmpty())
        val nostalgex = config.bundles.first { it.id == "nostalgex" }.channelIDs.toSet()
        assertTrue(l.channels.all { it.id in nostalgex })
        assertEquals(l.channels.sortedBy { it.number }.map { it.id }, l.channels.map { it.id })
        for (ch in l.channels) {
            val s = l.schedules[ch.id]
            assertTrue("${ch.name} has a programme now", s?.nowPlaying != null)
            val pick = l.tune(ch, now)!!
            assertTrue("${ch.name} tunes into its pool", ch.pool.any { it.ratingKey == pick.item.ratingKey })
        }
        // One title on two channels at once: only the lowest channel id shows it as on now.
        val shown = l.schedules.entries.filter { it.value.nowPlaying != null }.groupBy { it.value.nowPlaying!!.item.ratingKey }
        assertTrue(shown.values.all { it.size == 1 })
    }

    @Test
    fun aPackageWithNothingInItSwitchesOnThePackagesThatHaveContent() {
        val l = lineup()
        // A films-only library can't fill the music-video package.
        val switchedOn = l.build(library(3000, 0), setOf("high-rotation"))
        assertTrue("switched on: $switchedOn", switchedOn.isNotEmpty())
        assertTrue(switchedOn.none { id -> config.bundles.first { it.id == id }.activeMonths != null })
        assertTrue(l.channels.isNotEmpty())
    }

    /** A library the size of a real one, timed both ways: only the chosen package's channels, and all of them. */
    @Test
    fun theChosenPackageBuildsWithoutFilteringEveryChannel() {
        val items = library(4000, 370)
        repeat(2) { lineup().build(items, setOf("nostalgex")) } // JIT warm-up
        val t0 = System.nanoTime()
        val chosen = lineup().also { it.build(items, setOf("nostalgex")) }
        val chosenMs = (System.nanoTime() - t0) / 1_000_000
        val t1 = System.nanoTime()
        // A package with no content falls back to filtering every channel.
        lineup().build(items, setOf("high-rotation"))
        val allMs = (System.nanoTime() - t1) / 1_000_000
        val t2 = System.nanoTime()
        val config2 = ChannelConfig(read("channels.json"))
        val memberships2 = read("channels-memberships.json")
        val parseMs = (System.nanoTime() - t2) / 1_000_000
        val split = Lineup(config2, memberships2, DailyManifest(zone, InMemoryManifestStore()), "test").also { it.build(items, setOf("nostalgex")) }
        println("LineupTest: ${items.size} items; chosen package in $chosenMs ms (item facts ${chosen.prepareMs}), every channel in $allMs ms; " +
            "config parse $parseMs ms, cold item facts ${split.prepareMs} ms (JVM, not a TV)")
        assertTrue(chosen.channels.isNotEmpty())
    }

    /** The saved library (LibraryStore) round-trips to the same items, so it builds the same guide. */
    @Test
    fun aSavedLibraryBuildsTheSameGuide() {
        val items = library(800, 30).mapIndexed { i, it ->
            if (i % 3 == 0) it.copy(enrichment = Enrichment(keywords = listOf("heist")), tmdbID = i.toLong(), serverUrl = "https://a", partKey = "/p/$i") else it
        }
        val json = Json { explicitNulls = false }
        val restored = json.decodeFromString<List<MediaItem>>(json.encodeToString(items))
        assertEquals(items, restored)
        val now = ZonedDateTime.of(2026, 10, 29, 20, 15, 0, 0, zone)
        val a = lineup().also { it.build(items, setOf("nostalgex")); it.rebuildSchedules(now) }
        val b = lineup().also { it.build(restored, setOf("nostalgex")); it.rebuildSchedules(now) }
        assertEquals(a.channels.map { it.id to it.pool.map { p -> p.ratingKey } }, b.channels.map { it.id to it.pool.map { p -> p.ratingKey } })
        assertEquals(a.schedules.mapValues { it.value.entries.map { e -> e.id } }, b.schedules.mapValues { it.value.entries.map { e -> e.id } })
    }

    @Test
    fun anEmptyLibraryLeavesAnEmptyGuide() {
        val l = lineup()
        l.build(emptyList(), setOf("nostalgex"))
        assertTrue(l.channels.isEmpty())
    }

    /** Emby's Dolby Vision profile 5 titles stay off channels (isLeftOffChannels); on Plex they air. */
    @Test
    fun embyLeavesDolbyVisionProfileFiveOffChannels() {
        val items = library(600, 10).mapIndexed { i, it -> if (it.type == "movie" && i % 3 == 0) it.copy(doviProfile = 5) else it }
        val dv5 = items.filter { it.doviProfile == 5 }.map { it.ratingKey }.toSet()
        fun aired(backend: String) = Lineup(config, memberships, DailyManifest(zone, InMemoryManifestStore()), "test", backend)
            .also { it.build(items, setOf("nostalgex")) }
            .channels.flatMap { ch -> ch.pool.map { it.ratingKey } }.toSet()
        assertTrue("Plex airs some profile 5 titles", aired("plex").any { it in dv5 })
        assertTrue("Emby airs none", aired("emby").none { it in dv5 })
    }

    /** The sidebar lists packages in guide order: each at its earliest channel there (bundleJumpTargets). */
    @Test
    fun theSidebarFollowsTheGuideOrder() {
        val l = lineup()
        val all = config.bundles.map { it.id }.toSet()
        l.build(library(3000, 60), all)
        l.rebuildSchedules(ZonedDateTime.of(2026, 10, 29, 20, 15, 0, 0, zone))
        val targets = l.jumpTargets(all)
        assertTrue("more than one package fills", targets.size > 1)
        val at = targets.map { (_, ch) -> l.channels.indexOfFirst { it.id == ch.id } }
        assertEquals("rows in guide order", at.sorted(), at)
        for ((b, ch) in targets) {
            val earliest = l.channels.indexOfFirst { it.id in b.channelIDs }
            assertEquals("${b.id} jumps to its earliest channel", earliest, l.channels.indexOfFirst { it.id == ch.id })
        }
    }
}
