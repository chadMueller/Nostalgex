package com.muellhaus.nostalgex.engine

/**
 * The Apple TV 1.0.32 design tokens (#267, DesignTokens.swift; the Roku's ui/Tokens.brs, #262):
 * one type scale, one colour list and one row, so the screens read names and not literals. Sizes
 * are Apple TV points, drawn through `u()` and `sp()` at 1920x1080. Colours are opaque 0xRRGGBB:
 * white with an opacity is not a text colour, secondary text is TEXT_2, and TEXT_DIM is for the
 * guide grid only. A channel's own colour is never text. Every text colour is held to 4.5:1 on
 * the surfaces it sits on by DesignTokensTest.
 */
object DesignTokens {
    object Size {
        const val HERO = 96
        const val TITLE = 44
        const val HEADING = 34
        /** Row labels and values; nothing the viewer presses is smaller. */
        const val BODY = 29
        /** Section labels, hints, notes: the floor, nothing the viewer reads is smaller. */
        const val CAPTION = 25
        /** VT323 only (CH tags, countdowns, timestamps), measured by its visual size, so exempt from the floor. */
        const val TAG = 36
    }

    /** One step down, for Settings: caption stays 25. */
    object CompactSize {
        const val TITLE = 38
        const val HEADING = 29
        const val BODY = 25
        const val TAG = 31
    }

    /** The guide grid, an exception to the floor because it is dense. */
    object GuideSize {
        const val ROW = 22
        /** Times and the CHANNEL heading. */
        const val TIMES = 25
    }

    /** The Now Playing panel, an exception to the floor. */
    object PanelSize {
        const val TEXT = 22
        const val ITEM_TITLE = 29
        /** VT323. */
        const val TAG = 28
    }

    object Color {
        /** All primary text. */
        const val TEXT = 0xFFFFFF
        /** The main secondary grey: resting values, hints, labels, chevrons, OFF. */
        const val TEXT_2 = 0xB9C3DE
        /** The guide grid only: a programme title neither on now nor focused. */
        const val TEXT_DIM = 0x80879A
        /** Selection, ON, links, a focused chevron, the UP NEXT chip. */
        const val CYAN = 0x00D4FF
        /** Live status only (the sleep countdown). */
        const val YELLOW = 0xFFE500
        /** Warnings that need attention. */
        const val AMBER = 0xFFB020
        /** Danger as text. */
        const val RED_TEXT = 0xFF6B81
        /** Danger fill or outline only, never text on a row. */
        const val RED = 0xFF2244
        /** Text on a solid cyan fill. */
        const val ON_CYAN = 0x00101A
        /** Panel and rail background. */
        const val PANEL = 0x0A0F1E
        /** A resting row. */
        const val ROW = 0x141B33
        /** The row under the cursor. */
        const val SELECTED_ROW = 0x0B2A3A
        /** A row that is chosen but not under the cursor. */
        const val CHOSEN_NEUTRAL = 0x2B3760
        /** A resting row's outline: a boundary, not text. */
        const val RESTING_OUTLINE = 0x3A4670
        /** The bare guide background. */
        const val GUIDE = 0x0D0D1F
        /** The lightest guide row background: white at 5% over the guide (the issue's 4.83:1 for TEXT_DIM). */
        const val GUIDE_ROW_LIGHTEST = 0x19192A
    }

    /** Row geometry, in points. */
    object Row {
        const val CORNER = 12
        const val RESTING_OUTLINE = 1.5f
        const val SELECTED_OUTLINE = 3
        const val GLOW_RADIUS = 30
        const val GLOW_ALPHA = 0.55f
        const val LIFT = 1.03f
    }

    /** WCAG relative luminance of an opaque 0xRRGGBB colour. */
    fun luminance(rgb: Int): Double {
        fun channel(shift: Int): Double {
            val c = ((rgb shr shift) and 0xFF) / 255.0
            return if (c <= 0.03928) c / 12.92 else Math.pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    /** WCAG contrast ratio, 1 to 21. */
    fun contrast(a: Int, b: Int): Double {
        val la = luminance(a)
        val lb = luminance(b)
        return (maxOf(la, lb) + 0.05) / (minOf(la, lb) + 0.05)
    }

    /** Text on a solid channel-coloured fill: black or white, whichever has more contrast. */
    fun textOn(fill: Int): Int = if (contrast(0x000000, fill) >= contrast(0xFFFFFF, fill)) 0x000000 else 0xFFFFFF
}
