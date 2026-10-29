import AVFoundation
import XCTest
@testable import Nostalgex

/// Trello gENSCnj1: the channel info overlay could reappear during playback after a brief
/// stall and then stay on for good. `PlayerView` used to read
/// `appState.player?.timeControlStatus == .playing` live inside the view body.
/// `timeControlStatus` lives on the plain AVPlayer, not on an `@Observable` property, so
/// SwiftUI had no reliable reason to re-render when it changed on its own: a stall could
/// flip it away from `.playing`, the overlay would show on whatever unrelated render
/// happened to land at that moment, and once the stall cleared nothing forced another
/// render to hide it again.
///
/// The fix mirrors `timeControlStatus` into `AppState.isVideoPlaying` via KVO inside
/// `installFreshPlayer`, the same pattern already used for the Now Playing heartbeat
/// (`installStarvationMonitor`). These tests drive a real `AVPlayer` directly (not just
/// reading the code) to confirm the mirror actually fires, and that it tears down and
/// re-attaches correctly across a channel change instead of leaking or going stale.
///
/// Each `AVPlayerItem` below is built from `PlayableTestAsset`, a tiny real `.mov`
/// written to a temp file at runtime, not `AVPlayerItem(asset: AVMutableComposition())`.
/// A standalone probe (same KVO mechanism as this fix, run outside the test target)
/// showed an empty composition -- zero tracks, zero duration -- is not a reliable
/// "paused player" fixture: across repeated runs it either flashed to `.playing` for
/// under 50ms before settling straight back to `.paused` because there was nothing to
/// play, or never left `.waitingToPlayAtSpecifiedRate` /
/// `AVPlayerWaitingWithNoItemToPlayReason` at all within several seconds. Either way
/// there is no stable playing window for a polling assertion to catch, regardless of
/// whether the KVO bridge under test is correct. A real local asset, even a few silent
/// solid-colour frames, gives the player something to actually decode and hold
/// `.playing` on, which is what these tests are supposed to be exercising.
@MainActor
final class ChannelOverlayPlaybackStateTests: XCTestCase {
    private struct EmptyCredentials: CredentialStoring {
        func save(key: String, value: String) -> Bool { true }
        func load(key: String) -> String? { nil }
        func delete(key: String) {}
    }

    private func makeState() -> AppState {
        let defaults = UserDefaults(suiteName: "ChannelOverlayPlaybackStateTests")!
        defaults.removePersistentDomain(forName: "ChannelOverlayPlaybackStateTests")
        let sync = PreferenceSync(cloud: InMemoryKeyValueStore(), defaults: defaults,
                                  observeNotifications: false, keys: PreferenceSync.syncedKeys)
        return AppState(credentialStore: EmptyCredentials(), preferenceSync: sync)
    }

    /// The KVO sink is routed through `.receive(on: DispatchQueue.main)`, so the update
    /// lands on a later turn of the main run loop, not synchronously with `play()`/
    /// `pause()`. Poll rather than assert immediately, same style as the existing
    /// playback-recovery tests' `waitForRequests`.
    private func waitFor(_ state: AppState, isVideoPlaying expected: Bool, timeout: TimeInterval = 2,
                         file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while state.isVideoPlaying != expected, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.isVideoPlaying, expected, file: file, line: line)
    }

    func testTimeControlStatusChangeUpdatesTrackedProperty() async throws {
        let state = makeState()
        let item = AVPlayerItem(url: try PlayableTestAsset.url())
        state.installFreshPlayer(with: item, generation: 1)
        XCTAssertFalse(state.isVideoPlaying, "a freshly installed player starts paused")

        state.player?.play()
        await waitFor(state, isVideoPlaying: true)

        state.player?.pause()
        await waitFor(state, isVideoPlaying: false)

        state.player = nil
    }

    func testChannelChangeTearsDownOldObserverAndReattachesToTheNewPlayer() async throws {
        let state = makeState()
        let firstItem = AVPlayerItem(url: try PlayableTestAsset.url())
        state.installFreshPlayer(with: firstItem, generation: 1)
        let firstPlayer = state.player
        firstPlayer?.play()
        await waitFor(state, isVideoPlaying: true)

        // Every real load path (loadCurrentItem / retryLoad / fallbackToTranscode) clears
        // `cancellables` right before installing the next player. Mirror that here.
        state.cancellables.removeAll()
        let secondItem = AVPlayerItem(url: try PlayableTestAsset.url())
        state.installFreshPlayer(with: secondItem, generation: 2)
        let secondPlayer = state.player
        XCTAssertFalse(secondPlayer === firstPlayer, "installFreshPlayer always makes a new AVPlayer instance")
        XCTAssertFalse(state.isVideoPlaying, "the new player starts paused even though the old one was playing")

        // The retired player's own state changes must never reach `isVideoPlaying` again:
        // its subscription was already cancelled by `cancellables.removeAll()`, and the
        // sink's `self.player === fresh` identity guard would reject it even if it had
        // somehow survived. A leaked or wrongly-kept observer here would be the exact
        // "stuck overlay" bug in a different shape, the tracked property fighting the
        // view with the wrong player's state.
        firstPlayer?.play()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(state.isVideoPlaying, "a stale observer on the retired player must not override the current one")

        secondPlayer?.play()
        await waitFor(state, isVideoPlaying: true)

        secondPlayer?.pause()
        await waitFor(state, isVideoPlaying: false)

        state.player = nil
    }
}

/// Writes a tiny, real, local, silent `.mov` once per test run and hands back its URL, so
/// `AVPlayerItem`s built from it have actual video to decode and can genuinely reach and
/// hold `.playing`. No network access and no binary asset checked into the repo: a
/// handful of solid-colour frames at a low frame rate is all AVPlayer needs, and nothing
/// here inspects the picture itself.
private enum PlayableTestAsset {
    private static var cached: Result<URL, Error>?

    static func url() throws -> URL {
        if let cached {
            return try cached.get()
        }
        let result = Result { try makeMovie() }
        cached = result
        return try result.get()
    }

    private static func makeMovie() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChannelOverlayPlaybackStateTests-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        let size = CGSize(width: 64, height: 64)
        let fps: Int32 = 2
        let seconds = 10 // generous margin over the tests' 2s poll timeouts combined

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                             sourcePixelBufferAttributes: pixelBufferAttributes)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(Int32(seconds) * fps)
        for frameNumber in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pixelBufferOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
            guard let pixelBuffer = pixelBufferOut else { break }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, 0, CVPixelBufferGetBytesPerRow(pixelBuffer) * Int(size.height))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let time = CMTime(value: CMTimeValue(frameNumber), timescale: CMTimeScale(fps))
            adaptor.append(pixelBuffer, withPresentationTime: time)
        }
        input.markAsFinished()
        let group = DispatchGroup()
        group.enter()
        writer.finishWriting { group.leave() }
        group.wait()
        if writer.status == .failed {
            throw writer.error ?? NSError(domain: "PlayableTestAsset", code: -1)
        }
        return url
    }
}
