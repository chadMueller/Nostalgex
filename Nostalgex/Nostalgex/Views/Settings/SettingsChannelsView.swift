import SwiftUI

/// The pages of CHANNELS & BUNDLES. The tab opens on a short list (`nil`); each link
/// row drills into one of these, inside the same detail pane. Menu steps back one page
/// at a time (the container handles it), then to the rail.
enum ChannelsPage: String, Hashable {
    case packages
    case franchises
    case collections
    /// The I-004 explainer, one level under CHANNEL PACKAGES.
    case missing

    /// The page Menu returns to. `nil` is the Channels list.
    var parent: ChannelsPage? { self == .missing ? .packages : nil }

    /// Focus id of the link row that opens this page, so Menu can put focus back on it.
    var linkRowID: String { "channels_\(rawValue)" }

    var title: String {
        switch self {
        case .packages: return "CHANNEL PACKAGES"
        case .franchises: return "FRANCHISES"
        case .collections: return "MY COLLECTIONS"
        case .missing: return "MISSING CHANNELS"
        }
    }
}

/// CHANNELS & BUNDLES (N-028). A short list of link rows, each with its value on the
/// right, plus the WATERSHED switch. Replaces the long page of accordions.
///
/// Every page is its own view and no page computes anything library-sized in `body`.
/// Each row reads the shared focus binding, so a page's body runs again on every focus
/// move; the old single page re-filtered the whole library on each move while the
/// missing-channels accordion was open (about 1.1 s per press on a simulator with a
/// 11,863-item library), which is what made it lag and jump on an Apple TV.
struct SettingsChannelsView: View {
    @Environment(AppState.self) var appState
    let focus: FocusState<SettingsFocus?>.Binding
    let page: ChannelsPage?
    let open: (ChannelsPage) -> Void

    static func firstRowID(page: ChannelsPage?, appState: AppState) -> String {
        switch page {
        case nil:
            return ChannelsPage.packages.linkRowID
        case .packages:
            return ChannelsPackagesPage.rows(appState: appState).first.map { "bundle_\($0.id)" } ?? "channels_missing"
        case .franchises:
            return appState.franchiseListRows.isEmpty || !ChannelsFranchisesPage.packageOn(appState)
                ? "franchises_package_off" : "franchise_add_all"
        case .collections:
            return "scan_collections"
        case .missing:
            return ChannelsMissingPage.groups(appState: appState).first?.channels.first
                .map { "missing_card_\($0.id)" } ?? "missing_none"
        }
    }

    var body: some View {
        switch page {
        case nil:
            ChannelsHomePage(focus: focus, open: open)
        case .packages:
            ChannelsPackagesPage(focus: focus, open: open)
        case .franchises:
            ChannelsFranchisesPage(focus: focus)
        case .collections:
            ChannelsCollectionsPage(focus: focus)
        case .missing:
            ChannelsMissingPage(focus: focus)
        }
    }
}

// MARK: - Channels list

private struct ChannelsHomePage: View {
    @Environment(AppState.self) var appState
    let focus: FocusState<SettingsFocus?>.Binding
    let open: (ChannelsPage) -> Void

    var body: some View {
        let packages = ChannelsPackagesPage.rows(appState: appState)
        let packagesOn = packages.filter(\.enabled).count
        let franchises = appState.franchiseListRows
        let franchisesValue = ChannelsFranchisesPage.packageOn(appState)
            ? "\(franchises.filter(\.enabled).count) ON" : "OFF"
        let collectionsOn = appState.visibleDiscoveredCollections.filter(\.enabled).count

        VStack(spacing: 4) {
            link(.packages, value: "\(packagesOn) ON")
            link(.franchises, value: franchisesValue)
            link(.collections, value: appState.isScanning ? "SCANNING" : "\(collectionsOn) ON")

            SettingsToggleRow(
                title: "WATERSHED",
                subtitle: "18 and R-rated titles wait until 9 PM",
                isOn: appState.watershedEnabled,
                isFocused: isFocused("watershed")
            ) {
                appState.watershedEnabled.toggle()
            }
            .settingsRow("watershed", focus: focus)
        }
    }

