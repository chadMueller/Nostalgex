package com.muellhaus.nostalgex.ui

import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.nativeKeyCode
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.tv.material3.Text
import com.muellhaus.nostalgex.AppModel
import com.muellhaus.nostalgex.engine.GuideChannel
import com.muellhaus.nostalgex.engine.LanguageChoice
import com.muellhaus.nostalgex.engine.MediaItem
import com.muellhaus.nostalgex.engine.StreamQuality
import com.muellhaus.nostalgex.playback.PlaybackInfo

// Full screen's overlays, from PlayerView.swift (MiniChannelStrip) and NowPlayingPanel.swift
// (NowPlayingPanel, SleepGracePrompt), at their measurements.

private val CardFocused = Color(0.05f, 0.05f, 0.07f)

/** Selects on release, so the press that opened a screen can't also choose on it. */
private fun Modifier.onSelect(action: () -> Unit) = onKeyEvent { e ->
    when (e.key.nativeKeyCode) {
        AndroidKeyEvent.KEYCODE_DPAD_CENTER, AndroidKeyEvent.KEYCODE_ENTER -> {
            if (e.type == KeyEventType.KeyUp) action()
            true
        }
        else -> false
    }
}

// ── The mini channel strip ───────────────────────────────────────────────

/** Every channel as a card along the bottom, opened with Up; focus starts on the one on. */
@Composable
internal fun MiniChannelStrip(model: AppModel, onSelect: (GuideChannel) -> Unit) {
    val lineup = model.lineup ?: return
    val channels = lineup.channels
    val current = model.channel?.id
    val start = channels.indexOfFirst { it.id == current }.coerceAtLeast(0)
    val listState = rememberLazyListState(initialFirstVisibleItemIndex = maxOf(0, start - 2))
    var focusedId by remember { mutableStateOf(current) }
    val first = remember { FocusRequester() }

    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomStart) {
        LazyRow(
            state = listState,
            horizontalArrangement = Arrangement.spacedBy(u(12)),
            contentPadding = PaddingValues(horizontal = u(40), vertical = u(20)),
            modifier = Modifier
                .fillMaxWidth()
                .background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.35f), Color.Black.copy(alpha = 0.95f)))),
        ) {
            items(channels, key = { it.id }) { ch ->
                StripCard(
                    ch = ch,
                    nowPlaying = lineup.schedules[ch.id]?.nowPlaying?.item,
                    isCurrent = ch.id == current,
                    isFocused = ch.id == focusedId,
                    modifier = (if (ch.id == current) Modifier.focusRequester(first) else Modifier)
                        .onFocusChanged { if (it.isFocused) focusedId = ch.id }
                        .focusable()
                        .onSelect { onSelect(ch) },
                )
            }
        }
    }
    LaunchedEffect(Unit) { runCatching { first.requestFocus() } }
    // Keep the focused card in the middle (proxy.scrollTo(id, anchor: .center)).
    LaunchedEffect(focusedId) {
        val i = channels.indexOfFirst { it.id == focusedId }
        if (i >= 0) listState.animateScrollToItem(maxOf(0, i - 2))
    }
}

