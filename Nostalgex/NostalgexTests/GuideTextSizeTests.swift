import XCTest
import UIKit
@testable import Nostalgex

/// GUIDE TEXT SIZE: NORMAL is the guide as it always was, LARGE matches Roku's sizes,
/// the choice survives a relaunch, and every LARGE line still fits the fixed row,
/// header and number box, measured with the bundled DM Mono rather than estimated.
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

    func testNothingSavedOrAnythingButLargeIsNormal() {
        XCTAssertEqual(GuideTextSize(stored: nil), .normal)
        XCTAssertEqual(GuideTextSize(stored: ""), .normal)
        XCTAssertEqual(GuideTextSize(stored: "normal"), .normal)
        XCTAssertEqual(GuideTextSize(stored: "huge"), .normal)
        XCTAssertEqual(GuideTextSize(stored: "LARGE"), .normal)
        XCTAssertEqual(GuideTextSize(stored: "large"), .large)
    }

    func testFreshInstallIsNormal() {
        UserDefaults.standard.removeObject(forKey: GuideTextSize.storageKey)
        XCTAssertEqual(makeState().guideTextSize, .normal)
    }

    func testChoiceSurvivesARelaunch() {
        let first = makeState()
        first.guideTextSize = .large
        XCTAssertEqual(UserDefaults.standard.string(forKey: GuideTextSize.storageKey), "large")
        XCTAssertEqual(makeState().guideTextSize, .large, "a new AppState did not read LARGE back")

        first.guideTextSize = .normal
        XCTAssertEqual(UserDefaults.standard.string(forKey: GuideTextSize.storageKey), "normal")
        XCTAssertEqual(makeState().guideTextSize, .normal)
    }

    func testIsASyncedStringPreference() {
        XCTAssertTrue(PreferenceSync.syncedKeys.contains(GuideTextSize.storageKey))
        XCTAssertEqual(PreferenceSyncMerge.normalized("large", for: GuideTextSize.storageKey) as? String, "large")
    }

    // MARK: Metrics

    /// NORMAL is the 25 pt floor everywhere (Chad 2026-11-10: body read too big in the grid).
    func testNormalIsTheFloor() {
        let n = GuideTextSize.normal.metrics
        XCTAssertEqual(n.title, NXType.caption)
        XCTAssertEqual(n.timeLabel, NXType.caption)
        XCTAssertEqual(n.channelHeading, NXType.caption)
        XCTAssertEqual(n.number, NXType.caption)
        XCTAssertEqual(n.numberWidth, 46)
        XCTAssertEqual(n.name, NXType.caption)
        XCTAssertEqual(n.placeholder, NXType.caption)
    }

    /// LARGE is one step up the same scale: body everywhere. (It no longer matches Roku's GuideText.brs LARGE.)
    func testLargeIsOneStepUpTheScale() {
        let l = GuideTextSize.large.metrics
        XCTAssertEqual(l.title, NXType.body)
        XCTAssertEqual(l.timeLabel, NXType.body)
        XCTAssertEqual(l.channelHeading, NXType.body)
        XCTAssertEqual(l.number, NXType.body)
        XCTAssertEqual(l.numberWidth, 54)
        XCTAssertEqual(l.name, NXType.body)
        XCTAssertEqual(l.placeholder, NXType.body)
    }

    /// Nothing the guide draws is below the 25 pt floor, at either size.
    func testNoGuideTextIsBelowTheFloor() {
        for size in GuideTextSize.allCases {
            let m = size.metrics
            for s in [m.title, m.timeLabel, m.channelHeading, m.number, m.name, m.placeholder] {
                XCTAssertGreaterThanOrEqual(s, NXType.floor, "\(size) \(s) pt")
            }
        }
    }

    func testLargeIsBiggerEverywhere() {
        let n = GuideTextSize.normal.metrics
        let l = GuideTextSize.large.metrics
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

    /// Every three-digit number is drawn inside its right-aligned box, at both sizes.
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
        let rowRoom: CGFloat = NXLayout.rowHeight - 2 * (3 + 2)
        for size in GuideTextSize.allCases {
            let m = size.metrics
            for s in [m.title, m.number, m.name, m.placeholder] {
                print("GUIDE-TEXT \(size) row line \(s) pt: \(try font(s).lineHeight) tall, room \(rowRoom)")
                XCTAssertLessThanOrEqual(try font(s).lineHeight, rowRoom, "\(size) \(s) pt")
            }
            for s in [m.timeLabel, m.channelHeading] {
                XCTAssertLessThanOrEqual(try font(s).lineHeight, 58 - 2 * 8, "\(size) header \(s) pt")
            }
        }
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
