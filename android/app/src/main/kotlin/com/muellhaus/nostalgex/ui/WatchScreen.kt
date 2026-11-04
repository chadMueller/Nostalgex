package com.muellhaus.nostalgex.ui

import android.view.KeyEvent as AndroidKeyEvent
import android.view.LayoutInflater
import androidx.annotation.OptIn
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusable
import androidx.compose.foundation.focusGroup
import androidx.compose.ui.focus.focusProperties
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.nativeKeyCode
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.layout.widthIn
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.zIndex
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import androidx.tv.material3.Text
import com.muellhaus.nostalgex.AppModel
import com.muellhaus.nostalgex.R
import com.muellhaus.nostalgex.engine.DailyManifest
import com.muellhaus.nostalgex.engine.GuideChannel
import com.muellhaus.nostalgex.engine.ChannelConfig
import com.muellhaus.nostalgex.engine.MediaItem
import com.muellhaus.nostalgex.engine.PlaybackFailure
import com.muellhaus.nostalgex.engine.Schedule
import com.muellhaus.nostalgex.engine.Season
import com.muellhaus.nostalgex.engine.ScheduleEntry
import kotlinx.coroutines.delay
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

// The Apple TV app's tuner (TunerView.swift, InfoPanelView.swift, ChannelGuideView.swift) and
// full screen (PlayerView.swift), at its measurements. Sizes are the Apple TV's points on a
// 1920 x 1080 screen, scaled to this one by LocalUnit.

/** One Apple TV point at 1920 x 1080, on this screen. */
internal val LocalUnit = staticCompositionLocalOf { 0.5.dp }

@Composable
internal fun u(n: Number): Dp = LocalUnit.current * n.toFloat()

@Composable
internal fun sp(n: Number): TextUnit = with(LocalDensity.current) { (LocalUnit.current * n.toFloat()).toSp() }

@Composable
internal fun font(family: FontFamily, size: Number, color: Color, tracking: Number = 0) =
    TextStyle(fontFamily = family, fontSize = sp(size), color = color, letterSpacing = sp(tracking))

internal fun hex(s: String?): Color =
    runCatching { Color(android.graphics.Color.parseColor(s ?: "#FFE500")) }.getOrDefault(Color(0xFFFFE500))

private val GuideBackground = Color(0.05f, 0.05f, 0.12f)
private val PanelTop = Color(0.04f, 0.04f, 0.10f)
internal val BrandCyan = Color(0f, 0.831f, 1f)
private val Yellow = Color(0xFFFFE500)

private const val CHANNEL_COLUMN = 220
private const val ROW_HEIGHT = 80
private const val HEADER_HEIGHT = 60
/** 24-hour horizon in 30-minute slots, four visible: Left and Right scroll up to 44 slots on. */
private const val MAX_SLOT_OFFSET = 44
private const val VISIBLE_SECONDS = 7200L
/** The seasonal invite's focus id (ChannelGuideView.seasonalRowID): no channel's id is negative. */
private const val SEASONAL_ROW_ID = -900

private val clock = DateTimeFormatter.ofPattern("h:mm a")
private fun time(sec: Long) = clock.format(Instant.ofEpochSecond(sec).atZone(ZoneId.systemDefault()))

internal fun formatTime(totalSeconds: Long): String {
    val h = totalSeconds / 3600
    val m = (totalSeconds % 3600) / 60
    val s = totalSeconds % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}

private fun nowSec() = System.currentTimeMillis() / 1000.0

/** The seconds clock the progress bars, the OSD and the now line read. */
@Composable
internal fun ticking(): Double {
    var now by remember { mutableStateOf(nowSec()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(1000 - System.currentTimeMillis() % 1000)
            now = nowSec()
        }
    }
    return now
}

/**
 * The tuner, or full screen. One PlayerView serves both: it sits in the tuner's 4:3 box and
 * fills the screen in full screen, so changing modes never restarts the stream.
 */
