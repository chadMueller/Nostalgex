import XCTest
@testable import Nostalgex

/// Reproduced on an Apple TV HD (tvOS 26.6, build 45): a device signed into Plex pressed
/// Disconnect, connected Emby, and then not one channel would play until the app was
/// reinstalled. The ids reaching Emby were Plex rating keys ("Richie Rich" was retried
/// 28 times and is not in the Emby library at all).
///
/// These tests drive the real sign-in, disconnect, and `loadLibrary` paths against canned
/// backends and assert that nothing keyed to the old server can be served for the new
/// session: not in `allItems`, not in a channel pool, not in a built schedule, and not in
/// the snapshot written under the new identity.
@MainActor
final class BackendSwitchScheduleTests: XCTestCase {

    // MARK: - Fixtures

    private final class InMemoryStore: Nostalgex.CredentialStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        @discardableResult
        func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    /// A latch a backend's `loadLibrary` can block on, so a scan can be held "in flight"
    /// across a Disconnect exactly the way a multi-minute Plex scan is on a real device.
    private actor Gate {
        private var opened = false
        private var entered = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            opened = true
            let w = waiters; waiters = []
            w.forEach { $0.resume() }
        }

        func wait() async {
            entered = true
            let e = entryWaiters; entryWaiters = []
            e.forEach { $0.resume() }
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        /// Resolves once a scan has actually reached the gate.
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }
    }

    private final class FakeBackend: MediaBackend, @unchecked Sendable {
        let serverID: String
        let items: [PlexMediaItem]
        let gate: Gate?
        var authHeaders: [String: String] { ["X-Test": serverID] }

        init(serverID: String, items: [PlexMediaItem], gate: Gate? = nil) {
            self.serverID = serverID
            self.items = items
            self.gate = gate
        }

        func testConnection() async throws -> String { serverID }
        func loadLibrary(progress: LoadProgress?) async throws -> [PlexMediaItem] {
            if let gate { await gate.wait() }
            try Task.checkCancellation()
            return items
        }
        func loadSections() async throws -> [PlexSection] {
            [PlexSection(key: "1", title: "Movies", type: "movie", scannedAt: 1, updatedAt: 1, contentChangedAt: 1)]
        }
        func loadCollections(sectionKey: String) async throws -> [PlexCollection] { [] }
        func loadCollectionItems(collectionKey: String) async throws -> [String] { [] }
        func buildDirectPlayURL(for item: PlexMediaItem) -> URL? {
            URL(string: "http://\(serverID).test/\(item.ratingKey).mp4")
        }
        func buildTranscodeURL(for item: PlexMediaItem) -> URL? { nil }
        func thumbnailURL(for item: PlexMediaItem, width: Int) -> URL? { nil }
    }

    private static let plexServerID = "plex-machine-1"
    private static let embyServerID = "emby-server-1"
    private static let embyURL = "http://127.0.0.1:9"

    /// Rating keys shaped like the device logs: Plex keys are big integers, Emby's are small.
    private func movie(ratingKey: String, title: String, serverID: String) -> PlexMediaItem {
        PlexMediaItem(
            id: ratingKey, title: title, artist: nil, episodeTitle: nil, seTag: nil,
            summary: "", year: 1991, originallyAvailableAt: nil, contentRating: "PG",
            duration: 95, ratingKey: ratingKey, partKey: nil, container: "mp4",
            videoCodec: "h264", audioCodec: "aac", videoProfile: nil, bitrate: 4000,
            genres: ["Action", "Adventure"], rating: 7, userRating: 0, type: .movie,
            thumb: nil, art: nil, viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil,
            imdbID: nil, librarySource: .movie, serverID: serverID)
    }

    private func plexItems() -> [PlexMediaItem] {
        (0..<8).map { movie(ratingKey: "\(49_000 + $0)", title: "Plex Film \($0)", serverID: Self.plexServerID) }
    }

    private func embyItems() -> [PlexMediaItem] {
        (0..<8).map { movie(ratingKey: "\(3_000 + $0)", title: "Emby Film \($0)", serverID: Self.embyServerID) }
    }

    private var plexServer: AppState.ServerRef {
        AppState.ServerRef(machineIdentifier: Self.plexServerID, name: "Den", baseURL: "http://127.0.0.1:9", owned: true, token: "srv")
    }

    private var embyAuth: EmbyAPIService.AuthResult {
        EmbyAPIService.AuthResult(accessToken: "emby-token", userId: "emby-user", serverID: Self.embyServerID, serverName: "Emby")
    }

    private var store = InMemoryStore()

    override func setUp() {
        super.setUp()
        store = InMemoryStore()
        LibrarySnapshotStore.clear()
        DailyManifestStore.clearAll()
        // First load builds every configured channel; later loads only the enabled bundles.
        // Start from a fresh install either way.
        UserDefaults.standard.removeObject(forKey: AppState.initialLoadCompleteKey)
        UserDefaults.standard.set(["nostalgex"], forKey: "nostalgex_enabled_bundles")
    }

    override func tearDown() {
        LibrarySnapshotStore.clear()
        DailyManifestStore.clearAll()
        UserDefaults.standard.removeObject(forKey: AppState.initialLoadCompleteKey)
        super.tearDown()
    }

    /// A signed-in Plex session with a loaded library, the state a device is in before
    /// the user opens Settings.
    private func makePlexSession(plexBackend: FakeBackend, embyBackend: FakeBackend) async -> AppState {
        let state = AppState(credentialStore: store)
        state.backendOverride = { server in
            server?.machineIdentifier == Self.plexServerID ? plexBackend : embyBackend
        }
        state.completePlexSignIn(token: "plex-account-token", servers: [plexServer])
        await state.loadLibrary()
        XCTAssertEqual(state.backendKind, .plex)
        XCTAssertFalse(state.channels.isEmpty, "the Plex fixture must land in at least one channel")
        XCTAssertTrue(state.allItems.allSatisfy { $0.serverID == Self.plexServerID })
        return state
    }

    // MARK: - Assertions

    /// Everything the guide and the player can reach must belong to the connected server.
    private func assertOnlyEmbyIsServable(_ state: AppState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.backendKind, .emby, file: file, line: line)
        XCTAssertEqual(state.selectedServers.map(\.machineIdentifier), [Self.embyServerID], file: file, line: line)

        let foreignItems = state.allItems.filter { $0.serverID != Self.embyServerID }
        XCTAssertTrue(foreignItems.isEmpty,
                      "allItems carries \(foreignItems.count) item(s) from the disconnected server: \(foreignItems.prefix(3).map(\.title))",
                      file: file, line: line)
        XCTAssertFalse(state.allItems.isEmpty, "the Emby library should have loaded", file: file, line: line)

        for channel in state.channels {
            let foreignPool = channel.filteredPool().filter { $0.serverID != Self.embyServerID }
            XCTAssertTrue(foreignPool.isEmpty,
                          "CH \(channel.number) \(channel.name) pool holds \(foreignPool.count) Plex item(s)",
                          file: file, line: line)

            let schedule = ChannelScheduleBuilder.buildSchedule(
                for: channel, credentialFingerprint: state.scheduleCredentialFingerprint)
            let foreignEntries = (schedule?.entries ?? []).filter { $0.item.serverID != Self.embyServerID }
            XCTAssertTrue(foreignEntries.isEmpty,
                          "CH \(channel.number) \(channel.name) schedule would send \(foreignEntries.count) Plex key(s) to Emby: \(foreignEntries.prefix(3).map(\.item.ratingKey))",
                          file: file, line: line)
            if let now = schedule?.nowPlaying {
                XCTAssertEqual(now.item.serverID, Self.embyServerID,
                               "CH \(channel.number) is about to play \(now.item.title) (\(now.item.ratingKey)) from the wrong server",
                               file: file, line: line)
            }
        }

        // The snapshot written under the Emby identity is what the next launch restores.
        // Plex items in there make the breakage permanent.
        do {
            let loaded = try LibrarySnapshotStore.loadSnapshot(identity: state.snapshotIdentitySeed)
            let snapshotForeign = (loaded?.snapshot.allItems ?? []).filter { $0.serverID != Self.embyServerID }
            XCTAssertTrue(snapshotForeign.isEmpty,
                          "snapshot under the Emby identity holds \(snapshotForeign.count) Plex item(s), so a relaunch restores the broken state",
                          file: file, line: line)
        } catch {
            XCTFail("snapshot under the Emby identity did not decode: \(error)", file: file, line: line)
        }
    }

    // MARK: - The device sequence

    /// Plex signed in, library loaded, Disconnect, Emby connected. No concurrent work.
    func testCleanSwitchServesOnlyEmby() async {
        let plex = FakeBackend(serverID: Self.plexServerID, items: plexItems())
        let emby = FakeBackend(serverID: Self.embyServerID, items: embyItems())
        let state = await makePlexSession(plexBackend: plex, embyBackend: emby)

        state.disconnect()
        XCTAssertFalse(state.hasCredentials)
        XCTAssertTrue(state.channels.isEmpty)

        await state.completeEmbyAuth(serverURL: Self.embyURL, result: embyAuth)

        assertOnlyEmbyIsServable(state)
    }

    /// The launch the device actually had: a >6h-old Plex snapshot restored, which starts a
    /// background refresh of the whole Plex library (minutes on 11,650 items). The user
    /// disconnects and connects Emby while that scan is still running. When the Plex scan
    /// finishes it must not be allowed to land in the Emby session.
    func testAPlexRefreshStillRunningAtDisconnectCannotLandInTheEmbySession() async {
        let plexGate = Gate()
        let plex = FakeBackend(serverID: Self.plexServerID, items: plexItems(), gate: plexGate)
        let emby = FakeBackend(serverID: Self.embyServerID, items: embyItems())
        // The first (seed) load must not block: open a private gate for it by using an
        // ungated backend, then swap in the gated one for the refresh.
        let seedPlex = FakeBackend(serverID: Self.plexServerID, items: plexItems())
        let state = await makePlexSession(plexBackend: seedPlex, embyBackend: emby)
        state.backendOverride = { server in
            server?.machineIdentifier == Self.plexServerID ? plex : emby
        }

        // What Plex90App does when the restored snapshot is stale.
        let refresh = Task { await state.loadLibrary(background: true) }
        await plexGate.waitUntilEntered()
        XCTAssertTrue(state.isBackgroundRefreshing, "the Plex refresh is in flight")

        // Settings > Disconnect, then connect Emby.
        state.disconnect()
        await state.completeEmbyAuth(serverURL: Self.embyURL, result: embyAuth)
        XCTAssertEqual(state.backendKind, .emby)
        XCTAssertTrue(state.allItems.allSatisfy { $0.serverID == Self.embyServerID },
                      "right after the Emby load, the library is Emby's")

        // The Plex scan now completes.
        await plexGate.open()
        await refresh.value

        assertOnlyEmbyIsServable(state)
    }

    /// Same race, other order: the Plex scan is still running when the Emby load starts and
    /// finishes before it. Whichever load commits last must still be the Emby one.
    func testAPlexRefreshFinishingDuringTheEmbyLoadCannotLandEither() async {
        let plexGate = Gate()
        let embyGate = Gate()
        let plex = FakeBackend(serverID: Self.plexServerID, items: plexItems(), gate: plexGate)
        let emby = FakeBackend(serverID: Self.embyServerID, items: embyItems(), gate: embyGate)
        let seedPlex = FakeBackend(serverID: Self.plexServerID, items: plexItems())
        let state = await makePlexSession(plexBackend: seedPlex, embyBackend: emby)
        state.backendOverride = { server in
            server?.machineIdentifier == Self.plexServerID ? plex : emby
        }

        let refresh = Task { await state.loadLibrary(background: true) }
        await plexGate.waitUntilEntered()

        state.disconnect()
        let embyConnect = Task { await state.completeEmbyAuth(serverURL: Self.embyURL, result: self.embyAuth) }
        await embyGate.waitUntilEntered()

        // Plex lands while Emby's scan is still out.
        await plexGate.open()
        await refresh.value
        await embyGate.open()
        await embyConnect.value

        assertOnlyEmbyIsServable(state)
    }

    // MARK: - Belt and braces: items from a server that is not signed in

    func testAnItemFromAServerThatIsNotSignedInIsRefused() {
        let state = AppState(credentialStore: store)
        state.backendKind = .emby
        state.setSelectedServers([AppState.ServerRef(
            machineIdentifier: Self.embyServerID, name: "Emby", baseURL: Self.embyURL,
            owned: true, token: "t", userId: "emby-user")])

        XCTAssertTrue(state.itemBelongsToConnectedServers(movie(ratingKey: "3075", title: "Wayne's World 2", serverID: Self.embyServerID)))
        XCTAssertFalse(state.itemBelongsToConnectedServers(movie(ratingKey: "49689", title: "Richie Rich", serverID: Self.plexServerID)),
                       "a Plex key must never be routed to Emby just because Emby is what is connected now")
    }

    func testItemsWithoutAServerIDAreStillAccepted() {
        // Demo mode, the App Review repro and pre-multi-server snapshots stamp no id.
        let state = AppState(credentialStore: store)
        state.backendKind = .plex
        state.setSelectedServers([plexServer])
        XCTAssertTrue(state.itemBelongsToConnectedServers(movie(ratingKey: "1", title: "Legacy", serverID: "")))
        var legacy = movie(ratingKey: "1", title: "Legacy", serverID: "")
        legacy.serverID = nil
        XCTAssertTrue(state.itemBelongsToConnectedServers(legacy))
    }

    func testALegacyURLStampedItemMatchesTheSameHost() {
        // A pre-multi-server install keyed its server by URL; discovery later keyed the same
        // server by machine id. Same host and port is the same server, not a foreign one.
        let state = AppState(credentialStore: store)
        state.backendKind = .plex
        state.setSelectedServers([AppState.ServerRef(
            machineIdentifier: "abc123", name: "Den", baseURL: "http://192.168.1.10:32400", owned: true, token: "t")])
        XCTAssertTrue(state.itemBelongsToConnectedServers(movie(ratingKey: "1", title: "Old", serverID: "http://192.168.1.10:32400")))
        XCTAssertFalse(state.itemBelongsToConnectedServers(movie(ratingKey: "1", title: "Other", serverID: "http://192.168.1.99:32400")))
    }

    /// A device already in the broken state has a snapshot full of Plex items saved under
    /// the Emby identity. Restoring it must be refused so the next launch rescans Emby.
    func testAPoisonedSnapshotIsNotRestoredAndTriggersARescan() async {
        let emby = FakeBackend(serverID: Self.embyServerID, items: embyItems())
        let state = AppState(credentialStore: store)
        state.backendOverride = { _ in emby }
        state.backendKind = .emby
        state.token = "emby-token"
        state.jellyfinUserId = "emby-user"
        state.serverURL = Self.embyURL
        state.setSelectedServers([AppState.ServerRef(
            machineIdentifier: Self.embyServerID, name: "Emby", baseURL: Self.embyURL,
            owned: true, token: "emby-token", userId: "emby-user")])

        // What the unguarded Plex scan wrote: Plex items under the Emby identity.
        let poisonedChannel = Channel(id: 7, number: 7, name: "VHS VAULT", color: .blue, category: nil,
                                      rules: nil, timeRestrictions: nil, minItems: 0, itemPool: plexItems())
        try? LibrarySnapshotStore.save(
            identity: state.snapshotIdentitySeed, serverName: "Emby", librarySignature: nil,
            lastLoadAtUnix: Int(Date().timeIntervalSince1970), allItems: plexItems(),
            channelConfigChannels: [poisonedChannel], allChannels: [poisonedChannel],
            bundles: [], enabledBundleIDs: [], exclusiveRules: [], discoveredCollections: [])

        let restored = await state.restoreLibraryFromSnapshotIfNeeded()
        XCTAssertFalse(restored, "a snapshot of another server's items is not a restore")
        XCTAssertTrue(state.allItems.isEmpty)
        XCTAssertTrue(state.channels.isEmpty)
        XCTAssertNil(try? LibrarySnapshotStore.loadSnapshot(identity: state.snapshotIdentitySeed),
                     "the poisoned snapshot is gone so it cannot come back next launch")

        // The launch path then runs a full load, which is the Emby library.
        await state.loadLibrary()
        assertOnlyEmbyIsServable(state)
    }

    /// Disconnect removes the outgoing sign-in's day schedules, and names the right
    /// directory: the fingerprint has to be read before the credentials are reset.
    func testDisconnectRemovesTheOutgoingSessionsManifests() async {
        let plex = FakeBackend(serverID: Self.plexServerID, items: plexItems())
        let emby = FakeBackend(serverID: Self.embyServerID, items: embyItems())
        let state = await makePlexSession(plexBackend: plex, embyBackend: emby)
        let plexFP = state.scheduleCredentialFingerprint

        guard let channel = state.channels.first else { return XCTFail("no channel") }
        _ = ChannelScheduleBuilder.buildSchedule(for: channel, credentialFingerprint: plexFP)
        let dir = LocalStore.rootDirectory!
            .appendingPathComponent("daily_manifests", isDirectory: true)
            .appendingPathComponent(plexFP, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "a schedule was written for the Plex session")

        state.disconnect()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "the Plex session's manifests should be gone")
        XCTAssertNotEqual(state.scheduleCredentialFingerprint, plexFP)
    }

    // MARK: - Manifest store on its own

    /// The day manifests are keyed per credential fingerprint and resolve against the
    /// channel's pool, so by themselves they cannot hand a Plex key to an Emby session.
    /// Kept as a measurement: the leak is not here.
    func testManifestStoreCannotServeAPlexKeyUnderTheEmbyFingerprint() {
        let plexFP = LibrarySnapshotStore.fingerprint(identity: "plex|\(Self.plexServerID)")
        let embyFP = LibrarySnapshotStore.fingerprint(identity: "emby|\(Self.embyURL)|emby-user")
        XCTAssertNotEqual(plexFP, embyFP)

        var channel = Channel(id: 12, number: 12, name: "ACTION ADVENTURE", color: .blue, category: nil,
                              rules: nil, timeRestrictions: nil, minItems: 0, itemPool: plexItems())
        let plexBlocks = DailyManifestScheduler.blocks(for: channel, credentialFingerprint: plexFP)
        XCTAssertFalse(plexBlocks.isEmpty)

        // Disconnect clears the snapshot; the Emby session has its own fingerprint and pool.
        LibrarySnapshotStore.clear()
        channel.itemPool = embyItems()
        let embyBlocks = DailyManifestScheduler.blocks(for: channel, credentialFingerprint: embyFP)
        XCTAssertFalse(embyBlocks.isEmpty)
        XCTAssertTrue(embyBlocks.allSatisfy { $0.item.serverID == Self.embyServerID })
    }
}
