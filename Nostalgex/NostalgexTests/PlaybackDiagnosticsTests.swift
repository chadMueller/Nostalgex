import XCTest
@testable import Nostalgex

final class PlaybackDiagnosticsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "PlaybackDiagnosticsTests"

    override func setUp() { super.setUp(); UserDefaults().removePersistentDomain(forName: suite); defaults = UserDefaults(suiteName: suite) }
    override func tearDown() { UserDefaults().removePersistentDomain(forName: suite); super.tearDown() }

    func testNothingRecordedMeansNothingShown() {
        XCTAssertNil(PlaybackDiagnostics.latestForSettings(defaults: defaults))
        XCTAssertTrue(PlaybackDiagnostics.recent(defaults: defaults).isEmpty)
    }

    func testTheLatestVerdictCarriesWhatSettlesDeviceVersusServer() {
        PlaybackDiagnostics.record(outcome: "skipped to next after 40s", title: "Armageddon",
                                   detail: "ready=true, playhead moved 2.0s, frames=false, segments=14 stalls=0", defaults: defaults)
        let line = try! XCTUnwrap(PlaybackDiagnostics.latestForSettings(defaults: defaults))
        XCTAssertTrue(line.contains("Armageddon"), line)
        XCTAssertTrue(line.contains("frames=false"), "the one field that discriminates must survive: \(line)")
        XCTAssertTrue(line.contains("playhead moved 2.0s"), line)
        XCTAssertTrue(line.contains("skipped to next after 40s"), line)
    }

    func testNewestFirstAndOnlyAFewKept() {
        for i in 1...8 { PlaybackDiagnostics.record(outcome: "v\(i)", title: "T\(i)", detail: "d", defaults: defaults) }
        let rows = PlaybackDiagnostics.recent(defaults: defaults)
        XCTAssertEqual(rows.count, 5, "keep the last five, not a growing log")
        XCTAssertTrue(rows[0].contains("\"T8\""), "newest first: \(rows[0])")
        XCTAssertTrue(rows[4].contains("\"T4\""))
    }

    func testCredentialsAreRemovedBeforePersistenceAndLegacyRowsArePurged() {
        let samples = [
            "https://user:pass@example.invalid/file?X-Plex-Token=fixture-one#fragment",
            "/segment.ts?x-plex-token=fixture-two&other=ok",
            "X-Plex-Token: \"fixture-three\"",
            "Authorization: Bearer fixture-four",
            "https%3A%2F%2Fexample.invalid%2Ffile%3FX-Plex-Token%3Dfixture-five",
            "api_key=fixture-six; Token='fixture-seven'",
            #"{"X-Plex-Token": "fixture-eight", "Authorization": "Bearer fixture-nine"}"#,
            "X%252DPlex%252DToken%253Dfixture-ten",

        ]
        for sample in samples {
            PlaybackDiagnostics.record(outcome: "HTTP 403", title: "Synthetic", detail: sample, defaults: defaults)
            let persisted = defaults.dictionaryRepresentation().description
            XCTAssertFalse(persisted.contains("fixture-"), sample)
            XCTAssertFalse(persisted.contains("user:pass"), sample)
        }
        let rows = PlaybackDiagnostics.recent(defaults: defaults).joined()
        XCTAssertFalse(rows.contains("fixture-"))
        XCTAssertTrue(rows.contains("HTTP 403"))
        defaults.set(["legacy token tail"], forKey: "nostalgex_playback_verdicts")
        _ = PlaybackDiagnostics.recent(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "nostalgex_playback_verdicts"))
    }

    func testClearEmptiesIt() {
        PlaybackDiagnostics.record(outcome: "x", title: "y", detail: "z", defaults: defaults)
        PlaybackDiagnostics.clear(defaults: defaults)
        XCTAssertNil(PlaybackDiagnostics.latestForSettings(defaults: defaults))
    }
}

/// Settings shows the last playback failure. It used to survive a sign-out and a switch to
/// another server, so someone on a new library read a failure from the old one.
@MainActor
final class PlaybackFailureClearingTests: XCTestCase {
    private final class MemoryStore: CredentialStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        @discardableResult func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    override func setUp() { PlaybackDiagnostics.clear() }
    override func tearDown() { PlaybackDiagnostics.clear() }

    private func server(_ id: String, _ url: String) -> AppState.ServerRef {
        AppState.ServerRef(machineIdentifier: id, name: id, baseURL: url, owned: true, token: "t")
    }

    private func recordFailure() {
        PlaybackDiagnostics.record(outcome: "retry capped at 1080p after 20s", title: "72 Hours", detail: "HTTP 500")
        XCTAssertNotNil(PlaybackDiagnostics.latestForSettings())
    }

    func testSignOutClearsTheLastFailure() {
        let state = AppState(credentialStore: MemoryStore())
        state.setSelectedServers([server("a", "http://192.168.1.10:32400")])
        state.token = "t"
        recordFailure()

        state.disconnect()

        XCTAssertNil(PlaybackDiagnostics.latestForSettings())
        XCTAssertTrue(PlaybackDiagnostics.recent().isEmpty)
    }

    func testSwitchingToAnotherServerClearsIt() {
        let state = AppState(credentialStore: MemoryStore())
        state.setSelectedServers([server("a", "http://192.168.1.10:32400")])
        recordFailure()

        state.setSelectedServers([server("b", "http://192.168.1.20:32400")])

        XCTAssertNil(PlaybackDiagnostics.latestForSettings())
    }

    func testTheFirstSignInAndServersKeptInAMultiServerListKeepIt() {
        let state = AppState(credentialStore: MemoryStore())
        recordFailure()
        // Nothing was signed in before: nothing to leave behind (disconnect already cleared).
        state.setSelectedServers([server("a", "http://192.168.1.10:32400")])
        XCTAssertNotNil(PlaybackDiagnostics.latestForSettings())

        // Adding a second server, then removing the first, keeps one in common each time.
        state.setSelectedServers([server("a", "http://192.168.1.10:32400"), server("b", "http://192.168.1.20:32400")])
        XCTAssertNotNil(PlaybackDiagnostics.latestForSettings())
        state.setSelectedServers([server("b", "http://192.168.1.20:32400")])
        XCTAssertNotNil(PlaybackDiagnostics.latestForSettings())
    }

    func testTheSameServerKeyedByURLThenByIdentifierKeepsIt() {
        // A pre-multi-server install stored its server keyed by URL; discovery later knows
        // its machine identifier. Same host and port: same server.
        let state = AppState(credentialStore: MemoryStore())
        state.setSelectedServers([server("http://192.168.1.10:32400", "http://192.168.1.10:32400")])
        recordFailure()

        state.setSelectedServers([server("abc123", "http://192.168.1.10:32400")])

        XCTAssertNotNil(PlaybackDiagnostics.latestForSettings())
    }
}