@OptIn(UnstableApi::class)
@Composable
fun WatchScreen(model: AppModel) {
    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black)) {
        val unit = maxWidth / 1920f
        CompositionLocalProvider(LocalUnit provides unit, LocalGuideText provides if (model.guideTextLarge) GuideText.LARGE else GuideText.NORMAL) {
            val height = maxHeight / unit
            // TunerView: the top section is 51.43% of the screen; the picture is 4:3 at that height.
            val videoHeight = height * 0.5143f
            val videoWidth = minOf(1920f, videoHeight * 4f / 3f)
            val panelWidth = 1920f - videoWidth

            // The row the guide should put focus on, and a counter that asks it to.
            var focusTarget by remember { mutableIntStateOf(model.channel?.id ?: -1) }
            var focusRequest by remember { mutableIntStateOf(0) }
            var focusedId by remember { mutableStateOf<Int?>(null) }
            var osdUntil by remember { mutableLongStateOf(0L) }
            var overlay by remember { mutableStateOf(Overlay.NONE) }
            var picker by remember { mutableStateOf<PanelPicker?>(null) }
            var sidebarOpen by remember { mutableStateOf(false) }
            /** The seasonal package the invite's question is asking about (ChannelGuideView's confirmationDialog). */
            var asking by remember { mutableStateOf<ChannelConfig.Bundle?>(null) }
            fun flashOsd() { osdUntil = System.currentTimeMillis() + 8000 }
            fun focusLive() {
                focusTarget = model.channel?.id ?: return
                focusRequest++
            }

            // The OSD shows on entering full screen and on each new programme (PlayerView's onAppear, onChange of currentItem).
            LaunchedEffect(model.tuneCount, model.fullScreen, model.item) { if (model.fullScreen) flashOsd() }
            LaunchedEffect(model.fullScreen) { if (!model.fullScreen) overlay = Overlay.NONE }
            LaunchedEffect(overlay) { if (overlay != Overlay.PANEL) picker = null }

            // Back closes the strip or the panel first (PlayerView's onExitCommand), then leaves full
            // screen; in the guide it goes to the live row, and from there leaves the app
            // (GuideExitAction), which is when nothing here takes it.
            val backTakes = model.sleepGrace || asking != null || model.settingsOpen || sidebarOpen || model.fullScreen ||
                (focusedId != null && focusedId != model.channel?.id)
            fun back() {
                when {
                    // "STILL WATCHING?" takes the next key, Back included (SleepGracePrompt).
                    model.sleepGrace -> model.keepAwake()
                    // The invite's question: Back closes it, focus back on the invite.
                    asking != null -> { asking = null; focusTarget = SEASONAL_ROW_ID; focusRequest++ }
                    // Settings steps back one level at a time; from the rail it closes, back to the live row.
                    model.settingsOpen -> if (!model.settingsBack()) focusLive()
                    // The package sidebar closes back to the guide (BundleJumpSidebar's onExitCommand).
                    sidebarOpen -> { sidebarOpen = false; focusLive() }
                    // An open picker first: dropping out of the panel from inside a list would lose it on a mis-press.
                    model.fullScreen && picker != null -> picker = null
                    model.fullScreen && overlay != Overlay.NONE -> overlay = Overlay.NONE
                    model.fullScreen -> { model.fullScreen = false; focusLive() }
                    else -> focusLive()
                }
            }

            Box(
                Modifier
                    .fillMaxSize()
                    .onBack(backTakes) { back() }
                    .onPreviewKeyEvent { e ->
                        val code = e.key.nativeKeyCode
                        val up = e.type == KeyEventType.KeyUp
                        // "STILL WATCHING?" takes the next key, whatever it is (SleepGracePrompt).
                        if (model.sleepGrace) {
                            if (up) model.keepAwake()
                            return@onPreviewKeyEvent true
                        }
                        when (code) {
                            // Play/Pause goes full screen from the guide, and shows the OSD there.
                            AndroidKeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> {
                                if (up) { if (model.fullScreen) flashOsd() else if (model.channel != null) model.fullScreen = true }
                                true
                            }
                            else -> false
                        }
                    },
            ) {
                // Settings replaces the tuner; the programme plays on behind it, muted.
                if (model.settingsOpen) {
                    SettingsPage(model)
                    return@Box
                }
                if (!model.fullScreen) {
                    Tuner(
                        model = model,
                        panelWidth = panelWidth,
                        videoHeight = videoHeight,
                        focusTarget = focusTarget,
                        focusRequest = focusRequest,
                        onFocused = { focusedId = it },
                        onFocusTarget = { focusTarget = it; focusRequest++ },
                        sidebarOpen = sidebarOpen,
                        onSidebar = { sidebarOpen = it },
                        onInvite = { asking = it },
                    )
                }

                Box(
                    // Clipped here: the zoomed picture is wider than the box, and the PlayerView
                    // drew the overflow over the info panel.
                    (if (model.fullScreen) Modifier.fillMaxSize()
                    else Modifier.offset(x = u(panelWidth)).size(u(videoWidth), u(videoHeight))).clipToBounds(),
                ) {
                    Box(Modifier.fillMaxSize().background(Color(0.02f, 0.02f, 0.05f)))
                    // RETRO MODE is on by default on the Apple TV: the picture fills its box
                    // (.resizeAspectFill), which crops a wide film to 4:3 in the tuner. Each mode
                    // has its own surface (see the layouts); the player moves between them
                    // without restarting.
                    val layout = if (model.fullScreen) R.layout.player_surface else R.layout.player_texture
                    key(layout) {
                        AndroidView(
                            factory = { ctx ->
                                (LayoutInflater.from(ctx).inflate(layout, null) as PlayerView).apply {
                                    keepScreenOn = true
                                    player = model.playback.player
                                }
                            },
                            update = {
                                it.resizeMode = if (model.retroMode) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT
                            },
                            onRelease = { it.player = null },
                            modifier = Modifier.fillMaxSize().clipToBounds(),
                        )
                    }
                    // RETRO MODE's CRT look over the picture, then the tuning card on a slow start.
                    if (model.retroMode) CrtOverlay()
                    TuningOverlay(
                        loading = model.item != null && model.delivery == null && model.failure == null,
                        retro = model.retroMode,
                        channelNumber = model.channel?.number,
                    )
                    // Smaller in the guide's box than in full screen, as the Apple TV's.
                    model.failure?.let { FailureCard(it, compact = !model.fullScreen) }
                    if (model.watershedHold) WatershedCard(compact = !model.fullScreen)
                }

                if (model.fullScreen) {
                    FullScreen(model, osdUntil = osdUntil, overlay = overlay, onOverlay = { overlay = it }, picker = picker, onPicker = { picker = it }, onFlash = ::flashOsd)
                }
                asking?.let { offer ->
                    if (!model.fullScreen) SeasonalQuestion(offer) { answer ->
                        asking = null
                        model.answerSeasonalPrompt(answer, offer)
                        // Answered, the invite goes: focus to the live row.
                        focusLive()
                    }
                }
                if (model.sleepGrace) SleepGracePrompt(model)
            }
        }
    }
}

// ── Full screen (PlayerView.swift) ───────────────────────────────────────

/** What full screen has open over the picture. */
internal enum class Overlay { NONE, STRIP, PANEL }


@Composable
private fun FullScreen(
    model: AppModel,
    osdUntil: Long,
    overlay: Overlay,
    onOverlay: (Overlay) -> Unit,
    picker: PanelPicker?,
    onPicker: (PanelPicker?) -> Unit,
    onFlash: () -> Unit,
) {
    val focus = remember { FocusRequester() }
    val now = ticking()
    Box(
        Modifier
            .fillMaxSize()
            .focusRequester(focus)
            .focusable()
            .onKeyEvent { e ->
                // With the strip or the panel open, their own rows take the keys.
                if (overlay != Overlay.NONE) return@onKeyEvent false
                val down = e.type == KeyEventType.KeyDown
                when (e.key.nativeKeyCode) {
                    // Left and Right change channel, wrapping (AppState.previousChannel/nextChannel).
                    AndroidKeyEvent.KEYCODE_DPAD_RIGHT, AndroidKeyEvent.KEYCODE_CHANNEL_UP -> { if (down) { model.nextChannel(); onFlash() }; true }
                    AndroidKeyEvent.KEYCODE_DPAD_LEFT, AndroidKeyEvent.KEYCODE_CHANNEL_DOWN -> { if (down) { model.previousChannel(); onFlash() }; true }
                    // Up: the mini channel strip, from the bottom. Down: Now Playing, from the top.
                    AndroidKeyEvent.KEYCODE_DPAD_UP -> { if (!down) onOverlay(Overlay.STRIP); true }
                    AndroidKeyEvent.KEYCODE_DPAD_DOWN -> { if (!down) onOverlay(Overlay.PANEL); true }
                    // OK flashes the OSD (live TV: nothing to pause).
                    AndroidKeyEvent.KEYCODE_DPAD_CENTER, AndroidKeyEvent.KEYCODE_ENTER, AndroidKeyEvent.KEYCODE_INFO -> { if (!down) onFlash(); true }
                    else -> false
                }
            },
    ) {
        val ch = model.channel
        val item = model.item
        // Always shown while nothing plays, for 8 s after a flash while something does.
        if (ch != null && item != null && (model.delivery == null || System.currentTimeMillis() < osdUntil)) {
            ChannelOsd(ch, item, model.lineup?.schedules?.get(ch.id), now)
        }
        when (overlay) {
            Overlay.STRIP -> MiniChannelStrip(model, onSelect = { picked ->
                model.tune(picked)
                onOverlay(Overlay.NONE)
                onFlash()
            })
            Overlay.PANEL -> if (ch != null && item != null) NowPlayingPanel(model, ch, item, picker, onPicker)
            Overlay.NONE -> {}
        }
    }
    // Focus comes back here whenever the strip or the panel closes.
    LaunchedEffect(overlay) { if (overlay == Overlay.NONE) runCatching { focus.requestFocus() } }
}