@Composable
private fun StripCard(ch: GuideChannel, nowPlaying: MediaItem?, isCurrent: Boolean, isFocused: Boolean, modifier: Modifier) {
    val color = hex(ch.def.colorHex)
    val fill = when {
        isCurrent && !isFocused -> color.copy(alpha = 0.18f)
        isFocused -> CardFocused
        else -> Color.White.copy(alpha = 0.14f)
    }
    val border = when {
        isFocused -> color
        isCurrent -> color.copy(alpha = 0.6f)
        else -> Color.White.copy(alpha = 0.25f)
    }
    val shape = RoundedCornerShape(u(6))
    Column(
        modifier
            .width(u(310))
            .clip(shape)
            .background(fill)
            .border(u(if (isFocused) 2 else 1), border, shape),
    ) {
        Box(Modifier.fillMaxWidth().height(u(if (isFocused) 5 else 4)).background(color))
        Column(Modifier.padding(horizontal = u(16), vertical = u(12)), verticalArrangement = Arrangement.spacedBy(u(6))) {
            Row(horizontalArrangement = Arrangement.spacedBy(u(10)), verticalAlignment = Alignment.CenterVertically) {
                Text(ch.number.toString(), style = font(DMMonoMedium, 26, color))
                Text(ch.name.uppercase(), style = font(DMMonoMedium, 18, Color.White), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (nowPlaying != null) {
                Text(
                    nowPlaying.title,
                    style = font(DMMono, 16, Color.White.copy(alpha = if (isFocused) 0.9f else 0.7f)),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

// ── Now Playing ──────────────────────────────────────────────────────────

/** The multi-value settings that expand in place over the controls (PanelPicker). */
internal enum class PanelPicker(val title: String) {
    STREAM_QUALITY("STREAM QUALITY"),
    PLAYBACK_INFORMATION("PLAYBACK INFORMATION"),
    SUBTITLE_LANGUAGE("SUBTITLE LANGUAGE"),
    AUDIO_LANGUAGE("AUDIO LANGUAGE"),
}

/**
 * Opened with Down: what is on, on the left; on the right the program's controls (captions,
 * audio) and the device's (picture, stream quality, sleep timer, playback information). A
 * picker takes over the controls; Back closes it to its row. OPEN IN PLEX has nothing to act
 * on here, as on the Roku.
 */
@Composable
internal fun NowPlayingPanel(model: AppModel, ch: GuideChannel, item: MediaItem, picker: PanelPicker?, onPicker: (PanelPicker?) -> Unit) {
    val color = hex(ch.def.colorHex)
    val cc = remember { FocusRequester() }
    val owners = remember { PanelPicker.entries.associateWith { FocusRequester() } }
    // Where focus goes when the columns come back: the row that owned the picker, however it
    // closed (a choice, its BACK row, or the remote's Back).
    var returnTo by remember { mutableStateOf<PanelPicker?>(null) }
    LaunchedEffect(picker) { if (picker != null) returnTo = picker }
    val now = ticking()

    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopStart) {
        Row(
            Modifier
                .fillMaxWidth()
                .background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.92f), Color.Transparent)))
                .padding(start = u(48), end = u(48), top = u(40), bottom = u(32)),
            verticalAlignment = Alignment.Top,
        ) {
            InfoZone(model, ch, item, color)
            Spacer(Modifier.weight(1f).widthIn(min = u(24)))
            if (picker != null) {
                PickerZone(model, picker, color, onDone = { onPicker(null) })
            } else Row(horizontalArrangement = Arrangement.spacedBy(u(40)), verticalAlignment = Alignment.Top) {
                // What this program is doing right now (NowPlayingPanelLayout.programRows).
                Column(Modifier.width(u(420)), verticalArrangement = Arrangement.spacedBy(u(10))) {
                    ControlHeader("CAPTIONS")
                    // Always focusable, so focus lands here first; with no subtitles it says NONE.
                    ControlRow(
                        label = "CC",
                        value = if (model.hasSubtitleTracks) (if (model.subtitlesInFullScreen) "ON" else "OFF") else "NONE",
                        color = color,
                        active = model.hasSubtitleTracks && model.subtitlesInFullScreen,
                        disabled = !model.hasSubtitleTracks,
                        modifier = Modifier.focusRequester(cc),
                        onClick = model::toggleSubtitles,
                    )
                    // The language preferences only where their effect can be seen or heard.
                    if (model.hasSubtitleTracks) {
                        ControlRow(
                            label = "SUBTITLE LANGUAGE", value = LanguageChoice.shortLabel(model.subtitleLanguage), color = color, active = false, disabled = false,
                            modifier = Modifier.focusRequester(owners.getValue(PanelPicker.SUBTITLE_LANGUAGE)),
                        ) { onPicker(PanelPicker.SUBTITLE_LANGUAGE) }
                        ControlRow(
                            label = "AUTO SUBTITLES (FOREIGN AUDIO)", value = if (model.autoSubtitles) "ON" else "OFF", color = color,
                            active = model.autoSubtitles, disabled = false, onClick = model::toggleAutoSubtitles,
                        )
                    }
                    ControlHeader("AUDIO")
                    val tracks = model.audioTracks
                    if (tracks.size <= 1) {
                        // A single track is shown but can't be focused, so focus skips past it.
                        ControlRow(label = tracks.firstOrNull()?.name ?: "SINGLE TRACK", value = null, color = color, active = false, disabled = true, focusable = false)
                    } else {
                        for (t in tracks) {
                            ControlRow(label = t.name, value = if (t.selected) "ACTIVE" else null, color = color, active = t.selected, disabled = false) {
                                model.selectAudioTrack(t)
                            }
                        }
                        ControlRow(
                            label = "AUDIO LANGUAGE", value = LanguageChoice.shortLabel(model.audioLanguage), color = color, active = false, disabled = false,
                            modifier = Modifier.focusRequester(owners.getValue(PanelPicker.AUDIO_LANGUAGE)),
                        ) { onPicker(PanelPicker.AUDIO_LANGUAGE) }
                    }
                }
                // What the device is doing.
                Column(Modifier.width(u(420)), verticalArrangement = Arrangement.spacedBy(u(10))) {
                    ControlHeader("PICTURE")
                    ControlRow(label = "RETRO MODE", value = if (model.retroMode) "ON" else "OFF", color = color, active = model.retroMode, disabled = false, onClick = model::toggleRetroMode)
                    // Shown for every program: nothing says whether this one is transcoded, and the
                    // note says the part that matters.
                    ControlRow(
                        label = "STREAM QUALITY", value = model.streamQuality.displayName.uppercase(), color = color, active = false, disabled = false,
                        note = "Takes effect on the next program.",
                        modifier = Modifier.focusRequester(owners.getValue(PanelPicker.STREAM_QUALITY)),
                    ) { onPicker(PanelPicker.STREAM_QUALITY) }
                    ControlHeader("SLEEP TIMER")
                    val armed = model.sleepEndMs
                    ControlRow(label = "OFF", value = if (armed == null) "ACTIVE" else null, color = color, active = armed == null, disabled = false) {
                        model.cancelSleepTimer()
                    }
                    for (minutes in offeredSleepMinutes(model.sleepMinutes)) {
                        val selected = armed != null && model.sleepMinutes == minutes
                        val remaining = if (armed != null && selected) maxOf(0.0, armed / 1000.0 - now) else 0.0
                        ControlRow(
                            label = sleepLabel(minutes),
                            value = if (selected) countdownLabel(remaining) else null,
                            color = color,
                            active = selected,
                            disabled = false,
                        ) { model.startSleepTimer(minutes) }
                    }
                    ControlRow(
                        label = "PLAYBACK INFORMATION", value = "VIEW", color = color, active = false, disabled = false,
                        modifier = Modifier.focusRequester(owners.getValue(PanelPicker.PLAYBACK_INFORMATION)),
                    ) { onPicker(PanelPicker.PLAYBACK_INFORMATION) }
                }
                LaunchedEffect(Unit) {
                    val target = returnTo?.let(owners::getValue) ?: cc
                    returnTo = null
                    runCatching { target.requestFocus() }
                }
            }
        }
    }
}

/** A picker over the controls: its title, what the setting does, and its options. */
@Composable
private fun PickerZone(model: AppModel, picker: PanelPicker, color: Color, onDone: () -> Unit) {
    val selected = remember { FocusRequester() }
    Column(verticalArrangement = Arrangement.spacedBy(u(10))) {
        ControlHeader(picker.title)
        Text(
            when (picker) {
                PanelPicker.PLAYBACK_INFORMATION -> PlaybackInfo.EVIDENCE_NOTE
                PanelPicker.STREAM_QUALITY -> "Lower this when your connection is slow or shared. Takes effect on the next program."
                PanelPicker.SUBTITLE_LANGUAGE -> "Choose which subtitle track to prefer when multiple are available."
                PanelPicker.AUDIO_LANGUAGE -> "Choose which audio track to prefer when multiple are available."
            },
            style = font(DMMono, 17, Color.White.copy(alpha = 0.6f)),
            modifier = Modifier.widthIn(max = u(880)).padding(bottom = u(2)),
        )
        when (picker) {
            PanelPicker.PLAYBACK_INFORMATION -> Column(Modifier.width(u(880)), verticalArrangement = Arrangement.spacedBy(u(10))) {
                val rows = model.playbackInfo?.rows(model.videoSize?.first, model.videoSize?.second)
                Column(verticalArrangement = Arrangement.spacedBy(u(8))) {
                    if (rows == null) {
                        Text("Playback information is unavailable.", style = font(DMMono, 20, Color.White.copy(alpha = 0.8f)))
                    } else for (r in rows) {
                        Row(Modifier.padding(vertical = u(3)), horizontalArrangement = Arrangement.spacedBy(u(16))) {
                            Text(r.label, style = font(DMMonoMedium, 17, Color.White.copy(alpha = 0.6f)), modifier = Modifier.width(u(220)))
                            Text(r.value, style = font(DMMono, 21, Color.White))
                        }
                    }
                }
                ControlRow(label = "BACK", value = null, color = color, active = false, disabled = false, modifier = Modifier.padding(top = u(8)).focusRequester(selected), onClick = onDone)
            }
            PanelPicker.STREAM_QUALITY -> Column(Modifier.width(u(560)), verticalArrangement = Arrangement.spacedBy(u(10))) {
                for (q in StreamQuality.entries) {
                    val on = q == model.streamQuality
                    ControlRow(
                        label = q.displayName.uppercase(), value = if (on) "ACTIVE" else null, color = color, active = on, disabled = false, note = q.detail,
                        modifier = if (on) Modifier.focusRequester(selected) else Modifier,
                    ) { model.chooseStreamQuality(q); onDone() }
                }
            }
            PanelPicker.SUBTITLE_LANGUAGE, PanelPicker.AUDIO_LANGUAGE -> {
                // Two columns, so all sixteen fit without scrolling.
                val current = if (picker == PanelPicker.SUBTITLE_LANGUAGE) model.subtitleLanguage else model.audioLanguage
                val split = (LanguageChoice.presets.size + 1) / 2
                Row(horizontalArrangement = Arrangement.spacedBy(u(20)), verticalAlignment = Alignment.Top) {
                    for (column in listOf(LanguageChoice.presets.take(split), LanguageChoice.presets.drop(split))) {
                        Column(Modifier.width(u(380)), verticalArrangement = Arrangement.spacedBy(u(10))) {
                            for (preset in column) {
                                val on = preset.code == current
                                ControlRow(
                                    label = preset.label, value = if (on) "ACTIVE" else null, color = color, active = on, disabled = false,
                                    modifier = if (on) Modifier.focusRequester(selected) else Modifier,
                                ) {
                                    if (picker == PanelPicker.SUBTITLE_LANGUAGE) model.chooseSubtitleLanguage(preset.code) else model.chooseAudioLanguage(preset.code)
                                    onDone()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    // Focus opens on the option in effect.
    LaunchedEffect(picker) { runCatching { selected.requestFocus() } }
}

@Composable
private fun InfoZone(model: AppModel, ch: GuideChannel, item: MediaItem, color: Color) {
    var poster by remember(item.ratingKey) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(item.ratingKey) { poster = model.poster(item) }
    Row(horizontalArrangement = Arrangement.spacedBy(u(24)), verticalAlignment = Alignment.Top) {
        // Only when the server serves one (Plex's thumbnail transcode).
        poster?.let {
            Image(it, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.size(u(150), u(225)).clip(RoundedCornerShape(u(8))))
        }
        Column(Modifier.widthIn(max = u(640)), verticalArrangement = Arrangement.spacedBy(u(8))) {
            Box(Modifier.size(u(48), u(4)).background(color))
            Text("CH ${ch.number}", style = font(DMMonoMedium, 23, color))
            // The title leads and the channel name follows smaller (NowPlayingPanel, 02ac78f).
            val line = if (item.isMusicVideo) item.musicDisplayLine else item.title + (item.year?.let { "  $it" } ?: "")
            Text(line, style = font(DMMonoMedium, 30, Color.White), maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text(ch.name, style = font(DMMono, 25, Color.White.copy(alpha = 0.9f)), maxLines = 1, overflow = TextOverflow.Ellipsis)
            item.contentRating?.takeIf { it.isNotEmpty() }?.let {
                Text(it.uppercase(), style = font(DMMono, 18, Color.White.copy(alpha = 0.7f)))
            }
            model.lineup?.schedules?.get(ch.id)?.upNext?.item?.let { next ->
                Text("UP NEXT: ${if (next.isMusicVideo) next.musicDisplayLine else next.title}", style = font(DMMono, 18, Color.White.copy(alpha = 0.7f)), maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = u(4)))
            }
        }
    }
}

@Composable
private fun ControlHeader(text: String) {
    Text(text, style = font(DMMonoMedium, 16, Color.White.copy(alpha = 0.6f), tracking = 1.5))
}

@Composable
private fun ControlRow(
    label: String,
    value: String?,
    color: Color,
    active: Boolean,
    disabled: Boolean,
    modifier: Modifier = Modifier,
    focusable: Boolean = true,
    note: String? = null,
    onClick: () -> Unit = {},
) {
    var focused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(u(6))
    val border = when {
        focused -> color
        active -> color.copy(alpha = 0.5f)
        else -> Color.White.copy(alpha = 0.22f)
    }
    Column(
        modifier
            .fillMaxWidth()
            .then(if (focusable) Modifier.onFocusChanged { focused = it.isFocused }.focusable().onSelect(onClick) else Modifier)
            .clip(shape)
            .background(if (focused) CardFocused else Color.White.copy(alpha = 0.14f))
            .border(u(if (focused) 2 else 1), border, shape)
            .padding(horizontal = u(16), vertical = u(12)),
        verticalArrangement = Arrangement.spacedBy(u(4)),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                label,
                style = font(DMMonoMedium, 20, Color.White.copy(alpha = if (disabled) 0.35f else 1f)),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            if (value != null) {
                Text(value, style = font(DMMono, 18, if (active) color else Color.White.copy(alpha = 0.75f)), maxLines = 1)
            }
        }
        // What a label and a value can't say on their own.
        if (note != null) Text(note, style = font(DMMono, 16, Color.White.copy(alpha = 0.6f)), maxLines = 2)
    }
}

// SleepTimerLogic.swift: the presets, their labels and the countdown.

private val SLEEP_PRESETS = listOf(15, 30, 60)

/** A running timer whose preset is no longer offered keeps its row until it fires or is cancelled. */
private fun offeredSleepMinutes(armed: Int?): List<Int> =
    if (armed == null || armed <= 0 || armed in SLEEP_PRESETS) SLEEP_PRESETS else (SLEEP_PRESETS + armed).sorted()

private fun sleepLabel(minutes: Int): String {
    if (minutes <= 0) return "OFF"
    val h = minutes / 60
    val m = minutes % 60
    return when {
        h == 0 -> "$m MIN"
        m == 0 -> "$h HR"
        else -> "$h HR $m MIN"
    }
}

private fun countdownLabel(remaining: Double): String {
    val total = Math.round(remaining)
    val h = total / 3600
    val m = (total % 3600) / 60
    val s = total % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}

// ── "Still watching?" ────────────────────────────────────────────────────

/** Shown when the sleep timer runs out. Any key keeps watching; 20 s without one stops playback. */
@Composable
internal fun SleepGracePrompt(model: AppModel) {
    val deadline = remember { System.currentTimeMillis() / 1000.0 + 20 }
    val now = ticking()
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.8f)), contentAlignment = Alignment.Center) {
        val shape = RoundedCornerShape(u(10))
        Column(
            Modifier
                .clip(shape)
                .background(CardFocused)
                .border(u(1), Color.White.copy(alpha = 0.28f), shape)
                .padding(u(48)),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(u(16)),
        ) {
            Text("STILL WATCHING?", style = font(DMMonoMedium, 34, Color.White))
            Text("SLEEPING IN ${countdownLabel(maxOf(0.0, deadline - now))}", style = font(DMMono, 23, Color.White.copy(alpha = 0.85f)))
            Text("PRESS ANY BUTTON TO KEEP WATCHING", style = font(DMMono, 19, Color.White.copy(alpha = 0.65f)), modifier = Modifier.padding(top = u(4)))
        }
    }
}

// ── Music videos on screen (PlexMediaItem+MusicDisplay.swift) ─────────────

internal val MediaItem.isMusicVideo get() = type != "episode" && librarySource == "musicVideo"

/** "Artist · Title", the web tuner's now-playing label. */
internal val MediaItem.musicDisplayLine: String
    get() = if (isMusicVideo && !artist.isNullOrEmpty()) "$artist \u00B7 $title" else title

/** Up to four genres, without the generic music-video tags. */
internal val MediaItem.musicGenreDisplay: String?
    get() {
        if (!isMusicVideo) return null
        val useful = genres.filter { g -> g.lowercase().let { !it.contains("music video") && it != "music" && it != "musical" } }
        return useful.take(4).joinToString(" \u00B7 ").ifEmpty { null }
    }
