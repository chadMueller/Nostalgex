import SwiftUI
import Combine

struct ChannelGuideView: View {
    @Environment(AppState.self) var appState
    @FocusState private var focusedChannelID: Int?

    let schedules: [Int: ChannelSchedule]
    let windowStart: Date
    var onFocusChanged: ((Int?) -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil

    // How many 30-min slots the user has scrolled forward (0-44 for 24-hour window)
    @State private var slotOffset: Int = 0
    @State private var suppressFocusScroll: Bool = false

    @State private var showBundleSidebar: Bool = false

    /// Sentinel focus id for the seasonal invite row. Real channels use their own id, and
    /// none of them is negative.
    private static let seasonalRowID = -900
    /// Sentinel focus ids for the wrap rows that sit just outside the first and last
    /// channel. See `wrapSentinel`.
    private static let wrapBottomSentinelID = -902
    @State private var seasonalPromptShown = false

    private let channelColumnWidth: CGFloat = 220
    private let rowHeight: CGFloat = 80
    private let headerHeight: CGFloat = 60
    // 24-hour horizon, 30-min slots, 4 visible at a time → max scroll offset = 44.
    private let maxSlotOffset: Int = 44

    var body: some View {
        GeometryReader { geo in
            let programsWidth = geo.size.width - channelColumnWidth

            // Derive the grid window and header labels from the same snapped `windowStart`
            // the schedules were built from. This avoids header/window drift after returning
            // from fullscreen (where the tuner view can pause timers).
            let visibleStart = windowStart.addingTimeInterval(TimeInterval(slotOffset * 1800))
            let visibleLabels = timeSlotLabels(from: visibleStart)

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    // Header row
                    gridHeader(
                        labels: visibleLabels,
                        programsWidth: programsWidth
                    )

                    // Divider under header
                    Rectangle()
                        .fill(Color.white.opacity(0.25))
                        .frame(height: 1)

                    // Channel rows
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 0) {
                                if appState.channels.isEmpty {
                                    Text("NO CHANNELS AVAILABLE")
                                        .font(.custom("DMMono-Medium", size: 20))
                                        .foregroundStyle(.white.opacity(0.3))
                                        .frame(maxWidth: .infinity, minHeight: 200)
                                        .focusable()
                                }
                                if let offer = appState.seasonalBundleOnOffer {
                                    Button { seasonalPromptShown = true } label: {
                                        SeasonalInviteRow(
                                            bundle: offer,
                                            isFocused: focusedChannelID == Self.seasonalRowID,
                                            rowHeight: rowHeight
                                        )
                                    }
                                    .buttonStyle(NoHighlightButtonStyle())
                                    .focused($focusedChannelID, equals: Self.seasonalRowID)
                                    .accessibilityIdentifier("seasonalInviteRow")
                                    .accessibilityLabel("Turn on the \(offer.name) package")
                                    .id(Self.seasonalRowID)
                                }
                                ForEach(Array(appState.channels.enumerated()), id: \.element.id) { index, channel in
                                    Button {
                                        if appState.currentChannel?.id == channel.id {
                                            appState.isFullScreen = true
                                        } else {
                                            appState.tuneChannelFromUser(channel, method: .guide, precomputedSchedule: schedules[channel.id])
                                        }
                                    } label: {
                                        EPGRow(
                                            channel: channel,
                                            schedule: schedules[channel.id],
                                            isFocused: focusedChannelID == channel.id,
                                            isEvenRow: index % 2 == 0,
                                            channelColumnWidth: channelColumnWidth,
                                            programsWidth: programsWidth,
                                            visibleWindowStart: visibleStart,
                                            rowHeight: rowHeight
                                        )
                                    }
                                    .buttonStyle(NoHighlightButtonStyle())
                                    .focused($focusedChannelID, equals: channel.id)
                                    .accessibilityLabel(
                                        appState.currentChannel?.id == channel.id
                                            ? "Channel \(channel.number), \(channel.name), live"
                                            : "Channel \(channel.number), \(channel.name)"
                                    )
                                    .id(channel.id)
                                    // Play/Pause full-screens whatever is already tuned, from any row.
                                    // Select (the button action above) is what tunes the
                                    // highlighted row. Handling it here matters: a focused
                                    // row would otherwise swallow the press before the
                                    // guide-level handler, and used to retune instead.
                                    .onPlayPauseCommand {
                                        if appState.currentChannel != nil {
                                            appState.isFullScreen = true
                                        }
                                    }
                                }
                                wrapSentinel(Self.wrapBottomSentinelID)
                            }
                        }
                        .onChange(of: focusedChannelID) { oldID, newID in
                            // The downward wrap. Focus landing on the sentinel below the
                            // last channel is the only proof that a press ran off the end
                            // of the list, so that is what drives it. Nothing here reads a
                            // clock or guesses at .onMoveCommand's ordering against the
                            // focus engine, which is what the previous implementation had
                            // to do and why it could behave differently under load than on
                            // a quiet simulator.
                            //
                            // Arriving at the real last row is an ordinary focus move and
                            // lands normally, because the sentinel is one row further out.
                            // The bottom channel stays selectable by construction.
                            //
                            // There is deliberately no sentinel above channel one: pressing
                            // Up out of the top row is meant to reach SETTINGS in the nav
                            // bar, not wrap to the bottom.
                            //
                            // Where focus came FROM decides what to do, because the engine
                            // handing out initial focus or a programmatic jump can also
                            // land here, and those must fall through to the adjacent real
                            // row rather than wrap.
                            if newID == Self.wrapBottomSentinelID {
                                let cameFromBottomRow = oldID == appState.channels.last?.id
                                let target = cameFromBottomRow
                                    ? appState.channels.first?.id
                                    : appState.channels.last?.id
                                if let target { focusedChannelID = target }
                                return
                            }
                            if !suppressFocusScroll, let id = newID {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(id, anchor: .center)
                                }
                            }
                            onFocusChanged?(newID)
                        }
                        .onChange(of: appState.isFullScreen) { _, isFullScreen in
                            if !isFullScreen, let id = appState.currentChannel?.id {
                                // Suppress focus-driven scrolling while we anchor to live channel
                                suppressFocusScroll = true
                                focusedChannelID = id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    proxy.scrollTo(id, anchor: .center)
                                    suppressFocusScroll = false
                                }
                            }
                        }
                        .onChange(of: appState.currentChannel?.id) { _, newID in
                            // Keep the guide anchored to the live channel when it changes via a
                            // path that doesn't toggle fullscreen (mini-strip popup, swipe, move).
                            // Guard != focusedChannelID so selecting a row from the guide itself
                            // (which sets currentChannel to the already-focused id) is a no-op.
                            guard let id = newID, id != focusedChannelID else { return }
                            suppressFocusScroll = true
                            focusedChannelID = id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                proxy.scrollTo(id, anchor: .center)
                                suppressFocusScroll = false
                            }
                        }
                        .onAppear {
                            let targetID = appState.currentChannel?.id ?? appState.channels.first?.id
                            if let id = targetID {
                                focusedChannelID = id
                                // Explicit scroll in case focusedChannelID was already set
                                // (e.g., returning from Settings where the value didn't change)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        proxy.scrollTo(id, anchor: .center)
                                    }
                                }
                            }
                        }
                    }
                }

                // "Now" time indicator line
                let nowFraction = nowFractionInWindow(visibleStart: visibleStart)
                if nowFraction >= 0 && nowFraction <= 1 {
                    let nowX = channelColumnWidth + (nowFraction * (geo.size.width - channelColumnWidth))
                    Rectangle()
                        .fill(Color("BrandCyan"))
                        .frame(width: 2)
                        .offset(x: nowX)
                        .allowsHitTesting(false)
                }
            }
            .onMoveCommand { direction in
                switch direction {
                case .left:
                    if slotOffset > 0 {
                        slotOffset -= 1
                    } else if !showBundleSidebar {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showBundleSidebar = true
                        }
                    }
                case .right:
                    if showBundleSidebar {
                        withAnimation(.easeIn(duration: 0.15)) {
                            showBundleSidebar = false
                        }
                    } else if slotOffset < maxSlotOffset {
                        slotOffset += 1
                    }
                // Up and Down are deliberately not handled here. The vertical wrap is
                // driven by focus landing on a sentinel row (see `wrapSentinel` and the
                // focusedChannelID onChange above), which the focus engine decides, so
                // this handler has nothing to add and no clock to race.
                default:
                    break
                }
            }
            .onPlayPauseCommand {
                if appState.currentChannel != nil {
                    appState.isFullScreen = true
                }
            }
            // Menu jumps back to the channel that's actually playing, so a long
            // scroll down the grid doesn't mean scrolling all the way back up.
            // A second press, once focus is already there, does nothing — Menu
            // on the root screen has nowhere else to go.
            .confirmationDialog(
                seasonalDialogTitle,
                isPresented: $seasonalPromptShown,
                titleVisibility: .visible
            ) {
                if let offer = appState.seasonalBundleOnOffer {
                    Button("YES, TURN IT ON") { appState.answerSeasonalPrompt(.yes, for: offer) }
                    Button("NOT THIS YEAR") { appState.answerSeasonalPrompt(.notNow, for: offer) }
                    Button("DON'T ASK AGAIN", role: .destructive) {
                        appState.answerSeasonalPrompt(.never, for: offer)
                    }
                }
            }
            // nil when there is nothing to jump to: attaching an inert closure swallows
            // Menu and traps the viewer in the app. See GuideExitAction.
            .onExitCommand(perform: exitCommandAction)

            // Bundle jump sidebar
            if showBundleSidebar {
                BundleJumpSidebar(
                    targets: appState.bundleJumpTargets,
                    onSelect: { firstChannelID in
                        focusedChannelID = firstChannelID
                        withAnimation(.easeIn(duration: 0.15)) {
                            showBundleSidebar = false
                        }
                    },
                    onOpenSettings: {
                        withAnimation(.easeIn(duration: 0.15)) {
                            showBundleSidebar = false
                        }
                        onOpenSettings?()
                    },
                    onDismiss: {
                        withAnimation(.easeIn(duration: 0.15)) {
                            showBundleSidebar = false
                        }
                    }
                )
                .transition(.move(edge: .leading))
                .zIndex(10)
            }
        }
        .background(Color(red: 0.05, green: 0.05, blue: 0.12))
    }

    // MARK: - Wrap sentinels

    /// A one-point focusable strip just outside the first and last channel row.
    ///
    /// This is how the guide knows a press ran off the end of the list. The focus engine
    /// moves onto the sentinel exactly when there was no channel row left in that
    /// direction, and the focusedChannelID onChange bounces focus to the other end.
    /// Because the signal comes from the engine rather than from a timer, it behaves the
    /// same whether the press was a single click, a held direction, or a swipe — and the
    /// same whether the main thread is idle or busy rebuilding seventeen schedules.
    ///
    /// The top sentinel does a second job: it keeps Up out of the NavBar focus section.
    /// Without it, Up from channel one left the grid for SETTINGS, so the `.up` wrap could
    /// never fire. Settings is still one Left press away, as the first row of the package
    /// sidebar.
    ///
    /// Omitted below two channels: with one row there is nothing to wrap to, and the
    /// sentinel would bounce focus straight back onto the row it came from.
    @ViewBuilder
    private func wrapSentinel(_ id: Int) -> some View {
        if appState.channels.count > 1 {
            // Not Color.clear: a fully transparent view is not reliably a focus
            // candidate. One point tall and ~invisible is.
            Color.white.opacity(0.001)
                .frame(height: 1)
                .focusable()
                .focused($focusedChannelID, equals: id)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Now indicator

    private func nowFractionInWindow(visibleStart: Date) -> CGFloat {
        let now = Date()
        let visibleDuration: TimeInterval = 7200 // 2 hours
        let elapsed = now.timeIntervalSince(visibleStart)
        return CGFloat(elapsed / visibleDuration)
    }

    // MARK: - Grid header

    private func timeSlotLabels(from visibleStart: Date) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return (0..<4).map { i in
            formatter.string(from: visibleStart.addingTimeInterval(TimeInterval(i * 1800)))
        }
    }

    private func gridHeader(labels: [String], programsWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("CHANNEL")
                .font(.custom("DMMono-Medium", size: 18))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(width: channelColumnWidth, alignment: .leading)
                .padding(.leading, 12)

            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                Text(label)
                    .font(.custom("DMMono-Medium", size: 20))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .frame(width: programsWidth / 4, alignment: .leading)
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 1)
                    }
            }
        }
        .frame(height: headerHeight)
        .background(Color(red: 0.04, green: 0.04, blue: 0.08))
    }
}

