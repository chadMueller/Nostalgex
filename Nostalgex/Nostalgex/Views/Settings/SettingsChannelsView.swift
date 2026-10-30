import SwiftUI

/// CHANNELS & BUNDLES: the channel packages (with the FRANCHISES list and the I-004
/// missing-channels explainer under them), the SCHEDULE switch, and MY COLLECTIONS.
struct SettingsChannelsView: View {
    @Environment(AppState.self) var appState
    let focus: FocusState<SettingsFocus?>.Binding
    /// Open accordions. Held by the container so they survive a trip to another tab.
    @Binding var expandedCategories: Set<String>

    static func firstRowID(appState: AppState) -> String {
        if let first = appState.bundles.first(where: { !$0.id.hasPrefix("collections-") }) {
            return "bundle_\(first.id)"
        }
        return "watershed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 48) {
            // Channel Packages
            VStack(alignment: .leading, spacing: 20) {
                SettingsSectionHeader(title: "CHANNEL PACKAGES", subtitle: "Toggle packages to customize your lineup")

                VStack(spacing: 4) {
                    // Static bundles (non-collection bundles)
                    ForEach(appState.bundles.filter { !$0.id.hasPrefix("collections-") }) { bundle in
                        // A seasonal package can be switched on any time of year.
                        // Its months decide when it is offered in the guide and
                        // when it leads the lineup, not whether it is available.
                        let inSeason = bundle.isInSeason
                        let availability = appState.bundleChannelAvailability(for: bundle)
                        let availableNames = availability.filter { $0.hasContent }.map(\.name)
                        let missing = availability.filter { !$0.hasContent }
                        let missingNames = missing.map(\.name)
                        let available = availableNames.count
                        let total = bundle.channelIDs.count

                        // Availability is only computed for packages that are on, so
                        // an OFF package is an invitation, never a warning.
                        // ON: line 1 is the channels you have, line 2 (amber) the
                        // ones that can't build yet for lack of content.
                        let subtitle: String = {
                            if !bundle.enabled {
                                let invite = "Turn on to add up to \(total) channel\(total == 1 ? "" : "s") from your library."
                                guard bundle.activeMonths != nil, !inSeason else { return invite }
                                return "\(seasonalLabel(for: bundle)) · \(invite)"
                            }
                            if available == 0 { return "Not enough content to build this bundle" }
                            let names = availableNames.joined(separator: ", ")
                            guard bundle.activeMonths != nil, !inSeason else { return names }
                            return "\(seasonalLabel(for: bundle)) · \(names)"
                        }()
                        let warning: String? = {
                            guard bundle.enabled, available > 0, !missingNames.isEmpty else { return nil }
                            return "Needs more content: \(missingNames.joined(separator: ", "))"
                        }()
                        let detail: String? = bundle.enabled ? "\(available)/\(total) CH" : "\(total) CH"
                        // While its channels build, the row says so instead of
                        // briefly reading "Not enough content" and dimming.
                        let building = bundle.enabled && appState.buildingBundleIDs.contains(bundle.id)

                        SettingsToggleRow(
                            title: bundle.name,
                            subtitle: building ? "Finding \(total) channel\(total == 1 ? "" : "s") in your library" : subtitle,
                            detail: detail,
                            warning: building ? nil : warning,
                            isOn: bundle.enabled,
                            isFocused: isFocused("bundle_\(bundle.id)"),
                            isLoading: building,
                            loadingMessage: "BUILDING"
                        ) {
                            appState.toggleBundle(bundle)
                        }
                        .settingsRow("bundle_\(bundle.id)", focus: focus)
                        .opacity(bundle.enabled && available == 0 && !building ? 0.5 : 1.0)

                        // I-004: why a channel never came on air, in plain language,
                        // next to the count the library actually matched. Only while
                        // the package is on and still building, so an OFF package
                        // (an invitation, not a problem to explain) never shows it.
                        if bundle.enabled && !building && !missing.isEmpty {
                            missingChannelsExplainer(
                                headerID: "missing_\(bundle.id)",
                                missingIDs: missing.map(\.id)
                            )
                            .padding(.leading, 24)
                        }

                        // The classics above are the stock half of FRANCHISES.
                        // Everything the library itself turned out to hold
                        // sits right under them, one switch each.
                        if bundle.id == AppState.franchisesBundleID && bundle.enabled {
                            foundFranchisesBlock
                        }
                    }
                }
            }

            // Schedule: broadcast-realism settings, not a lineup toggle and not part
            // of any kid-mode concept. A sub-section here until it grows its own tab.
            VStack(alignment: .leading, spacing: 20) {
                SettingsSectionHeader(title: "SCHEDULE", subtitle: "How and when your library gets placed on the air")

                SettingsToggleRow(
                    title: "WATERSHED",
                    subtitle: "Hold 18 and R-rated titles until 9 PM on every channel, like broadcast TV. VHS VAULT already holds its own this way; this applies it everywhere else.",
                    isOn: appState.watershedEnabled,
                    isFocused: isFocused("watershed")
                ) {
                    appState.watershedEnabled.toggle()
                }
                .settingsRow("watershed", focus: focus)
            }

            // My Collections: scan once, then browse by category accordion (no bundle toggles)
            VStack(alignment: .leading, spacing: 20) {
                SettingsSectionHeader(title: "MY COLLECTIONS", subtitle: "Scan your server's collections, then turn the ones you want into channels")

                VStack(spacing: 14) {
                    scanCollectionsHeroButton(
                        subtitle: collectionsScanSubtitle(),
                        detail: scanStatusDetail
                    )

                    if !appState.discoveredCollections.isEmpty {
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 1)
                            .padding(.vertical, 4)

                        if appState.visibleDiscoveredCollections.isEmpty {
                            // Every collection the scan found is a franchise the
                            // FRANCHISES package already carries.
                            Text(allCollectionsFoldedHint)
                                .font(.custom("DMMono-Regular", size: 20))
                                .foregroundStyle(.white.opacity(0.7))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        ForEach(Array(CollectionCategory.allCases), id: \.rawValue) { category in
                            collectionsCategoryAccordion(category: category)
                        }
                    } else if !appState.isScanning {
                        Text(collectionEmptyHint)
                            .font(.custom("DMMono-Regular", size: 20))
                            .foregroundStyle(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func isFocused(_ id: String) -> Bool {
        focus.wrappedValue == .row(id)
    }

    // MARK: - Franchises (under the FRANCHISES package row)

    /// The indented block under FRANCHISES: one alphabetical list of every franchise,
    /// the stock classics (CH100-106) and the ones found in the library, each with its
    /// own switch. ADD ALL / REMOVE ALL act on the whole list. Hidden while the package
    /// is off (see the caller).
    @ViewBuilder
    private var foundFranchisesBlock: some View {
        let rows = appState.franchiseListRows

        VStack(alignment: .leading, spacing: 4) {
            if rows.isEmpty {
                Text(foundFranchisesEmptyHint)
                    .font(.custom("DMMono-Regular", size: 20))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            } else {
                HStack(spacing: 12) {
                    Text("YOUR FRANCHISES")
                        .font(.custom("DMMono-Medium", size: 20))
                        .foregroundStyle(.white.opacity(0.8))
                    Text("\(rows.filter(\.enabled).count)/\(rows.count) ON")
                        .font(.custom("VT323-Regular", size: 22))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 6)

                // Only when the range is actually full (CH 300-449); otherwise nothing.
                let overCap = appState.dynamicChannelsOverCap[.foundFranchises, default: 0]
                if overCap > 0 {
                    Text("Up to \(DynamicChannelBlock.foundFranchises.capacity) franchise channels fit in the guide. \(overCap) more are switched on but not shown.")
                        .font(.custom("DMMono-Regular", size: 18))
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 6)
                }

                let allOn = rows.allSatisfy(\.enabled)
                let allOff = !rows.contains(where: \.enabled)
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
        .padding(.leading, 24)
    }

    private var foundFranchisesEmptyHint: String {
        if appState.isDemoMode {
            return "Demo mode has no library to search. Connect a server to find your franchises."
        }
        return "Franchises you own show up here once your library has been enriched."
    }

    // MARK: - My Collections (scan hero + accordion)

    private var collectionEmptyHint: String {
        if appState.allItems.isEmpty {
            return "Wait for your library to finish loading, then scan here."
        }
        return "Finds server movie collections with 3+ films. Franchises go under CHANNEL PACKAGES; the rest appear here after the first scan."
    }

    private var allCollectionsFoldedHint: String {
        let count = appState.discoveredCollections.count
        let noun = count == 1 ? "collection is" : "collections are"
        return "All \(count) of your \(noun) already covered by the FRANCHISES package."
    }

    private func collectionsScanSubtitle() -> String? {
        if appState.isScanning { return nil }
        if appState.allItems.isEmpty {
            return "Library isn’t loaded yet. Try again shortly."
        }
        if appState.discoveredCollections.isEmpty {
            return "Turns your server's collections into optional channels"
        }
        let visible = appState.visibleDiscoveredCollections.count
        let folded = appState.discoveredCollections.count - visible
        let foldedNote = folded > 0 ? " · \(folded) UNDER FRANCHISES" : ""
        let noun = visible == 1 ? "COLLECTION" : "COLLECTIONS"
        return "\(visible) \(noun) CACHED\(foldedNote) · TAP TO RESCAN"
    }

    @ViewBuilder
    private func scanCollectionsHeroButton(subtitle: String?, detail: String) -> some View {
        let canTap = !appState.isScanning && !appState.allItems.isEmpty
        Button {
            if canTap { appState.scanAndCategorizeCollections() }
        } label: {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SCAN MY COLLECTIONS")
                        .font(.custom("DMMono-Medium", size: 22))
                        .foregroundStyle(canTap ? Color.white : Color.white.opacity(0.75))
                        .multilineTextAlignment(.leading)
                    if let subtitle {
                        Text(subtitle)
                            .font(.custom("DMMono-Regular", size: 20))
                            .foregroundStyle(canTap ? Color.white.opacity(0.8) : Color.white.opacity(0.7))
                            .lineLimit(4)
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
                } else if !detail.isEmpty {
                    Text(detail)
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
                        isFocused("scan_collections")
                            ? Color("BrandCyan").opacity(0.55)
                            : Color.white.opacity(canTap ? 0.12 : 0.06),
                        lineWidth: isFocused("scan_collections") ? 2 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(SettingsButtonStyle(
            isFocused: isFocused("scan_collections"),
            accentColor: Color("BrandCyan")
        ))
        .disabled(!canTap)
        .settingsRow("scan_collections", focus: focus)
        .animation(.easeInOut(duration: 0.2), value: appState.isScanning)
        .accessibilityHint(canTap ? "Starts a Plex collections scan." : "")
    }

    @ViewBuilder
    private func collectionsCategoryAccordion(category: CollectionCategory) -> some View {
        // A collection the fold credited to a franchise is not offered here again.
        let rows = appState.visibleDiscoveredCollections.filter { $0.category == category }
        if rows.isEmpty {
            EmptyView()
        } else {
            collectionsAccordionContent(category: category, rows: rows)
        }
    }

    @ViewBuilder
    private func collectionsAccordionContent(category: CollectionCategory, rows: [DiscoveredCollection]) -> some View {
        let headerID = category.bundleID
        let expanded = expandedCategories.contains(headerID)
        let enabledCount = rows.filter(\.enabled).count
        let detail = "\(enabledCount)/\(rows.count) ON AIR"

        VStack(alignment: .leading, spacing: 6) {
            CollectionAccordionHeaderRow(
                title: category.displayName,
                subtitle: category.bundleDescription,
                detail: detail,
                isExpanded: expanded,
                isFocused: isFocused("accordion_\(category.rawValue)")
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expanded {
                        expandedCategories.remove(headerID)
                    } else {
                        expandedCategories.insert(headerID)
                    }
                }
            }
            .settingsRow("accordion_\(category.rawValue)", focus: focus)

            // Only when this category's range is full.
            let overCap = appState.dynamicChannelsOverCap[category.block, default: 0]
            if overCap > 0 {
                Text("Up to \(category.displayCapacity) of these fit in the guide. \(overCap) more are switched on but not shown.")
                    .font(.custom("DMMono-Regular", size: 18))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }

            if expanded {
                ForEach(rows) { collection in
                    let warning = duplicateWarning(for: collection)
                    let subtitle = warning ?? collection.memberSummary
                    SettingsToggleRow(
                        title: collection.title,
                        subtitle: subtitle,
                        isOn: collection.enabled,
                        isFocused: isFocused("collection_\(collection.id)")
                    ) {
                        appState.toggleCollection(collection)
                    }
                    .settingsRow("collection_\(collection.id)", focus: focus)
                    .padding(.leading, 24)
                    .opacity(warning != nil && !collection.enabled ? 0.7 : 1.0)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// I-004: the accordion that explains why one or more of a package's channels have
    /// not come on air. Each row is a channel's own rules in plain language next to how
    /// many library items currently match them, so a viewer can go fix their metadata
    /// instead of wondering. Read-only: nothing here changes a setting or rescans.
    ///
    /// Scoped to static, rule-based channels only (`channel.rules != nil`). Dynamic and
    /// franchise-built channels have no `rules` to translate and are left out rather than
    /// guessed at; if every missing channel in this package is one of those, the
    /// accordion has nothing to show and renders nothing.
    @ViewBuilder
    private func missingChannelsExplainer(headerID: String, missingIDs: [Int]) -> some View {
        // Cheap: just which missing channels have rules to explain at all. No library
        // scan here, so this is safe to compute on every render of every package row.
        let explainable: [Channel] = missingIDs.compactMap { id in
            guard let channel = appState.channelDefinition(for: id), channel.rules != nil else { return nil }
            return channel
        }

        if !explainable.isEmpty {
            let expanded = expandedCategories.contains(headerID)
            // Expensive: a full-library re-filter per channel. Only run it once the
            // viewer actually opens the accordion, and only once for every channel in
            // it (currentMatchCounts builds the library cache a single time), not once
            // per render of a package the viewer never expands.
            let matchCounts = expanded ? appState.currentMatchCounts(for: explainable) : [:]
            VStack(alignment: .leading, spacing: 6) {
                CollectionAccordionHeaderRow(
                    title: "WHY AREN'T THESE ON AIR?",
                    subtitle: "See what each channel needs from your library",
                    detail: "\(explainable.count) CHANNEL\(explainable.count == 1 ? "" : "S")",
                    isExpanded: expanded,
                    isFocused: isFocused("explain_\(headerID)")
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expanded {
                            expandedCategories.remove(headerID)
                        } else {
                            expandedCategories.insert(headerID)
                        }
                    }
                }
                .settingsRow("explain_\(headerID)", focus: focus)

                if expanded {
                    ForEach(explainable, id: \.id) { channel in
                        ChannelRequirementCard(channel: channel, matchedCount: matchCounts[channel.id] ?? channel.itemPool.count)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    /// Subtitle text when a discovered Plex collection looks like a duplicate of
    /// an existing channel. Content overlap (from the TMDB membership manifest)
    /// is the strongest signal; name match is the fallback. Returns nil when
    /// there's no warning, so the row falls back to its member summary ("<N> movies",
    /// "<N> shows · <E> episodes").
    private func duplicateWarning(for collection: DiscoveredCollection) -> String? {
        if let overlap = collection.contentOverlap {
            return "⚠ \(overlap.percent)% already on \(overlap.channelName)"
        }
        if let matched = collection.matchedChannel {
            return "⚠ Exists: \(matched)"
        }
        return nil
    }

    private func seasonalLabel(for bundle: ChannelBundle) -> String {
        guard bundle.activeMonths != nil else { return bundle.description ?? "" }
        return bundle.spotlightLabel(now: Date())
    }

    private var scanStatusDetail: String {
        if appState.isScanning { return "" }
        guard let date = appState.lastScanDate else { return "TAP TO SCAN" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        return "SCANNED \(relative.uppercased())"
    }
}
