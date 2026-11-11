package com.muellhaus.nostalgex.engine

import com.muellhaus.nostalgex.engine.DesignTokens.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** #267: every text colour at 4.5:1 or more on every surface it sits on, as the Apple TV's and Roku's tests hold it. */
class DesignTokensTest {
    private val names = mapOf(
        Color.TEXT to "text", Color.TEXT_2 to "text-2", Color.TEXT_DIM to "textDim", Color.CYAN to "cyan", Color.YELLOW to "yellow",
        Color.AMBER to "amber", Color.RED_TEXT to "red-text", Color.ON_CYAN to "on-cyan", Color.PANEL to "panel", Color.ROW to "row",
        Color.SELECTED_ROW to "selected-row", Color.CHOSEN_NEUTRAL to "chosen-neutral", Color.GUIDE to "guide",
        Color.GUIDE_ROW_LIGHTEST to "lightest guide row",
    )

    @Test fun everyTextColourOnEverySurfaceItSitsOn() {
        val pairs = ArrayList<Pair<Int, Int>>()
        for (text in listOf(Color.TEXT, Color.TEXT_2, Color.CYAN, Color.YELLOW, Color.AMBER, Color.RED_TEXT))
            for (surface in listOf(Color.PANEL, Color.ROW, Color.SELECTED_ROW)) pairs += text to surface
        for (text in listOf(Color.TEXT, Color.TEXT_2)) pairs += text to Color.CHOSEN_NEUTRAL
        pairs += Color.ON_CYAN to Color.CYAN
        pairs += Color.TEXT_DIM to Color.GUIDE
        pairs += Color.TEXT_DIM to Color.GUIDE_ROW_LIGHTEST
        val under = pairs.filter { (t, s) -> DesignTokens.contrast(t, s) < 4.5 }
            .map { (t, s) -> "${names[t]} on ${names[s]}: %.2f".format(DesignTokens.contrast(t, s)) }
        assertEquals("pairs under 4.5:1", emptyList<String>(), under)
    }

    /** The issue's own figures for textDim, so the guide backgrounds are the ones it meant. */
    @Test fun textDimMatchesTheIssuesFigures() {
        assertEquals(5.36, DesignTokens.contrast(Color.TEXT_DIM, Color.GUIDE), 0.02)
        assertEquals(4.83, DesignTokens.contrast(Color.TEXT_DIM, Color.GUIDE_ROW_LIGHTEST), 0.02)
    }

    /** The check bites: textDim on the selected row is under 4.5:1, which is why it is kept off it. */
    @Test fun theCheckBites() = assertTrue(DesignTokens.contrast(Color.TEXT_DIM, Color.SELECTED_ROW) < 4.5)

    /** Text on a channel's colour is black or white, whichever reads better, at 4.58:1 or more for any colour. */
    @Test fun textOnAnyChannelColour() {
        var worst = 21.0
        for (r in 0..255 step 15) for (g in 0..255 step 15) for (b in 0..255 step 15) {
            val fill = (r shl 16) or (g shl 8) or b
            worst = minOf(worst, DesignTokens.contrast(DesignTokens.textOn(fill), fill))
        }
        assertTrue("worst $worst", worst >= 4.58)
    }

    @Test fun theTypeScale() {
        assertEquals(listOf(96, 44, 34, 29, 25, 36), with(DesignTokens.Size) { listOf(HERO, TITLE, HEADING, BODY, CAPTION, TAG) })
        assertEquals(listOf(38, 29, 25, 31), with(DesignTokens.CompactSize) { listOf(TITLE, HEADING, BODY, TAG) })
    }
}