// MARK: - EPG Row (single channel)

private struct EPGRow: View {
    @Environment(AppState.self) var appState
    let channel: Channel
    let schedule: ChannelSchedule?
    let isFocused: Bool
    let isEvenRow: Bool
    let channelColumnWidth: CGFloat
    let programsWidth: CGFloat
    let visibleWindowStart: Date
    let rowHeight: CGFloat

    // 2-hour visible window
    private let visibleDuration: TimeInterval = 7200
    /// Background for alternating rows
    private var rowBackground: Color {
        if isFocused {
            // The focused row must read from the couch at a glance. A 15% tint of the
            // channel colour disappeared on a bright TV; a third-strength fill plus the
            // outline and glow below does not.
            return channel.color.opacity(0.32)
        }
        return isEvenRow
            ? Color.white.opacity(0.03)
            : Color.clear
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Colored left accent bar using channel color
                Rectangle()
                    .fill(isLive || isFocused ? channel.color : channel.color.opacity(0.4))
                    .frame(width: isLive || isFocused ? 8 : 4)

                // Channel column
                channelColumn

                // Vertical divider
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 1)

                // Program blocks
                programBlocks
            }
            .frame(height: rowHeight)
            .background(rowBackground)
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(channel.color, lineWidth: 3)
                        .padding(2)
                        .shadow(color: channel.color.opacity(0.7), radius: 14)
                }
            }
            .zIndex(isFocused ? 1 : 0)

            // Row divider
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    // MARK: - Channel column

    private var isLive: Bool {
        appState.currentChannel?.id == channel.id
    }

    private var channelColumn: some View {
        HStack(alignment: .center, spacing: 0) {
            if isLive {
                liveBoltBadge
                    .padding(.trailing, 6)
                    .accessibilityHidden(true)
            }

            Text(String(format: "%d", channel.number))
                .font(.custom("DMMono-Medium", size: 20))
                .foregroundStyle(isFocused ? Color.white : channel.color)
                .frame(width: 36, alignment: .trailing)
                .padding(.trailing, 8)

            Text(channel.name.uppercased())
                .font(.custom("DMMono-Medium", size: 18))
                .foregroundStyle(isFocused ? Color.white : channel.color.opacity(0.95))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        // Every row's channel column must measure exactly channelColumnWidth. The live row
        // used a different leading pad and a differently-derived frame, leaving it 216pt
        // against 220pt elsewhere, so the tuned row's programs sat 4pt left of every other
        // row and of the now-line, which is positioned from a flat channelColumnWidth.
        .padding(.leading, isLive ? 8 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(width: channelColumnWidth - 4, alignment: .leading)
        .padding(.trailing, 4)
    }

    /// Compact tuned-in marker — only shown on the active channel row.
    private var liveBoltBadge: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.black.opacity(0.95))
            .symbolRenderingMode(.monochrome)
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .background(channel.color)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }

    // MARK: - Program blocks

    private var programBlocks: some View {
        let now = Date()

        // Segments are cursor-derived, so gaps hold their true position, overlap cannot
        // widen the row, and the fractions can never sum past 1. The explicit .leading
        // alignments matter as much as the math: a fixed-width SwiftUI frame centers
        // overflowing content, which is what slid whole rows left and buried the current
        // program's title under the channel column.
        return HStack(spacing: 0) {
            if let schedule {
                let segments = ProgramRowLayout.segments(
                    intervals: schedule.entries.map { ($0.startTime, $0.endTime) },
                    windowStart: visibleWindowStart,
                    windowDuration: visibleDuration
                )
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .gap(let fraction):
                        Color.clear
                            .frame(width: fraction * programsWidth, height: rowHeight)
                    case .block(let index, let fraction):
                        let entry = schedule.entries[index]
                        let isPast = entry.endTime < now && !entry.isNowPlaying

                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(Color.white.opacity(0.12))
                                .frame(width: 1)

                            Text(entryTitle(entry))
                                .font(.custom("DMMono-Medium", size: 20))
                                .foregroundStyle(
                                    entry.isNowPlaying || isFocused
                                        ? Color.white
                                        : isPast
                                            ? Color.white.opacity(0.5)
                                            : Color.white.opacity(0.85)
                                )
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.leading, 14)

                            Spacer(minLength: 0)
                        }
                        .frame(width: max(fraction * programsWidth, 1), height: rowHeight, alignment: .leading)
                        .clipped()
                        .background(
                            entry.isNowPlaying
                                ? channel.color.opacity(isFocused ? 0.55 : 0.25)
                                : isPast
                                    ? Color.white.opacity(0.02)
                                    : Color.clear
                        )
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: programsWidth, alignment: .leading)
        .clipped()
    }

    // MARK: - Helpers

    private func entryTitle(_ entry: ScheduleEntry) -> String {
        if entry.item.type == .episode {
            let parts = [entry.item.title, entry.item.episodeTitle]
                .compactMap { $0 }
            return parts.joined(separator: ": ")
        }
        if entry.item.isMusicVideo {
            return entry.item.musicDisplayLine
        }
        return entry.item.title
    }
}

