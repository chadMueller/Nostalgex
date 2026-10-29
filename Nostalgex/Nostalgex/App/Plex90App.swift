import SwiftUI
import Combine

// MARK: - Root navigation

struct RootView: View {
    @Environment(AppState.self) var appState
    @State private var navigationPath = NavigationPath()

    var body: some View {
        let forceSettings = ProcessInfo.processInfo.arguments.contains("-uiTestForceSettings")
        // Debug-only, same idea as `-uiTestForceSettings`: jumps straight to the new
        // library-selection screen or the full Settings page (SERVERS/LIBRARIES), with
        // canned sections, for a screenshot or a manual check with no server required.
        // The `.task` below sets `pendingLibrarySections` and THEN `needsLibrarySelection`
        //, same order `presentLibrarySelectionOrScan()` uses, so the view never mounts
        // on an empty list and defaults every row to off.
        let forceSettingsPage = ProcessInfo.processInfo.arguments.contains("-uiTestForceSettingsPage")
        let uiTestInstantAuth = ProcessInfo.processInfo.arguments.contains("-uiTestInstantAuth")
            || ProcessInfo.processInfo.arguments.contains("-reproAppReviewFlow")
        let reproAppReviewFlow = ProcessInfo.processInfo.arguments.contains("-reproAppReviewFlow")
        NavigationStack(path: $navigationPath) {
            Group {
                if reproAppReviewFlow {
                    TunerView(navigationPath: $navigationPath)
                } else if appState.needsServerSelection {
                    ServerPickerView()
                } else if appState.needsLibrarySelection {
                    LibrarySelectionView()
                } else if forceSettingsPage {
                    SettingsPageView()
                } else if forceSettings {
                    SettingsView()
                } else if !appState.didAttemptCredentialHydration {
                    // Keychain not read yet. Showing SettingsView here put the connect
                    // screen in front of users who were already signed in.
                    LoadingView()
                } else if !appState.hasCredentials {
                    SettingsView()
                } else if appState.isLoading {
                    LoadingView()
                } else if appState.channels.isEmpty {
                    EmptyChannelsView(navigationPath: $navigationPath)
                } else {
                    TunerView(navigationPath: $navigationPath)
                }
            }
            .navigationDestination(for: AppDestination.self) { destination in
                switch destination {
                case .settings:
                    SettingsPageView()
                }
            }
        }
        .fullScreenCover(isPresented: Bindable(appState).isFullScreen) {
            PlayerView()
                .environment(appState)
        }
        .onChange(of: appState.playbackState) { _, newState in
            // Disable tvOS screensaver/idle timer during active playback.
            // Without this, the Apple TV screensaver fires even while video is running.
            UIApplication.shared.isIdleTimerDisabled = (newState == .playing)
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("-uiTestForceLibrarySelection") {
                appState.didAttemptCredentialHydration = true
                appState.pendingLibrarySections = [
                    LibrarySectionRef(serverID: "demo", serverName: "Demo Server", sectionKey: "1", title: "Movies", type: "movie"),
                    LibrarySectionRef(serverID: "demo", serverName: "Demo Server", sectionKey: "2", title: "TV Shows", type: "show"),
                    LibrarySectionRef(serverID: "demo", serverName: "Demo Server", sectionKey: "3", title: "Home Videos", type: "movie"),
                ]
                // Set only after the list above, matching `presentLibrarySelectionOrScan()`'s
                // order: the view must never mount before it has rows to default to on.
                appState.needsLibrarySelection = true
                return
            }
            if forceSettingsPage {
                appState.didAttemptCredentialHydration = true
                appState.availableLibrarySections = [
                    LibrarySectionRef(serverID: "demo", serverName: "Demo Server", sectionKey: "1", title: "Movies", type: "movie"),
                    LibrarySectionRef(serverID: "demo", serverName: "Demo Server", sectionKey: "2", title: "TV Shows", type: "show"),
                ]
                return
            }
            if forceSettings { appState.didAttemptCredentialHydration = true; return }
            if reproAppReviewFlow { appState.didAttemptCredentialHydration = true; return }
            emitLaunchAnalyticsIfNeeded()
            if uiTestInstantAuth {
                appState.didAttemptCredentialHydration = true
                appState.startPINAuth()
                return
            }
            InstallDiagnostics.recordLaunch()
            await appState.hydrateCredentialsWithRetry()
            if appState.hasCredentials && appState.channels.isEmpty {
                let restored = await appState.restoreLibraryFromSnapshotIfNeeded()
                if !restored {
                    await appState.loadLibrary()
                }
                if PlaybackSoak.isRequested {
                    // A background refresh rebuilding 90 channels on the main actor would
                    // starve the player and the soak's own clock; measure playback alone.
                    await PlaybackSoak.run(appState: appState)
                    return
                }
                if restored, appState.isLibraryStale {
                    Task { await appState.refreshLibraryIfChanged() }
                }
                appState.startDailyRefresh()
            }
        }
    }

