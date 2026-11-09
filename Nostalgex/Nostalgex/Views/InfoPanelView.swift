import SwiftUI

struct InfoPanelView: View {
    let channel: Channel
    let schedule: ChannelSchedule
    /// When showing the active channel, pass the actual playing item so the title
    /// reflects what the player is showing, not the clock-based schedule (they can
    /// drift by ~40s due to file-duration vs metadata mismatches).
    var playingItem: PlexMediaItem? = nil
    /// A later programme the guide's window is moved to (I-089). When set, the panel shows it, with its time
    /// range where the progress bar is, and the programme after it as UP NEXT.
    var previewEntry: ScheduleEntry? = nil

    // MARK: - Typography

    private enum Typo {
        // VT323 accent font -- retro CRT vibe for labels, badges, timestamps
        static let channelTag   = Font.custom("VT323-Regular", size: 36)
        static let metaBadge    = Font.custom("VT323-Regular", size: 24)
        static let progressTime = Font.custom("VT323-Regular", size: 24)
        static let upNextLabel  = Font.custom("VT323-Regular", size: 24)

        // DM Mono -- clean readability for titles and body
        static let title        = Font.custom("DMMono-Medium", size: 38)
        static let episode      = Font.custom("DMMono-Regular", size: 22)
        static let description  = Font.custom("DMMono-Regular", size: 20)
        static let upNextTitle  = Font.custom("DMMono-Regular", size: 18)
    }

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
                .font(Typo.channelTag)
                .tracking(2)
                .foregroundStyle(channel.color)
                .padding(.bottom, Spacing.sectionGap)

            if let now = schedule.nowPlaying ?? previewEntry {
                // Use the actual playing item when provided (avoids title mismatch when
                // file duration differs from schedule metadata by a few seconds). A previewed later
                // programme is shown as it is on the schedule.
                let displayItem = previewEntry?.item ?? playingItem ?? now.item

                // Title (+ artist for music videos)
                Text(displayItem.title)
                    .font(Typo.title)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .lineSpacing(2)
                    .padding(.bottom, Spacing.innerGap)

                if let artist = displayItem.artist, !artist.isEmpty {
                    Text(artist)
                        .font(Typo.episode)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .padding(.bottom, Spacing.innerGap)
                }

                if let genres = displayItem.musicGenreDisplay {
                    Text(genres)
                        .font(Typo.episode)
                        .foregroundStyle(channel.color.opacity(0.75))
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
                            .font(Typo.episode)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .padding(.bottom, Spacing.innerGap)
                    }
                }

                // Divider
                Rectangle()
                    .fill(channel.color.opacity(0.3))
                    .frame(height: 1)
                    .padding(.bottom, Spacing.sectionGap)

                // Description (reserve up to 2 lines so layout doesn't collapse to one)
                if !displayItem.summary.isEmpty {
                    Text(displayItem.summary)
                        .font(Typo.description)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineSpacing(4)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                        .padding(.bottom, Spacing.sectionGap)
                }

                // Meta row + inline progress (or, for a later programme, when it is on)
                metaRow(item: displayItem)
                    .padding(.bottom, Spacing.sectionGap)

                // Up Next
                if let next = previewEntry != nil
                    ? previewEntry.flatMap({ GuideTimeCursor.entry(after: $0, in: schedule.entries) })
                    : schedule.upNext {
                    HStack(spacing: 10) {
                        Text("UP NEXT")
                            .font(Typo.upNextLabel)
                            .tracking(3)
                            .foregroundStyle(.white.opacity(0.5))
                        Text(next.item.isMusicVideo ? next.item.musicDisplayLine : next.item.title)
                            .font(Typo.upNextTitle)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
            }

            Spacer()
        }
        .padding(Spacing.panelPadding)
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
                        .foregroundStyle(.white.opacity(0.6))
                }
                .font(Typo.metaBadge)
            }

            if let previewEntry {
                Text("\(Self.clock(previewEntry.startTime)) - \(Self.clock(previewEntry.endTime))")
                    .font(Typo.progressTime)
                    .foregroundStyle(channel.color)
                    .accessibilityIdentifier("infoPanelTime")
            } else {
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
                                .fill(channel.color)
                                .frame(width: geo.size.width * progress)
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                        }
                    }
                    .frame(height: 4)

                    Text("\(formatTime(elapsed)) / \(formatTime(total))")
                        .font(Typo.progressTime)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            }
        }
    }

    private static let clockFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static func clock(_ date: Date) -> String { clockFormat.string(from: date) }

    private func metaBadge(_ text: String) -> some View {
        Text(text)
            .font(Typo.metaBadge)
            .foregroundStyle(.white.opacity(0.7))
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