@Composable
private fun ChannelOsd(ch: GuideChannel, item: MediaItem, schedule: Schedule?, now: Double) {
    val color = hex(ch.def.colorHex)
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomStart) {
        Column(
            Modifier
                .background(Brush.horizontalGradient(listOf(Color.Black.copy(alpha = 0.85f), Color.Transparent)))
                .padding(u(32)),
            verticalArrangement = Arrangement.spacedBy(u(8)),
        ) {
            Box(Modifier.size(u(48), u(4)).background(color))
            Text("CH ${ch.number}", style = font(DMMonoMedium, 20, color))
            // The title leads and the channel name follows smaller: viewers read this as
            // "what's playing" (PlayerView's ChannelOSD, 02ac78f).
            val headline = font(DMMonoMedium, 32, Color.White.copy(alpha = 0.95f))
            when {
                item.type == "episode" && item.episodeTitle != null ->
                    Text("${item.title}  ${item.seTag ?: ""}  \"${item.episodeTitle}\"", style = headline)
                item.isMusicVideo -> Column(verticalArrangement = Arrangement.spacedBy(u(4))) {
                    Text(item.title, style = headline)
                    item.artist?.takeIf { it.isNotEmpty() }?.let { Text(it, style = font(DMMonoMedium, 32, Color.White.copy(alpha = 0.7f))) }
                    val facts = listOfNotNull(item.year?.toString(), item.musicGenreDisplay)
                    if (facts.isNotEmpty()) Row(horizontalArrangement = Arrangement.spacedBy(u(12))) {
                        for (f in facts) Text(f, style = font(DMMonoMedium, 32, Color.White.copy(alpha = 0.55f)))
                    }
                }
                else -> Text(item.title + (item.year?.let { "  $it" } ?: ""), style = headline)
            }
            Text(ch.name, style = font(DMMono, 24, Color.White.copy(alpha = 0.9f)))
            val np = schedule?.nowPlaying?.takeIf { it.item.ratingKey == item.ratingKey }
            val label = if (np != null) {
                "${formatTime(DailyManifest.liveElapsedSeconds(schedule, now) ?: 0)} / ${formatTime(maxOf(1L, item.duration * 60L))}"
            } else formatTime(item.duration * 60L)
            Text(label, style = font(DMMono, 18, Color.Gray))
        }
    }
}

// ── The tuner (TunerView.swift) ──────────────────────────────────────────

@Composable
private fun Tuner(
    model: AppModel,
    panelWidth: Float,
    videoHeight: Float,
    focusTarget: Int,
    focusRequest: Int,
    onFocused: (Int?) -> Unit,
    onFocusTarget: (Int) -> Unit,
    sidebarOpen: Boolean,
    onSidebar: (Boolean) -> Unit,
    onInvite: (ChannelConfig.Bundle) -> Unit,
) {
    var previewId by remember { mutableStateOf<Int?>(null) }
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxWidth().height(u(videoHeight))) {
            Column(
                Modifier
                    .width(u(panelWidth))
                    .fillMaxHeight()
                    .background(Brush.linearGradient(listOf(PanelTop, GuideBackground))),
            ) {
                Spacer(Modifier.height(u(140)))
                // The focused channel, or the one on (TunerView.previewChannel). Schedules aren't
                // state, so the tick is read to redraw when they change: a channel off the air
                // for Watershed had none, and 9 PM gives it one with nothing else changing here.
                model.scheduleTick
                val lineup = model.lineup
                val ch = lineup?.channels?.firstOrNull { it.id == previewId } ?: model.channel
                val schedule = ch?.let { lineup?.schedules?.get(it.id) }
                if (ch != null && schedule != null) {
                    InfoPanel(ch, schedule, playingItem = if (ch.id == model.channel?.id) model.item else null)
                }
            }
            NavBar(panelWidth, onSettings = model::openSettings)
        }
        Guide(
            model = model,
            focusTarget = focusTarget,
            focusRequest = focusRequest,
            onFocused = { previewId = it; onFocused(it) },
            onFocusTarget = onFocusTarget,
            sidebarOpen = sidebarOpen,
            onSidebar = onSidebar,
            onInvite = onInvite,
        )
    }
}

/** TunerView's NavBar: the logo, and SETTINGS, which Up from channel one reaches. */
@Composable
private fun NavBar(panelWidth: Float, onSettings: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    Row(
        Modifier.width(u(panelWidth)).height(u(140)).padding(start = u(40), end = u(40), top = u(40)),
        verticalAlignment = Alignment.Top,
    ) {
        Image(
            painterResource(R.drawable.wordmark),
            contentDescription = "Nostalgex",
            modifier = Modifier.height(u(80)).width(u(600)),
            alignment = Alignment.CenterStart,
        )
        Spacer(Modifier.weight(1f))
        Text(
            "SETTINGS",
            style = font(DMMonoMedium, 24, if (focused) Yellow else Color.White.copy(alpha = 0.5f)),
            modifier = Modifier
                .padding(top = u(16))
                .onFocusChanged { focused = it.isFocused }
                .focusable()
                .onKeyEvent { e ->
                    when (e.key.nativeKeyCode) {
                        AndroidKeyEvent.KEYCODE_DPAD_CENTER, AndroidKeyEvent.KEYCODE_ENTER -> {
                            if (e.type == KeyEventType.KeyUp) onSettings()
                            true
                        }
                        else -> false
                    }
                }
                .padding(horizontal = u(16), vertical = u(12)),
        )
    }
}

// ── The info panel (InfoPanelView.swift) ─────────────────────────────────