    /// UserDefaults key that flips from missing → `true` on the first launch of an
    /// install, so subsequent launches can be reported as `.returning`. Persists for
    /// the lifetime of the app container: deleting the app resets it, which is the
    /// correct behaviour (install → connect success is what needs to be joined).
    private static let firstLaunchRecordedKey = "nostalgex_first_launch_recorded"

    /// Fires exactly one `app.launch` per app process, distinguishing the first launch
    /// on this install from every subsequent launch. Runs once per RootView appearance
    /// via a static flag so a hot-restart of the `.task` (SwiftUI reruns tasks when
    /// the view id changes) does not send duplicates.
    private static var launchReported = false
    private func emitLaunchAnalyticsIfNeeded() {
        guard !Self.launchReported else { return }
        Self.launchReported = true
        let defaults = UserDefaults.standard
        let kind: AnalyticsLaunchKind = defaults.bool(forKey: Self.firstLaunchRecordedKey)
            ? .returning
            : .first
        if kind == .first {
            defaults.set(true, forKey: Self.firstLaunchRecordedKey)
        }
        Analytics.track(.launch(kind: kind))
    }
}

enum AppDestination: Hashable {
    case settings
}

// MARK: - Loading screen

struct LoadingView: View {
    @Environment(AppState.self) var appState
    @State private var dots = ""
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    /// LoadingView is only ever presented for a foreground load — background refreshes keep
    /// the guide on screen — so every load that reaches here is doing real work and gets the
    /// step rail. The old compact "your lineup is already loaded for today" mode is gone: the
    /// one case still reaching it was a manual rescan, which clears the snapshot and re-crawls
    /// the whole server, so the reassurance it showed was the opposite of what was happening.
    private var mode: LoadingScreenMode {
        LoadingScreenMode.decide(
            didAttemptCredentialHydration: appState.didAttemptCredentialHydration,
            isFirstLibraryLoad: appState.isFirstLibraryLoad,
            loadingMessage: appState.loadingMessage,
            scanTotalSections: appState.scanTotalSections,
            channelBuildTotal: appState.channelBuildTotal
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if mode.showsStepRail {
                fullLoadBody
            } else {
                splashBody
            }
        }
    }

