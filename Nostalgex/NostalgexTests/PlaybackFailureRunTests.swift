import AVFoundation
import XCTest
@testable import Nostalgex

/// How a failed programme is reported and when a channel stops trying. Real AppState,
/// real AVPlayer; the backends hand out files that are missing (fails in milliseconds),
/// no URL at all, or a generated movie that plays.
@MainActor
final class PlaybackFailureRunTests: XCTestCase {
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
        UserDefaults.standard.removePersistentDomain(forName: "PlaybackFailureRunTests")
    }

    // MARK: - Fixtures

    private final class Recorder: AnalyticsService, @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [(at: Date, event: AnalyticsEvent)] = []
        var events: [(at: Date, event: AnalyticsEvent)] { lock.lock(); defer { lock.unlock() }; return _events }
        var errors: [AnalyticsEvent] { events.map(\.event).filter { $0.name == "playback.error" } }
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

    /// `direct` and `transcode` decide which URLs each item gets; every call is counted so
    /// a test can tell whether the app is still asking the server for anything.
    private final class Backend: MediaBackend, @unchecked Sendable {
        let direct: @Sendable (PlexMediaItem) -> URL?
        let transcode: @Sendable (PlexMediaItem) -> URL?
        private let lock = NSLock()
        private var _requests = 0
        var requests: Int { lock.lock(); defer { lock.unlock() }; return _requests }
        init(direct: @escaping @Sendable (PlexMediaItem) -> URL?, transcode: @escaping @Sendable (PlexMediaItem) -> URL? = { _ in nil }) {
            self.direct = direct
            self.transcode = transcode
        }
        let serverID = "synthetic"
        let authHeaders: [String: String] = [:]
        func testConnection() async throws -> String { "synthetic" }
        func loadLibrary(progress: LoadProgress?) async throws -> [PlexMediaItem] { [] }
        func loadSections() async throws -> [PlexSection] { [] }
        func loadCollections(sectionKey: String) async throws -> [PlexCollection] { [] }
        func loadCollectionItems(collectionKey: String) async throws -> [String] { [] }
        func buildDirectPlayURL(for item: PlexMediaItem) -> URL? {
            lock.lock(); _requests += 1; lock.unlock()
            return direct(item)
        }
        func buildTranscodeURL(for item: PlexMediaItem) -> URL? { transcode(item) }
        func thumbnailURL(for item: PlexMediaItem, width: Int) -> URL? { nil }
    }

    static let missingFile = URL(fileURLWithPath: "/nostalgex-missing.mp4")
    static let missingPlaylist = URL(fileURLWithPath: "/nostalgex-missing.m3u8")

    private func item(_ key: String) -> PlexMediaItem {
        PlexMediaItem(id: key, title: "Synthetic \(key)", artist: nil, episodeTitle: nil, seTag: nil,
                      summary: "", year: nil, originallyAvailableAt: nil, contentRating: nil,
                      duration: 30, ratingKey: key, partKey: nil, container: "mp4", videoCodec: "h264",
                      audioCodec: "aac", videoProfile: nil, bitrate: nil, genres: [], rating: 0,
                      userRating: 0, type: .movie, thumb: nil, art: nil, viewCount: 0, addedAt: 0,
                      studio: nil, tmdbID: nil, imdbID: nil, librarySource: .movie, serverID: "synthetic")
    }

    private func channel(_ id: Int, keys: [String]) -> Channel {
        Channel(id: id, number: id, name: "SYNTHETIC \(id)", color: .blue, category: "nostalgex",
                rules: ChannelRules(), timeRestrictions: nil, minItems: 0, itemPool: keys.map(item))
    }

    private func makeState(_ backend: Backend, channels: [Channel]) -> AppState {
        let defaults = UserDefaults(suiteName: "PlaybackFailureRunTests")!
        let sync = PreferenceSync(cloud: InMemoryKeyValueStore(), defaults: defaults,
                                  observeNotifications: false, keys: PreferenceSync.syncedKeys)
        let state = AppState(credentialStore: NoCredentials(), preferenceSync: sync)
        state.backendOverride = { _ in backend }
        state.allChannels = channels
        state.channels = channels
        return state
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func isShowingFailure(_ state: AppState) -> Bool {
        if case .error = state.playbackState { return true }
        return false
    }

    private func tearDown(_ state: AppState) {
        state.invalidatePlaybackAttempt()
        state.player?.pause()
        state.player = nil
    }

    // MARK: - One report per failure

    /// Direct play fails and there is no server stream: the player retries once, the
    /// retry fails, the card shows. That is one failure and one `playback.error`.
    func testRetryPathReportsOneErrorPerFailure() async {
        let backend = Backend(direct: { _ in Self.missingFile })
        let ch = channel(1, keys: ["a", "b", "c"])
        let state = makeState(backend, channels: [ch])
        let recorder = Recorder()
        Analytics.configure(with: recorder, gate: nil)
        state.selectChannel(ch)
        await waitUntil(5) { isShowingFailure(state) }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(isShowingFailure(state))
        XCTAssertEqual(recorder.errors.count, 1, "\(recorder.errors.map { $0.parameters["code"] ?? "" })")
        tearDown(state)
    }

    /// Direct play fails, the server stream is tried and fails too: one fallback signal,
    /// one `playback.error`.
    func testTranscodeFailedPathReportsOneErrorPerFailure() async {
        let backend = Backend(direct: { _ in Self.missingFile }, transcode: { _ in Self.missingPlaylist })
        let ch = channel(2, keys: ["a", "b", "c"])
        let state = makeState(backend, channels: [ch])
        let recorder = Recorder()
        Analytics.configure(with: recorder, gate: nil)
        state.selectChannel(ch)
        // tvOS 27 can report the missing HLS file after the old five-second deadline.
        await waitUntil(30) { isShowingFailure(state) }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(isShowingFailure(state))
        XCTAssertEqual(recorder.events.filter { $0.event.name == "playback.transcode_fallback" }.count, 1)
        XCTAssertEqual(recorder.errors.count, 1, "\(recorder.errors.map { $0.parameters["code"] ?? "" })")
        tearDown(state)
    }

    // MARK: - A channel where nothing plays stops

    /// (a) Every programme fails at once (no stream to open). The first four show their
    /// card and skip; the fifth stops the channel. Nothing more is asked of the server.
    /// (d) The gate sends one playback.error for the code; the session summary counts five.
    func testChannelWhereNothingPlaysStopsAfterFiveFailures() async throws {
        let backend = Backend(direct: { _ in nil })
        let ch = channel(3, keys: ["a", "b", "c", "d", "e", "f"])
        let state = makeState(backend, channels: [ch])
        state.errorCardSeconds = 0.05
        let recorder = Recorder()
        Analytics.configure(with: recorder, gate: nil)

        state.selectChannel(ch)
        await waitUntil(5) { state.channelFailureRun.isStopped }
        XCTAssertTrue(state.channelFailureRun.isStopped)
        XCTAssertEqual(state.channelFailureRun.count, ChannelFailureRun.limit)
        XCTAssertEqual(backend.requests, 5, "one load per failure, then none")
        guard case .error(.channelStopped(let last)) = state.playbackState else {
            return XCTFail("expected the stopped card, got \(state.playbackState)")
        }
        XCTAssertEqual(last.analyticsCode, .noPlayableSource)
        XCTAssertNil(state.playbackSkipTask, "no skip is pending")
        XCTAssertNil(state.player?.currentItem)

        try await Task.sleep(for: .milliseconds(600))   // twelve card lengths
        XCTAssertEqual(backend.requests, 5, "still nothing asked of the server")
        XCTAssertEqual(recorder.errors.count, 5, "one report per failure")
        XCTAssertTrue(state.channelFailureRun.isStopped)

        // (d) Through the gate: one error for the one code; the summary counts failures.
        var gate = AnalyticsGate()
        let recorded = recorder.events + [(Date(), AnalyticsEvent.sessionEnded(activeSeconds: 30))]
        let sent = recorded.flatMap { gate.admit($0.event, at: $0.at) }
        XCTAssertEqual(sent.filter { $0.name == "playback.error" }.count, 1)
        guard case .sessionEnded(_, let summary?) = sent.last else { return XCTFail("no summary") }
        XCTAssertEqual(summary.playbackErrors, 5)
        XCTAssertEqual(summary.wireParameters["playbackErrors"], "2-5")
        tearDown(state)
    }

    /// (b) One bad programme on a channel that otherwise plays: the card shows, the
    /// channel moves on, and the next programme plays. No stop.
    func testOneBadProgrammeStillSkipsAndThePlayingCarriesOn() async throws {
        let movie = FileManager.default.temporaryDirectory.appendingPathComponent("failure-run-good.mp4")
        try await TestMovie.write(seconds: 120, framesPerSecond: 10, to: movie)
        let backend = Backend(direct: { $0.ratingKey == "bad" ? Self.missingFile : movie })
        let ch = channel(4, keys: ["bad", "good1", "good2", "good3"])
        let state = makeState(backend, channels: [ch])
        state.errorCardSeconds = 0.05
        let recorder = Recorder()
        Analytics.configure(with: recorder, gate: nil)

        state.currentChannel = ch
        state.currentItem = item("bad")
        state.seekOffset = 0
        state.loadCurrentItem()
        await waitUntil(8) { state.playbackState == .playing }
        XCTAssertEqual(state.playbackState, .playing, "the next programme plays")
        XCTAssertNotEqual(state.currentItem?.ratingKey, "bad")
        XCTAssertEqual(recorder.errors.count, 1)
        XCTAssertEqual(state.channelFailureRun.count, 1)
        XCTAssertFalse(state.channelFailureRun.isStopped)
        tearDown(state)
    }

    /// Four failures in a row, then a programme that plays. The watchdog confirms the
    /// picture at its deadline (15s for direct play) and the run starts again from zero.
    func testConfirmedPictureResetsTheRun() async throws {
        let movie = FileManager.default.temporaryDirectory.appendingPathComponent("failure-run-good.mp4")
        try await TestMovie.write(seconds: 120, framesPerSecond: 10, to: movie)
        let ch = channel(5, keys: ["good1", "good2"])
        let state = makeState(Backend(direct: { _ in movie }), channels: [ch])
        for _ in 0..<4 { _ = state.channelFailureRun.recordFailure(onChannel: ch.id) }

        state.currentChannel = ch
        state.currentItem = item("good1")
        state.seekOffset = 0
        state.loadCurrentItem()
        await waitUntil(8) { state.playbackState == .playing }
        XCTAssertEqual(state.channelFailureRun.count, 4, "ready alone is not proof of a picture")
        await waitUntil(25) { state.channelFailureRun.count == 0 }
        XCTAssertEqual(state.channelFailureRun.count, 0)
        tearDown(state)
    }

    // MARK: - The viewer starts it again

    /// (c) A stopped channel restarts when the viewer tunes elsewhere, selects it again,
    /// or the app comes back to the foreground (the views call `selectChannel` then).
    func testTuningOrReselectingStartsAFreshRun() async {
        let backend = Backend(direct: { _ in nil })
        let dead = channel(6, keys: ["a", "b", "c"])
        let other = channel(7, keys: ["x", "y"])
        let state = makeState(backend, channels: [dead, other])
        state.errorCardSeconds = 0.05
        Analytics.configure(with: Recorder(), gate: nil)

        state.selectChannel(dead)
        await waitUntil(5) { state.channelFailureRun.isStopped }
        XCTAssertTrue(state.channelFailureRun.isStopped)

        // Another channel: a fresh run there, which (also unplayable) counts from one.
        state.tuneChannelFromUser(other, method: .next)
        XCTAssertEqual(state.channelFailureRun.channelID, other.id)
        XCTAssertEqual(state.channelFailureRun.count, 1)
        XCTAssertFalse(state.channelFailureRun.isStopped)
        state.invalidatePlaybackAttempt()

        // The stopped channel, selected again: it tries again from zero.
        let before = backend.requests
        state.tuneChannelFromUser(dead, method: .guide)
        XCTAssertEqual(state.channelFailureRun.count, 1)
        XCTAssertEqual(backend.requests, before + 1)
        await waitUntil(5) { state.channelFailureRun.isStopped }
        XCTAssertTrue(state.channelFailureRun.isStopped, "and stops again if it still cannot play")

        // Foreground return re-selects the current channel.
        let stoppedAt = backend.requests
        state.selectChannel(dead)
        XCTAssertEqual(backend.requests, stoppedAt + 1)
        XCTAssertEqual(state.channelFailureRun.count, 1)
        tearDown(state)
    }

    // MARK: - Pieces

    func testFailureRunCountsPerChannel() {
        var run = ChannelFailureRun()
        for n in 1..<ChannelFailureRun.limit {
            XCTAssertFalse(run.recordFailure(onChannel: 1), "\(n)")
        }
        XCTAssertFalse(run.recordFailure(onChannel: 2), "another channel starts its own run")
        XCTAssertEqual(run.count, 1)
        for _ in 1..<ChannelFailureRun.limit - 1 { _ = run.recordFailure(onChannel: 2) }
        XCTAssertTrue(run.recordFailure(onChannel: 2))
        XCTAssertTrue(run.isStopped)
        XCTAssertTrue(run.recordFailure(onChannel: 2), "a late failure keeps it stopped")
        run.reset()
        XCTAssertEqual(run, ChannelFailureRun())
        XCTAssertEqual(ChannelFailureRun.limit, 5)
    }

    func testStoppedCardWording() {
        let last = PlaybackFailure.serverRefused(server: "Emby", status: 500)
        let stopped = PlaybackFailure.channelStopped(last: last)
        XCTAssertEqual(stopped.headline, "Nothing on this channel will play right now")
        XCTAssertEqual(stopped.detail,
                       "5 programmes in a row wouldn't play, so this channel has stopped trying. "
                       + "Last reason: Your server wouldn't start this one.")
        XCTAssertEqual(stopped.nextStep, "Try another channel, or select this one again to retry.")
        XCTAssertEqual(last.nextStep, "Moving on to the next programme.")
        XCTAssertEqual(stopped.analyticsCode, last.analyticsCode)
        XCTAssertEqual(stopped.isServerSide, last.isServerSide)
        for text in [stopped.headline, stopped.detail, stopped.nextStep, stopped.diagnosticSummary] {
            XCTAssertFalse(text.contains("\u{2014}"), "no em dashes: \(text)")
        }
    }
}

/// A silent grey H.264 movie, written once per path. Small enough to make in a test.
enum TestMovie {
    static func write(seconds: Int, framesPerSecond: Int = 1, to url: URL) async throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        let partial = url.appendingPathExtension("partial.mp4")
        try? FileManager.default.removeItem(at: partial)
        let writer = try AVAssetWriter(outputURL: partial, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0...(seconds * framesPerSecond) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0x80, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(framesPerSecond)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        try FileManager.default.moveItem(at: partial, to: url)
    }
}
