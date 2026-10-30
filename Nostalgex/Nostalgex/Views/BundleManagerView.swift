import SwiftUI
import AVFoundation
import StoreKit

// MARK: - Settings Page (full navigation destination)

struct SettingsPageView: View {
    @Environment(AppState.self) var appState
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedItem: String?
    @State private var expandedCategories: Set<String> = []
    @State private var showSubtitleLanguagePicker = false
    @State private var streamQuality = StreamQuality.current
    @AppStorage(LocalPlexOriginalQuality.storageKey) private var localOriginalVideo = false
    @State private var showStreamQualityPicker = false
    @State private var showAudioLanguagePicker = false
    private let tipJar = TipJar.shared
    /// The tip row picked, which opens the quantity sheet.
    @State private var tipToConfirm: Product?
    /// Set by TIP in the quantity sheet; the purchase starts once the sheet is gone.
    @State private var pendingTip: (product: Product, quantity: Int)?

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

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 48) {

                        VStack(alignment: .leading, spacing: 20) {
                            sectionHeader(
                                "SUPPORT NOSTALGEX",
                                subtitle: showTips
                                    ? "A star rating or a tip, whichever suits"
                                    : "Star ratings help other households find Nostalgex"
                            )

                            if showTips {
                                supportGrid
                            } else {
                                // RATE alone keeps the full-width row it always had.
                                SettingsToggleRow(
                                    title: "RATE NOSTALGEX",
                                    subtitle: appState.hasTappedRate ? "Thanks for rating. Rate again anytime" : "Opens the App Store on your Apple TV",
                                    isOn: true,
                                    isFocused: focusedItem == "rate",
                                    showToggle: false
                                ) {
                                    rateTapped()
                                }
                                .focused($focusedItem, equals: "rate")
                                .id("rate")
                                .accessibilityHint("Opens Nostalgex in the App Store to leave a star rating")
                            }
                        }

                        settingsDivider

                        // Connection
                        connectionSection

                        // Enrichment status (only shown when enriching)
                        // Isolated into its own view so progress updates don't redraw the entire settings list
                        EnrichmentStatusView(enrichmentService: appState.enrichmentService)

                        settingsDivider

                        // Playback: how a channel looks and sounds once it is on screen.
                        VStack(alignment: .leading, spacing: 20) {
                            sectionHeader("PLAYBACK", subtitle: "Picture, quality, subtitles and audio")

                            SettingsToggleRow(
                                title: "RETRO MODE",
                                subtitle: "CRT scanlines, vignette, VHS glitch, 4:3 aspect ratio",
                                isOn: appState.retroMode,
                                isFocused: focusedItem == "retro"
                            ) {
                                appState.retroMode.toggle()
                            }
                            .focused($focusedItem, equals: "retro")
                            .id("retro")

                            SettingsToggleRow(
                                title: "STREAM QUALITY",
                                subtitle: "Lower this when your connection is slow or shared",
                                detail: localOriginalVideo && appState.backendKind == .plex ? "Original (local Plex)" : streamQuality.displayName,
                                isOn: true,
                                isFocused: focusedItem == "stream_quality",
                                showToggle: false
                            ) {
                                showStreamQualityPicker = true
                            }
                            .focused($focusedItem, equals: "stream_quality")
                            .id("stream_quality")

                            // One row for what used to be two switches. "Always" is the
                            // fullscreen switch; "Foreign audio" is the auto fallback alone.
                            // Subtitles never draw over the guide in any mode.
                            SettingsToggleRow(
                                title: "SUBTITLES",
                                subtitle: subtitleModeExplanation,
                                detail: subtitleModeLabel,
                                isOn: true,
                                isFocused: focusedItem == "sub_mode",
                                showToggle: false
                            ) {
                                cycleSubtitleMode()
                            }
                            .focused($focusedItem, equals: "sub_mode")
                            .id("sub_mode")

                            if appState.subtitlesInFullscreenEnabled || appState.autoSubtitlesForForeignAudioEnabled {
                                SettingsToggleRow(
                                    title: "SUBTITLE LANGUAGE",
                                    subtitle: "When the video has multiple subtitle tracks, prefer this language",
                                    detail: subtitleLanguageDetailLabel(appState.preferredSubtitleLanguageCode),
                                    isOn: true,
                                    isFocused: focusedItem == "sub_lang",
                                    showToggle: false
                                ) {
                                    showSubtitleLanguagePicker = true
                                }
                                .focused($focusedItem, equals: "sub_lang")
                                .id("sub_lang")
                            }

                            SettingsToggleRow(
                                title: "AUDIO LANGUAGE",
                                subtitle: "When the video has multiple audio tracks, prefer this language",
                                detail: SubtitleLanguagePreset.displayLabel(for: appState.preferredAudioLanguageCode),
                                isOn: true,
                                isFocused: focusedItem == "audio_lang",
                                showToggle: false
                            ) {
                                showAudioLanguagePicker = true
                            }
                            .focused($focusedItem, equals: "audio_lang")
                            .id("audio_lang")
                        }


                        settingsDivider

                        // Channel Packages
                        VStack(alignment: .leading, spacing: 20) {
                            sectionHeader("CHANNEL PACKAGES", subtitle: "Toggle packages to customize your lineup")

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
                                        isFocused: focusedItem == "bundle_\(bundle.id)",
                                        isLoading: building,
                                        loadingMessage: "BUILDING"
                                    ) {
                                        appState.toggleBundle(bundle)
                                    }
                                    .focused($focusedItem, equals: "bundle_\(bundle.id)")
                                    .id("bundle_\(bundle.id)")
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

                        settingsDivider

                        // Schedule, broadcast-realism settings, not a lineup toggle and
                        // not part of any kid-mode concept.
                        VStack(alignment: .leading, spacing: 20) {
                            sectionHeader("SCHEDULE", subtitle: "How and when your library gets placed on the air")

                            SettingsToggleRow(
                                title: "WATERSHED",
                                subtitle: "Hold 18 and R-rated titles until 9 PM on every channel, like broadcast TV. VHS VAULT already holds its own this way; this applies it everywhere else.",
                                isOn: appState.watershedEnabled,
                                isFocused: focusedItem == "watershed"
                            ) {
                                appState.watershedEnabled.toggle()
                            }
                            .focused($focusedItem, equals: "watershed")
                            .id("watershed")
                        }

                        settingsDivider

                        // My Collections — scan once, then browse by category accordion (no bundle toggles)
                        VStack(alignment: .leading, spacing: 20) {
                            sectionHeader("MY COLLECTIONS", subtitle: "Scan your server's collections, then turn the ones you want into channels")

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

                        Text(appVersionLabel)
                            .font(.custom("DMMono-Regular", size: 20))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 12)
                            .accessibilityLabel("App version \(appVersionLabel)")
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 60)
                }
                .onChange(of: focusedItem) { _, newID in
                    guard let id = newID else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .defaultFocus($focusedItem, "rate")
        .onAppear {
            // Nil lets tvOS pick first focusable; defaultFocus points it at RATE NOSTALGEX,
            // the leading tile of the top row.
            focusedItem = nil
            appState.player?.isMuted = true
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
            // Tip rows stay hidden until (and unless) StoreKit returns the products.
            guard !appState.isDemoMode else { return }
            await tipJar.loadProductsIfNeeded()
        }
        .onDisappear {
            appState.player?.isMuted = false
        }
        .onChange(of: appState.hasCredentials) { _, has in
            // Disconnect from Plex was tapped — pop back so RootView routes to the login screen.
            if !has { dismiss() }
        }
        .sheet(isPresented: $showStreamQualityPicker) {
            StreamQualityPickerSheet(selected: streamQuality, allowsOriginal: appState.backendKind == .plex) { picked in
                if picked != streamQuality {
                    Analytics.track(.settingChanged(key: "stream_quality", value: picked.rawValue))
                }
                StreamQuality.current = picked
                streamQuality = picked
                appState.preferenceSync.record(PreferenceSync.streamQualityKey, value: picked.rawValue)
            }
        }
        .sheet(isPresented: $showSubtitleLanguagePicker) {
            SubtitleLanguagePickerSheet()
                .environment(appState)
        }
        .sheet(isPresented: $showAudioLanguagePicker) {
            AudioLanguagePickerSheet()
                .environment(appState)
        }
        .fullScreenCover(item: $tipToConfirm, onDismiss: {
            guard let tip = pendingTip else { return }
            pendingTip = nil
            Task { await tipJar.purchase(tip.product, quantity: tip.quantity) }
        }) { product in
            TipQuantityView(
                product: product,
                onConfirm: { quantity in
                    pendingTip = (product, quantity)
                    tipToConfirm = nil
                },
                onCancel: { tipToConfirm = nil }
            )
        }
    }

    // MARK: - Helpers

    /// Tips never show in demo mode, and never as an error: no products, no rows.
    private var showTips: Bool {
        !appState.isDemoMode && tipJar.tipsAvailable
    }

    private func rateTapped() {
        Analytics.track(.rateTapped)
        appState.recordRatingTapped()
        openURL(AppStoreLink.productPage)
    }

    /// RATE plus the three tips as one row of four equal tiles.
    @ViewBuilder
    private var supportGrid: some View {
        Text("Tips help keep Nostalgex maintained.")
            .font(.custom("DMMono-Regular", size: 20))
            .foregroundStyle(.white.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 24) {
            SupportTile(
                art: PixelIcons.star,
                title: "RATE NOSTALGEX",
                caption: appState.hasTappedRate ? "Thanks for rating" : "Leave a star rating",
                isFocused: focusedItem == "rate"
            ) {
                rateTapped()
            }
            .focused($focusedItem, equals: "rate")
            .id("rate")
            .accessibilityHint("Opens Nostalgex in the App Store to leave a star rating")

            ForEach(tipJar.products, id: \.id) { product in
                if let tip = TipProduct(rawValue: product.id) {
                    SupportTile(
                        art: PixelIcons.art(for: tip),
                        title: tip.rowTitle,
                        caption: product.displayPrice,
                        captionIsPrice: true,
                        isFocused: focusedItem == tip.focusID
                    ) {
                        guard !tipJar.isPurchasing else { return }
                        tipToConfirm = product
                    }
                    .focused($focusedItem, equals: tip.focusID)
                    .id(tip.focusID)
                    .accessibilityHint("\(product.displayPrice) each. Choose how many, then tip. Unlocks nothing.")
                }
            }
        }
        .focusSection()

        if let line = tipJar.statusLine {
            Text(line)
                .font(.custom("DMMono-Regular", size: 20))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.leading, 24)
        }
    }

    private var subtitleModeLabel: String {
        if appState.subtitlesInFullscreenEnabled { return "ALWAYS" }
        if appState.autoSubtitlesForForeignAudioEnabled { return "FOREIGN AUDIO" }
        return "OFF"
    }

    private var subtitleModeExplanation: String {
        if appState.subtitlesInFullscreenEnabled { return "Shown in fullscreen whenever the video has them" }
        if appState.autoSubtitlesForForeignAudioEnabled { return "Shown in fullscreen when the audio isn't in your language" }
        return "Never shown. Press to change"
    }

    /// Off, then foreign audio only, then always, then back to off.
    private func cycleSubtitleMode() {
        if appState.subtitlesInFullscreenEnabled {
            appState.subtitlesInFullscreenEnabled = false
            appState.autoSubtitlesForForeignAudioEnabled = false
        } else if appState.autoSubtitlesForForeignAudioEnabled {
            appState.subtitlesInFullscreenEnabled = true
        } else {
            appState.autoSubtitlesForForeignAudioEnabled = true
        }
    }

    /// Marketing version plus build, e.g. "VERSION 1.0.10 (17)". Both matter: the build
    /// number is what distinguishes two submissions of the same version.
    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "VERSION \(version) (\(build))"
    }

    private func subtitleLanguageDetailLabel(_ code: String) -> String {
        SubtitleLanguagePreset.displayLabel(for: code)
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
                        isFocused: focusedItem == "franchise_add_all"
                    ) {
                        appState.setAllFranchises(enabled: true)
                    }
                    .focused($focusedItem, equals: "franchise_add_all")
                    .id("franchise_add_all")

                    FranchiseActionButton(
                        title: "REMOVE ALL",
                        subtitle: allOff ? "None are on" : "Take them all out of the guide",
                        isEnabled: !allOff,
                        isFocused: focusedItem == "franchise_remove_all"
                    ) {
                        appState.setAllFranchises(enabled: false)
                    }
                    .focused($focusedItem, equals: "franchise_remove_all")
                    .id("franchise_remove_all")
                }

                ForEach(rows) { row in
                    SettingsToggleRow(
                        title: row.name,
                        subtitle: row.countLabel,
                        detail: row.channelNumber.map { "CH \($0)" },
                        isOn: row.enabled,
                        isFocused: focusedItem == "franchise_\(row.id)"
                    ) {
                        appState.toggleFranchiseRow(row)
                    }
                    .focused($focusedItem, equals: "franchise_\(row.id)")
                    .id("franchise_\(row.id)")
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
                        focusedItem == "scan_collections"
                            ? Color("BrandCyan").opacity(0.55)
                            : Color.white.opacity(canTap ? 0.12 : 0.06),
                        lineWidth: focusedItem == "scan_collections" ? 2 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(SettingsButtonStyle(
            isFocused: focusedItem == "scan_collections",
            accentColor: Color("BrandCyan")
        ))
        .disabled(!canTap)
        .focused($focusedItem, equals: "scan_collections")
        .id("scan_collections")
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
                isFocused: focusedItem == "accordion_\(category.rawValue)"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expanded {
                        expandedCategories.remove(headerID)
                    } else {
                        expandedCategories.insert(headerID)
                    }
                }
            }
            .focused($focusedItem, equals: "accordion_\(category.rawValue)")
            .id("accordion_\(category.rawValue)")

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
                        isFocused: focusedItem == "collection_\(collection.id)"
                    ) {
                        appState.toggleCollection(collection)
                    }
                    .focused($focusedItem, equals: "collection_\(collection.id)")
                    .id("collection_\(collection.id)")
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
                    isFocused: focusedItem == "explain_\(headerID)"
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expanded {
                            expandedCategories.remove(headerID)
                        } else {
                            expandedCategories.insert(headerID)
                        }
                    }
                }
                .focused($focusedItem, equals: "explain_\(headerID)")
                .id("explain_\(headerID)")

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

    private var settingsDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.06))
            .frame(height: 1)
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.custom("DMMono-Medium", size: 28))
                .foregroundStyle(.white.opacity(0.8))
            Text(subtitle)
                .font(.custom("DMMono-Regular", size: 20))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CONNECTION")
                .font(.custom("DMMono-Medium", size: 28))
                .foregroundStyle(.white.opacity(0.8))

            Text("SERVERS")
                .font(.custom("DMMono-Regular", size: 20))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 4)

            // One row per reachable server. Toggle to include/exclude its library;
            // the last remaining server can't be turned off.
            ForEach(appState.serversForSettings) { server in
                let isIncluded = appState.selectedServers.contains { $0.machineIdentifier == server.machineIdentifier }
                let isLast = isIncluded && appState.selectedServers.count <= 1
                SettingsToggleRow(
                    title: server.name.uppercased(),
                    subtitle: isLast ? "Your server · only connected server" : (server.owned ? "Your server" : "Shared with you"),
                    detail: isIncluded ? "INCLUDED" : "OFF",
                    isOn: isIncluded,
                    isFocused: focusedItem == "server_\(server.machineIdentifier)",
                    // No toggle when it's the only server — it can't be removed.
                    showToggle: !isLast
                ) {
                    guard !isLast, !appState.isLoading, !appState.isBackgroundRefreshing else { return }
                    appState.toggleServer(server)
                }
                .focused($focusedItem, equals: "server_\(server.machineIdentifier)")
                .id("server_\(server.machineIdentifier)")
            }

            Text("LIBRARIES")
                .font(.custom("DMMono-Regular", size: 20))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 4)

            // One row per library section on every connected server (I-054). Toggle to
            // include/exclude it from the scan; the last remaining section can't be
            // turned off, same guard the server row above already has.
            ForEach(appState.librarySectionsForSettings) { section in
                let isOn = !appState.isLibrarySectionDeselected(section)
                let isLast = isOn && appState.enabledLibrarySectionCount <= 1
                let multiServer = Set(appState.librarySectionsForSettings.map(\.serverID)).count > 1
                SettingsToggleRow(
                    title: section.title.uppercased(),
                    subtitle: isLast
                        ? "\(section.typeLabel) · only enabled library"
                        : (multiServer ? "\(section.serverName) · \(section.typeLabel)" : section.typeLabel),
                    detail: isOn ? "INCLUDED" : "OFF",
                    isOn: isOn,
                    isFocused: focusedItem == "section_\(section.id)",
                    // No toggle when it's the only section left on, it can't be removed.
                    showToggle: !isLast
                ) {
                    guard !isLast, !appState.isLoading, !appState.isBackgroundRefreshing else { return }
                    appState.toggleLibrarySection(section)
                }
                .focused($focusedItem, equals: "section_\(section.id)")
                .id("section_\(section.id)")
            }

            SettingsToggleRow(
                title: "RESCAN LIBRARY",
                subtitle: {
                    let updated = appState.libraryLastUpdatedText
                    // What the app is actually holding, so a support report can say it in
                    // one screenshot. See LibraryDiagnostics.
                    let held = LibraryDiagnostics.summary(appState.allItems)
                    let base = "Pull a fresh copy of your \(appState.backendDisplayName) library after adding content"
                    // The last time the app gave up on a stream, and exactly why. Reads
                    // "device" or "server" without a debugger. See PlaybackDiagnostics.
                    let verdict = PlaybackDiagnostics.latestForSettings().map { "\nLast playback failure: \($0)" } ?? ""
                    return "\(held)\nLast updated \(updated). \(base)\(verdict)"
                }(),
                isOn: true,
                isFocused: focusedItem == "rescan",
                isLoading: appState.isLoading || appState.isBackgroundRefreshing,
                loadingMessage: appState.isBackgroundRefreshing ? "Updating…" : (appState.isLoading ? "Scanning…" : nil),
                showToggle: false
            ) {
                guard !appState.isLoading, !appState.isBackgroundRefreshing else { return }
                Task { await appState.rescanLibrary() }
            }
            .focused($focusedItem, equals: "rescan")
            .id("rescan")
            .accessibilityLabel("Rescan library")
            .padding(.top, 8)

            if !appState.isDemoMode {
                SettingsToggleRow(
                    title: "SHOW NOW PLAYING ON \(appState.backendDisplayName.uppercased())",
                    subtitle: appState.backendKind == .plex
                        ? "Show the current program on Plex. Leave Mark Watched off to keep watch history unchanged."
                        : "Show the current program. Prior watch state is restored when playback ends; a working connection is required.",
                    isOn: appState.showNowPlaying,
                    isFocused: focusedItem == "now_playing_sync"
                ) {
                    appState.showNowPlaying.toggle()
                }
                .focused($focusedItem, equals: "now_playing_sync")
                .id("now_playing_sync")
                .accessibilityHint("Reports the current program to \(appState.backendDisplayName). Mark Watched is a separate choice")

                SettingsToggleRow(
                    title: "MARK WATCHED ON \(appState.backendDisplayName.uppercased())",
                    subtitle: "Count a program as watched when you tune in during its first 15% and watch at least 75%. Independent of Now Playing. Off by default.",
                    isOn: appState.markWatched,
                    isFocused: focusedItem == "mark_watched"
                ) {
                    appState.markWatched.toggle()
                }
                .focused($focusedItem, equals: "mark_watched")
                .id("mark_watched")
                .accessibilityHint("Updates watch history after a qualifying watch. Does not enable Now Playing")
            }

            // Off by default and per-TV. Turning it on pushes this TV's lineup and
            // settings to iCloud first, then listens.
            SettingsToggleRow(
                title: "SYNC WITH MY OTHER APPLE TVS",
                subtitle: appState.iCloudSyncEnabled
                    ? "This Apple TV's lineup is shared through iCloud."
                    : "Turn on to share your lineup and settings with your other Apple TVs through iCloud.",
                isOn: appState.iCloudSyncEnabled,
                isFocused: focusedItem == "icloud_sync"
            ) {
                appState.iCloudSyncEnabled.toggle()
            }
            .focused($focusedItem, equals: "icloud_sync")
            .id("icloud_sync")

            SettingsToggleRow(
                title: "DISCONNECT FROM \(appState.backendDisplayName.uppercased())",
                subtitle: "Clears saved \(appState.backendDisplayName) access. Use when switching servers",
                isOn: true,
                isFocused: focusedItem == "disconnect",
                showToggle: false
            ) {
                appState.disconnect()
            }
            .focused($focusedItem, equals: "disconnect")
            .id("disconnect")
            .accessibilityLabel("Disconnect from \(appState.backendDisplayName)")
        }
    }

}