// MARK: - Bundle Jump Sidebar

private struct BundleJumpSidebar: View {
    let targets: [(bundleID: String, bundleName: String, firstChannelID: Int, channelColor: Color)]
    let onSelect: (Int) -> Void
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void
    /// -1 is the pinned Settings row. Package rows use their list index.
    @FocusState private var focusedIndex: Int?
    private let settingsFocus = -1
    /// Matches the guide's own row height and focus treatment so the sidebar reads as
    /// part of the same grid rather than a separate widget.
    private static let width: CGFloat = 380
    private static let rowHeight: CGFloat = 72

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Text("PACKAGES")
                    .font(.custom("DMMono-Medium", size: 22))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 2) {
                            // Inside the list, not above it: tvOS won't move focus out
                            // of a ScrollView, so Settings has to be a row. It sits
                            // first; the sidebar still opens on the first package,
                            // and Up from there lands here.
                            let settingsFocused = focusedIndex == settingsFocus
                            let settingsAccent = Color(hex: "#FFE500")
                            Button(action: onOpenSettings) {
                                HStack(spacing: 14) {
                                    Rectangle()
                                        .fill(settingsFocused ? settingsAccent : settingsAccent.opacity(0.4))
                                        .frame(width: settingsFocused ? 8 : 4)

                                    Image(systemName: "gearshape.fill")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(settingsFocused ? .white : .white.opacity(0.75))
                                        .frame(width: 26)

                                    Text("SETTINGS")
                                        .font(.custom("DMMono-Medium", size: 24))
                                        .foregroundStyle(settingsFocused ? .white : .white.opacity(0.75))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)

                                    Spacer()
                                }
                                .padding(.trailing, 16)
                                .frame(height: Self.rowHeight)
                                .background(settingsFocused ? settingsAccent.opacity(0.32) : .clear)
                                .overlay {
                                    if settingsFocused {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(settingsAccent, lineWidth: 3)
                                            .padding(2)
                                            .shadow(color: settingsAccent.opacity(0.7), radius: 14)
                                    }
                                }
                                .zIndex(settingsFocused ? 1 : 0)
                            }
                            .buttonStyle(NoHighlightButtonStyle())
                            .focused($focusedIndex, equals: settingsFocus)
                            .accessibilityIdentifier("tunerSidebarSettings")
                            .id(settingsFocus)

                            Rectangle()
                                .fill(Color.white.opacity(0.1))
                                .frame(height: 1)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 6)

                            ForEach(Array(targets.enumerated()), id: \.element.bundleID) { index, target in
                                let isFocused = focusedIndex == index

                                Button {
                                    onSelect(target.firstChannelID)
                                } label: {
                                    HStack(spacing: 14) {
                                        Rectangle()
                                            .fill(isFocused ? target.channelColor : target.channelColor.opacity(0.4))
                                            .frame(width: isFocused ? 8 : 4)

                                        Text(target.bundleName)
                                            .font(.custom("DMMono-Medium", size: 24))
                                            .foregroundStyle(isFocused ? .white : .white.opacity(0.75))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.8)

                                        Spacer()
                                    }
                                    .padding(.trailing, 16)
                                    .frame(height: Self.rowHeight)
                                    .background(isFocused ? target.channelColor.opacity(0.32) : .clear)
                                    .overlay {
                                        if isFocused {
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .strokeBorder(target.channelColor, lineWidth: 3)
                                                .padding(2)
                                                .shadow(color: target.channelColor.opacity(0.7), radius: 14)
                                        }
                                    }
                                    .zIndex(isFocused ? 1 : 0)
                                }
                                .buttonStyle(NoHighlightButtonStyle())
                                .focused($focusedIndex, equals: index)
                                .id(index)
                            }
                        }
                    }
                    .onChange(of: focusedIndex) { _, newIndex in
                        if let idx = newIndex, idx >= 0 {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(idx, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(width: Self.width)
            .background(Color(red: 0.03, green: 0.03, blue: 0.08).opacity(0.95))

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1)

            Spacer()
        }
        .onAppear {
            focusedIndex = 0
        }
        .onExitCommand {
            onDismiss()
        }
    }
}


