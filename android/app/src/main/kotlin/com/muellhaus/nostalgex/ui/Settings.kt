package com.muellhaus.nostalgex.ui

import android.text.format.DateUtils
import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.nativeKeyCode
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.res.imageResource
import androidx.compose.ui.text.style.TextAlign
import androidx.tv.material3.Text
import com.muellhaus.nostalgex.AppModel
import com.muellhaus.nostalgex.SettingsCategory
import com.muellhaus.nostalgex.engine.ChannelConfig
import com.muellhaus.nostalgex.engine.ChannelRequirements
import com.muellhaus.nostalgex.engine.LanguageChoice
import com.muellhaus.nostalgex.engine.Lineup
import com.muellhaus.nostalgex.engine.Season
import com.muellhaus.nostalgex.engine.StreamQuality
import java.time.LocalDateTime

// Settings as a rail plus a pane (SettingsContainerView, N-028), at the Apple TV's measurements.
// Up and Down on the rail swap the pane with no press; Right or OK moves into its rows; Left
// from the rows lands on the selected category; Back steps out one level at a time.
// Not here: SUPPORT NOSTALGEX and NOSTALGEX PRO (no store tips or Pro on a sideloaded app),
// WATCH HISTORY (watch state isn't ported), iCloud sync (Apple only), FRANCHISES and MY
// COLLECTIONS as pages (found franchises and collections aren't ported, so FRANCHISES is a
// package under CHANNEL PACKAGES), and DISCORD and RATE NOSTALGEX, hidden on the Apple TV too.

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
        ) { model.chooseStreamQuality(StreamQuality.fromId(it)); model.settingsPicker = null; model.focusPane("stream_quality") }
        "sub_lang" -> PickerPage(
            title = "SUBTITLE LANGUAGE",
            subtitle = "When the video has multiple subtitle tracks, prefer this language",
            options = LanguageChoice.presets.map { Triple(it.code, it.label, null) },
            selected = model.subtitleLanguage,
        ) { model.chooseSubtitleLanguage(it); model.settingsPicker = null; model.focusPane("sub_lang") }
        "audio_lang" -> PickerPage(
            title = "AUDIO LANGUAGE",
            subtitle = "When the video has multiple audio tracks, prefer this language",
            options = LanguageChoice.presets.map { Triple(it.code, it.label, null) },
            selected = model.audioLanguage,
        ) { model.chooseAudioLanguage(it); model.settingsPicker = null; model.focusPane("audio_lang") }
        else -> RailAndPane(model)
    }
}

/** The pane's rows register here, so focus can be put on one by key, or on the first. */
private class PaneRows {
    val requesters = LinkedHashMap<String, FocusRequester>()
}

private val LocalPaneRows = compositionLocalOf { PaneRows() }

/**
 * A pane row: focusable under `key`. Focus on it means focus is in the pane, so Back
 * goes to the rail. Put before the row's own focusable.
 */
@Composable
private fun Modifier.paneRow(model: AppModel, key: String): Modifier {
    val requester = remember { FocusRequester() }
    LocalPaneRows.current.requesters[key] = requester
    return focusRequester(requester).onFocusChanged {
        if (it.isFocused) {
            model.settingsOnRail = false
            model.paneSwapping = false
        }
    }
}

@Composable
private fun RailAndPane(model: AppModel) {
    val railRequesters = remember { SettingsCategory.entries.associateWith { FocusRequester() } }
    // The rail takes focus as Settings opens, and whenever the rows hand it back; not while
    // a pane row is waiting for it (a picker just closed onto its row).
    LaunchedEffect(model.railFocusTick) {
        withFrameNanos { }
        if (model.paneFocusTick != model.paneTickHandled) return@LaunchedEffect
        runCatching { railRequesters.getValue(model.settingsCategory).requestFocus() }
    }
    Row(Modifier.fillMaxSize().background(Brush.linearGradient(listOf(PageTop, PageBottom)))) {
        Rail(model, railRequesters)
        Pane(model)
    }
}

