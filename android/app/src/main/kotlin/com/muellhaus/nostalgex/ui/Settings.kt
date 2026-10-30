package com.muellhaus.nostalgex.ui

import android.text.format.DateUtils
import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.nativeKeyCode
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.style.TextAlign
import androidx.tv.material3.Text
import com.muellhaus.nostalgex.AppModel
import com.muellhaus.nostalgex.engine.LanguageChoice
import com.muellhaus.nostalgex.engine.Season
import com.muellhaus.nostalgex.engine.StreamQuality
import java.time.LocalDateTime

// The settings page: SettingsPageView in BundleManagerView.swift, at its measurements.
// Not here: SUPPORT NOSTALGEX (App Store ratings and tips have no counterpart in a sideloaded
// app), SHOW NOW PLAYING and MARK WATCHED (watch state isn't ported), iCloud sync (Apple
// only), the enrichment status and MY COLLECTIONS (enrichment and collections aren't ported).

private val PageTop = Color(0.04f, 0.04f, 0.10f)
private val PageBottom = Color(0.05f, 0.05f, 0.12f)
private val Amber = Color(0xFFFFB020)
private val Cyan = Color(0f, 0.831f, 1f)

@Composable
internal fun SettingsPage(model: AppModel) {
    when (model.settingsPicker) {
        "stream_quality" -> PickerPage(
            title = "STREAM QUALITY",
            subtitle = "Lower quality uses less bandwidth. Auto adjusts as your connection changes.",
            options = StreamQuality.entries.map { Triple(it.id, it.displayName.uppercase(), it.detail) },
            selected = model.streamQuality.id,
        ) { model.chooseStreamQuality(StreamQuality.fromId(it)); model.settingsPicker = null }
        "sub_lang" -> PickerPage(
            title = "SUBTITLE LANGUAGE",
            subtitle = "When the video has multiple subtitle tracks, prefer this language",
            options = LanguageChoice.presets.map { Triple(it.code, it.label, null) },
            selected = model.subtitleLanguage,
        ) { model.chooseSubtitleLanguage(it); model.settingsPicker = null }
        "audio_lang" -> PickerPage(
            title = "AUDIO LANGUAGE",
            subtitle = "When the video has multiple audio tracks, prefer this language",
            options = LanguageChoice.presets.map { Triple(it.code, it.label, null) },
            selected = model.audioLanguage,
        ) { model.chooseAudioLanguage(it); model.settingsPicker = null }
        else -> MainPage(model)
    }
}

