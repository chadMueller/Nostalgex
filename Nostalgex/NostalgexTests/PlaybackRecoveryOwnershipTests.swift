import AVFoundation
import XCTest
@testable import Nostalgex

/// Exercises the callbacks used by the startup watchdog and the one-second starvation
/// monitor on a real AppState/AVPlayerItem. Only the backend's async replies are controlled.
@MainActor
final class PlaybackRecoveryOwnershipTests: XCTestCase {
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
        UserDefaults.standard.removePersistentDomain(forName: "PlaybackRecoveryOwnershipTests")
    }

    private struct EmptyCredentials: CredentialStoring {
        func save(key: String, value: String) -> Bool { true }
        func load(key: String) -> String? { nil }
        func delete(key: String) {}
    }

    private actor Requests {
        typealias Result = (resolution: PlaybackResolution, startsAtOffset: Bool)
        var pending: [Int: CheckedContinuation<Result?, Never>] = [:]
        var kinds: [String] = []
        var stopped: [String] = []

        /// Intentionally ignores cancellation, like a response already delivered by a server.
        func resolve(_ kind: String) async -> Result? {
            let index = kinds.count
            kinds.append(kind)
            return await withCheckedContinuation { pending[index] = $0 }
        }

        func finish(_ index: Int, session: String?, startsAtOffset: Bool = true,
                    isDirectPlay: Bool = false, url: URL? = nil) {
            let result = session.map {
                (PlaybackResolution(url: url ?? URL(fileURLWithPath: "/synthetic-\($0).m3u8"),
                                    playSessionId: $0, isDirectPlay: isDirectPlay), startsAtOffset)
            }
            pending.removeValue(forKey: index)?.resume(returning: result)
        }

        func stop(_ session: String?) {
            if let session { stopped.append(session) }
        }

        func snapshot() -> (kinds: [String], stopped: [String]) { (kinds, stopped) }
    }

    private final class Backend: MediaBackend, @unchecked Sendable {
        let requests = Requests()
        let offersCappedStream: Bool
        let offersDirectPlay: Bool
        init(offersCappedStream: Bool = false, offersDirectPlay: Bool = false) {
            self.offersCappedStream = offersCappedStream
            self.offersDirectPlay = offersDirectPlay
        }
        let serverID = "synthetic"
        let authHeaders: [String: String] = [:]
        func testConnection() async throws -> String { "synthetic" }
        func loadLibrary(progress: LoadProgress?) async throws -> [PlexMediaItem] { [] }
        func loadSections() async throws -> [PlexSection] { [] }
        func loadCollections(sectionKey: String) async throws -> [PlexCollection] { [] }
        func loadCollectionItems(collectionKey: String) async throws -> [String] { [] }
        func buildDirectPlayURL(for item: PlexMediaItem) -> URL? {
            offersDirectPlay ? URL(fileURLWithPath: "/synthetic-missing.mp4") : nil
        }
        func buildTranscodeURL(for item: PlexMediaItem) -> URL? { URL(fileURLWithPath: "/synthetic.m3u8") }
        func thumbnailURL(for item: PlexMediaItem, width: Int) -> URL? { nil }
        func resolveTranscodePlayback(for item: PlexMediaItem, offsetSeconds: Int) async -> Requests.Result? {
            await requests.resolve("initial:\(item.ratingKey)")
        }
        func resolveServerStream(for item: PlexMediaItem, offsetSeconds: Int) async -> Requests.Result? {
            await requests.resolve("server:\(item.ratingKey)")
        }
        func stopTranscode(playSessionId: String?) async { await requests.stop(playSessionId) }
        func cappedTranscodeURL(for item: PlexMediaItem, offsetSeconds: Int, sessionID: String) -> URL? {
            guard offersCappedStream else { return nil }
            var components = URLComponents(url: URL(fileURLWithPath: "/synthetic.m3u8"), resolvingAgainstBaseURL: false)!
            components.queryItems = [.init(name: "session", value: sessionID)]
            return components.url
        }
        func prepareTranscodeSession(startURL: URL) async { _ = await requests.resolve("prepare") }
    }

    private func item(_ key: String = "first") -> PlexMediaItem {
        PlexMediaItem(id: key, title: "Synthetic", artist: nil, episodeTitle: nil, seTag: nil,
                      summary: "", year: nil, originallyAvailableAt: nil, contentRating: nil,
                      duration: 90, ratingKey: key, partKey: nil, container: "mp4", videoCodec: "h264",
                      audioCodec: "aac", videoProfile: nil, bitrate: nil, genres: [], rating: 0,
                      userRating: 0, type: .movie, thumb: nil, art: nil, viewCount: 0, addedAt: 0,
                      studio: nil, tmdbID: nil, imdbID: nil, librarySource: .movie, serverID: "synthetic")
    }

    private func makeState(_ backend: Backend) -> (AppState, AVPlayerItem) {
        let defaults = UserDefaults(suiteName: "PlaybackRecoveryOwnershipTests")!
        let sync = PreferenceSync(cloud: InMemoryKeyValueStore(), defaults: defaults,
                                  observeNotifications: false, keys: PreferenceSync.syncedKeys)
        let state = AppState(credentialStore: EmptyCredentials(), preferenceSync: sync)
        state.backendOverride = { _ in backend }
        state.currentItem = item()
        state.loadGeneration = 1
        let playerItem = AVPlayerItem(asset: AVMutableComposition())
        state.player = AVPlayer(playerItem: playerItem)
        state.playbackState = .playing
        state.beginPlaybackInformation(for: state.currentItem!, generation: state.loadGeneration)
        let information = state.beginPlaybackInformationAttempt(generation: state.loadGeneration,
            attempt: state.playbackAttemptGeneration, isDirectPlay: true)
        state.markPlaybackInformationReady(for: playerItem, generation: state.loadGeneration,
            attempt: state.playbackAttemptGeneration, attemptID: information)
        return (state, playerItem)
    }

    private func waitForRequests(_ count: Int, backend: Backend, timeout: TimeInterval = 2,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await backend.requests.snapshot().kinds.count < count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let actual = await backend.requests.snapshot().kinds.count
        XCTAssertGreaterThanOrEqual(actual, count, file: file, line: line)
    }

    private func starve(_ state: AppState, _ playerItem: AVPlayerItem, position: Int = 50) {
        state.handleStarvation(item: state.currentItem, isDirectPlay: true,
                               generation: state.loadGeneration, attempt: state.playbackAttemptGeneration,
                               playerItem: playerItem, allowCappedRetry: true, position: position,
                               title: "Synthetic", detail: "controlled stall")
    }

    func testRepeatedStarvationAndStartupWatchdogShareOneNegotiation() async {
        let backend = Backend()
        let (state, playerItem) = makeState(backend)
        var monitor = PlaybackStarvation()
        var verdicts = 0
        for second in 0...26 {
            if monitor.observe(playhead: Double(min(second, 2)), wall: Double(second),
                               paused: false, remaining: 1000) != nil {
                verdicts += 1
                starve(state, playerItem)
                await Task.yield()
            }
        }
        XCTAssertEqual(verdicts, 4, "the real monitor repeats its verdict while the backend is pending")
        XCTAssertEqual(state.playbackInformation?.reason, .streamStalled)
        XCTAssertEqual(state.playbackInformation?.isReady, false)
        state.handleWatchdogNoPicture(playerItem: playerItem, item: state.currentItem,
                                      isDirectPlay: true, generation: state.loadGeneration,
                                      attempt: state.playbackAttemptGeneration, allowCappedRetry: true,
                                      deadline: 15, detail: "overlapping startup deadline")
        await waitForRequests(1, backend: backend)
        let requests = await backend.requests.snapshot()
        XCTAssertEqual(requests.kinds, ["server:first"], "all recovery uses the forced server-stream resolver")
        XCTAssertEqual(state.playbackInformation?.reason, .streamStalled, "a competing watchdog must not overwrite the winning recovery")
        let task = state.playbackResolutionTask
        state.invalidatePlaybackAttempt()
        await backend.requests.finish(0, session: "retired")
        await task?.value
        let final = await backend.requests.snapshot()
        XCTAssertEqual(final.stopped, ["retired"])
        state.player = nil
    }

    func testLateRecoveryAfterChannelLoadCleansSessionWithoutTouchingNewPlayer() async {
        let backend = Backend()
        let (state, playerItem) = makeState(backend)
        starve(state, playerItem)
        await waitForRequests(1, backend: backend)
        let retired = state.playbackResolutionTask
        state.currentItem = nil
        state.loadCurrentItem() // the actual channel-load invalidation path
        let nextPlayer = AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition()))
        state.player = nextPlayer
        await backend.requests.finish(0, session: "late")
        await retired?.value
        XCTAssertTrue(state.player === nextPlayer)
        XCTAssertNil(state.activeTranscode)
        XCTAssertEqual(state.hlsRequestedOffset, 0)
        XCTAssertNil(state.playbackInformation)
        let final = await backend.requests.snapshot()
        XCTAssertEqual(final.stopped, ["late"])
        state.player = nil
    }

    func testOldWatchdogCannotRecoverReplacementInsideSameChannelGeneration() async {
        let backend = Backend()
        let (state, oldItem) = makeState(backend)
        let generation = state.loadGeneration
        let attempt = state.playbackAttemptGeneration
        let replacement = AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition()))
        state.player = replacement // identity guard is required even without a generation change
        state.handleWatchdogNoPicture(playerItem: oldItem, item: state.currentItem,
                                      isDirectPlay: true, generation: generation, attempt: attempt,
                                      allowCappedRetry: true, deadline: 15, detail: "old deadline")
        await Task.yield()
        let result = await backend.requests.snapshot()
        XCTAssertTrue(result.kinds.isEmpty)
        XCTAssertFalse(state.playbackRecoveryInFlight)
        XCTAssertTrue(state.player === replacement)
        state.player = nil
    }

    func testOldCompletionCannotClearOrReplaceNewerRecovery() async {
        let backend = Backend()
        let (state, oldItem) = makeState(backend)
        starve(state, oldItem)
        await waitForRequests(1, backend: backend)
        let retired = state.playbackResolutionTask
        state.invalidatePlaybackAttempt()
        let newItem = AVPlayerItem(asset: AVMutableComposition())
        state.player = AVPlayer(playerItem: newItem)
        starve(state, newItem, position: 70)
        await waitForRequests(2, backend: backend)
        let current = state.playbackResolutionTask
        let currentInformation = state.playbackInformation
        await backend.requests.finish(0, session: "old")
        await retired?.value
        XCTAssertTrue(state.playbackRecoveryInFlight)
        XCTAssertNil(state.activeTranscode)
        XCTAssertEqual(state.playbackInformation, currentInformation)
        await backend.requests.finish(1, session: "new")
        await current?.value
        XCTAssertEqual(state.activeTranscode?.playSessionId, "new")
        XCTAssertEqual(state.seekOffset, 70)
        XCTAssertEqual(state.playbackInformation?.reason, .streamStalled)
        XCTAssertEqual(state.playbackInformation?.delivery, .serverStream)
        XCTAssertEqual(state.playbackInformation?.isReady, false)
        let result = await backend.requests.snapshot()
        XCTAssertEqual(result.stopped, ["old"])
        state.invalidatePlaybackAttempt() // cancel the real 300ms fallback before any file is opened
        state.player = nil
    }

    func testInitialNegotiationReplyAfterRapidSurfCannotChangeOffsetOrSession() async {
        let backend = Backend()
        let (state, _) = makeState(backend)
        state.seekOffset = 25
        state.loadCurrentItem()
        await waitForRequests(1, backend: backend)
        let retired = state.playbackResolutionTask
        state.currentItem = item("second")
        state.seekOffset = 900
        state.loadCurrentItem()
        await waitForRequests(2, backend: backend)
        let current = state.playbackResolutionTask
        let secondInformation = state.playbackInformation
        await backend.requests.finish(0, session: "first-late")
        await retired?.value
        XCTAssertNil(state.activeTranscode)
        XCTAssertEqual(state.hlsRequestedOffset, 0)
        XCTAssertEqual(state.seekOffset, 900)
        XCTAssertEqual(state.playbackInformation, secondInformation)
        XCTAssertEqual(state.playbackInformation?.generation, state.loadGeneration)
        let result = await backend.requests.snapshot()
        // Cleanup of initial resolution is detached, so drain it without fixed sleeps.
        let deadline = Date().addingTimeInterval(2)
        while await backend.requests.snapshot().stopped.isEmpty, Date() < deadline { await Task.yield() }
        let final = await backend.requests.snapshot()
        XCTAssertEqual(final.stopped, ["first-late"])
        XCTAssertEqual(result.kinds, ["initial:first", "initial:second"])
        state.invalidatePlaybackAttempt()
        await backend.requests.finish(1, session: "second-late")
        await current?.value
        state.player = nil
    }

    func testCancelledPreparationCleansItsSessionAfterTheBackendReturns() async {
        let backend = Backend(offersCappedStream: true)
        let (state, playerItem) = makeState(backend)
        // This is the production watchdog -> capped URL -> delayed prepare -> player path.
        state.handleWatchdogNoPicture(playerItem: playerItem, item: state.currentItem,
                                      isDirectPlay: false, generation: state.loadGeneration,
                                      attempt: state.playbackAttemptGeneration, allowCappedRetry: true,
                                      deadline: 20, detail: "controlled no-picture stream")
        let session = state.activeTranscode?.playSessionId
        XCTAssertNotNil(session)
        XCTAssertEqual(state.playbackInformation?.reason, .startupNoPicture)
        XCTAssertEqual(state.playbackInformation?.recoveryRequest, .compatibility1080p)
        XCTAssertEqual(state.playbackInformation?.isReady, false)
        await waitForRequests(1, backend: backend)
        let preparing = state.playbackResolutionTask
        state.currentItem = nil
        state.loadCurrentItem()
        await backend.requests.finish(0, session: nil)
        await preparing?.value
        let deadline = Date().addingTimeInterval(2)
        while await backend.requests.snapshot().stopped.count < 2, Date() < deadline { await Task.yield() }
        let result = await backend.requests.snapshot()
        XCTAssertEqual(result.kinds, ["prepare"])
        XCTAssertEqual(result.stopped, [session!, session!],
                       "channel teardown stops it, then late prepare cleanup stops a potentially reopened session")
        XCTAssertNil(state.lastStreamURL, "the cancelled preparation must never install a player item")
        XCTAssertNil(state.playbackInformation)
        state.player = nil
    }

    func testCancelledDebounceDoesNotStartObsoleteNegotiation() async {
        let backend = Backend()
        let (state, _) = makeState(backend)
        state.loadCurrentItem()
        let retired = state.playbackResolutionTask
        state.currentItem = item("second")
        state.loadCurrentItem()
        await retired?.value
        await waitForRequests(1, backend: backend)
        let current = state.playbackResolutionTask
        let result = await backend.requests.snapshot()
        XCTAssertEqual(result.kinds, ["initial:second"])
        state.invalidatePlaybackAttempt()
        await backend.requests.finish(0, session: nil)
        await current?.value
        state.player = nil
    }

    func testWatchdogInformationDescribesPendingRecoveryWithoutRevivingTheOldReadyCallback() async {
        let backend = Backend()
        let (state, playerItem) = makeState(backend)
        let owner = state.playbackAttemptGeneration
        let oldInformation = state.playbackInformation?.attemptID
        state.handleWatchdogNoPicture(playerItem: playerItem, item: state.currentItem,
                                      isDirectPlay: true, generation: state.loadGeneration,
                                      attempt: owner, allowCappedRetry: true,
                                      deadline: 15, detail: "controlled no-picture stream")
        await waitForRequests(1, backend: backend)
        XCTAssertEqual(state.playbackInformation?.reason, .startupNoPicture)
        XCTAssertEqual(state.playbackInformation?.isReady, false)
        state.markPlaybackInformationReady(for: playerItem, generation: state.loadGeneration,
                                           attempt: owner, attemptID: oldInformation)
        XCTAssertEqual(state.playbackInformation?.isReady, false)
        let pending = state.playbackResolutionTask
        await backend.requests.finish(0, session: "watchdog")
        await pending?.value
        XCTAssertEqual(state.playbackInformation?.reason, .startupNoPicture)
        XCTAssertEqual(state.playbackInformation?.delivery, .serverStream)
        state.invalidatePlaybackAttempt()
        state.stopActiveTranscodeIfNeeded()
        state.player = nil
    }

    func testServerRecoveryInformationUsesTheResolversDeliveryEvidence() async {
        let backend = Backend()
        let (state, playerItem) = makeState(backend)
        starve(state, playerItem)
        await waitForRequests(1, backend: backend)
        let pending = state.playbackResolutionTask
        await backend.requests.finish(0, session: "direct-result", isDirectPlay: true)
        await pending?.value
        XCTAssertEqual(state.playbackInformation?.delivery, .directPlay)
        XCTAssertEqual(state.playbackInformation?.reason, .streamStalled)
        XCTAssertEqual(state.playbackInformation?.isReady, false, "a resolver result is not player readiness")
        state.invalidatePlaybackAttempt()
        state.stopActiveTranscodeIfNeeded()
        state.player = nil
    }

    func testStaleInformationInitializationCannotReplaceTheCurrentProgram() {
        let backend = Backend()
        let (state, _) = makeState(backend)
        state.loadGeneration += 1
        state.beginPlaybackInformation(for: item("second"), generation: state.loadGeneration)
        let current = state.playbackInformation
        state.beginPlaybackInformation(for: item("retired"), generation: state.loadGeneration - 1)
        XCTAssertEqual(state.playbackInformation, current)
        state.invalidatePlaybackAttempt()
        state.player = nil
    }

    func testDirectPlayerFailurePublishesItsFallbackReasonDuringPreparation() async {
        let backend = Backend(offersDirectPlay: true)
        let (state, _) = makeState(backend)
        state.loadCurrentItem()
        // The missing local file drives the production AVPlayerItem failure callback.
        // The server preparation remains controlled and never contacts a media server.
        await waitForRequests(1, backend: backend, timeout: 5)
        let snapshot = await backend.requests.snapshot()
        XCTAssertEqual(snapshot.kinds, ["prepare"])
        XCTAssertEqual(state.playbackInformation?.reason, .directPlayFailed)
        XCTAssertEqual(state.playbackInformation?.delivery, .serverStream)
        XCTAssertEqual(state.playbackInformation?.isReady, false)
        let preparing = state.playbackResolutionTask
        state.invalidatePlaybackAttempt()
        await backend.requests.finish(0, session: nil)
        await preparing?.value
        state.player = nil
    }

    func testFailedServerStreamRetryRetiresThePreviousInformationAttempt() async {
        let backend = Backend()
        let (state, _) = makeState(backend)
        state.loadCurrentItem()
        await waitForRequests(1, backend: backend)
        let resolving = state.playbackResolutionTask
        let firstOwner = state.playbackAttemptGeneration
        // Missing HLS can remain in loading while AVFoundation waits on its playlist.
        // A missing local MP4 deterministically exercises the same .failed callback.
        await backend.requests.finish(0, session: "missing-local-file",
                                      url: URL(fileURLWithPath: "/synthetic-missing-retry.mp4"))
        await resolving?.value
        let deadline = Date().addingTimeInterval(5)
        while state.playbackInformation?.reason != .playerRetry, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.playbackInformation?.reason, .playerRetry)
        XCTAssertEqual(state.playbackInformation?.delivery, .serverStream)
        XCTAssertEqual(state.playbackInformation?.isReady, false)
        XCTAssertGreaterThan(state.playbackAttemptGeneration, firstOwner)
        state.invalidatePlaybackAttempt()
        state.stopActiveTranscodeIfNeeded()
        state.player = nil
    }
    private func checkOriginalVideoRecovery(startup: Bool) async {
        for explicit in [false, true] {
            let backend = Backend(offersCappedStream: true)
            let (state, playerItem) = makeState(backend)
            let candidate = await PlexAPIService.resolveOriginalVideoCandidate(
                url: URL(fileURLWithPath: "/synthetic-original.m3u8"), sessionID: "original",
                offsetSeconds: 50, requiresOriginalVideo: explicit,
                prepare: { _ in .init(code: "1001", text: "ok", preservesOriginalVideo: true, preservesOriginalAudio: true) },
                stop: { _ in }, fallback: { nil })
            state.playbackRequiresOriginalVideo = candidate!.resolution.requiresOriginalVideo
            if startup {
                state.handleWatchdogNoPicture(playerItem: playerItem, item: state.currentItem,
                    isDirectPlay: false, generation: state.loadGeneration, attempt: state.playbackAttemptGeneration,
                    allowCappedRetry: true, deadline: 20, detail: "controlled original-video startup")
            } else {
                state.handleStarvation(item: state.currentItem, isDirectPlay: false,
                    generation: state.loadGeneration, attempt: state.playbackAttemptGeneration,
                    playerItem: playerItem, allowCappedRetry: true, position: 50,
                    title: "Synthetic", detail: "controlled original-video stall")
            }
            if explicit {
                XCTAssertNil(state.activeTranscode)
                let requests = await backend.requests.snapshot()
                XCTAssertTrue(requests.kinds.isEmpty, "explicit Original must not request a capped stream")
            } else {
                XCTAssertNotNil(state.activeTranscode?.playSessionId)
                XCTAssertEqual(state.playbackInformation?.recoveryRequest, .compatibility1080p)
                await waitForRequests(1, backend: backend)
            }
            let pending = state.playbackResolutionTask
            state.currentItem = nil
            state.loadCurrentItem()
            if !explicit { await backend.requests.finish(0, session: nil) }
            await pending?.value
            state.player = nil
        }
    }

    func testAutomaticOriginalVideoKeepsStartupCappedRescue() async {
        await checkOriginalVideoRecovery(startup: true)
    }

    func testAutomaticOriginalVideoKeepsStallCappedRescue() async {
        await checkOriginalVideoRecovery(startup: false)
    }

}
