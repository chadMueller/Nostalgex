package com.muellhaus.nostalgex.ui

import androidx.compose.ui.graphics.Color
import com.muellhaus.nostalgex.engine.DesignTokens

/**
 * The Apple TV 1.0.32 design tokens (#267) as Compose colours; the values and sizes live in the
 * engine's DesignTokens, where their contrast is tested. Sizes go through `u()` and `sp()` as
 * written: they are Apple TV points at 1920x1080.
 */
internal object Tokens {
    private fun c(rgb: Int) = Color(0xFF000000 or rgb.toLong())

    val Text = c(DesignTokens.Color.TEXT)
    val Text2 = c(DesignTokens.Color.TEXT_2)
    val TextDim = c(DesignTokens.Color.TEXT_DIM)
    val Cyan = c(DesignTokens.Color.CYAN)
    val Yellow = c(DesignTokens.Color.YELLOW)
    val Amber = c(DesignTokens.Color.AMBER)
    val RedText = c(DesignTokens.Color.RED_TEXT)
    val Red = c(DesignTokens.Color.RED)
    val OnCyan = c(DesignTokens.Color.ON_CYAN)
    val Panel = c(DesignTokens.Color.PANEL)
    val Row = c(DesignTokens.Color.ROW)
    val SelectedRow = c(DesignTokens.Color.SELECTED_ROW)
    val ChosenNeutral = c(DesignTokens.Color.CHOSEN_NEUTRAL)
    val RestingOutline = c(DesignTokens.Color.RESTING_OUTLINE)
    val Guide = c(DesignTokens.Color.GUIDE)

    /** Text on a solid channel-coloured fill: black or white, whichever reads better. */
    fun textOn(fill: Color): Color {
        val rgb = ((fill.red * 255).toInt() shl 16) or ((fill.green * 255).toInt() shl 8) or (fill.blue * 255).toInt()
        return c(DesignTokens.textOn(rgb))
    }
}
