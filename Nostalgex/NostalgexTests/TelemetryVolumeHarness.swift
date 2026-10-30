import AVFoundation
import XCTest
@testable import Nostalgex

/// Measures how many analytics events the real AppState produces, then replays that
/// exact stream through `AnalyticsGate` to show what would reach TelemetryDeck.
///
/// The first two tests run in the normal suite and need no media: every item has no
/// playable source, which is the shape of a server that is down or a library the device
/// cannot play. The third plays real (generated) video and is skipped unless asked for:
///   TEST_RUNNER_NOSTALGEX_TELEMETRY_LIVE=1
/// Results are attached to the test as text (`xcresulttool export attachments`).
@MainActor
final class TelemetryVolumeHarness: XCTestCase {
    private var savedReportPreference: Any?

    override func setUp() {
        savedReportPreference = UserDefaults.standard.object(forKey: AppState.syncPlexActivityDefaultsKey)
        UserDefaults.standard.set(false, forKey: AppState.syncPlexActivityDefaultsKey)
    }

    override func tearDown() {
        if let savedReportPreference {
            UserDefaults.standard.set(savedReportPreference, forKey: AppState.syncPlexActivityDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppState.syncPlexActivityDefaultsKey)
        }
        Analytics.configure(with: NoOpAnalytics())
        UserDefaults.standard.removePersistentDomain(forName: "TelemetryVolumeHarness")
    }

    // MARK: - Fixtures

