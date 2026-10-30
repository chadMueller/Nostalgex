import SwiftUI
import AVFoundation

/// Settings as a rail plus a detail pane (N-028). What AppDestination.settings pushes.
///
/// - Up/down on the rail swaps the detail pane's hero and rows live, no press.
/// - Right or select moves focus into the category's rows.
/// - Menu from the rows returns focus to the rail; Menu from the rail leaves Settings.
/// - Left from the rows lands back on the selected tab, not whichever tab is level with
///   the row, so the pane never swaps under you on the way out.
/// - The hero and title stay pinned at the top of the pane; only the rows scroll.
struct SettingsContainerView: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: SettingsFocus?
    @State private var selected: SettingsCategory = .support
    /// Open accordions in CHANNELS & BUNDLES, kept while you visit other tabs.
    @State private var expandedCategories: Set<String> = []

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
                        focus = .rail(selected)
                    }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .defaultFocus($focus, .rail(.support))
        .onChange(of: focus) { _, newFocus in
            guard case .rail(let category)? = newFocus, category != selected else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                selected = category
            }
        }
        .onAppear {
            appState.player?.isMuted = true
        }
        .onDisappear {
            appState.player?.isMuted = false
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

    private func firstRowID(for category: SettingsCategory) -> String {
        switch category {
        case .support: return SettingsSupportView.firstRowID
        case .playback: return SettingsPlaybackView.firstRowID
        case .channels: return SettingsChannelsView.firstRowID(appState: appState)
        case .servers: return SettingsServersView.firstRowID(appState: appState)
        case .pro: return SettingsProView.firstRowID
        case .about: return SettingsAboutView.firstRowID
        }
    }

    // MARK: - Detail pane

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
                .padding(.horizontal, 80)
                .padding(.top, 60)
                .padding(.bottom, 28)

            // Only the rows scroll. Pro will add 10 to 15 rows across categories, so
            // nothing here assumes a category fits on screen.
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 1).id("rows_top")
                        categoryRows
                            .id(selected)
                            .transition(.opacity)
                    }
                    // Room for the focused row's stroke and the Support tiles' lift,
                    // so neither is clipped at the scroll edges.
                    .padding(.horizontal, 80)
                    .padding(.top, 16)
                    .padding(.bottom, 80)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: focus) { _, newFocus in
                    guard case .row(let id)? = newFocus else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onChange(of: selected) { _, _ in
                    proxy.scrollTo("rows_top", anchor: .top)
                }
            }
            .overlay(alignment: .top) {
                // A thin line where rows slide under the pinned hero.
                SettingsDivider()
                    .padding(.horizontal, 80)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var categoryRows: some View {
        switch selected {
        case .support:
            SettingsSupportView(focus: $focus)
        case .playback:
            SettingsPlaybackView(focus: $focus)
        case .channels:
            SettingsChannelsView(focus: $focus, expandedCategories: $expandedCategories)
        case .servers:
            SettingsServersView(focus: $focus)
        case .pro:
            SettingsProView(focus: $focus)
        case .about:
            SettingsAboutView(focus: $focus)
        }
    }

    /// The category's 16:9 illustration beside its title. Falls back to the SF Symbol
    /// placeholder until the asset is in Assets.xcassets/SettingsHero.
    private var hero: some View {
        HStack(alignment: .center, spacing: 44) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.03))
                heroArt
                    .id(selected)
                    .transition(.opacity)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            }
            .frame(width: Self.heroSize.width, height: Self.heroSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
                Text(selected.title)
                    .font(.custom("DMMono-Medium", size: 44))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(selected.subtitle)
                    .font(.custom("DMMono-Regular", size: 22))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id(selected)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settingsHeroTitle")
        }
    }

    /// 16:9, to match the hero PNGs.
    static let heroSize = CGSize(width: 384, height: 216)

    @ViewBuilder
    private var heroArt: some View {
        if UIImage(named: selected.heroImageName) != nil {
            Image(selected.heroImageName)
                .resizable()
                .scaledToFill()
                .frame(width: Self.heroSize.width, height: Self.heroSize.height)
        } else {
            Image(systemName: selected.sfSymbolPlaceholder)
                .resizable()
                .scaledToFit()
                .frame(width: 110, height: 110)
                .foregroundStyle(selected.heroTint)
        }
    }
}