    private func link(_ page: ChannelsPage, value: String) -> some View {
        SettingsLinkRow(title: page.title, value: value, isFocused: isFocused(page.linkRowID)) {
            open(page)
        }
        .settingsRow(page.linkRowID, focus: focus)
    }

    private func isFocused(_ id: String) -> Bool { focus.wrappedValue == .row(id) }
}

// MARK: - Channel packages

private struct ChannelsPackagesPage: View {
    @Environment(AppState.self) var appState
    let focus: FocusState<SettingsFocus?>.Binding
    let open: (ChannelsPage) -> Void

    /// The packages the page lists: every bundle but the per-category collection ones,
    /// which MY COLLECTIONS manages.
    static func rows(appState: AppState) -> [ChannelBundle] {
        appState.bundles.filter { !$0.id.hasPrefix("collections-") }
    }

    var body: some View {
        let missingCount = ChannelsMissingPage.groups(appState: appState).reduce(0) { $0 + $1.channels.count }

        VStack(alignment: .leading, spacing: 20) {
            SettingsSectionHeader(title: ChannelsPage.packages.title, subtitle: "Each package adds a set of channels")

            VStack(spacing: 4) {
                ForEach(Self.rows(appState: appState)) { bundle in
                    packageRow(bundle)
                }

                if missingCount > 0 {
                    SettingsLinkRow(
                        title: "WHY ARE SOME CHANNELS MISSING?",
                        value: "\(missingCount) CH",
                        isFocused: isFocused(ChannelsPage.missing.linkRowID)
                    ) {
                        open(.missing)
                    }
                    .settingsRow(ChannelsPage.missing.linkRowID, focus: focus)
                    .padding(.top, 12)
                }
            }
        }
    }

    @ViewBuilder
    private func packageRow(_ bundle: ChannelBundle) -> some View {
        // A seasonal package can be switched on any time of year. Its months decide
        // when it is offered in the guide and when it leads the lineup, not whether it
        // is available.
        let inSeason = bundle.isInSeason
        let availability = appState.bundleChannelAvailability(for: bundle)
        let available = availability.filter(\.hasContent).count
        let missing = availability.count - available
        let total = bundle.channelIDs.count
        // While its channels build, the row says so instead of briefly reading
        // "Not enough content" and dimming.
        let building = bundle.enabled && appState.buildingBundleIDs.contains(bundle.id)

        // Availability is only computed for packages that are on, so an OFF package is
        // an invitation, never a warning.
        let subtitle: String? = {
            if building { return "Finding \(total) channel\(total == 1 ? "" : "s") in your library" }
            if bundle.enabled && available == 0 { return "Not enough content to build this package" }
            if bundle.activeMonths != nil, !inSeason { return bundle.spotlightLabel(now: Date()) }
            return bundle.description
        }()
        let warning: String? = {
            guard bundle.enabled, !building, available > 0, missing > 0 else { return nil }
            return "\(missing) need\(missing == 1 ? "s" : "") more content"
        }()

        SettingsToggleRow(
            title: bundle.name,
            subtitle: subtitle,
            detail: bundle.enabled ? "\(available)/\(total) CH" : "\(total) CH",
            warning: warning,
            isOn: bundle.enabled,
            isFocused: isFocused("bundle_\(bundle.id)"),
            isLoading: building,
            loadingMessage: "BUILDING"
        ) {
            appState.toggleBundle(bundle)
        }
        .settingsRow("bundle_\(bundle.id)", focus: focus)
        .opacity(bundle.enabled && available == 0 && !building ? 0.5 : 1.0)
    }

    private func isFocused(_ id: String) -> Bool { focus.wrappedValue == .row(id) }
}

// MARK: - Missing channels (I-004)

