import XCTest
@testable import Nostalgex

/// I-054: a library section the viewer turns off (onboarding or Settings) must never be
/// fetched during a scan — not fetched and then discarded. These tests drive the real
/// sign-in gate (`presentLibrarySelectionOrScan`), the real scan wiring
/// (`excludedSectionKeys(forServerID:)` feeding each backend's `loadLibrary`), and the
/// real Settings toggle (`toggleLibrarySection`) against a backend instrumented to
/// record which section keys it actually fetched — the proof is in that log, not just
/// in the final item list, which a post-hoc filter could also produce.
@MainActor
final class LibrarySelectionTests: XCTestCase {

    // MARK: - Fixtures

    private final class InMemoryStore: Nostalgex.CredentialStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        @discardableResult
        func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    /// Hands back canned items per section and records every section key it actually
    /// fetched items for, in call order. A key missing from that log was skipped before
    /// any request for it went out — not requested and discarded afterward.
    private final class SectionAwareBackend: MediaBackend, @unchecked Sendable {
        let serverID: String
        let sections: [PlexSection]
        let itemsBySection: [String: [PlexMediaItem]]
        private(set) var fetchedSectionKeys: [String] = []
        var authHeaders: [String: String] { [:] }

        init(serverID: String, sections: [PlexSection], itemsBySection: [String: [PlexMediaItem]]) {
            self.serverID = serverID
            self.sections = sections
            self.itemsBySection = itemsBySection
        }

        func testConnection() async throws -> String { serverID }
        func loadSections() async throws -> [PlexSection] { sections }
        func loadLibrary(excludedSectionKeys: Set<String> = [], progress: LoadProgress? = nil) async throws -> [PlexMediaItem] {
            var items: [PlexMediaItem] = []
            for section in sections where !excludedSectionKeys.contains(section.key) {
                fetchedSectionKeys.append(section.key)
                items.append(contentsOf: itemsBySection[section.key] ?? [])
            }
            return items
        }
        func loadCollections(sectionKey: String) async throws -> [PlexCollection] { [] }
        func loadCollectionItems(collectionKey: String) async throws -> [String] { [] }
        func buildDirectPlayURL(for item: PlexMediaItem) -> URL? { nil }
        func buildTranscodeURL(for item: PlexMediaItem) -> URL? { nil }
        func thumbnailURL(for item: PlexMediaItem, width: Int) -> URL? { nil }
    }

    private func movie(ratingKey: String, title: String, serverID: String) -> PlexMediaItem {
        PlexMediaItem(
            id: ratingKey, title: title, artist: nil, episodeTitle: nil, seTag: nil,
            summary: "", year: 1991, originallyAvailableAt: nil, contentRating: "PG",
            duration: 95, ratingKey: ratingKey, partKey: nil, container: "mp4",
            videoCodec: "h264", audioCodec: "aac", videoProfile: nil, bitrate: 4000,
            genres: ["Action"], rating: 7, userRating: 0, type: .movie,
            thumb: nil, art: nil, viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil,
            imdbID: nil, librarySource: .movie, serverID: serverID)
    }

    private let server = AppState.ServerRef(
        machineIdentifier: "srv-1", name: "Den", baseURL: "http://127.0.0.1:9", owned: true, token: "t"
    )

    private var store = InMemoryStore()

    override func setUp() {
        super.setUp()
        store = InMemoryStore()
        LibrarySnapshotStore.clear()
        DailyManifestStore.clearAll()
        UserDefaults.standard.removeObject(forKey: AppState.initialLoadCompleteKey)
        UserDefaults.standard.removeObject(forKey: "nostalgex_deselected_library_sections")
        UserDefaults.standard.set(["nostalgex"], forKey: "nostalgex_enabled_bundles")
    }

    override func tearDown() {
        LibrarySnapshotStore.clear()
        DailyManifestStore.clearAll()
        UserDefaults.standard.removeObject(forKey: AppState.initialLoadCompleteKey)
        UserDefaults.standard.removeObject(forKey: "nostalgex_deselected_library_sections")
        super.tearDown()
    }

    /// `toggleLibrarySection`/`confirmLibrarySelection` kick off the reload as a
    /// fire-and-forget `Task`, the same pattern `toggleServer` already uses. Polls with
    /// a short bound rather than asserting the instant the call returns.
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Onboarding: shows for >1 section, skips for exactly 1

    func testScreenShowsWhenBackendHasMultipleSections() async {
        let backend = SectionAwareBackend(
            serverID: server.machineIdentifier,
            sections: [
                PlexSection(key: "1", title: "Movies", type: "movie"),
                PlexSection(key: "2", title: "TV Shows", type: "show"),
            ],
            itemsBySection: [:]
        )
        let state = AppState(credentialStore: store)
        state.backendOverride = { _ in backend }
        state.completePlexSignIn(token: "acct", servers: [server])

        await state.presentLibrarySelectionOrScan()

        XCTAssertTrue(state.needsLibrarySelection, "a backend with more than one section must show the picker")
        XCTAssertEqual(Set(state.pendingLibrarySections.map(\.sectionKey)), ["1", "2"])
        XCTAssertTrue(state.allItems.isEmpty, "the scan must not start until the picker is confirmed")
    }

