package com.muellhaus.nostalgex.engine

import com.muellhaus.nostalgex.engine.GuideStripes.Group
import com.muellhaus.nostalgex.engine.GuideStripes.GuideBundle
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The guide's bundle stripes, held to the Apple TV's `GuideStripesTests.swift`: which bundle a channel is in,
 * the runs that make a stripe, the colour of a name and whether its text reads on it, the bundle boundary
 * maths for Up and Down, and where a sticky label sits in the viewport.
 */
class GuideStripesTest {
    private val franchises = "franchises"
    private val franchiseCollections = "collections-franchises"
    private val pitch = 81f

    private fun bundle(id: String, name: String, ids: List<Int>) = ChannelConfig.Bundle(id, name, ids, null)

    private fun membership(bundles: List<ChannelConfig.Bundle>, on: List<String>? = null, found: List<Int> = emptyList()) =
        GuideStripes.membership(bundles, (on ?: bundles.map { it.id }).toSet(), found, franchises, franchiseCollections)

    private fun group(name: String?, first: Int, count: Int) = Group(name?.let { GuideBundle(it, it) }, first, count)

    private fun groups(names: List<String?>, rows: Int = 2) = names.mapIndexed { i, n -> group(n, i * rows, rows) }

    // Which bundle a channel is in

    @Test fun aChannelIsInTheBundleThatListsIt() {
        val m = membership(listOf(bundle("a", "ALPHA", listOf(1, 2)), bundle("b", "BETA", listOf(3))))
        assertEquals("ALPHA", m[1]?.name); assertEquals("ALPHA", m[2]?.name); assertEquals("BETA", m[3]?.name)
        assertNull(m[4])
    }

    @Test fun aBundleThatIsOffNamesNoChannel() {
        val m = membership(listOf(bundle("a", "ALPHA", listOf(1, 2)), bundle("b", "BETA", listOf(3))), on = listOf("a"))
        assertNull(m[3])
    }

    @Test fun theFirstBundleInOrderWinsAChannelListedTwice() {
        val m = membership(listOf(bundle("a", "ALPHA", listOf(1)), bundle("b", "BETA", listOf(1, 2))))
        assertEquals("ALPHA", m[1]?.name); assertEquals("BETA", m[2]?.name)
    }

    @Test fun everyFranchiseChannelIsInOneBundleNamedByTheStockBundle() {
        val bundles = listOf(
            bundle("a", "ALPHA", listOf(1)),
            bundle(franchiseCollections, "FRANCHISE SETS", listOf(30)),
            bundle(franchises, "FRANCHISES", listOf(10, 11)),
        )
        val m = membership(bundles, found = listOf(12))
        for (id in listOf(10, 11, 12, 30)) assertEquals("channel $id", "FRANCHISES", m[id]?.name)
        assertEquals(1, listOf(10, 11, 12, 30).mapNotNull { m[it]?.id }.toSet().size)
    }

    @Test fun franchiseCollectionsAloneAreNamedByTheirOwnBundle() {
        val m = membership(
            listOf(bundle("a", "ALPHA", listOf(1)), bundle(franchiseCollections, "FRANCHISE SETS", listOf(30))),
            on = listOf("a", franchiseCollections),
        )
        assertEquals("FRANCHISE SETS", m[30]?.name)
    }

    @Test fun foundFranchisesAreNotAnyBundlesWhileFranchisesIsOff() {
        val m = membership(listOf(bundle("a", "ALPHA", listOf(1)), bundle(franchises, "FRANCHISES", listOf(10))), on = listOf("a"), found = listOf(12))
        assertNull(m[12]); assertNull(m[10])
    }

    // The runs

    @Test fun consecutiveRowsInOneBundleAreOneRun() {
        val m = membership(listOf(bundle("a", "ALPHA", listOf(1, 2)), bundle("b", "BETA", listOf(3, 4, 5))))
        val g = GuideStripes.groups(listOf(1, 2, 3, 4, 5), m)
        assertEquals(listOf<String?>("ALPHA", "BETA"), g.map { it.name })
        assertEquals(listOf(0, 2), g.map { it.firstRow })
        assertEquals(listOf(2, 3), g.map { it.rowCount })
        assertEquals(listOf(1, 4), g.map { it.lastRow })
    }

