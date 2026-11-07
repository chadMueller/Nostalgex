import XCTest
@testable import Nostalgex

/// The saved-library fields that landed in 1.0.30 meet in one file: `scanFieldsVersion` (what the
/// scan asked for and kept, #204 and #205) and `skippedNoRuntime` (the count under RESCAN LIBRARY).
/// Both are optional in meta.json, so a library saved by 1.0.29 has neither.
///
/// This is the upgrade, end to end, on Emby (where all of it applies): a 1.0.29 file restores
/// with everything it held, comes up stale with no signature so the refresh is not skipped, can
/// be saved again before the refresh without being stamped as new, and after the refresh holds
/// both fields and is fresh. A second launch does not refresh again.
@MainActor
final class SnapshotUpgradePathTests: XCTestCase {

    private final class Memory: Nostalgex.CredentialStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        @discardableResult func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    /// Seven films, one of them with no runtime, so the scan skips exactly one.
    nonisolated private static func reply(path: String, query: [String: String]) -> LoopbackReply? {
        if path.hasSuffix("/UserViews") || path.hasSuffix("/Views") {
            return LoopbackReply(delayMs: 0, body: ["TotalRecordCount": 1, "Items": [
                ["Id": "movies", "Name": "Movies", "CollectionType": "movies"]]])
        }
        guard path.hasSuffix("/Items"), query["ParentId"] == "movies" else { return nil }
        let rows: [[String: Any]] = (0..<7).map { i in
            var d: [String: Any] = ["Id": "m\(i)", "Name": "Upgrade Film \(i)", "Type": "Movie", "Genres": ["Action"],
                                    "ProductionYear": 1984 + i, "ProviderIds": ["Tmdb": "\(100_000 + i)"],
                                    "OfficialRating": "PG", "CommunityRating": 7.0,
                                    "MediaSources": [["Id": "ms-\(i)", "Container": "mkv"]]]
            if i != 6 { d["RunTimeTicks"] = Int64(100) * 600_000_000 }
            return d
        }
        return LoopbackReply(delayMs: 0, body: ["TotalRecordCount": rows.count, "Items": rows])
    }