@Composable
private fun InfoPanel(ch: GuideChannel, schedule: Schedule, playingItem: MediaItem?) {
    val color = hex(ch.def.colorHex)
    val now = ticking()
    Column(Modifier.fillMaxSize().padding(u(40))) {
        Spacer(Modifier.height(u(24)))
        Text(
            "CH %02d — %s".format(ch.number, ch.name.uppercase()),
            style = font(VT323, 36, color, tracking = 2),
            maxLines = 1,
            modifier = Modifier.padding(bottom = u(20)),
        )
        val np = schedule.nowPlaying ?: return@Column
        // The item the player has, when this is the channel on: the schedule can run a few seconds apart.
        val item = playingItem ?: np.item
        Text(item.title, style = font(DMMonoMedium, 38, Color.White), maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(bottom = u(10)))
        val subtitle = if (item.type == "episode") listOfNotNull(item.seTag, item.episodeTitle?.takeIf { it.isNotEmpty() }).joinToString("  ") else ""
        run {
            if (subtitle.isNotEmpty()) {
                Text(subtitle, style = font(DMMono, 22, Color.White.copy(alpha = 0.7f)), maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(bottom = u(10)))
            }
        }
        Box(Modifier.padding(bottom = u(20)).fillMaxWidth().height(u(1)).background(color.copy(alpha = 0.3f)))
        if (item.summary.isNotEmpty()) {
            Text(
                item.summary,
                style = font(DMMono, 20, Color.White.copy(alpha = 0.65f)).copy(lineHeight = sp(28)),
                // Two lines, as the Apple TV reserves; one under an episode line, so UP NEXT still
                // fits in the panel (SwiftUI shrinks the stack to fit; Compose would push it off).
                maxLines = if (subtitle.isNotEmpty()) 1 else 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(bottom = u(20)),
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(u(14)), modifier = Modifier.padding(bottom = u(20))) {
            item.year?.let { MetaBadge(it.toString()) }
            item.contentRating?.takeIf { it.isNotEmpty() }?.let { MetaBadge(it) }
            if (item.rating > 0) {
                Row(horizontalArrangement = Arrangement.spacedBy(u(6)), verticalAlignment = Alignment.CenterVertically) {
                    Text("★", style = font(DMMono, 22, Yellow))
                    Text("%.1f".format(item.rating), style = font(VT323, 24, Color.White.copy(alpha = 0.6f)))
                }
            }
            // The progress bar and time follow the wall clock (schedule.livePlayback).
            val total = maxOf(1L, item.duration * 60L)
            val elapsed = DailyManifest.liveElapsedSeconds(schedule, now) ?: schedule.elapsedSeconds
            val progress = (elapsed.toFloat() / total).coerceIn(0f, 1f)
            Box(Modifier.weight(1f).height(u(4)).clip(RoundedCornerShape(u(2))).background(Color.White.copy(alpha = 0.08f))) {
                Box(Modifier.fillMaxHeight().fillMaxWidth(progress).background(color))
            }
            Text("${formatTime(elapsed)} / ${formatTime(total)}", style = font(VT323, 24, Color.White.copy(alpha = 0.55f)))
        }
        schedule.upNext?.let { next ->
            Row(horizontalArrangement = Arrangement.spacedBy(u(10)), verticalAlignment = Alignment.CenterVertically) {
                Text("UP NEXT", style = font(VT323, 24, Color.White.copy(alpha = 0.5f), tracking = 3))
                Text(next.item.title, style = font(DMMono, 18, Color.White.copy(alpha = 0.75f)), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun MetaBadge(text: String) {
    Text(
        text,
        style = font(VT323, 24, Color.White.copy(alpha = 0.7f)),
        modifier = Modifier
            .border(u(1), Color.White.copy(alpha = 0.15f), RoundedCornerShape(u(4)))
            .padding(horizontal = u(12), vertical = u(5)),
    )
}

// ── The guide (ChannelGuideView.swift) ───────────────────────────────────

@Composable
private fun Guide(
    model: AppModel,
    focusTarget: Int,
    focusRequest: Int,
    onFocused: (Int?) -> Unit,
    onFocusTarget: (Int) -> Unit,
    sidebarOpen: Boolean,
    onSidebar: (Boolean) -> Unit,
    onInvite: (ChannelConfig.Bundle) -> Unit,
) {
    val lineup = model.lineup ?: return
    // Read so the rows redraw when the schedules are rebuilt.
    model.scheduleTick
    val channels = lineup.channels
    // The seasonal invite sits above channel one while a seasonal package is in season and off.
    val offer = model.seasonalOffer
    val lead = if (offer != null) 1 else 0
    var slotOffset by remember { mutableIntStateOf(0) }
    var rowFocus by remember { mutableStateOf<Int?>(null) }
    val listState = rememberLazyListState(initialFirstVisibleItemIndex = maxOf(0, channels.indexOfFirst { it.id == focusTarget } + lead - 2))
    val visibleStart = lineup.windowStartSec + slotOffset * 1800L
    val now = ticking()

    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .background(GuideBackground)
            .onPreviewKeyEvent { e ->
                val down = e.type == KeyEventType.KeyDown
                // With the sidebar open, its rows take Up and Down; Right closes it, Left does nothing.
                if (sidebarOpen) {
                    return@onPreviewKeyEvent when (e.key.nativeKeyCode) {
                        AndroidKeyEvent.KEYCODE_DPAD_RIGHT -> { if (down) { onSidebar(false); rowFocus?.let(onFocusTarget) }; true }
                        AndroidKeyEvent.KEYCODE_DPAD_LEFT -> true
                        else -> false
                    }
                }
                when (e.key.nativeKeyCode) {
                    // Left and Right move the window by a half hour (ChannelGuideView's onMoveCommand);
                    // Left at the first half hour opens the package sidebar.
                    AndroidKeyEvent.KEYCODE_DPAD_LEFT -> { if (down) { if (slotOffset > 0) slotOffset-- else onSidebar(true) }; true }
                    AndroidKeyEvent.KEYCODE_DPAD_RIGHT -> { if (down && slotOffset < MAX_SLOT_OFFSET) slotOffset++; true }
                    // Down off the last channel wraps to the first; Up off the first does not.
                    AndroidKeyEvent.KEYCODE_DPAD_DOWN -> {
                        if (channels.size > 1 && rowFocus == channels.last().id) {
                            if (down) onFocusTarget(channels.first().id)
                            true
                        } else false
                    }
                    else -> false
                }
            },
    ) {
        val programsWidth = maxWidth / LocalUnit.current - CHANNEL_COLUMN
        Column(Modifier.fillMaxSize()) {
            GridHeader(visibleStart, programsWidth)
            Box(Modifier.fillMaxWidth().height(u(1)).background(Color.White.copy(alpha = 0.25f)))
            LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
                if (offer != null) item(key = "seasonal-invite") {
                    SeasonalInviteRow(
                        bundle = offer,
                        requestFocus = focusTarget == SEASONAL_ROW_ID,
                        focusRequest = focusRequest,
                        onFocused = { rowFocus = SEASONAL_ROW_ID; onFocused(SEASONAL_ROW_ID) },
                        onSelect = { onInvite(offer) },
                    )
                }
                itemsIndexed(channels, key = { _, ch -> ch.id }) { index, ch ->
                    EpgRow(
                        ch = ch,
                        schedule = lineup.schedules[ch.id],
                        watershedHold = model.watershed && lineup.schedules[ch.id] == null && lineup.isWatershedHold(ch),
                        isLive = ch.id == model.channel?.id,
                        isEvenRow = index % 2 == 0,
                        programsWidth = programsWidth,
                        visibleStart = visibleStart,
                        now = now,
                        requestFocus = ch.id == focusTarget,
                        focusRequest = focusRequest,
                        onFocused = {
                            rowFocus = ch.id
                            onFocused(ch.id)
                        },
                        onSelect = {
                            // Selecting the channel that is on goes full screen, unless it stopped after
                            // repeated failures: then selecting it retries. Any other channel tunes.
                            if (ch.id == model.channel?.id && !model.channelStopped) model.fullScreen = true else model.tune(ch)
                        },
                    )
                }
            }
        }
        // The now line, across header and rows.
        val fraction = (now - visibleStart) / VISIBLE_SECONDS
        if (fraction in 0.0..1.0) {
            Box(
                Modifier
                    .offset(x = u(CHANNEL_COLUMN + fraction * programsWidth))
                    .width(u(2))
                    .fillMaxHeight()
                    .background(BrandCyan),
            )
        }
        if (sidebarOpen) {
            PackageSidebar(
                targets = lineup.jumpTargets(model.enabledBundles),
                onSelect = { ch -> onSidebar(false); onFocusTarget(ch.id) },
                onSettings = { onSidebar(false); model.openSettings() },
            )
        }
    }

    // Bring the asked-for row into the middle of the guide (proxy.scrollTo(id, anchor: .center)).
    // The invite, when there is one, is the list's first item, so a channel's place is one further on.
    fun lazyIndex(id: Int?) = if (id == SEASONAL_ROW_ID && offer != null) 0 else channels.indexOfFirst { it.id == id }.let { if (it < 0) -1 else it + lead }
    LaunchedEffect(focusRequest) {
        val index = lazyIndex(focusTarget)
        if (index >= 0) listState.animateScrollToItem(maxOf(0, index - 2))
    }
    // And keep a row moved to with Up and Down there too.
    LaunchedEffect(rowFocus) {
        val index = lazyIndex(rowFocus)
        if (index >= 0) listState.animateScrollToItem(maxOf(0, index - 2))
    }
}

@Composable
private fun GridHeader(visibleStart: Long, programsWidth: Float) {
    Row(Modifier.fillMaxWidth().height(u(HEADER_HEIGHT)).background(Color(0.04f, 0.04f, 0.08f)), verticalAlignment = Alignment.CenterVertically) {
        // The Apple TV's header runs 12 points wide of the rows (its padding is outside the
        // column's frame); kept in line with the rows here, as the Roku port does.
        Text("CHANNEL", style = font(DMMonoMedium, LocalGuideText.current.channelHeading, Color.White.copy(alpha = 0.7f)), modifier = Modifier.width(u(CHANNEL_COLUMN)).padding(start = u(12)))
        for (i in 0 until 4) {
            Box(Modifier.width(u(programsWidth / 4)).fillMaxHeight()) {
                Box(Modifier.width(u(1)).fillMaxHeight().background(Color.White.copy(alpha = 0.2f)))
                Text(
                    time(visibleStart + i * 1800L),
                    style = font(DMMonoMedium, LocalGuideText.current.timeLabel, Color.White.copy(alpha = 0.95f)),
                    modifier = Modifier.align(Alignment.CenterStart).padding(start = u(14)),
                )
            }
        }
    }
}

@Composable
private fun EpgRow(
    ch: GuideChannel,
    schedule: Schedule?,
    /** No schedule because Watershed emptied the channel: the row says so rather than nothing. */
    watershedHold: Boolean,
    isLive: Boolean,
    isEvenRow: Boolean,
    programsWidth: Float,
    visibleStart: Long,
    now: Double,
    requestFocus: Boolean,
    focusRequest: Int,
    onFocused: () -> Unit,
    onSelect: () -> Unit,
) {
    val color = hex(ch.def.colorHex)
    var focused by remember { mutableStateOf(false) }
    val requester = remember { FocusRequester() }
    LaunchedEffect(focusRequest, requestFocus) { if (requestFocus) runCatching { requester.requestFocus() } }
    val accent = isLive || focused

    Column(Modifier.zIndex(if (focused) 1f else 0f)) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(u(ROW_HEIGHT))
                .focusRequester(requester)
                .onFocusChanged { focused = it.isFocused; if (it.isFocused) onFocused() }
                .focusable()
                // Selected on release: the press may be the one that brought this screen up.
                .onKeyEvent { e ->
                    when (e.key.nativeKeyCode) {
                        AndroidKeyEvent.KEYCODE_DPAD_CENTER, AndroidKeyEvent.KEYCODE_ENTER -> {
                            if (e.type == KeyEventType.KeyUp) onSelect()
                            true
                        }
                        else -> false
                    }
                }
                // A third-strength fill of the channel colour, so the focused row reads from the couch.
                .background(if (focused) color.copy(alpha = 0.32f) else if (isEvenRow) Color.White.copy(alpha = 0.03f) else Color.Transparent),
        ) {
            Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.width(u(if (accent) 8 else 4)).fillMaxHeight().background(if (accent) color else color.copy(alpha = 0.4f)))
                Row(
                    Modifier.width(u(CHANNEL_COLUMN - (if (accent) 8 else 4))).padding(start = u(if (isLive) 8 else 6), end = u(4)),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (isLive) {
                        BoltBadge(color)
                        Spacer(Modifier.width(u(6)))
                    }
                    Text(
                        ch.number.toString(),
                        style = font(DMMonoMedium, LocalGuideText.current.number, if (focused) Color.White else color),
                        modifier = Modifier.width(u(LocalGuideText.current.numberWidth + 8)).padding(end = u(8)),
                        maxLines = 1,
                    )
                    Text(
                        ch.name.uppercase(),
                        style = font(DMMonoMedium, LocalGuideText.current.name, if (focused) Color.White else color.copy(alpha = 0.95f)),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Box(Modifier.width(u(1)).fillMaxHeight().background(Color.White.copy(alpha = 0.15f)))
                ProgramBlocks(schedule, watershedHold, color, focused, programsWidth, visibleStart, now)
            }
            if (focused) {
                Box(Modifier.matchParentSize().padding(u(2)).border(u(3), color, RoundedCornerShape(u(6))))
            }
        }
        Box(Modifier.fillMaxWidth().height(u(1)).background(Color.White.copy(alpha = 0.08f)))
    }
}

/** The bolt on the live channel's row (SF Symbol bolt.fill), black on the channel colour. */
@Composable
private fun BoltBadge(color: Color) {
    Box(Modifier.clip(RoundedCornerShape(u(2))).background(color).padding(horizontal = u(4), vertical = u(5))) {
        Canvas(Modifier.size(u(11), u(14))) {
            val w = size.width
            val h = size.height
            val bolt = Path().apply {
                moveTo(w * 0.62f, 0f)
                lineTo(w * 0.05f, h * 0.58f)
                lineTo(w * 0.45f, h * 0.58f)
                lineTo(w * 0.35f, h)
                lineTo(w * 0.95f, h * 0.40f)
                lineTo(w * 0.55f, h * 0.40f)
                close()
            }
            drawPath(bolt, Color.Black.copy(alpha = 0.95f))
        }
    }
}

/** ProgramRowLayout.segments: a cursor walked from the window start, so gaps keep their place and overlap is trimmed. */
private sealed interface Segment {
    val fraction: Double
    data class Gap(override val fraction: Double) : Segment
    data class Block(val entry: ScheduleEntry, override val fraction: Double) : Segment
}

private fun segments(entries: List<ScheduleEntry>, windowStart: Long, duration: Long): List<Segment> {
    val windowEnd = windowStart + duration
    val out = ArrayList<Segment>()
    var cursor = windowStart
    for (e in entries.sortedBy { it.startSec }) {
        if (cursor >= windowEnd) break
        val visStart = maxOf(e.startSec, cursor)
        val visEnd = minOf(e.endSec, windowEnd)
        if (visEnd <= visStart) continue
        if (visStart > cursor) out.add(Segment.Gap((visStart - cursor).toDouble() / duration))
        out.add(Segment.Block(e, (visEnd - visStart).toDouble() / duration))
        cursor = visEnd
    }
    return out
}

private fun entryTitle(e: ScheduleEntry): String =
    if (e.item.type == "episode") listOfNotNull(e.item.title, e.item.episodeTitle).joinToString(": ") else e.item.title

@Composable
private fun ProgramBlocks(schedule: Schedule?, watershedHold: Boolean, color: Color, focused: Boolean, programsWidth: Float, visibleStart: Long, now: Double) {
    Row(Modifier.width(u(programsWidth)).fillMaxHeight().clipToBounds()) {
        if (schedule == null) {
            // ChannelGuideView's watershedRowPlaceholder.
            if (watershedHold) Row(Modifier.fillMaxSize().background(Color.White.copy(alpha = 0.02f)), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.width(u(1)).fillMaxHeight().background(Color.White.copy(alpha = 0.12f)))
                Text("BROADCASTS RESUME AT 9 PM", style = font(DMMonoMedium, LocalGuideText.current.placeholder, Color.White.copy(alpha = 0.4f)), maxLines = 1, modifier = Modifier.padding(start = u(14)))
            }
            return@Row
        }
        for (segment in segments(schedule.entries, visibleStart, VISIBLE_SECONDS)) {
            val width = u(maxOf(segment.fraction * programsWidth, 1.0))
            when (segment) {
                is Segment.Gap -> Spacer(Modifier.width(width))
                is Segment.Block -> {
                    val e = segment.entry
                    val isPast = e.endSec < now && !e.isNowPlaying
                    Row(
                        Modifier
                            .width(width)
                            .fillMaxHeight()
                            .background(
                                when {
                                    e.isNowPlaying -> color.copy(alpha = if (focused) 0.55f else 0.25f)
                                    isPast -> Color.White.copy(alpha = 0.02f)
                                    else -> Color.Transparent
                                },
                            ),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(Modifier.width(u(1)).fillMaxHeight().background(Color.White.copy(alpha = 0.12f)))
                        Text(
                            entryTitle(e),
                            style = font(
                                DMMonoMedium, LocalGuideText.current.title,
                                when {
                                    e.isNowPlaying || focused -> Color.White
                                    isPast -> Color.White.copy(alpha = 0.5f)
                                    else -> Color.White.copy(alpha = 0.85f)
                                },
                            ),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.padding(start = u(14)),
                        )
                    }
                }
            }
        }
    }
}

// ── The package sidebar (ChannelGuideView.swift's BundleJumpSidebar) ──────

/** Left at the guide's first half hour: SETTINGS, then each package on. A package jumps to its first channel. */
@Composable
private fun PackageSidebar(
    targets: List<Pair<ChannelConfig.Bundle, GuideChannel>>,
    onSelect: (GuideChannel) -> Unit,
    onSettings: () -> Unit,
) {
    val first = remember { FocusRequester() }
    Row(Modifier.fillMaxHeight()) {
        Column(
            Modifier
                .width(u(380))
                .fillMaxHeight()
                .background(Color(0.03f, 0.03f, 0.08f).copy(alpha = 0.95f)),
        ) {
            Text(
                "PACKAGES",
                style = font(DMMonoMedium, 22, Color.White.copy(alpha = 0.6f)),
                modifier = Modifier.padding(horizontal = u(24), vertical = u(18)),
            )
            LazyColumn(verticalArrangement = Arrangement.spacedBy(u(2))) {
                item(key = "settings") {
                    // A row of the list, first, so Up from the first package reaches it.
                    SidebarRow("\u2699  SETTINGS", Yellow, Modifier, onSettings)
                    Box(Modifier.padding(horizontal = u(16)).padding(bottom = u(6)).fillMaxWidth().height(u(1)).background(Color.White.copy(alpha = 0.1f)))
                }
                itemsIndexed(targets, key = { _, t -> t.first.id }) { i, (bundle, ch) ->
                    SidebarRow(bundle.name, hex(ch.def.colorHex), if (i == 0) Modifier.focusRequester(first) else Modifier) { onSelect(ch) }
                }
            }
        }
        Box(Modifier.width(u(1)).fillMaxHeight().background(Color.White.copy(alpha = 0.1f)))
    }
    // The sidebar opens on the first package.
    LaunchedEffect(Unit) { runCatching { first.requestFocus() } }
}

@Composable
private fun SidebarRow(title: String, color: Color, modifier: Modifier, onSelect: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    Box(
        modifier
            .fillMaxWidth()
            .height(u(72))
            .zIndex(if (focused) 1f else 0f)
            .onFocusChanged { focused = it.isFocused }
            .focusable()
            .onKeyEvent { e ->
                when (e.key.nativeKeyCode) {
                    AndroidKeyEvent.KEYCODE_DPAD_CENTER, AndroidKeyEvent.KEYCODE_ENTER -> {
                        if (e.type == KeyEventType.KeyUp) onSelect()
                        true
                    }
                    else -> false
                }
            }
            .background(if (focused) color.copy(alpha = 0.32f) else Color.Transparent),
    ) {
        Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(u(14))) {
            Box(Modifier.width(u(if (focused) 8 else 4)).fillMaxHeight().background(if (focused) color else color.copy(alpha = 0.4f)))
            Text(title, style = font(DMMonoMedium, 24, Color.White.copy(alpha = if (focused) 1f else 0.75f)), maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (focused) Box(Modifier.matchParentSize().padding(u(2)).border(u(3), color, RoundedCornerShape(u(6))))
    }
}

// ── GUIDE TEXT SIZE (GuideTextSize.swift, Roku's GuideText.brs) ──────────

/**
 * Type sizes for the text the guide grid draws. Only text changes: rows stay 80 high, the
 * header 60, the channel column 220, and blocks are laid out from times alone, so LARGE never
 * moves a row or a block. The number sits in a box that grows with it.
 */
internal data class GuideText(val title: Int, val timeLabel: Int, val channelHeading: Int, val number: Int, val numberWidth: Int, val name: Int, val placeholder: Int) {
    companion object {
        /** The sizes the guide drew before GUIDE TEXT SIZE. Must not change. */
        val NORMAL = GuideText(title = 20, timeLabel = 20, channelHeading = 18, number = 20, numberWidth = 36, name = 18, placeholder = 18)
        /** Roku's LARGE: titles and times 26, heading 22, number 24 in a wider box, name 20. */
        val LARGE = GuideText(title = 26, timeLabel = 26, channelHeading = 22, number = 24, numberWidth = 44, name = 20, placeholder = 22)
    }
}

internal val LocalGuideText = staticCompositionLocalOf { GuideText.NORMAL }

// ── CONNECTION FAILED and NO CHANNELS FOUND (Plex90App.swift) ──────────────

/** The library failed to load: the Apple TV's CONNECTION FAILED, the reason, RETRY and SETTINGS. */
@Composable
fun ConnectionFailedScreen(model: AppModel, message: String) = StatusScreen(model) {
    Text("CONNECTION FAILED", style = font(DMMonoMedium, 28, Color.Red.copy(alpha = 0.8f)))
    Text(message, style = font(DMMono, 18, Color.White.copy(alpha = 0.5f)), textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = u(1200)))
    Row(horizontalArrangement = Arrangement.spacedBy(u(16))) {
        OnboardingButton("RETRY", primary = true, focusFirst = true, onClick = model::start)
        OnboardingButton("SETTINGS", primary = false, onClick = model::openSettings)
    }
}

/** No package fills a channel: the Apple TV's two lines and OPEN SETTINGS. */
@Composable
fun NoChannelsScreen(model: AppModel) = StatusScreen(model) {
    Text("NO CHANNELS FOUND", style = font(DMMonoMedium, 28, Color.White.copy(alpha = 0.6f)))
    Text(
        "Your library didn't have enough content to fill any channels.\nOpen Settings to see which packages your library supports.",
        style = font(DMMono, 18, Color.White.copy(alpha = 0.3f)),
        textAlign = TextAlign.Center,
    )
    OnboardingButton("OPEN SETTINGS", primary = true, focusFirst = true, onClick = model::openSettings)
}

/** The logo over a status, on black; Settings opens over it, and Back closes Settings. */
@Composable
private fun StatusScreen(model: AppModel, content: @Composable () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black)) {
        CompositionLocalProvider(LocalUnit provides maxWidth / 1920f) {
            Box(
                Modifier
                    .fillMaxSize()
                    .onBack(model.settingsOpen) { model.settingsBack() },
                contentAlignment = Alignment.Center,
            ) {
                if (model.settingsOpen) SettingsPage(model)
                else Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(u(32))) {
                    Image(painterResource(R.drawable.wordmark), contentDescription = "Nostalgex", modifier = Modifier.width(u(540)))
                    content()
                }
            }
        }
    }
}