    @Test fun channelsInNoBundleAreARunWithNoName() {
        val m = membership(listOf(bundle("a", "ALPHA", listOf(1, 2)), bundle("b", "BETA", listOf(3))))
        val g = GuideStripes.groups(listOf(1, 2, 9, 3), m)
        assertEquals(listOf("ALPHA", null, "BETA"), g.map { it.name })
        assertEquals(listOf(2, 1, 1), g.map { it.rowCount })
    }

    @Test fun aBundleListedInTwoStretchesIsTwoRuns() {
        val m = membership(listOf(bundle("a", "ALPHA", listOf(1, 2)), bundle("b", "BETA", listOf(3))))
        assertEquals(listOf<String?>("ALPHA", "BETA", "ALPHA"), GuideStripes.groups(listOf(1, 3, 2), m).map { it.name })
    }

    @Test fun noChannelsIsNoRuns() = assertEquals(emptyList<Group>(), GuideStripes.groups(emptyList(), emptyMap()))

    @Test fun aBundleWithNoRowsHasNoRun() {
        val m = membership(listOf(bundle("a", "ALPHA", listOf(1, 2)), bundle("b", "BETA", listOf(3, 4))))
        assertEquals(listOf<String?>("BETA"), GuideStripes.groups(listOf(3, 4), m).map { it.name })
    }

    @Test fun theRunAChannelIsIn() {
        val g = GuideStripes.groups(listOf(1, 2, 3, 4, 5), membership(listOf(bundle("a", "A", listOf(1, 2)), bundle("b", "B", listOf(3, 4, 5)))))
        assertEquals(0, GuideStripes.groupIndexContainingRow(0, g)); assertEquals(0, GuideStripes.groupIndexContainingRow(1, g))
        assertEquals(1, GuideStripes.groupIndexContainingRow(2, g)); assertEquals(1, GuideStripes.groupIndexContainingRow(4, g))
        assertNull(GuideStripes.groupIndexContainingRow(5, g))
    }

    // Up and Down on the stripe

    @Test fun downGoesToTheNextBundleAndUpToThePrevious() {
        val g = groups(listOf("A", "B", "C"))
        assertEquals(1, GuideStripes.neighbourIndex(0, 1, g)); assertEquals(2, GuideStripes.neighbourIndex(1, 1, g))
        assertEquals(1, GuideStripes.neighbourIndex(2, -1, g)); assertEquals(0, GuideStripes.neighbourIndex(1, -1, g))
    }

    @Test fun thereIsNoWrapPastTheFirstOrLastBundle() {
        val g = groups(listOf("A", "B", "C"))
        assertNull(GuideStripes.neighbourIndex(0, -1, g)); assertNull(GuideStripes.neighbourIndex(2, 1, g))
    }

    @Test fun anUnnamedRunIsSteppedOver() {
        val g = groups(listOf("A", null, "B", null))
        assertEquals(2, GuideStripes.neighbourIndex(0, 1, g)); assertEquals(0, GuideStripes.neighbourIndex(2, -1, g))
        assertNull(GuideStripes.neighbourIndex(2, 1, g))
    }

    @Test fun thereAreNoBundlesToMoveBetweenWhenNoRunIsNamed() {
        assertFalse(GuideStripes.hasBundles(groups(listOf(null, null)))); assertFalse(GuideStripes.hasBundles(emptyList()))
        assertTrue(GuideStripes.hasBundles(groups(listOf(null, "A"))))
    }

    // What each row draws