/// Why a package's channel never came on air: each channel's own rules in plain
/// language, next to how many library items match them now. Read-only.
///
/// Scoped to static, rule-based channels (`channel.rules != nil`) in packages that are
/// on and built. Dynamic and franchise-built channels have no rules to translate.
private struct ChannelsMissingPage: View {
    @Environment(AppState.self) var appState
    let focus: FocusState<SettingsFocus?>.Binding
    /// Live match counts, worked out once when the page opens. Never in `body`: that
    /// runs on every focus move, and the count re-filters the whole library.
    @State private var matchCounts: [Int: Int]?

    struct Group: Identifiable {
        let bundle: ChannelBundle
        let channels: [Channel]
        var id: String { bundle.id }
    }

    /// Cheap: which missing channels have rules to explain. No library scan.
    static func groups(appState: AppState) -> [Group] {
        ChannelsPackagesPage.rows(appState: appState).compactMap { bundle in
            guard bundle.enabled, !appState.buildingBundleIDs.contains(bundle.id) else { return nil }
            let channels: [Channel] = appState.bundleChannelAvailability(for: bundle)
                .filter { !$0.hasContent }
                .compactMap { entry in
                    guard let channel = appState.channelDefinition(for: entry.id), channel.rules != nil else { return nil }
                    return channel
                }
            return channels.isEmpty ? nil : Group(bundle: bundle, channels: channels)
        }
    }

    var body: some View {
        let groups = Self.groups(appState: appState)

        VStack(alignment: .leading, spacing: 20) {
            SettingsSectionHeader(
                title: ChannelsPage.missing.title,
                subtitle: "A channel goes on air once your library has enough titles that fit it"
            )

            if groups.isEmpty {
                Text("Every channel in your packages is on air.")
                    .font(.custom("DMMono-Regular", size: 20))
                    .foregroundStyle(.white.opacity(0.7))
                    .focusable(true)
                    .settingsRow("missing_none", focus: focus)
            }

            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    SettingsSubheader(text: group.bundle.name)
                    ForEach(group.channels, id: \.id) { channel in
                        ChannelRequirementCard(
                            channel: channel,
                            matchedCount: matchCounts?[channel.id],
                            isFocused: focus.wrappedValue == .row("missing_card_\(channel.id)")
                        )
                        .settingsRow("missing_card_\(channel.id)", focus: focus)
                    }
                }
            }
        }
        .task {
            // Let the page draw first, then count once for every channel on it.
            await Task.yield()
            let channels = Self.groups(appState: appState).flatMap(\.channels)
            matchCounts = appState.currentMatchCounts(for: channels)
        }
    }
}

// MARK: - Franchises

private struct ChannelsFranchisesPage: View {
    @Environment(AppState.self) var appState
    let focus: FocusState<SettingsFocus?>.Binding

    static func packageOn(_ appState: AppState) -> Bool {
        appState.bundles.first(where: { $0.id == AppState.franchisesBundleID })?.enabled == true
    }

