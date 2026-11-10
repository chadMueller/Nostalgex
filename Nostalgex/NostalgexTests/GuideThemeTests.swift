import XCTest
import UIKit
@testable import Nostalgex

/// THEME: NOSTALGEX unless a viewer picked another, NOSTALGEX sets no overrides (so the
/// default guide draws exactly as before), the row cycles through every theme, and every
/// font a theme names ships on tvOS.
final class GuideThemeTests: XCTestCase {

    func testNothingSavedIsNostalgex() {
        let defaults = UserDefaults(suiteName: "GuideThemeTests")!
        defaults.removePersistentDomain(forName: "GuideThemeTests")
        XCTAssertEqual(GuideTheme.current(defaults: defaults), .nostalgex)
        XCTAssertEqual(GuideTheme(stored: "nonsense"), .nostalgex)
        defaults.set("1998", forKey: GuideTheme.storageKey)
        XCTAssertEqual(GuideTheme.current(defaults: defaults), .y1998)
    }

    func testNostalgexOverridesNothing() {
        let t = GuideTheme.nostalgex
        XCTAssertNil(t.boldFont)
        XCTAssertNil(t.cellColors)
        XCTAssertNil(t.infoBackground)
        XCTAssertNil(t.panelBackground)
        XCTAssertNil(t.accent)
        XCTAssertNil(t.textShadow)
        XCTAssertEqual(t.cellGap, 0)
    }

    func testRowCyclesThroughEveryTheme() {
        var seen: [String] = []
        var theme = GuideTheme.nostalgex
        for _ in GuideTheme.all {
            seen.append(theme.label)
            theme = theme.next
        }
        XCTAssertEqual(seen, ["NOSTALGEX", "SATELLITE", "CABLE BOX", "1998", "Y2K"])
        XCTAssertEqual(theme, .nostalgex)
    }

    func testEveryNamedFontExists() {
        for theme in GuideTheme.all {
            for name in [theme.boldFont, theme.regularFont].compactMap({ $0 }) {
                XCTAssertNotNil(UIFont(name: name, size: 20), "\(theme.label) names a font tvOS doesn't have: \(name)")
            }
        }
    }
}
