import XCTest
@testable import Nostalgex

/// N-074: the guide is built from nostalgex.app's channels.json only when the download passes, and a bad
/// download never replaces the last good copy.
final class ChannelConfigStoreTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var dir: URL!
    private var cache: URL { dir.appendingPathComponent("channels-live.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ChannelConfigStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func shipped() throws -> Data {
        try Data(contentsOf: Self.repoRoot.appendingPathComponent("channels.json"))
    }

    /// The shipped file with some top-level fields changed.
    private func shipped(_ change: (inout [String: Any]) -> Void) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: shipped()) as? [String: Any])
        change(&json)
        return try JSONSerialization.data(withJSONObject: json)
    }

    private var bundledVersion: Int { (try? ChannelConfigStore.version(of: shipped())) ?? 0 }

    func testTheShippedFileIsAccepted() throws {
        XCTAssertGreaterThan(bundledVersion, 0)
        XCTAssertEqual(ChannelConfigStore.verdict(for: try shipped(), bundledVersion: bundledVersion, appVersion: "1.0.33"),
                       .accepted(version: bundledVersion))
    }

    func testAnInvalidFileIsRejectedAndTheKeptCopyStays() throws {
        let good = try shipped { $0["channels"] = Array(($0["channels"] as? [Any] ?? []).prefix(3)) }
        try good.write(to: cache)

        for bad in [Data("<html>502 Bad Gateway</html>".utf8), Data("{\"version\": 51, \"channels\": [{\"id\": 1}]}".utf8), Data()] {
            let v = ChannelConfigStore.store(downloaded: bad, bundledVersion: bundledVersion, appVersion: "1.0.33", to: cache)
            XCTAssertEqual(v, .invalid)
            XCTAssertEqual(try Data(contentsOf: cache), good, "a bad download must not replace the kept copy")
        }

        let empty = try shipped { $0["channels"] = [] }
        XCTAssertEqual(ChannelConfigStore.store(downloaded: empty, bundledVersion: bundledVersion, appVersion: "1.0.33", to: cache), .noChannels)
        XCTAssertEqual(try Data(contentsOf: cache), good)
    }

    func testAnOlderOrNewerFormatIsRejected() throws {
        let older = try shipped { $0["version"] = self.bundledVersion - 1 }
        XCTAssertEqual(ChannelConfigStore.verdict(for: older, bundledVersion: bundledVersion, appVersion: "1.0.33"),
                       .olderThanBundled(live: bundledVersion - 1, bundled: bundledVersion))

        let newerFormat = try shipped { $0["formatVersion"] = 2 }
        XCTAssertEqual(ChannelConfigStore.verdict(for: newerFormat, bundledVersion: bundledVersion, appVersion: "1.0.33"), .unsupportedFormat(2))

        // formatVersion 1, or missing (counts as 1), is read.
        let formatOne = try shipped { $0["formatVersion"] = 1 }
        XCTAssertEqual(ChannelConfigStore.verdict(for: formatOne, bundledVersion: bundledVersion, appVersion: "1.0.33"),
                       .accepted(version: bundledVersion))

        // A content version newer than the bundled one is fine.
        let newerContent = try shipped { $0["version"] = self.bundledVersion + 5 }
        XCTAssertEqual(ChannelConfigStore.verdict(for: newerContent, bundledVersion: bundledVersion, appVersion: "1.0.33"),
                       .accepted(version: bundledVersion + 5))

        // Neither rejected one is kept.
        for data in [older, newerFormat] {
            ChannelConfigStore.store(downloaded: data, bundledVersion: bundledVersion, appVersion: "1.0.33", to: cache)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testANewerGoodCopyIsKeptAndBuiltFrom() throws {
        let newer = try shipped { json in
            json["version"] = self.bundledVersion + 1
            var channels = json["channels"] as? [[String: Any]] ?? []
            channels[0]["name"] = "LIVE RULES TEST"
            json["channels"] = channels
        }
        XCTAssertEqual(ChannelConfigStore.store(downloaded: newer, bundledVersion: bundledVersion, appVersion: "1.0.33", to: cache),
                       .accepted(version: bundledVersion + 1))
        let active = ChannelConfigStore.active(bundled: try shipped(), cached: try Data(contentsOf: cache), appVersion: "1.0.33")
        XCTAssertEqual(active.source, "live")
        XCTAssertEqual(active.result.channels.first?.name, "LIVE RULES TEST")
    }

    func testAKeptCopyThatNoLongerPassesFallsBackToTheBundledOne() throws {
        // An app update can ship a newer channels.json than the copy kept from the site.
        let older = try shipped { $0["version"] = self.bundledVersion - 1 }
        let a = ChannelConfigStore.active(bundled: try shipped(), cached: older, appVersion: "1.0.33")
        XCTAssertEqual(a.source, "bundled")
        let b = ChannelConfigStore.active(bundled: try shipped(), cached: Data("garbage".utf8), appVersion: "1.0.33")
        XCTAssertEqual(b.source, "bundled")
        let c = ChannelConfigStore.active(bundled: try shipped(), cached: nil, appVersion: "1.0.33")
        XCTAssertEqual(c.source, "bundled")
        XCTAssertFalse(c.result.channels.isEmpty)
    }

    /// An unchanged file costs a 304: the request carries If-None-Match only when there is an ETag to send.
    func testTheRequestIsConditionalWhenThereIsAnETag() {
        let plain = ChannelConfigStore.request(etag: nil, timeout: 10)
        XCTAssertNil(plain.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertNil(ChannelConfigStore.request(etag: "", timeout: 10).value(forHTTPHeaderField: "If-None-Match"))
        let conditional = ChannelConfigStore.request(etag: "W/\"abc\"", timeout: 3)
        XCTAssertEqual(conditional.value(forHTTPHeaderField: "If-None-Match"), "W/\"abc\"")
        XCTAssertEqual(conditional.timeoutInterval, 3)
        XCTAssertEqual(conditional.url, ChannelConfigStore.liveURL)
        XCTAssertEqual(conditional.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertLessThan(ChannelConfigStore.blockingTimeout, ChannelConfigStore.timeout)
    }

    /// Parse cost of the live file, measured on the simulator host (the numbers in the dev log).
    func testParseTimeOfTheShippedFile() throws {
        let data = try shipped()
        var best = Double.infinity
        for _ in 0..<5 {
            let t0 = CFAbsoluteTimeGetCurrent()
            XCTAssertNotNil(ChannelConfigLoader.loadConfig(from: data))
            best = min(best, CFAbsoluteTimeGetCurrent() - t0)
        }
        print("[CONFIGPERF] \(data.count) bytes, loadConfig best of 5 = \(Int(best * 1000)) ms")
        XCTAssertLessThan(best, 0.5, "parsing channels.json should be far under half a second")
    }

    func testVersionCompare() {
        XCTAssertTrue(ChannelConfigStore.isVersion("1.0.34", newerThan: "1.0.33"))
        XCTAssertTrue(ChannelConfigStore.isVersion("1.1", newerThan: "1.0.99"))
        XCTAssertFalse(ChannelConfigStore.isVersion("1.0.33", newerThan: "1.0.33"))
        XCTAssertFalse(ChannelConfigStore.isVersion("1.0", newerThan: "1.0.0"))
    }
}
