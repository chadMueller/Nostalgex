import XCTest
@testable import Nostalgex

/// N-016 option A: one rule set, on every platform, for which Plex libraries are listed and read
/// (scripts/library-picker-golden.json, the web tuner's contract). The Apple TV half: the picker and
/// Settings list what `PlexAPIService.readableSections` keeps, as `LibrarySectionRef`s, and a scan reads
/// the same set.
@MainActor
final class LibraryPickerGoldenTests: XCTestCase {
    private func golden() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/library-picker-golden.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testPlexListingMatchesTheGolden() throws {
        let cases = try XCTUnwrap(try golden()["plexListing"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            var listed: [LibrarySectionRef] = []
            for server in c["servers"] as? [[String: Any]] ?? [] {
                // A server that did not answer (`sections` null) lists nothing, as `loadAllLibrarySections` skips it.
                guard let raw = server["sections"] as? [[String: Any]] else { continue }
                let sections = raw.map { PlexSection(key: $0["key"] as! String, title: $0["title"] as! String, type: $0["type"] as! String) }
                listed += PlexAPIService.readableSections(sections).map {
                    LibrarySectionRef(serverID: server["id"] as! String, serverName: server["name"] as? String ?? "",
                                      sectionKey: $0.key, title: $0.title, type: $0.type)
                }
            }
            let multiServer = Set(listed.map(\.serverID)).count > 1
            let expected = c["listed"] as? [[String: Any]] ?? []
            XCTAssertEqual(listed.map(\.id), expected.map { $0["id"] as! String }, name)
            for (got, want) in zip(listed, expected) {
                XCTAssertEqual(got.title, want["title"] as? String, name)
                XCTAssertEqual(got.type, want["type"] as? String, name)
                XCTAssertEqual(got.typeLabel, want["label"] as? String, "\(name): \(got.title)")
                XCTAssertEqual(got.subtitle(multiServer: multiServer), want["subtitle"] as? String, "\(name): \(got.title)")
                XCTAssertEqual(PlexAPIService.isMusicVideoLibrary(title: got.title), want["musicVideo"] as? Bool, "\(name): \(got.title)")
                XCTAssertEqual(got.isHidden, want["hidden"] as? Bool, name)
            }
        }
    }

    /// Switching a library in Settings is a different library: a scan already out must not land.
    func testSwitchingALibraryEndsTheScanThatIsRunning() {
        let state = AppState()
        let section = LibrarySectionRef(serverID: "machine-a", serverName: "Den", sectionKey: "1", title: "Movies", type: "movie")
        let other = LibrarySectionRef(serverID: "machine-a", serverName: "Den", sectionKey: "2", title: "TV Shows", type: "show")
        state.availableLibrarySections = [section, other]
        let before = state.librarySessionGeneration
        state.toggleLibrarySection(section)
        XCTAssertGreaterThan(state.librarySessionGeneration, before)
        state.toggleLibrarySection(section)
        LibrarySectionSelectionStore.save([])
    }
}