/**
 * OnboardingButtonStyle: cyan outline (primary) or a faint one (secondary), and a solid cyan
 * slab with dark text, a little larger, when focused.
 */
@Composable
internal fun OnboardingButton(
    label: String,
    primary: Boolean,
    focusFirst: Boolean = false,
    fontSize: Int = 24,
    fullWidth: Boolean = false,
    /** A cyan outline instead of the slab, for a screen whose main thing is a code. */
    quietFocus: Boolean = false,
    requester: FocusRequester = remember { FocusRequester() },
    onClick: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(u(14))
    val slab = focused && !quietFocus
    val style = font(
        DMMonoMedium, fontSize,
        when {
            slab -> Color(0f, 0.06f, 0.09f)
            focused -> Color.White
            primary -> BrandCyan
            else -> Color.White.copy(alpha = 0.62f)
        },
        tracking = 1,
    ).copy(textAlign = TextAlign.Center)
    // A label too long for its button shrinks to as little as 60%, as minimumScaleFactor(0.6).
    BasicText(
        label,
        style = style,
        maxLines = 1,
        autoSize = TextAutoSize.StepBased(minFontSize = style.fontSize * 0.6f, maxFontSize = style.fontSize),
        modifier = Modifier
            .focusRequester(requester)
            .onFocusChanged { focused = it.isFocused }
            .focusable()
            .onKeyEvent { e ->
                when (e.key.nativeKeyCode) {
                    AndroidKeyEvent.KEYCODE_DPAD_CENTER, AndroidKeyEvent.KEYCODE_ENTER -> {
                        if (e.type == KeyEventType.KeyUp) onClick()
                        true
                    }
                    else -> false
                }
            }
            .graphicsLayer { scaleX = if (focused) (if (quietFocus) 1.04f else 1.07f) else 1f; scaleY = scaleX }
            .then(if (fullWidth) Modifier.fillMaxWidth() else Modifier)
            .clip(shape)
            .background(if (slab) BrandCyan else Color.White.copy(alpha = if (focused) 0.07f else 0.03f))
            .then(
                when {
                    focused && quietFocus -> Modifier.border(u(3), BrandCyan, shape)
                    focused -> Modifier
                    else -> Modifier.border(u(if (primary) 2.5 else 1.5), if (primary) BrandCyan.copy(alpha = 0.75f) else Color.White.copy(alpha = 0.28f), shape)
                },
            )
            .padding(horizontal = u(36), vertical = u(if (primary) 24 else 20)),
    )
    if (focusFirst) LaunchedEffect(Unit) { runCatching { requester.requestFocus() } }
}