    var body: some View {
        let rows = appState.franchiseListRows
        let on = Self.packageOn(appState)

        VStack(alignment: .leading, spacing: 20) {
            SettingsSectionHeader(
                title: ChannelsPage.franchises.title,
                subtitle: on && !rows.isEmpty ? "\(rows.filter(\.enabled).count) of \(rows.count) on" : nil
            )

            if !on || rows.isEmpty {
                Text(on ? emptyHint : "Turn on the FRANCHISES package under CHANNEL PACKAGES to pick franchises.")
                    .font(.custom("DMMono-Regular", size: 20))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .focusable(true)
                    .settingsRow("franchises_package_off", focus: focus)
            } else {
                // Only when the range is actually full (CH 310-399); otherwise nothing.
                let overCap = appState.dynamicChannelsOverCap[.foundFranchises, default: 0]
                if overCap > 0 {
                    Text("Up to \(DynamicChannelBlock.foundFranchises.capacity) franchise channels fit in the guide. \(overCap) more are on but not shown.")
                        .font(.custom("DMMono-Regular", size: 18))
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }

                let allOn = rows.allSatisfy(\.enabled)
                let allOff = !rows.contains(where: \.enabled)
                VStack(spacing: 4) {
                    HStack(spacing: 12) {
                        FranchiseActionButton(
                            title: "ADD ALL",
                            subtitle: allOn ? "Every franchise is on" : "Turn on all \(rows.count)",
                            isEnabled: !allOn,
                            isFocused: isFocused("franchise_add_all")
                        ) {
                            appState.setAllFranchises(enabled: true)
                        }
                        .settingsRow("franchise_add_all", focus: focus)

                        FranchiseActionButton(
                            title: "REMOVE ALL",
                            subtitle: allOff ? "None are on" : "Take them all out of the guide",
                            isEnabled: !allOff,
                            isFocused: isFocused("franchise_remove_all")
                        ) {
                            appState.setAllFranchises(enabled: false)
                        }
                        .settingsRow("franchise_remove_all", focus: focus)
                    }

                    ForEach(rows) { row in
                        SettingsToggleRow(
                            title: row.name,
                            subtitle: row.countLabel,
                            detail: row.channelNumber.map { "CH \($0)" },
                            isOn: row.enabled,
                            isFocused: isFocused("franchise_\(row.id)")
                        ) {
                            appState.toggleFranchiseRow(row)
                        }
                        .settingsRow("franchise_\(row.id)", focus: focus)
                    }
                }
            }
        }
    }

    private var emptyHint: String {
        if appState.isDemoMode {
            return "Demo mode has no library to search. Connect a server to find your franchises."
        }
        return "Franchises you own show up here once your library has been enriched."
    }

    private func isFocused(_ id: String) -> Bool { focus.wrappedValue == .row(id) }
}

// MARK: - My Collections

private struct ChannelsCollectionsPage: View {
    @Environment(AppState.self) var appState
    let focus: FocusState<SettingsFocus?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSectionHeader(
                title: ChannelsPage.collections.title,
                subtitle: "Turn your server's collections into channels"
            )

            VStack(alignment: .leading, spacing: 14) {
                scanButton

                if !appState.discoveredCollections.isEmpty {
                    if appState.visibleDiscoveredCollections.isEmpty {
                        // Every collection the scan found is a franchise the FRANCHISES
                        // package already carries.
                        hint(allFoldedHint)
                    }
                    ForEach(Array(CollectionCategory.allCases), id: \.rawValue) { category in
                        categoryGroup(category)
                    }
                } else if !appState.isScanning {
                    hint(emptyHint)
                }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.custom("DMMono-Regular", size: 20))
            .foregroundStyle(.white.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One category's collections, listed flat under a caption with its count. No
    /// accordion: the page itself is the drill-down.
    @ViewBuilder
    private func categoryGroup(_ category: CollectionCategory) -> some View {
        // A collection the fold credited to a franchise is not offered here again.
        let rows = appState.visibleDiscoveredCollections.filter { $0.category == category }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    SettingsSubheader(text: category.displayName)
                    Text("\(rows.filter(\.enabled).count)/\(rows.count) ON")
                        .font(.custom("VT323-Regular", size: 22))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 4)
                }
                .padding(.top, 10)
                .padding(.bottom, 4)

