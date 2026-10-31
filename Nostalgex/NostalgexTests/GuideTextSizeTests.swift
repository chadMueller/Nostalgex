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

    /// The literals ChannelGuideView drew before this setting existed. If this fails,
    /// NORMAL no longer draws today's guide.
    func testNormalIsTodaysGuide() {
        let n = GuideTextSize.normal.metrics
        XCTAssertEqual(n.title, 20)
        XCTAssertEqual(n.timeLabel, 20)
        XCTAssertEqual(n.channelHeading, 18)
        XCTAssertEqual(n.number, 20)
        XCTAssertEqual(n.numberWidth, 36)
        XCTAssertEqual(n.name, 18)
        XCTAssertEqual(n.placeholder, 18)
    }

    /// Same numbers as Roku's GuideText.brs LARGE.
    func testLargeMatchesRoku() {
        let l = GuideTextSize.large.metrics
        XCTAssertEqual(l.title, 26)
        XCTAssertEqual(l.timeLabel, 26)
        XCTAssertEqual(l.channelHeading, 22)
        XCTAssertEqual(l.number, 24)
        XCTAssertEqual(l.numberWidth, 44)
        XCTAssertEqual(l.name, 20)
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
    /// taken off top and bottom, nor than the 60 pt header.
    func testLinesFitTheRowAndTheHeader() throws {
        let rowRoom: CGFloat = 80 - 2 * (3 + 2)
        for size in GuideTextSize.allCases {
            let m = size.metrics
            for s in [m.title, m.number, m.name, m.placeholder] {
                print("GUIDE-TEXT \(size) row line \(s) pt: \(try font(s).lineHeight) tall, room \(rowRoom)")
                XCTAssertLessThanOrEqual(try font(s).lineHeight, rowRoom, "\(size) \(s) pt")
            }
            for s in [m.timeLabel, m.channelHeading] {
                XCTAssertLessThanOrEqual(try font(s).lineHeight, 60, "\(size) header \(s) pt")
            }
        }
    }

    /// The longest header label still fits its quarter of the programme area at the
    /// narrowest guide this app draws (1920 wide minus the 220 pt channel column, then
    /// the 14 pt lead-in).
    func testTimeLabelsFitTheirSlot() throws {
        let slot = (1920 - 220) / 4 - 14
        for size in GuideTextSize.allCases {
            let w = try width("12:30 AM", size.metrics.timeLabel)
            print("GUIDE-TEXT \(size) time label 12:30 AM: \(w) wide, slot \(slot)")
            XCTAssertLessThanOrEqual(w, CGFloat(slot), "\(size): \(w) pt")
        }
    }
}