// ── The seasonal invite (ChannelGuideView.swift's SeasonalInviteRow) ────

/** Each season its own colour, so the invite reads as part of that season, not a notice. */
private fun seasonAccent(bundle: ChannelConfig.Bundle) = when (bundle.id) {
    "seasonal" -> Color(0xFFFF6B00)        // pumpkin
    "tis-the-season" -> Color(0xFFE74C3C)  // holiday red
    else -> Color(0xFFFFE500)
}

/**
 * The invite above channel one while a seasonal package is in season and off. Exactly one
 * channel row high, so the guide still reads as a grid: the outline, the fill and the pill do
 * the separating. Nothing is added to anyone's lineup until they answer its question.
 */
@Composable
private fun SeasonalInviteRow(
    bundle: ChannelConfig.Bundle,
    requestFocus: Boolean,
    focusRequest: Int,
    onFocused: () -> Unit,
    onSelect: () -> Unit,
) {
    val accent = seasonAccent(bundle)
    var focused by remember { mutableStateOf(false) }
    val requester = remember { FocusRequester() }
    LaunchedEffect(focusRequest, requestFocus) { if (requestFocus) runCatching { requester.requestFocus() } }
    val shape = RoundedCornerShape(u(6))
    Box(
        Modifier
            .zIndex(1f)
            .fillMaxWidth()
            .height(u(ROW_HEIGHT))
            .focusRequester(requester)
            .onFocusChanged { focused = it.isFocused; if (it.isFocused) onFocused() }
            .focusable()
            .onKeyEvent { e ->
                when (e.key.nativeKeyCode) {
                    AndroidKeyEvent.KEYCODE_DPAD_CENTER, AndroidKeyEvent.KEYCODE_ENTER -> {
                        if (e.type == KeyEventType.KeyUp) onSelect()
                        true
                    }
                    else -> false
                }
            }
            .background(if (focused) accent else accent.copy(alpha = 0.22f)),
    ) {
        Box(Modifier.matchParentSize().padding(u(2)).border(u(if (focused) 4 else 2), accent, shape))
        Box(Modifier.width(u(if (focused) 8 else 4)).fillMaxHeight().background(accent))
        Row(
            Modifier.fillMaxSize().padding(horizontal = u(20)),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(u(14)),
        ) {
            val headline = Season.headline(bundle, java.time.LocalDateTime.now())
            val style = font(DMMonoMedium, 22, if (focused) Color.Black else accent)
            BasicText(
                headline, style = style, maxLines = 1,
                autoSize = TextAutoSize.StepBased(minFontSize = style.fontSize * 0.7f, maxFontSize = style.fontSize),
                modifier = Modifier.weight(1f, fill = false),
            )
            // One call to action, not two.
            Text(
                "PRESS TO ADD THE ${bundle.name} PACKAGE",
                style = font(DMMonoMedium, 14, if (focused) Color.Black.copy(alpha = 0.65f) else Color.Black),
                maxLines = 1,
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background(if (focused) Color.Black.copy(alpha = 0.18f) else accent)
                    .padding(horizontal = u(11), vertical = u(5)),
            )
        }
    }
}