@Composable
private fun MainPage(model: AppModel) {
    val first = remember { FocusRequester() }
    Column(
        Modifier
            .fillMaxSize()
            .background(Brush.linearGradient(listOf(PageTop, PageBottom)))
            .verticalScroll(rememberScrollState())
            .padding(horizontal = u(80), vertical = u(60)),
        verticalArrangement = Arrangement.spacedBy(u(48)),
    ) {
        // ── CONNECTION ──
        Column(verticalArrangement = Arrangement.spacedBy(u(12))) {
            Text("CONNECTION", style = font(DMMonoMedium, 28, Color.White.copy(alpha = 0.8f)))
            Text("SERVERS", style = font(DMMono, 20, Color.White.copy(alpha = 0.7f)), modifier = Modifier.padding(top = u(4)))
            val selected = model.selectedServers
            for ((i, server) in model.serversForSettings.withIndex()) {
                val included = selected.any { it.machineIdentifier == server.machineIdentifier }
                val isLast = included && selected.size <= 1
                ToggleRow(
                    title = server.name.uppercase(),
                    subtitle = if (isLast) "Your server · only connected server" else if (server.owned) "Your server" else "Shared with you",
                    detail = if (included) "INCLUDED" else "OFF",
                    on = included,
                    // No switch on the only server: it can't be removed.
                    showToggle = !isLast,
                    modifier = if (i == 0) Modifier.focusRequester(first) else Modifier,
                ) { model.toggleServer(server) }
            }
            val updated = model.libraryUpdatedMs?.let {
                DateUtils.getRelativeTimeSpanString(it, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString().lowercase()
            } ?: "never"
            ToggleRow(
                title = "RESCAN LIBRARY",
                subtitle = "${model.librarySummary()}\nLast updated $updated. Pull a fresh copy of your ${model.backendName} library after adding content",
                on = true,
                showToggle = false,
                loading = if (model.refreshing) "Updating…" else null,
                modifier = Modifier.padding(top = u(8)),
            ) { model.rescanLibrary() }
            ToggleRow(
                title = "DISCONNECT FROM ${model.backendName.uppercase()}",
                subtitle = "Clears saved ${model.backendName} access. Use when switching servers",
                on = true,
                showToggle = false,
            ) { model.signOut() }
        }

        Divider()

        // ── PLAYBACK ──
        Column(verticalArrangement = Arrangement.spacedBy(u(20))) {
            SectionHeader("PLAYBACK", "Picture, quality, subtitles and audio")
            ToggleRow(
                title = "RETRO MODE",
                subtitle = "CRT scanlines, vignette, VHS glitch, 4:3 aspect ratio",
                on = model.retroMode,
            ) { model.toggleRetroMode() }
            ToggleRow(
                title = "STREAM QUALITY",
                subtitle = "Lower this when your connection is slow or shared",
                detail = model.streamQuality.displayName,
                on = true,
                showToggle = false,
            ) { model.settingsPicker = "stream_quality" }
            // One row for two switches: ALWAYS is CC in full screen, FOREIGN AUDIO the automatic fallback alone.
            ToggleRow(
                title = "SUBTITLES",
                subtitle = when {
                    model.subtitlesInFullScreen -> "Shown in fullscreen whenever the video has them"
                    model.autoSubtitles -> "Shown in fullscreen when the audio isn't in your language"
                    else -> "Never shown. Press to change"
                },
                detail = when {
                    model.subtitlesInFullScreen -> "ALWAYS"
                    model.autoSubtitles -> "FOREIGN AUDIO"
                    else -> "OFF"
                },
                on = true,
                showToggle = false,
            ) { model.cycleSubtitleMode() }
            if (model.subtitlesInFullScreen || model.autoSubtitles) {
                ToggleRow(
                    title = "SUBTITLE LANGUAGE",
                    subtitle = "When the video has multiple subtitle tracks, prefer this language",
                    detail = LanguageChoice.presets.firstOrNull { it.code == model.subtitleLanguage }?.label ?: model.subtitleLanguage.uppercase(),
                    on = true,
                    showToggle = false,
                ) { model.settingsPicker = "sub_lang" }
            }
            ToggleRow(
                title = "AUDIO LANGUAGE",
                subtitle = "When the video has multiple audio tracks, prefer this language",
                detail = LanguageChoice.presets.firstOrNull { it.code == model.audioLanguage }?.label ?: model.audioLanguage.uppercase(),
                on = true,
                showToggle = false,
            ) { model.settingsPicker = "audio_lang" }
        }

        Divider()

        // ── CHANNEL PACKAGES ──
        Column(verticalArrangement = Arrangement.spacedBy(u(20))) {
            SectionHeader("CHANNEL PACKAGES", "Toggle packages to customize your lineup")
            val lineup = model.lineup
            val now = LocalDateTime.now()
            Column(verticalArrangement = Arrangement.spacedBy(u(4))) {
                for (bundle in model.bundles.filter { !it.id.startsWith("collections-") }) {
                    val enabled = bundle.id in model.enabledBundles
                    // A seasonal package works in any month; its months decide when it's offered and leads.
                    val offSeason = Season.isSeasonal(bundle) && !Season.isInSeason(bundle, now)
                    val availability = if (enabled) lineup?.availability(bundle) ?: emptyList() else emptyList()
                    val availableNames = availability.filter { it.second }.map { it.first }
                    val missingNames = availability.filterNot { it.second }.map { it.first }
                    val total = bundle.channelIDs.size
                    val building = enabled && bundle.id in model.buildingBundles
                    // An OFF package is an invitation, never a warning.
                    val subtitle = when {
                        building -> "Finding $total channel${if (total == 1) "" else "s"} in your library"
                        !enabled -> {
                            val invite = "Turn on to add up to $total channel${if (total == 1) "" else "s"} from your library."
                            if (offSeason) "${Season.spotlightLabel(bundle, now)} · $invite" else invite
                        }
                        availableNames.isEmpty() -> "Not enough content to build this bundle"
                        offSeason -> "${Season.spotlightLabel(bundle, now)} · ${availableNames.joinToString(", ")}"
                        else -> availableNames.joinToString(", ")
                    }
                    val warning = if (enabled && !building && availableNames.isNotEmpty() && missingNames.isNotEmpty()) {
                        "Needs more content: ${missingNames.joinToString(", ")}"
                    } else null
                    ToggleRow(
                        title = bundle.name,
                        subtitle = subtitle,
                        detail = if (enabled) "${availableNames.size}/$total CH" else "$total CH",
                        warning = warning,
                        on = enabled,
                        loading = if (building) "BUILDING" else null,
                        modifier = Modifier.alpha(if (enabled && availableNames.isEmpty() && !building) 0.5f else 1f),
                    ) { model.toggleBundle(bundle.id) }
                }
            }
        }

        Divider()

        // ── SCHEDULE ──
        Column(verticalArrangement = Arrangement.spacedBy(u(20))) {
            SectionHeader("SCHEDULE", "How and when your library gets placed on the air")
            ToggleRow(
                title = "WATERSHED",
                subtitle = "Hold 18 and R-rated titles until 9 PM on every channel, like broadcast TV. VHS VAULT already holds its own this way; this applies it everywhere else.",
                on = model.watershed,
            ) { model.toggleWatershed() }
        }

        Text(
            model.versionLabel,
            style = font(DMMono, 20, Color.White.copy(alpha = 0.7f)),
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(top = u(12)),
        )
    }
    LaunchedEffect(Unit) { runCatching { first.requestFocus() } }
}

@Composable
private fun Divider() = Box(Modifier.fillMaxWidth().height(u(1)).background(Color.White.copy(alpha = 0.06f)))

@Composable
private fun SectionHeader(title: String, subtitle: String) {
    Column(verticalArrangement = Arrangement.spacedBy(u(6))) {
        Text(title, style = font(DMMonoMedium, 28, Color.White.copy(alpha = 0.8f)))
        Text(subtitle, style = font(DMMono, 20, Color.White.copy(alpha = 0.7f)))
    }
}

/** SettingsToggleRow: title, subtitle, an amber warning, a faint detail and the switch. */
@Composable
private fun ToggleRow(
    title: String,
    subtitle: String?,
    on: Boolean,
    modifier: Modifier = Modifier,
    detail: String? = null,
    warning: String? = null,
    loading: String? = null,
    showToggle: Boolean = true,
    onClick: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(u(10))
    Row(
        modifier
            .fillMaxWidth()
            .onFocusChanged { focused = it.isFocused }
            .focusable()
            .onKeyEvent { e ->
                when (e.key.nativeKeyCode) {
                    AndroidKeyEvent.KEYCODE_DPAD_CENTER, AndroidKeyEvent.KEYCODE_ENTER -> {
                        // On release, so the press that opened Settings can't also choose here.
                        if (e.type == KeyEventType.KeyUp) onClick()
                        true
                    }
                    else -> false
                }
            }
            .clip(shape)
            .background(Color.White.copy(alpha = if (focused) 0.07f else 0.02f))
            .border(u(1.5), if (focused) Cyan.copy(alpha = 0.5f) else Color.Transparent, shape)
            .padding(horizontal = u(24), vertical = u(18)),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(u(16)),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(u(4))) {
            Text(title, style = font(DMMonoMedium, 22, Color.White.copy(alpha = if (on) 1f else 0.35f)))
            if (subtitle != null) Text(subtitle, style = font(DMMono, 20, Color.White.copy(alpha = if (on) 0.8f else 0.5f)), maxLines = 3)
            if (warning != null) Text(warning, style = font(DMMono, 20, Amber), maxLines = 2)
        }
        when {
            loading != null -> Text(loading, style = font(DMMono, 20, Cyan.copy(alpha = 0.7f)))
            detail != null -> Text(detail, style = font(VT323, 20, Color.White.copy(alpha = 0.2f)))
        }
        if (loading == null && showToggle) ToggleSwitch(on)
    }
}

