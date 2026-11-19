import XCTest
@testable import Nostalgex

/// Closing the app on CHOOSE YOUR LIBRARIES and opening it again used to skip the picker and read every library:
/// the sign-in is saved before the picker shows, and the picker itself lives only in memory. The viewer still owes the
/// choice, so `LibrarySectionSelectionStore.pickOwed` is saved with the sign-in and a launch resumes the picker.
///
/// A relaunch is a second `AppState` over the same credential store and defaults, driven through what RootView's
/// launch does: `hydrateCredentialsWithRetry`, then `resumeLibraryPickIfOwed`, then the usual launch load.
@MainActor
final class PickerOwedTests: XCTestCase {

    private final class InMemoryStore: Nostalgex.CredentialStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        @discardableResult
        func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    /// Records every section key it was asked to read items from.
    private final class RecordingBackend: MediaBackend, @unchecked Sendable {
        let serverID: String
        let sections: [PlexSection]
        var sectionsReadable = true
        /// Runs while the sections are being read, as a viewer pressing a button would.
        nonisolated(unsafe) var whileReadingSections: (@Sendable @MainActor () -> Void)?
        private let lock = NSLock()
        private var fetched: [String] = []
        var fetchedSectionKeys: [String] { lock.withLock { fetched } }
        var authHeaders: [String: String] { [:] }
        init(serverID: String, sections: [PlexSection]) { self.serverID = serverID; self.sections = sections }
        func testConnection() async throws -> String { serverID }
        func loadSections() async throws -> [PlexSection] {
            if let hook = whileReadingSections { await hook() }
            if !sectionsReadable { throw PlexAPIService.APIError.invalidResponse }
            return sections
        }
        func loadLibrary(excludedSectionKeys: Set<String> = [], progress: LoadProgress? = nil) async throws -> [PlexMediaItem] {
            var items: [PlexMediaItem] = []
            for section in sections where !excludedSectionKeys.contains(section.key) {
                lock.withLock { fetched.append(section.key) }
                items.append(PickerOwedTests.movie(key: "m-\(section.key)", serverID: serverID))
            }
            return items
        }
        func loadCollections(sectionKey: String) async throws -> [PlexCollection] { [] }
        func loadCollectionItems(collectionKey: String) async throws -> [String] { [] }
        func buildDirectPlayURL(for item: PlexMediaItem) -> URL? { nil }
        func buildTranscodeURL(for item: PlexMediaItem) -> URL? { nil }
        func thumbnailURL(for item: PlexMediaItem, width: Int) -> URL? { nil }
    }

    private nonisolated static func movie(key: String, serverID: String) -> PlexMediaItem {
        PlexMediaItem(
            id: key, title: "Film \(key)", artist: nil, episodeTitle: nil, seTag: nil,
            summary: "", year: 1991, originallyAvailableAt: nil, contentRating: "PG",
            duration: 95, ratingKey: key, partKey: nil, container: "mp4",
            videoCodec: "h264", audioCodec: "aac", videoProfile: nil, bitrate: 4000,
            genres: ["Action"], rating: 7, userRating: 0, type: .movie,
            thumb: nil, art: nil, viewCount: 0, addedAt: 0, studio: nil, tmdbID: nil,
            imdbID: nil, librarySource: .movie, serverID: serverID)
    }

    private let server = AppState.ServerRef(
        machineIdentifier: "srv-1", name: "Den", baseURL: "http://127.0.0.1:9", owned: true, token: "t")

    private var store = InMemoryStore()
    private var backend: RecordingBackend!

    private func twoLibraries() -> RecordingBackend {
        RecordingBackend(serverID: server.machineIdentifier, sections: [
            PlexSection(key: "1", title: "Movies", type: "movie"),
            PlexSection(key: "2", title: "Cartoons", type: "movie"),
        ])
    }

    override func setUp() {
        super.setUp()
        store = InMemoryStore()
        backend = twoLibraries()
        reset()
    }

    override func tearDown() { reset(); super.tearDown() }

    private func reset() {
        LibrarySnapshotStore.clear()
        DailyManifestStore.clearAll()
        UserDefaults.standard.removeObject(forKey: AppState.initialLoadCompleteKey)
        AppDefaults.standard.removeObject(forKey: "nostalgex_deselected_library_sections")
        AppDefaults.standard.removeObject(forKey: "nostalgex_library_pick_owed")
    }

    /// The first launch: signed in, picker showing, nothing chosen.
    private func signInToThePicker() async -> AppState {
        let first = AppState(credentialStore: store)
        first.backendOverride = { [backend] _ in backend! }
        first.completePlexSignIn(token: "acct", servers: [server])
        await first.presentLibrarySelectionOrScan()
        return first
    }

    /// Closing the app: a new AppState over the same stores, hydrated as RootView does.
    private func relaunch() async -> AppState {
        let next = AppState(credentialStore: store)
        next.backendOverride = { [backend] _ in backend! }
        await next.hydrateCredentialsWithRetry()
        return next
    }

