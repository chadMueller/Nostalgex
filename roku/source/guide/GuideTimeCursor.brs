' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' The guide's time cursor (#275), the Apple TV's GuideTimeCursor.swift (I-089):
' Right and Left move the guide's window through time, 30 minutes a press with
' focus staying on the row, and the info panel follows it. Moved later than
' now, the panel shows the focused channel's programme at the window's left
' edge (the one about to start there), with its time range where the progress
' bar was and the programme after it as UP NEXT, not what is on now.

' The time the panel previews: windowStart plus slotOffset half hours, or
' invalid for the live programme (the window is at its start, or the cursor is
' not later than now). `windowStartSec` is the window's first tick with no
' offset (the current half hour).
function NxGuidePreviewTime(slotOffset as Integer, windowStartSec as LongInteger, nowSec as LongInteger) as Dynamic
    if slotOffset <= 0 then return invalid
    cursor& = windowStartSec + slotOffset * 1800
    if cursor& > nowSec then return cursor&
    return invalid
end function

' The programme of `blocks` that covers `t`, or invalid for a gap (the panel
' then shows what is on now, as it always did): a start is that programme's.
function NxGuideBlockCovering(blocks as Object, t as LongInteger) as Dynamic
    for each b in NxList(blocks)
        if b.startSec <= t and t < b.endSec then return b
    end for
    return invalid
end function

' "9:30 PM to 11:00 PM": a programme's time range, as the panel shows it in
' place of the progress bar. `label` turns an epoch second into "9:30 PM".
function NxGuideTimeRange(startLabel as String, endLabel as String) as String
    return startLabel + " to " + endLabel
end function