    /// Shown when there is nothing to report. The logo and a heartbeat, no rail, no
    /// headline, no empty progress — a short wait should look deliberate.
    private var splashBody: some View {
        VStack(spacing: 26) {
            Image("NostalgexLogo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 460)

            Text(String(repeating: "\u{25A0}", count: 3))
                .font(.custom("DMMono-Medium", size: 14))
                .tracking(10)
                .foregroundStyle(Color("BrandCyan").opacity(0.25 + 0.25 * Double(dots.count)))
                .onReceive(timer) { _ in
                    dots = dots.count >= 3 ? "" : dots + "."
                }
                .accessibilityHidden(true)
        }
    }

    private var fullLoadBody: some View {
        VStack(spacing: 28) {
            Image("NostalgexLogo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 500)
                .padding(.bottom, 20)

            if mode.showsFirstRunWarning {
                    Text("First setup can take a few minutes to scan and build channels.")
                        .font(.custom("DMMono-Regular", size: 22))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: 1100)
                        .padding(.horizontal, 40)
                }

                LibraryLoadStepRail(
                    visibleSteps: appState.libraryLoadVisibleSteps,
                    currentPhase: appState.libraryLoadPhase
                )
                .padding(.horizontal, 48)

                Text(appState.loadingMessage + dots)
                    .font(.custom("DMMono-Medium", size: 32))
                    .foregroundStyle(Color("BrandCyan"))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 800)
                    .onReceive(timer) { _ in
                        dots = dots.count >= 3 ? "" : dots + "."
                    }

                if !phaseDetailLine.isEmpty {
                    Text(phaseDetailLine)
                        .font(.custom("DMMono-Regular", size: 22))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 720)
                }

            phaseProgressBlock

            if appState.isLoadStalling {
                stallBlock
            }
        }
        .padding(.vertical, 40)
    }

    /// Shown once the scan has gone quiet for a while. The watchdog will resolve this on
    /// its own, but that wait is long by design (a real scan can be quiet for minutes), and
    /// sitting in front of a frozen screen with no option is the thing being fixed here.
    private var stallBlock: some View {
        VStack(spacing: 14) {
            Text("Still waiting on your server. Nothing has come back for a while.")
                .font(.custom("DMMono-Regular", size: 20))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760)

            Button("STOP WAITING") {
                appState.stopWaitingForLibraryScan()
            }
            .buttonStyle(OnboardingButtonStyle(role: .primary, fullWidth: false, fontSize: 24))

            Text("Keeps whatever has loaded so far and finishes the rest later.")
                .font(.custom("DMMono-Regular", size: 17))
                .foregroundStyle(.white.opacity(0.3))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760)
        }
        .padding(.top, 12)
    }

    private var phaseDetailLine: String {
        // Channel name is the cyan headline; progress lives under the bar.
        if appState.libraryLoadPhase == .buildingChannels, appState.channelBuildTotal > 0 {
            return ""
        }
        if appState.isScanning, !appState.scanningMessage.isEmpty {
            return appState.scanningMessage.uppercased()
        }
        // The metadata phase spends its first stretch reading the Supabase cache in
        // sequential chunks and its last stretch writing back — minutes of work on a large
        // library that the item counter can't describe. Its own status line can.
        if appState.libraryLoadPhase == .enrichingMetadata,
           !appState.enrichmentService.statusMessage.isEmpty {
            return appState.enrichmentService.statusMessage.uppercased()
        }
        if !appState.libraryLoadDetail.isEmpty {
            return appState.libraryLoadDetail.uppercased()
        }
        return appState.libraryLoadPhase.phaseHint.uppercased()
    }

    @ViewBuilder
    private var phaseProgressBlock: some View {
        switch appState.libraryLoadPhase {
        case .scanningLibrary where appState.scanTotalSections > 0:
            linearProgress(
                value: Double(appState.scanSectionIndex + 1) / Double(max(appState.scanTotalSections, 1)),
                caption: "Section \(appState.scanSectionIndex + 1) of \(appState.scanTotalSections) · \(appState.scanItemsFound) items"
            )
        case .discoveringCollections where appState.collectionScanTotal > 0:
            linearProgress(
                value: Double(appState.collectionScanIndex) / Double(max(appState.collectionScanTotal, 1)),
                caption: "Collection \(appState.collectionScanIndex) of \(appState.collectionScanTotal)"
            )
        case .enrichingMetadata where appState.enrichmentService.isEnriching:
            // Until the cache check finishes we don't know how many titles need fetching;
            // a 0/1 bar would read as a stall, so show motion instead of a false zero.
            if appState.enrichmentService.totalToEnrich > 0 {
                linearProgress(
                    value: appState.enrichmentService.progress,
                    caption: "Metadata \(appState.enrichmentService.enrichedCount)/\(appState.enrichmentService.totalToEnrich)"
                )
            } else {
                indeterminateProgress()
            }
        case .enrichingMusic where appState.musicEnrichmentService.isEnriching:
            linearProgress(
                value: appState.musicEnrichmentService.progress,
                caption: "Music \(appState.musicEnrichmentService.enrichedCount)/\(max(appState.musicEnrichmentService.totalToEnrich, 1))"
            )
        case .buildingChannels where appState.channelBuildTotal > 0:
            linearProgress(
                value: Double(appState.channelBuildIndex) / Double(max(appState.channelBuildTotal, 1)),
                caption: "Channel \(appState.channelBuildIndex) of \(appState.channelBuildTotal)"
            )
        default:
            EmptyView()
        }
    }

    private func indeterminateProgress() -> some View {
        ProgressView()
            .progressViewStyle(.linear)
            .tint(Color("BrandCyan"))
            .frame(maxWidth: 420)
    }

    private func linearProgress(value: Double, caption: String) -> some View {
        VStack(spacing: 10) {
            ProgressView(value: min(max(value, 0), 1))
                .progressViewStyle(.linear)
                .tint(Color("BrandCyan"))
                .frame(maxWidth: 420)
            Text(caption.uppercased())
                .font(.custom("DMMono-Regular", size: 19))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}

// MARK: - Load phase step rail

private struct LibraryLoadStepRail: View {
    let visibleSteps: [LibraryLoadPhase]
    let currentPhase: LibraryLoadPhase

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(visibleSteps.enumerated()), id: \.offset) { index, step in
                stepCell(step: step, index: index)
                if index < visibleSteps.count - 1 {
                    connector(after: step)
                }
            }
        }
        .frame(maxWidth: 900)
    }

    @ViewBuilder
    private func stepCell(step: LibraryLoadPhase, index: Int) -> some View {
        let state = stepState(for: step)
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .strokeBorder(circleColor(state: state), lineWidth: 2)
                    .frame(width: 28, height: 28)
                if state == .complete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color("BrandCyan"))
                } else if state == .active {
                    Circle()
                        .fill(Color("BrandCyan"))
                        .frame(width: 10, height: 10)
                }
            }
            Text(step.title.uppercased())
                .font(.custom("DMMono-Regular", size: 16))
                .foregroundStyle(labelColor(state: state))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private func connector(after step: LibraryLoadPhase) -> some View {
        let done = stepState(for: step) == .complete
        return Rectangle()
            .fill(done ? Color("BrandCyan").opacity(0.5) : Color.white.opacity(0.15))
            .frame(height: 2)
            .frame(maxWidth: 36)
            .padding(.bottom, 22)
    }

    private enum StepState { case upcoming, active, complete }

    private func stepState(for step: LibraryLoadPhase) -> StepState {
        guard let currentIdx = currentPhase.index(in: visibleSteps),
              let stepIdx = step.index(in: visibleSteps) else {
            return step < currentPhase ? .complete : .upcoming
        }
        if stepIdx < currentIdx { return .complete }
        if stepIdx == currentIdx { return .active }
        return .upcoming
    }

    private func circleColor(state: StepState) -> Color {
        switch state {
        case .complete, .active: return Color("BrandCyan")
        case .upcoming: return Color.white.opacity(0.25)
        }
    }

    private func labelColor(state: StepState) -> Color {
        switch state {
        case .active: return Color("BrandCyan")
        case .complete: return .white.opacity(0.55)
        case .upcoming: return .white.opacity(0.3)
        }
    }
}

