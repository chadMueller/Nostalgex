import XCTest
import AVFoundation
@testable import Nostalgex

/// The end rule on a real Apple TV with the real player code: signs a harness `AppState` into a live Emby or
/// Jellyfin server, tunes a channel at a clock set a few seconds before a chosen title ends, lets `AppState`
/// play it to its end and on into the next programme, and times the gap between the last frame of the one and
/// the first frame of the next by reading the frame number coded in the top strip of each frame (the I-052 test
/// files). Runs only with TEST_RUNNER_NX_LIVE_SERVER_CONFIG (JSON: base, token, userId, serverId),
/// TEST_RUNNER_NX_LIVE_KIND and TEST_RUNNER_NX_END_TITLES ("title@lead,title@lead", lead in seconds before the
/// end), and only under TEST_RUNNER_NOSTALGEX_HARNESS_ROOT, so the TV's real sign-in and stores are never
/// touched. Prints `[ENDPROOF]` lines; the token is never printed.
@MainActor
final class LiveEndOfProgrammeHarness: XCTestCase {

    private func frameCode(_ pb: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let scale = Double(CVPixelBufferGetWidthOfPlane(pb, 0)) / 1920
        var v = 0
        for b in 0..<16 {
            var sum = 0, n = 0
            for y in Int(20 * scale)..<Int(44 * scale) {
                for x in Int(Double(b * 120 + 30) * scale)..<Int(Double(b * 120 + 90) * scale) { sum += Int(base[y * stride + x]); n += 1 }
            }
            if n > 0, sum / n > 128 { v |= 1 << b }
        }
        return v
    }

    func testEachTitlePlaysToItsEndAndTheNextStarts() async throws {
        let env = ProcessInfo.processInfo.environment
        guard HarnessIsolation.isActive, let cfgText = env["NX_LIVE_SERVER_CONFIG"], let kind = env["NX_LIVE_KIND"],
              let titlesSpec = env["NX_END_TITLES"] else {
            throw XCTSkip("set TEST_RUNNER_NOSTALGEX_HARNESS_ROOT, TEST_RUNNER_NX_LIVE_SERVER_CONFIG, TEST_RUNNER_NX_LIVE_KIND and TEST_RUNNER_NX_END_TITLES")
        }
        let cfg = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(cfgText.utf8)) as? [String: String])
        let base = try XCTUnwrap(cfg["base"]), token = try XCTUnwrap(cfg["token"]), userId = try XCTUnwrap(cfg["userId"])
        let serverId = cfg["serverId"] ?? ""

        let state = AppState()
        var clockBase = Date()
        var clockStart = Date()
        state.scheduleClock = { clockBase.addingTimeInterval(Date().timeIntervalSince(clockStart)) }
        if kind == "emby" {
            await state.completeEmbyAuth(serverURL: base, result: .init(accessToken: token, userId: userId, serverID: serverId, serverName: "Lab"))
        } else {
            throw XCTSkip("jellyfin: not wired in this harness yet")
        }
        let loaded = Date()
        while state.allChannels.isEmpty, Date().timeIntervalSince(loaded) < 120 { try await Task.sleep(for: .milliseconds(250)) }
        print("[ENDPROOF] channels: \(state.allChannels.map { "\($0.number) \($0.name) (\($0.itemPool.count))" })")

        for spec in titlesSpec.split(separator: ",") {
            let parts = spec.split(separator: "@")
            let title = String(parts[0]), lead = Double(parts.count > 1 ? String(parts[1]) : "15") ?? 15
            guard let channel = state.allChannels.first(where: { $0.itemPool.contains { $0.title == title } }) else {
                print("[ENDPROOF] \(title): on no channel"); continue
            }
            // The block where this title airs next, from the real scheduler.
            let fp = state.scheduleCredentialFingerprint
            DailyManifestScheduler.invalidateMemo()
            let blocks = DailyManifestScheduler.blocksInRange(for: channel, from: Date(), to: Date().addingTimeInterval(2 * 86400), credentialFingerprint: fp)
            guard let block = blocks.first(where: { $0.item.title == title }),
                  let next = blocks.first(where: { $0.startTime >= block.endTime }) else {
                print("[ENDPROOF] \(title): not in the next two days on CH \(channel.number)"); continue
            }
            let runtime = block.item.exactDurationSeconds ?? Double(block.item.slotSeconds)
            clockBase = block.startTime.addingTimeInterval(runtime - lead)
            clockStart = Date()
            state.selectChannel(channel)

            // Watch the player the app builds: frames of this title until they stop, then the next title's first frame.
            var output: AVPlayerItemVideoOutput?
            var watchedItem: AVPlayerItem?
            var lastCodeOfTitle = -1, lastFrameOfTitleAt: Date?, firstFrameOfNextAt: Date?, nextTitle = ""
            var firstCodeOfNext = -1
            let started = Date()
            var lastTrace = Date.distantPast
            while Date().timeIntervalSince(started) < lead + 90 {
                if env["NX_END_TRACE"] != nil, Date().timeIntervalSince(lastTrace) >= 1, let p = state.player, let it = p.currentItem {
                    lastTrace = Date()
                    print("[ENDTRACE] +\(String(format: "%.1f", Date().timeIntervalSince(started))) \(state.currentItem?.title ?? "?") t=\(String(format: "%.2f", it.currentTime().seconds)) dur=\(String(format: "%.1f", it.duration.seconds)) rate=\(p.rate) tc=\(p.timeControlStatus.rawValue) status=\(it.status.rawValue) state=\(state.playbackState) base=\(state.hlsBaseOffset) runtime=\(PlaybackEndRule.runtime(for: state.currentItem).map { String($0) } ?? "nil")")
                }
                if let item = state.player?.currentItem, item !== watchedItem {
                    let o = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
                    item.add(o); output = o; watchedItem = item
                }
                if let o = output, let item = watchedItem {
                    let t = o.itemTime(forHostTime: CACurrentMediaTime())
                    if o.hasNewPixelBuffer(forItemTime: t), let pb = o.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
                        let code = frameCode(pb)
                        if state.currentItem?.title == title {
                            lastCodeOfTitle = code; lastFrameOfTitleAt = Date()
                        } else if lastFrameOfTitleAt != nil, firstFrameOfNextAt == nil, item === state.player?.currentItem {
                            firstFrameOfNextAt = Date(); nextTitle = state.currentItem?.title ?? "?"; firstCodeOfNext = code
                            break
                        }
                    }
                }
                try await Task.sleep(for: .milliseconds(4))
            }
            var gap: Double?
            if let a = lastFrameOfTitleAt, let b = firstFrameOfNextAt { gap = b.timeIntervalSince(a) }
            let recent = PlaybackDiagnostics.recent().suffix(3).joined(separator: " || ")
            print("[ENDPROOF] \(title) on CH \(channel.number), joined \(Int(lead)) s before its \(String(format: "%.2f", runtime)) s end: last frame code \(lastCodeOfTitle), next \"\(nextTitle)\" (scheduled \"\(next.item.title)\") first code \(firstCodeOfNext), gap \(gap.map { String(format: "%.1f s", $0) } ?? "NO NEXT PROGRAMME in \(Int(lead + 90)) s") | diagnostics: \(recent)")
        }
        state.player?.pause()
        state.disconnect()
    }
}