/**
 * The invite's question (ChannelGuideView's confirmationDialog): the package stays on until
 * switched off. Focus starts on YES; Back closes it with nothing changed.
 */
@Composable
private fun SeasonalQuestion(bundle: ChannelConfig.Bundle, onAnswer: (Season.Answer) -> Unit) {
    val shape = RoundedCornerShape(u(18))
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.7f)), contentAlignment = Alignment.Center) {
        Column(
            Modifier
                .widthIn(max = u(900))
                .clip(shape)
                .background(Color(0xFF16161C))
                .border(u(1), Color.White.copy(alpha = 0.12f), shape)
                // Focus stays on the three answers, as in the Apple TV's dialog: Back is the way out.
                .focusProperties { onExit = { cancelFocusChange() } }
                .focusGroup()
                .padding(horizontal = u(64), vertical = u(48)),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(u(20)),
        ) {
            Text(
                "Add ${bundle.name} to your lineup? It stays on until you switch it off.",
                style = font(DMMonoMedium, 28, Color.White), textAlign = TextAlign.Center,
                modifier = Modifier.padding(bottom = u(12)),
            )
            OnboardingButton("YES, TURN IT ON", primary = true, focusFirst = true, fontSize = 24, fullWidth = true) { onAnswer(Season.Answer.YES) }
            OnboardingButton("NOT THIS YEAR", primary = false, fontSize = 24, fullWidth = true) { onAnswer(Season.Answer.NOT_NOW) }
            OnboardingButton("DON'T ASK AGAIN", primary = false, fontSize = 24, fullWidth = true) { onAnswer(Season.Answer.NEVER) }
        }
    }
}

