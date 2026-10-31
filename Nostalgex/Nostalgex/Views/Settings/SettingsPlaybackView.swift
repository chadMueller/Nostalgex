import SwiftUI

/// PLAYBACK & PICTURE: how a channel looks and sounds once it is on screen, plus the
/// two switches that report what you watch back to the server.
struct SettingsPlaybackView: View {
    @Environment(AppState.self) var appState
    let focus: FocusState<SettingsFocus?>.Binding

    @State private var streamQuality = StreamQuality.current
    @AppStorage(LocalPlexOriginalQuality.storageKey) private var localOriginalVideo = false
    @State private var showStreamQualityPicker = false
    @State private var showSubtitleLanguagePicker = false
    @State private var showAudioLanguagePicker = false

    static let firstRowID = "retro"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsToggleRow(
                title: "RETRO MODE",
                subtitle: "CRT scanlines, vignette, VHS glitch, 4:3 aspect ratio",
                isOn: appState.retroMode,
                isFocused: isFocused("retro")
            ) {
                appState.retroMode.toggle()
            }
            .settingsRow("retro", focus: focus)

            // Two built-in sizes, NORMAL and LARGE; select switches between them.
            SettingsToggleRow(
                title: "GUIDE TEXT SIZE",
                subtitle: "Bigger program titles, times and channel names in the guide",
                detail: appState.guideTextSize.label,
                isOn: true,
                isFocused: isFocused("guide_text_size"),
                showToggle: false
            ) {
                appState.guideTextSize = appState.guideTextSize == .large ? .normal : .large
            }
            .settingsRow("guide_text_size", focus: focus)
            .accessibilityValue(appState.guideTextSize.label)

            SettingsToggleRow(
                title: "STREAM QUALITY",
                subtitle: "Lower this when your connection is slow or shared",
                detail: streamQualityLabel,
                isOn: true,
                isFocused: isFocused("stream_quality"),
                showToggle: false
            ) {
                showStreamQualityPicker = true
            }
            .settingsRow("stream_quality", focus: focus)

            // One row for what used to be two switches. "Always" is the fullscreen
            // switch; "Foreign audio" is the auto fallback alone. Subtitles never draw
            // over the guide in any mode.
            SettingsToggleRow(
                title: "SUBTITLES",
                subtitle: subtitleModeExplanation,
                detail: subtitleModeLabel,
                isOn: true,
                isFocused: isFocused("sub_mode"),
                showToggle: false
            ) {
                cycleSubtitleMode()
            }
            .settingsRow("sub_mode", focus: focus)

            if appState.subtitlesInFullscreenEnabled || appState.autoSubtitlesForForeignAudioEnabled {
                SettingsToggleRow(
                    title: "SUBTITLE LANGUAGE",
                    subtitle: "When the video has multiple subtitle tracks, prefer this language",
                    detail: SubtitleLanguagePreset.displayLabel(for: appState.preferredSubtitleLanguageCode),
                    isOn: true,
                    isFocused: isFocused("sub_lang"),
                    showToggle: false
                ) {
                    showSubtitleLanguagePicker = true
                }
                .settingsRow("sub_lang", focus: focus)
            }

            SettingsToggleRow(
                title: "AUDIO LANGUAGE",
                subtitle: "When the video has multiple audio tracks, prefer this language",
                detail: SubtitleLanguagePreset.displayLabel(for: appState.preferredAudioLanguageCode),
                isOn: true,
                isFocused: isFocused("audio_lang"),
                showToggle: false
            ) {
                showAudioLanguagePicker = true
            }
            .settingsRow("audio_lang", focus: focus)

            // Moved here from CONNECTION: both are about what happens while you watch.
            if !appState.isDemoMode {
                SettingsSectionHeader(
                    title: "WATCH HISTORY",
                    subtitle: "What \(appState.backendDisplayName) is told about what you watch"
                )
                .padding(.top, 24)

                SettingsToggleRow(
                    title: "SHOW NOW PLAYING ON \(appState.backendDisplayName.uppercased())",
                    subtitle: appState.backendKind == .plex
                        ? "Show the current program on Plex. Leave Mark Watched off to keep watch history unchanged."
                        : "Show the current program. Prior watch state is restored when playback ends; a working connection is required.",
                    isOn: appState.showNowPlaying,
                    isFocused: isFocused("now_playing_sync")
                ) {
                    appState.showNowPlaying.toggle()
                }
                .settingsRow("now_playing_sync", focus: focus)
                .accessibilityHint("Reports the current program to \(appState.backendDisplayName). Mark Watched is a separate choice")

                SettingsToggleRow(
                    title: "MARK WATCHED ON \(appState.backendDisplayName.uppercased())",
                    subtitle: "Count a program as watched when you tune in during its first 15% and watch at least 75%. Independent of Now Playing. Off by default.",
                    isOn: appState.markWatched,
                    isFocused: isFocused("mark_watched")
                ) {
                    appState.markWatched.toggle()
                }
                .settingsRow("mark_watched", focus: focus)
                .accessibilityHint("Updates watch history after a qualifying watch. Does not enable Now Playing")
            }
        }
        .sheet(isPresented: $showStreamQualityPicker) {
            StreamQualityPickerSheet(selected: streamQuality, allowsOriginal: appState.backendKind == .plex) { picked in
                if picked != streamQuality {
                    Analytics.track(.settingChanged(key: "stream_quality", value: picked.rawValue))
                }
                StreamQuality.current = picked
                streamQuality = picked
                appState.preferenceSync.record(PreferenceSync.streamQualityKey, value: picked.rawValue)
            }
        }
        .sheet(isPresented: $showSubtitleLanguagePicker) {
            SubtitleLanguagePickerSheet()
                .environment(appState)
        }
        .sheet(isPresented: $showAudioLanguagePicker) {
            AudioLanguagePickerSheet()
                .environment(appState)
        }
    }

    private func isFocused(_ id: String) -> Bool {
        focus.wrappedValue == .row(id)
    }

    /// Upper case, like every other row's value.
    private var streamQualityLabel: String {
        let label = localOriginalVideo && appState.backendKind == .plex ? "Original (local Plex)" : streamQuality.displayName
        return label.uppercased()
    }

    private var subtitleModeLabel: String {
        if appState.subtitlesInFullscreenEnabled { return "ALWAYS" }
        if appState.autoSubtitlesForForeignAudioEnabled { return "FOREIGN AUDIO" }
        return "OFF"
    }

    private var subtitleModeExplanation: String {
        if appState.subtitlesInFullscreenEnabled { return "Shown in fullscreen whenever the video has them" }
        if appState.autoSubtitlesForForeignAudioEnabled { return "Shown in fullscreen when the audio isn't in your language" }
        return "Never shown. Press to change"
    }

    /// Off, then foreign audio only, then always, then back to off.
    private func cycleSubtitleMode() {
        if appState.subtitlesInFullscreenEnabled {
            appState.subtitlesInFullscreenEnabled = false
            appState.autoSubtitlesForForeignAudioEnabled = false
        } else if appState.autoSubtitlesForForeignAudioEnabled {
            appState.subtitlesInFullscreenEnabled = true
        } else {
            appState.autoSubtitlesForForeignAudioEnabled = true
        }
    }
}