// MARK: - Server picker (multiple Plex servers reachable)

struct ServerPickerView: View {
    @Environment(AppState.self) var appState
    @State private var selectedIDs: Set<String> = []
    @FocusState private var focusedID: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            HStack(alignment: .center, spacing: 80) {
                // Left: branding + explanation
                VStack(alignment: .leading, spacing: 28) {
                    Image("NostalgexLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 440)

                    Text("CHOOSE YOUR LIBRARIES")
                        .font(.custom("DMMono-Medium", size: 40))
                        .foregroundStyle(.white.opacity(0.9))

                    Text("Your account can reach more than one Plex server. Pick which libraries Nostalgex should build channels from. You can change this later in Settings.")
                        .font(.custom("DMMono-Regular", size: 22))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.leading)
                        .lineSpacing(4)
                        // Without this the copy clips to two lines and ellipsises.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right: server list + continue
                VStack(alignment: .leading, spacing: 24) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 12) {
                            ForEach(appState.availableServers) { server in
                                serverRow(server)
                            }
                        }
                    }
                    .frame(maxHeight: 560)

                    Button("CONTINUE") {
                        let chosen = appState.availableServers.filter { selectedIDs.contains($0.machineIdentifier) }
                        appState.confirmServerSelection(chosen)
                    }
                    .buttonStyle(OnboardingButtonStyle(role: .primary))
                    .disabled(selectedIDs.isEmpty)
                    .focused($focusedID, equals: "continue")
                    .accessibilityIdentifier("serverPickerContinue")
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 100)
            .padding(.vertical, 60)
        }
        .defaultFocus($focusedID, "continue")
        .onAppear {
            // Default selection: owned servers, or all if none are owned.
            let owned = appState.availableServers.filter(\.owned)
            let defaults = owned.isEmpty ? appState.availableServers : owned
            selectedIDs = Set(defaults.map(\.machineIdentifier))
            // The usual choice is already ticked, so the remote starts on CONTINUE: one
            // press to go on, instead of walking down past every server first.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                focusedID = "continue"
            }
        }
    }

    @ViewBuilder
    private func serverRow(_ server: AppState.ServerRef) -> some View {
        let isOn = selectedIDs.contains(server.machineIdentifier)
        let isFocused = focusedID == server.machineIdentifier
        Button {
            if isOn { selectedIDs.remove(server.machineIdentifier) }
            else { selectedIDs.insert(server.machineIdentifier) }
        } label: {
            // Same focus language as the connect screens: the focused row is a solid cyan
            // slab with dark text that grows and glows; the rest are dim outlines.
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(server.name)
                        .font(.custom("DMMono-Medium", size: 28))
                        .foregroundStyle(isFocused ? OnboardingPalette.onFocus : (isOn ? .white : .white.opacity(0.55)))
                    Text(server.owned ? "Your server" : "Shared with you")
                        .font(.custom("DMMono-Regular", size: 18))
                        .foregroundStyle(isFocused ? OnboardingPalette.onFocus.opacity(0.75) : .white.opacity(0.4))
                }
                Spacer()
                Text(isOn ? "INCLUDED" : "OFF")
                    .font(.custom("DMMono-Medium", size: 22))
                    .foregroundStyle(isFocused ? OnboardingPalette.onFocus : (isOn ? OnboardingPalette.cyan : .white.opacity(0.35)))
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(
                isFocused ? OnboardingPalette.cyan : .white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
                isFocused ? .clear : .white.opacity(0.18), lineWidth: 1.5))
            .shadow(color: OnboardingPalette.cyan.opacity(isFocused ? 0.6 : 0), radius: 28)
            .scaleEffect(isFocused ? 1.04 : 1.0)
            .animation(.easeOut(duration: 0.14), value: isFocused)
        }
        .buttonStyle(PickerRowButtonStyle())
        .focused($focusedID, equals: server.machineIdentifier)
    }
}

