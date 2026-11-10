import SwiftUI

/// "Still watching?" overlay shown when the sleep timer reaches zero. It grabs focus and
/// routes the next remote input (any direction, Play/Pause, or Back) to `onStayAwake`.
/// If ignored, `AppState`'s 20s grace timer stops playback on its own.
struct SleepGracePrompt: View {
    var onStayAwake: () -> Void

    @FocusState private var focused: Bool
    @State private var deadline: Date?

    var body: some View {
        ZStack {
            Color.black.opacity(0.8).ignoresSafeArea()

            VStack(spacing: 16) {
                Text("STILL WATCHING?")
                    .font(NXFont.heading)
                    .foregroundStyle(Color.nxText)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, (deadline ?? context.date).timeIntervalSince(context.date))
                    Text("SLEEPING IN \(SleepTimerLogic.countdownLabel(remaining: remaining))")
                        .font(NXFont.bodyRegular)
                        .foregroundStyle(Color.nxYellow)
                }

                Text("PRESS ANY BUTTON TO KEEP WATCHING")
                    .font(NXFont.captionRegular)
                    .foregroundStyle(Color.nxText2)
                    .padding(.top, 4)
            }
            .padding(48)
            .background(
                RoundedRectangle(cornerRadius: NXLayout.rowRadius, style: .continuous)
                    .fill(Color.nxPanel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: NXLayout.rowRadius, style: .continuous)
                    .strokeBorder(Color.nxRestingOutline, lineWidth: NXLayout.restingOutline)
            )
        }
        .focusable(true)
        .focused($focused)
        .onAppear {
            deadline = Date().addingTimeInterval(20)
            focused = true
        }
        .onExitCommand { onStayAwake() }
        .onPlayPauseCommand { onStayAwake() }
        .onMoveCommand { _ in onStayAwake() }
    }
}

/// Focus targets inside the Now Playing panel.
enum NowPlayingFocus: Hashable {
    case cc
    /// The collapsed AUDIO row (it opens the track list).
    case audioRow
    /// A track inside the audio list, by `AudioTrackDescriptor.id`.
    case audio(Int)
    /// The collapsed SLEEP TIMER row (it opens the list).
    case sleepRow
    /// A choice inside the sleep list, in minutes; -1 == OFF.
    case sleep(Int)
    case retro
    case streamQuality
    case playbackInformation
    case subtitleLanguage
    case audioLanguage
    case autoSubtitles
    case openInPlex
    case compatibilityRetry
    /// A row inside an expanded picker, keyed by that option's own stable id
    /// (a `StreamQuality.id` or a language code).
    case option(String)
}

/// The multi-value settings the panel can expand into a list.
///
/// These open as a `.sheet` on the settings page, which is the wrong tool here: the panel
/// already sits inside a `fullScreenCover` over live video, and presenting a sheet from
/// there fights the focus engine. Expanding in place keeps everything in one flat focus
/// section and one presentation layer.
private enum PanelPicker: Hashable {
    case streamQuality
    case playbackInformation
    case subtitleLanguage
    case audioLanguage
    case audioTracks
    case sleepTimer
}

/// Top-anchored in-player control panel opened with the Siri Remote UP button, the
/// counterpart to the bottom mini-guide. Left: what is playing and what is next. Middle: what
/// this program is doing (captions, audio). Right: what the device is doing (picture, stream
/// quality, sleep timer). Built on the shared design tokens (`DesignTokens.swift`): six type
/// sizes, one row, the cyan selected state, channel color never as text.
struct NowPlayingPanel: View {
    @Environment(AppState.self) var appState
    let channel: Channel
    let item: PlexMediaItem
    var onDismiss: (() -> Void)? = nil

    @FocusState private var focusedControl: NowPlayingFocus?

    /// Non-nil while one of the multi-value settings has taken over the controls area.
    @State private var expandedPicker: PanelPicker?

    /// Where focus should land once the collapsed columns come back. Assigning
    /// `focusedControl` at the moment a picker closes is dropped — the rows it names do
    /// not exist yet — so the value is parked here and applied from the columns' onAppear.
    @State private var focusAfterCollapse: NowPlayingFocus?

    @State private var streamQuality = StreamQuality.current
    @AppStorage(LocalPlexOriginalQuality.storageKey, store: AppDefaults.standard) private var localOriginalVideo = false

