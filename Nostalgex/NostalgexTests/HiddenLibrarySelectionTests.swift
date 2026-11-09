import XCTest
@testable import Nostalgex

/// A library the user hides from the Jellyfin home screen is listed in LIBRARIES and in the
/// onboarding picker, marked, and OFF until the viewer switches it on. `LibrarySectionSelectionStore.
/// hiddenSectionsOnByDefault` is the one constant behind that. Everything the viewer already has is
/// left as it was: a library that is not hidden follows the same opt-out as before.
///
/// Most tests set the default on the AppState they use (`hiddenSectionsOnByDefault`), so they do not
/// change when the constant does. Two tests read the shipped constant (`testTheShippedDefault...`);
/// flipping it is one line plus those two.
@MainActor
final class HiddenLibrarySelectionTests: XCTestCase {

    private final class InMemoryStore: Nostalgex.CredentialStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        @discardableResult func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    private final class SpyAnalytics: AnalyticsService, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(name: String, parameters: [String: String])] = []
        var calls: [(name: String, parameters: [String: String])] { lock.lock(); defer { lock.unlock() }; return _calls }
        func configure() {}
        func track(_ event: AnalyticsEvent, contextParameters: [String: String]) {
            lock.lock(); _calls.append((event.name, event.parameters)); lock.unlock()
        }
    }

    /// Answers `loadSections` with a library on the home screen and one the user hides (or only
    /// the hidden one), and records nothing else.
    private final class Backend: MediaBackend, @unchecked Sendable {
        let serverID = "srv-1"
        var authHeaders: [String: String] { [:] }
        let sections: [PlexSection]
        init(onlyHidden: Bool = false) {
            var hidden = PlexSection(key: "hidden", title: "Plugin Films", type: "movie")
            hidden.hidden = true
            sections = onlyHidden ? [hidden] : [PlexSection(key: "shown", title: "Movies", type: "movie"), hidden]
        }
        func testConnection() async throws -> String { serverID }
        func loadSections() async throws -> [PlexSection] { sections }
        func loadLibrary(excludedSectionKeys: Set<String> = [], progress: LoadProgress? = nil) async throws -> [PlexMediaItem] { [] }
        private let lock = NSLock()
        private var _collectionSectionKeys: [String] = []
        /// The sections the collection sweep asked for collections, in order.
        var collectionSectionKeys: [String] { lock.lock(); defer { lock.unlock() }; return _collectionSectionKeys }
        func loadCollections(sectionKey: String) async throws -> [PlexCollection] {
            lock.lock(); _collectionSectionKeys.append(sectionKey); lock.unlock()
            return []
        }
        func loadCollectionItems(collectionKey: String) async throws -> [String] { [] }
        func buildDirectPlayURL(for item: PlexMediaItem) -> URL? { nil }
        func buildTranscodeURL(for item: PlexMediaItem) -> URL? { nil }
        func thumbnailURL(for item: PlexMediaItem, width: Int) -> URL? { nil }
    }

    private let server = AppState.ServerRef(
        machineIdentifier: "srv-1", name: "Den", baseURL: "http://127.0.0.1:9", owned: true, token: "t")

    private func signedIn(onByDefault: Bool, onlyHidden: Bool = false) -> AppState {
        let state = AppState(credentialStore: InMemoryStore())
        state.hiddenSectionsOnByDefault = onByDefault
        state.backendOverride = { _ in Backend(onlyHidden: onlyHidden) }
        state.completePlexSignIn(token: "acct", servers: [server])
        return state
    }

    // MARK: Off by default (the opt-in)

    func testAHiddenLibraryIsListedMarkedAndOff() async {
        let scope = HarnessScope.begin("hidden-lib-listed")
        defer { scope.end() }
        let state = signedIn(onByDefault: false)

        await state.refreshAvailableLibrarySections()
        XCTAssertEqual(state.librarySectionsForSettings.map(\.sectionKey), ["shown", "hidden"])
        let hidden = state.librarySectionsForSettings[1]
        XCTAssertTrue(hidden.isHidden)
        XCTAssertEqual(hidden.subtitle(multiServer: false), "Movies · HIDDEN ON JELLYFIN")
        XCTAssertEqual(state.librarySectionsForSettings[0].subtitle(multiServer: false), "Movies", "a library on the home screen reads as before")
        XCTAssertTrue(state.isLibrarySectionDeselected(hidden), "off until the viewer switches it on")
        XCTAssertFalse(state.isLibrarySectionDeselected(state.librarySectionsForSettings[0]))
        XCTAssertEqual(state.enabledLibrarySectionCount, 1)
    }

    func testSwitchingAHiddenLibraryOnIsRememberedAndReachesTheScan() async {
        let scope = HarnessScope.begin("hidden-lib-toggle")
        defer { scope.end() }
        let state = signedIn(onByDefault: false)
        await state.refreshAvailableLibrarySections()
        let hidden = state.librarySectionsForSettings[1]

        state.toggleLibrarySection(hidden)
        XCTAssertFalse(state.isLibrarySectionDeselected(hidden))
        XCTAssertEqual(state.includedHiddenSectionKeys(forServerID: "srv-1"), ["hidden"], "the raw key the Jellyfin scan knows it by")
        XCTAssertEqual(LibrarySectionSelectionStore.loadIncludedHidden(), [hidden.id], "kept across launches")
        XCTAssertTrue(state.deselectedLibrarySectionKeys.isEmpty, "it is an opt-in, not an opt-out")

        state.toggleLibrarySection(hidden)
        XCTAssertTrue(state.isLibrarySectionDeselected(hidden))
        XCTAssertTrue(state.includedHiddenSectionKeys(forServerID: "srv-1").isEmpty)
        XCTAssertTrue(LibrarySectionSelectionStore.loadIncludedHidden().isEmpty)
    }

    func testALibraryThatIsNotHiddenFollowsTheSameOptOutAsBefore() async {
        let scope = HarnessScope.begin("hidden-lib-regular")
        defer { scope.end() }
        let state = signedIn(onByDefault: false)
        await state.refreshAvailableLibrarySections()
        let hidden = state.librarySectionsForSettings[1]
        state.toggleLibrarySection(hidden)                       // two libraries on, so the other can go off
        let shown = state.librarySectionsForSettings[0]

        state.toggleLibrarySection(shown)
        XCTAssertTrue(state.deselectedLibrarySectionKeys.contains(shown.id))
        XCTAssertEqual(state.excludedSectionKeys(forServerID: "srv-1"), ["shown"])
        XCTAssertEqual(state.includedHiddenLibrarySectionKeys, [hidden.id], "the opt-in is untouched by it")
    }

    func testTheOnboardingPickerListsAHiddenLibraryOffAndOnlyTurnsItOnWhenAsked() async {
        let scope = HarnessScope.begin("hidden-lib-picker")
        defer { scope.end() }
        let state = signedIn(onByDefault: false)

        await state.presentLibrarySelectionOrScan()
        XCTAssertTrue(state.needsLibrarySelection)
        let hidden = state.pendingLibrarySections[1]
        XCTAssertTrue(hidden.isHidden)
        XCTAssertFalse(state.librarySectionStartsOn(hidden), "the picker starts it off")
        XCTAssertTrue(state.librarySectionStartsOn(state.pendingLibrarySections[0]))

        // CONTINUE with the picker's own defaults: the hidden library stays off and nothing else changes.
        let defaults = Set(state.pendingLibrarySections.filter(state.librarySectionStartsOn).map(\.id))
        state.confirmLibrarySelection(includedIDs: defaults)
        XCTAssertTrue(state.includedHiddenLibrarySectionKeys.isEmpty)
        XCTAssertTrue(state.deselectedLibrarySectionKeys.isEmpty)
        XCTAssertTrue(state.includedHiddenSectionKeys(forServerID: "srv-1").isEmpty)
    }

    func testSwitchingItOnInTheOnboardingPickerIsKept() async {
        let scope = HarnessScope.begin("hidden-lib-picker-on")
        defer { scope.end() }
        let state = signedIn(onByDefault: false)

        await state.presentLibrarySelectionOrScan()
        state.confirmLibrarySelection(includedIDs: Set(state.pendingLibrarySections.map(\.id)))
        XCTAssertEqual(state.includedHiddenSectionKeys(forServerID: "srv-1"), ["hidden"])
        XCTAssertTrue(state.deselectedLibrarySectionKeys.isEmpty)
    }

    /// A hidden library that simply stayed off is not something the viewer turned off.
    func testTheConfirmedSignalDoesNotCountAHiddenLibraryThatStayedOff() async {
        let scope = HarnessScope.begin("hidden-lib-signal")
        defer { scope.end() }
        let spy = SpyAnalytics()
        Analytics.configure(with: spy, gate: nil)
        defer { Analytics.configure(with: NoOpAnalytics()) }
        let state = signedIn(onByDefault: false)

        await state.presentLibrarySelectionOrScan()
        state.confirmLibrarySelection(includedIDs: Set(state.pendingLibrarySections.filter(state.librarySectionStartsOn).map(\.id)))
        let confirmed = spy.calls.filter { $0.name == "connect.library_selection.confirmed" }
        XCTAssertEqual(confirmed.count, 1)
        XCTAssertEqual(confirmed.first?.parameters["sectionCount"], "2")
        XCTAssertEqual(confirmed.first?.parameters["excludedCount"], "0")

        // The viewer turning the ordinary library off is an exclusion.
        await state.presentLibrarySelectionOrScan()
        state.confirmLibrarySelection(includedIDs: [state.pendingLibrarySections[1].id])
        XCTAssertEqual(spy.calls.filter { $0.name == "connect.library_selection.confirmed" }.last?.parameters["excludedCount"], "1")
    }

    /// A hidden library alone: nothing else to choose, but it starts off, so without the picker nothing
    /// would be scanned and nothing would offer it.
    func testAHiddenLibraryAloneStillGetsThePicker() async {
        let scope = HarnessScope.begin("hidden-lib-alone")
        defer { scope.end() }
        let state = signedIn(onByDefault: false, onlyHidden: true)

        await state.presentLibrarySelectionOrScan()
        XCTAssertTrue(state.needsLibrarySelection)
        XCTAssertEqual(state.pendingLibrarySections.map(\.sectionKey), ["hidden"])
    }

    /// The collection sweep and any other reader of sections leaves out what the scan leaves out.
    func testSectionsTheScanLeavesOutIncludeAHiddenLibraryUntilItIsSwitchedOn() async {
        let scope = HarnessScope.begin("hidden-lib-sweep")
        defer { scope.end() }
        let state = signedIn(onByDefault: false)
        let sections = Backend().sections

        XCTAssertEqual(state.sectionKeysLeftOutOfScan(sections, forServerID: "srv-1"), ["hidden"])
        state.includedHiddenLibrarySectionKeys = ["srv-1::hidden"]
        XCTAssertTrue(state.sectionKeysLeftOutOfScan(sections, forServerID: "srv-1").isEmpty)
        state.deselectedLibrarySectionKeys = ["srv-1::shown"]
        XCTAssertEqual(state.sectionKeysLeftOutOfScan(sections, forServerID: "srv-1"), ["shown"], "the viewer's own opt-out still applies")
    }

    /// The collection sweep asks each section the scan reads for its collections, and no other.
    func testTheCollectionSweepSkipsAHiddenLibraryUntilItIsSwitchedOn() async {
        let scope = HarnessScope.begin("hidden-lib-collections")
        defer { scope.end() }
        let backend = Backend()
        let state = AppState(credentialStore: InMemoryStore())
        state.hiddenSectionsOnByDefault = false
        state.backendOverride = { _ in backend }
        state.completePlexSignIn(token: "acct", servers: [server])
        state.allItems = [PlexMediaItem(
            id: "m1", title: "A Film", artist: nil, episodeTitle: nil, seTag: nil, summary: "", year: 1991,
            originallyAvailableAt: nil, contentRating: "PG", duration: 95, ratingKey: "m1", partKey: nil,
            container: "mp4", videoCodec: "h264", audioCodec: "aac", videoProfile: nil, bitrate: 4000,
            genres: ["Action"], rating: 7, userRating: 0, type: .movie, thumb: nil, art: nil, viewCount: 0,
            addedAt: 0, studio: nil, tmdbID: nil, imdbID: nil, librarySource: .movie, serverID: "srv-1")]

        await state.scanCollections()
        XCTAssertEqual(backend.collectionSectionKeys, ["shown"], "no collections request for the hidden library")

        state.includedHiddenLibrarySectionKeys = ["srv-1::hidden"]
        await state.scanCollections()
        XCTAssertEqual(backend.collectionSectionKeys, ["shown", "shown", "hidden"], "asked once switched on")
    }

    /// A new sign-in starts from the defaults, as it does for the opt-out set.
    func testANewSignInForgetsWhichHiddenLibrariesWereOn() async {
        let scope = HarnessScope.begin("hidden-lib-signin")
        defer { scope.end() }
        let state = signedIn(onByDefault: false)
        state.includedHiddenLibrarySectionKeys = ["srv-1::hidden"]
        LibrarySectionSelectionStore.saveIncludedHidden(["srv-1::hidden"])

        await state.presentLibrarySelectionOrScan()
        XCTAssertTrue(state.includedHiddenLibrarySectionKeys.isEmpty)
        XCTAssertTrue(LibrarySectionSelectionStore.loadIncludedHidden().isEmpty)
    }

    // MARK: On by default (the opt-out, when the constant is flipped)

    func testWithTheDefaultOnAHiddenLibraryIsOnAndFollowsTheOptOut() async {
        let scope = HarnessScope.begin("hidden-lib-default-on")
        defer { scope.end() }
        let state = signedIn(onByDefault: true)
        await state.refreshAvailableLibrarySections()
        let hidden = state.librarySectionsForSettings[1]

        XCTAssertFalse(state.isLibrarySectionDeselected(hidden), "on until the viewer switches it off")
        XCTAssertTrue(state.librarySectionStartsOn(hidden), "the picker starts it on")
        XCTAssertEqual(state.enabledLibrarySectionCount, 2)
        XCTAssertTrue(state.sectionKeysLeftOutOfScan(Backend().sections, forServerID: "srv-1").isEmpty)

        state.toggleLibrarySection(hidden)
        XCTAssertTrue(state.deselectedLibrarySectionKeys.contains(hidden.id), "off is an opt-out here, like any other library")
        XCTAssertTrue(state.includedHiddenLibrarySectionKeys.isEmpty)
        XCTAssertEqual(state.excludedSectionKeys(forServerID: "srv-1"), ["hidden"])
    }

    // MARK: Nothing hidden, and the shipped default

    /// No hidden libraries: nothing is marked and nothing starts off.
    func testWithNoHiddenLibraryNothingChanges() {
        let section = LibrarySectionRef(serverID: "srv-1", serverName: "Den", sectionKey: "1", title: "Movies", type: "movie")
        XCTAssertFalse(section.isHidden)
        XCTAssertEqual(section.subtitle(multiServer: false), "Movies")
        XCTAssertEqual(section.subtitle(multiServer: true), "Den · Movies")
        for onByDefault in [false, true] {
            let state = AppState(credentialStore: InMemoryStore())
            state.hiddenSectionsOnByDefault = onByDefault
            XCTAssertTrue(state.librarySectionStartsOn(section))
            XCTAssertFalse(state.isLibrarySectionDeselected(section))
        }
    }

    /// Reads the shipped constant and follows it; the one assertion that pins it is in
    /// `JellyfinHiddenLibrariesTests.testTheShippedDefaultIsOff`.
    func testTheShippedDefaultDecidesWhereAHiddenLibraryStarts() {
        let state = AppState(credentialStore: InMemoryStore())
        var hidden = LibrarySectionRef(serverID: "srv-1", serverName: "Den", sectionKey: "h", title: "Plugin Films", type: "movie")
        hidden.isHidden = true
        XCTAssertEqual(state.hiddenSectionsOnByDefault, LibrarySectionSelectionStore.hiddenSectionsOnByDefault)
        XCTAssertEqual(state.librarySectionStartsOn(hidden), LibrarySectionSelectionStore.hiddenSectionsOnByDefault)
        XCTAssertEqual(state.isLibrarySectionDeselected(hidden), !LibrarySectionSelectionStore.hiddenSectionsOnByDefault)
    }
}
