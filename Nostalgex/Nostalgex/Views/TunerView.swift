import SwiftUI
import AVKit
import Combine

struct TunerView: View {
    @Environment(AppState.self) var appState
    @Binding var navigationPath: NavigationPath
    @State private var schedules: [Int: ChannelSchedule] = [:]
    @State private var windowStart: Date = Date()
    /// Guards against an older schedule rebuild landing after a newer one.
    @State private var scheduleBuildToken: Int = 0
    @State private var previewChannelID: Int? = nil
    /// How far the guide's window is moved through time, in 30 minute steps (GuideTimeCursor).
    @State private var guideTimeOffset = 0
    // Refresh schedules every 30 seconds (progress bar + entry transitions)
    let scheduleTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    /// GUIDE TIMEOUT's check. Every 5 seconds, so a 5-minute timeout fires within 5 seconds of it.
    let guideTimeoutTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let videoHeight = geo.size.height * 0.5143
            // 4:3 video width based on the top section height
            let videoWidth = min(geo.size.width, videoHeight * (4.0 / 3.0))
            let panelWidth = geo.size.width - videoWidth

            VStack(spacing: 0) {
                // Top section: Nav + Info Panel (left) + Video (right)
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        // Left column: info panel
                        VStack(spacing: 0) {
                            // Space for nav bar
                            Spacer().frame(height: 140)

                            if let channel = previewChannel,
                               let schedule = schedules[channel.id] {
                                let isActiveChannel = channel.id == appState.currentChannel?.id
                                InfoPanelView(
                                    channel: channel,
                                    schedule: schedule,
                                    playingItem: isActiveChannel ? appState.currentItem : nil,
                                    previewEntry: previewEntry(in: schedule)
                                )
                                    .frame(maxHeight: .infinity)
                                    .animation(.easeInOut(duration: 0.15), value: channel.id)
                            } else {
                                Spacer()
                            }
                        }
                        .frame(width: panelWidth)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.04, green: 0.04, blue: 0.10),
                                    Color(red: 0.05, green: 0.05, blue: 0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                        VideoAreaView(
                            player: appState.player,
                            playbackState: appState.playbackState,
                            currentChannel: appState.currentChannel,
                            currentItem: appState.currentItem,
                            showChannelBug: false,
                            retroMode: appState.retroMode
                        )
                        .frame(width: videoWidth, height: videoHeight)
                    }