    @Test fun everyRowDrawsItsBundlesColourAndTheFirstOfARunStartsIt() {
        val g = listOf(group("ALPHA", 0, 2), group(null, 2, 1), group("BETA", 3, 2))
        val cells = GuideStripes.rowCells(g, 5)
        assertEquals(listOf(true, false, true, true, false), cells.map { it.startsRun })
        assertEquals(GuideStripes.Palette.hex("ALPHA"), cells[0].hex); assertEquals(GuideStripes.Palette.hex("ALPHA"), cells[1].hex)
        assertNull(cells[2].hex); assertEquals(GuideStripes.Palette.hex("BETA"), cells[3].hex)
    }

    // Colour

    /** Pinned to the Apple TV's list, so a change to the hash or the palette shows up here. */
    @Test fun theColourOfAShippedBundleNeverChanges() {
        val expected = listOf(
            "NOSTALGEX" to 9, "KIDZ ZONE" to 1, "PRIME TIME" to 6, "MARQUEE" to 1, "ADVENTURELAND" to 4,
            "OVERTIME" to 9, "CASE FILES" to 2, "DECADES" to 4, "ARTHOUSE" to 0, "NETWORKS" to 6, "SCREAM" to 0,
            "TIS THE SEASON" to 5, "FRANCHISES" to 6, "HIGH ROTATION" to 7,
        )
        for ((name, index) in expected) assertEquals(name, index, GuideStripes.Palette.index(name))
    }

    @Test fun theColourDoesNotDependOnCase() =
        assertEquals(GuideStripes.Palette.index("KIDZ ZONE"), GuideStripes.Palette.index("Kidz Zone"))

    @Test fun everyNameLandsInThePalette() {
        for (name in listOf("", "A", "KIDZ ZONE", "A VERY LONG BUNDLE NAME WITH MANY WORDS", "ÅNGSTRÖM", "日本語"))
            assertTrue(name, GuideStripes.Palette.index(name) in GuideStripes.Palette.hexes.indices)
    }

    @Test fun thePaletteIsTenDistinctValidColours() {
        val hexes = GuideStripes.Palette.hexes
        assertEquals(10, hexes.size); assertEquals(hexes.size, hexes.toSet().size)
        for (hex in hexes) assertNotEquals(hex, null, hex.removePrefix("#").toIntOrNull(16))
    }

    @Test fun theNameReadsOnItsStripeAndOnTheFocusedStripe() {
        for (hex in GuideStripes.Palette.hexes) {
            assertTrue(hex, GuideStripes.Palette.nameContrast(hex) >= 4.5)
            val lifted = GuideStripes.Palette.focusedHex(hex)
            assertTrue(hex, GuideStripes.Palette.luminance(lifted) > GuideStripes.Palette.luminance(hex))
            assertTrue("$hex lifted to $lifted", GuideStripes.Palette.nameContrast(lifted) >= 4.5)
        }
        assertEquals("#383838", GuideStripes.Palette.focusedHex("#000000"))
        assertEquals("#FFFFFF", GuideStripes.Palette.focusedHex("#FFFFFF"))
        assertTrue(GuideStripes.Palette.nameIsBlack("#F1C40F")); assertFalse(GuideStripes.Palette.nameIsBlack("#8E44AD"))
        assertEquals(1.0, GuideStripes.Palette.luminance("#FFFFFF"), 0.001); assertEquals(0.0, GuideStripes.Palette.luminance("#000000"), 0.001)
    }

    /** scripts/guide-stripe-colours-golden.json, written by the Apple TV's GuideStripeColoursGoldenTests. */
    @Test fun theColoursMatchTheAppleTVsGolden() {
        val root = File(System.getProperty("nostalgex.repoRoot") ?: "..")
        val golden = Json.parseToJsonElement(root.resolve("scripts/guide-stripe-colours-golden.json").readText()).jsonObject
        assertEquals(golden["hexes"]!!.jsonArray.map { it.jsonPrimitive.content }, GuideStripes.Palette.hexes)
        val names = golden["names"]!!.jsonObject
        assertTrue(names.size >= 20)
        for ((name, index) in names) assertEquals(name, index.jsonPrimitive.int, GuideStripes.Palette.index(name))
        val config = ChannelConfig(Json.parseToJsonElement(root.resolve("channels.json").readText()).jsonObject)
        for (b in config.bundles) assertTrue("${b.name} is a shipped bundle and is not in the golden", b.name in names)
    }

