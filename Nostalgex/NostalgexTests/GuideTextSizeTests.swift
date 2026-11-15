import XCTest
import UIKit
@testable import Nostalgex

/// GUIDE TEXT SIZE: three steps, SMALLER, DEFAULT and LARGER (the old LARGE, raw value
/// "large" unchanged). The choice survives a relaunch, an unknown saved value is DEFAULT, and every
/// line at every step still fits the fixed row, header and number box, measured with the bundled
/// DM Mono rather than estimated.
@MainActor
final class GuideTextSizeTests: XCTestCase {

    private var savedValue: Any?

    override func setUp() {
        super.setUp()
        savedValue = UserDefaults.standard.object(forKey: GuideTextSize.storageKey)
    }

    override func tearDown() {
        if let savedValue {
            UserDefaults.standard.set(savedValue, forKey: GuideTextSize.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: GuideTextSize.storageKey)
        }
        super.tearDown()
    }

    private func makeState() -> AppState {
        let defaults = UserDefaults(suiteName: "GuideTextSizeTests")!
        defaults.removePersistentDomain(forName: "GuideTextSizeTests")
        let sync = PreferenceSync(cloud: InMemoryKeyValueStore(), defaults: defaults,
                                  observeNotifications: false, keys: PreferenceSync.syncedKeys)
        return AppState(preferenceSync: sync)
    }

    // MARK: Saved value

    func testNothingSavedOrAnythingUnknownIsDefault() {
        XCTAssertEqual(GuideTextSize(stored: nil), .normal)
        XCTAssertEqual(GuideTextSize(stored: ""), .normal)
        XCTAssertEqual(GuideTextSize(stored: "normal"), .normal)
        XCTAssertEqual(GuideTextSize(stored: "huge"), .normal)
        XCTAssertEqual(GuideTextSize(stored: "LARGE"), .normal)
        XCTAssertEqual(GuideTextSize(stored: "SMALL"), .normal)
        XCTAssertEqual(GuideTextSize(stored: "smaller"), .normal)
        XCTAssertEqual(GuideTextSize(stored: "large"), .large)
        XCTAssertEqual(GuideTextSize(stored: "small"), .small)
    }

    /// The raw values are the contract with iCloud sync, stored prefs and the other platforms: "large" is the old
    /// LARGE, "small" is new, and a platform that only knows normal and large reads "small" as normal.
    func testRawValuesAndLabels() {
        XCTAssertEqual(GuideTextSize.allCases, [.small, .normal, .large])
        XCTAssertEqual(GuideTextSize.small.rawValue, "small")
        XCTAssertEqual(GuideTextSize.normal.rawValue, "normal")
        XCTAssertEqual(GuideTextSize.large.rawValue, "large")
        XCTAssertEqual(GuideTextSize.allCases.map(\.label), ["SMALLER", "DEFAULT", "LARGER"])
    }

    /// What select does on the Settings row.
    func testTheRowCyclesSmallerDefaultLargerAndRoundAgain() {
        XCTAssertEqual(GuideTextSize.small.next, .normal)
        XCTAssertEqual(GuideTextSize.normal.next, .large)
        XCTAssertEqual(GuideTextSize.large.next, .small)
    }

    func testFreshInstallIsDefault() {
        UserDefaults.standard.removeObject(forKey: GuideTextSize.storageKey)
        XCTAssertEqual(makeState().guideTextSize, .normal)
    }

    func testChoiceSurvivesARelaunch() {
        let first = makeState()
        first.guideTextSize = .large
        XCTAssertEqual(UserDefaults.standard.string(forKey: GuideTextSize.storageKey), "large")
        XCTAssertEqual(makeState().guideTextSize, .large, "a new AppState did not read LARGE back")

        first.guideTextSize = .small
        XCTAssertEqual(UserDefaults.standard.string(forKey: GuideTextSize.storageKey), "small")
        XCTAssertEqual(makeState().guideTextSize, .small, "a new AppState did not read SMALLER back")
        XCTAssertEqual(GuideTextSize.current, .small, "the bundle list and Now Playing read the saved step")

        first.guideTextSize = .normal
        XCTAssertEqual(UserDefaults.standard.string(forKey: GuideTextSize.storageKey), "normal")
        XCTAssertEqual(makeState().guideTextSize, .normal)
    }

    func testIsASyncedStringPreference() {
        XCTAssertTrue(PreferenceSync.syncedKeys.contains(GuideTextSize.storageKey))
        XCTAssertEqual(PreferenceSyncMerge.normalized("large", for: GuideTextSize.storageKey) as? String, "large")
        XCTAssertEqual(PreferenceSyncMerge.normalized("small", for: GuideTextSize.storageKey) as? String, "small")
    }

