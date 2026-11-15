import SwiftUI

/// The lines of the guide's info panel, top to bottom. One place says the order so the view and its test agree:
/// the channel line above everything (drawn first, not listed), the title as the lead line, then artist, genres and
/// episode subtitle where the programme has them, a divider, the badges (year, rating, star rating), the description,
/// the progress bar (or a later programme's time range) and UP NEXT as one line.
///
/// The description used to sit above the badges and the progress, between the divider and the meta row, and took
/// no room when a programme had none, so every line under it moved up and down from one programme to the next.
/// It now comes after the badges and always holds `descriptionLines` lines, empty or not, so the progress bar and
/// UP NEXT stay where they are.
enum InfoPanelSection: Equatable {
    case title, artist, genres, episode, divider, badges, description, progress, upNext
}

enum InfoPanelLayout {
    /// Lines the description area always holds. A longer description ends in an ellipsis.
    static let descriptionLines = 2

    static func sections(for item: PlexMediaItem, hasUpNext: Bool) -> [InfoPanelSection] {
        var out: [InfoPanelSection] = [.title]
        if let artist = item.artist, !artist.isEmpty { out.append(.artist) }
        if item.musicGenreDisplay != nil { out.append(.genres) }
        if item.type == .episode,
           !([item.seTag, item.episodeTitle].compactMap { $0 }.joined(separator: "  ")).isEmpty { out.append(.episode) }
        out.append(.divider)
        if item.year != nil || !(item.contentRating ?? "").isEmpty || item.rating > 0 { out.append(.badges) }
        out.append(.description)
        out.append(.progress)
        if hasUpNext { out.append(.upNext) }
        return out
    }
}

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
        static let sectionGap: CGFloat = 10
        static let innerGap: CGFloat = 6
        static let panelPadding: CGFloat = 40
    }

    var body: some View {
        GeometryReader { geo in
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 4)

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

                let next = previewEntry != nil
                    ? previewEntry.flatMap({ GuideTimeCursor.entry(after: $0, in: schedule.entries) })
                    : schedule.upNext
                ForEach(Array(InfoPanelLayout.sections(for: displayItem, hasUpNext: next != nil).enumerated()), id: \.offset) { _, section in
                    sectionView(section, item: displayItem, next: next)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(Spacing.panelPadding)
        // Held to the room it is given, anchored to the top: a programme with a title on two lines, an artist, genres
        // and a long description is taller than that room, and then its last line is cut at the bottom. It must not
        // grow the column, which pushed the nav bar and the logo up off the screen.
        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        .clipped()
        }
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

    // MARK: - Sections

    @ViewBuilder
    private func sectionView(_ section: InfoPanelSection, item: PlexMediaItem, next: ScheduleEntry?) -> some View {
        switch section {
        case .title:
            // Title (+ artist for music videos)
            Text(item.title)
                .font(Typo.title)
                .foregroundStyle(.white)
                .lineLimit(2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)   // two lines when it needs them, never cut to one by the room left
                .padding(.bottom, Spacing.innerGap)

        case .artist:
            Text(item.artist ?? "")
                .font(Typo.episode)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .padding(.bottom, Spacing.innerGap)

        case .genres:
            Text(item.musicGenreDisplay ?? "")
                .font(Typo.episode)
                .foregroundStyle(channel.color.opacity(0.75))
                .lineLimit(2)
                .padding(.bottom, Spacing.innerGap)

        case .episode:
            Text([item.seTag, item.episodeTitle].compactMap { $0 }.joined(separator: "  "))
                .font(Typo.episode)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .padding(.bottom, Spacing.innerGap)

        case .divider:
            Rectangle()
                .fill(channel.color.opacity(0.3))
                .frame(height: 1)
                .padding(.bottom, Spacing.sectionGap)

        case .badges:
            badgesRow(item: item)
                .padding(.bottom, Spacing.sectionGap)

        case .description:
            // Always two lines tall, empty or not, so what is under it never moves (see InfoPanelLayout).
            ZStack(alignment: .topLeading) {
                Text(Array(repeating: "A", count: InfoPanelLayout.descriptionLines).joined(separator: "\n"))
                    .font(Typo.description)
                    .lineSpacing(4)
                    .hidden()
                Text(item.summary)
                    .font(Typo.description)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineSpacing(4)
                    .lineLimit(InfoPanelLayout.descriptionLines)
                    .truncationMode(.tail)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, Spacing.sectionGap)
            .accessibilityIdentifier("infoPanelDescription")

        case .progress:
            progressRow(item: item)
                .padding(.bottom, Spacing.sectionGap)

        case .upNext:
            if let next {
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
    }

    // MARK: - Badges

    private func badgesRow(item: PlexMediaItem) -> some View {
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
        }
    }

    // MARK: - Progress (or, for a later programme, when it is on)

    private func progressRow(item: PlexMediaItem) -> some View {
        Group {
            if let previewEntry {
                Text("\(Self.clock(previewEntry.startTime)) - \(Self.clock(previewEntry.endTime))")
                    .font(Typo.progressTime)
                    .foregroundStyle(channel.color)
                    .accessibilityIdentifier("infoPanelTime")
            } else {
                // Progress bar + time (wall clock, updates every second)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let live = schedule.livePlayback(at: context.date)
                    let elapsed = live?.elapsedSeconds ?? schedule.elapsedSeconds
                    let progress = live?.progress ?? schedule.progress
                    let total = live?.totalSeconds ?? item.slotSeconds

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