private extension ChannelGuideView {
    /// Menu jumps back to the channel that's playing, so a long scroll down the grid
    /// doesn't mean scrolling all the way back up. Once focus is already there the guide
    /// declines the press entirely, so tvOS can background the app.
    var exitCommandAction: (() -> Void)? {
        switch GuideExitAction.decide(
            liveChannelID: appState.currentChannel?.id,
            focusedChannelID: focusedChannelID
        ) {
        case .letSystemHandle:
            return nil
        case .jumpToLiveChannel(let id):
            return { focusedChannelID = id }
        }
    }

    var seasonalDialogTitle: String {
        guard let offer = appState.seasonalBundleOnOffer else { return "" }
        return "Add \(offer.name) to your lineup for the rest of the month?"
    }
}

/// The invite that sits above channel one while a seasonal package is in season and
/// switched off. Nothing is added to anyone's lineup until they answer the dialog.
struct SeasonalInviteRow: View {
    let bundle: ChannelBundle
    let isFocused: Bool
    let rowHeight: CGFloat

    private var headline: String {
        switch bundle.id {
        case "seasonal":        return "IT'S OCTOBER. ARE YOU READY TO SCREAM?"
        case "tis-the-season":  return "IT'S DECEMBER. DECK THE CHANNELS."
        default:                return "\(bundle.name) IS IN SEASON."
        }
    }

