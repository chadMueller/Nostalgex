package com.muellhaus.nostalgex.engine

import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * Bundle stripes in the guide: a coloured stripe down the left edge of the guide with the bundle
 * name written up it. A port of the Apple TV's `Models/GuideStripes.swift` (and the Roku's
 * `source/guide/GuideStripes.brs`). Everything here is pure: which bundle a channel is in, the runs
 * of channels that make a stripe, the colour of a name, and where a label sits in the viewport. No
 * stored data; all of it is worked out from the lineup on screen.
 *
 * The colour of a name must be the same on every launch and every device, so the hash is written
 * out (FNV-1a over the upper-cased UTF-8 name) and pinned by GuideStripesTest.
 */
object GuideStripes {
    /** A bundle as the stripe names it. */
    data class GuideBundle(val id: String, val name: String)

    /**
     * A run of consecutive guide rows in the same bundle (or in none). A bundle can come back as a
     * second run if the guide lists its channels apart; each run is its own stripe.
     */
    data class Group(
        /** Null for channels in no bundle on screen: their stripe has no name. */
        val bundle: GuideBundle?,
        val firstRow: Int,
        val rowCount: Int,
    ) {
        val lastRow: Int get() = firstRow + rowCount - 1
        val name: String? get() = bundle?.name
    }

    /** What one row draws in the stripe's column: its colour (null for a plain stripe) and whether it starts a run. */
    data class RowCell(val hex: String?, val startsRun: Boolean)

    /** A name written up the stripe: its span in the viewport, and the name. */
    data class Label(val groupIndex: Int, val name: String, val top: Float, val height: Float)


    /**
     * Channel id to bundle, for the bundles that are on. A channel is in the first bundle, in the order of
     * `bundles`, that lists it. FRANCHISES is one bundle holding every franchise channel: the stock classics,
     * the franchises found in the library and the server's franchise collections, named by the stock bundle
     * when it is on.
     */
    fun membership(
        bundles: List<ChannelConfig.Bundle>,
        enabledBundleIDs: Set<String>,
        foundFranchiseChannelIDs: List<Int>,
        franchisesBundleID: String,
        franchiseCollectionsBundleID: String,
    ): Map<Int, GuideBundle> {
        val franchiseIDs = setOf(franchisesBundleID, franchiseCollectionsBundleID)
        val entries = mutableListOf<Pair<GuideBundle, MutableList<Int>>>()
        for (bundle in bundles) {
            if (bundle.id !in enabledBundleIDs) continue
            val ids = bundle.channelIDs.toMutableList()
            if (bundle.id == franchisesBundleID) ids += foundFranchiseChannelIDs
            if (bundle.id in franchiseIDs) {
                val i = entries.indexOfFirst { it.first.id in franchiseIDs }
                if (i >= 0) {
                    val merged = entries[i].second.apply { addAll(ids) }
                    val named = if (bundle.id == franchisesBundleID) GuideBundle(bundle.id, bundle.name) else entries[i].first
                    entries[i] = named to merged
                    continue
                }
            }
            entries += GuideBundle(bundle.id, bundle.name) to ids
        }
        val result = HashMap<Int, GuideBundle>()
        for ((b, ids) in entries) for (id in ids) if (id !in result) result[id] = b
        return result
    }

    /** The stripes: consecutive rows with the same bundle, in guide order. A channel in no bundle is a run with no name. */
    fun groups(channelIDs: List<Int>, membership: Map<Int, GuideBundle>): List<Group> {
        val out = mutableListOf<Group>()
        var bundle: GuideBundle? = null
        var first = 0
        var count = 0
        for ((row, id) in channelIDs.withIndex()) {
            val b = membership[id]
            if (count > 0 && b == bundle) {
                count += 1
            } else {
                if (count > 0) out += Group(bundle, first, count)
                bundle = b; first = row; count = 1
            }
        }
        if (count > 0) out += Group(bundle, first, count)
        return out
    }

    /** The run row `row` is in, or null. */
    fun groupIndexContainingRow(row: Int, groups: List<Group>): Int? =
        groups.indexOfFirst { it.firstRow <= row && row <= it.lastRow }.takeIf { it >= 0 }

    /**
     * The previous (`step` -1) or next (+1) run that is a bundle, from run `index`. Runs with no bundle are
     * stepped over, and there is no wrap: past the first or last bundle there is nowhere to go (null).
     */
    fun neighbourIndex(from: Int, step: Int, groups: List<Group>): Int? {
        require(step == 1 || step == -1)
        var i = from + step
        while (i in groups.indices) {
            if (groups[i].bundle != null) return i
            i += step
        }
        return null
    }