/** SettingsRailView: SETTINGS, then one row per category with an accent bar that thickens on focus. */
@Composable
private fun Rail(model: AppModel, requesters: Map<SettingsCategory, FocusRequester>) {
    Column(
        Modifier
            .width(u(470))
            .fillMaxHeight()
            .background(Color(0.03f, 0.03f, 0.08f).copy(alpha = 0.95f))
            .drawBehind {
                // A very faint scanline texture, the rail's only.
                var y = 0f
                val step = 4 * size.width / 470f
                while (y < size.height) {
                    drawRect(Color.White.copy(alpha = 0.05f), topLeft = Offset(0f, y), size = Size(size.width, step / 4))
                    y += step
                }
                drawRect(Color.White.copy(alpha = 0.1f), topLeft = Offset(size.width - 1f, 0f), size = Size(1f, size.height))
            },
    ) {
        Text("SETTINGS", style = font(VT323, 44, Color.White.copy(alpha = 0.6f)), modifier = Modifier.padding(start = u(40), top = u(70), bottom = u(24)))
        Column(Modifier.padding(horizontal = u(20)), verticalArrangement = Arrangement.spacedBy(u(4))) {
            val all = SettingsCategory.entries
            for ((i, category) in all.withIndex()) {
                RailRow(
                    category, selected = model.settingsCategory == category, requester = requesters.getValue(category),
                    first = i == 0, last = i == all.size - 1,
                    onFocused = {
                        // Focus dropped here by a page swap, on its way to the new page: not a choice.
                        if (model.paneSwapping) return@RailRow
                        model.settingsOnRail = true
                        if (model.settingsCategory != category) {
                            model.settingsCategory = category
                            model.channelsPage = null
                        }
                    },
                    onActivate = { model.focusPane() },
                )
            }
        }
    }
}

@Composable
private fun RailRow(
    category: SettingsCategory,
    selected: Boolean,
    requester: FocusRequester,
    first: Boolean,
    last: Boolean,
    onFocused: () -> Unit,
    onActivate: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    val lit = focused || selected
    val shape = RoundedCornerShape(u(8))
    Row(
        Modifier
            .fillMaxWidth()
            .height(u(76))
            .focusRequester(requester)
            .onFocusChanged {
                focused = it.isFocused
                if (it.isFocused) onFocused()
            }
            .focusable()
            .onKeyEvent { e ->
                when (e.key.nativeKeyCode) {
                    // Right or OK moves into the category's rows.
                    AndroidKeyEvent.KEYCODE_DPAD_RIGHT, AndroidKeyEvent.KEYCODE_DPAD_CENTER, AndroidKeyEvent.KEYCODE_ENTER -> {
                        if (e.type == KeyEventType.KeyUp) onActivate()
                        true
                    }
                    // The rail ends at its first and last rows.
                    AndroidKeyEvent.KEYCODE_DPAD_UP -> first
                    AndroidKeyEvent.KEYCODE_DPAD_DOWN -> last
                    AndroidKeyEvent.KEYCODE_DPAD_LEFT -> true
                    else -> false
                }
            }
            .clip(shape)
            .background(if (focused) Cyan.copy(alpha = 0.22f) else if (selected) Color.White.copy(alpha = 0.06f) else Color.Transparent)
            .then(if (focused) Modifier.border(u(3), Cyan, shape) else Modifier)
            .padding(end = u(16)),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(u(18)),
    ) {
        Box(Modifier.width(u(if (focused) 8 else if (selected) 6 else 4)).fillMaxHeight().background(if (lit) Cyan else Cyan.copy(alpha = 0.3f)))
        // The Apple TV draws an SF Symbol here; Android has none, so the category's pixel icon.
        Image(
            ImageBitmap.imageResource(category.icon), contentDescription = null, filterQuality = FilterQuality.None,
            modifier = Modifier.size(u(32)).alpha(if (lit) 1f else 0.6f),
        )
        Text(category.title, style = font(DMMonoMedium, 24, if (lit) Color.White else Color.White.copy(alpha = 0.7f)), maxLines = 1)
    }
}

