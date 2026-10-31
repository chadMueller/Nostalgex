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
                    .font(.custom("DMMono-Medium", size: 34))
                    .foregroundStyle(.white)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, (deadline ?? context.date).timeIntervalSince(context.date))
                    Text("SLEEPING IN \(SleepTimerLogic.countdownLabel(remaining: remaining))")
                        .font(.custom("DMMono-Regular", size: 23))
                        .foregroundStyle(.white.opacity(0.85))
                }

                Text("PRESS ANY BUTTON TO KEEP WATCHING")
                    .font(.custom("DMMono-Regular", size: 19))
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.top, 4)
            }
            .padding(48)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 0.05, green: 0.05, blue: 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.28), lineWidth: 1)
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
    case audio(Int)
    case sleep(Int)  // -1 == OFF row
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

/// The multi-value settings the panel can expand into a full-width list.
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
}

/// Top-anchored in-player control panel opened with the Siri Remote UP button — the
/// counterpart to the bottom mini-guide. Left: now-playing context + Up Next.
/// Right: two control columns — what this program is doing right now (captions, audio),
/// and what the device is doing (picture, stream quality, sleep timer).
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
    @AppStorage(LocalPlexOriginalQuality.storageKey) private var localOriginalVideo = false

    /// Wide enough for the longest title the panel carries, "AUTO SUBTITLES (FOREIGN
    /// AUDIO)", without truncating its value.
    private let controlColumnWidth: CGFloat = 420

    private var schedule: ChannelSchedule? {
        ChannelScheduleBuilder.buildSchedule(
            for: channel,
            credentialFingerprint: appState.scheduleCredentialFingerprint
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            infoZone
            Spacer(minLength: 24)
            controlsZone
        }
        .padding(.horizontal, 48)
        .padding(.top, 40)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.92), .clear],
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
        HStack(alignment: .top, spacing: 24) {
            // Poster only when the backend can serve one (Plex's thumbnail transcode
            // carries the token in the URL, so AsyncImage needs no header support).
            // The panel reads fine without it on Jellyfin/Emby.
            if let poster = appState.posterURL(for: item) {
                AsyncImage(url: poster) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.14)
                }
                .frame(width: 150, height: 225)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(channel.color)
                .frame(width: 48, height: 4)

            Text("CH \(channel.number)")
                .font(.custom("DMMono-Medium", size: 23))
                .foregroundStyle(channel.color)

            // Title leads as the big headline, channel name follows smaller below it
            // (Discord feedback, 2026-10-29: viewers read this as "what's
            // playing", so the title should dominate and the channel is secondary).
            Text(nowPlayingLine)
                .font(.custom("DMMono-Medium", size: 30))
                .foregroundStyle(.white)
                .lineLimit(2)

            Text(channel.name)
                .font(.custom("DMMono-Regular", size: 25))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)

            if let rating = item.contentRating, !rating.isEmpty {
                Text(rating.uppercased())
                    .font(.custom("DMMono-Regular", size: 18))
                    .foregroundStyle(.white.opacity(0.7))
            }

            if let next = schedule?.upNext?.item {
                Text("UP NEXT: \(next.isMusicVideo ? next.musicDisplayLine : next.title)")
                    .font(.custom("DMMono-Regular", size: 18))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .padding(.top, 4)
            }
            }
            .frame(maxWidth: 640, alignment: .leading)
        }
    }

    private var nowPlayingLine: String {
        if item.isMusicVideo { return item.musicDisplayLine }
        if let year = item.year { return "\(item.title)  \(String(year))" }
        return item.title
    }

    // MARK: - Controls zone
    //
    // Still exactly one flat focus section, whichever state the panel is in. Nested focus
    // sections trap the tvOS focus engine and block up/down travel, so the two columns are
    // plain sibling VStacks of buttons under a single `.focusSection()` and the engine
    // resolves up/down and left/right between them geometrically.
    //
    // Two columns rather than one long list: the panel lies over live video and has to
    // stay short and quick to leave. Nine rows in one column already ran tall, and this
    // adds five more. Splitting by what the row acts on (this program vs. the device)
    // leaves the panel shorter than it was before while showing everything at once, with
    // no scrolling and no rows hidden below the fold.

    @ViewBuilder
    private var controlsZone: some View {
        if let picker = expandedPicker {
            pickerZone(picker)
        } else {
            HStack(alignment: .top, spacing: 40) {
                programColumn
                deviceColumn
            }
            .focusSection()
            .onAppear { focusedControl = .cc }
        }
    }

    /// Controls that act on the program playing right now.
    private var programColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            if appState.canRetryOriginalVideo {
                compatibilityRetryRow
            }
        }
        .frame(width: controlColumnWidth, alignment: .leading)
    }

    @ViewBuilder
    private func programRow(_ row: NowPlayingProgramRow) -> some View {
        switch row {
        case .captionsHeader:
            controlHeader("CAPTIONS")
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
        case .audioHeader:
            controlHeader("AUDIO")
        case .audioTracks:
            audioRows
        case .openInPlex:
            openInPlexRow
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
        VStack(alignment: .leading, spacing: 10) {
            controlHeader("PICTURE")
            retroRow
            streamQualityRow

            controlHeader("SLEEP TIMER")
            sleepRow(minutes: 0)  // OFF
            ForEach(SleepTimerLogic.offeredMinutes(armed: appState.sleepTimerMinutes), id: \.self) { minutes in
                sleepRow(minutes: minutes)
            }
            pickerRow(.playbackInformation, title: "PLAYBACK INFORMATION", value: "VIEW", focus: .playbackInformation)
        }
        .frame(width: controlColumnWidth, alignment: .leading)
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
            controlRow(
                label: "CC",
                value: appState.hasSubtitleTracks
                    ? (appState.subtitlesInFullscreenEnabled ? "ON" : "OFF")
                    : "NONE",
                isFocused: focusedControl == .cc,
                isActive: appState.hasSubtitleTracks && appState.subtitlesInFullscreenEnabled,
                disabled: !appState.hasSubtitleTracks
            )
        }
        .buttonStyle(NoHighlightButtonStyle())
        .focused($focusedControl, equals: .cc)
    }

    @State private var compatibilityStatus: String?

    private var compatibilityRetryRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                compatibilityStatus = "CHECKING SERVER"
                Task { @MainActor in
                    compatibilityStatus = await appState.retryOriginalVideoCompatibility()
                }
            } label: {
                controlRow(label: "RETRY ORIGINAL VIDEO", value: "",
                           isFocused: focusedControl == .compatibilityRetry,
                           isActive: false, disabled: appState.compatibilityRetryInFlight)
            }
            .buttonStyle(NoHighlightButtonStyle())
            .focused($focusedControl, equals: .compatibilityRetry)
            .disabled(appState.compatibilityRetryInFlight)
            Text(compatibilityStatus ?? "Try different packaging for this program. Keeps original video; quality settings stay unchanged.")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        }
    }

    @State private var openInPlexStatus: String?

    private var openInPlexRow: some View {
        Button {
            appState.openCurrentItemInPlex { [self] opened in
                if !opened { openInPlexStatus = "NO PLEX APP" }
            }
        } label: {
            controlRow(
                label: "OPEN IN PLEX",
                value: openInPlexStatus ?? "",
                isFocused: focusedControl == .openInPlex,
                isActive: false,
                disabled: false
            )
        }
        .buttonStyle(NoHighlightButtonStyle())
        .focused($focusedControl, equals: .openInPlex)
    }

    private var autoSubtitlesRow: some View {
        Button {
            appState.autoSubtitlesForForeignAudioEnabled.toggle()
        } label: {
            controlRow(
                label: "AUTO SUBTITLES (FOREIGN AUDIO)",
                value: appState.autoSubtitlesForForeignAudioEnabled ? "ON" : "OFF",
                isFocused: focusedControl == .autoSubtitles,
                isActive: appState.autoSubtitlesForForeignAudioEnabled,
                disabled: false
            )
        }
        .buttonStyle(NoHighlightButtonStyle())
        .focused($focusedControl, equals: .autoSubtitles)
    }

    private var retroRow: some View {
        Button {
            appState.retroMode.toggle()
        } label: {
            controlRow(
                label: "RETRO MODE",
                value: appState.retroMode ? "ON" : "OFF",
                isFocused: focusedControl == .retro,
                isActive: appState.retroMode,
                disabled: false
            )
        }
        .buttonStyle(NoHighlightButtonStyle())
        .focused($focusedControl, equals: .retro)
    }

    // Stream quality is shown for every program, not just transcoded ones: nothing
    // observable tells the panel whether the current stream is a transcode or a direct
    // play, and a row that vanished unpredictably would be worse than one that is
    // occasionally inert. The note carries the part that does matter — the URL for this
    // program is already built, so a new ceiling cannot apply until the next one.
    private var streamQualityRow: some View {
        pickerRow(
            .streamQuality,
            title: "STREAM QUALITY",
            value: localOriginalVideo && appState.backendKind == .plex ? "ORIGINAL (LOCAL PLEX)" : streamQuality.displayName.uppercased(),
            focus: .streamQuality,
            note: "Takes effect on the next program."
        )
    }

    /// A collapsed multi-value row: current value on the right, expands in place on select.
    private func pickerRow(
        _ picker: PanelPicker,
        title: String,
        value: String,
        focus: NowPlayingFocus,
        note: String? = nil
    ) -> some View {
        Button {
            expandPicker(picker)
        } label: {
            controlRow(
                label: title,
                value: value,
                isFocused: focusedControl == focus,
                isActive: false,
                disabled: false,
                note: note
            )
        }
        .buttonStyle(NoHighlightButtonStyle())
        .focused($focusedControl, equals: focus)
    }

    // Audio track list — per-item ephemeral selection. A single-/no-track item shows a
    // non-focusable row so the focus engine skips straight past it.
    @ViewBuilder
    private var audioRows: some View {
        if appState.audioTracks.count <= 1 {
            controlRow(
                label: appState.audioTracks.first?.displayName ?? "SINGLE TRACK",
                value: nil,
                isFocused: false,
                isActive: false,
                disabled: true
            )
        } else {
            ForEach(appState.audioTracks) { track in
                Button {
                    appState.selectAudioTrack(id: track.id)
                } label: {
                    controlRow(
                        label: track.displayName,
                        value: track.id == appState.selectedAudioTrackID ? "ACTIVE" : nil,
                        isFocused: focusedControl == .audio(track.id),
                        isActive: track.id == appState.selectedAudioTrackID,
                        disabled: false
                    )
                }
                .buttonStyle(NoHighlightButtonStyle())
                .focused($focusedControl, equals: .audio(track.id))
            }
        }
    }

    @ViewBuilder
    private func sleepRow(minutes: Int) -> some View {
        let isOff = minutes == 0
        let armed = appState.sleepTimerEndDate != nil
        let isSelected = isOff ? !armed : (armed && appState.sleepTimerMinutes == minutes)
        let focusKey: NowPlayingFocus = .sleep(isOff ? -1 : minutes)

        Button {
            if isOff {
                appState.cancelSleepTimer()
            } else {
                appState.startSleepTimer(minutes: minutes)
            }
        } label: {
            if !isOff && isSelected {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = SleepTimerLogic.remaining(from: appState.sleepTimerEndDate, now: context.date) ?? 0
                    controlRow(
                        label: SleepTimerLogic.label(minutes: minutes),
                        value: SleepTimerLogic.countdownLabel(remaining: remaining),
                        isFocused: focusedControl == focusKey,
                        isActive: true,
                        disabled: false
                    )
                }
            } else {
                controlRow(
                    label: isOff ? "OFF" : SleepTimerLogic.label(minutes: minutes),
                    value: isSelected ? "ACTIVE" : nil,
                    isFocused: focusedControl == focusKey,
                    isActive: isSelected,
                    disabled: false
                )
            }
        }
        .buttonStyle(NoHighlightButtonStyle())
        .focused($focusedControl, equals: focusKey)
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
            }
        }()
        expandedPicker = nil
    }

    /// The picker takes over the whole controls area rather than pushing its options in
    /// underneath the other rows. Sixteen languages inlined below a row would run the
    /// panel off the bottom of the screen; swapping keeps the panel roughly the height it
    /// already is, and the options are still ordinary buttons in the one focus section.
    @ViewBuilder
    private func pickerZone(_ picker: PanelPicker) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            controlHeader(pickerTitle(picker))

            Text(pickerSubtitle(picker))
                .font(.custom("DMMono-Regular", size: 17))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 2)

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
            }
        }
        .focusSection()
        .onAppear { focusedControl = .option(selectedOptionID(picker)) }
    }

    /// Reuses the panel's in-place navigation. Playback continues; Back returns focus
    /// to the information row rather than dismissing the whole panel.
    private var playbackInformationContents: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    if appState.playbackInformationRows.isEmpty {
                        Text("Playback information is unavailable.")
                            .font(.custom("DMMono-Regular", size: 20))
                            .foregroundStyle(.white.opacity(0.8))
                    } else {
                        ForEach(appState.playbackInformationRows) { row in
                            HStack(alignment: .top, spacing: 16) {
                                Text(row.label)
                                    .font(.custom("DMMono-Medium", size: 17))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .frame(width: 220, alignment: .leading)
                                Text(row.value)
                                    .font(.custom("DMMono-Regular", size: 21))
                                    .foregroundStyle(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            Button { collapsePicker(owner: .playbackInformation) } label: {
                controlRow(label: "BACK", value: nil,
                           isFocused: focusedControl == .option("information-back"),
                           isActive: false, disabled: false)
            }
            .buttonStyle(NoHighlightButtonStyle())
            .focused($focusedControl, equals: .option("information-back"))
            .accessibilityLabel("Back to playback controls")
            .padding(.top, 8)
        }
        .frame(width: controlColumnWidth * 2 + 40, alignment: .leading)
    }

    private var streamQualityOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if appState.backendKind == .plex {
                Button {
                    localOriginalVideo.toggle()
                    collapsePicker(owner: .streamQuality)
                } label: {
                    controlRow(label: "ORIGINAL (LOCAL PLEX)", value: localOriginalVideo ? "ACTIVE" : nil,
                               isFocused: focusedControl == .option("local-original"), isActive: localOriginalVideo,
                               disabled: false, note: LocalPlexOriginalQuality.detail)
                }
                .buttonStyle(NoHighlightButtonStyle())
                .focused($focusedControl, equals: .option("local-original"))
            }
            ForEach(StreamQuality.allCases) { quality in
                Button {
                    localOriginalVideo = false
                    StreamQuality.current = quality
                    streamQuality = quality
                    collapsePicker(owner: .streamQuality)
                } label: {
                    controlRow(
                        label: quality.displayName.uppercased(),
                        value: quality == streamQuality ? (localOriginalVideo ? "OTHER PLAYBACK" : "ACTIVE") : nil,
                        isFocused: focusedControl == .option(quality.id),
                        isActive: quality == streamQuality,
                        disabled: false,
                        note: quality.detail
                    )
                }
                .buttonStyle(NoHighlightButtonStyle())
                .focused($focusedControl, equals: .option(quality.id))
            }
        }
        .frame(width: 560, alignment: .leading)
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
        return HStack(alignment: .top, spacing: 20) {
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
        VStack(alignment: .leading, spacing: 10) {
            ForEach(presets) { preset in
                Button {
                    onPick(preset.code)
                    collapsePicker(owner: picker)
                } label: {
                    controlRow(
                        label: preset.label,
                        value: preset.code == selected ? "ACTIVE" : nil,
                        isFocused: focusedControl == .option(preset.code),
                        isActive: preset.code == selected,
                        disabled: false
                    )
                }
                .buttonStyle(NoHighlightButtonStyle())
                .focused($focusedControl, equals: .option(preset.code))
            }
        }
        .frame(width: 380, alignment: .leading)
    }

    private func pickerTitle(_ picker: PanelPicker) -> String {
        switch picker {
        case .streamQuality:    return "STREAM QUALITY"
        case .subtitleLanguage: return "SUBTITLE LANGUAGE"
        case .audioLanguage:    return "AUDIO LANGUAGE"
        case .playbackInformation: return "PLAYBACK INFORMATION"
        }
    }

    /// Same wording the settings page uses for each setting, plus the one thing that is
    /// only true in here: a new quality ceiling cannot reach the stream already playing.
    private func pickerSubtitle(_ picker: PanelPicker) -> String {
        switch picker {
        case .playbackInformation:
            return appState.playbackInformation?.evidenceNote ?? "Playback information is unavailable for this program."
        case .streamQuality:
            return "Lower this when your connection is slow or shared. Takes effect on the next program."
        case .subtitleLanguage:
            return "Choose which subtitle track to prefer when multiple are available."
        case .audioLanguage:
            return "Choose which audio track to prefer when multiple are available."
        }
    }

    /// Which option row focus should open on — the one currently in effect.
    private func selectedOptionID(_ picker: PanelPicker) -> String {
        switch picker {
        case .streamQuality:    return localOriginalVideo && appState.backendKind == .plex ? "local-original" : streamQuality.id
        case .subtitleLanguage: return appState.preferredSubtitleLanguageCode
        case .audioLanguage:    return appState.preferredAudioLanguageCode
        case .playbackInformation: return "information-back"
        }
    }

    // MARK: - Row builders

    private func controlHeader(_ text: String) -> some View {
        Text(text)
            .font(.custom("DMMono-Medium", size: 16))
            .foregroundStyle(.white.opacity(0.6))
            .tracking(1.5)
    }

    /// `note` is a dim caption under the row, for the one thing a label and a value can't
    /// say on their own (what a stream-quality choice does and doesn't reach).
    private func controlRow(
        label: String,
        value: String?,
        isFocused: Bool,
        isActive: Bool,
        disabled: Bool,
        note: String? = nil
    ) -> some View {
        let fill: Color = isFocused ? Color(red: 0.05, green: 0.05, blue: 0.07) : Color.white.opacity(0.14)
        let border: Color = isFocused
            ? channel.color
            : isActive ? channel.color.opacity(0.5) : Color.white.opacity(0.22)
        let labelOpacity: Double = disabled ? 0.35 : 1.0

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.custom("DMMono-Medium", size: 20))
                    .foregroundStyle(.white.opacity(labelOpacity))
                    .lineLimit(1)
                    // The longest titles ("AUTO SUBTITLES (FOREIGN AUDIO)") only just fit;
                    // shrink rather than truncate if a localized value runs longer.
                    .minimumScaleFactor(0.8)
                Spacer()
                if let value {
                    Text(value)
                        .font(.custom("DMMono-Regular", size: 18))
                        .foregroundStyle(isActive ? channel.color : .white.opacity(0.75))
                        .lineLimit(1)
                }
            }

            if let note {
                Text(note)
                    .font(.custom("DMMono-Regular", size: 16))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(border, lineWidth: isFocused ? 2 : 1)
        )
        .compositingGroup()
    }
}