    /// The identity column gets the room: 540 + 44 + 560 + 36 + 560 fills the width inside the 90 pt safe
    /// margins. 560 is what the longest row still needs at 29 pt (PLAYBACK INFORMATION, its value and its
    /// chevron: 495 pt of the 504 pt inside the row's padding).
    private let infoWidth: CGFloat = 540
    private let columnWidth: CGFloat = 560
    private let columnGap: CGFloat = 36

    private var schedule: ChannelSchedule? {
        ChannelScheduleBuilder.buildSchedule(
            for: channel,
            credentialFingerprint: appState.scheduleCredentialFingerprint
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 44) {
            infoZone
            controlsZone
        }
        .padding(.horizontal, NXLayout.safeX)
        .padding(.top, NXLayout.safeY)
        .padding(.bottom, 56)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(
                stops: [
                    .init(color: Color.nxPanel.opacity(0.96), location: 0),
                    .init(color: Color.nxPanel.opacity(0.96), location: 0.85),
                    .init(color: Color.nxPanel.opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onExitCommand {
            // Back closes an expanded picker first. Dropping straight out to bare
            // playback from inside a list would lose the panel on a mis-press.
            if let picker = expandedPicker {
                collapsePicker(owner: picker)
            } else {
                onDismiss?()
            }
        }
        // Hand focus back to the row that owned the picker once the columns return.
        // This has to happen on a hop after the swap: the rows do not exist while the
        // picker is still on screen, and an assignment made in the same update loses to
        // the focus engine's own pass over the rows it has just been handed (which puts
        // focus on the first one, CC).
        .onChange(of: expandedPicker) { _, picker in
            guard picker == nil, let target = focusAfterCollapse else { return }
            focusAfterCollapse = nil
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 60_000_000)
                focusedControl = target
            }
        }
    }

    // MARK: - Info zone (non-focusable)

    private var infoZone: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Poster only when the backend can serve one (Plex's thumbnail transcode
            // carries the token in the URL, so AsyncImage needs no header support).
            // The panel reads fine without it on Jellyfin/Emby.
            if let poster = appState.posterURL(for: item) {
                AsyncImage(url: poster) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.nxRow
                }
                .frame(width: 200, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.nxRestingOutline, lineWidth: 2)
                )
            }