    func testClosingTheAppOnThePickerBringsThePickerBack() async {
        let first = await signInToThePicker()
        XCTAssertTrue(first.needsLibrarySelection, "setup: the picker is up")
        XCTAssertTrue(LibrarySectionSelectionStore.pickOwed)

        let second = await relaunch()
        let resumed = await second.resumeLibraryPickIfOwed()

        XCTAssertTrue(resumed)
        XCTAssertTrue(second.needsLibrarySelection, "the picker must come back")
        XCTAssertEqual(Set(second.pendingLibrarySections.map(\.sectionKey)), ["1", "2"])
        XCTAssertTrue(backend.fetchedSectionKeys.isEmpty, "no library may be read before the choice: \(backend.fetchedSectionKeys)")
        XCTAssertFalse(second.isResumingLibraryPick)
    }

    func testClosingTheAppTwiceOnThePickerStillBringsItBack() async {
        _ = await signInToThePicker()
        _ = await relaunch().resumeLibraryPickIfOwed()
        let third = await relaunch()
        let resumed = await third.resumeLibraryPickIfOwed()
        XCTAssertTrue(resumed)
        XCTAssertTrue(third.needsLibrarySelection)
        XCTAssertTrue(backend.fetchedSectionKeys.isEmpty)
    }

    func testContinuingClearsTheChoiceOwed() async {
        let first = await signInToThePicker()
        let kept = first.pendingLibrarySections.first { $0.sectionKey == "1" }!.id
        first.confirmLibrarySelection(includedIDs: [kept])
        XCTAssertFalse(LibrarySectionSelectionStore.pickOwed)

        let second = await relaunch()
        let resumed = await second.resumeLibraryPickIfOwed()
        XCTAssertFalse(resumed, "a made choice is not asked for again")
        XCTAssertFalse(second.needsLibrarySelection)
        XCTAssertEqual(LibrarySectionSelectionStore.load(), [LibrarySectionRef(
            serverID: server.machineIdentifier, serverName: "Den", sectionKey: "2", title: "Cartoons", type: "movie").id],
            "the choice made is the one a relaunch keeps")
    }

    func testASignInWithNothingToChooseIsNeverOwed() async {
        backend = RecordingBackend(serverID: server.machineIdentifier, sections: [PlexSection(key: "1", title: "Movies", type: "movie")])
        let first = await signInToThePicker()
        XCTAssertFalse(first.needsLibrarySelection)
        XCTAssertFalse(LibrarySectionSelectionStore.pickOwed)
        let second = await relaunch()
        let resumed = await second.resumeLibraryPickIfOwed()
        XCTAssertFalse(resumed)
    }

    func testSigningOutClearsTheChoiceOwed() async {
        let first = await signInToThePicker()
        XCTAssertTrue(LibrarySectionSelectionStore.pickOwed)
        first.clearCredentials()
        XCTAssertFalse(LibrarySectionSelectionStore.pickOwed)
    }

    func testARelaunchThatCannotReadTheLibrariesKeepsTheChoiceOwed() async {
        _ = await signInToThePicker()
        backend.sectionsReadable = false
        let second = await relaunch()
        _ = await second.resumeLibraryPickIfOwed()
        XCTAssertTrue(LibrarySectionSelectionStore.pickOwed, "an unreachable server must not turn into a pick that was never made")

        backend.sectionsReadable = true
        let third = await relaunch()
        let resumed = await third.resumeLibraryPickIfOwed()
        XCTAssertTrue(resumed)
        XCTAssertTrue(third.needsLibrarySelection, "once the server answers, the picker is shown")
    }

    func testTheServerReadShowsTheStepRailSoSTARTOVERIsThere() async {
        _ = await signInToThePicker()
        let second = await relaunch()
        nonisolated(unsafe) var message = ""
        nonisolated(unsafe) var resuming = false
        nonisolated(unsafe) var mode = LoadingScreenMode.splash
        backend.whileReadingSections = { [unowned second] in
            message = second.loadingMessage
            resuming = second.isResumingLibraryPick
            mode = LoadingScreenMode.decide(
                didAttemptCredentialHydration: second.didAttemptCredentialHydration,
                isFirstLibraryLoad: second.isFirstLibraryLoad,
                loadingMessage: second.loadingMessage,
                scanTotalSections: second.scanTotalSections,
                channelBuildTotal: second.channelBuildTotal)
        }
        _ = await second.resumeLibraryPickIfOwed()
        XCTAssertTrue(resuming)
        XCTAssertEqual(message, "FINDING YOUR SERVERS...")
        XCTAssertTrue(mode.showsStepRail, "the bare logo has no START OVER; a server that never answers would trap the viewer")
        XCTAssertEqual(second.loadingMessage, "", "the headline does not outlive the step")
    }

    func testStartingOverWhileTheServerIsBeingReadDoesNotShowThePicker() async {
        _ = await signInToThePicker()
        let second = await relaunch()
        backend.whileReadingSections = { [unowned second] in second.clearCredentials() }
        _ = await second.resumeLibraryPickIfOwed()
        XCTAssertFalse(second.needsLibrarySelection, "signed out meanwhile: no picker for a sign-in that is gone")
        XCTAssertFalse(LibrarySectionSelectionStore.pickOwed)
        XCTAssertTrue(backend.fetchedSectionKeys.isEmpty)
    }

    func testAnOrdinaryRelaunchIsUntouched() async {
        let signedIn = AppState(credentialStore: store)
        signedIn.backendOverride = { [backend] _ in backend! }
        signedIn.completePlexSignIn(token: "acct", servers: [server])
        let relaunched = await relaunch()
        let resumed = await relaunched.resumeLibraryPickIfOwed()
        XCTAssertFalse(resumed, "no pick owed, so the launch goes on to the library as before")
    }
}