/// tvOS button style that suppresses the default white focus halo so we can draw our
/// own cyan-bordered focus state (matching the rest of the app).
private struct PickerRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Library selection (I-054): more than one library section to choose from

/// Shown once per sign-in, right after server selection (or right after connect for
/// Jellyfin/Emby, which never show `ServerPickerView`) and before the first scan. Same
/// two-column layout as `ServerPickerView` on purpose, same screen family, one step
/// later in the same flow. Default is every section ON: this is opting a library OUT,
/// not opting one in, so leaving without touching anything still builds a full guide.
struct LibrarySelectionView: View {
    @Environment(AppState.self) var appState
    @State private var includedIDs: Set<String> = []
    @FocusState private var focusedID: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            HStack(alignment: .center, spacing: 80) {
                // Left: branding + explanation
                VStack(alignment: .leading, spacing: 28) {
                    Image("NostalgexLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 440)

                    Text("CHOOSE YOUR LIBRARIES")
                        .font(.custom("DMMono-Medium", size: 40))
                        .foregroundStyle(.white.opacity(0.9))

                    Text("Pick which of your \(appState.backendDisplayName) libraries Nostalgex should build channels from. A library you leave off is never scanned. You can change this later in Settings.")
                        .font(.custom("DMMono-Regular", size: 22))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.leading)
                        .lineSpacing(4)
                        // Without this the copy clips to two lines and ellipsises.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right: section list + continue
                VStack(alignment: .leading, spacing: 24) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 12) {
                            ForEach(appState.pendingLibrarySections) { section in
                                sectionRow(section)
                            }
                        }
                    }
                    .frame(maxHeight: 560)