/** The pane: the category's pixel icon and title pinned at the top, its rows scrolling under them. */
@Composable
private fun Pane(model: AppModel) {
    val category = model.settingsCategory
    val page = if (category == SettingsCategory.CHANNELS) model.channelsPage else null
    val rows = remember(category, page) { PaneRows() }
    LaunchedEffect(model.paneFocusTick, category, page) {
        if (model.paneFocusTick == model.paneTickHandled) return@LaunchedEffect
        model.paneTickHandled = model.paneFocusTick
        withFrameNanos { }
        val target = model.paneFocusKey?.let { rows.requesters[it] } ?: rows.requesters.values.firstOrNull()
        runCatching { target?.requestFocus() }
        // Whether or not a row took it, the swap is over: the rail chooses categories again.
        model.paneSwapping = false
    }
    Column(
        Modifier
            .fillMaxSize()
            // Left from any row goes back to the selected category.
            .onPreviewKeyEvent { e ->
                if (e.key.nativeKeyCode != AndroidKeyEvent.KEYCODE_DPAD_LEFT || model.settingsOnRail) return@onPreviewKeyEvent false
                if (e.type == KeyEventType.KeyDown) model.focusRail()
                true
            },
    ) {
        Row(
            Modifier.padding(start = u(80), end = u(80), top = u(60), bottom = u(20)),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(u(28)),
        ) {
            // 16x16 pixel art at six design units a pixel, drawn without smoothing.
            Image(ImageBitmap.imageResource(category.icon), contentDescription = null, filterQuality = FilterQuality.None, modifier = Modifier.size(u(96)))
            Column(verticalArrangement = Arrangement.spacedBy(u(6))) {
                Text(category.title, style = font(DMMonoMedium, 34, Color.White), maxLines = 1)
                Text(category.subtitle, style = font(DMMono, 20, Color.White.copy(alpha = 0.7f)))
            }
        }
        Box(Modifier.padding(horizontal = u(80)).fillMaxWidth().height(u(1)).background(Color.White.copy(alpha = 0.06f)))
        Box(Modifier.fillMaxSize()) {
            CompositionLocalProvider(LocalPaneRows provides rows) {
                Column(
                    Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(start = u(80), end = u(80), top = u(48), bottom = u(80)),
                ) {
                    when (category) {
                        SettingsCategory.PLAYBACK -> PlaybackRows(model)
                        SettingsCategory.CHANNELS -> when (page) {
                            "packages" -> PackagesPage(model)
                            "missing" -> MissingPage(model)
                            else -> ChannelsList(model)
                        }
                        SettingsCategory.SERVERS -> ServerRows(model)
                        SettingsCategory.ABOUT -> AboutRows(model)
                    }
                }
            }
            // Rows dissolve as they slide under the pinned hero instead of being cut mid-line.
            Box(Modifier.fillMaxWidth().height(u(32)).background(Brush.verticalGradient(listOf(PageTop, PageTop.copy(alpha = 0f)))))
        }
    }
}

// ── PLAYBACK & PICTURE ──

@Composable
private fun PlaybackRows(model: AppModel) {
    Column(verticalArrangement = Arrangement.spacedBy(u(20))) {
        ToggleRow(
            title = "RETRO MODE",
            subtitle = "CRT scanlines, vignette, VHS glitch, 4:3 aspect ratio",
            on = model.retroMode,
            modifier = Modifier.paneRow(model, "retro_mode"),
        ) { model.toggleRetroMode() }
        // Two built-in sizes; OK switches between them.
        ToggleRow(
            title = "GUIDE TEXT SIZE",
            subtitle = "Bigger program titles, times and channel names in the guide",
            detail = if (model.guideTextLarge) "LARGE" else "NORMAL",
            on = true,
            showToggle = false,
            modifier = Modifier.paneRow(model, "guide_text_size"),
        ) { model.toggleGuideTextSize() }
        ToggleRow(
            title = "STREAM QUALITY",
            subtitle = "Lower this when your connection is slow or shared",
            detail = model.streamQuality.displayName,
            on = true,
            showToggle = false,
            modifier = Modifier.paneRow(model, "stream_quality"),
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
            modifier = Modifier.paneRow(model, "subtitles"),
        ) { model.cycleSubtitleMode() }
        if (model.subtitlesInFullScreen || model.autoSubtitles) {
            ToggleRow(
                title = "SUBTITLE LANGUAGE",
                subtitle = "When the video has multiple subtitle tracks, prefer this language",
                detail = LanguageChoice.presets.firstOrNull { it.code == model.subtitleLanguage }?.label ?: model.subtitleLanguage.uppercase(),
                on = true,
                showToggle = false,
                modifier = Modifier.paneRow(model, "sub_lang"),
            ) { model.settingsPicker = "sub_lang" }
        }
        ToggleRow(
            title = "AUDIO LANGUAGE",
            subtitle = "When the video has multiple audio tracks, prefer this language",
            detail = LanguageChoice.presets.firstOrNull { it.code == model.audioLanguage }?.label ?: model.audioLanguage.uppercase(),
            on = true,
            showToggle = false,
            modifier = Modifier.paneRow(model, "audio_lang"),
        ) { model.settingsPicker = "audio_lang" }
    }
}

