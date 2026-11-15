import XCTest
@testable import Nostalgex

/// Left and Right move the guide's cursor a programme at a time, whatever its length and over gaps; the window moves
/// only when the programme would leave the view (Chad 2026-11-15).
final class GuideProgramCursorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // the window's start, 30 minute aligned
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func entry(_ id: String, _ from: Double, _ to: Double, now: Date) -> ScheduleEntry {
        let item = DemoData.channels()[0].itemPool[0]
        return ScheduleEntry(id: id, item: item, startTime: at(from), endTime: at(to),
                             isNowPlaying: at(from) <= now && now < at(to))
    }

    /// A row: A on now (0 to 22), B 22 to 23 (one minute), a gap to 50, C 50 to 170 (two hours), D 170 to 200.
    private func row(now: Date) -> [ScheduleEntry] {
        [entry("A", -10, 22, now: now), entry("B", 22, 23, now: now), entry("C", 50, 170, now: now), entry("D", 170, 200, now: now)]
    }

    func testRightGoesProgrammeByProgrammeWhateverTheLengthAndOverAGap() {
        let now = at(5)
        let r = row(now: now)
        var cursor: Date? = nil
        XCTAssertEqual(GuideProgramCursor.current(in: r, cursor: cursor, now: now)?.id, "A", "nil is the live programme")
        var ids: [String] = []
        while let next = GuideProgramCursor.next(in: r, cursor: cursor, now: now) {
            ids.append(next.id)
            cursor = GuideProgramCursor.cursor(for: next, now: now)
        }
        XCTAssertEqual(ids, ["B", "C", "D"], "a one-minute programme, then over the gap, then a two-hour one")
    }

    func testLeftGoesBackAndStopsAtTheLiveProgramme() {
        let now = at(5)
        let r = row(now: now)
        var cursor: Date? = at(170)   // on D
        var ids: [String] = []
        while let prev = GuideProgramCursor.previous(in: r, cursor: cursor, now: now) {
            ids.append(prev.id)
            cursor = GuideProgramCursor.cursor(for: prev, now: now)
        }
        XCTAssertEqual(ids, ["C", "B", "A"])
        XCTAssertNil(cursor, "back on the live programme the cursor is nil")
        XCTAssertNil(GuideProgramCursor.previous(in: r, cursor: nil, now: now), "Left from the live programme goes to the stripe")
    }

    /// Up and Down keep the time: on another row the cursor is on the programme covering it, or in a gap on none,
    /// and Right from a gap goes to the first programme after it.
    func testAnotherRowKeepsTheTime() {
        let now = at(5)
        let other = [entry("X", -20, 40, now: now), entry("Y", 60, 90, now: now)]
        XCTAssertEqual(GuideProgramCursor.current(in: other, cursor: at(22), now: now)?.id, "X")
        XCTAssertNil(GuideProgramCursor.current(in: other, cursor: at(50), now: now), "a gap at that time")
        XCTAssertEqual(GuideProgramCursor.next(in: other, cursor: at(50), now: now)?.id, "Y")
        XCTAssertEqual(GuideProgramCursor.previous(in: other, cursor: at(50), now: now)?.id, "X")
    }

    /// A cursor left behind by the clock is at now.
    func testACursorBehindTheClockIsAtNow() {
        let now = at(25)
        let r = row(now: now)
        XCTAssertEqual(GuideProgramCursor.current(in: r, cursor: at(22), now: now)?.id, nil, "B ended at 23; now is in the gap")
        XCTAssertEqual(GuideProgramCursor.next(in: r, cursor: at(22), now: now)?.id, "C")
    }

    /// The window moves only when the programme would leave the two-hour view, to the slot its start is in.
    func testTheWindowMovesOnlyWhenTheProgrammeWouldLeaveTheView() {
        let now = at(5)
        let r = row(now: now)
        let off = { (e: ScheduleEntry, offset: Int) in
            GuideProgramCursor.windowOffset(showing: e, offset: offset, windowStart: self.t0, now: now, maxOffset: 44)
        }
        XCTAssertEqual(off(r[1], 0), 0, "B at 22 min is in view")
        XCTAssertEqual(off(r[2], 0), 0, "C at 50 min is in view")
        XCTAssertEqual(off(r[3], 0), 5, "D at 170 min is past the 120 min view: the slot its start is in")
        XCTAssertEqual(off(r[2], 5), 1, "back to C from there: the slot C starts in")
        XCTAssertEqual(off(r[0], 1), 0, "the live programme: the slot now is in")
        XCTAssertEqual(off(entry("late", 110, 140, now: now), 0), 3, "a start in the last 15 minutes of the view moves the view")
    }
}
