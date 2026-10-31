import XCTest
@testable import Nostalgex

/// The rail follows SettingsFeatures.showProTab: with Pro off it has five tabs in the
/// same order as before, with Pro on it has all six. Neither case asserts which way the
/// switch is set, so flipping it needs no test change.
final class SettingsFeaturesTests: XCTestCase {

    func testRailWithoutProKeepsOrderAndDropsOnlyPro() {
        XCTAssertEqual(
            SettingsCategory.visible(showPro: false),
            [.support, .playback, .channels, .servers, .about]
        )
    }

    func testRailWithProIsEverySixTabs() {
        XCTAssertEqual(SettingsCategory.visible(showPro: true), SettingsCategory.allCases)
        XCTAssertEqual(SettingsCategory.allCases.count, 6)
    }

    func testPinnedAndUnpinnedFollowTheSwitch() {
        let visible = SettingsCategory.visible()
        XCTAssertEqual(SettingsCategory.pinned, [.support])
        XCTAssertEqual(SettingsCategory.pinned + SettingsCategory.unpinned, visible)
        XCTAssertEqual(visible.contains(.pro), SettingsFeatures.showProTab)
    }
}