                    // Nav bar overlaid at top-left, above the info panel
                    NavBar(onSettings: { navigationPath.append(AppDestination.settings) })
                        .frame(width: panelWidth, height: 140)
                }
                .frame(height: videoHeight)

                // Bottom section: EPG Grid (takes remaining space)
                ChannelGuideView(
                    schedules: schedules,
                    windowStart: windowStart,
                    onFocusChanged: { id in previewChannelID = id },
                    onTimeOffsetChanged: { guideTimeOffset = $0 },
                    onOpenSettings: { navigationPath.append(AppDestination.settings) }
                )
                .frame(maxHeight: .infinity)

                // Rating nudge: below the guide rather than over it, so it never
                // covers a channel row. The guide gives up the height while it shows.
                if appState.isRatingNudgeVisible {
                    RatingNudgeBanner()
                        .padding(.horizontal, 60)
                        .padding(.top, 16)
                        .padding(.bottom, 40)
                        .frame(maxWidth: .infinity)
                        .background(Color(red: 0.05, green: 0.05, blue: 0.12))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.isRatingNudgeVisible)
        .background(Color.black)
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            RemoteActivityMonitor.install()
            RemoteActivityMonitor.noteActivity()
            buildAllSchedules()
            // Resume playback if player exists but isn't playing (e.g., returning from Settings)
            if let player = appState.player,
               player.timeControlStatus != .playing,
               appState.currentItem != nil {
                player.play()
            }
        }
        .onChange(of: appState.channels.count) { _, _ in
            buildAllSchedules()
        }
        .onReceive(scheduleTimer) { _ in
            buildAllSchedules()
        }
        .onReceive(guideTimeoutTimer) { now in
            // GUIDE TIMEOUT: a guide left alone goes fullscreen on the playing channel, the
            // same as Play/Pause, so its still parts don't burn into an OLED.
            let goFullscreen = GuideTimeout.shouldGoFullscreen(
                interval: GuideTimeout.current().interval,
                lastActivity: RemoteActivityMonitor.lastActivity,
                now: now,
                guideIsFrontmost: navigationPath.isEmpty && !appState.isFullScreen,
                isPlaying: appState.playbackState == .playing && appState.currentChannel != nil
            )
            if goFullscreen {
                appState.isFullScreen = true
            }
        }
        .onChange(of: navigationPath.isEmpty) { _, isEmpty in
            // Back from Settings: the guide gets the full timeout again.
            if isEmpty { RemoteActivityMonitor.noteActivity() }
        }
        .onChange(of: appState.isFullScreen) { _, isFullScreen in
            // When fullscreen cover is presented, this view can stop receiving the 30s timer.
            // Rebuild immediately on return so the guide header + grid window stay aligned.
            if !isFullScreen {
                RemoteActivityMonitor.noteActivity()
                buildAllSchedules()
                // The rating nudge's only trigger. Waits until the guide has re-anchored
                // focus on the live row (0.3s in ChannelGuideView), so the banner takes
                // focus from a settled guide and hands it back to the same row.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    guard !appState.isFullScreen else { return }
                    appState.ratingNudgeGuideDidReturn()
                }
            }
        }
        .onChange(of: appState.currentItem) { _, _ in
            buildAllSchedules()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // Recalculate schedule — clock has advanced, different content should be playing
            buildAllSchedules()
            if let channel = appState.currentChannel {
                let schedule = schedules[channel.id]
                appState.selectChannel(channel, precomputedSchedule: schedule)
            }
        }
        .onPlayPauseCommand {
            if appState.currentChannel != nil {
                appState.isFullScreen = true
            }
        }
    }

    /// The programme the info panel previews, when the guide's window is moved later than now: the one on the
    /// focused channel at the window's left edge. Nil shows what is on now.
    private func previewEntry(in schedule: ChannelSchedule) -> ScheduleEntry? {
        guard let time = GuideTimeCursor.previewTime(slotOffset: guideTimeOffset, windowStart: windowStart),
              let entry = GuideTimeCursor.entry(in: schedule.entries, at: time),
              !entry.isNowPlaying else { return nil }
        return entry
    }

    /// Channel to show in the info panel: focused channel in EPG, or current if none focused
    private var previewChannel: Channel? {
        if let id = previewChannelID {
            return appState.channels.first { $0.id == id }
        }
        return appState.currentChannel
    }

    // MARK: - Schedule management

    /// Rebuilds every channel's schedule off the main thread.
    ///
    /// This runs on a 30s timer for as long as the guide is open, and again on every
    /// program change. Measured on a Mac it costs 114ms for 40 channels and 921ms for 90,
    /// and it used to run inline — so the focus engine froze for that long, every thirty
    /// seconds, forever. It is the jank that was still there minutes after launch, once
    /// the one-off channel rebuild had long finished.
    private func buildAllSchedules() {
        let now = Date()
        windowStart = ChannelScheduleBuilder.windowStart(at: now)

        let channels = appState.channels
        let fingerprint = appState.scheduleCredentialFingerprint
        scheduleBuildToken &+= 1
        let token = scheduleBuildToken

        Task.detached(priority: .userInitiated) {
            var newSchedules: [Int: ChannelSchedule] = [:]
            for channel in channels {
                if let schedule = ChannelScheduleBuilder.buildSchedule(
                    for: channel,
                    at: now,
                    credentialFingerprint: fingerprint
                ) {
                    newSchedules[channel.id] = schedule
                }
            }
            ChannelScheduleBuilder.resolveConflicts(&newSchedules)
            let built = newSchedules
            await MainActor.run {
                // A later rebuild may have started while this one ran — the timer and a
                // program change can overlap. Only the newest result may land, or the
                // guide would flick back to a stale window.
                guard token == scheduleBuildToken else { return }
                schedules = built
            }
        }
    }
}

// MARK: - Navigation bar

private struct NavBar: View {
    var onSettings: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Logo
            Image("NostalgexLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 80)
                .padding(.leading, 40)

            Spacer()

            // Menu items
            HStack(spacing: 32) {
                NavItem(label: "SETTINGS", action: onSettings)
                    .accessibilityIdentifier("tunerSettingsButton")
            }
            .padding(.trailing, 40)
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .focusSection()
    }
}

private struct NavItem: View {
    let label: String
    var isActive: Bool = false
    var action: (() -> Void)? = nil
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            action?()
        } label: {
            // A real button: the pill every selectable thing is (resting fill and outline), with the
            // shared selected state when it has focus (3 pt cyan outline, glow, 3% lift).
            Text(label)
                .font(NXFont.bodyMedium)
                .foregroundStyle(Color.nxText)
                .padding(.horizontal, 36)
                .padding(.vertical, 14)
                .nxRowSurface(isSelected: isFocused, cornerRadius: 40)
                .contentShape(Capsule())
        }
        .buttonStyle(NoHighlightButtonStyle())
        .focused($isFocused)
        .onPlayPauseCommand { action?() }
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Button style that suppresses tvOS default white focus highlight

struct NoHighlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}