    /**
     * Up or Down on the stripe with a wrap, as the channel rows have it: past the last bundle the first, before the first the
     * last (Chad 2026-11-15: "reaching the bottom should take you back to the top"). Runs with no bundle are stepped over. Null
     * when there is no other bundle to go to.
     */
    fun neighbourIndexWrapping(from: Int, step: Int, groups: List<Group>): Int? {
        neighbourIndex(from, step, groups)?.let { return it }
        val named = groups.indices.filter { groups[it].bundle != null }
        val target = (if (step > 0) named.firstOrNull() else named.lastOrNull()) ?: return null
        return target.takeIf { it != from }
    }

    /** Whether there is any bundle to move between. With none, Left goes to the bundle list as it always did. */
    fun hasBundles(groups: List<Group>): Boolean = groups.any { it.bundle != null }

    fun rowCells(groups: List<Group>, count: Int): List<RowCell> {
        val cells = MutableList(count) { RowCell(null, false) }
        for (g in groups) {
            val hex = g.name?.let { Palette.hex(it) }
            for (row in g.firstRow..g.lastRow) if (row in cells.indices) cells[row] = RowCell(hex, row == g.firstRow)
        }
        return cells
    }

    object Palette {
        /** The ten colours a stripe can be, all taken from the channel colours the app already uses. */
        val hexes: List<String> = listOf(
            "#FF2DB4", "#E74C3C", "#E67E22", "#F1C40F", "#2ECC71",
            "#2DC7B0", "#00BFFF", "#7B68EE", "#8E44AD", "#B9770E",
        )

        /** FNV-1a over the upper-cased name, its two halves folded together, modulo the palette. */
        fun index(name: String): Int {
            var hash = 0x811c9dc5u
            for (byte in name.uppercase(java.util.Locale.ROOT).toByteArray(Charsets.UTF_8)) {
                hash = hash xor (byte.toInt() and 0xFF).toUInt()
                hash *= 0x01000193u
            }
            val folded = (hash shr 16) xor (hash and 0xFFFFu)
            return (folded % hexes.size.toUInt()).toInt()
        }

        fun hex(name: String): String = hexes[index(name)]

        private fun value(hex: String): Int = hex.removePrefix("#").toIntOrNull(16) ?: 0

        /** WCAG relative luminance of a "#RRGGBB" colour. */
        fun luminance(hex: String): Double {
            val v = value(hex)
            fun channel(shift: Int): Double {
                val c = ((v shr shift) and 0xFF) / 255.0
                return if (c <= 0.03928) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)
            }
            return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        }

        fun contrast(a: Double, b: Double): Double = (max(a, b) + 0.05) / (min(a, b) + 0.05)

        /** Black or white, whichever reads better on the stripe. Never below 4.5 to 1 on any colour. */
        fun nameIsBlack(hex: String): Boolean {
            val l = luminance(hex)
            return contrast(l, 0.0) >= contrast(l, 1.0)
        }

        /** The stripe's colour while it has focus: a fifth of the way to white (22%), so it reads brighter than its neighbours. */
        fun focusedHex(hex: String): String {
            val v = value(hex)
            fun lift(shift: Int): Int {
                val c = ((v shr shift) and 0xFF).toDouble()
                return (c + (255 - c) * 0.22).roundToInt()
            }
            return "#%02X%02X%02X".format(lift(16), lift(8), lift(0))
        }

        fun nameContrast(hex: String): Double {
            val l = luminance(hex)
            return max(contrast(l, 0.0), contrast(l, 1.0))
        }
    }

    /** Width of the stripe, in Apple TV points. It sits in the slot at the left of every row, so it takes nothing from names or programmes. */
    const val STRIPE_WIDTH = 28f

    /** A span too short to show even a couple of letters has no label. */
    const val MINIMUM_LABEL_HEIGHT = 44f

    /**
     * The part of a run that is on screen, in the viewport's own coordinates (0 at the top of the rows), or null.
     * A bundle whose first rows have scrolled away still has its name and its ring on the rows that are left.
     */
    fun visibleSpan(group: Group, rowPitch: Float, leading: Float, offset: Float, viewport: Float): Pair<Float, Float>? {
        val top = leading + group.firstRow * rowPitch
        val bottom = top + group.rowCount * rowPitch
        val visibleTop = max(top, offset)
        val visibleBottom = min(bottom, offset + viewport)
        if (visibleBottom <= visibleTop) return null
        return (visibleTop - offset) to (visibleBottom - visibleTop)
    }

    fun labels(groups: List<Group>, rowPitch: Float, leading: Float, offset: Float, viewport: Float): List<Label> =
        groups.mapIndexedNotNull { index, g ->
            val name = g.name ?: return@mapIndexedNotNull null
            val span = visibleSpan(g, rowPitch, leading, offset, viewport) ?: return@mapIndexedNotNull null
            if (span.second < MINIMUM_LABEL_HEIGHT) null else Label(index, name, span.first, span.second)
        }
}