// ── CHANNELS & BUNDLES ──

/** The packages with a switch: every one but the per-category collection ones. */
private fun lineupPackages(model: AppModel) = model.bundles.filter { !it.id.startsWith("collections-") }

/** The Channels list: CHANNEL PACKAGES with how many are on, then the WATERSHED switch. */
@Composable
private fun ChannelsList(model: AppModel) {
    Column(verticalArrangement = Arrangement.spacedBy(u(4))) {
        val on = lineupPackages(model).count { it.id in model.enabledBundles }
        LinkRow("CHANNEL PACKAGES", "$on ON", Modifier.paneRow(model, "channels_packages")) { model.openChannelsPage("packages") }
        ToggleRow(
            title = "WATERSHED",
            subtitle = "18 and R-rated titles wait until 9 PM",
            on = model.watershed,
            modifier = Modifier.paneRow(model, "watershed"),
        ) { model.toggleWatershed() }
    }
}

/** The packages that are on and built, and their channels the library doesn't fill (I-004). */
private fun missingGroups(model: AppModel): List<Pair<ChannelConfig.Bundle, List<Lineup.OffAir>>> {
    val lineup = model.lineup ?: return emptyList()
    return lineupPackages(model).filter { it.id in model.enabledBundles && it.id !in model.buildingBundles }
        .map { it to lineup.offAir(it) }.filter { it.second.isNotEmpty() }
}

@Composable
private fun PackagesPage(model: AppModel) {
    val lineup = model.lineup
    val now = LocalDateTime.now()
    val missingCount = missingGroups(model).sumOf { it.second.size }
    Column(verticalArrangement = Arrangement.spacedBy(u(20))) {
        SectionHeader("CHANNEL PACKAGES", "Each package adds a set of channels")
        Column(verticalArrangement = Arrangement.spacedBy(u(4))) {
            for (bundle in lineupPackages(model)) {
                val enabled = bundle.id in model.enabledBundles
                val availability = if (enabled) lineup?.availability(bundle) ?: emptyList() else emptyList()
                val available = availability.count { it.second }
                val missing = availability.size - available
                val total = bundle.channelIDs.size
                val building = enabled && bundle.id in model.buildingBundles
                // A seasonal package works in any month; its months decide when it's offered and leads.
                val subtitle = when {
                    building -> "Finding $total channel${if (total == 1) "" else "s"} in your library"
                    enabled && available == 0 -> "Not enough content to build this package"
                    Season.isSeasonal(bundle) && !Season.isInSeason(bundle, now) -> Season.spotlightLabel(bundle, now)
                    else -> bundle.description
                }
                ToggleRow(
                    title = bundle.name,
                    subtitle = subtitle.ifEmpty { null },
                    detail = if (enabled) "$available/$total CH" else "$total CH",
                    // Channels still short of content: an amber count, explained below.
                    badge = if (enabled && !building && available > 0 && missing > 0) missing else null,
                    on = enabled,
                    loading = if (building) "BUILDING" else null,
                    modifier = Modifier.paneRow(model, "bundle_${bundle.id}").alpha(if (enabled && available == 0 && !building) 0.5f else 1f),
                ) { model.toggleBundle(bundle.id) }
            }
            if (missingCount > 0) {
                LinkRow(
                    "WHY ARE SOME CHANNELS MISSING?", "$missingCount CH",
                    Modifier.paneRow(model, "channels_missing").padding(top = u(12)),
                ) { model.openChannelsPage("missing") }
            }
        }
    }
}

