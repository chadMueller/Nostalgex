import XCTest
import AVFoundation
@testable import Nostalgex

/// N-013 live harness, not a unit test. What the Apple TV app does when the server cannot
/// burn a forced subtitle track into the picture (Emby 4.10.1.0: every burn-in job answers
/// HTTP 500 before ffmpeg starts).
///
/// Drives the production load path (`AppState.loadCurrentItem`, `selectChannel`, the
/// watchdog, the fail-fast probe, the error card, the skip and `ChannelFailureRun`) against a
/// lab server holding the synthetic films from `scripts/lab-forced-subtitle/make-media.sh`.
/// Point it at the logging proxy (`logproxy.py`) to get the request side as well.
///
/// Skipped unless a server is supplied (xcodebuild passes `TEST_RUNNER_`-prefixed variables
/// through to the test process):
///   NOSTALGEX_FS_URL       server or proxy base URL, e.g. http://127.0.0.1:8197
///   NOSTALGEX_FS_TOKEN     access token (never printed)
///   NOSTALGEX_FS_USER      user id
///   NOSTALGEX_FS_BACKEND   emby (default) or jellyfin
///   NOSTALGEX_FS_TITLES    test A: title fragments, one app load each
///   NOSTALGEX_FS_OBSERVE   test A: seconds to watch each title (default 45)
///   NOSTALGEX_FS_POOL_FORCED / NOSTALGEX_FS_POOL_MIXED   tests B, C: title fragments for a channel
///   NOSTALGEX_FS_CHANNEL_SECONDS   tests B, C: how long to watch the channel (default 150)
///   NOSTALGEX_FS_OUT       transcript file (every line also goes to stdout, prefix [FSBURN])
@MainActor
final class ForcedSubtitleBurnHarness: XCTestCase {
    private final class MemStore: Nostalgex.CredentialStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        @discardableResult
        func save(key: String, value: String) -> Bool { values[key] = value; return true }
        func load(key: String) -> String? { values[key] }
        func delete(key: String) { values[key] = nil }
    }

    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var out: [String] = []
    private var token = ""
    private var epoch0 = Date()

    private func emit(_ s: String) {
        let line = String(format: "[FSBURN] %.3f ", Date().timeIntervalSince1970) + s
        print(line); out.append(line)
        // Append: XCTest makes a new instance per test method, so overwriting kept only the last test.
        if let p = env["NOSTALGEX_FS_OUT"], let data = (line + "\n").data(using: .utf8) {
            if let h = FileHandle(forWritingAtPath: p) { h.seekToEndOfFile(); h.write(data); try? h.close() }
            else { FileManager.default.createFile(atPath: p, contents: data) }
        }
    }

    private func redact(_ s: String) -> String { token.isEmpty ? s : s.replacingOccurrences(of: token, with: "TOKEN") }

    private func describe(_ s: PlaybackState) -> String {
        switch s {
        case .error(let f): return "ERROR CARD [\(f.headline) | \(f.detail) | \(f.diagnosticSummary) | \(f.nextStep)]"
        default: return "\(s)"
        }
    }

    private func makeApp() async throws -> (AppState, [PlexMediaItem]) {
        guard let url = env["NOSTALGEX_FS_URL"], let tok = env["NOSTALGEX_FS_TOKEN"],
              let user = env["NOSTALGEX_FS_USER"] else {
            throw XCTSkip("No lab server configured (NOSTALGEX_FS_URL/TOKEN/USER)")
        }
        token = tok
        let backend = env["NOSTALGEX_FS_BACKEND"] ?? "emby"
        let app = AppState(credentialStore: MemStore())
        app.backendKind = backend == "jellyfin" ? .jellyfin : .emby
        app.serverURL = url
        app.token = tok
        app.jellyfinUserId = user
        app.setSelectedServers([AppState.ServerRef(
            machineIdentifier: "fs-harness", name: "FS Harness \(backend)",
            baseURL: url, owned: true, token: tok, userId: user)])
        await app.loadLibrary()
        emit("setup: backend=\(backend) library=\(app.allItems.count) items, subtitle language=\(SubtitleSelectionLogic.currentSubtitleLanguage()), "
             + "stream quality=\(StreamQuality.current.rawValue), errorCardSeconds=\(app.errorCardSeconds), failure limit=\(ChannelFailureRun.limit)")
        return (app, app.allItems)
    }

    private func fragments(_ key: String) -> [String] {
        (env[key] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func pick(_ items: [PlexMediaItem], _ frags: [String]) -> [PlexMediaItem] {
        frags.compactMap { f in items.first { $0.title.contains(f) } }
    }

    private func stop(_ app: AppState) {
        app.invalidatePlaybackAttempt()
        app.player?.pause()
        app.currentItem = nil
        app.currentChannel = nil
        app.loadCurrentItem()
    }

    // MARK: - A. Each film on its own through the production load path

    func testA_EachFilmThroughTheAppLoadPath() async throws {
        let (app, items) = try await makeApp()
        let observe = Double(env["NOSTALGEX_FS_OBSERVE"] ?? "") ?? 45
        for item in pick(items, fragments("NOSTALGEX_FS_TITLES")) {
            emit("A ===== \"\(item.title)\" container=\(item.container ?? "nil") video=\(item.videoCodec ?? "nil") audio=\(item.audioCodec ?? "nil") partKey=\(item.partKey ?? "nil")")
            app.currentItem = item
            app.seekOffset = 0
            let urlBefore = app.lastStreamURL.map { redact($0.absoluteString) }
            let t0 = Date()
            app.loadCurrentItem()
            var timeline: [String] = []
            var urls: [String] = []
            var outcome = "no terminal state in \(observe)s"
            var cardAt: Double?
            while Date().timeIntervalSince(t0) < observe {
                try await Task.sleep(nanoseconds: 100_000_000)
                let dt = Date().timeIntervalSince(t0)
                let s = describe(app.playbackState)
                if timeline.last.map({ !$0.hasSuffix(s) }) ?? true { timeline.append(String(format: "+%.1fs ", dt) + s) }
                if let u = app.lastStreamURL.map({ redact($0.absoluteString) }), u != urlBefore, urls.last != u { urls.append(u) }
                if case .error = app.playbackState, cardAt == nil {
                    cardAt = dt
                    outcome = String(format: "ERROR CARD at +%.1fs", dt)
                    // keep watching for the card's own length plus one second: does anything follow?
                    try await Task.sleep(nanoseconds: UInt64((app.errorCardSeconds + 1) * 1_000_000_000))
                    timeline.append(String(format: "+%.1fs after card: state=%@ currentItem=%@", Date().timeIntervalSince(t0),
                                           describe(app.playbackState), app.currentItem?.title ?? "nil"))
                    break
                }
                if case .playing = app.playbackState, (app.player?.currentTime().seconds ?? 0) > 3 {
                    outcome = String(format: "PLAYING at +%.1fs, playhead %.1fs", dt, app.player?.currentTime().seconds ?? -1)
                    break
                }
            }
            emit("A result: \(outcome)")
            for t in timeline { emit("A   timeline \(t)") }
            for u in urls { emit("A   stream url: \(u)") }
            emit("A   settings diagnostics: \(PlaybackDiagnostics.recent().first.map(redact) ?? "none")")
            stop(app)
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: - D. What AVPlayer's own logs hold while the server refuses the burn stream

    /// The app's fail-fast check (`failFastOnServerRefusal`, 4 s in) needs the player's error
    /// log to name the failing request (`uri`). This prints what the log really holds at
    /// 1, 2, 3, 4.5, 6, 8 and 12 s, and asks the app's own probe what the stream answers.
    func testD_PlayerLogsWhileTheBurnStreamIsRefused() async throws {
        let (app, items) = try await makeApp()
        let frag = env["NOSTALGEX_FS_D_TITLE"] ?? "Forced Lines Film"
        guard let item = items.first(where: { $0.title.contains(frag) }) else { return XCTFail("no item \(frag)") }
        app.currentItem = item
        app.seekOffset = 0
        let t0 = Date()
        app.loadCurrentItem()
        for at in [1.0, 2.0, 3.0, 4.5, 6.0, 8.0, 12.0] {
            while Date().timeIntervalSince(t0) < at { try await Task.sleep(nanoseconds: 50_000_000) }
            guard let pi = app.player?.currentItem else { emit("D +\(at)s no player item, state=\(describe(app.playbackState))"); continue }
            let events = pi.errorLog()?.events ?? []
            let last = events.last
            let access = pi.accessLog()?.events ?? []
            emit(String(format: "D +%.1fs state=%@ itemStatus=%d errorLog: %d event(s), any uri=%@, last: domain=%@ code=%d comment=%@ uri=%@ | accessLog events=%d | would fail-fast find a uri: %@",
                        Date().timeIntervalSince(t0), describe(app.playbackState), pi.status.rawValue, events.count,
                        events.contains { $0.uri != nil } ? "yes" : "no",
                        last?.errorDomain ?? "-", last?.errorStatusCode ?? 0, redact(last?.errorComment ?? "-"),
                        redact(last?.uri ?? "nil"), access.count,
                        events.reversed().compactMap({ $0.uri }).first == nil ? "NO" : "yes"))
            if at == 4.5, let url = app.lastStreamURL {
                let status = await StreamFailureProbe.refusalStatus(of: url, headers: app.api(for: item.serverID).authHeaders)
                emit("D the app's own probe on the stream URL it handed the player answers: \(status.map(String.init) ?? "nothing") (refusal=\(status.map(StreamFailureProbe.isRefusal) ?? false))")
            }
        }
        stop(app)

        // D2. AVPlayer alone on the same burn URL, none of the app's watchdogs: how long does it
        // keep retrying before it calls the item failed, and with what?
        let backend = app.api(for: item.serverID)
        guard let resolved = await backend.resolveTranscodePlayback(for: item), !resolved.isDirectPlay else {
            return emit("D2 no transcode resolution for \(item.title)")
        }
        emit("D2 bare AVPlayer on the burn URL (resolver answered a TranscodingUrl, direct=\(resolved.isDirectPlay)): \(redact(resolved.url.absoluteString).prefix(150))...")
        let pi = AVPlayerItem(url: resolved.url)
        pi.preferredForwardBufferDuration = 5
        let player = AVPlayer(playerItem: pi)
        player.isMuted = true
        player.play()
        let limit = Double(env["NOSTALGEX_FS_D2_SECONDS"] ?? "") ?? 75
        let b0 = Date()
        var lastCount = 0
        while Date().timeIntervalSince(b0) < limit {
            try await Task.sleep(nanoseconds: 250_000_000)
            let n = pi.errorLog()?.events.count ?? 0
            if n != lastCount { lastCount = n; emit(String(format: "D2 +%.1fs errorLog now holds %d event(s), last code=%d", Date().timeIntervalSince(b0), n, pi.errorLog()?.events.last?.errorStatusCode ?? 0)) }
            if pi.status == .failed {
                let e = pi.error as NSError?
                emit(String(format: "D2 AVPlayer item FAILED at +%.1fs: %@ %d \"%@\" underlying=%@", Date().timeIntervalSince(b0),
                            e?.domain ?? "-", e?.code ?? 0, e?.localizedDescription ?? "-",
                            ((e?.userInfo[NSUnderlyingErrorKey] as? NSError).map { "\($0.domain) \($0.code)" }) ?? "none"))
                break
            }
            if pi.status == .readyToPlay { emit(String(format: "D2 readyToPlay at +%.1fs", Date().timeIntervalSince(b0))); break }
        }
        if pi.status == .unknown { emit(String(format: "D2 still status=unknown after %.0fs (AVPlayer never gave up)", Date().timeIntervalSince(b0))) }
        player.pause(); player.replaceCurrentItem(with: nil)
        await backend.stopTranscode(playSessionId: resolved.playSessionId)
    }

    // MARK: - B, C. A channel, tuned the way a viewer tunes one

    private func watchChannel(name: String, id: Int, poolKey: String, successIsPlaying: Bool) async throws {
        let (app, items) = try await makeApp()
        let pool = pick(items, fragments(poolKey))
        guard !pool.isEmpty else { return XCTFail("no pool for \(poolKey)") }
        let seconds = Double(env["NOSTALGEX_FS_CHANNEL_SECONDS"] ?? "") ?? 150
        let ch = Channel(id: id, number: id, name: name, color: .blue, category: "nostalgex",
                         rules: ChannelRules(), timeRestrictions: nil, minItems: 0, itemPool: pool)
        app.allChannels = [ch]
        app.channels = [ch]
        emit("\(name) pool: " + pool.map(\.title).joined(separator: " | "))
        let t0 = Date()
        app.selectChannel(ch)
        var last = ""
        var attempts: [String] = []
        var verdict = "watched \(Int(seconds))s with no terminal state"
        var playingSince: Date?
        while Date().timeIntervalSince(t0) < seconds {
            try await Task.sleep(nanoseconds: 100_000_000)
            let dt = Date().timeIntervalSince(t0)
            let line = "item=\"\(app.currentItem?.title ?? "nil")\" run=\(app.channelFailureRun.count) state=\(describe(app.playbackState))"
            if line != last {
                emit(String(format: "%@ +%.1fs %@", name, dt, line))
                last = line
                if attempts.last != app.currentItem?.title { attempts.append(app.currentItem?.title ?? "nil") }
            }
            if case .error(let f) = app.playbackState, case .channelStopped = f {
                verdict = String(format: "CHANNEL STOPPED at +%.1fs after %d failed programmes", dt, app.channelFailureRun.count); break
            }
            if case .playing = app.playbackState, (app.player?.currentTime().seconds ?? 0) > 3 {
                if playingSince == nil { playingSince = Date() }
                if successIsPlaying, Date().timeIntervalSince(playingSince!) > 6, app.channelFailureRun.count == 0, !attempts.isEmpty,
                   attempts.count > 1 {
                    verdict = String(format: "PLAYING \"%@\" at +%.1fs (recovered after %d earlier programme(s))", app.currentItem?.title ?? "?", dt, attempts.count - 1); break
                }
            } else { playingSince = nil }
        }
        emit("\(name) verdict: \(verdict); programmes tried in order: " + attempts.joined(separator: " -> "))
        emit("\(name) settings diagnostics: " + PlaybackDiagnostics.recent().prefix(8).map(redact).joined(separator: " || "))
        stop(app)
    }

    func testB_ChannelOfOnlyForcedFilms() async throws {
        try await watchChannel(name: "CH91 ALL-FORCED", id: 91, poolKey: "NOSTALGEX_FS_POOL_FORCED", successIsPlaying: false)
    }

    func testC_ChannelMixedForcedAndPlain() async throws {
        try await watchChannel(name: "CH92 MIXED", id: 92, poolKey: "NOSTALGEX_FS_POOL_MIXED", successIsPlaying: true)
    }
}
