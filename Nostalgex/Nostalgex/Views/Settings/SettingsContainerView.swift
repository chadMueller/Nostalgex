import SwiftUI
import AVFoundation

/// Settings as a rail plus a detail pane (N-028). What AppDestination.settings pushes.
///
/// - Up/down on the rail swaps the detail pane's hero and rows live, no press.
/// - Right or select moves focus into the category's rows.
/// - Menu from the rows returns focus to the rail; Menu from the rail leaves Settings.
///   Inside a CHANNELS & BUNDLES sub-page, Menu first steps back one page, landing on
///   the row that opened it.
/// - Left from the rows lands back on the selected tab, not whichever tab is level with
///   the row, so the pane never swaps under you on the way out.
/// - The hero and title stay pinned at the top of the pane; only the rows scroll.
struct SettingsContainerView: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: SettingsFocus?
    @State private var selected: SettingsCategory = .support
    /// The CHANNELS & BUNDLES sub-page on show; nil is its list. Back to the list
    /// whenever another tab is selected.
    @State private var channelsPage: ChannelsPage?
    /// The pending placement of a package row (`centreFocusedRow`). Cancelled by the next focus change.
    @State private var placeRowTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.04, blue: 0.10),
                    Color(red: 0.05, green: 0.05, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            HStack(spacing: 0) {
                SettingsRailView(selected: selected, focus: $focus) { category in
                    activate(category)
                }
                .focusSection()
                .defaultFocus($focus, .rail(selected), priority: .userInitiated)

                detailPane
                    .focusSection()
                    .defaultFocus($focus, .row(firstRowID(for: selected)), priority: .userInitiated)
                    .onExitCommand {
                        // Only reached while a row has focus; Menu on the rail is not
                        // handled here, so the NavigationStack pops as before.
                        if selected == .channels, let page = channelsPage {
                            showChannelsPage(page.parent, focusing: page.linkRowID)
                        } else {
                            focus = .rail(selected)
                        }
                    }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .defaultFocus($focus, .rail(.support))
        .onChange(of: focus) { _, newFocus in
            guard case .rail(let category)? = newFocus, category != selected else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                selected = category
                channelsPage = nil
            }
        }
        .onAppear {
            appState.player?.isMuted = true
        }
        .onDisappear {
            appState.player?.isMuted = TestLaunchFlags.audioMuted
        }
        .task {
            // Refresh the reachable-server list so deselected servers can be re-added.
            await appState.refreshAvailableServers()
        }
        .task {
            // Refresh the library-section list so one picked off in onboarding (or on
            // a prior Settings visit) still shows up to be turned back on.
            await appState.refreshAvailableLibrarySections()
        }
        .task {
            // Tip tiles stay hidden until (and unless) StoreKit returns the products.
            guard !appState.isDemoMode else { return }
            await TipJar.shared.loadProductsIfNeeded()
        }
        .onChange(of: appState.hasCredentials) { _, has in
            // DISCONNECT was pressed: pop back so RootView routes to the sign-in screen.
            if !has { dismiss() }
        }
    }

    // MARK: - Focus

    private func activate(_ category: SettingsCategory) {
        selected = category
        focus = .row(firstRowID(for: category))
    }

    /// Swaps the CHANNELS & BUNDLES sub-page in place, then moves focus once the new
    /// page's rows exist (setting it in the same update would target a row that is not
    /// there yet, and the focus engine would pick its own).
    private func showChannelsPage(_ page: ChannelsPage?, focusing rowID: String? = nil) {
        channelsPage = page
        let target = rowID ?? SettingsChannelsView.firstRowID(page: page, appState: appState)
        DispatchQueue.main.async {
            focus = .row(target)
        }
    }

    private func firstRowID(for category: SettingsCategory) -> String {
        switch category {
        case .support: return SettingsSupportView.firstRowID
        case .playback: return SettingsPlaybackView.firstRowID
        case .channels: return SettingsChannelsView.firstRowID(page: channelsPage, appState: appState)
        case .servers: return SettingsServersView.firstRowID(appState: appState)
        case .pro: return SettingsProView.firstRowID
        case .about: return SettingsAboutView.firstRowID
        }
    }

    // MARK: - Detail pane

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
                .padding(.horizontal, 72)
                .padding(.top, 52)
                .padding(.bottom, 16)

            // Only the rows scroll. Future rows will land across categories, so nothing
            // here assumes a category fits on screen.
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 1).id("rows_top")
                        categoryRows
                            .id(rowsIdentity)
                            .transition(.opacity)
                    }
                    // Room for the focused row's stroke and the Support tiles' lift,
                    // so neither is clipped at the scroll edges. At the top that room
                    // sits below the fade, so the first row is never dimmed.
                    .padding(.horizontal, 72)
                    .padding(.top, Self.rowsTopInset)
                    .padding(.bottom, 70)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: focus) { previous, newFocus in
                    centreFocusedRow(previous: previous, now: newFocus, proxy: proxy)
                }
                .onChange(of: selected) { _, _ in
                    proxy.scrollTo("rows_top", anchor: .top)
                }
                .onChange(of: channelsPage) { _, _ in
                    // A new page starts at its top. Stepping back, the focus change
                    // that follows scrolls to the row that opened the page.
                    proxy.scrollTo("rows_top", anchor: .top)
                }
            }
            // Rows dissolve as they slide under the pinned hero instead of being cut
            // mid-line at the divider. A focused row never sits in the fade: it is
            // scrolled to the centre of the pane, and the first row rests at
            // rowsTopInset, below the fade.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.black.opacity(0), .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: Self.rowsTopFade)
                    Color.black
                }
            }
            .overlay(alignment: .top) {
                // A thin line where rows slide under the pinned hero.
                SettingsDivider()
                    .padding(.horizontal, 72)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Scrolls the row that took focus to the centre of the pane.
    ///
    /// A package row grows to list its channels while it has focus and the one that lost focus shrinks back, so
    /// the rows are changing size for `SettingsToggleRow.focusAnimationDuration` after every press. Centring the
    /// row at the moment of the press did not give the same place on an Apple TV as on a simulator: going down,
    /// rows came to rest lower and lower on the screen, and one landed with its title under the pinned header.
    /// The cause was not isolated (the system's own scroll to the focused row, or a centre worked out before the
    /// rows had finished moving). So when a package row gains or loses focus the pane waits until the rows have
    /// stopped changing size and centres the row once, after the system has done its own scrolling. The centre of
    /// the pane is the same point whatever a row's height and the tallest row is well inside it, so a package row
    /// sits wholly below the header, in the same place going down as going up. Pressing again before the wait is
    /// over cancels it, so a held press scrolls once, where it stops. Every other row centres at once, as before.
    private func centreFocusedRow(previous: SettingsFocus?, now: SettingsFocus?, proxy: ScrollViewProxy) {
        placeRowTask?.cancel()
        placeRowTask = nil
        guard case .row(let id)? = now else { return }
        var changesSize = SettingsChannelsView.isPackageRow(id)
        if case .row(let before)? = previous, SettingsChannelsView.isPackageRow(before) { changesSize = true }
        guard changesSize else {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
            return
        }
        placeRowTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(SettingsToggleRow.focusAnimationDuration + Self.placeRowSettle))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: Self.placeRowDuration)) {
                proxy.scrollTo(id, anchor: .center)
            }
            // Once the slide is over, the same target again, with no animation: nothing moves if the slide
            // arrived, and a slide the system cut short is finished instead of left half way.
            try? await Task.sleep(for: .seconds(Self.placeRowDuration + Self.placeRowSettle))
            guard !Task.isCancelled else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    /// A little over a frame, so the rows are done changing size and the layout has run before the pane looks.
    private static let placeRowSettle: Double = 0.05
    /// The slide to the centre. Short: the row is already on screen.
    private static let placeRowDuration: Double = 0.15

    /// Identity of the rows block, so a tab or sub-page swap cross-fades as a whole.
    private var rowsIdentity: String {
        selected == .channels ? "channels-\(channelsPage?.rawValue ?? "list")" : selected.rawValue
    }

    @ViewBuilder
    private var categoryRows: some View {
        switch selected {
        case .support:
            SettingsSupportView(focus: $focus)
        case .playback:
            SettingsPlaybackView(focus: $focus)
        case .channels:
            SettingsChannelsView(focus: $focus, page: channelsPage) { page in
                showChannelsPage(page)
            }
        case .servers:
            SettingsServersView(focus: $focus)
        case .pro:
            SettingsProView(focus: $focus)
        case .about:
            SettingsAboutView(focus: $focus)
        }
    }

    /// The category's pixel icon beside its title. Falls back to the SF Symbol
    /// placeholder until the asset is in Assets.xcassets/SettingsHero.
    private var hero: some View {
        HStack(alignment: .center, spacing: 24) {
            heroArt
                .id(selected)
                .transition(.opacity)
                .frame(width: Self.heroSize, height: Self.heroSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(selected.title)
                    .font(SettingsFont.heading)
                    .foregroundStyle(Color.nxText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(selected.subtitle)
                    .font(NXFont.captionRegular)
                    .foregroundStyle(Color.nxText2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id(selected)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settingsHeroTitle")
        }
    }

    /// Height of the fade at the top of the scrolling rows, under the hero's divider.
    static let rowsTopFade: CGFloat = 28

    /// Where the first row rests: below the fade, plus the 16 points the focused row's
    /// stroke and glow and the Support tiles' lift have always had.
    static let rowsTopInset: CGFloat = rowsTopFade + 16

    /// The icons are 16x16 pixel art. 80 points is 5 points per pixel (Settings' step down from
    /// the 96 of 6 per pixel), so every pixel still lands on whole points.
    static let heroSize: CGFloat = 80

    @ViewBuilder
    private var heroArt: some View {
        if UIImage(named: selected.heroImageName) != nil {
            Image(selected.heroImageName)
                .resizable()
                // Nearest-neighbour, so the pixel edges stay hard if the art is ever
                // drawn at a size other than its own.
                .interpolation(.none)
                .scaledToFit()
                .frame(width: Self.heroSize, height: Self.heroSize)
        } else {
            Image(systemName: selected.sfSymbolPlaceholder)
                .resizable()
                .scaledToFit()
                .frame(width: 92, height: 92)
                .foregroundStyle(Color.nxCyan)
        }
    }
}