    private func meta() throws -> (url: URL, json: [String: Any]) {
        let root = try XCTUnwrap(LibrarySnapshotStore.snapshotDirectoryURL)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("current.json"))) as? [String: Any]
        let generation = try XCTUnwrap(manifest?["generation"] as? String)
        let url = root.appendingPathComponent(generation).appendingPathComponent("meta.json")
        return (url, try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]))
    }

    func testA1029SnapshotRestoresRefreshesOnceAndLosesNothing() async throws {
        let scope = HarnessScope.begin("snapshot-upgrade")
        defer { scope.end() }
        let http = try LoopbackJSONServer { path, query in Self.reply(path: path, query: query) }
        try await http.start()
        defer { http.stop() }
        let api = EmbyAPIService(serverURL: http.url, accessToken: "tok", userId: "u1")
        let auth = EmbyAPIService.AuthResult(accessToken: "tok", userId: "u1", serverID: "emby-up", serverName: "Emby Up")

        func session() -> AppState {
            let s = AppState(credentialStore: Memory())
            s.backendOverride = { _ in api }
            return s
        }
        func reconnect(_ s: AppState, like first: AppState) {
            s.backendKind = .emby; s.serverURL = http.url; s.jellyfinUserId = "u1"
            s.token = "tok"; s.serverName = "Emby Up"
            s.setSelectedServers(first.selectedServers)
        }

        // 1. The library as a build wrote it: scanned, saved. Then made to look like 1.0.29's file.
        let first = session()
        await first.completeEmbyAuth(serverURL: http.url, result: auth)
        if first.needsLibrarySelection { await first.loadLibrary() }
        XCTAssertEqual(first.allItems.count, 6, "six films have a runtime")
        XCTAssertEqual(first.skippedNoRuntimeCount, 1)
        first.librarySignature = "sig-1"
        first.saveLibrarySnapshotIfNeeded()
        await Task.detached { LibrarySnapshotStore.waitForPendingSaves() }.value
        let fresh = try meta().json
        XCTAssertEqual(fresh["scanFieldsVersion"] as? Int, LibrarySnapshotStore.scanFieldsVersion, "the new scan stamps its version")
        XCTAssertEqual(fresh["skippedNoRuntime"] as? Int, 1, "and its skipped count")
        let titlesBefore = Set(first.allItems.map(\.title))
        let channelsBefore = first.allChannels.map(\.id)
        XCTAssertFalse(channelsBefore.isEmpty)

        var old = fresh
        old.removeValue(forKey: "scanFieldsVersion")
        old.removeValue(forKey: "skippedNoRuntime")
        let location = try meta().url
        try JSONSerialization.data(withJSONObject: old).write(to: location)

        // 2. Launch on the new build: it restores everything, and a refresh is due that is not skipped.
        let second = session()
        reconnect(second, like: first)
        let restored = await second.restoreLibraryFromSnapshotIfNeeded()
        XCTAssertTrue(restored)
        XCTAssertEqual(Set(second.allItems.map(\.title)), titlesBefore, "every title comes back")
        XCTAssertEqual(second.allChannels.map(\.id), channelsBefore, "and every channel")
        XCTAssertEqual(second.skippedNoRuntimeCount, 0, "a count the file never held reads as none")
        XCTAssertNil(second.libraryScanFieldsVersion, "and the scan it came from reads as the old one")
        XCTAssertTrue(second.isLibraryStale)
        XCTAssertNil(second.librarySignature, "no signature, so refreshLibraryIfChanged cannot skip the scan")

        // 3. Saved again before the refresh finishes (a package toggle does this): not stamped as new.
        second.saveLibrarySnapshotIfNeeded()
        await Task.detached { LibrarySnapshotStore.waitForPendingSaves() }.value
        let between = try meta().json
        XCTAssertNil(between["scanFieldsVersion"], "old items are not stamped as read by the new scan")
        XCTAssertEqual((between["skippedNoRuntime"] as? Int) ?? 0, 0)

        // 4. The refresh: the scan stamps its version, counts what it skipped, keeps what it had.
        await second.refreshLibraryIfChanged()
        XCTAssertEqual(second.libraryScanFieldsVersion, LibrarySnapshotStore.scanFieldsVersion)
        XCTAssertEqual(second.skippedNoRuntimeCount, 1)
        XCTAssertEqual(Set(second.allItems.map(\.title)), titlesBefore, "nothing lost by the refresh")
        await Task.detached { LibrarySnapshotStore.waitForPendingSaves() }.value
        let after = try meta().json
        XCTAssertEqual(after["scanFieldsVersion"] as? Int, LibrarySnapshotStore.scanFieldsVersion)
        XCTAssertEqual(after["skippedNoRuntime"] as? Int, 1)

        // 5. The next launch is an ordinary one: fresh, signature kept, no second refresh.
        let third = session()
        reconnect(third, like: first)
        let restoredAgain = await third.restoreLibraryFromSnapshotIfNeeded()
        XCTAssertTrue(restoredAgain)
        XCTAssertFalse(third.isLibraryStale, "refreshed once, not again")
        XCTAssertFalse(LibrarySnapshotStore.scanNeedsRefresh(backend: .emby, savedVersion: third.libraryScanFieldsVersion))
        XCTAssertEqual(third.skippedNoRuntimeCount, 1)
        XCTAssertEqual(third.libraryScanFieldsVersion, LibrarySnapshotStore.scanFieldsVersion)

        third.disconnect(); second.disconnect(); first.disconnect()
    }

    /// Plex's scan never had either problem: a 1.0.29 Plex snapshot is not forced to refresh.
    func testAPlexSnapshotFrom1029IsNotForcedToRefresh() {
        XCTAssertFalse(LibrarySnapshotStore.scanNeedsRefresh(backend: .plex, savedVersion: nil))
    }
}
