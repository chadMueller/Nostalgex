import SwiftUI
import AVKit
import Combine

struct PlayerView: View {
    @Environment(AppState.self) var appState
    @State private var showOSD: Bool = false
    @State private var osdTimer: Timer?
    @State private var showMiniGuide: Bool = false
    @State private var miniGuideTimer: Timer?
    @State private var showNowPlaying: Bool = false
    @State private var showStatic = false
    @FocusState private var isPlayerFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .task(id: appState.playbackState) {
                    if appState.playbackState == .loading {
                        try? await Task.sleep(nanoseconds: 750_000_000)
                        if !Task.isCancelled { showStatic = true }
                    } else {
                        showStatic = false
                    }
                }

            // Video player - uses shared player from AppState
            // Always show the player -- black background covers gaps during loading
            if let player = appState.player {
                RawVideoPlayer(
                    player: player,
                    videoGravity: appState.retroMode ? .resizeAspectFill : .resizeAspect
                )
                .ignoresSafeArea()
            }

            // CRT overlay (no scanlines in fullscreen - too distracting)
            if appState.retroMode {
                CRTOverlayView(showScanlines: false)
                    .ignoresSafeArea()
            }

            // Loading / error states. Loading crossfades in the "TUNING" overlay (visual
            // only) once we're past the ~0.75s threshold, so the screen isn't black during a
            // slow transcode spin-up; error shows a brief message before auto-skip advances.
            if case .error(let failure) = appState.playbackState {
                PlaybackFailureCard(failure: failure, compact: false)
            }

