import SwiftUI

struct InfoPanelView: View {
    @Environment(AppState.self) private var appState
    let channel: Channel
    let schedule: ChannelSchedule
    /// When showing the active channel, pass the actual playing item so the title
    /// reflects what the player is showing, not the clock-based schedule (they can
    /// drift by ~40s due to file-duration vs metadata mismatches).
    var playingItem: PlexMediaItem? = nil

    // MARK: - Typography

    /// The panel's type, through THEME. NOSTALGEX gives back these exact faces and sizes.
    private struct Typo {
        let theme: GuideTheme
        // VT323 accent font -- retro CRT vibe for labels, badges, timestamps
        var channelTag: Font   { theme.font("VT323-Regular", size: 36) }
        var metaBadge: Font    { theme.font("VT323-Regular", size: 24) }
        var progressTime: Font { theme.font("VT323-Regular", size: 24) }
        var upNextLabel: Font  { theme.font("VT323-Regular", size: 24) }

        // DM Mono -- clean readability for titles and body
        var title: Font        { theme.font("DMMono-Medium", size: 38) }
        var episode: Font      { theme.font("DMMono-Regular", size: 22) }
        var description: Font  { theme.font("DMMono-Regular", size: 20) }
        var upNextTitle: Font  { theme.font("DMMono-Regular", size: 18) }
    }

    private var theme: GuideTheme { appState.guideTheme }
    private var typo: Typo { Typo(theme: theme) }
    private var accent: Color { theme.accent(for: channel) }
    private var body_: Color { theme.infoBody ?? .white }

    // MARK: - Spacing

    private enum Spacing {
        static let sectionGap: CGFloat = 20
        static let innerGap: CGFloat = 10
        static let panelPadding: CGFloat = 40
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 24)

            // Channel tag
            Text("CH \(String(format: "%02d", channel.number)) \u{2014} \(channel.name.uppercased())")
                .font(typo.channelTag)
                .tracking(2)
                .foregroundStyle(accent)
                .themeTextShadow(theme.textShadow)
                .padding(.bottom, Spacing.sectionGap)

            if let now = schedule.nowPlaying {
                // Use the actual playing item when provided (avoids title mismatch when
                // file duration differs from schedule metadata by a few seconds).
                let displayItem = playingItem ?? now.item

                // Title (+ artist for music videos)
                Text(displayItem.title)
                    .font(typo.title)
                    .foregroundStyle(theme.infoTitle ?? .white)
                    .themeTextShadow(theme.textShadow)
                    .lineLimit(2)
                    .lineSpacing(2)
                    .padding(.bottom, Spacing.innerGap)

                if let artist = displayItem.artist, !artist.isEmpty {
                    Text(artist)
                        .font(typo.episode)
                        .foregroundStyle(body_.opacity(0.7))
                        .lineLimit(1)
                        .padding(.bottom, Spacing.innerGap)
                }

                if let genres = displayItem.musicGenreDisplay {
                    Text(genres)
                        .font(typo.episode)
                        .foregroundStyle(accent.opacity(0.75))
                        .lineLimit(2)
                        .padding(.bottom, Spacing.innerGap)
                }

                // Episode subtitle
                if displayItem.type == .episode {
                    let subtitle = [displayItem.seTag, displayItem.episodeTitle]
                        .compactMap { $0 }
                        .joined(separator: "  ")
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(typo.episode)
                            .foregroundStyle(body_.opacity(0.7))
                            .lineLimit(1)
                            .padding(.bottom, Spacing.innerGap)
                    }
                }

                // Divider
                Rectangle()
                    .fill(accent.opacity(0.3))
                    .frame(height: 1)
                    .padding(.bottom, Spacing.sectionGap)

                // Description (reserve up to 2 lines so layout doesn't collapse to one)
                if !displayItem.summary.isEmpty {
                    Text(displayItem.summary)
                        .font(typo.description)
                        .foregroundStyle(body_.opacity(0.65))
                        .lineSpacing(4)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                        .padding(.bottom, Spacing.sectionGap)
                }

                // Meta row + inline progress
                metaRow(item: displayItem)
                    .padding(.bottom, Spacing.sectionGap)

                // Up Next
                if let next = schedule.upNext {
                    HStack(spacing: 10) {
                        Text("UP NEXT")
                            .font(typo.upNextLabel)
                            .tracking(3)
                            .foregroundStyle(body_.opacity(0.5))
                        Text(next.item.isMusicVideo ? next.item.musicDisplayLine : next.item.title)
                            .font(typo.upNextTitle)
                            .foregroundStyle(body_.opacity(0.75))
                            .lineLimit(1)
                    }
                }
            }

            Spacer()
        }
        .padding(Spacing.panelPadding)
        .background(
            LinearGradient(
                colors: theme.infoBackground ?? [
                    Color(red: 0.04, green: 0.04, blue: 0.10),
                    Color(red: 0.05, green: 0.05, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    // MARK: - Meta row

    private func metaRow(item: PlexMediaItem) -> some View {
        HStack(spacing: 14) {
            if let year = item.year {
                metaBadge(String(year))
            }
            if let rating = item.contentRating, !rating.isEmpty {
                metaBadge(rating)
            }
            if item.rating > 0 {
                HStack(spacing: 6) {
                    Text("\u{2605}")
                        .foregroundStyle(Color(hex: "#FFE500"))
                    Text(String(format: "%.1f", item.rating))
                        .foregroundStyle(body_.opacity(0.6))
                }
                .font(typo.metaBadge)
            }

            // Inline progress bar + time (wall clock, updates every second)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let live = schedule.livePlayback(at: context.date)
                let elapsed = live?.elapsedSeconds ?? schedule.elapsedSeconds
                let progress = live?.progress ?? schedule.progress
                let total = live?.totalSeconds ?? item.duration * 60

                HStack(spacing: 10) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                            Rectangle()
                                .fill(accent)
                                .frame(width: geo.size.width * progress)
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                        }
                    }
                    .frame(height: 4)

                    Text("\(formatTime(elapsed)) / \(formatTime(total))")
                        .font(typo.progressTime)
                        .foregroundStyle(body_.opacity(0.55))
                }
            }
        }
    }

    private func metaBadge(_ text: String) -> some View {
        Text(text)
            .font(typo.metaBadge)
            .foregroundStyle(body_.opacity(0.7))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(.white.opacity(0.15), lineWidth: 1)
            )
    }

    // MARK: - Formatting

    private func formatDuration(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
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
