import Foundation
import Observation
import SwiftUI
import AVFoundation
import Combine
import UIKit
import os

// Authentication, credential persistence, server session lifecycle and 401 handling.
// Split out of AppState.swift; behavior unchanged.
extension AppState {
    // MARK: - Credentials (Keychain)

    /// Loads credentials from Keychain only when we don't already have them in memory.
    /// This avoids clobbering a just-acquired token/serverURL during the PIN auth flow.
    func hydrateCredentialsIfNeeded() {
        if ProcessInfo.processInfo.arguments.contains("-uiTestResetCredentials")
            || ProcessInfo.processInfo.arguments.contains("-reproAppReviewFlow") {
            return
        }
        // Restore the last-load timestamp from UserDefaults so the "loaded < 24h
        // ago" gate works even before any snapshot restore attempt.
        if lastLoadAtUnix == 0 {
            let saved = UserDefaults.standard.integer(forKey: Self.lastLoadKey)
            if saved > 0 { lastLoadAtUnix = saved }
        }
        guard !hasCredentials else { return }
        loadCredentials()
    }

    func loadCredentials() {
        // Migrate from UserDefaults to Keychain (one-time)
        if let legacyURL = UserDefaults.standard.string(forKey: "plex_server_url"), !legacyURL.isEmpty {
            credentialStore.save(key: "plex_server_url", value: Self.normalizePlexServerURL(legacyURL))
            UserDefaults.standard.removeObject(forKey: "plex_server_url")
        }
        if let legacyToken = UserDefaults.standard.string(forKey: "plex_token"), !legacyToken.isEmpty {
            credentialStore.save(key: "plex_token", value: legacyToken)
            UserDefaults.standard.removeObject(forKey: "plex_token")
        }

        serverURL = Self.normalizePlexServerURL(credentialStore.load(key: "plex_server_url") ?? "")
        token = credentialStore.load(key: "plex_token") ?? ""

        // Backend selection (defaults to Plex for existing installs).
        backendKind = credentialStore.load(key: Self.backendKindKey)
            .flatMap(MediaBackendKind.init(rawValue:)) ?? .plex
        jellyfinUserId = credentialStore.load(key: Self.jellyfinUserIdKey) ?? ""

        // One-time migration: re-save credentials under AfterFirstUnlock (was ThisDeviceOnly,
        // which doesn't survive device restores or tvOS updates). Harmless if already migrated.
        let keychainMigrationKey = "plex90_keychain_v2_migrated"
        if !token.isEmpty && !UserDefaults.standard.bool(forKey: keychainMigrationKey) {
            credentialStore.save(key: "plex_token", value: token)
            if !serverURL.isEmpty { credentialStore.save(key: "plex_server_url", value: serverURL) }
            UserDefaults.standard.set(true, forKey: keychainMigrationKey)
        }

        // Load the multi-server selection. Migrate a legacy single server into the list.
        if let json = credentialStore.load(key: Self.serversKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ServerRef].self, from: data),
           !decoded.isEmpty {
            let cleaned = Self.dedupingServers(decoded)
            selectedServers = cleaned
            if cleaned.count != decoded.count {
                print("[Plex90] AUTH: server list had \(decoded.count - cleaned.count) duplicate entr\(decoded.count - cleaned.count == 1 ? "y" : "ies") for the same server, removed")
                persistSelectedServers()
            }
        } else if !serverURL.isEmpty {
            selectedServers = [ServerRef(
                machineIdentifier: serverURL,
                name: serverName.isEmpty ? "Plex Server" : serverName,
                baseURL: serverURL,
                owned: true,
                token: token
            )]
            persistSelectedServers()
        }
        syncPrimaryServerFields()
    }

    /// Pure so the marker/status matrix is unit-testable without a keychain.
    static func signInLossDiagnosis(markerPresent: Bool, statuses: [String: Int]) -> String? {
        guard markerPresent else { return nil }
        let token = statuses["plex_token"].map(String.init) ?? "?"
        return "THIS DEVICE LOST YOUR SAVED SIGN-IN (CODE \(token)). PLEASE REPORT THAT CODE."
    }

    /// Launch-time hydration with a short retry for transient keychain refusals, and a
    /// diagnosis when the sign-in is genuinely gone.
    func hydrateCredentialsWithRetry() async {
        defer { didAttemptCredentialHydration = true }
        for attempt in 0 ..< 3 {
            hydrateCredentialsIfNeeded()
            if hasCredentials {
                // Sign-ins that predate the marker never got one at sign-in time, so a
                // later loss on those devices was silent. Any successful launch load is
                // proof this device held a sign-in.
                UserDefaults.standard.set(true, forKey: Self.hasHeldSignInMarkerKey)
                return
            }
            let statuses = KeychainService.lastLoadStatuses()
            let transient = statuses.values.contains { KeychainService.isTransientLoadStatus($0) }
            guard transient, attempt < 2 else { break }
            print("[Plex90] AUTH: keychain not ready \(statuses), retrying load \(attempt + 1)")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if !hasCredentials {
            signInLossDiagnostic = Self.signInLossDiagnosis(
                markerPresent: UserDefaults.standard.bool(forKey: Self.hasHeldSignInMarkerKey),
                statuses: KeychainService.lastLoadStatuses()
            )
            if let diagnostic = signInLossDiagnostic {
                print("[Plex90] AUTH: \(diagnostic)")
                // Fire once per launch — hydrateCredentialsWithRetry is a launch path.
                // Report the primary token's OSStatus (short digits, not PII).
                let keychainStatus = KeychainService.lastLoadStatuses()["plex_token"].map(String.init) ?? "?"
                Analytics.track(.credentialsSignInLost(code: keychainStatus))
            }
        }
    }

    func saveCredentials() {
        serverURL = Self.normalizePlexServerURL(serverURL)
        // Every write is verified by reading it back, so a false here means this sign-in will
        // not survive relaunch. Recorded rather than ignored: silently losing the session is
        // the single most trust-damaging failure this app has, and the user deserves to know
        // it happened rather than blaming themselves for "getting logged out again".
        var allPersisted = true
        allPersisted = credentialStore.save(key: "plex_server_url", value: serverURL) && allPersisted
        allPersisted = credentialStore.save(key: "plex_token", value: token) && allPersisted
        allPersisted = credentialStore.save(key: Self.backendKindKey, value: backendKind.rawValue) && allPersisted
        allPersisted = credentialStore.save(key: Self.jellyfinUserIdKey, value: jellyfinUserId) && allPersisted
        credentialsArePersistent = allPersisted
        InstallDiagnostics.log.notice("save: persisted=\(allPersisted) \(InstallDiagnostics.summary(), privacy: .public)")
        signInLossDiagnostic = nil
        lastSignOutNotice = nil
        UserDefaults.standard.removeObject(forKey: Self.lastSignOutNoticeKey)
        UserDefaults.standard.set(true, forKey: Self.hasHeldSignInMarkerKey)
        if !allPersisted {
            print("[Plex90] AUTH: credentials could not be persisted — sign-in will be lost on relaunch")
            Analytics.track(.credentialsPersistFailed)
        }
        persistSelectedServers()
    }

    /// Replaces the selected-server list, keeps the primary display fields in sync, and persists.
    func setSelectedServers(_ servers: [ServerRef]) {
        selectedServers = Self.dedupingServers(servers)
        syncPrimaryServerFields()
        persistSelectedServers()
        // A different server set is a different library; nothing a running scan brings
        // back belongs in it.
        invalidateInFlightLibraryLoads()
    }

    /// One entry per physical server. A pre-multi-server install migrated its single server
    /// as a ServerRef keyed by its URL; discovery later added the same server keyed by its
    /// machine identifier, and toggling in Settings compared identifiers, so both survived.
    /// The library was then scanned once per entry and every pool held every title twice,
    /// which is what aired the same film back to back and trapped on duplicate keys.
    /// Same host and port means the same server; the entry with a real identifier wins.
    static func dedupingServers(_ servers: [ServerRef]) -> [ServerRef] {
        func host(_ url: String) -> String {
            guard let u = URL(string: url), let h = u.host?.lowercased() else { return url.lowercased() }
            return "\(h):\(u.port ?? 32400)"
        }
        func isLegacy(_ s: ServerRef) -> Bool { s.machineIdentifier.lowercased().hasPrefix("http") }
        var out: [ServerRef] = []
        for s in servers {
            if let i = out.firstIndex(where: { $0.machineIdentifier == s.machineIdentifier || host($0.baseURL) == host(s.baseURL) }) {
                if isLegacy(out[i]) && !isLegacy(s) { out[i] = s }
                continue
            }
            out.append(s)
        }
        return out
    }

    private func persistSelectedServers() {
        guard let data = try? JSONEncoder().encode(selectedServers),
              let json = String(data: data, encoding: .utf8) else { return }
        credentialStore.save(key: Self.serversKey, value: json)
    }

    /// Mirrors the primary (first) server into `serverURL`/`serverName` for display
    /// and the single-server fallback paths.
    private func syncPrimaryServerFields() {
        if let primary = selectedServers.first {
            serverURL = primary.baseURL
            serverName = primary.name
        }
    }

    /// Login picker confirmed: lock in the chosen servers and scan.
    func confirmServerSelection(_ servers: [ServerRef]) {
        guard !servers.isEmpty else { return }
        Analytics.track(.connectServerPickerConfirmed(backend: .plex, serverCount: servers.count))
        completePlexSignIn(token: token, servers: servers)
        needsServerSelection = false
        Task { await loadLibrary() }
    }

    /// The one place a Plex sign-in is committed. Selecting servers used to be the only
    /// step, which persisted the server list but never the account token, so every sign-in
    /// made after May 2026 lived only in memory and vanished on relaunch.
    func completePlexSignIn(token authToken: String, servers: [ServerRef]) {
        token = authToken
        backendKind = .plex
        setSelectedServers(servers)
        saveCredentials()
    }

    /// Include/exclude a server from Settings, then rescan. Won't remove the last server.
    func toggleServer(_ server: ServerRef) {
        let wasIncluded = selectedServers.contains(where: { $0.machineIdentifier == server.machineIdentifier })
        if wasIncluded {
            guard selectedServers.count > 1 else { return }
            setSelectedServers(selectedServers.filter { $0.machineIdentifier != server.machineIdentifier })
        } else {
            setSelectedServers(selectedServers + [server])
        }
        // Server identity is deliberately absent — a `true`/`false` toggle is enough
        // to see how often the row is used; the machine identifier is not analytics data.
        Analytics.track(.settingChanged(key: "server", value: wasIncluded ? "false" : "true"))
        LibrarySnapshotStore.clear()
        Task { await loadLibrary() }
    }

    /// Re-query plex.tv for reachable servers so Settings can show servers the user
    /// previously deselected (and pick up newly added ones).
    func refreshAvailableServers() async {
        guard !token.isEmpty else { return }
        if let result = try? await PlexAPIService.discoverServers(token: token) {
            availableServers = result.reachable.map {
                ServerRef(machineIdentifier: $0.machineIdentifier, name: $0.name, baseURL: $0.bestReachableURI, owned: $0.owned, token: $0.token)
            }
        }
    }

    /// Display name for a channel id, whether or not it has enough content to air.
    /// Falls back to the full config so channels dropped for low content still resolve.
    func channelName(for id: Int) -> String? {
        allChannels.first(where: { $0.id == id })?.name
            ?? channelConfigChannels.first(where: { $0.id == id })?.name
    }

    /// Every channel in a bundle (config order), flagged by whether it currently has
    /// enough content to air. Lets Settings show the full lineup and mark missing ones.
    func bundleChannelAvailability(for bundle: ChannelBundle) -> [(name: String, hasContent: Bool)] {
        let availableIDs = Set(allChannels.map(\.id))
        return bundle.channelIDs.compactMap { id in
            guard let name = channelName(for: id) else { return nil }
            return (name, availableIDs.contains(id))
        }
    }

    /// Servers to show in the Settings list: everything discovered, plus any selected
    /// server discovery didn't return this time (so it can still be toggled off).
    var serversForSettings: [ServerRef] {
        var seen = Set<String>()
        var result: [ServerRef] = []
        for server in availableServers + selectedServers {
            if seen.insert(server.machineIdentifier).inserted {
                result.append(server)
            }
        }
        return result
    }

    /// Stable form for Plex base URL (discovery sometimes returns a trailing slash).
    private static func normalizePlexServerURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    func clearCredentials() {
        // A deliberate sign-out (or a proven-dead token) must not read as "the device lost
        // your sign-in" on the next launch.
        UserDefaults.standard.removeObject(forKey: Self.hasHeldSignInMarkerKey)
        signInLossDiagnostic = nil
        credentialStore.delete(key: "plex_server_url")
        credentialStore.delete(key: "plex_token")
        credentialStore.delete(key: Self.serversKey)
        credentialStore.delete(key: Self.backendKindKey)
        credentialStore.delete(key: Self.jellyfinUserIdKey)
        serverURL = ""
        token = ""
        serverName = ""
        selectedServers = []
        availableServers = []
        backendKind = .plex
        jellyfinUserId = ""
        LibrarySnapshotStore.clear()
        // Any library scan still running was started for the sign-in that just ended. It
        // must not land its items, channels or snapshot in whatever is signed in next.
        invalidateInFlightLibraryLoads()
    }

    /// A Plex token alone is a sign-in: servers are rediscovered from plex.tv whenever the
    /// saved list is missing. Jellyfin and Emby tokens are per-server, so they need the URL.
    var hasCredentials: Bool {
        if isDemoMode { return true }
        guard !token.isEmpty else { return false }
        return backendKind == .plex || !selectedServers.isEmpty || !serverURL.isEmpty
    }

    /// Rebuilds the server list from plex.tv when the saved one is gone. Returns false when
    /// nothing reachable was found; the sign-in is kept either way.
    func recoverPlexServersIfNeeded() async -> Bool {
        guard backendKind == .plex, !token.isEmpty, selectedServers.isEmpty else { return true }
        print("[Plex90] AUTH: saved server list missing, rediscovering from plex.tv")
        do {
            let result = try await PlexAPIService.discoverServers(token: token)
            let servers = result.reachable.map {
                ServerRef(machineIdentifier: $0.machineIdentifier, name: $0.name, baseURL: $0.bestReachableURI, owned: $0.owned, token: $0.token)
            }
            guard !servers.isEmpty else {
                errorMessage = result.totalServers == 0
                    ? "Signed in, but no Plex Media Server was found on your account."
                    : "Signed in, but couldn't reach your Plex server from this network (\(result.totalServers) found, none reachable). Make sure it's running, then Retry."
                return false
            }
            setSelectedServers(servers)
            saveCredentials()
            return true
        } catch {
            errorMessage = "Signed in, but couldn't reach plex.tv to find your servers. Check your connection and Retry."
            return false
        }
    }

    /// Activates a static demo experience: bundled sample channels, no network calls.
    /// Used as an App Store review fallback so reviewers can evaluate the UI even when
    /// they can't (or won't) connect to a real Plex Media Server.
    func enterDemoMode() {
        // Wipe any half-finished auth state
        cancelPINAuth()
        errorMessage = nil
        authError = nil
        lastFailureDiagnostic = nil
        justAuthenticated = false

        isDemoMode = true
        // Every subsequent signal on this device is tagged demo=true so the dashboard
        // can filter demo-mode exploration out of the real usage stats.
        Analytics.setDemoMode(true)
        serverName = "Demo"
        isConnected = true
        isLoading = false

        let demoChannels = DemoData.channels()
        allChannels = demoChannels
        channels = demoChannels
        allItems = demoChannels.flatMap { $0.itemPool }

        if currentChannel == nil, let first = channels.first {
            selectChannel(first)
        }
    }

    // MARK: - Connection

    func testConnection() async {
        errorMessage = nil
        do {
            let name = try await api.testConnection()
            serverName = name
            isConnected = true
            saveCredentials()
        } catch let api as PlexAPIService.APIError {
            isConnected = false
            errorMessage = Self.userFacingPlexAPIServiceError(api, justAuthenticated: justAuthenticated, backend: backendKind)
            lastFailureDiagnostic = diagnosticString(for: api)
        } catch {
            isConnected = false
            errorMessage = "Could not connect. Check URL and token."
        }
    }

    // MARK: - Unauthorized handling

    static let lastSignOutNoticeKey = "nostalgex_last_signout_notice"

    /// A 401 during a library load never costs the user their sign-in. Relay tunnels,
    /// reverse proxies, servers coming out of sleep, and plex.tv hiccups all answer 401 for
    /// a healthy token, and every automatic sign-out this app ever shipped was eventually
    /// traced to one of those. The token stays; the message says what we know, and the
    /// user can Disconnect from Settings if they want a fresh start.
    func resolveUnauthorizedLoadFailure() async {
        let validity: TokenValidity = backendKind == .plex
            ? await PlexAPIService.validateAccountToken(token)
            : .unknown
        print("[Plex90] AUTH: 401 on library load, token \(validity), session kept")
        errorMessage = Self.unauthorizedLoadMessage(tokenValidity: validity, backend: backendKind)
        lastFailureDiagnostic = "\(lastFailureDiagnostic ?? "401") · token \(validity) · session kept"
    }

    static func unauthorizedLoadMessage(tokenValidity: TokenValidity, backend: MediaBackendKind) -> String {
        switch tokenValidity {
        case .valid:
            return "Your Plex account is still signed in, but the server refused the request. It may still be waking up, or a proxy in front of it returned 401. Try again in a moment."
        case .invalid:
            return "Plex reports this sign-in is no longer valid. Your saved sign-in was kept. To start fresh, open Settings, choose Disconnect, then connect again."
        case .unknown:
            return backend == .plex
                ? "Your server refused the request and plex.tv couldn't be reached to confirm your sign-in. Your sign-in has been kept. Try again once the server is awake and online."
                : "Your server refused the request. Your sign-in has been kept. Try again once the server is awake and online; if it keeps happening, open Settings and choose Disconnect, then sign in again."
        }
    }

    /// Maps client errors surfaced during library loads and connection checks.
    ///
    /// `PlexAPIService.APIError` is the shared error type for all three backends, so the
    /// copy has to be told which server the user actually connected to. Without `backend`
    /// an Emby user whose scan 404s is told to check Plex's Remote Access setting, which
    /// sends them looking at the wrong server (reported 2026-10-08 during the #6 triage).
    ///
    /// `justAuthenticated=true` means we're seeing this error on the first library load
    /// after a fresh sign-in. In that case `.unauthorized` is NOT a session expiry —
    /// it almost always means the account lacks library access on the discovered server.
    /// The reworded message keeps reviewers (and users) from being told their session
    /// expired on the very screen they just signed in from.
    static func userFacingPlexAPIServiceError(
        _ error: PlexAPIService.APIError,
        justAuthenticated: Bool = false,
        backend: MediaBackendKind = .plex
    ) -> String {
        let server = backend.displayName
        switch error {
        case .unauthorized:
            if justAuthenticated {
                switch backend {
                case .plex:
                    return "Signed in, but this account can't access libraries on the discovered Plex server. Open Plex (Settings → Users & Sharing) and confirm this user has library access, then try again."
                case .jellyfin, .emby:
                    return "Signed in, but this account can't access any libraries on your \(server) server. Open the \(server) dashboard, find this user, and confirm they have access to at least one library, then try again."
                }
            }
            return "Session expired. Please reconnect in Settings."
        case .invalidResponse:
            return "Invalid reply from \(server). Disconnect and reconnect in Settings."
        case .noReachableServer:
            switch backend {
            case .plex:
                return "Signed in, but no Plex server was reachable. Confirm Plex is running and Remote Access is enabled, then try again."
            case .jellyfin, .emby:
                return "Signed in, but your \(server) server stopped answering. Confirm it is running and reachable at the address you entered, then try again."
            }
        case .httpFailure(let code):
            switch backend {
            case .plex:
                return "Plex (or your network path) returned HTTP \(code). If you use a reverse proxy or custom domain, confirm it proxies /library and /identity without injecting a login page. Then reconnect."
            case .jellyfin, .emby:
                return "\(server) (or your network path) returned HTTP \(code). If you use a reverse proxy or custom domain, confirm it passes the \(server) API through without injecting a login page. Check that the address includes the right port, then reconnect."
            }
        case .receivedMarkupInsteadOfJSON:
            return "This \(server) URL returned a web page instead of the data the app expects. That usually means a proxy, a captive portal, or the wrong hostname or port. Disconnect in Settings, sign in again, or open \(server) using the server's LAN address."
        }
    }

    /// Short, monospaced diagnostic for the failure screen. Server URL + HTTP code or short
    /// reason. Designed to be readable in a rejection screenshot so we can debug remotely.
    func diagnosticString(for error: PlexAPIService.APIError) -> String {
        let host = URL(string: serverURL)?.host ?? (serverURL.isEmpty ? "no server" : serverURL)
        switch error {
        case .unauthorized:                       return "\(host) · 401 unauthorized"
        case .invalidResponse:                    return "\(host) · invalid response"
        case .noReachableServer:                  return "discovery · no candidate reachable"
        case .httpFailure(let code):              return "\(host) · HTTP \(code)"
        case .receivedMarkupInsteadOfJSON(let c): return "\(host) · HTTP \(c) markup"
        }
    }

    static func userFacingLoadLibraryError(_ error: Error, backend: MediaBackendKind = .plex) -> String {
        if let apiErr = error as? PlexAPIService.APIError {
            return userFacingPlexAPIServiceError(apiErr, backend: backend)
        }
        if let stalled = error as? LibraryLoadStalled {
            // Nothing usable came back, so there is no guide to fall back on. Say what
            // happened and what to check, not "failed to load library".
            return stalled.userInitiated
                ? "Stopped waiting. Nothing had come back from your server, so no channels were built. Retry when the connection looks better."
                : "Your server stopped sending data partway through the scan and never resumed. Check that it is awake and reachable on this network, then Retry."
        }
        if error is DecodingError {
            return "Your server returned unexpected data. Update your media server software, or disconnect and reconnect in Settings."
        }
        let urlErr = error as? URLError
            ?? ((error as NSError).underlyingErrors.first as? URLError)
        if let urlErr {
            switch urlErr.code {
            case .timedOut:
                return "Timed out loading your library. Large libraries can need a second attempt, so tap Retry. If it keeps timing out, use Settings to pick a closer server URL."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost:
                return "Can't reach the server address saved on this device. Open Settings and reconnect while on the same network as your server."
            case .notConnectedToInternet:
                return "No internet connection. Check Wi‑Fi, then Retry."
            case .cancelled:
                return "Failed to load library. Check that your server is running and reachable."
            default:
                break
            }
        }
        return "Failed to load library. Check that your server is running and reachable."
    }

    // MARK: - PIN Auth

    func startPINAuth() {
        if isUITestInstantAuth {
            authError = nil
            isAuthInProgress = true
            pinCode = "TEST"
            pinID = 1

            // Simulate an immediate successful auth.
            token = "TEST_TOKEN"
            serverURL = "https://example.com"
            saveCredentials()
            isAuthInProgress = false
            pinCode = ""

            Task { await loadLibrary() }
            return
        }

        pinPollTask?.cancel()
        authError = nil
        isAuthInProgress = true
        pinCode = ""
        currentAuthAttempt = (.plex, .pin)
        Analytics.track(.connectStarted(backend: .plex, method: .pin))
        pinPollTask = Task {
            // An Apple TV that just woke up can have no route yet; that fails instantly
            // rather than timing out, so a single attempt flashed the PIN screen and bounced
            // the user straight to an error. Retry transient failures before giving up.
            var lastError: Error?
            for attempt in 0 ..< Self.pinRequestAttempts {
                do {
                    let (id, code) = try await PlexAPIService.requestPIN()
                    guard !Task.isCancelled else { return }
                    pinID = id
                    pinCode = code
                    startPolling()
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    lastError = error
                    print("[Plex90] AUTH: PIN request attempt \(attempt + 1) failed: \(error)")
                    guard Self.isTransientPINRequestError(error), attempt < Self.pinRequestAttempts - 1 else { break }
                    try? await Task.sleep(for: .seconds(attempt + 1))
                    guard !Task.isCancelled else { return }
                }
            }
            isAuthInProgress = false
            currentAuthAttempt = nil
            Analytics.track(.connectFailed(backend: .plex, reason: "pin_request_failed"))
            authError = Self.pinRequestFailureMessage(lastError)
        }
    }

    static let pinRequestAttempts = 4

    static func isTransientPINRequestError(_ error: Error) -> Bool {
        if let api = error as? PlexAPIService.APIError {
            if case .httpFailure(let code) = api { return (500...599).contains(code) }
            return false
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// "Could not reach" hid every cause behind one line. The one that cost a user days:
    /// tvOS refusing a plain http:// URL outside the private LAN ranges (a Tailscale or
    /// other VPN address), which the app reported exactly like a dead server.
    static func serverUnreachableMessage(_ error: Error, backend: String) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .appTransportSecurityRequiresSecureConnection:
                return "tvOS blocked the plain http:// address (ATS error -1022). Update Nostalgex, or use https:// if you are on an older build."
            case .cannotFindHost, .dnsLookupFailed:
                return "Could not find that host. Check the address."
            case .cannotConnectToHost:
                return "Nothing answered at that address and port. Check the port (Jellyfin and Emby default to 8096)."
            case .timedOut:
                return "The \(backend) server took too long to answer. Check the address, or that the Apple TV can reach it."
            case .notConnectedToInternet, .networkConnectionLost:
                return "No network. Check the Apple TV's connection."
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .secureConnectionFailed:
                return "The server's HTTPS certificate is not trusted by the Apple TV (error \(urlError.code.rawValue))."
            default:
                return "Could not reach the \(backend) server (error \(urlError.code.rawValue)). Check the URL."
            }
        }
        return "Could not reach the \(backend) server. Check the URL."
    }

    static func pinRequestFailureMessage(_ error: Error?) -> String {
        if let api = error as? PlexAPIService.APIError, case .httpFailure(let code) = api {
            if code == 429 {
                return "plex.tv is rate-limiting sign-in requests from this device. Wait a minute, then tap Connect again."
            }
            return "plex.tv returned an error (HTTP \(code)). Try again in a moment."
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "No internet connection. Check the Apple TV's Wi‑Fi or Ethernet, then tap Connect again."
            case .timedOut:
                return "plex.tv took too long to respond. Check your connection, then tap Connect again."
            default:
                return "Could not reach plex.tv (error \(urlError.code.rawValue)). Check your connection, then tap Connect again."
            }
        }
        return "Could not reach plex.tv. Check your connection, then tap Connect again."
    }

    func cancelPINAuth() {
        // Report cancel BEFORE clearing currentAuthAttempt so the signal names the
        // sign-in the user backed out of. `wasInFlight` gate avoids sending a cancel
        // for `startPINAuth()` -> immediate-failure paths that already fired failed.
        let wasInFlight = isAuthInProgress
        if wasInFlight, let attempt = currentAuthAttempt {
            Analytics.track(.connectCancelled(backend: attempt.backend, method: attempt.method))
        }
        currentAuthAttempt = nil
        pinPollTask?.cancel()
        pinPollTask = nil
        isAuthInProgress = false
        pinCode = ""
        pinID = 0
        jellyfinQuickConnectCode = ""
        isDiscoveringServers = false
        authError = nil
    }

    /// Force a fresh library scan: clears the on-disk snapshot and pulls everything from Plex again.
    /// Use when the user wants to pick up library changes without signing out.
    func rescanLibrary() async {
        guard hasCredentials else { return }
        Analytics.track(.settingChanged(key: "rescan", value: "tapped"))
        LibrarySnapshotStore.clear()
        DailyManifestStore.clearAll(credentialFingerprint: scheduleCredentialFingerprint)
        await loadLibrary()
    }

    func disconnect() {
        Analytics.track(.settingChanged(key: "disconnect", value: "tapped"))
        // Fold accumulated watch time into one final playback.stopped before the
        // tracker is torn down. Otherwise every disconnect drops the last session's
        // seconds on the floor.
        emitPlaybackStoppedForActiveSession()
        currentPlaybackDelivery = nil
        playbackReadyReported = false
        let outgoing = playbackTracker
        playbackTracker = nil
        outgoing?.stop()
        cancelPINAuth()
        stopActiveTranscodeIfNeeded()
        player?.pause()
        player = nil
        currentChannel = nil
        currentItem = nil
        playbackState = .idle
        isFullScreen = false
        channels = []
        allChannels = []
        allItems = []
        // Collection rows hold resolved items from the old server; a later materialise
        // would put them straight back into the guide.
        collectionScanTask?.cancel()
        collectionScanTask = nil
        discoveredCollections = []
        isLibraryStale = false
        // Today's schedules for the outgoing sign-in go with it. Computed before
        // clearCredentials resets the backend, or this would name the wrong directory.
        DailyManifestStore.clearAll(credentialFingerprint: scheduleCredentialFingerprint)
        clearCredentials()
        serverName = ""
        isConnected = false
        justAuthenticated = false
        lastFailureDiagnostic = nil
        isDemoMode = false
        // Real backend from here on out; keep the analytics context in sync.
        Analytics.setDemoMode(false)
    }

    private func startPolling() {
        let id = pinID
        var attempts = 0
        pinPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                attempts += 1
                if attempts > 150 {
                    Analytics.track(.connectCodeExpired(backend: .plex, method: .pin))
                    authError = "Code expired. Tap Connect to try again."
                    isAuthInProgress = false
                    currentAuthAttempt = nil
                    break
                }
                do {
                    if let authToken = try await PlexAPIService.checkPIN(id: id) {
                        isDiscoveringServers = true
                        do {
                            let result = try await PlexAPIService.discoverServers(token: authToken)
                            isDiscoveringServers = false
                            availableServers = result.reachable.map {
                                ServerRef(machineIdentifier: $0.machineIdentifier, name: $0.name, baseURL: $0.bestReachableURI, owned: $0.owned, token: $0.token)
                            }

                            guard !availableServers.isEmpty else {
                                // Differentiate "no server on the account" from "server(s)
                                // exist but none reachable" — very different fixes for the user.
                                let n = result.totalServers
                                if n == 0 {
                                    authError = "Signed in, but no Plex Media Server was found on your account. Set up Plex on a computer or NAS (with media), make sure it's running, then try again."
                                } else if result.ownedServers == 0 {
                                    // Shared-only user: they don't own the server, so "enable
                                    // Remote Access" is the wrong advice — only the owner can.
                                    authError = "Signed in, but the shared library you have access to isn't reachable right now (\(n) found, none reachable). Ask the server's owner to confirm it's online and Remote Access is on, then try again."
                                } else {
                                    authError = "Signed in, but couldn't reach your Plex server from this network (\(n) found, none reachable). Make sure the server is running and Remote Access is enabled, then try again."
                                }
                                Analytics.track(.connectFailed(backend: .plex, reason: "no_reachable_server"))
                                isAuthInProgress = false
                                currentAuthAttempt = nil
                                break
                            }

                            isAuthInProgress = false
                            currentAuthAttempt = nil
                            pinCode = ""
                            justAuthenticated = true
                            lastFailureDiagnostic = nil
                            Analytics.track(.connectCompleted(backend: .plex, serverCount: availableServers.count))
                            if availableServers.count == 1 {
                                completePlexSignIn(token: authToken, servers: availableServers)
                                await loadLibrary()
                            } else {
                                // Held in memory until the picker confirms; the token is
                                // persisted together with the chosen servers.
                                token = authToken
                                needsServerSelection = true
                            }
                        } catch {
                            isDiscoveringServers = false
                            Analytics.track(.connectFailed(backend: .plex, reason: "server_discovery_failed"))
                            authError = "Signed in, but couldn't reach plex.tv to find your servers. Check your connection and try again."
                            isAuthInProgress = false
                            currentAuthAttempt = nil
                        }
                        break
                    }
                } catch {
                    // Network error — keep polling
                }
            }
        }
    }

    // MARK: - Jellyfin Auth

    /// Username/password login against a Jellyfin server URL. On success switches the
    /// backend to Jellyfin, persists credentials, and loads the library.
    func authenticateJellyfin(serverURL rawURL: String, username: String, password: String) {
        let url = Self.normalizeJellyfinServerURL(rawURL)
        guard !url.isEmpty else { authError = "Enter your Jellyfin server URL."; return }
        guard !username.isEmpty else { authError = "Enter your Jellyfin username."; return }

        pinPollTask?.cancel()
        authError = nil
        isAuthInProgress = true
        currentAuthAttempt = (.jellyfin, .password)
        Analytics.track(.connectStarted(backend: .jellyfin, method: .password))
        pinPollTask = Task {
            do {
                let (url, result) = try await Self.tryServerCandidates(rawURL) {
                    try await JellyfinAPIService.authenticate(serverURL: $0, username: username, password: password)
                }
                guard !Task.isCancelled else { return }
                await completeJellyfinAuth(serverURL: url, result: result)
            } catch let api as PlexAPIService.APIError {
                guard !Task.isCancelled else { return }
                isAuthInProgress = false
                currentAuthAttempt = nil
                Analytics.track(.connectFailed(backend: .jellyfin, reason: "jellyfin_auth_failed"))
                authError = api == .unauthorized
                    ? "Incorrect username or password."
                    : "Could not reach the Jellyfin server. Check the URL."
            } catch {
                guard !Task.isCancelled else { return }
                isAuthInProgress = false
                currentAuthAttempt = nil
                Analytics.track(.connectFailed(backend: .jellyfin, reason: "jellyfin_unreachable"))
                authError = Self.serverUnreachableMessage(error, backend: "Jellyfin")
            }
        }
    }

    /// Quick Connect login: shows a code the user approves in their Jellyfin dashboard,
    /// then polls until approved and exchanges the secret for an access token.
    func startJellyfinQuickConnect(serverURL rawURL: String) {
        let url = Self.normalizeJellyfinServerURL(rawURL)
        guard !url.isEmpty else { authError = "Enter your Jellyfin server URL."; return }

        pinPollTask?.cancel()
        authError = nil
        isAuthInProgress = true
        jellyfinQuickConnectCode = ""
        currentAuthAttempt = (.jellyfin, .quickConnect)
        Analytics.track(.connectStarted(backend: .jellyfin, method: .quickConnect))
        pinPollTask = Task {
            do {
                let (url, initiated) = try await Self.tryServerCandidates(rawURL) {
                    try await JellyfinAPIService.quickConnectInitiate(serverURL: $0)
                }
                guard !Task.isCancelled else { return }
                jellyfinQuickConnectCode = initiated.code

                var attempts = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { break }
                    attempts += 1
                    if attempts > 150 {
                        Analytics.track(.connectCodeExpired(backend: .jellyfin, method: .quickConnect))
                        authError = "Code expired. Tap Connect to try again."
                        isAuthInProgress = false
                        currentAuthAttempt = nil
                        jellyfinQuickConnectCode = ""
                        break
                    }
                    let approved = (try? await JellyfinAPIService.quickConnectCheck(serverURL: url, secret: initiated.secret)) ?? false
                    guard approved else { continue }

                    let result = try await JellyfinAPIService.quickConnectAuthenticate(serverURL: url, secret: initiated.secret)
                    guard !Task.isCancelled else { return }
                    await completeJellyfinAuth(serverURL: url, result: result)
                    break
                }
            } catch {
                guard !Task.isCancelled else { return }
                isAuthInProgress = false
                currentAuthAttempt = nil
                jellyfinQuickConnectCode = ""
                Analytics.track(.connectFailed(backend: .jellyfin, reason: "jellyfin_quick_connect_failed"))
                authError = Self.quickConnectFailureMessage(error)
            }
        }
    }

    /// Shared success path for both Jellyfin auth methods.
    private func completeJellyfinAuth(serverURL url: String, result: JellyfinAPIService.AuthResult) async {
        backendKind = .jellyfin
        token = result.accessToken
        jellyfinUserId = result.userId
        serverURL = url
        serverName = result.serverName

        let machineID = result.serverID.isEmpty ? url : result.serverID
        let ref = ServerRef(machineIdentifier: machineID, name: result.serverName,
                            baseURL: url, owned: true, token: result.accessToken, userId: result.userId)
        availableServers = [ref]

        isAuthInProgress = false
        currentAuthAttempt = nil
        jellyfinQuickConnectCode = ""
        justAuthenticated = true
        lastFailureDiagnostic = nil
        Analytics.track(.connectCompleted(backend: .jellyfin, serverCount: 1))

        setSelectedServers([ref])   // persists selectedServers + syncs primary fields
        saveCredentials()           // persists backendKind, token, serverURL, jellyfinUserId
        await loadLibrary()
    }

    // MARK: - Emby Auth

    /// Username/password login against an Emby server URL.
    func authenticateEmby(serverURL rawURL: String, username: String, password: String) {
        let url = Self.normalizeJellyfinServerURL(rawURL)
        guard !url.isEmpty else { authError = "Enter your Emby server URL."; return }
        guard !username.isEmpty else { authError = "Enter your Emby username."; return }

        pinPollTask?.cancel()
        authError = nil
        isAuthInProgress = true
        currentAuthAttempt = (.emby, .password)
        Analytics.track(.connectStarted(backend: .emby, method: .password))
        pinPollTask = Task {
            do {
                let (url, result) = try await Self.tryServerCandidates(rawURL) {
                    try await EmbyAPIService.authenticate(serverURL: $0, username: username, password: password)
                }
                guard !Task.isCancelled else { return }
                await completeEmbyAuth(serverURL: url, result: result)
            } catch let api as PlexAPIService.APIError {
                guard !Task.isCancelled else { return }
                isAuthInProgress = false
                currentAuthAttempt = nil
                Analytics.track(.connectFailed(backend: .emby, reason: "emby_auth_failed"))
                authError = api == .unauthorized
                    ? "Incorrect username or password."
                    : "Could not reach the Emby server. Check the URL."
            } catch {
                guard !Task.isCancelled else { return }
                isAuthInProgress = false
                currentAuthAttempt = nil
                Analytics.track(.connectFailed(backend: .emby, reason: "emby_unreachable"))
                authError = Self.serverUnreachableMessage(error, backend: "Emby")
            }
        }
    }

    /// The one place an Emby sign-in is committed. Internal (not private) so the backend
    /// switch test can run the real commit path with a canned auth result.
    func completeEmbyAuth(serverURL url: String, result: EmbyAPIService.AuthResult) async {
        backendKind = .emby
        token = result.accessToken
        jellyfinUserId = result.userId
        serverURL = url
        serverName = result.serverName

        let machineID = result.serverID.isEmpty ? url : result.serverID
        let ref = ServerRef(machineIdentifier: machineID, name: result.serverName,
                            baseURL: url, owned: true, token: result.accessToken, userId: result.userId)
        availableServers = [ref]

        isAuthInProgress = false
        currentAuthAttempt = nil
        justAuthenticated = true
        lastFailureDiagnostic = nil
        Analytics.track(.connectCompleted(backend: .emby, serverCount: 1))

        setSelectedServers([ref])
        saveCredentials()
        await loadLibrary()
    }

    /// Cleans up a typed Jellyfin / Emby address (see `ServerURLNormalizer`). Only used to
    /// check that something usable was typed; sign-in itself tries every candidate.
    static func normalizeJellyfinServerURL(_ raw: String) -> String {
        ServerURLNormalizer.normalize(raw)
    }

    /// Runs a sign-in call against each candidate base URL in order and returns the one
    /// that answered. A bare IP tries `:8096` first and the address as typed second.
    /// Moves on only when the first try clearly hit the wrong place (nothing listening,
    /// a 404, or a web page); a wrong password or a timeout is a real answer and stops.
    static func tryServerCandidates<T>(_ raw: String, _ operation: (String) async throws -> T) async throws -> (url: String, value: T) {
        let candidates = ServerURLNormalizer.candidates(raw)
        guard !candidates.isEmpty else { throw PlexAPIService.APIError.invalidResponse }
        for (index, url) in candidates.enumerated() {
            do {
                return (url, try await operation(url))
            } catch {
                guard index < candidates.count - 1, isWrongPlaceError(error) else { throw error }
            }
        }
        throw PlexAPIService.APIError.invalidResponse
    }

    /// Quick Connect failing to start was one message for two different problems, and the
    /// common one (the server wasn't reachable at that address) got the wrong advice.
    /// Jellyfin answers 401 when Quick Connect is switched off.
    static func quickConnectFailureMessage(_ error: Error) -> String {
        if error is URLError { return serverUnreachableMessage(error, backend: "Jellyfin") }
        switch error as? PlexAPIService.APIError {
        case .unauthorized?:
            return "Quick Connect is off on this server. Turn it on in Jellyfin (Dashboard, then General), or sign in with your password."
        case .httpFailure(statusCode: 404)?, .receivedMarkupInsteadOfJSON?:
            return "That address answered, but it isn't Jellyfin. Check the address and port (Jellyfin uses 8096)."
        default:
            return "Could not start Quick Connect. Check the server address, or sign in with your password."
        }
    }

    static func isWrongPlaceError(_ error: Error) -> Bool {
        if let urlError = error as? URLError { return urlError.code == .cannotConnectToHost }
        switch error as? PlexAPIService.APIError {
        case .httpFailure(statusCode: 404)?, .receivedMarkupInsteadOfJSON?: return true
        default: return false
        }
    }
}
