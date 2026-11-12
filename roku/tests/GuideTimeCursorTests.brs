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

    print "guide time cursor tests: "; r.pass; " passed, "; r.fail; " failed"
    return r.fail
end function