    // MARK: Metrics

    /// DEFAULT row text is 20 pt and times, heading and placeholder 22 pt (Chad 2026-11-13, pulled back about 10% from
    /// 22 and 25; an exception to the 25 pt floor for the guide only). The bundle list and Now Playing follow.
    func testNormalSizes() {
        let n = GuideTextSize.normal.metrics
        XCTAssertEqual(n.title, 20)
        XCTAssertEqual(n.timeLabel, 22)
        XCTAssertEqual(n.channelHeading, 22)
        XCTAssertEqual(n.number, 20)
        XCTAssertEqual(n.numberWidth, 36)
        XCTAssertEqual(n.name, 20)
        XCTAssertEqual(n.placeholder, 22)
        XCTAssertEqual(n.packageRowText, 20)
        XCTAssertEqual(n.packageHeading, 22)
        XCTAssertEqual(n.panelText, 20)
        XCTAssertEqual(n.panelTitle, NXType.body)
        XCTAssertEqual(n.panelTag, 28)
    }

    /// SMALLER is a visible step down from DEFAULT: 85% and 86% of it, 17 and 19 pt.
    func testSmallIsAVisibleStepDownFromDefault() {
        let s = GuideTextSize.small.metrics
        XCTAssertEqual(s.title, 17)
        XCTAssertEqual(s.timeLabel, 19)
        XCTAssertEqual(s.channelHeading, 19)
        XCTAssertEqual(s.number, 17)
        XCTAssertEqual(s.numberWidth, 31)
        XCTAssertEqual(s.name, 17)
        XCTAssertEqual(s.placeholder, 19)
        XCTAssertEqual(s.packageRowText, 17)
        XCTAssertEqual(s.packageHeading, 19)
        XCTAssertEqual(s.panelText, 17)
        XCTAssertEqual(s.panelTitle, 25)
        XCTAssertEqual(s.panelTag, 24)
        let d = GuideTextSize.normal.metrics
        XCTAssertLessThanOrEqual(s.title / d.title, 0.86, "SMALLER must not be a nudge")
        XCTAssertLessThanOrEqual(s.timeLabel / d.timeLabel, 0.87)
    }

    /// LARGER is what LARGE always was: body everywhere in the grid (it no longer matches Roku's GuideText.brs
    /// LARGE); the bundle list and Now Playing stay at 22 pt, as they were at LARGE.
    func testLargerIsTodaysLarge() {
        let l = GuideTextSize.large.metrics
        XCTAssertEqual(l.title, NXType.body)
        XCTAssertEqual(l.timeLabel, NXType.body)
        XCTAssertEqual(l.channelHeading, NXType.body)
        XCTAssertEqual(l.number, NXType.body)
        XCTAssertEqual(l.numberWidth, 54)
        XCTAssertEqual(l.name, NXType.body)
        XCTAssertEqual(l.placeholder, NXType.body)
        XCTAssertEqual(l.packageRowText, 22)
        XCTAssertEqual(l.packageHeading, NXType.caption)
        XCTAssertEqual(l.panelText, 22)
        XCTAssertEqual(l.panelTitle, NXType.body)
        XCTAssertEqual(l.panelTag, 28)
    }

    /// The guide's own floors, below the app's 25 pt one: row text and the bundle list and panel text never below
    /// 17, header text, the placeholder and the BUNDLES heading never below 19, at every step.
    func testNoGuideTextIsBelowTheFloor() {
        for size in GuideTextSize.allCases {
            let m = size.metrics
            for s in [m.title, m.number, m.name, m.packageRowText, m.panelText] {
                XCTAssertGreaterThanOrEqual(s, 17, "\(size) \(s) pt")
            }
            for s in [m.timeLabel, m.channelHeading, m.placeholder, m.packageHeading] {
                XCTAssertGreaterThanOrEqual(s, 19, "\(size) \(s) pt")
            }
        }
    }

    /// The steps only ever grow: SMALLER < DEFAULT < LARGER on every size.
    func testEachStepIsAtLeastAsBigAsTheOneBelow() {
        let order = GuideTextSize.allCases.map(\.metrics)
        for (a, b) in zip(order, order.dropFirst()) {
            for (lo, hi) in [(a.title, b.title), (a.timeLabel, b.timeLabel), (a.channelHeading, b.channelHeading),
                             (a.number, b.number), (a.numberWidth, b.numberWidth), (a.name, b.name),
                             (a.placeholder, b.placeholder), (a.packageRowText, b.packageRowText),
                             (a.packageHeading, b.packageHeading), (a.panelText, b.panelText),
                             (a.panelTitle, b.panelTitle), (a.panelTag, b.panelTag)] {
                XCTAssertLessThanOrEqual(lo, hi)
            }
        }
    }

