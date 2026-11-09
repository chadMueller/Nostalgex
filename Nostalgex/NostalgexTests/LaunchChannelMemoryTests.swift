import XCTest
@testable import Nostalgex

/// OPEN ON LAST CHANNEL (I-017): the saved / restored / gone / renumbered cases, the default, demo
/// mode and sign-out. The helper takes its UserDefaults, so most of these run in a throwaway suite;
/// the AppState ones run under a harness scope so nothing reaches the real defaults.
@MainActor
final class LaunchChannelMemoryTests: XCTestCase {

    private func channel(_ id: Int, _ name: String) -> Channel {
        Channel(id: id, number: id, name: name, color: .white, category: nil, rules: nil,
                timeRestrictions: nil, minItems: 0, itemPool: [])
    }

    private var lineup: [Channel] {
        [channel(1, "ACTION"), channel(2, "COMEDY"), channel(401, "TOM HANKS"), channel(402, "JOHN WICK")]
    }

    private func freshDefaults() -> UserDefaults {
        let name = "launch-channel-memory-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: The helper

    func testItIsOffUntilSomeoneTurnsItOn() {
        let defaults = freshDefaults()
        XCTAssertFalse(LaunchChannelMemory.enabledByDefault, "the default is Chad's call; this pins what ships")
        XCTAssertEqual(LaunchChannelMemory.isEnabled(defaults: defaults), LaunchChannelMemory.enabledByDefault)
        LaunchChannelMemory.remember(lineup[2], defaults: defaults)
        XCTAssertNil(LaunchChannelMemory.channelToOpen(in: lineup, defaults: defaults),
                     "with the switch off a launch opens where it always did, whatever was saved")
    }

    func testOnOpensTheChannelTheViewerLastTuned() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: LaunchChannelMemory.enabledKey)
        LaunchChannelMemory.remember(lineup[1], defaults: defaults)
        XCTAssertEqual(LaunchChannelMemory.channelToOpen(in: lineup, defaults: defaults)?.id, 2)
        LaunchChannelMemory.remember(lineup[2], defaults: defaults)
        XCTAssertEqual(LaunchChannelMemory.channelToOpen(in: lineup, defaults: defaults)?.name, "TOM HANKS",
                       "the last one tuned wins")
    }

    func testTheSwitchTurnedBackOffOpensNothing() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: LaunchChannelMemory.enabledKey)
        LaunchChannelMemory.remember(lineup[1], defaults: defaults)
        defaults.set(false, forKey: LaunchChannelMemory.enabledKey)
        XCTAssertNil(LaunchChannelMemory.channelToOpen(in: lineup, defaults: defaults))
    }

    func testFirstLaunchHasNothingSaved() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: LaunchChannelMemory.enabledKey)
        XCTAssertNil(LaunchChannelMemory.saved(defaults: defaults))
        XCTAssertNil(LaunchChannelMemory.channelToOpen(in: lineup, defaults: defaults))
    }

    func testAChannelThatIsGoneOpensNothing() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: LaunchChannelMemory.enabledKey)
        LaunchChannelMemory.remember(lineup[2], defaults: defaults)
        let withoutIt = lineup.filter { $0.id != 401 }
        XCTAssertNil(LaunchChannelMemory.channelToOpen(in: withoutIt, defaults: defaults))
        XCTAssertNil(LaunchChannelMemory.channelToOpen(in: [], defaults: defaults), "an empty lineup, the library not built yet")
    }

    /// A franchise or collection channel renumbered by a rebuild: the id now belongs to another
    /// channel, or the name has moved to another id. Neither is tuned.
    func testARenumberedChannelIsNotTunedByMistake() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: LaunchChannelMemory.enabledKey)
        LaunchChannelMemory.remember(channel(401, "TOM HANKS"), defaults: defaults)

        let idNowAnotherChannel = [channel(1, "ACTION"), channel(401, "JOHN WICK"), channel(402, "TOM HANKS")]
        XCTAssertNil(LaunchChannelMemory.channelToOpen(in: idNowAnotherChannel, defaults: defaults),
                     "same id, different name: not the channel the viewer left, and the same name on another id is not guessed at")
    }

    func testSignOutForgetsTheChannel() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: LaunchChannelMemory.enabledKey)
        LaunchChannelMemory.remember(lineup[1], defaults: defaults)
        LaunchChannelMemory.clear(defaults: defaults)
        XCTAssertNil(LaunchChannelMemory.saved(defaults: defaults))
        XCTAssertNil(LaunchChannelMemory.channelToOpen(in: lineup, defaults: defaults))
        XCTAssertTrue(LaunchChannelMemory.isEnabled(defaults: defaults), "the switch is the viewer's setting and stays")
    }

    func testTheSwitchAndTheChannelNeverReachICloud() {
        XCTAssertFalse(PreferenceSync.syncedKeys.contains(LaunchChannelMemory.enabledKey))
        XCTAssertFalse(PreferenceSync.syncedKeys.contains(LaunchChannelMemory.savedKey))
    }

    // MARK: Through AppState

    func testALaunchOpensOnTheFirstChannelWhileTheSwitchIsOff() {
        let scope = HarnessScope.begin("launch-channel-off")
        defer { scope.end() }
        let state = AppState()
        state.channels = lineup
        state.rememberLaunchChannel(lineup[2])
        XCTAssertEqual(state.channelToOpenFirst?.id, 1, "today's behaviour, untouched")
    }

    func testALaunchOpensOnTheSavedChannelWhenTheSwitchIsOn() {
        let scope = HarnessScope.begin("launch-channel-on")
        defer { scope.end() }
        AppDefaults.standard.set(true, forKey: LaunchChannelMemory.enabledKey)
        let state = AppState()
        state.channels = lineup
        state.rememberLaunchChannel(lineup[2])
        XCTAssertEqual(state.channelToOpenFirst?.id, 401)
        state.channels = lineup.filter { $0.id != 401 }
        XCTAssertEqual(state.channelToOpenFirst?.id, 1, "the saved channel is gone: where the app opens today")
        state.channels = []
        XCTAssertNil(state.channelToOpenFirst, "no channels built yet: nothing to open, and nothing crashes")
    }

    func testDemoModeAlwaysOpensOnTheFirstChannelAndSavesNothing() {
        let scope = HarnessScope.begin("launch-channel-demo")
        defer { scope.end() }
        AppDefaults.standard.set(true, forKey: LaunchChannelMemory.enabledKey)
        let state = AppState()
        state.channels = lineup
        state.rememberLaunchChannel(lineup[2])
        XCTAssertTrue(state.launchMemoryApplies, "a real library shows the row and uses the memory")
        state.isDemoMode = true
        XCTAssertFalse(state.launchMemoryApplies, "demo mode hides the row (SettingsPlaybackView) and ignores the memory")
        XCTAssertEqual(state.channelToOpenFirst?.id, 1)
        state.rememberLaunchChannel(lineup[1])
        XCTAssertEqual(LaunchChannelMemory.saved()?.id, 401, "a demo tune does not overwrite the real memory")
    }

    func testSigningOutClearsTheSavedChannel() {
        let scope = HarnessScope.begin("launch-channel-signout")
        defer { scope.end() }
        let state = AppState()
        state.channels = lineup
        state.rememberLaunchChannel(lineup[2])
        XCTAssertNotNil(LaunchChannelMemory.saved())
        state.disconnect()
        XCTAssertNil(LaunchChannelMemory.saved())
    }
}