            // The channel's own color is a small bar beside the number, never the number.
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(channel.color)
                    .frame(width: 12, height: 36)
                Text("CH \(channel.number)")
                    .font(NXFont.tag)
                    .foregroundStyle(Color.nxText)
            }

            // Title leads as the big headline, channel name follows smaller below it
            // (Discord feedback, 2026-10-29: viewers read this as "what's
            // playing", so the title should dominate and the channel is secondary).
            Text(titleLine)
                .font(NXFont.title)
                .foregroundStyle(Color.nxText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Text(channel.name.uppercased())
                .font(NXFont.bodyRegular)
                .foregroundStyle(Color.nxText2)
                .lineLimit(2)

            if let meta = metaLine {
                Text(meta)
                    .font(NXFont.captionRegular)
                    .foregroundStyle(Color.nxText2)
            }

            if let next = schedule?.upNext?.item {
                VStack(alignment: .leading, spacing: 8) {
                    Text("UP NEXT")
                        .font(NXFont.captionMedium)
                        .tracking(3)
                        .foregroundStyle(Color.nxYellow)
                    Text(next.isMusicVideo ? next.musicDisplayLine : next.title)
                        .font(NXFont.bodyRegular)
                        .foregroundStyle(Color.nxText)
                        .lineLimit(2)
                }
                .padding(.top, 6)
            }
        }
        .frame(width: infoWidth, alignment: .leading)
    }

    /// The title, or the artist and song for a music video.
    private var titleLine: String {
        item.isMusicVideo ? item.musicDisplayLine : item.title
    }

    /// "1985 · PG-13": the year (not for a music video) and the content rating, whichever exist.
    private var metaLine: String? {
        var parts: [String] = []
        if !item.isMusicVideo, let year = item.year { parts.append(String(year)) }
        if let rating = item.contentRating, !rating.isEmpty { parts.append(rating.uppercased()) }
        return parts.isEmpty ? nil : parts.joined(separator: "  \u{00B7}  ")
    }

    // MARK: - Controls zone
    //
    // Still exactly one flat focus section, whichever state the panel is in. Nested focus
    // sections trap the tvOS focus engine and block up/down travel, so the two columns are
    // plain sibling VStacks of buttons under a single `.focusSection()` and the engine
    // resolves up/down and left/right between them geometrically.

    @ViewBuilder
    private var controlsZone: some View {
        if let picker = expandedPicker {
            pickerZone(picker)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                // Each column is as tall as the taller one, and is a focus section: Right or Left from a row
                // with nothing beside it (OPEN IN PLEX, at the foot of a longer left column) still moves into
                // the other column, to the row nearest, instead of doing nothing.
                HStack(alignment: .top, spacing: columnGap) {
                    programColumn
                        .frame(maxHeight: .infinity, alignment: .top)
                        .focusSection()
                    deviceColumn
                        .frame(maxHeight: .infinity, alignment: .top)
                        .focusSection()
                }
                // Only as tall as the taller column, never the whole screen: the hint sits right under it.
                .fixedSize(horizontal: false, vertical: true)
                hintLine(NowPlayingPanelHints.hint(for: focusedControl) ?? " ", status: compatibilityHintOverride,
                         width: columnWidth * 2 + columnGap)
            }
            .focusSection()
            .onAppear { focusedControl = .cc }
        }
    }

    /// The RETRY ORIGINAL VIDEO result replaces its hint while that row has focus, as the note under
    /// the row did before.
    private var compatibilityHintOverride: String? {
        focusedControl == .compatibilityRetry ? compatibilityStatus : nil
    }

    /// One fixed two-line slot, so row heights never change when the hint does. The playback
    /// information note is four sentences, so that list gets the full width and room for them.
    private func hintLine(_ text: String, status: String? = nil, lines: Int = 2, width: CGFloat? = nil) -> some View {
        Text(status ?? text)
            .font(NXFont.captionRegular)
            .foregroundStyle(Color.nxText2)
            .lineLimit(lines)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width ?? columnWidth, alignment: .topLeading)
            .frame(minHeight: 64, alignment: .topLeading)
    }

    /// Controls that act on the program playing right now.
    private var programColumn: some View {
        VStack(alignment: .leading, spacing: NXLayout.rowGap) {
            ForEach(
                NowPlayingPanelLayout.programRows(
                    hasSubtitleTracks: appState.hasSubtitleTracks,
                    audioTrackCount: appState.audioTracks.count,
                    canOpenInPlex: appState.canOpenCurrentItemInPlex
                ),
                id: \.self
            ) { row in
                programRow(row)
            }
        }
        .frame(width: columnWidth, alignment: .leading)
    }

    @ViewBuilder
    private func programRow(_ row: NowPlayingProgramRow) -> some View {
        switch row {
        case .header:
            groupLabel("AUDIO & CAPTIONS")
        case .captions:
            ccRow
        case .subtitleLanguage:
            pickerRow(
                .subtitleLanguage,
                title: "SUBTITLE LANGUAGE",
                value: SubtitleLanguagePreset.shortLabel(for: appState.preferredSubtitleLanguageCode),
                focus: .subtitleLanguage
            )
        case .autoSubtitles:
            autoSubtitlesRow
        case .audio:
            audioRow
        case .openInPlex:
            openInPlexRow
                .padding(.top, 6)
        case .audioLanguage:
            pickerRow(
                .audioLanguage,
                title: "AUDIO LANGUAGE",
                value: SubtitleLanguagePreset.shortLabel(for: appState.preferredAudioLanguageCode),
                focus: .audioLanguage
            )
        }
    }

    /// Controls that act on the device rather than on this program.
    private var deviceColumn: some View {
        VStack(alignment: .leading, spacing: NXLayout.rowGap) {
            groupLabel("PICTURE")
            retroRow
            streamQualityRow
            if appState.canRetryOriginalVideo {
                compatibilityRetryRow
            }
            pickerRow(.playbackInformation, title: "PLAYBACK INFORMATION", value: "VIEW", focus: .playbackInformation)
            sleepTimerRow
                .padding(.top, 6)
        }
        .frame(width: columnWidth, alignment: .leading)
    }

    // MARK: - Rows

    // CC toggle — flips the global subtitlesInFullscreenEnabled, i.e. the settings page's
    // SUBTITLES (FULLSCREEN) row under its player name. Always focusable so initial focus
    // reliably lands here; a no-caption stream just shows "NONE" and no-ops.
    private var ccRow: some View {
        Button {
            guard appState.hasSubtitleTracks else { return }
            appState.subtitlesInFullscreenEnabled.toggle()
        } label: {
            PanelRow(
                label: "CC",
                value: appState.hasSubtitleTracks
                    ? (appState.subtitlesInFullscreenEnabled ? .on : .off)
                    : .text("NONE"),
                isFocused: focusedControl == .cc
            )
        }
        .buttonStyle(NoHighlightButtonStyle())
        .focused($focusedControl, equals: .cc)
        .accessibilityLabel("CC")
        .accessibilityValue(appState.hasSubtitleTracks ? (appState.subtitlesInFullscreenEnabled ? "ON" : "OFF") : "NONE")
    }

    @State private var compatibilityStatus: String?

    private var compatibilityRetryRow: some View {
        Button {
            compatibilityStatus = "CHECKING SERVER"
            Task { @MainActor in
                compatibilityStatus = await appState.retryOriginalVideoCompatibility()
            }
        } label: {
            PanelRow(
                label: "RETRY ORIGINAL VIDEO",
                // While it runs the row shows a spinner; "CHECKING SERVER" is the hint line.
                value: .none,
                trailing: appState.compatibilityRetryInFlight ? .busy : .retry,
                isFocused: focusedControl == .compatibilityRetry
            )
        }
        .buttonStyle(NoHighlightButtonStyle())
        .focused($focusedControl, equals: .compatibilityRetry)
        .disabled(appState.compatibilityRetryInFlight)
        .accessibilityLabel("RETRY ORIGINAL VIDEO")
    }

    @State private var openInPlexStatus: String?

    private var openInPlexRow: some View {
        Button {
            appState.openCurrentItemInPlex { [self] opened in
                if !opened { openInPlexStatus = "NO PLEX APP" }
            }
        } label: {
            PanelRow(
                label: "OPEN IN PLEX",
                value: openInPlexStatus.map { PanelRow.Value.warning($0) } ?? PanelRow.Value.none,
                trailing: .external,
                isFocused: focusedControl == .openInPlex
            )
        }
        .buttonStyle(NoHighlightButtonStyle())
        .focused($focusedControl, equals: .openInPlex)
        .accessibilityLabel("OPEN IN PLEX")
    }

    private var autoSubtitlesRow: some View {
        Button {
            appState.autoSubtitlesForForeignAudioEnabled.toggle()
        } label: {
            PanelRow(
                label: "AUTO SUBTITLES",
                value: appState.autoSubtitlesForForeignAudioEnabled ? .on : .off,
                isFocused: focusedControl == .autoSubtitles
            )
        }
        .buttonStyle(NoHighlightButtonStyle())
        .focused($focusedControl, equals: .autoSubtitles)
        .accessibilityLabel("AUTO SUBTITLES")
        .accessibilityValue(appState.autoSubtitlesForForeignAudioEnabled ? "ON" : "OFF")
    }

    private var retroRow: some View {
        Button {
            appState.retroMode.toggle()
        } label: {
            PanelRow(
                label: "RETRO MODE",
                value: appState.retroMode ? .on : .off,
                isFocused: focusedControl == .retro
            )
        }
        .buttonStyle(NoHighlightButtonStyle())
        .focused($focusedControl, equals: .retro)
        .accessibilityLabel("RETRO MODE")
        .accessibilityValue(appState.retroMode ? "ON" : "OFF")
    }

    // Stream quality is shown for every program, not just transcoded ones: nothing
    // observable tells the panel whether the current stream is a transcode or a direct
    // play, and a row that vanished unpredictably would be worse than one that is
    // occasionally inert. The "takes effect on the next program" note is the hint line.
    private var streamQualityRow: some View {
        pickerRow(
            .streamQuality,
            title: "STREAM QUALITY",
            // The row shows the short word; the list keeps the full wording.
            value: localOriginalVideo && appState.backendKind == .plex ? "ORIGINAL" : streamQuality.displayName.uppercased(),
            focus: .streamQuality
        )
    }

    /// A collapsed multi-value row: current value on the right, a chevron, expands in place on select.
    private func pickerRow(
        _ picker: PanelPicker,
        title: String,
        value: String,
        focus: NowPlayingFocus
    ) -> some View {
        Button {
            expandPicker(picker)
        } label: {
            PanelRow(label: title, value: .text(value), trailing: .chevron, isFocused: focusedControl == focus)
        }
        .buttonStyle(NoHighlightButtonStyle())
        .focused($focusedControl, equals: focus)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    // Audio: one row showing the current track, opening the track list when there is a choice.
    // A single-/no-track item shows a plain row the focus engine skips straight past.
    @ViewBuilder
    private var audioRow: some View {
        if NowPlayingPanelLayout.audioRowOpensList(trackCount: appState.audioTracks.count) {
            pickerRow(.audioTracks, title: "AUDIO", value: currentAudioName, focus: .audioRow)
        } else {
            PanelRow(
                label: appState.audioTracks.first?.displayName ?? "SINGLE TRACK",
                value: .none,
                isFocused: false,
                isStatic: true
            )
        }
    }

    private var currentAudioName: String {
        appState.audioTracks.first { $0.id == appState.selectedAudioTrackID }?.displayName
            ?? appState.audioTracks.first?.displayName ?? ""
    }

    /// SLEEP TIMER reads OFF, or the countdown in yellow while one runs, so OFF can never look like ON.
    private var sleepTimerRow: some View {
        Button {
            expandPicker(.sleepTimer)
        } label: {
            if appState.sleepTimerEndDate != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = SleepTimerLogic.remaining(from: appState.sleepTimerEndDate, now: context.date) ?? 0
                    PanelRow(label: "SLEEP TIMER", value: .live(SleepTimerLogic.countdownLabel(remaining: remaining)),
                             trailing: .chevron, isFocused: focusedControl == .sleepRow)
                }
            } else {
                PanelRow(label: "SLEEP TIMER", value: .text("OFF"), trailing: .chevron, isFocused: focusedControl == .sleepRow)
            }
        }
        .buttonStyle(NoHighlightButtonStyle())
        .focused($focusedControl, equals: .sleepRow)
        .accessibilityLabel("SLEEP TIMER")
        .accessibilityValue(appState.sleepTimerEndDate != nil ? "ON" : "OFF")
    }

    // MARK: - Expanded picker

    private func expandPicker(_ picker: PanelPicker) {
        expandedPicker = picker
    }

    private func collapsePicker(owner picker: PanelPicker) {
        focusAfterCollapse = {
            switch picker {
            case .streamQuality:    return .streamQuality
            case .subtitleLanguage: return .subtitleLanguage
            case .audioLanguage:    return .audioLanguage
            case .playbackInformation: return .playbackInformation
            case .audioTracks:      return .audioRow
            case .sleepTimer:       return .sleepRow
            }
        }()
        expandedPicker = nil
    }

    /// The picker takes over the whole controls area rather than pushing its options in
    /// underneath the other rows. Sixteen languages inlined below a row would run the
    /// panel off the bottom of the screen; swapping keeps the panel roughly the height it
    /// already is, and the options are still ordinary buttons in the one focus section.
    /// A list opened from the right column (stream quality, sleep timer) sits under it.
    @ViewBuilder
    private func pickerZone(_ picker: PanelPicker) -> some View {
        VStack(alignment: .leading, spacing: NXLayout.rowGap) {
            groupLabel(pickerTitle(picker), live: pickerLive(picker))
            switch picker {
            case .playbackInformation:
                playbackInformationContents
            case .streamQuality:
                streamQualityOptions
            case .subtitleLanguage:
                languageOptions(picker, selected: appState.preferredSubtitleLanguageCode) {
                    appState.preferredSubtitleLanguageCode = $0
                }
            case .audioLanguage:
                languageOptions(picker, selected: appState.preferredAudioLanguageCode) {
                    appState.preferredAudioLanguageCode = $0
                }
            case .audioTracks:
                audioTrackOptions
            case .sleepTimer:
                sleepOptions
            }
            // A list that opens from the left spans both columns; one from the right sits under its column.
            hintLine(pickerHint(picker),
                     lines: (picker == .playbackInformation || picker == .streamQuality) ? 4 : 2,
                     width: pickerOffset(picker) == 0 ? columnWidth * 2 + columnGap : columnWidth)
                .padding(.top, 8)
        }
        .padding(.leading, pickerOffset(picker))
        .focusSection()
        .onAppear { focusedControl = initialFocus(picker) }
    }

    /// Lists that open from the right column sit under it, as the sleep list does in the design.
    private func pickerOffset(_ picker: PanelPicker) -> CGFloat {
        switch picker {
        case .streamQuality, .sleepTimer: return columnWidth + columnGap
        default: return 0
        }
    }

    /// Reuses the panel's in-place navigation. Playback continues; Back returns focus
    /// to the information row rather than dismissing the whole panel.
    private var playbackInformationContents: some View {
        VStack(alignment: .leading, spacing: NXLayout.rowGap) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    if appState.playbackInformationRows.isEmpty {
                        Text("Playback information is unavailable.")
                            .font(NXFont.bodyRegular)
                            .foregroundStyle(Color.nxText2)
                    } else {
                        ForEach(appState.playbackInformationRows) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 24) {
                                Text(row.label)
                                    .font(NXFont.captionMedium)
                                    .foregroundStyle(Color.nxText2)
                                    .frame(width: 330, alignment: .leading)
                                Text(row.value)
                                    .font(NXFont.bodyRegular)
                                    .foregroundStyle(Color.nxText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            Button { collapsePicker(owner: .playbackInformation) } label: {
                PanelRow(label: "BACK", value: .none, isFocused: focusedControl == .option("information-back"))
            }
            .buttonStyle(NoHighlightButtonStyle())
            .focused($focusedControl, equals: .option("information-back"))
            .accessibilityLabel("Back to playback controls")
            .frame(width: columnWidth)
            .padding(.top, 8)
        }
        .frame(width: columnWidth * 2 + columnGap, alignment: .leading)
    }

    private var streamQualityOptions: some View {
        VStack(alignment: .leading, spacing: NXLayout.rowGap) {
            if appState.backendKind == .plex {
                Button {
                    localOriginalVideo.toggle()
                    collapsePicker(owner: .streamQuality)
                } label: {
                    PanelRow(label: "ORIGINAL (LOCAL PLEX)", value: .none, trailing: localOriginalVideo ? .check : .none,
                             isFocused: focusedControl == .option("local-original"))
                }
                .buttonStyle(NoHighlightButtonStyle())
                .focused($focusedControl, equals: .option("local-original"))
                .accessibilityLabel("ORIGINAL (LOCAL PLEX)")
            }
            ForEach(StreamQuality.allCases) { quality in
                Button {
                    localOriginalVideo = false
                    StreamQuality.current = quality
                    streamQuality = quality
                    collapsePicker(owner: .streamQuality)
                } label: {
                    PanelRow(
                        label: quality.displayName.uppercased(),
                        value: quality == streamQuality && localOriginalVideo ? .text("OTHER PLAYBACK") : .none,
                        trailing: quality == streamQuality && !localOriginalVideo ? .check : .none,
                        isFocused: focusedControl == .option(quality.id)
                    )
                }
                .buttonStyle(NoHighlightButtonStyle())
                .focused($focusedControl, equals: .option(quality.id))
                .accessibilityLabel(quality.displayName.uppercased())
            }
        }
        .frame(width: columnWidth, alignment: .leading)
    }

    private var audioTrackOptions: some View {
        VStack(alignment: .leading, spacing: NXLayout.rowGap) {
            ForEach(appState.audioTracks) { track in
                Button {
                    appState.selectAudioTrack(id: track.id)
                    collapsePicker(owner: .audioTracks)
                } label: {
                    PanelRow(label: track.displayName, value: .none,
                             trailing: track.id == appState.selectedAudioTrackID ? .check : .none,
                             isFocused: focusedControl == .audio(track.id))
                }
                .buttonStyle(NoHighlightButtonStyle())
                .focused($focusedControl, equals: .audio(track.id))
                .accessibilityLabel(track.displayName)
            }
        }
        .frame(width: columnWidth, alignment: .leading)
    }

    /// OFF and the offered times. A timer that is running shows its countdown beside the title.
    private var sleepOptions: some View {
        VStack(alignment: .leading, spacing: NXLayout.rowGap) {
            ForEach([0] + SleepTimerLogic.offeredMinutes(armed: appState.sleepTimerMinutes), id: \.self) { minutes in
                let isOff = minutes == 0
                let armed = appState.sleepTimerEndDate != nil
                let isChosen = isOff ? !armed : (armed && appState.sleepTimerMinutes == minutes)
                Button {
                    if isOff {
                        appState.cancelSleepTimer()
                    } else {
                        appState.startSleepTimer(minutes: minutes)
                    }
                    collapsePicker(owner: .sleepTimer)
                } label: {
                    PanelRow(label: isOff ? "OFF" : SleepTimerLogic.label(minutes: minutes), value: .none,
                             trailing: isChosen ? .check : .none,
                             isFocused: focusedControl == .sleep(isOff ? -1 : minutes))
                }
                .buttonStyle(NoHighlightButtonStyle())
                .focused($focusedControl, equals: .sleep(isOff ? -1 : minutes))
                .accessibilityLabel(isOff ? "OFF" : SleepTimerLogic.label(minutes: minutes))
            }
        }
        .frame(width: columnWidth, alignment: .leading)
    }

    /// Two columns so all sixteen languages fit without scrolling. Focus travel between
    /// them is the same geometric left/right the two control columns already rely on.
    private func languageOptions(
        _ picker: PanelPicker,
        selected: String,
        onPick: @escaping (String) -> Void
    ) -> some View {
        let all = SubtitleLanguagePreset.all
        let split = (all.count + 1) / 2
        return HStack(alignment: .top, spacing: columnGap) {
            languageColumn(Array(all[..<split]), picker: picker, selected: selected, onPick: onPick)
            languageColumn(Array(all[split...]), picker: picker, selected: selected, onPick: onPick)
        }
    }

    private func languageColumn(
        _ presets: [SubtitleLanguagePreset],
        picker: PanelPicker,
        selected: String,
        onPick: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: NXLayout.rowGap) {
            ForEach(presets) { preset in
                Button {
                    onPick(preset.code)
                    collapsePicker(owner: picker)
                } label: {
                    PanelRow(label: preset.label, value: .none,
                             trailing: preset.code == selected ? .check : .none,
                             isFocused: focusedControl == .option(preset.code))
                }
                .buttonStyle(NoHighlightButtonStyle())
                .focused($focusedControl, equals: .option(preset.code))
                .accessibilityLabel(preset.label)
            }
        }
        .frame(width: columnWidth, alignment: .leading)
    }

    private func pickerTitle(_ picker: PanelPicker) -> String {
        switch picker {
        case .streamQuality:    return "STREAM QUALITY"
        case .subtitleLanguage: return "SUBTITLE LANGUAGE"
        case .audioLanguage:    return "AUDIO LANGUAGE"
        case .playbackInformation: return "PLAYBACK INFORMATION"
        case .audioTracks:      return "AUDIO"
        case .sleepTimer:       return "SLEEP TIMER"
        }
    }

    /// The countdown in the sleep list's title row, while a timer runs.
    private func pickerLive(_ picker: PanelPicker) -> AnyView? {
        guard picker == .sleepTimer, appState.sleepTimerEndDate != nil else { return nil }
        return AnyView(
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = SleepTimerLogic.remaining(from: appState.sleepTimerEndDate, now: context.date) ?? 0
                Text("\(SleepTimerLogic.countdownLabel(remaining: remaining)) LEFT")
                    .font(NXFont.tag)
                    .foregroundStyle(Color.nxYellow)
            }
        )
    }

    /// Same wording the settings page uses for each setting, plus the one thing that is
    /// only true in here: a new quality ceiling cannot reach the stream already playing.
    private func pickerHint(_ picker: PanelPicker) -> String {
        switch picker {
        case .playbackInformation:
            return appState.playbackInformation?.evidenceNote ?? "Playback information is unavailable for this program."
        case .streamQuality:
            if focusedControl == .option("local-original") { return LocalPlexOriginalQuality.detail }
            if case .option(let id)? = focusedControl, let quality = StreamQuality.allCases.first(where: { $0.id == id }) {
                return quality.detail
            }
            return "Lower this when your connection is slow or shared. Takes effect on the next program."
        case .subtitleLanguage:
            return NowPlayingPanelHints.subtitleLanguage
        case .audioLanguage:
            return NowPlayingPanelHints.audioLanguage
        case .audioTracks:
            return NowPlayingPanelHints.audio
        case .sleepTimer:
            return NowPlayingPanelHints.sleepList
        }
    }

    /// Which row focus should open on: the one currently in effect.
    private func initialFocus(_ picker: PanelPicker) -> NowPlayingFocus {
        switch picker {
        case .streamQuality:
            return .option(localOriginalVideo && appState.backendKind == .plex ? "local-original" : streamQuality.id)
        case .subtitleLanguage: return .option(appState.preferredSubtitleLanguageCode)
        case .audioLanguage:    return .option(appState.preferredAudioLanguageCode)
        case .playbackInformation: return .option("information-back")
        case .audioTracks:      return .audio(appState.selectedAudioTrackID ?? appState.audioTracks.first?.id ?? 0)
        case .sleepTimer:
            let armed = appState.sleepTimerEndDate != nil
            return .sleep(armed ? (appState.sleepTimerMinutes ?? -1) : -1)
        }
    }

    // MARK: - Row builders

    /// A group label: 25 pt, letter-spaced, with a rule under it. `live` is the yellow status at its right.
    private func groupLabel(_ text: String, live: AnyView? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(text)
                    .font(NXFont.captionMedium)
                    .tracking(3)
                    .foregroundStyle(Color.nxText2)
                Spacer(minLength: 12)
                if let live { live }
            }
            Rectangle()
                .fill(Color.nxRestingOutline)
                .frame(height: 2)
        }
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The panel's one row: label left, value right, optional icon at the far right; 76 pt high, the
/// shared row surface (resting and selected). ON reads in cyan and OFF in text-2, as words, never
/// as a switch; a running countdown reads in yellow; a warning in amber.
private struct PanelRow: View {
    enum Value: Equatable {
        case none
        case text(String)
        case on
        case off
        case live(String)
        case warning(String)
    }

