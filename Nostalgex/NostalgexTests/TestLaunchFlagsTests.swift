import XCTest
@testable import Nostalgex

/// A launch flag that deletes or rewrites stored data acts only while the app's stores are isolated
/// (`TestLaunchFlags`). On 2026-11-09 one of them wiped a real Apple TV.
final class TestLaunchFlagsTests: XCTestCase {
    func testEveryDestructiveFlagIsIgnoredWithoutIsolation() {
        for flag in TestLaunchFlags.destructive {
            XCTAssertFalse(TestLaunchFlags.shouldHonour(flag, arguments: ["-other", flag, "1"], isolationActive: false), flag)
        }
    }

    func testEveryDestructiveFlagActsUnderIsolation() {
        for flag in TestLaunchFlags.destructive {
            XCTAssertTrue(TestLaunchFlags.shouldHonour(flag, arguments: [flag], isolationActive: true), flag)
        }
    }

    func testAFlagThatIsNotOnTheCommandLineNeverActs() {
        for flag in TestLaunchFlags.destructive {
            XCTAssertFalse(TestLaunchFlags.shouldHonour(flag, arguments: ["-uiTestManyChannels"], isolationActive: true), flag)
        }
    }

    func testAFlagThatOnlyChangesWhatIsShownIsNotHeld() {
        for flag in ["-uiTestManyChannels", "-uiTestStartOnChannel", "-uiTestShortPackage", "-uiTestForceSettingsPage"] {
            XCTAssertTrue(TestLaunchFlags.shouldHonour(flag, arguments: [flag], isolationActive: false), flag)
        }
    }

    func testTheNamedFlagsThatDeleteOrRewriteAreOnTheList() {
        for flag in ["-uiTestResetCredentials", "-reproAppReviewFlow", "-uiTestInstantAuth", "-uiTestRescanRowFixture"] {
            XCTAssertTrue(TestLaunchFlags.destructive.contains(flag), flag)
        }
    }

    /// The test process has no flags and, unless a device run asked for it, no isolation. Reading a flag
    /// through `isOn` is false either way and never crashes.
    func testIsOnIsFalseWithoutTheFlag() {
        XCTAssertFalse(TestLaunchFlags.isOn("-uiTestResetCredentials-not-passed"))
    }
}