    /// Each season gets its own colour so the invite reads as part of that season rather
    /// than as a generic notice.
    private var accent: Color {
        switch bundle.id {
        case "seasonal":        return Color(hex: "#FF6B00")   // pumpkin
        case "tis-the-season":  return Color(hex: "#E74C3C")   // holiday red
        default:                return Color(hex: "#FFE500")
        }
    }

    /// Loud enough to notice, not loud enough to shout. It sits at exactly one channel
    /// row's height so the grid still reads as a grid — the outline, the fill and the pill
    /// do the separating, not size. The first cut was 35% taller with 30pt type and
    /// dominated the screen.
    var body: some View {
        HStack(spacing: 14) {
            Text(headline)
                .font(.custom("DMMono-Medium", size: 22))
                .foregroundStyle(isFocused ? .black : accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            // One call to action, not two. "ADD THE SCREAM PACKAGE" next to "PRESS SELECT"
            // said the same thing twice.
            Text("PRESS TO ADD THE \(bundle.name) PACKAGE")
                .font(.custom("DMMono-Medium", size: 14))
                .foregroundStyle(isFocused ? .black.opacity(0.65) : .black)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isFocused ? Color.black.opacity(0.18) : accent)
                )

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
        .background(isFocused ? accent : accent.opacity(0.22))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(accent, lineWidth: isFocused ? 4 : 2)
                .padding(2)
                .shadow(color: accent.opacity(isFocused ? 0.7 : 0.3), radius: isFocused ? 14 : 7)
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(accent).frame(width: isFocused ? 8 : 4)
        }
        .zIndex(1)
    }
}