/** MISSING CHANNELS: each channel's rules in plain words, and how many titles match. Read-only. */
@Composable
private fun MissingPage(model: AppModel) {
    val groups = missingGroups(model)
    Column(verticalArrangement = Arrangement.spacedBy(u(20))) {
        SectionHeader("MISSING CHANNELS", "A channel goes on air once your library has enough titles that fit it")
        if (groups.isEmpty()) {
            var focused by remember { mutableStateOf(false) }
            Text(
                "Every channel in your packages is on air.",
                style = font(DMMono, 20, Color.White.copy(alpha = if (focused) 1f else 0.7f)),
                modifier = Modifier.paneRow(model, "missing_none").onFocusChanged { focused = it.isFocused }.focusable(),
            )
        }
        for ((bundle, channels) in groups) {
            Column(verticalArrangement = Arrangement.spacedBy(u(6))) {
                Subheader(bundle.name)
                for (o in channels) RequirementCard(o, Modifier.paneRow(model, "missing_card_${o.def.id}"))
            }
        }
    }
}

// ── SERVERS & ACCOUNTS ──

@Composable
private fun ServerRows(model: AppModel) {
    Column(verticalArrangement = Arrangement.spacedBy(u(12))) {
        Subheader("SERVERS")
        val selected = model.selectedServers
        for (server in model.serversForSettings) {
            val included = selected.any { it.machineIdentifier == server.machineIdentifier }
            val isLast = included && selected.size <= 1
            ToggleRow(
                title = server.name.uppercase(),
                subtitle = if (isLast) "Your server · only connected server" else if (server.owned) "Your server" else "Shared with you",
                detail = if (included) "INCLUDED" else "OFF",
                on = included,
                // No switch on the only server: it can't be removed.
                showToggle = !isLast,
                modifier = Modifier.paneRow(model, "server_${server.machineIdentifier}"),
            ) { model.toggleServer(server) }
        }
        // One row per library on the servers in use; one switched off is never scanned.
        // The last one on has no switch, as the last server.
        if (model.availableSections.isNotEmpty()) {
            Subheader("LIBRARIES")
            val multiServer = model.availableSections.map { it.serverId }.toSet().size > 1
            for (section in model.availableSections) {
                val on = section.id !in model.deselectedSections
                val isLast = on && model.enabledSectionCount <= 1
                ToggleRow(
                    title = section.title.uppercase(),
                    subtitle = when {
                        isLast -> "${section.typeLabel} · only enabled library"
                        multiServer -> "${section.serverName} · ${section.typeLabel}"
                        else -> section.typeLabel
                    },
                    detail = if (on) "INCLUDED" else "OFF",
                    on = on,
                    showToggle = !isLast,
                    modifier = Modifier.paneRow(model, "section_${section.id}"),
                ) { model.toggleLibrarySection(section) }
            }
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
            modifier = Modifier.paneRow(model, "rescan").padding(top = u(8)),
        ) { model.rescanLibrary() }
        ToggleRow(
            title = "DISCONNECT FROM ${model.backendName.uppercase()}",
            subtitle = "Clears saved ${model.backendName} access. Use when switching servers",
            on = true,
            showToggle = false,
            modifier = Modifier.paneRow(model, "disconnect"),
        ) { model.signOut() }
    }
}

// ── ABOUT ──

@Composable
private fun AboutRows(model: AppModel) {
    Column(verticalArrangement = Arrangement.spacedBy(u(20))) {
        // Focusable so the remote has somewhere to land; OK does nothing.
        ToggleRow(
            title = "VERSION",
            subtitle = "The build number tells two builds of one version apart",
            detail = model.versionLabel.removePrefix("VERSION "),
            prominentDetail = true,
            on = true,
            showToggle = false,
            modifier = Modifier.paneRow(model, "about_version"),
        ) {}
        Box(Modifier.padding(top = u(24))) { SectionHeader("LINKS", null) }
        ToggleRow(
            title = "GITHUB",
            subtitle = "Source code and issues. Open it on a phone or computer.",
            detail = "github.com/chadMueller/Nostalgex",
            prominentDetail = true,
            on = true,
            showToggle = false,
            modifier = Modifier.paneRow(model, "about_github"),
        ) {}
    }
}

@Composable
private fun SectionHeader(title: String, subtitle: String?) {
    Column(verticalArrangement = Arrangement.spacedBy(u(6))) {
        Text(title, style = font(DMMonoMedium, 28, Color.White.copy(alpha = 0.8f)))
        if (subtitle != null) Text(subtitle, style = font(DMMono, 20, Color.White.copy(alpha = 0.7f)))
    }
}