// ── Watershed's slate (WatershedCard.swift) ─────────────────────────────

/**
 * The channel has content, but all of it is 18, R or TV-MA and Watershed holds it until 9 PM.
 * The failure card's shape in cyan: nothing is broken. It clears itself at 9 PM, or when
 * Watershed is switched off.
 */
@Composable
private fun WatershedCard(compact: Boolean) {
    val shape = RoundedCornerShape(u(if (compact) 10 else 14))
    Box(Modifier.fillMaxSize().padding(u(if (compact) 24 else 60)), contentAlignment = Alignment.Center) {
        Column(
            Modifier
                .clip(shape)
                .background(Color.Black.copy(alpha = 0.82f))
                .border(u(1), BrandCyan.copy(alpha = 0.35f), shape)
                .padding(horizontal = u(if (compact) 32 else 72), vertical = u(if (compact) 28 else 48)),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(u(if (compact) 12 else 18)),
        ) {
            Text("BROADCASTS WILL RESUME AT 9 PM", style = font(DMMonoMedium, if (compact) 26 else 38, BrandCyan), textAlign = TextAlign.Center)
            Text(
                "This channel's 18 and R-rated titles wait for 9 PM, like broadcast TV. Everything in its pool right now falls in that window.",
                style = font(DMMono, if (compact) 16 else 22, Color.White.copy(alpha = 0.75f)).copy(lineHeight = sp(if (compact) 20 else 26)),
                textAlign = TextAlign.Center,
                modifier = Modifier.widthIn(max = u(if (compact) 520 else 900)),
            )
            Text("Turn off Watershed in Settings to watch now.", style = font(DMMono, if (compact) 13 else 17, Color.White.copy(alpha = 0.4f)))
        }
    }
}

// ── When a programme won't play (PlaybackFailureCard.swift) ───────────────

/** What happened and whose problem it is: amber when it's the server, red when the file or the device. */
@Composable
internal fun FailureCard(failure: PlaybackFailure, compact: Boolean) {
    val accent = if (failure.isServerSide) Color(0xFFFFB020) else Color(0xFFFF2244)
    val shape = RoundedCornerShape(u(if (compact) 10 else 14))
    Box(Modifier.fillMaxSize().padding(u(if (compact) 24 else 60)), contentAlignment = Alignment.Center) {
        Column(
            Modifier
                .clip(shape)
                .background(Color.Black.copy(alpha = 0.82f))
                .border(u(1), accent.copy(alpha = 0.35f), shape)
                .padding(horizontal = u(if (compact) 32 else 72), vertical = u(if (compact) 28 else 48)),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(u(if (compact) 12 else 18)),
        ) {
            Text(failure.headline, style = font(DMMonoMedium, if (compact) 26 else 38, accent), textAlign = TextAlign.Center)
            Text(
                failure.detail,
                style = font(DMMono, if (compact) 16 else 22, Color.White.copy(alpha = 0.75f)).copy(lineHeight = sp(if (compact) 20 else 26)),
                textAlign = TextAlign.Center,
                modifier = Modifier.widthIn(max = u(if (compact) 520 else 900)),
            )
            Text(failure.nextStep, style = font(DMMono, if (compact) 13 else 17, Color.White.copy(alpha = 0.4f)))
        }
    }
}