    /** The shipped bundles in guide order (by their first channel number): no two neighbours share a colour. */
    @Test fun noTwoNeighbouringShippedBundlesShareAColour() {
        val root = File(System.getProperty("nostalgex.repoRoot") ?: "..")
        val config = ChannelConfig(Json.parseToJsonElement(root.resolve("channels.json").readText()).jsonObject)
        val number = config.channels.associate { it.id to it.number }
        val ordered = config.bundles.filter { it.channelIDs.isNotEmpty() }
            .sortedBy { b -> b.channelIDs.mapNotNull { number[it] }.minOrNull() ?: Int.MAX_VALUE }
        assertTrue(ordered.size >= 10)
        for ((a, b) in ordered.zipWithNext())
            assertNotEquals("${a.name} and ${b.name} are neighbours in the guide and the same colour",
                GuideStripes.Palette.index(a.name), GuideStripes.Palette.index(b.name))
    }

    // Where things are on the screen

    @Test fun aWholeRunThatIsOnScreenIsItsOwnSpan() {
        val span = GuideStripes.visibleSpan(group("A", 2, 3), pitch, 0f, 0f, 463f)
        assertEquals(162f, span?.first); assertEquals(243f, span?.second)
    }

    @Test fun aRunScrolledPartlyOffTheTopKeepsTheRowsThatAreLeft() {
        val span = GuideStripes.visibleSpan(group("A", 0, 5), pitch, 0f, 162f, 463f)
        assertEquals(0f, span?.first); assertEquals(243f, span?.second)
    }

    @Test fun aRunRunningOffTheBottomIsCutAtTheViewport() {
        val span = GuideStripes.visibleSpan(group("A", 4, 10), pitch, 0f, 0f, 463f)
        assertEquals(324f, span?.first); assertEquals(139f, span?.second)
    }

    @Test fun aRunWhollyOffScreenHasNoSpan() {
        assertNull(GuideStripes.visibleSpan(group("A", 0, 2), pitch, 0f, 500f, 463f))
        assertNull(GuideStripes.visibleSpan(group("B", 20, 2), pitch, 0f, 0f, 463f))
    }

    @Test fun theInviteRowPushesEveryRunDown() {
        val span = GuideStripes.visibleSpan(group("A", 0, 2), pitch, 80f, 0f, 463f)
        assertEquals(80f, span?.first); assertEquals(162f, span?.second)
    }

    @Test fun labelsAreOnlyForNamedRunsWithRoomForThem() {
        val g = listOf(group("ALPHA", 0, 3), group(null, 3, 2), group("BETA", 5, 1))
        assertEquals(listOf("BETA"), GuideStripes.labels(g, pitch, 0f, 213f, 463f).map { it.name })
        val full = GuideStripes.labels(g, pitch, 0f, 0f, 463f)
        assertEquals(listOf("ALPHA", "BETA"), full.map { it.name })
        assertEquals(0f, full.first().top); assertEquals(243f, full.first().height)
    }

    @Test fun aOneRowBundleHasALabel() =
        assertEquals(1, GuideStripes.labels(listOf(group("TINY", 0, 1)), pitch, 0f, 0f, 463f).size)

    @Test fun theStripeFitsTheSlotOnEveryRow() {
        val screen = 1920f; val channelColumn = 340f
        val programs = screen - channelColumn
        val headerWidth = channelColumn + 12 + 4 * (programs / 4 + 14)
        for (accent in listOf(4f, 8f)) assertTrue(GuideStripes.STRIPE_WIDTH < (headerWidth - (accent + channelColumn + 1 + programs)) / 2)
        assertEquals(29.5f, (headerWidth - (8 + channelColumn + 1 + programs)) / 2, 0.01f)
    }
}