            // Tuning overlay — layered here (not inside a switch) so it crossfades over the
            // video as playback resolves instead of hard-cutting.
            if showStatic {
                tuningOverlay
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            // Channel OSD -- always visible when not playing, timed when playing
            if let channel = appState.currentChannel, let item = appState.currentItem {
                let videoActive = appState.player?.timeControlStatus == .playing
                if showOSD || !videoActive {
                    ChannelOSD(
                        channel: channel,
                        item: item,
                        schedule: ChannelScheduleBuilder.buildSchedule(
                            for: channel,
                            credentialFingerprint: appState.scheduleCredentialFingerprint
                        )
                    )
                    .transition(.opacity)
                }
            }

            // Bare-playback remote input: trackpad swipes + click-ring presses.
            //
            // Both live on this overlay — which only exists while nothing is layered over
            // the video — instead of on the player root. An `onMoveCommand` attached to the
            // root stays in the responder path once the Now Playing panel or mini guide
            // opens, and SwiftUI hands it every directional press before the focus engine
            // sees it. The guard below then dropped those presses on the floor, so the
            // panel's buttons never received a focus move and the panel looked frozen.
            if !showMiniGuide && !showNowPlaying && !appState.sleepGracePromptActive {
                RemoteSwipeGesture { direction in
                    switch direction {
                    case .left:
                        appState.previousChannel()
                        flashOSD()
                    case .right:
                        appState.nextChannel()
                        flashOSD()
                    case .down:
                        // Pull down from the top edge = the panel that lives at the top;
                        // push up from the bottom edge = the strip that lives at the bottom.
                        // These were crossed, so every swipe summoned the far overlay.
                        showNowPlayingPanel()
                    case .up:
                        showMiniGuideStrip()
                    default:
                        break
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(true)
                .focusable(true)
                .focused($isPlayerFocused)
                // The overlay is torn down and rebuilt with every open/close, so re-claim
                // focus here rather than relying on an assignment made while it was gone.
                .onAppear { isPlayerFocused = true }
                .onMoveCommand { direction in
                    switch direction {
                    case .left:
                        appState.previousChannel()
                        flashOSD()
                    case .right:
                        appState.nextChannel()
                        flashOSD()
                    case .down:
                        // Pull down from the top edge = the panel that lives at the top;
                        // push up from the bottom edge = the strip that lives at the bottom.
                        // These were crossed, so every swipe summoned the far overlay.
                        showNowPlayingPanel()
                    case .up:
                        showMiniGuideStrip()
                    @unknown default:
                        break
                    }
                }
            }

            // Mini channel strip (slides up from bottom)
            if showMiniGuide {
                VStack {
                    Spacer()
                    MiniChannelStrip(
                        channels: appState.channels,
                        currentChannelID: appState.currentChannel?.id,
                        onSelect: { channel in
                            appState.tuneChannelFromUser(channel, method: .miniStrip)
                            hideMiniGuide()
                            flashOSD()
                        },
                        onDismiss: {
                            hideMiniGuide()
                        }
                    )
                }
                .transition(.move(edge: .bottom))
                .ignoresSafeArea()
            }

            // Now Playing panel (slides down from top) — CC / audio / sleep timer
            if showNowPlaying, let channel = appState.currentChannel, let item = appState.currentItem {
                VStack {
                    NowPlayingPanel(
                        channel: channel,
                        item: item,
                        onDismiss: { hideNowPlaying() }
                    )
                    Spacer()
                }
                .transition(.move(edge: .top))
                .ignoresSafeArea()
            }

            // Sleep-timer grace prompt — "Still watching?" captures the next remote input.
            if appState.sleepGracePromptActive {
                SleepGracePrompt(
                    onStayAwake: { appState.keepAwakeFromGrace() }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: showStatic)
        .animation(.easeInOut(duration: 0.25), value: showNowPlaying)
        .animation(.easeInOut(duration: 0.2), value: appState.sleepGracePromptActive)
        .focusSection()
        .onAppear {
            flashOSD()
        }
        .onChange(of: appState.currentItem?.id) { _, _ in
            flashOSD()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // Recalculate schedule — clock has advanced, different content should be playing.
            // Stays on `selectChannel` (automatic path): this isn't a user tune, and firing
            // channel.tuned here would count every foreground return as a channel change.
            if let channel = appState.currentChannel {
                appState.selectChannel(channel)
            }
        }

        // Remote: Play/Pause -- flash OSD (no pause, this is live TV)
        .onPlayPauseCommand {
            flashOSD()
        }

        // Remote: Back -> dismiss panel / mini guide, else return to guide
        .onExitCommand {
            if showNowPlaying {
                hideNowPlaying()
            } else if showMiniGuide {
                hideMiniGuide()
            } else {
                appState.isFullScreen = false
            }
        }

        .onDisappear {
            osdTimer?.invalidate()
            osdTimer = nil
            miniGuideTimer?.invalidate()
            miniGuideTimer = nil
        }
    }

    // MARK: - Tuning overlay

    /// Short "CH 42" tag shown during tuning, when a channel is known.
    private var channelLabel: String? {
        appState.currentChannel.map { "CH \($0.number)" }
    }

    /// Retro users get the (calmer) snow; users who turned retro mode off get a clean dim
    /// tuning card instead of an effect they opted out of.
    @ViewBuilder
    private var tuningOverlay: some View {
        if appState.retroMode {
            StaticScreenView(channelLabel: channelLabel)
        } else {
            ZStack {
                Color.black
                Text(channelLabel.map { "TUNING · \($0)" } ?? "TUNING")
                    .font(.custom("DMMono-Medium", size: 24))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    // MARK: - OSD

    private func flashOSD() {
        osdTimer?.invalidate()
        withAnimation(.easeIn(duration: 0.15)) { showOSD = true }
        osdTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { _ in
            Task { @MainActor in
                withAnimation(.easeOut(duration: 0.4)) { showOSD = false }
            }
        }
    }

    // MARK: - Mini Guide

    private func showMiniGuideStrip() {
        miniGuideTimer?.invalidate()
        withAnimation(.easeOut(duration: 0.25)) { showMiniGuide = true }
    }

    private func hideMiniGuide() {
        miniGuideTimer?.invalidate()
        withAnimation(.easeIn(duration: 0.2)) { showMiniGuide = false }
        // Focus returns to the player via the input overlay's onAppear — it does not
        // exist yet at this point, so assigning isPlayerFocused here would be a no-op.
    }

    // MARK: - Now Playing panel

    private func showNowPlayingPanel() {
        withAnimation(.easeOut(duration: 0.25)) { showNowPlaying = true }
    }

    private func hideNowPlaying() {
        withAnimation(.easeIn(duration: 0.2)) { showNowPlaying = false }
        // See hideMiniGuide — the input overlay reclaims focus when it reappears.
    }
}

// MARK: - Mini Channel Strip

private struct MiniChannelStrip: View {
    @Environment(AppState.self) var appState
    let channels: [Channel]
    let currentChannelID: Int?
    let onSelect: (Channel) -> Void
    var onDismiss: (() -> Void)? = nil
    @FocusState private var focusedID: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(channels) { channel in
                        let isCurrent = channel.id == currentChannelID
                        let isFocused = focusedID == channel.id

                        Button {
                            onSelect(channel)
                        } label: {
                            stripCard(channel: channel, isCurrent: isCurrent, isFocused: isFocused)
                        }
                        // Same treatment as tuner nav — tvOS `.plain` still applies a huge glass/zoom ring.
                        .buttonStyle(NoHighlightButtonStyle())
                        .focused($focusedID, equals: channel.id)
                        .accessibilityLabel("Channel \(channel.number), \(channel.name)")
                        .id(channel.id)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 20)
            }
            .onAppear {
                focusedID = currentChannelID
                if let id = currentChannelID {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: focusedID) { _, newID in
                if let id = newID {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .background(
            LinearGradient(
                colors: [.black.opacity(0.35), .black.opacity(0.95)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onExitCommand {
            onDismiss?()
        }
    }
}

private extension MiniChannelStrip {
    func stripCard(channel: Channel, isCurrent: Bool, isFocused: Bool) -> some View {
        let nowPlayingSubtitle: Double = isFocused ? 0.9 : 0.7

        let fill: Color = {
            if isCurrent && !isFocused {
                return channel.color.opacity(0.18)
            }
            if isFocused {
                return Color(red: 0.05, green: 0.05, blue: 0.07)
            }
            return Color.white.opacity(0.14)
        }()

        let borderColor = isFocused
            ? channel.color
            : isCurrent ? channel.color.opacity(0.6) : Color.white.opacity(0.25)

        return VStack(spacing: 0) {
            Rectangle()
                .fill(channel.color)
                .frame(height: isFocused ? 5 : 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("\(channel.number)")
                        .font(.custom("DMMono-Medium", size: 26))
                        .foregroundStyle(channel.color)

                    Text(channel.name.uppercased())
                        .font(.custom("DMMono-Medium", size: 18))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                if let schedule = ChannelScheduleBuilder.buildSchedule(
                    for: channel,
                    credentialFingerprint: appState.scheduleCredentialFingerprint
                ),
                   let nowPlaying = schedule.nowPlaying?.item {
                    Text(nowPlaying.isMusicVideo ? nowPlaying.musicDisplayLine : nowPlaying.title)
                        .font(.custom("DMMono-Regular", size: 16))
                        .foregroundStyle(.white.opacity(nowPlayingSubtitle))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 310, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isFocused ? 2 : 1)
        )
        .compositingGroup()
    }
}

// MARK: - Channel OSD (on-screen display)

private struct ChannelOSD: View {
    let channel: Channel
    let item: PlexMediaItem
    let schedule: ChannelSchedule?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Rectangle()
                        .fill(channel.color)
                        .frame(width: 48, height: 4)

                    Text("CH \(channel.number)")
                        .font(.custom("DMMono-Medium", size: 20))
                        .foregroundStyle(channel.color)

                    Text(channel.name)
                        .font(.custom("DMMono-Medium", size: 32))
                        .foregroundStyle(.white)

                    Group {
                        if item.type == .episode, let epTitle = item.episodeTitle {
                            Text("\(item.title)  \(item.seTag ?? "")  \"\(epTitle)\"")
                                .foregroundStyle(.white.opacity(0.8))
                        } else if item.isMusicVideo {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .foregroundStyle(.white.opacity(0.95))
                                if let artist = item.artist, !artist.isEmpty {
                                    Text(artist)
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                                HStack(spacing: 12) {
                                    if let year = item.year {
                                        Text(String(year))
                                    }
                                    if let genres = item.musicGenreDisplay {
                                        Text(genres)
                                    }
                                }
                                .foregroundStyle(.white.opacity(0.55))
                            }
                        } else {
                            Text("\(item.title)\(item.year.map { "  \(String($0))" } ?? "")")
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                    .font(.custom("DMMono-Regular", size: 24))

                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(playbackTimeLabel(at: context.date))
                            .font(.custom("DMMono-Regular", size: 18))
                            .foregroundStyle(.gray)
                    }
                }
                .padding(32)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.85), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

                Spacer()
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            item.isMusicVideo
                ? "Channel \(channel.number), \(channel.name), now playing \(item.musicDisplayLine)"
                : "Channel \(channel.number), \(channel.name), now playing \(item.title)"
        )
    }

    private func playbackTimeLabel(at now: Date) -> String {
        if let live = schedule?.livePlayback(at: now) {
            return "\(formatTime(live.elapsedSeconds)) / \(formatTime(live.totalSeconds))"
        }
        return formatTime(item.duration * 60)
    }

    private func formatTime(_ totalSeconds: Int) -> String {
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Swipe gesture recognizer for Siri Remote trackpad

struct RemoteSwipeGesture: UIViewRepresentable {
    var onSwipe: (UISwipeGestureRecognizer.Direction) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right, .up, .down] {
            let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipe(_:)))
            swipe.direction = direction
            view.addGestureRecognizer(swipe)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSwipe: onSwipe)
    }

    class Coordinator {
        let onSwipe: (UISwipeGestureRecognizer.Direction) -> Void
        init(onSwipe: @escaping (UISwipeGestureRecognizer.Direction) -> Void) {
            self.onSwipe = onSwipe
        }
        @objc func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
            onSwipe(gesture.direction)
        }
    }
}
