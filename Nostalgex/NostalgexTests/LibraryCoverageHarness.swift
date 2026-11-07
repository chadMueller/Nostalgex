import XCTest
@testable import Nostalgex

/// Opt-in: runs the app's own coverage count on a library the size of the one the web tuner was
/// calibrated on (1,792 movies, 8,891 episodes, 1,126 music videos, 142 channels, cold
/// enrichment), writes the items and the Swift numbers to a folder, and prints the time it took.
/// `scripts/qa/library-coverage.mjs` then runs the web tuner's copy of the filter over the same
/// items and compares, kind by kind.
///
///     TEST_RUNNER_NOSTALGEX_COVERAGE_OUT=/some/folder \
///       xcodebuild test ... -only-testing:NostalgexTests/LibraryCoverageHarness
///     node scripts/qa/library-coverage.mjs /some/folder
///
/// The library is synthetic (the scale fixtures), so the orphan numbers are not Chad's; what it
/// proves is that the two engines agree on the same items, and what the count costs.
@MainActor
final class LibraryCoverageHarness: XCTestCase {

    func testACalibrationSizedLibrary() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let outPath = env["NOSTALGEX_COVERAGE_OUT"] ?? env["TEST_RUNNER_NOSTALGEX_COVERAGE_OUT"], !outPath.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_NOSTALGEX_COVERAGE_OUT to a folder to run the coverage harness")
        }
        let scope = HarnessScope.begin("coverage-harness")
        defer { scope.end() }

        let movies = MovieLibraryScaleHarness.makeMovieLibrary(count: 1_792, serverID: "cov-movies").items
        let big = BigLibraryHarness.makeLibrary(count: 30_000, serverID: "cov-big").items
        let episodes = Array(big.filter { $0.type == .episode }.prefix(8_891))
        let musicVideos = Array(big.filter { $0.librarySource == .musicVideo }.prefix(1_126))
        let items = movies + episodes + musicVideos

        let config = ChannelConfigLoader.loadBundled()
        let suite = UserDefaults(suiteName: "LibraryCoverageHarness.\(UUID().uuidString)")!
        let sync = PreferenceSync(cloud: InMemoryKeyValueStore(), defaults: suite, observeNotifications: false, keys: PreferenceSync.syncedKeys)
        let state = AppState(preferenceSync: sync)
        state.allItems = items
        state.channelConfigChannels = config.channels
        state.exclusiveRules = config.exclusiveRules

        let before = BigLibraryHarness.footprintBytes()
        let started = Date()
        state.ensureLibraryCoverage()
        await state.libraryCoverageTask?.value
        let seconds = Date().timeIntervalSince(started)
        let coverage = try XCTUnwrap(state.libraryCoverage)

        var swift: [String: [String: Int]] = [:]
        for kind in LibraryDiagnostics.Kind.allCases {
            swift[kind.rawValue] = ["loaded": coverage.loaded[kind] ?? 0, "onChannels": coverage.onChannels[kind] ?? 0, "orphans": coverage.orphans(kind)]
        }
        let summary = "items=\(items.count) channels=\(config.channels.count) seconds=\(String(format: "%.1f", seconds)) "
            + "footprintDeltaMB=\((Int(BigLibraryHarness.footprintBytes()) - Int(before)) / 1_048_576) swift=\(swift)"
        print("[COVERAGE-HARNESS] \(summary)")

        // Per channel, how many titles each pool holds, so a disagreement with the web filter can be
        // traced to the channel that differs rather than just counted.
        let cache = state.makeFilterCache(items)
        var pools: [String: [String]] = [:]
        for channel in config.channels where channel.rules != nil {
            let pool = AppState.filterItems(cache, rules: channel.rules, forChannelID: channel.id, category: channel.category,
                                            memberships: state.channelMemberships, exclusiveRules: state.exclusiveRules)
            pools[String(channel.id)] = pool.map(\.id)
        }

        let dir = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(items).write(to: dir.appendingPathComponent("items.json"))
        try JSONSerialization.data(withJSONObject: ["items": items.count, "seconds": seconds, "swift": swift])
            .write(to: dir.appendingPathComponent("swift-result.json"))
        try JSONSerialization.data(withJSONObject: pools).write(to: dir.appendingPathComponent("swift-pools.json"))
        let a = XCTAttachment(string: summary)
        a.name = "coverage-harness.txt"; a.lifetime = .keepAlways
        add(a)
        state.disconnect()
    }
}