@Composable
private fun Subheader(text: String) = Text(text, style = font(DMMono, 20, Color.White.copy(alpha = 0.7f)), modifier = Modifier.padding(top = u(4)))

/** SettingsLinkRow: a title, its value on the right in cyan when focused, and a chevron. */
@Composable
private fun LinkRow(title: String, value: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(u(10))
    Row(
        modifier
            .fillMaxWidth()
            .onFocusChanged { focused = it.isFocused }
            .focusable()
            .onKeyEvent { e ->
                if (e.key.nativeKeyCode != AndroidKeyEvent.KEYCODE_DPAD_CENTER && e.key.nativeKeyCode != AndroidKeyEvent.KEYCODE_ENTER) return@onKeyEvent false
                if (e.type == KeyEventType.KeyUp) onClick()
                true
            }
            .clip(shape)
            .background(Color.White.copy(alpha = if (focused) 0.07f else 0.02f))
            .border(u(1.5), if (focused) Cyan.copy(alpha = 0.5f) else Color.Transparent, shape)
            .padding(horizontal = u(24), vertical = u(22)),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(u(16)),
    ) {
        Text(title, style = font(DMMonoMedium, 22, Color.White), modifier = Modifier.weight(1f))
        Text(value, style = font(DMMonoMedium, 22, if (focused) Cyan else Color.White.copy(alpha = 0.6f)))
        Text("›", style = font(DMMonoMedium, 30, if (focused) Cyan else Color.White.copy(alpha = 0.35f)))
    }
}

/** AlertCountBadge: a small amber count, such as channels still short of content. */
@Composable
private fun AlertBadge(count: Int) {
    Box(
        Modifier.defaultMinSize(u(34), u(34)).clip(RoundedCornerShape(50)).background(Amber).padding(horizontal = u(if (count > 9) 9 else 0)),
        contentAlignment = Alignment.Center,
    ) {
        Text(if (count > 99) "99+" else count.toString(), style = font(DMMonoMedium, 20, Color(0xFF0A0A1A)))
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
    /** The detail in white at 22 rather than the faint VT323, for a value worth reading (VERSION). */
    prominentDetail: Boolean = false,
    warning: String? = null,
    /** A small amber count beside the detail. */
    badge: Int? = null,
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
        if (loading != null) {
            Text(loading, style = font(DMMono, 20, Cyan.copy(alpha = 0.7f)))
        } else {
            if (badge != null) AlertBadge(badge)
            if (detail != null) {
                Text(detail, style = if (prominentDetail) font(DMMonoMedium, 22, Color.White.copy(alpha = 0.85f)) else font(VT323, 20, Color.White.copy(alpha = 0.2f)))
            }
        }
        if (loading == null && showToggle) ToggleSwitch(on)
    }
}

/** ChannelRequirementCard: the channel, how many titles it needs against how many match, and its rules. Takes focus, so the list can be read row by row. */
@Composable
private fun RequirementCard(o: Lineup.OffAir, modifier: Modifier = Modifier) {
    val need = o.def.minItems
    var focused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(u(8))
    Column(
        modifier
            .fillMaxWidth()
            .onFocusChanged { focused = it.isFocused }
            .focusable()
            .clip(shape)
            .background(Color.White.copy(alpha = if (focused) 0.07f else 0.03f))
            .border(u(1.5), if (focused) Cyan.copy(alpha = 0.5f) else Color.Transparent, shape)
            .padding(horizontal = u(20), vertical = u(14)),
        verticalArrangement = Arrangement.spacedBy(u(8)),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(u(10))) {
            Box(Modifier.size(u(4), u(18)).background(hex(o.def.colorHex)))
            Text(o.def.name.uppercase(), style = font(DMMonoMedium, 20, Color.White))
        }
        Text("Needs $need matching title${if (need == 1) "" else "s"}. You have ${o.matched}.", style = font(DMMono, 18, Amber))
        Column(verticalArrangement = Arrangement.spacedBy(u(4))) {
            for (line in ChannelRequirements.plainLanguage(o.def.rules)) {
                Text("\u2022 $line", style = font(DMMono, 18, Color.White.copy(alpha = 0.65f)))
            }
        }
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

