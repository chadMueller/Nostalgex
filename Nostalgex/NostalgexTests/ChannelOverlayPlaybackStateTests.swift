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

    func testTimeControlStatusChangeUpdatesTrackedProperty() async {
        let state = makeState()
        let item = AVPlayerItem(asset: AVMutableComposition())
        state.installFreshPlayer(with: item, generation: 1)
        XCTAssertFalse(state.isVideoPlaying, "a freshly installed player starts paused")

        state.player?.play()
        await waitFor(state, isVideoPlaying: true)

        state.player?.pause()
        await waitFor(state, isVideoPlaying: false)

        state.player = nil
    }

    func testChannelChangeTearsDownOldObserverAndReattachesToTheNewPlayer() async {
        let state = makeState()
        let firstItem = AVPlayerItem(asset: AVMutableComposition())
        state.installFreshPlayer(with: firstItem, generation: 1)
        let firstPlayer = state.player
        firstPlayer?.play()
        await waitFor(state, isVideoPlaying: true)

        // Every real load path (loadCurrentItem / retryLoad / fallbackToTranscode) clears
        // `cancellables` right before installing the next player. Mirror that here.
        state.cancellables.removeAll()
        let secondItem = AVPlayerItem(asset: AVMutableComposition())
        state.installFreshPlayer(with: secondItem, generation: 2)
        let secondPlayer = state.player
        XCTAssertFalse(secondPlayer === firstPlayer, "installFreshPlayer always makes a new AVPlayer instance")
        XCTAssertFalse(state.isVideoPlaying, "the new player starts paused even though the old one was playing")

        // The retired player's own state changes must never reach `isVideoPlaying` again:
        // its subscription was already cancelled by `cancellables.removeAll()`, and the
        // sink's `self.player === fresh` identity guard would reject it even if it had
        // somehow survived. A leaked or wrongly-kept observer here would be the exact
        // "stuck overlay" bug in a different shape — the tracked property fighting the
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
