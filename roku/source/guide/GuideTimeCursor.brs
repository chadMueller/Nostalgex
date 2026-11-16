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

' ── The programme cursor (Chad 2026-11-15, the Apple TV's GuideProgramCursor) ──
' "It should jump to the next title not the next 30 minutes and we should have
' a highlight or some way of seeing where the cursor is at." Focus stays on
' the row; the cursor is a time on it, and the programme the cursor is on is
' the one covering that time. `cursor` is that time, or invalid for the live
' programme (where the guide comes back to). Blocks are { startSec, endSec }.
'
'  - Right: the next programme on the row, whatever its length, over a gap too.
'  - Left: the previous programme that has not ended; from the programme on now
'    there is none, and the guide goes to the bundle stripe as before.
'  - Up and Down: the row changes and the time stays, so the cursor is on the
'    programme of the new row covering that time.
'  - The window moves in time only when the programme the cursor moves to would
'    leave the view (NxGuideWindowOffset).

' The time the cursor stands at: its own, or now when it is on the live
' programme or has fallen behind now.
function NxGuideCursorTime(cursor as Dynamic, nowSec as LongInteger) as LongInteger
    if cursor = invalid then return nowSec
    c& = cursor
    if c& < nowSec then return nowSec
    return c&
end function

' The programme the cursor is on: the one covering its time. invalid in a gap.
function NxGuideCursorCurrent(blocks as Object, cursor as Dynamic, nowSec as LongInteger) as Dynamic
    return NxGuideBlockCovering(blocks, NxGuideCursorTime(cursor, nowSec))
end function

' Right: the programme after the cursor's, or the first to start after the
' cursor's time when it is in a gap. invalid when there is none.
function NxGuideCursorNext(blocks as Object, cursor as Dynamic, nowSec as LongInteger) as Dynamic
    cur = NxGuideCursorCurrent(blocks, cursor, nowSec)
    best = invalid
    if cur <> invalid then
        for each b in NxList(blocks)
            if b.startSec >= cur.endSec then
                if best = invalid or b.startSec < best.startSec then best = b
            end if
        end for
        return best
    end if
    t& = NxGuideCursorTime(cursor, nowSec)
    for each b in NxList(blocks)
        if b.startSec > t& then
            if best = invalid or b.startSec < best.startSec then best = b
        end if
    end for
    return best
end function

' Left: the programme before the cursor's that has not ended yet. invalid from
' the programme on now.
function NxGuideCursorPrevious(blocks as Object, cursor as Dynamic, nowSec as LongInteger) as Dynamic
    cur = NxGuideCursorCurrent(blocks, cursor, nowSec)
    anchor& = NxGuideCursorTime(cursor, nowSec)
    if cur <> invalid then anchor& = cur.startSec
    best = invalid
    for each b in NxList(blocks)
        if b.endSec <= anchor& and b.endSec > nowSec then
            if best = invalid or b.startSec > best.startSec then best = b
        end if
    end for
    return best
end function

' The cursor for a programme: its start, or invalid (live) when it is on now.
function NxGuideCursorFor(block as Object, nowSec as LongInteger) as Dynamic
    if block.startSec <= nowSec then return invalid
    return block.startSec
end function

' The window's offset, in half hours from the current one, that shows `block`:
' the offset it has while the programme starts inside the view with at least
' half a slot (15 minutes) of it showing; otherwise the slot its start is in
' (for the live programme, the slot now is in), clamped to 0..maxOffset.
' `windowStartSec` is the current half hour (offset 0).
function NxGuideWindowOffset(block as Object, offset as Integer, windowStartSec as LongInteger, nowSec as LongInteger, maxOffset as Integer) as Integer
    start& = block.startSec
    if start& < nowSec then start& = nowSec
    viewStart& = windowStartSec + offset * 1800
    viewEnd& = viewStart& + 7200
    if start& >= viewStart& and start& < viewEnd& - 900 then return offset
    wanted = Int((start& - windowStartSec) / 1800)
    if wanted < 0 then wanted = 0
    if wanted > maxOffset then wanted = maxOffset
    return wanted
end function