                // Only when this category's range is full.
                let overCap = appState.dynamicChannelsOverCap[category.block, default: 0]
                if overCap > 0 {
                    Text("Up to \(category.displayCapacity) of these fit in the guide. \(overCap) more are on but not shown.")
                        .font(.custom("DMMono-Regular", size: 18))
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(rows) { collection in
                    let warning = duplicateWarning(for: collection)
                    SettingsToggleRow(
                        title: collection.title,
                        subtitle: warning ?? collection.memberSummary,
                        isOn: collection.enabled,
                        isFocused: isFocused("collection_\(collection.id)")
                    ) {
                        appState.toggleCollection(collection)
                    }
                    .settingsRow("collection_\(collection.id)", focus: focus)
                    .opacity(warning != nil && !collection.enabled ? 0.7 : 1.0)
                }
            }
        }
    }

    @ViewBuilder
    private var scanButton: some View {
        let canTap = !appState.isScanning && !appState.allItems.isEmpty
        let focused = isFocused("scan_collections")
        Button {
            if canTap { appState.scanAndCategorizeCollections() }
        } label: {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SCAN MY COLLECTIONS")
                        .font(.custom("DMMono-Medium", size: 22))
                        .foregroundStyle(canTap ? Color.white : Color.white.opacity(0.75))
                    if let subtitle = scanSubtitle {
                        Text(subtitle)
                            .font(.custom("DMMono-Regular", size: 20))
                            .foregroundStyle(.white.opacity(canTap ? 0.8 : 0.7))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                if appState.isScanning {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(Color("BrandCyan"))
                        Text(appState.scanningMessage.isEmpty ? "SCANNING…" : appState.scanningMessage)
                            .font(.custom("DMMono-Regular", size: 20))
                            .foregroundStyle(Color("BrandCyan").opacity(0.85))
                            .lineLimit(2)
                    }
                } else if !scanDetail.isEmpty {
                    Text(scanDetail)
                        .font(.custom("VT323-Regular", size: 22))
                        .foregroundStyle(Color.white.opacity(canTap ? 0.42 : 0.22))
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(canTap ? Color("BrandCyan").opacity(0.1) : Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        focused ? Color("BrandCyan").opacity(0.55) : Color.white.opacity(canTap ? 0.12 : 0.06),
                        lineWidth: focused ? 2 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(SettingsButtonStyle(isFocused: focused, accentColor: Color("BrandCyan")))
        // Stays focusable while it can't be pressed, so the page always has a first row
        // to land on.
        .settingsRow("scan_collections", focus: focus)
        .animation(.easeInOut(duration: 0.2), value: appState.isScanning)
        .accessibilityHint(canTap ? "Starts a collections scan." : "")
    }

    private var scanSubtitle: String? {
        if appState.isScanning { return nil }
        if appState.allItems.isEmpty { return "Library isn’t loaded yet. Try again shortly." }
        if appState.discoveredCollections.isEmpty { return "Collections with 3 or more films can become channels" }
        let visible = appState.visibleDiscoveredCollections.count
        let folded = appState.discoveredCollections.count - visible
        let foldedNote = folded > 0 ? " · \(folded) UNDER FRANCHISES" : ""
        return "\(visible) FOUND\(foldedNote) · TAP TO RESCAN"
    }

    private var scanDetail: String {
        if appState.isScanning { return "" }
        guard let date = appState.lastScanDate else { return "TAP TO SCAN" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "SCANNED \(formatter.localizedString(for: date, relativeTo: Date()).uppercased())"
    }

    private var emptyHint: String {
        if appState.allItems.isEmpty { return "Wait for your library to finish loading, then scan here." }
        return "Franchises go under FRANCHISES; other collections show up here after a scan."
    }

    private var allFoldedHint: String {
        let count = appState.discoveredCollections.count
        let noun = count == 1 ? "collection is" : "collections are"
        return "All \(count) of your \(noun) already covered by FRANCHISES."
    }

    /// Subtitle when a collection looks like a duplicate of an existing channel. Content
    /// overlap (from the TMDB membership manifest) is the strongest signal; name match
    /// is the fallback. nil means no warning, so the row shows its member summary.
    private func duplicateWarning(for collection: DiscoveredCollection) -> String? {
        if let overlap = collection.contentOverlap {
            return "⚠ \(overlap.percent)% already on \(overlap.channelName)"
        }
        if let matched = collection.matchedChannel {
            return "⚠ Exists: \(matched)"
        }
        return nil
    }

    private func isFocused(_ id: String) -> Bool { focus.wrappedValue == .row(id) }
}
