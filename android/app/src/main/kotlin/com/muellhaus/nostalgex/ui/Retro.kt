package com.muellhaus.nostalgex.ui

import android.graphics.Bitmap
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.animation.core.Animatable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.tv.material3.Text
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.max
import kotlin.math.min
import kotlin.random.Random

// RETRO MODE's look: CRTOverlayView.swift and StaticScreenView.swift, at the Apple TV's numbers.

/** How strong the look is, as RetroLook (picked on a living room TV on 2026-10-18; the Roku matches). */
private object RetroLook {
    const val SCANLINE_OPACITY = 0.18f
    const val CORNER_SHADOW = 0.78f
    const val TOP_BOTTOM_SHADOW = 0.58f
    const val SIDE_SHADOW = 0.48f
    /** Chance per 80 ms tick that the scanlines dip, and how far. */
    const val FLICKER_CHANCE = 0.08
    val FLICKER_RANGE = 0.76f..0.88f
    /** Chance that a tracking line runs at each 6 to 15 s check, and its brightness. */
    const val GLITCH_CHANCE = 0.45
    const val GLITCH_BRIGHTNESS = 0.22f
}

/** Scanlines, vignette, flicker and the VHS tracking line, over the picture. */
@Composable
internal fun CrtOverlay() {
    var flicker by remember { mutableFloatStateOf(1f) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(80)
            if (Random.nextDouble() > 1 - RetroLook.FLICKER_CHANCE) {
                flicker = Random.nextDouble(RetroLook.FLICKER_RANGE.start.toDouble(), RetroLook.FLICKER_RANGE.endInclusive.toDouble()).toFloat()
                delay(60)
                flicker = 1f
            }
        }
    }
    // The tracking line: from a random height, moving down 150 to 400 points over 0.5 to 1.5 s.
    var glitchFrom by remember { mutableFloatStateOf(0f) }
    var glitchOn by remember { mutableStateOf(false) }
    val travel = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(Random.nextLong(6_000, 15_000))
            if (Random.nextDouble() > 1 - RetroLook.GLITCH_CHANCE) {
                val duration = Random.nextInt(500, 1_500)
                glitchFrom = Random.nextInt(-200, 200).toFloat()
                travel.snapTo(0f)
                glitchOn = true
                travel.animateTo(Random.nextInt(150, 400).toFloat(), tween(duration, easing = LinearEasing))
                glitchOn = false
            }
        }
    }

    val unit = u(1)
    Box(Modifier.fillMaxSize()) {
        // Scanlines every 3 points, 1.5 wide; the path is built once per size.
        Box(
            Modifier
                .fillMaxSize()
                .graphicsLayer { alpha = flicker }
                .drawWithCache {
                    val spacing = 3 * unit.toPx()
                    val path = Path()
                    var y = 0f
                    while (y < size.height) {
                        path.moveTo(0f, y)
                        path.lineTo(size.width, y)
                        y += spacing
                    }
                    val stroke = Stroke(width = 1.5f * unit.toPx())
                    onDrawBehind { drawPath(path, Color.Black.copy(alpha = RetroLook.SCANLINE_OPACITY), style = stroke) }
                },
        )
        if (glitchOn) {
            Canvas(Modifier.fillMaxSize()) {
                val u1 = unit.toPx()
                val top = size.height * 0.5f + (glitchFrom + travel.value) * u1
                val b = RetroLook.GLITCH_BRIGHTNESS
                // A thin bright band, and a fainter one beneath.
                drawRect(
                    Brush.verticalGradient(
                        listOf(Color.Transparent, Color.White.copy(alpha = b * 0.53f), Color.White.copy(alpha = b), Color.White.copy(alpha = b * 0.53f), Color.Transparent),
                        startY = top, endY = top + 12 * u1,
                    ),
                    topLeft = Offset(0f, top), size = Size(size.width, 12 * u1),
                )
                drawRect(
                    Brush.verticalGradient(listOf(Color.White.copy(alpha = b * 0.2f), Color.Transparent), startY = top + 12 * u1, endY = top + 42 * u1),
                    topLeft = Offset(0f, top + 12 * u1), size = Size(size.width, 30 * u1),
                )
            }
        }
        // The vignette: heavy corners, darker top and bottom, lighter sides.
        Canvas(Modifier.fillMaxSize()) {
            val w = size.width
            val h = size.height
            val start = min(w, h) * 0.3f
            val end = max(w, h) * 0.7f
            // SwiftUI's three stops spread from startRadius to endRadius.
            drawRect(
                Brush.radialGradient(
                    0f to Color.Transparent,
                    (start + end) / 2 / end to Color.Transparent,
                    1f to Color.Black.copy(alpha = RetroLook.CORNER_SHADOW),
                    center = center, radius = end,
                ),
            )
            val tb = Color.Black.copy(alpha = RetroLook.TOP_BOTTOM_SHADOW)
            drawRect(Brush.verticalGradient(listOf(tb, Color.Transparent), endY = h * 0.08f), size = Size(w, h * 0.08f))
            drawRect(Brush.verticalGradient(listOf(Color.Transparent, tb), startY = h * 0.92f, endY = h), topLeft = Offset(0f, h * 0.92f), size = Size(w, h * 0.08f))
            val side = Color.Black.copy(alpha = RetroLook.SIDE_SHADOW)
            drawRect(Brush.horizontalGradient(listOf(side, Color.Transparent), endX = w * 0.06f), size = Size(w * 0.06f, h))
            drawRect(Brush.horizontalGradient(listOf(Color.Transparent, side), startX = w * 0.94f, endX = w), topLeft = Offset(w * 0.94f, 0f), size = Size(w * 0.06f, h))
        }
        // The screen's edge glow.
        Box(Modifier.fillMaxSize().border(u(2), Color.White.copy(alpha = 0.04f), RoundedCornerShape(u(12))))
    }
}

