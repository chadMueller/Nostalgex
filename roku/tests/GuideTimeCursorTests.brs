' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' The guide's time cursor (source/guide/GuideTimeCursor.brs, issue #275): the
' Apple TV's GuideTimeCursorTests (I-089), case for case, on epoch seconds.
' Returns the failure count.

function NxRunGuideTimeCursorTests() as Integer
    r = { pass: 0, fail: 0 }
    windowStart& = 1800000000&
    now& = windowStart& + 600

    NxCheck(r, "at the start of the window the panel shows what is on", NxToStr(NxGuidePreviewTime(0, windowStart&, now&) = invalid), "true")
    NxCheck(r, "a step later is 30 minutes on", NxToStr(NxGuidePreviewTime(1, windowStart&, now&)), NxToStr(windowStart& + 1800))
    NxCheck(r, "three steps are 90 minutes on", NxToStr(NxGuidePreviewTime(3, windowStart&, now&)), NxToStr(windowStart& + 5400))
    NxCheck(r, "a cursor not later than now shows what is on", NxToStr(NxGuidePreviewTime(1, windowStart&, windowStart& + 4000) = invalid), "true")
    NxCheck(r, "a cursor exactly now shows what is on", NxToStr(NxGuidePreviewTime(1, windowStart&, windowStart& + 1800) = invalid), "true")
    NxCheck(r, "a negative offset is the live programme", NxToStr(NxGuidePreviewTime(-1, windowStart&, now&) = invalid), "true")

    blocks = [
        { title: "A", startSec: windowStart&, endSec: windowStart& + 45 * 60 },
        { title: "B", startSec: windowStart& + 45 * 60, endSec: windowStart& + 90 * 60 },
        { title: "C", startSec: windowStart& + 90 * 60, endSec: windowStart& + 120 * 60 }
    ]
    NxCheck(r, "the programme covering the cursor", NxGuideBlockCovering(blocks, windowStart& + 30 * 60).title, "A")
    NxCheck(r, "a start is that programme's", NxGuideBlockCovering(blocks, windowStart& + 45 * 60).title, "B")
    NxCheck(r, "the third", NxGuideBlockCovering(blocks, windowStart& + 90 * 60).title, "C")
    NxCheck(r, "past the last", NxToStr(NxGuideBlockCovering(blocks, windowStart& + 120 * 60) = invalid), "true")
    NxCheck(r, "no blocks", NxToStr(NxGuideBlockCovering([], windowStart&) = invalid), "true")
    NxCheck(r, "not blocks", NxToStr(NxGuideBlockCovering(invalid, windowStart&) = invalid), "true")
    gap = [
        { title: "A", startSec: windowStart&, endSec: windowStart& + 20 * 60 },
        { title: "B", startSec: windowStart& + 50 * 60, endSec: windowStart& + 90 * 60 }
    ]
    NxCheck(r, "a gap has no programme", NxToStr(NxGuideBlockCovering(gap, windowStart& + 30 * 60) = invalid), "true")
    unordered = [blocks[2], blocks[0], blocks[1]]
    NxCheck(r, "order does not matter", NxGuideBlockCovering(unordered, windowStart& + 50 * 60).title, "B")

    NxCheck(r, "the time range reads from start to end", NxGuideTimeRange("9:30 PM", "11:00 PM"), "9:30 PM to 11:00 PM")

    ' ── The programme cursor, GuideProgramCursorTests case for case ──
    ' A row: A on now (-10 to 22 minutes), B 22 to 23 (one minute), a gap to 50, C 50 to 170 (two hours), D 170 to 200.
    t0& = 1800000000&
    nowC& = t0& + 5 * 60
    row = [
        { id: "A", startSec: t0& - 600, endSec: t0& + 22 * 60 },
        { id: "B", startSec: t0& + 22 * 60, endSec: t0& + 23 * 60 },
        { id: "C", startSec: t0& + 50 * 60, endSec: t0& + 170 * 60 },
        { id: "D", startSec: t0& + 170 * 60, endSec: t0& + 200 * 60 }
    ]
    NxCheck(r, "cursor: nil is the live programme", NxGuideCursorCurrent(row, invalid, nowC&).id, "A")
    cursor = invalid
    ids = []
    while true
        nxt = NxGuideCursorNext(row, cursor, nowC&)
        if nxt = invalid then exit while
        ids.Push(nxt.id)
        cursor = NxGuideCursorFor(nxt, nowC&)
    end while
    NxCheck(r, "cursor: Right goes programme by programme, a one-minute one, over the gap, a two-hour one", ids.Join(","), "B,C,D")
    cursor = t0& + 170 * 60
    ids = []
    while true
        prev = NxGuideCursorPrevious(row, cursor, nowC&)
        if prev = invalid then exit while
        ids.Push(prev.id)
        cursor = NxGuideCursorFor(prev, nowC&)
    end while
    NxCheck(r, "cursor: Left goes back and stops at the live programme", ids.Join(","), "C,B,A")
    NxCheck(r, "cursor: back on the live programme the cursor is nil", NxToStr(cursor = invalid), "true")
    NxCheck(r, "cursor: Left from the live programme goes to the stripe", NxToStr(NxGuideCursorPrevious(row, invalid, nowC&) = invalid), "true")
    other = [{ id: "X", startSec: t0& - 20 * 60, endSec: t0& + 40 * 60 }, { id: "Y", startSec: t0& + 60 * 60, endSec: t0& + 90 * 60 }]
    NxCheck(r, "cursor: another row keeps the time", NxGuideCursorCurrent(other, t0& + 22 * 60, nowC&).id, "X")
    NxCheck(r, "cursor: a gap at that time is no programme", NxToStr(NxGuideCursorCurrent(other, t0& + 50 * 60, nowC&) = invalid), "true")
    NxCheck(r, "cursor: Right from a gap is the first programme after it", NxGuideCursorNext(other, t0& + 50 * 60, nowC&).id, "Y")
    NxCheck(r, "cursor: Left from a gap is the one before", NxGuideCursorPrevious(other, t0& + 50 * 60, nowC&).id, "X")
    now25& = t0& + 25 * 60
    NxCheck(r, "cursor: a cursor behind the clock is at now, in the gap after B", NxToStr(NxGuideCursorCurrent(row, t0& + 22 * 60, now25&) = invalid), "true")
    NxCheck(r, "cursor: and Right from there is C", NxGuideCursorNext(row, t0& + 22 * 60, now25&).id, "C")
    off = {}
    NxCheck(r, "window: B at 22 minutes is in view", NxToStr(NxGuideWindowOffset(row[1], 0, t0&, nowC&, 44)), "0")
    NxCheck(r, "window: C at 50 minutes is in view", NxToStr(NxGuideWindowOffset(row[2], 0, t0&, nowC&, 44)), "0")
    NxCheck(r, "window: D at 170 minutes is past the view, the slot its start is in", NxToStr(NxGuideWindowOffset(row[3], 0, t0&, nowC&, 44)), "5")
    NxCheck(r, "window: back to C from there, the slot C starts in", NxToStr(NxGuideWindowOffset(row[2], 5, t0&, nowC&, 44)), "1")
    NxCheck(r, "window: the live programme, the slot now is in", NxToStr(NxGuideWindowOffset(row[0], 1, t0&, nowC&, 44)), "0")
    late = { id: "late", startSec: t0& + 110 * 60, endSec: t0& + 140 * 60 }
    NxCheck(r, "window: a start in the last 15 minutes of the view moves the view", NxToStr(NxGuideWindowOffset(late, 0, t0&, nowC&, 44)), "3")
    NxCheck(r, "window: clamped to the last offset", NxToStr(NxGuideWindowOffset(late, 0, t0&, nowC&, 2)), "2")
    NxCheck(r, "window: a programme that starts before the view moves it back", NxToStr(NxGuideWindowOffset(row[1], 3, t0&, nowC&, 44)), "0")

    print "guide time cursor tests: "; r.pass; " passed, "; r.fail; " failed"
    return r.fail
end function
