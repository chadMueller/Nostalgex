import Foundation
import os
import Observation
import SwiftUI
import AVFoundation
import Combine
import UIKit

// Library loading, snapshot hydration and restore.
// Split out of AppState.swift; behavior unchanged.
extension AppState {
    // MARK: - Library loading

    private func markInitialLibraryLoadComplete() {
        UserDefaults.standard.set(true, forKey: Self.initialLoadCompleteKey)
    }

    func setLibraryPhase(_ phase: LibraryLoadPhase, detail: String = "") {
        libraryLoadPhase = phase
        libraryLoadDetail = detail
        loadingMessage = phase.headline(detail: detail)
    }

    /// Lets SwiftUI paint each load phase before the next stretch of work (avoids steps appearing pre-checked).
    private func briefUILBeat() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 220_000_000)
    }

    private func pulseLibraryPhase(_ phase: LibraryLoadPhase, detail: String = "") async {
        setLibraryPhase(phase, detail: detail)
        await briefUILBeat()
    }

    private static let musicBundleID = "high-rotation"

    private var isMusicBundleEnabled: Bool {
        enabledBundleIDs.contains(Self.musicBundleID)
    }

    /// Apply on-disk MusicBrainz rows only (no network).
    private func applyMusicCacheToLibrary() {
        musicEnrichmentService.loadDiskCache()
        allItems = musicEnrichmentService.itemsWithDisplayMetadata(allItems)
    }

    /// MusicBrainz is rate-limited (~1 req/s); don't block first tune-in unless user wants music channels.
    private func startDeferredMusicEnrichmentIfNeeded() {
        guard isMusicBundleEnabled else { return }
        let musicVideos = allItems.filter { ($0.librarySource ?? .movie) == .musicVideo }
        guard !musicVideos.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            print("[MusicEnrichment] Background pass for \(musicVideos.count) music videos (High Rotation bundle on)")
            await self.musicEnrichmentService.enrichMusicVideos(self.allItems)
            await MainActor.run {
                self.allItems = self.musicEnrichmentService.itemsWithDisplayMetadata(self.allItems)
                self.allChannels = self.musicEnrichmentService.refreshChannelPools(self.allChannels, from: self.allItems)
                self.applyBundleFilter()
                if let current = self.currentChannel {
                    self.selectChannel(current)
                }
                self.saveLibrarySnapshotIfNeeded()
            }
        }
    }

    private func refreshLibraryLoadStepRail(includesCollections: Bool, includesMusic: Bool) {
        libraryLoadVisibleSteps = LibraryLoadPhase.visibleSteps(
            includesCollections: includesCollections,
            includesMusic: includesMusic
        )
    }

    /// What the stall watch compares. These are the counters a live scan keeps moving, so a
    /// scan that is still finding items is never interrupted no matter how long it takes.
    private func libraryScanProgressSample() -> LibraryLoadProgressSample {
        LibraryLoadProgressSample(
            phase: libraryLoadPhase.rawValue,
            sectionIndex: scanSectionIndex,
            totalSections: scanTotalSections,
            itemsFound: scanItemsFound,
            detail: libraryLoadDetail
        )
    }

    func loadLibrary(background: Bool = false) async {
        guard hasCredentials else { return }
        // Demo mode is fully bundled — never hit the network
        if isDemoMode { return }
        // Cleared by the defer on every end this process lives to see. Still set at the
        // next launch means the app died inside this load (LaunchGuard). Only a load the
        // viewer is waiting on counts: tvOS ending a suspended app during a background
        // refresh says nothing about whether the library can load.
        let tracksLoad = LaunchGuard.tracksLoad(background: background, hasChannels: !channels.isEmpty)
        if tracksLoad { LaunchGuard.loadStarted() }
        defer { if tracksLoad { LaunchGuard.loadEnded() } }
        InstallDiagnostics.note("loadLibrary: background=\(background) channels=\(self.channels.count) servers=\(self.selectedServers.count) lastLoadAge=\(Int(Date().timeIntervalSince1970) - self.lastLoadAtUnix)s")
        // Wall-clock start for the load duration on library.load.completed. Placed
        // before the UI-test stub bailout on purpose: a stubbed load is still a load,
        // and duration=0ms is a valid answer for it.
        let loadStartedAt = Date()
        Analytics.track(.libraryLoadStarted(background: background && !channels.isEmpty, firstLoad: isFirstLibraryLoad))

        if !isUITestStubLibrarySuccess {
            if !background { isLoading = true; loadingMessage = "FINDING YOUR SERVERS..." }
            guard await recoverPlexServersIfNeeded() else {
                isLoading = false
                return
            }
        }

        let isBackground = background && !channels.isEmpty

        // The sign-in this load is for. Taken after server recovery, which may itself
        // replace the server list. Checked after every await that precedes a commit: a
        // Disconnect or a new sign-in while a scan is out means its results are for a
        // library the user has left, and they must not touch the one they moved to.
        let session = librarySessionGeneration
        func superseded() -> Bool {
            guard librarySessionGeneration != session else { return false }
            print("[Plex90] LOAD: sign-in changed while the scan was running, discarding its results")
            isLoadStalling = false
            if isBackground {
                isBackgroundRefreshing = false
            } else if !hasCredentials {
                isLoading = false
            }
            return true
        }

        if isUITestStubLibrarySuccess {
            isLoading = true
            loadingMessage = "LOADING CHANNELS..."
            errorMessage = nil

            let stubChannel = Channel(
                id: 1,
                number: 1,
                name: "STUB",
                color: .blue,
                category: nil,
                rules: nil,
                timeRestrictions: nil,
                minItems: 0,
                itemPool: []
            )
            allChannels = [stubChannel]
            channels = [stubChannel]
            isLoading = false
            return
        }

        let buildAllConfigChannels = isFirstLibraryLoad
        let hasAnyCollectionBundle = CollectionCategory.allCases.contains {
            enabledBundleIDs.contains($0.bundleID)
        }

        // A "stop waiting" pressed as the previous scan was finishing must not carry over
        // and abandon this one on its first poll.
        loadCancelRequested = false
        isLoadStalling = false

        if isBackground {
            isBackgroundRefreshing = true
        } else {
            isLoading = true
            errorMessage = nil
            channelBuildIndex = 0
            channelBuildTotal = 0
        }

        refreshLibraryLoadStepRail(includesCollections: hasAnyCollectionBundle, includesMusic: false)
        await pulseLibraryPhase(.preparing, detail: isFirstLibraryLoad ? "First setup" : "Updating lineup")

        // Migrate legacy "collections" bundle ID if needed
        migrateCollectionBundleIDs()

        // Load channel + bundle config: try server first, fall back to bundled
        await pulseLibraryPhase(.preparing, detail: "Loading channel rules")
        let config = await loadChannelConfig()

        // Store bundles, applying persisted enabled/disabled state
        bundles = config.bundles.map { def in
            def.toChannelBundle(enabled: enabledBundleIDs.contains(def.id))
        }

        // Store exclusive rules for channel ownership
        exclusiveRules = config.exclusiveRules

        await pulseLibraryPhase(.preparing, detail: "\(config.bundles.count) bundles · \(enabledBundleIDs.count) on")
        await pulseLibraryPhase(.scanningLibrary, detail: "Connecting to \(backendDisplayName)")
        scanSectionIndex = 0
        scanTotalSections = 0
        scanItemsFound = 0

        do {
            // Scan every selected server (the token is account-level and works on all of
            // them) and merge. Items are tagged with their server id inside each service,
            // so playback can route back to the right server later.
            let apisToScan: [any MediaBackend] = selectedServers.isEmpty
                ? [api]
                : selectedServers.map { apiForServer($0) }
            let serverNames: [String] = selectedServers.isEmpty ? [serverName] : selectedServers.map(\.name)
            let multiServer = apisToScan.count > 1

            var merged: [PlexMediaItem] = []
            var successCount = 0
            var lastError: Error?
            // Set when a scan was abandoned rather than finishing. What follows is built
            // from whatever was fetched, and the library is marked stale so a later
            // refresh fills in the rest.
            var scanWasAbandoned = false

            for (serverIndex, scanAPI) in apisToScan.enumerated() {
                let serverLabel = serverIndex < serverNames.count ? serverNames[serverIndex] : "Plex"
                let baseCount = merged.count
                do {
                    let items = try await withLibraryLoadStallWatch(
                        sample: { [weak self] in self?.libraryScanProgressSample() ?? LibraryLoadProgressSample() },
                        onVerdict: { [weak self] verdict in
                            guard let self else { return }
                            // A background refresh has no loading screen to warn on, and the
                            // user is mid-program: stay silent and let the watchdog resolve
                            // it without touching what's on screen.
                            guard !isBackground else { return }
                            switch verdict {
                            case .progressing: self.isLoadStalling = false
                            case .slow, .stalled: self.isLoadStalling = true
                            }
                        },
                        // A sign-in change also ends the scan early rather than letting
                        // minutes of requests run against a server the user left.
                        abortRequested: { [weak self] in
                            guard let self else { return true }
                            return self.consumeLoadCancelRequest() || self.librarySessionGeneration != session
                        },
                        operation: {
                            try await scanAPI.loadLibrary { [weak self] event in
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    self.scanSectionIndex = event.sectionIndex
                                    self.scanTotalSections = event.totalSections
                                    self.scanItemsFound = baseCount + event.itemsLoadedSoFar
                                    self.libraryLoadPhase = .scanningLibrary
                                    let label: String
                                    switch event.sectionType {
                                    case "show": label = "TV shows"
                                    case "movie":
                                        let lower = event.sectionTitle.lowercased()
                                        if lower.contains("music") { label = "Music" }
                                        else { label = "Movies" }
                                    case "artist": label = "Music"
                                    case "photo": label = "Photos"
                                    default: label = "Library"
                                    }
                                    let prefix = multiServer ? "\(serverLabel) · " : ""
                                    if let done = event.showsCompleted, let total = event.totalShows {
                                        self.libraryLoadDetail = "\(prefix)Section \(event.sectionIndex + 1)/\(event.totalSections) · \(done)/\(total) shows"
                                        self.loadingMessage = self.libraryLoadPhase.headline(
                                            detail: "\(label) \(done)/\(total)"
                                        )
                                    } else {
                                        self.libraryLoadDetail = "\(prefix)Section \(event.sectionIndex + 1)/\(max(event.totalSections, 1)) · \(event.itemsLoadedSoFar) items"
                                        self.loadingMessage = self.libraryLoadPhase.headline(detail: label)
                                    }
                                }
                            }
                        }
                    )
                    merged.append(contentsOf: items)
                    successCount += 1
                } catch let interrupted as LibraryScanInterrupted {
                    // Abandoned partway, but whole sections came back. Those count as a
                    // success: a reduced guide beats an error screen.
                    print("[Plex90] LOAD: server '\(serverLabel)' abandoned with \(interrupted.partialItems.count) items already fetched")
                    merged.append(contentsOf: interrupted.partialItems)
                    if !interrupted.partialItems.isEmpty { successCount += 1 }
                    scanWasAbandoned = true
                    lastError = interrupted
                } catch let stalled as LibraryLoadStalled {
                    print("[Plex90] LOAD: server '\(serverLabel)' stalled (userInitiated=\(stalled.userInitiated))")
                    scanWasAbandoned = true
                    lastError = stalled
                } catch {
                    print("[Plex90] LOAD: server '\(serverLabel)' failed: \(error)")
                    lastError = error
                }
            }
            isLoadStalling = false
            LibraryLoadProbe.mark("fetch")

            // Nothing below this line may run for a sign-in that has ended.
            if superseded() { return }

            // Surface a connection error only when every server failed.
            if successCount == 0 {
                throw lastError ?? PlexAPIService.APIError.noReachableServer
            }

            if scanWasAbandoned {
                // Distinguish "user tapped stop waiting" from "watchdog gave up" so the
                // dashboard can tell frustration from unreliability.
                let userInitiated = (lastError as? LibraryLoadStalled)?.userInitiated == true
                    || (lastError as? LibraryScanInterrupted) != nil
                Analytics.track(.libraryLoadAbandoned(
                    background: isBackground,
                    itemsFound: merged.count,
                    userInitiated: userInitiated
                ))
            }

            // A background refresh that had to be abandoned is thrown away rather than
            // applied. Its partial item list is a subset of what the user is already
            // watching, so adopting it would shrink a working guide mid-program. Marking
            // the library stale leaves the existing daily-refresh loop to try again.
            if isBackground, scanWasAbandoned {
                print("[Plex90] LOAD: background refresh abandoned mid-scan, keeping the loaded lineup")
                isBackgroundRefreshing = false
                isLibraryStale = true
                return
            }

            merged = Self.dedupingItems(merged, servers: selectedServers)
            // Belt and braces under the generation check: an item stamped with a server
            // that is not signed in can never be played, so it never enters a pool.
            let foreign = merged.filter { !itemBelongsToConnectedServers($0) }.count
            if foreign > 0 {
                print("[Plex90] LOAD: dropped \(foreign) item(s) from servers that are not signed in")
                merged = merged.filter { itemBelongsToConnectedServers($0) }
            }
            allItems = merged
            scanItemsFound = merged.count
            let withTMDB = merged.filter { $0.tmdbID != nil }.count
            let withIMDB = merged.filter { $0.imdbID != nil }.count
            print("[Plex90] Library: \(merged.count) items from \(successCount) server(s), \(withTMDB) with TMDB IDs, \(withIMDB) with IMDb IDs")
            if backendKind == .emby {
                // They stay in the library; ChannelEligibility keeps them out of every pool.
                print("[Plex90] CHANNELS: \(ChannelEligibility.leftOffCount(merged, backend: backendKind)) Emby Dolby Vision profile 5 item(s) left off channels")
            }
            LibraryLoadProbe.mark("merge+dedupe")

            if hasAnyCollectionBundle {
                await pulseLibraryPhase(.discoveringCollections)
                await scanCollections()
            } else {
                print("[Plex90] COLLECTIONS: No collection bundles enabled, skipping scan")
            }
            LibraryLoadProbe.mark("collections")

            let enrichableCount = allItems.filter { $0.tmdbID != nil || $0.imdbID != nil }.count
            await pulseLibraryPhase(.enrichingMetadata, detail: "\(enrichableCount) titles")
            await enrichmentService.enrichItems(
                allItems,
                omdbGates: OMDBGate.gates(from: config.channels.compactMap(\.rules))
            )
            await briefUILBeat()
            LibraryLoadProbe.mark("enrichment")

            // Collections and enrichment both waited on the network.
            if superseded() { return }

            applyMusicCacheToLibrary()
            LibraryLoadProbe.mark("musicCache")
            if isMusicBundleEnabled {
                let musicVideoCount = allItems.filter { ($0.librarySource ?? .movie) == .musicVideo }.count
                if musicVideoCount > 0 {
                    print("[Plex90] Music: deferring MusicBrainz for \(musicVideoCount) videos until after tune-in")
                }
            }

            channelConfigChannels = config.channels
            let poolChannelIDs = staticChannelIDsForPoolBuild(buildAllConfigChannels: buildAllConfigChannels)
            print("[Plex90] CHANNEL BUILD: firstLoad=\(buildAllConfigChannels), building \(poolChannelIDs.count) static channels")

            setLibraryPhase(.buildingChannels, detail: buildAllConfigChannels ? "Full lineup" : "Enabled bundles")
            let staticBuilt = await rebuildStaticChannelPools(
                configChannels: config.channels,
                items: allItems,
                onlyChannelIDs: poolChannelIDs
            )

            // The pool build ran off the main actor.
            if superseded() { return }

            let dynamicChannels = allChannels.filter { $0.rules == nil }
            allChannels = (staticBuilt + dynamicChannels).sorted { $0.number < $1.number }
            LibraryLoadProbe.mark("channelsMerged")

            // Enrichment has landed and the classics are built: decide which franchises
            // the library holds, fold any server collection that is one of them, and
            // rebuild the runtime channels from both lists.
            rebuildFoundFranchises()
            materializeDynamicChannels()

            setLibraryPhase(.finishing)
            print("[Plex90] BUNDLES: \(bundles.map { "\($0.name)(\($0.channelIDs.count)ch, \($0.enabled ? "ON" : "OFF"))" }.joined(separator: ", "))")
            print("[Plex90] allChannels: \(allChannels.count), enabledBundleIDs: \(enabledBundleIDs)")

            printChannelAudit()
            LibraryLoadProbe.mark("channelAudit")
            applyBundleFilter()
            // New user whose enabled bundle didn't match their library: pull in any other
            // bundle that does have content so they land in a real guide, not the dead end.
            if channels.isEmpty {
                autoEnableBundlesWithContent()
            }
            // A partial scan must not count as the first load: that flag is what stops
            // later loads from rebuilding every channel, and the channels built here were
            // matched against an incomplete library.
            if !scanWasAbandoned {
                markInitialLibraryLoadComplete()
            }
            isLoading = false
            isBackgroundRefreshing = false
            isLibraryStale = scanWasAbandoned
            LibraryLoadProbe.mark("guideVisible")

            // Library refresh: only purge yesterday's (and older) manifests. Today's
            // schedule is already self-invalidating via pool fingerprint inside
            // DailyManifestStore — leave it alone so a background refresh can't
            // reshuffle the EPG the user is currently watching.
            let todayKey = DailyManifestStore.localDayKey(for: Date())
            DailyManifestStore.purgeDays(keeping: todayKey, credentialFingerprint: scheduleCredentialFingerprint)

            if isBackground {
                libraryUpdateNotice = scanWasAbandoned ? "Lineup partly updated" : "Lineup updated"
                if let current = currentChannel {
                    selectChannel(current)
                }
            } else if currentChannel == nil, let first = channels.first {
                selectChannel(first)
            }

            LibraryLoadProbe.mark("selectChannel")
            startDeferredMusicEnrichmentIfNeeded()


            // Record when this load completed (Unix seconds) — drives 24h
            // rolling cache validity. A partial scan is backdated past that window, which
            // does two jobs at once: the snapshot still restores instantly on the next
            // launch (a reduced guide beats a cold start) but reads as stale, and the
            // daily-refresh loop already running picks it up on its next 15-minute tick.
            // The alternative, a new snapshot field, would invalidate every snapshot on
            // every device.
            let completedAt = Int(Date().timeIntervalSince1970)
            let signature = scanWasAbandoned ? nil : await currentLibrarySignature()
            // The signature request is one more await before the snapshot is written.
            if superseded() { return }
            LibraryLoadProbe.mark("signature")
            lastLoadAtUnix = scanWasAbandoned ? completedAt - 86_400 : completedAt
            librarySignature = signature
            lastLibraryCheckAtUnix = completedAt
            saveLibrarySnapshotIfNeeded()
            LibraryLoadProbe.mark("snapshotSaved")

            let durationMs = Int(Date().timeIntervalSince(loadStartedAt) * 1000)
            Analytics.track(.libraryLoadCompleted(
                channelCount: channels.count,
                itemCount: allItems.count,
                background: isBackground,
                durationMs: durationMs,
                partial: scanWasAbandoned
            ))
            if channels.isEmpty {
                Analytics.track(.libraryLoadEmpty)
            }

            // The lineup only really changes on a load, so this is the cheap
            // place to refresh what the Top Shelf shows. No-ops until the App
            // Group exists.
            refreshTopShelfSnapshot()

            // Library loaded successfully — clear the "first-login" flag so future failures
            // (e.g. server restart, token rotation) get the proper "session expired" message.
            justAuthenticated = false
            lastFailureDiagnostic = nil
        } catch let api as PlexAPIService.APIError {
            isLoading = false
            isBackgroundRefreshing = false
            isLoadStalling = false
            print("[Plex90] loadLibrary failed: \(api)")
            let reason = String(describing: api)
            if isBackground {
                // Silent to the user; still important for reliability metrics.
                Analytics.track(.libraryRefreshBackgroundFailed(reason: reason))
            } else {
                Analytics.track(.libraryLoadFailed(reason: reason, background: false))
                errorMessage = Self.userFacingPlexAPIServiceError(api, justAuthenticated: justAuthenticated, backend: backendKind)
                lastFailureDiagnostic = diagnosticString(for: api)
                if case .unauthorized = api, !justAuthenticated {
                    await resolveUnauthorizedLoadFailure()
                }
            }
        } catch is CancellationError {
            isLoading = false
            isBackgroundRefreshing = false
            isLoadStalling = false
            errorMessage = nil
        } catch {
            isLoading = false
            isBackgroundRefreshing = false
            isLoadStalling = false
            print("[Plex90] loadLibrary failed: \(error)")
            let reason = Self.analyticsReason(for: error)
            if isBackground {
                Analytics.track(.libraryRefreshBackgroundFailed(reason: reason))
            } else {
                Analytics.track(.libraryLoadFailed(reason: reason, background: false))
                errorMessage = Self.userFacingLoadLibraryError(error, backend: backendKind)
                let host = URL(string: serverURL)?.host ?? "?"
                if let stalled = error as? LibraryLoadStalled {
                    lastFailureDiagnostic = "\(host) · stalled \(Int(stalled.secondsWithoutProgress))s"
                } else {
                    lastFailureDiagnostic = "\(host) · \((error as NSError).domain) \((error as NSError).code)"
                }
            }
        }
    }

    // MARK: - Library snapshot (same-day relaunch avoids full Plex scan)

    /// Restore lineup from disk when credentials match. Returns true even for stale (>24h) snapshots.
    /// One small request per server. Nil whenever any server cannot answer, so an outage
    /// or a backend without timestamps falls back to the ordinary scan rather than a skip.
    func currentLibrarySignature() async -> String? {
        guard backendKind == .plex, !selectedServers.isEmpty else { return nil }
        var parts: [String] = []
        for server in selectedServers {
            let backend = apiForServer(server)
            guard let sections = try? await backend.loadSections(),
                  let sig = LibraryChangeSignature.signature(serverID: server.machineIdentifier, sections: sections) else {
                return nil
            }
            parts.append(sig)
        }
        return LibraryChangeSignature.combine(parts)
    }

    /// The 6h refresh, made to ask before it scans. A guide that hasn't changed on the
    /// server is not rebuilt; past the 24h cap it is rebuilt regardless.
    func refreshLibraryIfChanged() async {
        let now = Int(Date().timeIntervalSince1970)
        lastLibraryCheckAtUnix = now
        let age = now - lastLoadAtUnix
        let current = await currentLibrarySignature()
        if LibraryChangeSignature.shouldSkipRefresh(ageSeconds: age, stored: librarySignature, current: current,
                                                    hardCapSeconds: LibrarySnapshotStore.forceRefreshAfterSeconds) {
            print("[Plex90] REFRESH: library unchanged on server (\(age / 3600)h since scan), skipping rebuild")
            isLibraryStale = false
            return
        }
        print("[Plex90] REFRESH: \(age / 3600)h since scan, signature \(current == nil ? "unavailable" : "changed"), reloading in background")
        await loadLibrary(background: true)
    }

    /// Drops second copies of a title that arrived under two identities for the same server
    /// (see dedupingServers). Keyed on the server's host plus ratingKey, so two genuinely
    /// different servers that happen to reuse a ratingKey both keep their item.
    static func dedupingItems(_ items: [PlexMediaItem], servers: [ServerRef]) -> [PlexMediaItem] {
        func host(_ url: String) -> String {
            guard let u = URL(string: url), let h = u.host?.lowercased() else { return url.lowercased() }
            return "\(h):\(u.port ?? 32400)"
        }
        var hostByServerID: [String: String] = [:]
        for s in servers { hostByServerID[s.machineIdentifier] = host(s.baseURL) }
        func key(_ item: PlexMediaItem) -> String {
            let sid = item.serverID ?? ""
            return (hostByServerID[sid] ?? (sid.lowercased().hasPrefix("http") ? host(sid) : sid)) + "|" + item.ratingKey
        }
        // Find the duplicates first. Usually there are none, and then the input goes back
        // as is instead of a second full copy of the library being built next to it.
        var seen = Set<String>()
        seen.reserveCapacity(items.count)
        var duplicates = IndexSet()
        for (i, item) in items.enumerated() where !seen.insert(key(item)).inserted {
            duplicates.insert(i)
        }
        seen = []
        guard !duplicates.isEmpty else { return items }
        var out: [PlexMediaItem] = []
        out.reserveCapacity(items.count - duplicates.count)
        for (i, item) in items.enumerated() where !duplicates.contains(i) {
            out.append(item)
        }
        if out.count != items.count {
            print("[Plex90] LOAD: removed \(items.count - out.count) duplicate items (same server, two identities)")
        }
        return out
    }

    func restoreLibraryFromSnapshotIfNeeded() async -> Bool {
        guard hasCredentials else {
            InstallDiagnostics.note("snapshot: restore skipped, no credentials in memory")
            return false
        }
        guard !isUITestStubLibrarySuccess else { return false }
        // Reading and decoding the files is the slow part (seconds at 400k items); keep it
        // off the main actor so the launch screen stays responsive.
        let seed = snapshotIdentitySeed
        var loaded: LibrarySnapshotStore.Loaded?
        do {
            loaded = try await Task.detached(priority: .userInitiated) {
                try LibrarySnapshotStore.loadSnapshot(identity: seed)
            }.value
        } catch {
            InstallDiagnostics.fail("snapshot: restore threw \(String(describing: error)), falling back to full scan")
            return false
        }
        // `found` is the only owner of the decoded items from here on, so applying it can
        // drop them as soon as the deduplicated copy exists.
        guard var found = loaded else { return false }
        loaded = nil
        // A snapshot whose items were scanned from a server that is no longer signed in
        // (written by a scan that outlived a Disconnect, before that was stopped) would
        // restore a guide where nothing plays. Rescan instead.
        let foreign = found.snapshot.allItems.reduce(0) { $0 + (itemBelongsToConnectedServers($1) ? 0 : 1) }
        if foreign > 0 {
            InstallDiagnostics.note("snapshot: \(foreign) of \(found.snapshot.allItems.count) items belong to a server that is not signed in, rescanning")
            LibrarySnapshotStore.clear()
            DailyManifestStore.clearAll(credentialFingerprint: scheduleCredentialFingerprint)
            return false
        }
        let isStale = found.isStale
        let fromLegacyFile = found.fromLegacyFile
        applyLibrarySnapshot(&found.snapshot)
        isLibraryStale = isStale
        InstallDiagnostics.note("snapshot: restored, stale=\(isStale)")
        if fromLegacyFile {
            // One-time migration: write it back in the chunked format, which removes the
            // legacy file on commit, so the next launch never decodes the big file again.
            saveLibrarySnapshotIfNeeded()
        }
        return true
    }

    /// Takes the snapshot inout so its item array can be released as soon as the
    /// deduplicated copy exists, instead of both living until the restore returns.
    private func applyLibrarySnapshot(_ snap: inout LibrarySnapshotV1) {
        var restored = Self.dedupingItems(snap.allItems, servers: selectedServers)
        snap.allItems = []
        musicEnrichmentService.loadDiskCache()
        restored = musicEnrichmentService.itemsWithDisplayMetadata(restored)
        allItems = restored
        restored = []

        // id -> index into allItems, first occurrence wins (as refreshChannelPools resolved
        // it). An index is 8 bytes; a dictionary of whole items cost ~500 bytes an entry.
        var indexById: [String: Int] = [:]
        indexById.reserveCapacity(allItems.count)
        for (i, item) in allItems.enumerated() where indexById[item.id] == nil {
            indexById[item.id] = i
        }
        let items = allItems
        let lookup: (String) -> PlexMediaItem? = { id in indexById[id].map { items[$0] } }

        serverName = snap.serverName
        isConnected = true
        errorMessage = nil
        lastLoadAtUnix = snap.lastLoadAtUnix
        librarySignature = snap.librarySignature

        // The bundle list in UserDefaults is the latest choice, and may be newer than the
        // snapshot (a toggle that never re-saved it, or a lineup that arrived from another
        // Apple TV through iCloud while this one was off). Read it before the snapshot
        // overwrites it.
        let storedBundleIDs = UserDefaults.standard.stringArray(forKey: PreferenceSync.enabledBundlesKey)
        enabledBundleIDs = Set(snap.enabledBundleIDList)
        bundles = snap.bundleDefinitions.map { def in
            def.toChannelBundle(enabled: enabledBundleIDs.contains(def.id))
        }
        exclusiveRules = snap.exclusiveRuleJSON.map { $0.toExclusiveRule() }
        channelConfigChannels = snap.channelConfigRows.map {
            Channel.fromSnapshotRow($0, itemLookup: lookup, includePool: false)
        }
        // Pools resolve against allItems, which already carries the music display metadata,
        // so the old refreshChannelPools pass here (a second full id -> item dictionary)
        // produced the same pools.
        allChannels = snap.allChannelRows.map {
            Channel.fromSnapshotRow($0, itemLookup: lookup, includePool: true)
        }
        discoveredCollections = snap.discoveredCollectionRows.map { $0.resolve(itemLookup: lookup) }
        // The enrichment cache is empty until the next scan, so the found list cannot be
        // rebuilt here; it is restored as saved, with the viewer's current switches applied.
        foundFranchises = (snap.foundFranchiseRows ?? []).map {
            $0.resolve(itemLookup: lookup, enabledIDs: enabledFranchiseIDs, disabledIDs: disabledFranchiseIDs)
        }

        scanSectionIndex = 0
        scanTotalSections = 0
        scanItemsFound = allItems.count

        // Collection lineup no longer exposes per-category toggles; keep bundles enabled when discoveries exist.
        syncCollectionCategoryBundlesWithDiscoveries(persistPreferences: false)
        let preferredBundleIDs = Self.preferredBundleIDsAfterSnapshot(
            stored: storedBundleIDs, snapshotWithDiscoveries: enabledBundleIDs,
            discoveredCategoryBundleIDs: Set(discoveredCollections.map(\.category.bundleID)))
        if preferredBundleIDs == enabledBundleIDs { saveBundlePreferences() }
        for i in bundles.indices {
            bundles[i].enabled = enabledBundleIDs.contains(bundles[i].id)
        }

        // Runtime channels come back from the restored lists rather than the stored rows,
        // so the found-franchise channel ids are known to applyBundleFilter. Same content,
        // same numbering: the lists are what the rows were built from.
        materializeDynamicChannels()
        applyBundleFilter()
        if currentChannel == nil, let first = channels.first {
            selectChannel(first)
        }
        if preferredBundleIDs != enabledBundleIDs {
            print("[Sync] snapshot lineup differs from the saved one, rebuilding to the saved lineup")
            applyEnabledBundleIDs(preferredBundleIDs)
        }
        if discoveredCollections.contains(where: { $0.enabled != enabledCollectionKeys.contains($0.id) }) {
            print("[Sync] snapshot collections differ from the saved ones, rebuilding")
            applyEnabledCollectionKeys(enabledCollectionKeys)
        }
        print("[Plex90] Snapshot: restored from disk (no Plex crawl)")
    }

    /// Stable, PII-free label for an unexpected library-load failure.
    ///
    /// This exists because the analytics reason used to be `error.localizedDescription`,
    /// which is free-form text the app does not control. Some Foundation and third-party
    /// errors interpolate the failing URL into that string, which would have put a user's
    /// server address into an analytics event and contradicted the privacy policy.
    /// Domain plus code is enough to group failures and cannot carry a hostname.
    static func analyticsReason(for error: Error) -> String {
        if error is LibraryLoadStalled { return "load_stalled" }
        let ns = error as NSError
        return "\(ns.domain)_\(ns.code)"
    }

    /// Captures the library on the main actor (copy-on-write, no copying) and writes it on
    /// a background queue in chunks. Returns immediately.
    func saveLibrarySnapshotIfNeeded() {
        guard !isUITestStubLibrarySuccess else { return }
        let payload = LibrarySnapshotStore.makePayload(
            identity: snapshotIdentitySeed,
            serverName: serverName,
            librarySignature: librarySignature,
            lastLoadAtUnix: lastLoadAtUnix,
            allItems: allItems,
            channelConfigChannels: channelConfigChannels,
            allChannels: allChannels,
            bundles: bundles,
            enabledBundleIDs: enabledBundleIDs,
            exclusiveRules: exclusiveRules,
            discoveredCollections: discoveredCollections,
            foundFranchises: foundFranchises
        )
        LibraryLoadProbe.mark("snapshot.capture")
        LibrarySnapshotStore.saveInBackground(payload)
    }
}
