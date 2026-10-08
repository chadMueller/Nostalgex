import SwiftUI
import AVKit
import Combine

// MARK: - Playback state

enum PlaybackState: Equatable {
    case idle
    case loading
    case playing
    /// Carries the reason rather than a sentence, so the screen can say both what happened
    /// and whose problem it is. See `PlaybackFailure`.
    case error(PlaybackFailure)
}

// MARK: - AVPlayerLayer container (proper layout sizing)

class PlayerContainerView: UIView {
    let playerLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used — this view is only created programmatically") }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

// MARK: - Raw video player (no transport controls)

struct RawVideoPlayer: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = videoGravity
    }
}

// MARK: - Video area view

struct VideoAreaView: View {
    let player: AVPlayer?
    let playbackState: PlaybackState
    let currentChannel: Channel?
    let currentItem: PlexMediaItem?
    var showChannelBug: Bool = true
    var retroMode: Bool = true

    /// The "TUNING" static only reveals after the load has stayed in `.loading` for ~0.75s,
    /// so fast starts (direct play / Apple-TV-4K remux) never flash it.
    @State private var showStatic = false

    var body: some View {
        ZStack {
            Color.black

            GeometryReader { geo in
                let available = geo.size
                let targetWidth = retroMode
                    ? min(available.width, available.height * (4.0 / 3.0))
                    : available.width

                ZStack {
                    Color(red: 0.02, green: 0.02, blue: 0.05)

                    switch playbackState {
                    case .idle:
                        idleOverlay
                    case .error(let message):
                        errorOverlay(message)
                    case .loading:
                        // Black for the first ~0.75s; the tuning overlay below crossfades
                        // in only on a genuinely-slow start (transcode spin-up).
                        EmptyView()
                    case .playing:
                        if let player {
                            RawVideoPlayer(
                                player: player,
                                videoGravity: retroMode ? .resizeAspectFill : .resizeAspect
                            )
                        }
                    }

                    // CRT + VHS effects on top of video (retro mode only)
                    if retroMode {
                        CRTOverlayView()
                    }

                    // Tuning overlay — layered above so it can crossfade over the video as
                    // playback resolves, instead of the switch hard-swapping views.
                    if showStatic {
                        tuningOverlay
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.35), value: showStatic)
                .frame(width: targetWidth, height: available.height)
                .clipped()
                .position(
                    x: retroMode ? available.width - targetWidth / 2 : available.width / 2,
                    y: available.height / 2
                )
            }

            // Channel bug
            if showChannelBug, let channel = currentChannel, let item = currentItem {
                channelBug(channel: channel, item: item)
            }
        }
        .clipped()
        .task(id: playbackState) {
            // Reveal the static only if we stay in .loading past the threshold; the task is
            // auto-cancelled the instant playbackState changes (e.g. flips to .playing).
            if playbackState == .loading {
                try? await Task.sleep(nanoseconds: 750_000_000)
                if !Task.isCancelled { showStatic = true }
            } else {
                showStatic = false
            }
        }
    }

    // MARK: - State overlays

    private var idleOverlay: some View {
        VStack(spacing: 24) {
            Image("NostalgexLogo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 400)
            Text("SELECT A CHANNEL")
                .font(.custom("DMMono-Medium", size: 28))
                .foregroundStyle(Color("BrandCyan"))
        }
    }

    /// Short "CH 42" tag shown during tuning, when a channel is known.
    private var channelLabel: String? {
        currentChannel.map { "CH \($0.number)" }
    }

    /// Retro users get the (now calmer) snow; users who turned retro mode off get a clean
    /// dim tuning card instead of an effect they opted out of.
    @ViewBuilder
    private var tuningOverlay: some View {
        if retroMode {
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

    private func errorOverlay(_ failure: PlaybackFailure) -> some View {
        PlaybackFailureCard(failure: failure, compact: true)
    }

    // MARK: - Channel bug (bottom-left info)

    private func channelBug(channel: Channel, item: PlexMediaItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Rectangle()
                        .fill(channel.color)
                        .frame(width: 40, height: 3)
                    Text("CH \(channel.number)")
                        .font(.custom("DMMono-Medium", size: 18))
                        .foregroundStyle(channel.color)
                    Text(channel.name)
                        .font(.custom("DMMono-Medium", size: 26))
                        .foregroundStyle(.white)
                    if item.isMusicVideo {
                        Text(item.title)
                            .font(.custom("DMMono-Medium", size: 22))
                            .foregroundStyle(.white.opacity(0.9))
                        if let artist = item.artist, !artist.isEmpty {
                            Text(artist)
                                .font(.custom("DMMono-Regular", size: 18))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        if let genres = item.musicGenreDisplay {
                            Text(genres)
                                .font(.custom("DMMono-Regular", size: 16))
                                .foregroundStyle(channel.color.opacity(0.8))
                        }
                    } else {
                        Text(item.title)
                            .font(.custom("DMMono-Regular", size: 20))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(24)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.75), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                Spacer()
            }
        }
    }
}

// MARK: - Loading dots animation

struct LoadingDotsView: View {
    let message: String
    @State private var dots = ""
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(message + dots)
            .font(.custom("DMMono-Medium", size: 28))
            .foregroundStyle(Color(hex: "#00C4FF"))
            .onReceive(timer) { _ in
                dots = dots.count >= 3 ? "" : dots + "."
            }
    }
}