    func testScreenSkippedWhenBackendHasOneSection() async {
        let backend = SectionAwareBackend(
            serverID: server.machineIdentifier,
            sections: [PlexSection(key: "1", title: "Movies", type: "movie")],
            itemsBySection: ["1": [movie(ratingKey: "m1", title: "Only Movie", serverID: server.machineIdentifier)]]
        )
        let state = AppState(credentialStore: store)
        state.backendOverride = { _ in backend }
        state.completePlexSignIn(token: "acct", servers: [server])

        await state.presentLibrarySelectionOrScan()

        XCTAssertFalse(state.needsLibrarySelection, "a single-section backend must see no new screen")
        XCTAssertEqual(backend.fetchedSectionKeys, ["1"], "the one section must still be scanned automatically — no behavior change")
    }

    // MARK: - Exclusion is real: a deselected section is never fetched by the scan

    func testDeselectedSectionInOnboardingIsNeverFetched() async {
        let keepItem = movie(ratingKey: "m1", title: "Kept Movie", serverID: server.machineIdentifier)
        let droppedItem = movie(ratingKey: "m2", title: "Dropped Show", serverID: server.machineIdentifier)
        let backend = SectionAwareBackend(
            serverID: server.machineIdentifier,
            sections: [
                PlexSection(key: "1", title: "Movies", type: "movie"),
                PlexSection(key: "2", title: "Huge TV Library", type: "show"),
            ],
            itemsBySection: ["1": [keepItem], "2": [droppedItem]]
        )
        let state = AppState(credentialStore: store)
        state.backendOverride = { _ in backend }
        state.completePlexSignIn(token: "acct", servers: [server])

        await state.presentLibrarySelectionOrScan()
        XCTAssertTrue(state.needsLibrarySelection)
        let keptSectionID = state.pendingLibrarySections.first { $0.sectionKey == "1" }!.id

        state.confirmLibrarySelection(includedIDs: [keptSectionID])
        await waitUntil { !state.allItems.isEmpty || state.errorMessage != nil }

        XCTAssertFalse(state.needsLibrarySelection)
        XCTAssertEqual(state.allItems.map(\.ratingKey), ["m1"])
        XCTAssertEqual(backend.fetchedSectionKeys, ["1"], "section 2 must never be fetched, not fetched then discarded")
        XCTAssertFalse(backend.fetchedSectionKeys.contains("2"))
    }

    // MARK: - Settings toggle: clears the snapshot immediately, reloads without the section

    func testSettingsToggleClearsSnapshotAndReloadsWithoutTheSection() async {
        let keepItem = movie(ratingKey: "m1", title: "Kept Movie", serverID: server.machineIdentifier)
        let droppedItem = movie(ratingKey: "m2", title: "Dropped Show", serverID: server.machineIdentifier)
        let backend = SectionAwareBackend(
            serverID: server.machineIdentifier,
            sections: [
                PlexSection(key: "1", title: "Movies", type: "movie"),
                PlexSection(key: "2", title: "TV Shows", type: "show"),
            ],
            itemsBySection: ["1": [keepItem], "2": [droppedItem]]
        )
        let state = AppState(credentialStore: store)
        state.backendOverride = { _ in backend }
        state.completePlexSignIn(token: "acct", servers: [server])
        await state.loadLibrary()
        LibrarySnapshotStore.waitForPendingSaves()

        XCTAssertEqual(Set(state.allItems.map(\.ratingKey)), ["m1", "m2"])
        XCTAssertNotNil(try? LibrarySnapshotStore.loadIfValid(identity: state.snapshotIdentitySeed), "a fresh load must leave a snapshot behind")

        await state.refreshAvailableLibrarySections()
        let sectionB = state.librarySectionsForSettings.first { $0.sectionKey == "2" }!
        let fetchCountBeforeToggle = backend.fetchedSectionKeys.count

        state.toggleLibrarySection(sectionB)

        // Synchronous: the snapshot clear runs before the reload Task is even spawned,
        // so this must already be gone the instant the call returns — not eventually,
        // once some background reload gets around to it.
        XCTAssertNil(try? LibrarySnapshotStore.loadIfValid(identity: state.snapshotIdentitySeed), "toggling a section must clear the snapshot immediately")
        XCTAssertTrue(state.isLibrarySectionDeselected(sectionB))

        await waitUntil { !state.allItems.contains(where: { $0.ratingKey == "m2" }) }

        XCTAssertEqual(state.allItems.map(\.ratingKey), ["m1"], "the toggle must trigger a reload that excludes the turned-off section")
        let fetchedSincetoggle = backend.fetchedSectionKeys[fetchCountBeforeToggle...]
        XCTAssertFalse(fetchedSincetoggle.contains("2"), "the reload itself must not fetch the turned-off section either")
    }

    // MARK: - Keep at least one section on

    func testCannotTurnOffTheLastEnabledSection() async {
        let item = movie(ratingKey: "m1", title: "Only Movie", serverID: server.machineIdentifier)
        let backend = SectionAwareBackend(
            serverID: server.machineIdentifier,
            sections: [PlexSection(key: "1", title: "Movies", type: "movie")],
            itemsBySection: ["1": [item]]
        )
        let state = AppState(credentialStore: store)
        state.backendOverride = { _ in backend }
        state.completePlexSignIn(token: "acct", servers: [server])
        await state.loadLibrary()
        await state.refreshAvailableLibrarySections()

        let onlySection = state.librarySectionsForSettings.first!
        XCTAssertEqual(state.enabledLibrarySectionCount, 1)

        state.toggleLibrarySection(onlySection)

        XCTAssertFalse(state.isLibrarySectionDeselected(onlySection), "the last enabled section must not be turned off")
        XCTAssertTrue(state.deselectedLibrarySectionKeys.isEmpty)
    }
}