                    Button("CONTINUE") {
                        appState.confirmLibrarySelection(includedIDs: includedIDs)
                    }
                    .buttonStyle(OnboardingButtonStyle(role: .primary))
                    .disabled(includedIDs.isEmpty)
                    .focused($focusedID, equals: "continue")
                    .accessibilityIdentifier("librarySelectionContinue")
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 100)
            .padding(.vertical, 60)
        }
        .defaultFocus($focusedID, "continue")
        .onAppear {
            // Default: every section on, so the remote starts on CONTINUE, one press
            // builds a full guide without having to touch a single row.
            includedIDs = Set(appState.pendingLibrarySections.map(\.id))
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                focusedID = "continue"
            }
        }
    }

    @ViewBuilder
    private func sectionRow(_ section: LibrarySectionRef) -> some View {
        let isOn = includedIDs.contains(section.id)
        let isFocused = focusedID == section.id
        // Only worth naming the server when more than one is in play (Plex multi-server);
        // Jellyfin/Emby and single-server Plex just show the library's own kind.
        let multiServer = Set(appState.pendingLibrarySections.map(\.serverID)).count > 1
        Button {
            if isOn { includedIDs.remove(section.id) }
            else { includedIDs.insert(section.id) }
        } label: {
            // Same focus language as the connect screens and the server picker.
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title)
                        .font(.custom("DMMono-Medium", size: 28))
                        .foregroundStyle(isFocused ? OnboardingPalette.onFocus : (isOn ? .white : .white.opacity(0.55)))
                    Text(multiServer ? "\(section.serverName) · \(section.typeLabel)" : section.typeLabel)
                        .font(.custom("DMMono-Regular", size: 18))
                        .foregroundStyle(isFocused ? OnboardingPalette.onFocus.opacity(0.75) : .white.opacity(0.4))
                }
                Spacer()
                Text(isOn ? "INCLUDED" : "OFF")
                    .font(.custom("DMMono-Medium", size: 22))
                    .foregroundStyle(isFocused ? OnboardingPalette.onFocus : (isOn ? OnboardingPalette.cyan : .white.opacity(0.35)))
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(
                isFocused ? OnboardingPalette.cyan : .white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
                isFocused ? .clear : .white.opacity(0.18), lineWidth: 1.5))
            .shadow(color: OnboardingPalette.cyan.opacity(isFocused ? 0.6 : 0), radius: 28)
            .scaleEffect(isFocused ? 1.04 : 1.0)
            .animation(.easeOut(duration: 0.14), value: isFocused)
        }
        .buttonStyle(PickerRowButtonStyle())
        .focused($focusedID, equals: section.id)
        .accessibilityIdentifier("librarySection_\(section.id)")
    }
}

// MARK: - Empty channels screen

struct EmptyChannelsView: View {
    @Environment(AppState.self) var appState
    @Binding var navigationPath: NavigationPath

    private var hasError: Bool {
        appState.errorMessage != nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 32) {
                Image("NostalgexLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 540)

                if hasError {
                    // Library load failed — channels are empty because of the failure, not "not enough content"
                    Text("CONNECTION FAILED")
                        .font(.custom("DMMono-Medium", size: 28))
                        .foregroundStyle(.red.opacity(0.8))

                    if let error = appState.errorMessage {
                        Text(error)
                            .font(.custom("DMMono-Regular", size: 18))
                            .foregroundStyle(.white.opacity(0.5))
                            .multilineTextAlignment(.center)
                    }

                    // Tiny diagnostic line — visible in App Store rejection screenshots so we
                    // can debug what actually failed (server URL + HTTP code) instead of
                    // guessing from the user-facing message above.
                    if let diag = appState.lastFailureDiagnostic {
                        Text(diag)
                            .font(.custom("DMMono-Regular", size: 12))
                            .foregroundStyle(.white.opacity(0.25))
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }

                    HStack(spacing: 16) {
                        Button("RETRY") {
                            Task {
                                appState.errorMessage = nil
                                await appState.loadLibrary()
                            }
                        }
                        .buttonStyle(OnboardingButtonStyle(role: .primary, fullWidth: false, fontSize: 24))

                        Button("SETTINGS") {
                            navigationPath.append(AppDestination.settings)
                        }
                        .buttonStyle(OnboardingButtonStyle(role: .secondary, fullWidth: false, fontSize: 24))
                    }
                } else {
                    // Library loaded fine but no channels meet minItems — true "not enough content"
                    Text("NO CHANNELS FOUND")
                        .font(.custom("DMMono-Medium", size: 28))
                        .foregroundStyle(.white.opacity(0.6))

                    Text("Your library didn't have enough content to fill any channels.\nOpen Settings to see which packages your library supports.")
                        .font(.custom("DMMono-Regular", size: 18))
                        .foregroundStyle(.white.opacity(0.3))
                        .multilineTextAlignment(.center)

                    Button("OPEN SETTINGS") {
                        navigationPath.append(AppDestination.settings)
                    }
                    .buttonStyle(OnboardingButtonStyle(role: .primary, fullWidth: false, fontSize: 24))
                }
            }
        }
    }
}