    func testLargeIsBiggerEverywhere() {
        let n = GuideTextSize.normal.metrics
        let l = GuideTextSize.large.metrics
        let sm = GuideTextSize.small.metrics
        for (big, small) in [(n.title, sm.title), (n.timeLabel, sm.timeLabel), (n.number, sm.number),
                             (n.numberWidth, sm.numberWidth), (n.name, sm.name), (n.placeholder, sm.placeholder)] {
            XCTAssertGreaterThan(big, small)
        }
        for (big, small) in [(l.title, n.title), (l.timeLabel, n.timeLabel), (l.channelHeading, n.channelHeading),
                             (l.number, n.number), (l.numberWidth, n.numberWidth), (l.name, n.name),
                             (l.placeholder, n.placeholder)] {
            XCTAssertGreaterThan(big, small)
        }
    }

    // MARK: Fit, measured with the real font

    private func font(_ size: CGFloat) throws -> UIFont {
        try XCTUnwrap(UIFont(name: "DMMono-Medium", size: size), "DM Mono Medium is not registered")
    }

    private func width(_ text: String, _ size: CGFloat) throws -> CGFloat {
        (text as NSString).size(withAttributes: [.font: try font(size)]).width
    }

    /// Every three-digit number is drawn inside its right-aligned box, at every step.
    func testThreeDigitChannelNumbersFitTheirBox() throws {
        for size in GuideTextSize.allCases {
            let m = size.metrics
            for number in ["100", "216", "452", "888", "999"] {
                let w = try width(number, m.number)
                print("GUIDE-TEXT \(size) number \(number) at \(m.number) pt: \(w) wide, box \(m.numberWidth)")
                XCTAssertLessThanOrEqual(w, m.numberWidth, "\(number) at \(m.number) pt is \(w) pt, box \(m.numberWidth)")
            }
        }
    }

    /// A line is never taller than its row once the focus outline (3 pt, inset 2 pt) is
    /// taken off top and bottom, nor than the 58 pt header (which keeps at least 8 pt above and below a header line).
    func testLinesFitTheRowAndTheHeader() throws {
        for size in GuideTextSize.allCases {
            let m = size.metrics
            let rowRoom: CGFloat = m.rowHeight - 2 * (3 + 2)
            for s in [m.title, m.number, m.name, m.placeholder] {
                print("GUIDE-TEXT \(size) row line \(s) pt: \(try font(s).lineHeight) tall, room \(rowRoom)")
                XCTAssertLessThanOrEqual(try font(s).lineHeight, rowRoom, "\(size) \(s) pt")
            }
            for s in [m.timeLabel, m.channelHeading] {
                XCTAssertLessThanOrEqual(try font(s).lineHeight, m.headerHeight - 2 * 8, "\(size) header \(s) pt")
            }
        }
    }

    /// LARGER grows the row and the header with its text, keeping about the room DEFAULT leaves around a line; the
    /// other two steps keep the guide's 64 and 58 (Chad 2026-11-15).
    func testRowsAndHeaders() {
        XCTAssertEqual(GuideTextSize.small.metrics.rowHeight, 64)
        XCTAssertEqual(GuideTextSize.normal.metrics.rowHeight, 64)
        XCTAssertEqual(GuideTextSize.large.metrics.rowHeight, 76)
        XCTAssertEqual(GuideTextSize.small.metrics.headerHeight, 58)
        XCTAssertEqual(GuideTextSize.normal.metrics.headerHeight, 58)
        XCTAssertEqual(GuideTextSize.large.metrics.headerHeight, 66)
        let d = GuideTextSize.normal.metrics, l = GuideTextSize.large.metrics
        XCTAssertEqual((l.rowHeight - l.title) / 2, (d.rowHeight - d.title) / 2, accuracy: 2, "the same room above and below a row line")
        XCTAssertEqual((l.headerHeight - l.timeLabel) / 2, (d.headerHeight - d.timeLabel) / 2, accuracy: 1, "the same room around a time")
    }

    /// The longest header label still fits its quarter of the programme area at the
    /// narrowest guide this app draws (1920 wide minus the 340 pt channel column, then
    /// the 14 pt lead-in).
    func testTimeLabelsFitTheirSlot() throws {
        let slot = (1920 - 340) / 4 - 14
        for size in GuideTextSize.allCases {
            let w = try width("12:30 AM", size.metrics.timeLabel)
            print("GUIDE-TEXT \(size) time label 12:30 AM: \(w) wide, slot \(slot)")
            XCTAssertLessThanOrEqual(w, CGFloat(slot), "\(size): \(w) pt")
        }
    }
}