    enum Trailing { case none, chevron, external, retry, check, busy }

    let label: String
    var value: Value = .none
    var trailing: Trailing = .none
    let isFocused: Bool
    /// A row that only informs (one audio track): no fill, a dashed outline, not focusable.
    var isStatic: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(NXFont.bodyMedium)
                .foregroundStyle(Color.nxText)
                .lineLimit(1)
                // The longest title, "AUTO SUBTITLES (FOREIGN AUDIO)", only just fits; shrink
                // rather than truncate if a longer one ever arrives.
                .minimumScaleFactor(0.8)
            Spacer(minLength: 12)
            valueView
            trailingView
        }
        .padding(.horizontal, NXLayout.rowPaddingX)
        .frame(height: NXLayout.rowHeight)
        .nxRowSurface(isSelected: isFocused, isStatic: isStatic)
        .contentShape(RoundedRectangle(cornerRadius: NXLayout.rowRadius))
        .animation(.easeInOut(duration: 0.12), value: isFocused)
    }

    @ViewBuilder
    private var valueView: some View {
        switch value {
        case .none:
            EmptyView()
        case .text(let text):
            Text(text)
                .font(NXFont.bodyRegular)
                .foregroundStyle(isFocused ? Color.nxText : Color.nxText2)
                .lineLimit(1)
                .truncationMode(.tail)
        case .on:
            Text("ON").font(NXFont.bodyMedium).foregroundStyle(Color.nxCyan)
        case .off:
            Text("OFF")
                .font(NXFont.bodyRegular)
                .foregroundStyle(isFocused ? Color.nxText : Color.nxText2)
        case .live(let text):
            Text(text).font(NXFont.bodyRegular).foregroundStyle(Color.nxYellow)
        case .warning(let text):
            Text(text).font(NXFont.bodyRegular).foregroundStyle(Color.nxAmber)
        }
    }

    @ViewBuilder
    private var trailingView: some View {
        switch trailing {
        case .none:
            EmptyView()
        case .chevron:
            Image(systemName: "chevron.right").font(NXFont.icon).foregroundStyle(isFocused ? Color.nxCyan : Color.nxText2)
        case .external:
            Image(systemName: "arrow.up.right").font(NXFont.icon).foregroundStyle(isFocused ? Color.nxCyan : Color.nxText2)
        case .retry:
            Image(systemName: "arrow.clockwise").font(NXFont.icon).foregroundStyle(isFocused ? Color.nxCyan : Color.nxText2)
        case .check:
            Image(systemName: "checkmark").font(NXFont.icon).foregroundStyle(Color.nxCyan)
        case .busy:
            ProgressView().tint(Color.nxCyan)
        }
    }
}