@Composable
private fun ToggleSwitch(on: Boolean) {
    Box(
        Modifier
            .size(u(52), u(30))
            .clip(CircleShape)
            .background(if (on) Cyan.copy(alpha = 0.3f) else Color.White.copy(alpha = 0.1f))
            .border(u(1), if (on) Cyan.copy(alpha = 0.5f) else Color.White.copy(alpha = 0.15f), CircleShape)
            .padding(u(3)),
        contentAlignment = if (on) Alignment.CenterEnd else Alignment.CenterStart,
    ) {
        Box(Modifier.size(u(24)).clip(CircleShape).background(if (on) Cyan else Color.White.copy(alpha = 0.7f)))
    }
}

/** LanguagePickerSheet and StreamQualityPickerSheet: a page of choices, the one in effect marked ACTIVE. */
@Composable
private fun PickerPage(title: String, subtitle: String, options: List<Triple<String, String, String?>>, selected: String, onPick: (String) -> Unit) {
    val current = remember { FocusRequester() }
    Column(
        Modifier
            .fillMaxSize()
            .background(Brush.linearGradient(listOf(PageTop, PageBottom)))
            .verticalScroll(rememberScrollState())
            .padding(horizontal = u(80), vertical = u(60)),
        verticalArrangement = Arrangement.spacedBy(u(20)),
    ) {
        Text(title, style = font(DMMonoMedium, 28, Color.White.copy(alpha = 0.8f)))
        Text(subtitle, style = font(DMMono, 20, Color.White.copy(alpha = 0.7f)))
        Column(verticalArrangement = Arrangement.spacedBy(u(6))) {
            for ((code, label, note) in options) {
                val isSel = code == selected
                var focused by remember { mutableStateOf(false) }
                val shape = RoundedCornerShape(u(10))
                Row(
                    (if (isSel) Modifier.focusRequester(current) else Modifier)
                        .fillMaxWidth()
                        .onFocusChanged { focused = it.isFocused }
                        .focusable()
                        .onKeyEvent { e ->
                            when (e.key.nativeKeyCode) {
                                AndroidKeyEvent.KEYCODE_DPAD_CENTER, AndroidKeyEvent.KEYCODE_ENTER -> {
                                    if (e.type == KeyEventType.KeyUp) onPick(code)
                                    true
                                }
                                else -> false
                            }
                        }
                        .clip(shape)
                        .background(Color.White.copy(alpha = if (focused) 0.07f else 0.02f))
                        .border(u(1.5), if (focused) Cyan.copy(alpha = 0.5f) else Color.Transparent, shape)
                        .padding(horizontal = u(24), vertical = u(18)),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(u(4))) {
                        Text(label, style = font(DMMonoMedium, 22, if (isSel) Cyan else Color.White.copy(alpha = 0.85f)))
                        if (note != null) Text(note, style = font(DMMono, 20, Color.White.copy(alpha = 0.6f)))
                    }
                    if (isSel) Text("ACTIVE", style = font(VT323, 20, Cyan.copy(alpha = 0.7f)))
                }
            }
        }
    }
    LaunchedEffect(Unit) { runCatching { current.requestFocus() } }
}