// MARK: - Collection category accordion (show / hide only — not a lineup toggle)

private struct CollectionAccordionHeaderRow: View {
    let title: String
    let subtitle: String
    let detail: String
    let isExpanded: Bool
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.custom("DMMono-Medium", size: 20))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)

                    Text(subtitle)
                        .font(.custom("DMMono-Regular", size: 20))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(detail)
                        .font(.custom("DMMono-Regular", size: 20))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(isExpanded ? "HIDE" : "SHOW")
                        .font(.custom("VT323-Regular", size: 22))
                        .foregroundStyle(Color("BrandCyan").opacity(isFocused ? 1.0 : 0.75))
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isFocused ? Color.white.opacity(0.07) : Color.white.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isFocused ? Color("BrandCyan").opacity(0.5) : Color.white.opacity(0.08),
                        lineWidth: isFocused ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SettingsButtonStyle(isFocused: isFocused, accentColor: Color("BrandCyan")))
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
        .animation(.easeInOut(duration: 0.12), value: isFocused)
    }
}

/// I-004: one channel's plain-language explainer, inside the missing-channels
/// accordion. Read-only, not focusable; nothing on this card changes anything.
private struct ChannelRequirementCard: View {
    let channel: Channel
    let matchedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(channel.color)
                    .frame(width: 4, height: 18)
                Text(channel.name.uppercased())
                    .font(.custom("DMMono-Medium", size: 20))
                    .foregroundStyle(.white)
            }

            Text("Needs at least \(channel.minItems) matching title\(channel.minItems == 1 ? "" : "s"). Your library has \(matchedCount) right now.")
                .font(.custom("DMMono-Regular", size: 18))
                .foregroundStyle(Color(hex: "#FFB020"))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array((channel.rules?.plainLanguageRequirements ?? []).enumerated()), id: \.offset) { _, line in
                    Text("\u{2022} \(line)")
                        .font(.custom("DMMono-Regular", size: 18))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.03))
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Franchises: ADD ALL / REMOVE ALL

