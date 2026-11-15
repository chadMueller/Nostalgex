package com.muellhaus.nostalgex.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.tv.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import com.muellhaus.nostalgex.engine.GuideStripes

/** One row's piece of the stripe, drawn in the slot at the left of the row (GuideStripeCell). */
@Composable
internal fun GuideStripeCell(cell: GuideStripes.RowCell?, modifier: Modifier = Modifier) {
    Box(modifier.width(u(GuideStripes.STRIPE_WIDTH)).fillMaxHeight().background(cell?.hex?.let { hex(it) } ?: Color.White.copy(alpha = 0.10f))) {
        // The first row of a run gets a thin dark line above it, so two stripes never run together.
        if (cell?.startsRun == true) Box(Modifier.height(u(2)).width(u(GuideStripes.STRIPE_WIDTH)).background(Tokens.Guide).align(Alignment.TopStart))
    }
}

/** The lift of the focused stripe out of its slot, over the row's left edge (GuideStripeOverlay.liftWidth). */
private const val LIFT_WIDTH = 38f

/**
 * The names written up the stripe and the ring when the stripe has focus (GuideStripeOverlay). Sticky: each
 * name sits in the part of its bundle that is on screen, so it stays readable while the viewer scrolls
 * through the bundle's channels. It takes no focus and no touch.
 *
 * @param leading height above the first channel row (the seasonal invite, when it is on).
 */
@Composable
internal fun GuideStripeOverlay(
    groups: List<GuideStripes.Group>,
    listState: LazyListState,
    leading: Float,
    hasInvite: Boolean,
    /** A channel row with its divider, in Apple TV points: it follows the text step. */
    rowPitch: Float,
    focusedGroup: Int?,
) {
    val unitPx = with(LocalDensity.current) { LocalUnit.current.toPx() }
    val first = listState.firstVisibleItemIndex
    val inItem = listState.firstVisibleItemScrollOffset / unitPx
    // The guide's scroll position in points from the top of the first channel row's list.
    val offset = (if (!hasInvite) first * rowPitch else if (first == 0) 0f else leading + (first - 1) * rowPitch) + inItem
    val viewport = listState.layoutInfo.viewportSize.height / unitPx
    val labels = GuideStripes.labels(groups, rowPitch, leading, offset, viewport)
    Box(Modifier.width(u(LIFT_WIDTH + 20)).fillMaxHeight().clipToBounds()) {
        if (focusedGroup != null && focusedGroup in groups.indices) {
            val name = groups[focusedGroup].name
            val span = name?.let { GuideStripes.visibleSpan(groups[focusedGroup], rowPitch, leading, offset, viewport) }
            if (span != null) {
                val lifted = hex(GuideStripes.Palette.focusedHex(GuideStripes.Palette.hex(name)))
                Box(
                    Modifier.offset(y = u(span.first)).width(u(LIFT_WIDTH)).height(u(span.second))
                        .cyanGlow()
                        .background(lifted, RoundedCornerShape(u(8)))
                        .border(u(5), Tokens.Cyan, RoundedCornerShape(u(8))),
                )
            }
        }
        for (label in labels) {
            val isFocused = label.groupIndex == focusedGroup
            val black = GuideStripes.Palette.nameIsBlack(GuideStripes.Palette.hex(label.name).let { if (isFocused) GuideStripes.Palette.focusedHex(it) else it })
            Box(
                Modifier.offset(y = u(label.top)).width(u(if (isFocused) LIFT_WIDTH else GuideStripes.STRIPE_WIDTH)).height(u(label.height)),
                contentAlignment = Alignment.Center,
            ) {
                // A name written up the stripe: laid out as a line as long as the span, then turned.
                Text(
                    label.name,
                    style = font(DMMonoMedium, 25, if (black) Color.Black else Tokens.Text, tracking = 1).copy(textAlign = TextAlign.Center),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.requiredSize(u(maxOf(label.height - 16, 0f)), u(GuideStripes.STRIPE_WIDTH)).rotate(-90f),
                )
            }
        }
    }
}