    /// Records every event AppState offers, with the time it was offered.
    private final class Recorder: AnalyticsService, @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [(at: Date, event: AnalyticsEvent)] = []
        var events: [(at: Date, event: AnalyticsEvent)] { lock.lock(); defer { lock.unlock() }; return _events }
        func configure() {}
        func track(_ event: AnalyticsEvent, contextParameters: [String: String]) {
            lock.lock(); _events.append((Date(), event)); lock.unlock()
        }
    }

    private struct NoCredentials: CredentialStoring {
        func save(key: String, value: String) -> Bool { true }
        func load(key: String) -> String? { nil }
        func delete(key: String) {}
    }

    /// A server that plays `file` directly, or offers nothing at all when `file` is nil.
    private final class Backend: MediaBackend, @unchecked Sendable {
        let file: URL?
        init(file: URL?) { self.file = file }
        let serverID = "synthetic"
        let authHeaders: [String: String] = [:]
        func testConnection() async throws -> String { "synthetic" }
        func loadLibrary(excludedSectionKeys: Set<String> = [], progress: LoadProgress?) async throws -> [PlexMediaItem] { [] }
        func loadSections() async throws -> [PlexSection] { [] }
        func loadCollections(sectionKey: String) async throws -> [PlexCollection] { [] }
        func loadCollectionItems(collectionKey: String) async throws -> [String] { [] }
        func buildDirectPlayURL(for item: PlexMediaItem) -> URL? { file }
        func buildTranscodeURL(for item: PlexMediaItem) -> URL? { nil }
        func thumbnailURL(for item: PlexMediaItem, width: Int) -> URL? { nil }
    }

    private func item(_ key: String, minutes: Int) -> PlexMediaItem {
        PlexMediaItem(id: key, title: "Synthetic \(key)", artist: nil, episodeTitle: nil, seTag: nil,
                      summary: "", year: nil, originallyAvailableAt: nil, contentRating: nil,
                      duration: minutes, ratingKey: key, partKey: nil, container: "mp4", videoCodec: "h264",
                      audioCodec: "aac", videoProfile: nil, bitrate: nil, genres: [], rating: 0,
                      userRating: 0, type: .movie, thumb: nil, art: nil, viewCount: 0, addedAt: 0,
                      studio: nil, tmdbID: nil, imdbID: nil, librarySource: .movie, serverID: "synthetic")
    }

    private func lineup(count: Int, minutes: Int) -> [Channel] {
        (1...count).map { id in
            Channel(id: id, number: id, name: "SYNTHETIC \(id)", color: .blue, category: "nostalgex",
                    rules: ChannelRules(), timeRestrictions: nil, minItems: 0,
                    itemPool: (0..<4).map { item("c\(id)-\($0)", minutes: minutes) })
        }
    }

    private func makeState(_ backend: Backend, channels: [Channel]) -> AppState {
        let defaults = UserDefaults(suiteName: "TelemetryVolumeHarness")!
        let sync = PreferenceSync(cloud: InMemoryKeyValueStore(), defaults: defaults,
                                  observeNotifications: false, keys: PreferenceSync.syncedKeys)
        let state = AppState(credentialStore: NoCredentials(), preferenceSync: sync)
        state.backendOverride = { _ in backend }
        state.allChannels = channels
        state.channels = channels
        return state
    }

    /// Raw counts by name, the gated counts from replaying the same stream, and a table.
    private func compare(_ recorded: [(at: Date, event: AnalyticsEvent)], title: String)
        -> (raw: [String: Int], gated: [String: Int], report: String) {
        var gate = AnalyticsGate()
        let gatedEvents = recorded.flatMap { gate.admit($0.event, at: $0.at) }
        let raw = recorded.reduce(into: [String: Int]()) { $0[$1.event.name, default: 0] += 1 }
        let gated = gatedEvents.reduce(into: [String: Int]()) { $0[$1.name, default: 0] += 1 }
        var lines = [title, "signal                        raw  gated"]
        for name in Set(raw.keys).union(gated.keys).sorted() {
            lines.append(name.padding(toLength: 28, withPad: " ", startingAt: 0)
                         + String(format: "%5d  %5d", raw[name] ?? 0, gated[name] ?? 0))
        }
        lines.append("total".padding(toLength: 28, withPad: " ", startingAt: 0)
                     + String(format: "%5d  %5d", recorded.count, gatedEvents.count))
        let report = lines.joined(separator: "\n")
        let attachment = XCTAttachment(string: report)
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["NOSTALGEX_TELEMETRY_OUT"] {
            try? report.write(toFile: dir + "/\(title).txt", atomically: true, encoding: .utf8)
        }
        return (raw, gated, report)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - In the suite

    /// 200 user channel changes through `tuneChannelFromUser` on a lineup where nothing
    /// plays. Each change sends channel.tuned and, from the load, playback.error.
    func testSurfingTwoHundredChannelsThroughTheRealAppState() {
        let channels = lineup(count: 40, minutes: 30)
        let state = makeState(Backend(file: nil), channels: channels)
        let recorder = Recorder()
        Analytics.configure(with: recorder, gate: nil)
        for flip in 0..<200 {
            state.tuneChannelFromUser(channels[flip % channels.count], method: flip.isMultiple(of: 10) ? .guide : .next)
        }
        state.invalidatePlaybackAttempt()
        let result = compare(recorder.events, title: "surf-200-no-source")
        XCTAssertEqual(result.raw["channel.tuned"], 200)
        XCTAssertEqual(result.raw["playback.error"], 200)
        // Compared by name: the test host's own AppState may add a launch-time signal.
        XCTAssertEqual(result.gated["channel.tuned"], 2, result.report)
        XCTAssertEqual(result.gated["playback.error"], 1, result.report)
        state.player = nil
    }

    /// One channel where every item fails, left alone. The app shows the reason for
    /// five seconds and skips to the next item, which fails the same way, forever.
    /// Measures the loop period; the gate sends the first error only.
    func testFailingChannelSkipsEveryFiveSecondsUntilSomeoneTunesAway() async {
        let channels = lineup(count: 1, minutes: 30)
        let state = makeState(Backend(file: nil), channels: channels)
        let recorder = Recorder()
        Analytics.configure(with: recorder, gate: nil)
        state.selectChannel(channels[0])
        await waitUntil(8) { recorder.events.filter { $0.event.name == "playback.error" }.count >= 2 }
        state.invalidatePlaybackAttempt()
        let errors = recorder.events.filter { $0.event.name == "playback.error" }
        XCTAssertGreaterThanOrEqual(errors.count, 2, "the skip loop keeps going with nobody at the remote")
        if errors.count >= 2 {
            let period = errors[1].at.timeIntervalSince(errors[0].at)
            XCTAssertEqual(period, 5, accuracy: 1, "one error every ~5s is ~720 an hour")
            let result = compare(recorder.events, title: String(format: "error-loop-period-%.1fs", period))
            XCTAssertEqual(result.gated["playback.error"], 1, result.report)
        }
        state.player = nil
    }

    // MARK: - Live (real playback)

    /// Plays generated H.264 through the real load path: `flips` channel changes with a
    /// short dwell, then one channel whose 4-second files end into the next programme
    /// over and over (a programme boundary every few seconds instead of every few minutes).
    func testRealPlaybackSurfAndProgrammeBoundaries() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["NOSTALGEX_TELEMETRY_LIVE"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_NOSTALGEX_TELEMETRY_LIVE=1 to play generated video")
        }
        let flips = Int(env["NOSTALGEX_TELEMETRY_FLIPS"] ?? "") ?? 20
        let long = FileManager.default.temporaryDirectory.appendingPathComponent("telemetry-long.mp4")
        let short = FileManager.default.temporaryDirectory.appendingPathComponent("telemetry-short.mp4")
        try await TestMovie.write(seconds: 1800, to: long)
        try await TestMovie.write(seconds: 4, to: short)

        // Surf: real readyToPlay, real watch time.
        let channels = lineup(count: 40, minutes: 30)
        let surf = makeState(Backend(file: long), channels: channels)
        let recorder = Recorder()
        Analytics.configure(with: recorder, gate: nil)
        var reachedPlaying = 0
        for flip in 0..<flips {
            surf.tuneChannelFromUser(channels[flip % channels.count], method: .next)
            await waitUntil(4) { surf.playbackState == .playing }
            if surf.playbackState == .playing { reachedPlaying += 1 }
            try await Task.sleep(for: .milliseconds(1300))
        }
        surf.emitPlaybackStoppedForActiveSession()
        Analytics.track(.sessionEnded(activeSeconds: 60))
        surf.invalidatePlaybackAttempt()
        surf.player?.pause()
        surf.player = nil
        let surfResult = compare(recorder.events, title: "surf-\(flips)-real-playback-\(reachedPlaying)-played")
        XCTAssertEqual(surfResult.raw["channel.tuned"], flips)
        XCTAssertGreaterThan(reachedPlaying, flips / 2, "generated video should play in the simulator")

        // Boundaries: one channel, 4-second programmes.
        let boundaryChannel = lineup(count: 1, minutes: 1)
        let boundary = makeState(Backend(file: short), channels: boundaryChannel)
        let boundaryRecorder = Recorder()
        Analytics.configure(with: boundaryRecorder, gate: nil)
        boundary.tuneChannelFromUser(boundaryChannel[0], method: .guide)
        let seconds = Double(env["NOSTALGEX_TELEMETRY_BOUNDARY_SECONDS"] ?? "") ?? 30
        try await Task.sleep(for: .seconds(seconds))
        boundary.emitPlaybackStoppedForActiveSession()
        Analytics.track(.sessionEnded(activeSeconds: seconds))
        boundary.invalidatePlaybackAttempt()
        boundary.player?.pause()
        boundary.player = nil
        let boundaryResult = compare(boundaryRecorder.events, title: String(format: "boundaries-%.0fs-4s-programmes", seconds))
        XCTAssertGreaterThan(boundaryResult.raw["playback.ready"] ?? 0, 2)
        XCTAssertLessThanOrEqual(boundaryResult.gated["playback.ready"] ?? 0, 1)
    }
}