/// Half-width action row for the found-franchise block. Same chrome as
/// SettingsToggleRow (DMMono, cyan focus stroke), no switch, dims when it has nothing
/// left to do so the pair reads as a state as much as a control.
private struct FranchiseActionButton: View {
    let title: String
    let subtitle: String
    let isEnabled: Bool
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.custom("DMMono-Medium", size: 22))
                    .foregroundStyle(isEnabled ? .white : .white.opacity(0.35))
                Text(subtitle)
                    .font(.custom("DMMono-Regular", size: 20))
                    .foregroundStyle(.white.opacity(isEnabled ? 0.8 : 0.5))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isFocused ? .white.opacity(0.07) : .white.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isFocused ? Color("BrandCyan").opacity(0.5) : .clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(SettingsButtonStyle(isFocused: isFocused))
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Support tile

/// One of the four SUPPORT NOSTALGEX tiles: a pixel icon, a title and one short line.
/// Focus matches SettingsToggleRow (cyan stroke, lighter fill) plus a small lift.
struct SupportTile: View {
    let art: PixelArt
    let title: String
    let caption: String
    /// A price reads in the title weight so it stays legible from the couch.
    var captionIsPrice: Bool = false
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 18) {
                PixelIconView(art: art, size: 96)

                VStack(spacing: 6) {
                    Text(title)
                        .font(.custom("DMMono-Medium", size: 22))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(caption)
                        .font(captionIsPrice ? .custom("DMMono-Medium", size: 22) : .custom("DMMono-Regular", size: 20))
                        .foregroundStyle(.white.opacity(captionIsPrice ? 0.85 : 0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 30)
            .padding(.bottom, 26)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isFocused ? .white.opacity(0.08) : .white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isFocused ? Color("BrandCyan").opacity(0.6) : .white.opacity(0.06),
                        lineWidth: isFocused ? 2 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .scaleEffect(isFocused ? 1.04 : 1.0)
        }
        .buttonStyle(SettingsButtonStyle(isFocused: isFocused))
        .accessibilityLabel(title)
        .accessibilityValue(caption)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Toggle Row

struct SettingsToggleRow: View {
    let title: String
    let subtitle: String?
    var detail: String? = nil
    /// A price has to be readable; the default detail is a faint annotation.
    var detailIsProminent: Bool = false
    var warning: String? = nil
    let isOn: Bool
    let isFocused: Bool
    var isLoading: Bool = false
    var loadingMessage: String? = nil
    var showToggle: Bool = true
    let onToggle: () -> Void

    var body: some View {
        Button {
            onToggle()
        } label: {
            HStack(spacing: 16) {
                // Label
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.custom("DMMono-Medium", size: 22))
                        .foregroundStyle(isOn ? .white : .white.opacity(0.35))

                    if let subtitle {
                        Text(subtitle)
                            .font(.custom("DMMono-Regular", size: 20))
                            .foregroundStyle(.white.opacity(isOn ? 0.8 : 0.5))
                            .lineLimit(2)
                    }

                    if let warning {
                        Text(warning)
                            .font(.custom("DMMono-Regular", size: 20))
                            .foregroundStyle(Color(hex: "#FFB020"))
                            .lineLimit(2)
                    }
                }

                Spacer()

                // Detail text or loading message
                if isLoading, let msg = loadingMessage {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(Color("BrandCyan"))
                        Text(msg)
                            .font(.custom("DMMono-Regular", size: 20))
                            .foregroundStyle(Color("BrandCyan").opacity(0.7))
                    }
                } else if isLoading {
                    ProgressView()
                        .tint(Color("BrandCyan"))
                } else if let detail {
                    Text(detail)
                        .font(detailIsProminent ? .custom("DMMono-Medium", size: 22) : .custom("VT323-Regular", size: 20))
                        .foregroundStyle(.white.opacity(detailIsProminent ? 0.85 : 0.2))
                }

                // Toggle switch (hidden while loading or when showToggle is false)
                if !isLoading && showToggle {
                    ToggleSwitch(isOn: isOn)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isFocused ? .white.opacity(0.07) : .white.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isFocused ? Color("BrandCyan").opacity(0.5) : .clear,
                        lineWidth: 1.5
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(SettingsButtonStyle(isFocused: isFocused))
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .animation(.easeInOut(duration: 0.2), value: isOn)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Toggle Switch

struct ToggleSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            // Track
            Capsule()
                .fill(isOn ? Color("BrandCyan").opacity(0.3) : .white.opacity(0.1))
                .frame(width: 52, height: 30)
                .overlay(
                    Capsule()
                        .stroke(isOn ? Color("BrandCyan").opacity(0.5) : .white.opacity(0.15), lineWidth: 1)
                )

            // Thumb
            Circle()
                .fill(isOn ? Color("BrandCyan") : .white.opacity(0.7))
                .frame(width: 24, height: 24)
                .padding(3)
        }
        .animation(.easeInOut(duration: 0.2), value: isOn)
        .accessibilityHidden(true)
    }
}

// MARK: - Enrichment Progress (isolated to limit redraw blast radius)

private struct EnrichmentStatusView: View {
    let enrichmentService: EnrichmentService

    var body: some View {
        if enrichmentService.isEnriching {
            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ENRICHMENT")
                        .font(.custom("DMMono-Medium", size: 28))
                        .foregroundStyle(.white.opacity(0.8))
                    Text("Improving channel accuracy with TMDB + OMDb metadata")
                        .font(.custom("DMMono-Regular", size: 20))
                        .foregroundStyle(.white.opacity(0.7))
                }

                HStack(spacing: 16) {
                    ProgressView(value: enrichmentService.progress)
                        .progressViewStyle(.linear)
                        .tint(Color("BrandCyan"))
                        .focusable(false)

                    Text("\(enrichmentService.enrichedCount)/\(enrichmentService.totalToEnrich)")
                        .font(.custom("DMMono-Medium", size: 20))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }
}

// MARK: - Button Style

struct SettingsButtonStyle: ButtonStyle {
    let isFocused: Bool
    var accentColor: Color = Color("BrandCyan")

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Subtitle language preset list
//
// `SubtitleLanguagePreset` now lives in Models/ — the in-player Now Playing panel offers
// the same two language settings and has to render the same labels.

private struct LanguagePickerSheet: View {
    let title: String
    let subtitle: String
    let presets: [SubtitleLanguagePreset]
    let selectedCode: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedID: String?

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

            VStack(alignment: .leading, spacing: 20) {
                Text(title)
                    .font(.custom("DMMono-Medium", size: 28))
                    .foregroundStyle(.white.opacity(0.8))

                Text(subtitle)
                    .font(.custom("DMMono-Regular", size: 20))
                    .foregroundStyle(.white.opacity(0.7))

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(presets) { preset in
                            let isSel = selectedCode == preset.code
                            Button {
                                onSelect(preset.code)
                                dismiss()
                            } label: {
                                HStack(spacing: 16) {
                                    Text(preset.label)
                                        .font(.custom("DMMono-Medium", size: 22))
                                        .foregroundStyle(isSel ? Color("BrandCyan") : .white.opacity(0.85))

                                    Spacer()

                                    if isSel {
                                        Text("ACTIVE")
                                            .font(.custom("VT323-Regular", size: 20))
                                            .foregroundStyle(Color("BrandCyan").opacity(0.7))
                                    }
                                }
                                .padding(.horizontal, 24)
                                .padding(.vertical, 18)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(focusedID == preset.id ? .white.opacity(0.07) : .white.opacity(0.02))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(
                                            focusedID == preset.id ? Color("BrandCyan").opacity(0.5) : .clear,
                                            lineWidth: 1.5
                                        )
                                )
                            }
                            .buttonStyle(SettingsButtonStyle(isFocused: focusedID == preset.id))
                            .focused($focusedID, equals: preset.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
        }
    }
}

struct StreamQualityPickerSheet: View {
    let selected: StreamQuality
    let allowsOriginal: Bool
    @AppStorage(LocalPlexOriginalQuality.storageKey) private var localOriginalVideo = false
    let onSelect: (StreamQuality) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedID: String?

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

            VStack(alignment: .leading, spacing: 20) {
                Text("STREAM QUALITY")
                    .font(.custom("DMMono-Medium", size: 28))
                    .foregroundStyle(.white.opacity(0.8))

                Text("Lower quality uses less bandwidth. Auto adjusts as your connection changes.")
                    .font(.custom("DMMono-Regular", size: 20))
                    .foregroundStyle(.white.opacity(0.7))

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        if allowsOriginal {
                            Button {
                                localOriginalVideo.toggle()
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(localOriginalVideo ? "Original (local Plex) · ACTIVE" : "Original (local Plex)")
                                        .font(.custom("DMMono-Medium", size: 22))
                                    Text(LocalPlexOriginalQuality.detail)
                                        .font(.custom("DMMono-Regular", size: 20))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(18)
                            }
                            .focused($focusedID, equals: "local-original")
                        }
                        ForEach(StreamQuality.allCases) { quality in
                            let isSel = selected == quality
                            Button {
                                localOriginalVideo = false
                                onSelect(quality)
                                dismiss()
                            } label: {
                                HStack(spacing: 16) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(quality.displayName)
                                            .font(.custom("DMMono-Medium", size: 22))
                                            .foregroundStyle(isSel ? Color("BrandCyan") : .white.opacity(0.85))

                                        Text(quality.detail)
                                            .font(.custom("DMMono-Regular", size: 20))
                                            .foregroundStyle(.white.opacity(0.7))
                                    }

                                    Spacer()

                                    if isSel {
                                        Text("ACTIVE")
                                            .font(.custom("VT323-Regular", size: 20))
                                            .foregroundStyle(Color("BrandCyan").opacity(0.7))
                                    }
                                }
                                .padding(.horizontal, 24)
                                .padding(.vertical, 18)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(focusedID == quality.id ? .white.opacity(0.07) : .white.opacity(0.02))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(
                                            focusedID == quality.id ? Color("BrandCyan").opacity(0.5) : .clear,
                                            lineWidth: 1.5
                                        )
                                )
                            }
                            .buttonStyle(SettingsButtonStyle(isFocused: focusedID == quality.id))
                            .focused($focusedID, equals: quality.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
        }
    }
}

struct SubtitleLanguagePickerSheet: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        LanguagePickerSheet(
            title: "SUBTITLE LANGUAGE",
            subtitle: "Choose which subtitle track to prefer when multiple are available.",
            presets: SubtitleLanguagePreset.all,
            selectedCode: appState.preferredSubtitleLanguageCode
        ) { appState.preferredSubtitleLanguageCode = $0 }
    }
}

struct AudioLanguagePickerSheet: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        LanguagePickerSheet(
            title: "AUDIO LANGUAGE",
            subtitle: "Choose which audio track to prefer when multiple are available.",
            presets: SubtitleLanguagePreset.all,
            selectedCode: appState.preferredAudioLanguageCode
        ) { appState.preferredAudioLanguageCode = $0 }
    }
}
