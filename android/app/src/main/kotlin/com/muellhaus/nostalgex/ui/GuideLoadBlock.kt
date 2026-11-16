package com.muellhaus.nostalgex.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.tv.material3.Text
import com.muellhaus.nostalgex.AppModel
import com.muellhaus.nostalgex.engine.DesignTokens
import com.muellhaus.nostalgex.engine.GuideLoad

/**
 * The loading pattern's empty guide state (Chad, 2026-11-15; the same on every platform): while a library is read in front of the guide
 * the guide area holds one centred block. A yellow title (CHANNEL GUIDE IS CHANGING after a server or library switch), what has been
 * read so far in text-2, the library being read under it, and a cyan indicator that moves. A stalled read says so here too, with STOP
 * WAITING, never over the video.
 */
@Composable
internal fun GuideLoadBlock(model: AppModel, load: GuideLoad) {
    Box(Modifier.fillMaxSize().background(GuideBackground), contentAlignment = Alignment.Center) {
        Column(
            Modifier.widthIn(max = u(900)).semantics(mergeDescendants = true) { contentDescription = listOfNotNull(load.title, load.readLine, load.detail.ifEmpty { null }).joinToString(". ") },
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(u(14)),
        ) {
            Text(load.title, style = font(DMMonoMedium, DesignTokens.Size.HEADING, Tokens.Yellow, tracking = 1), textAlign = TextAlign.Center, maxLines = 1)
            load.readLine?.let { Text(it, style = font(DMMono, DesignTokens.Size.CAPTION, Tokens.Text2), maxLines = 1) }
            if (load.detail.isNotEmpty()) {
                Text(load.detail, style = font(DMMono, DesignTokens.Size.CAPTION, Tokens.Text2.copy(alpha = 0.7f)), textAlign = TextAlign.Center, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            LoadingBar(Modifier.padding(top = u(8)))
            // The scan has gone quiet (LoadingView.stallBlock): the notice and the way out are here. STOP WAITING takes focus as it appears.
            if (model.loadStalling) {
                Text(
                    "Still waiting on your server. Nothing has come back for a while.",
                    style = font(DMMono, DesignTokens.Size.CAPTION, Tokens.Text2), textAlign = TextAlign.Center,
                    modifier = Modifier.padding(top = u(12)),
                )
                OnboardingButton("STOP WAITING", primary = true, focusFirst = true, fontSize = 22, onClick = model::stopWaitingForLibraryScan)
                Text(
                    "Keeps whatever has loaded so far and finishes the rest later.",
                    style = font(DMMono, DesignTokens.Size.CAPTION, Tokens.Text2.copy(alpha = 0.7f)), textAlign = TextAlign.Center,
                )
            }
        }
    }
}

/** A cyan segment sliding along a faint track: it moves while the read goes on, and says nothing it does not know. */
@Composable
private fun LoadingBar(modifier: Modifier = Modifier) {
    val trackWidth = 420f
    val segment = 120f
    val transition = rememberInfiniteTransition(label = "guide load")
    val x by transition.animateFloat(
        initialValue = 0f,
        targetValue = trackWidth - segment,
        animationSpec = infiniteRepeatable(tween(durationMillis = 1100, easing = LinearEasing), RepeatMode.Reverse),
        label = "segment",
    )
    Box(modifier.width(u(trackWidth)).height(u(4)).clip(RoundedCornerShape(u(2))).background(Color.White.copy(alpha = 0.15f))) {
        Box(Modifier.offset(x = u(x)).width(u(segment)).height(u(4)).background(Tokens.Cyan))
    }
}
