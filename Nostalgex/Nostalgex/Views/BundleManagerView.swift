import SwiftUI
import AVFoundation

// MARK: - Settings Page (full navigation destination)

struct SettingsPageView: View {
    @Environment(AppState.self) var appState
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedItem: String?
    @State private var expandedCategories: Set<String> = []
    @State private var showSubtitleLanguagePicker = false
    @State private var streamQuality = StreamQuality.current
    @State private var showStreamQualityPicker = false
    @State private var showAudioLanguagePicker = false

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
                            sectionHeader("SUPPORT NOSTALGEX", subtitle: "Star ratings help other households find Nostalgex")

                            SettingsToggleRow(
                                title: "RATE NOSTALGEX",
                                subtitle: "Opens the App Store on your Apple TV",
                                isOn: true,
                                isFocused: focusedItem == "rate",
                                showToggle: false
                            ) {
                                Analytics.track(.rateTapped)
                                openURL(AppStoreLink.productPage)
                            }
                            .focused($focusedItem, equals: "rate")
                            .id("rate")
                            .accessibilityHint("Opens Nostalgex in the App Store to leave a star rating")

                        }

                        settingsDivider

                        // Connection
                        connectionSection

                        // Enrichment status (only shown when enriching)
                        // Isolated into its own view so progress updates don't redraw the entire settings list
                        EnrichmentStatusView(enrichmentService: appState.enrichmentService)

                        settingsDivider

                        // Display
                        VStack(alignment: .leading, spacing: 20) {
                            sectionHeader("DISPLAY", subtitle: "Visual effects and aspect ratio")

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
                                detail: streamQuality.displayName,
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
                                    let missingNames = availability.filter { !$0.hasContent }.map(\.name)
                                    let available = availableNames.count
                                    let total = bundle.channelIDs.count

                                    // Line 1: channels you have. Line 2 (amber): channels that
                                    // can't build yet because there isn't enough content.
                                    let subtitle: String = {
                                        if available == 0 { return "Not enough content to build this bundle" }
                                        let names = availableNames.joined(separator: ", ")
                                        guard bundle.activeMonths != nil, !inSeason else { return names }
                                        return "\(seasonalLabel(for: bundle)) · \(names)"
                                    }()
                                    let warning: String? = {
                                        guard available > 0, !missingNames.isEmpty else { return nil }
                                        return "Needs more content: \(missingNames.joined(separator: ", "))"
                                    }()
                                    let detail: String? = "\(available)/\(total) CH"

                                    SettingsToggleRow(
                                        title: bundle.name,
                                        subtitle: subtitle,
                                        detail: detail,
                                        warning: warning,
                                        isOn: bundle.enabled,
                                        isFocused: focusedItem == "bundle_\(bundle.id)"
                                    ) {
                                        appState.toggleBundle(bundle)
                                    }
                                    .focused($focusedItem, equals: "bundle_\(bundle.id)")
                                    .id("bundle_\(bundle.id)")
                                    .opacity(available == 0 ? 0.5 : 1.0)
                                }
                            }
                        }

                        settingsDivider

                        // My Collections — scan once, then browse by category accordion (no bundle toggles)
                        VStack(alignment: .leading, spacing: 20) {
                            sectionHeader("MY COLLECTIONS", subtitle: "Scan Plex collections, then turn individual collections into channels")

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
        .onAppear {
            // Nil lets tvOS pick first focusable (RATE NOSTALGEX is the top row).
            focusedItem = nil
            appState.player?.isMuted = true
        }
        .task {
            // Refresh the reachable-server list so deselected servers can be re-added.
            await appState.refreshAvailableServers()
        }
        .onDisappear {
            appState.player?.isMuted = false
        }
        .onChange(of: appState.hasCredentials) { _, has in
            // Disconnect from Plex was tapped — pop back so RootView routes to the login screen.
            if !has { dismiss() }
        }
        .sheet(isPresented: $showStreamQualityPicker) {
            StreamQualityPickerSheet(selected: streamQuality) { picked in
                if picked != streamQuality {
                    Analytics.track(.settingChanged(key: "stream_quality", value: picked.rawValue))
                }
                StreamQuality.current = picked
                streamQuality = picked
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
    }

    // MARK: - Helpers

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

    // MARK: - My Collections (scan hero + accordion)

    private var collectionEmptyHint: String {
        if appState.allItems.isEmpty {
            return "Wait for your library to finish loading, then scan here."
        }
        return "Finds Plex movie collections with 3+ films. Categories appear after the first scan."
    }

    private func collectionsScanSubtitle() -> String? {
        if appState.isScanning { return nil }
        if appState.allItems.isEmpty {
            return "Library isn’t loaded yet. Try again shortly."
        }
        if appState.discoveredCollections.isEmpty {
            return "Turns your server's collections into optional channels"
        }
        return "\(appState.discoveredCollections.count) COLLECTIONS CACHED · TAP TO RESCAN"
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
        let rows = appState.discoveredCollections.filter { $0.category == category }
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

            if expanded {
                ForEach(rows) { collection in
                    let warning = duplicateWarning(for: collection)
                    let subtitle = warning ?? "\(collection.movieCount) movies"
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

    /// Subtitle text when a discovered Plex collection looks like a duplicate of
    /// an existing channel. Content overlap (from the TMDB membership manifest)
    /// is the strongest signal; name match is the fallback. Returns nil when
    /// there's no warning, so the row falls back to "<N> movies".
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
        guard let months = bundle.activeMonths else { return bundle.description ?? "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        let names = months.compactMap { m -> String? in
            var comps = DateComponents()
            comps.month = m
            guard let date = Calendar.current.date(from: comps) else { return nil }
            return formatter.string(from: date).uppercased()
        }
        return "Spotlighted \(names.joined(separator: ", "))"
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

            // Playback reporting. Same switch on every server: off, a watch here
            // stays in the app; on, it counts on the server they connected.
            if !appState.isDemoMode {
                SettingsToggleRow(
                    title: "REPORT PLAYBACK TO \(appState.backendDisplayName.uppercased())",
                    subtitle: "Off by default. When on, a real watch here counts on your server.",
                    // Warning stays full-brightness while the row's own text dims,
                    // so the side effect is legible exactly when it applies.
                    warning: appState.syncPlexActivity
                        ? "Channel surfing can mark plays and leave resume points"
                        : nil,
                    isOn: appState.syncPlexActivity,
                    isFocused: focusedItem == "plex_sync"
                ) {
                    appState.syncPlexActivity.toggle()
                }
                .focused($focusedItem, equals: "plex_sync")
                .id("plex_sync")
                .accessibilityHint("Updates play counts, resume points and Continue Watching in \(appState.backendDisplayName)")
            }

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

// MARK: - Toggle Row

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String?
    var detail: String? = nil
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
                        .font(.custom("VT323-Regular", size: 20))
                        .foregroundStyle(.white.opacity(0.2))
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

private struct ToggleSwitch: View {
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

private struct SettingsButtonStyle: ButtonStyle {
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

private struct StreamQualityPickerSheet: View {
    let selected: StreamQuality
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
                        ForEach(StreamQuality.allCases) { quality in
                            let isSel = selected == quality
                            Button {
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

private struct SubtitleLanguagePickerSheet: View {
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

private struct AudioLanguagePickerSheet: View {
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
