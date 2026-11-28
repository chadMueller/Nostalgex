import XCTest
@testable import Nostalgex

/// N-074, faster: when a new live channels.json is checked for and applied. The rules are pure, so the cases are
/// plain: unchanged, newer, invalid, during playback, and at launch.
final class LiveChannelRulesTests: XCTestCase {
    private typealias M = LiveChannelRules.Moment
    private let onGuide = M(onGuide: true)

    func testAnUnchangedOrOlderVersionDoesNothing() {
        XCTAssertEqual(LiveChannelRules.decide(appliedVersion: 50, keptVersion: 50, moment: onGuide), .nothing)
        XCTAssertEqual(LiveChannelRules.decide(appliedVersion: 51, keptVersion: 50, moment: onGuide), .nothing)
        XCTAssertEqual(LiveChannelRules.decide(appliedVersion: 50, keptVersion: 0, moment: onGuide), .nothing)
    }

    func testANewerVersionIsAppliedOnTheGuide() {
        XCTAssertEqual(LiveChannelRules.decide(appliedVersion: 50, keptVersion: 51, moment: onGuide), .applyNow)
    }

    func testNothingIsAppliedDuringPlaybackOrALoad() {
        for moment in [M(isFullScreen: true, onGuide: false), M(isFullScreen: true, onGuide: true),
                       M(isLoading: true, onGuide: true), M(isRebuilding: true, onGuide: true)] {
            XCTAssertEqual(LiveChannelRules.decide(appliedVersion: 50, keptVersion: 51, moment: moment), .waitForGuide, "\(moment)")
        }
        // Under Settings, or anywhere but the guide.
        XCTAssertEqual(LiveChannelRules.decide(appliedVersion: 50, keptVersion: 51, moment: M(onGuide: false)), .waitForGuide)
    }

    func testItWaitsForTheNextTimeTheViewerIsOnTheGuide() {
        var moment = M(isFullScreen: true)
        XCTAssertEqual(LiveChannelRules.decide(appliedVersion: 50, keptVersion: 51, moment: moment), .waitForGuide)
        moment = M(onGuide: true)   // back from full screen
        XCTAssertEqual(LiveChannelRules.decide(appliedVersion: 50, keptVersion: 51, moment: moment), .applyNow)
    }

    func testAtLaunchANewerVersionIsAppliedBeforeAnythingPlays() {
        XCTAssertEqual(LiveChannelRules.decide(appliedVersion: 50, keptVersion: 51, moment: M(atLaunch: true)), .applyNow)
        XCTAssertEqual(LiveChannelRules.decide(appliedVersion: 51, keptVersion: 51, moment: M(atLaunch: true)), .nothing)
        // A launch that is still loading waits for the guide.
        XCTAssertEqual(LiveChannelRules.decide(appliedVersion: 50, keptVersion: 51, moment: M(isLoading: true, atLaunch: true)), .waitForGuide)
    }

    func testWhenApplyingWhileRunningIsOffOnlyTheNextLaunchApplies() {
        XCTAssertEqual(LiveChannelRules.decide(appliedVersion: 50, keptVersion: 51, moment: onGuide, appliesWhileRunning: false), .waitForLaunch)
        XCTAssertEqual(LiveChannelRules.decide(appliedVersion: 50, keptVersion: 51, moment: M(atLaunch: true), appliesWhileRunning: false), .applyNow)
        XCTAssertEqual(LiveChannelRules.decide(appliedVersion: 50, keptVersion: 50, moment: onGuide, appliesWhileRunning: false), .nothing)
    }

    /// An invalid download never moves the kept version, so there is nothing newer to apply.
    func testAnInvalidDownloadLeavesNothingToApply() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LiveRules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("channels-live.json")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shipped = try Data(contentsOf: root.appendingPathComponent("channels.json"))
        let bundled = ChannelConfigStore.version(of: shipped)

        // Invalid, no channels, older, a format from the future: all refused, so the kept version stays the bundled one.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: shipped) as? [String: Any])
        json["version"] = bundled + 9; json["formatVersion"] = 2
        let future = try JSONSerialization.data(withJSONObject: json)
        for bad in [Data("<html>".utf8), future] {
            ChannelConfigStore.store(downloaded: bad, bundledVersion: bundled, appVersion: "1.0.33", to: cache)
        }
        let active = ChannelConfigStore.active(bundled: shipped, cached: try? Data(contentsOf: cache), appVersion: "1.0.33")
        XCTAssertEqual(active.version, bundled)
        XCTAssertEqual(LiveChannelRules.decide(appliedVersion: bundled, keptVersion: active.version, moment: onGuide), .nothing)

        // A good newer copy is kept and then applies.
        json["formatVersion"] = 1
        let good = try JSONSerialization.data(withJSONObject: json)
        ChannelConfigStore.store(downloaded: good, bundledVersion: bundled, appVersion: "1.0.33", to: cache)
        let newer = ChannelConfigStore.active(bundled: shipped, cached: try? Data(contentsOf: cache), appVersion: "1.0.33")
        XCTAssertEqual(newer.version, bundled + 9)
        XCTAssertEqual(LiveChannelRules.decide(appliedVersion: bundled, keptVersion: newer.version, moment: onGuide), .applyNow)

        // A rollback is the old content under a HIGHER version: applies. The old version number would not.
        json["version"] = bundled + 10
        let rollback = try JSONSerialization.data(withJSONObject: json)
        XCTAssertEqual(ChannelConfigStore.store(downloaded: rollback, bundledVersion: bundled, appVersion: "1.0.33", to: cache), .accepted(version: bundled + 10))
        json["version"] = bundled - 1
        let older = try JSONSerialization.data(withJSONObject: json)
        XCTAssertEqual(ChannelConfigStore.store(downloaded: older, bundledVersion: bundled, appVersion: "1.0.33", to: cache), .olderThanBundled(live: bundled - 1, bundled: bundled))
    }

    func testTheCheckIsDueOncePerInterval() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let interval = ChannelConfigStore.checkInterval
        XCTAssertEqual(interval, 3600, "Chad asked for hours, not a day")
        XCTAssertTrue(ChannelConfigStore.isCheckDue(lastCheck: 0, keptCopyExists: true, now: now), "never checked")
        XCTAssertTrue(ChannelConfigStore.isCheckDue(lastCheck: now.timeIntervalSince1970 - 10, keptCopyExists: false, now: now), "no kept copy")
        XCTAssertFalse(ChannelConfigStore.isCheckDue(lastCheck: now.timeIntervalSince1970 - (interval - 1), keptCopyExists: true, now: now))
        XCTAssertTrue(ChannelConfigStore.isCheckDue(lastCheck: now.timeIntervalSince1970 - interval, keptCopyExists: true, now: now))
    }

    func testTheAppliedVersionStartsAsTheBundledOne() {
        let d = UserDefaults(suiteName: "LiveRulesTests-\(UUID().uuidString)")!
        XCTAssertEqual(ChannelConfigStore.appliedVersion(defaults: d, bundledVersion: 50), 50)
        ChannelConfigStore.recordApplied(version: 53, defaults: d)
        XCTAssertEqual(ChannelConfigStore.appliedVersion(defaults: d, bundledVersion: 50), 53)
    }
}
