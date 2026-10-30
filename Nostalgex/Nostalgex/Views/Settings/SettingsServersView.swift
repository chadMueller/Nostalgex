import SwiftUI

/// SERVERS & ACCOUNTS: which servers and libraries feed the guide, rescans, iCloud
/// sync between Apple TVs, and disconnect. DISCONNECT is still one press, as before.
struct SettingsServersView: View {
    @Environment(AppState.self) var appState
    let focus: FocusState<SettingsFocus?>.Binding

    static func firstRowID(appState: AppState) -> String {
        if let server = appState.serversForSettings.first {
            return "server_\(server.machineIdentifier)"
        }
        if let section = appState.librarySectionsForSettings.first {
            return "section_\(section.id)"
        }
        return "rescan"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSubheader(text: "SERVERS")

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
                    isFocused: isFocused("server_\(server.machineIdentifier)"),
                    // No toggle when it's the only server, it can't be removed.
                    showToggle: !isLast
                ) {
                    guard !isLast, !appState.isLoading, !appState.isBackgroundRefreshing else { return }
                    appState.toggleServer(server)
                }
                .settingsRow("server_\(server.machineIdentifier)", focus: focus)
            }

            SettingsSubheader(text: "LIBRARIES")

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
                    isFocused: isFocused("section_\(section.id)"),
                    // No toggle when it's the only section left on, it can't be removed.
                    showToggle: !isLast
                ) {
                    guard !isLast, !appState.isLoading, !appState.isBackgroundRefreshing else { return }
                    appState.toggleLibrarySection(section)
                }
                .settingsRow("section_\(section.id)", focus: focus)
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
                isFocused: isFocused("rescan"),
                isLoading: appState.isLoading || appState.isBackgroundRefreshing,
                loadingMessage: appState.isBackgroundRefreshing ? "Updating…" : (appState.isLoading ? "Scanning…" : nil),
                showToggle: false
            ) {
                guard !appState.isLoading, !appState.isBackgroundRefreshing else { return }
                Task { await appState.rescanLibrary() }
            }
            .settingsRow("rescan", focus: focus)
            .accessibilityLabel("Rescan library")
            .padding(.top, 8)

            // Off by default and per-TV. Turning it on pushes this TV's lineup and
            // settings to iCloud first, then listens.
            SettingsToggleRow(
                title: "SYNC WITH MY OTHER APPLE TVS",
                subtitle: appState.iCloudSyncEnabled
                    ? "This Apple TV's lineup is shared through iCloud."
                    : "Turn on to share your lineup and settings with your other Apple TVs through iCloud.",
                isOn: appState.iCloudSyncEnabled,
                isFocused: isFocused("icloud_sync")
            ) {
                appState.iCloudSyncEnabled.toggle()
            }
            .settingsRow("icloud_sync", focus: focus)

            SettingsToggleRow(
                title: "DISCONNECT FROM \(appState.backendDisplayName.uppercased())",
                subtitle: "Clears saved \(appState.backendDisplayName) access. Use when switching servers",
                isOn: true,
                isFocused: isFocused("disconnect"),
                showToggle: false
            ) {
                appState.disconnect()
            }
            .settingsRow("disconnect", focus: focus)
            .accessibilityLabel("Disconnect from \(appState.backendDisplayName)")

            // Only while enrichment runs. Its own view, so progress updates don't
            // redraw the rows above.
            EnrichmentStatusView(enrichmentService: appState.enrichmentService)
        }
    }

    private func isFocused(_ id: String) -> Bool {
        focus.wrappedValue == .row(id)
    }
}