/**
 * Shown only when a tune is still loading after 0.75 s, so a fast start never flashes it.
 * Retro mode gets the snow; with it off, a plain dim card.
 */
@Composable
internal fun TuningOverlay(loading: Boolean, retro: Boolean, channelNumber: Int?) {
    var show by remember { mutableStateOf(false) }
    LaunchedEffect(loading) {
        if (loading) {
            delay(750)
            show = true
        } else show = false
    }
    AnimatedVisibility(show, enter = fadeIn(tween(350)), exit = fadeOut(tween(350))) {
        val label = channelNumber?.let { "TUNING · CH $it" } ?: "TUNING"
        if (retro) StaticScreen(label) else {
            Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
                Text(label, style = font(DMMonoMedium, 24, Color.White.copy(alpha = 0.35f)))
            }
        }
    }
}

/**
 * The snow: 4-point blocks of grey at 0.45 alpha, from the Apple TV's generator (a 64-bit LCG
 * from a seed stepped every 70 ms), faint at 0.32 and settling to 0.14 after 0.9 s. Drawn as
 * one small bitmap scaled up rather than a rectangle per block.
 */
@Composable
private fun StaticScreen(label: String) {
    var seed by remember { mutableIntStateOf(0) }
    var settled by remember { mutableStateOf(false) }
    val opacity by animateFloatAsState(if (settled) 0.14f else 0.32f, tween(700), label = "snow")
    LaunchedEffect(Unit) {
        launch {
            delay(900)
            settled = true
        }
        while (true) {
            delay(70)
            seed++
        }
    }
    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
        val blockPx = with(androidx.compose.ui.platform.LocalDensity.current) { u(4).toPx() }
        val cols = max(1, (constraints.maxWidth / blockPx).toInt())
        val rows = max(1, (constraints.maxHeight / blockPx).toInt())
        val bitmap = remember(cols, rows) { Bitmap.createBitmap(cols, rows, Bitmap.Config.ARGB_8888) }
        val pixels = remember(cols, rows) { IntArray(cols * rows) }
        Canvas(Modifier.fillMaxSize().graphicsLayer { alpha = opacity }) {
            var rng = seed.toULong()
            for (i in pixels.indices) {
                rng = rng * 6364136223846793005uL + 1442695040888963407uL
                val b = ((rng shr 33) % 256uL).toInt()
                pixels[i] = (115 shl 24) or (b shl 16) or (b shl 8) or b
            }
            bitmap.setPixels(pixels, 0, cols, 0, 0, cols, rows)
            drawImage(
                bitmap.asImageBitmap(),
                srcOffset = IntOffset.Zero, srcSize = IntSize(cols, rows),
                dstOffset = IntOffset.Zero, dstSize = IntSize((cols * blockPx).toInt(), (rows * blockPx).toInt()),
                filterQuality = FilterQuality.None,
            )
        }
        Text(label, style = font(DMMonoMedium, 26, Color.White.copy(alpha = 0.42f)))
    }
}
