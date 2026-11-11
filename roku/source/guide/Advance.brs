' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' When an airing hands over to the next, after upstream's advanceToNextItem
' (App/AppState+Playback.swift). The schedule counts whole minutes, but a file
' runs to its own length, which can be up to a minute past its slot (its
' milliseconds truncated to minutes, as the Apple TV's loaders do) or short
' of it. Upstream moves on when the file ends,
' not when the slot does, and starts the next item from its beginning, so the
' last seconds of an episode are never cut. The player itself lives in
' components/GuideView.brs.

' How long an airing may run past its slot before the clock takes over
' anyway: a stream that reports playing but never finishes must not hold the
' channel. Upstream has no such cap; five minutes is well past any rounding
' or metadata drift (upstream measured 40+ s).
function NxOverrunCapSec() as Integer
    return 300
end function

' Whether the clock should take the channel off the airing it plays. Not
' while the file is still playing past its slot: it ends on its own.
function NxAiringEnded(playing as Dynamic, t as LongInteger, videoState as String) as Boolean
    if playing = invalid or t < playing.endSec then return false
    if videoState = "playing" and t < playing.endSec + NxOverrunCapSec() then return false
    return true
end function

' Whether a guide rebuilt at t leaves the airing playing alone because it
' began before today's local midnight and its slot is still running. A day's
' last programme can run past midnight (the packing loop is t < dayEnd, so it
' ends where the file does), and from midnight the guide reads the new day
' only: the airing is no longer in it, the new day's first one is on now, and
' the rebuild would retune the channel off a film mid-way (#297). The Apple
' TV and the web tuner leave the player alone on a rebuild; it ends on its own
' (NxAiringEnded) and NxAdvancePick moves on. Stateless, so it holds through
' every later rebuild until the slot is over.
function NxKeepPlayingPastMidnight(playing as Dynamic, t as LongInteger) as Boolean
    if playing = invalid then return false
    if t >= playing.endSec then return false
    return playing.startSec < NxLocalDay(t).dayStartSec
end function

' ── What airs: the guide's window, one title on two channels, the next pick ──
' After ChannelScheduleBuilder (Models/ChannelSchedule.swift) and
' AppState.advanceToNextItem, as the web tuner mirrors them in
' scripts/nostalgex-daily-manifest.js (buildSchedule, resolveConflicts,
' findConflict, advancePick). Checked against upstream's
' scripts/schedule-parity-golden.json, which the Apple TV's own code made
' (tests/ScheduleParityGoldenTests.brs). `channels` are the guide's, in guide
' order, each with its `blocks` (NxScheduleGuide: today and tomorrow, which
' always hold the 24-hour window).

' A channel at t as buildSchedule sees it: the blocks of the 24-hour window
' from the current half hour, in start order, and the indexes of what is on
' now and next in them (-1 for none). invalid when the window holds nothing.
' window is NxGuideWindow(t), passed when one t serves many channels.
function NxChannelSchedule(blocks as Object, t as LongInteger, window = invalid as Dynamic) as Dynamic
    if window = invalid then window = NxGuideWindow(t)
    entries = []
    nowIdx = -1
    for each b in blocks
        if b.endSec > window.fromSec and b.startSec < window.toSec and b.startSec >= window.daysFrom and b.startSec < window.daysTo then
            if nowIdx < 0 and b.startSec <= t and b.endSec > t then nowIdx = entries.Count()
            entries.Push(b)
        end if
    end for
    if entries.Count() = 0 then return invalid
    nextIdx = -1
    if nowIdx >= 0 and nowIdx + 1 < entries.Count() then nextIdx = nowIdx + 1
    elapsed& = 0
    if nowIdx >= 0 then elapsed& = t - entries[nowIdx].startSec
    return { entries: entries, now: nowIdx, next: nextIdx, elapsed: elapsed& }
end function

' The guide's window at t: the 24-hour span from the current half hour
' (fromSec, toSec), and the local days DailyManifestScheduler.blocksInRange
' reads for it (a block belongs to the day it starts in; daysFrom, daysTo).
' The days run from the day of the window's start, a step of one calendar
' day at the same clock time each time (calendar.date(byAdding: .day)), while
' that is not past the day of its end. On a day that starts at 1 AM (midnight
' skipped), the step lands at 1 AM the next day, past that day's start, so
' the window stops at the midnight, as the Apple TV's does.
function NxGuideWindow(t as LongInteger) as Object
    wStart& = (t \ 1800) * 1800
    wEnd& = wStart& + 86400
    out = { fromSec: wStart&, toSec: wEnd&, daysFrom: NxLocalDay(wStart&).dayStartSec, daysTo: 0& }
    out.daysTo = out.daysFrom
    cursor& = out.daysFrom
    endDay& = NxLocalDay(wEnd&).dayStartSec
    while cursor& <= endDay&
        d = NxLocalDay(cursor& + 3600)
        out.daysTo = NxStartOfNextLocalDaySec(d.dayStartSec)
        ' The same clock time on the next day; a time the clocks skip there
        ' moves on to the day's first moment, as Foundation and JS Date do.
        nextStart& = NxStartOfNextLocalDaySec(cursor&)
        nxt& = nextStart& + NxClockSecOfDay(NxLocalClock(cursor&)) - NxClockSecOfDay(NxLocalClock(nextStart&))
        if nxt& < nextStart& then nxt& = nextStart&
        cursor& = nxt&
    end while
    return out
end function

' The block on air at t, as the schedule's now, or invalid. Not simply a
' block spanning t: a day's last programme can run past midnight, and from
' midnight on the window reads the new day only, so its first programme is
' the one on.
function NxBlockOnAir(blocks as Object, t as LongInteger, window = invalid as Dynamic) as Dynamic
    s = NxChannelSchedule(blocks, t, window)
    if s = invalid then return invalid
    if s.now < 0 then return invalid
    return s.entries[s.now]
end function

' One title on two channels at once (resolveConflicts): the lowest channel id
' keeps it, and every other channel showing it gives it way, its next
' programme shown as on now. One pass, as on the Apple TV: a channel moved on
' is not checked again. Returns an AA of channel index (as a string) to
' { gaveWay, shown } for the channels that gave way: the block given way, and
' the one shown as on now in its place (the same block when nothing follows
' it in the window).
function NxGaveWay(channels as Object, t as LongInteger) as Object
    window = NxGuideWindow(t)
    byKey = {}
    byKey.SetModeCaseSensitive()
    keys = []
    for i = 0 to channels.Count() - 1
        b = NxBlockOnAir(channels[i].blocks, t, window)
        if b <> invalid then
            k = NxToStr(b.ratingKey)
            if not byKey.DoesExist(k) then
                byKey[k] = []
                keys.Push(k)
            end if
            byKey[k].Push(i)
        end if
    end for
    out = {}
    for each k in keys
        idxs = byKey[k]
        if idxs.Count() > 1 then
            keep = idxs[0]
            for each i in idxs
                if channels[i].id < channels[keep].id then keep = i
            end for
            for each i in idxs
                if i <> keep then
                    s = NxChannelSchedule(channels[i].blocks, t, window)
                    shown = s.entries[s.now]
                    if s.next >= 0 then shown = s.entries[s.next]
                    out[i.ToStr()] = { gaveWay: s.entries[s.now], shown: shown }
                end if
            end for
        end if
    end for
    return out
end function

' The first other channel, in guide order, with ratingKey on at t
' (findConflict): its index, or -1.
function NxFindConflict(channels as Object, idx as Integer, ratingKey as Dynamic, t as LongInteger) as Integer
    k = NxToStr(ratingKey)
    window = NxGuideWindow(t)
    for i = 0 to channels.Count() - 1
        if i <> idx and channels[i].id <> channels[idx].id then
            b = NxBlockOnAir(channels[i].blocks, t, window)
            if b <> invalid then
                if NxToStr(b.ratingKey) = k then return i
            end if
        end if
    end for
    return -1
end function

' What channel idx plays when the programme prevKey was playing ends at t,
' and from where (advanceToNextItem): what is on now, if the schedule has
' moved off prevKey, else the one after it. Never the title another channel
' has on at t: the entry after that title's first in the window instead,
' from its start. natural says the file played to its end, so the pick
' starts from its beginning; after a stall or a failure, one already airing
' joins where the clock is. Returns { block, seek }, or invalid when the
' window holds nothing. A block already over at t comes back as a copy that
' airs from t.
function NxAdvancePick(channels as Object, idx as Integer, prevKey as Dynamic, t as LongInteger, natural as Boolean) as Dynamic
    s = NxChannelSchedule(channels[idx].blocks, t)
    if s = invalid then return invalid
    nowB = invalid
    if s.now >= 0 then nowB = s.entries[s.now]
    if nowB = invalid then
        moved = prevKey <> invalid
    else if prevKey = invalid then
        moved = true
    else
        moved = NxToStr(nowB.ratingKey) <> NxToStr(prevKey)
    end if
    pick = invalid
    if moved then
        pick = nowB
    else if s.next >= 0 then
        pick = s.entries[s.next]
    else
        pick = nowB
    end if
    if pick = invalid then return invalid
    seek& = 0
    if moved and not natural then seek& = s.elapsed
    if NxFindConflict(channels, idx, pick.ratingKey, t) >= 0 then
        k = NxToStr(pick.ratingKey)
        for i = 0 to s.entries.Count() - 1
            if NxToStr(s.entries[i].ratingKey) = k then
                if i + 1 < s.entries.Count() then
                    pick = s.entries[i + 1]
                    seek& = 0
                end if
                exit for
            end if
        end for
    end if
    ' The skip takes the entry after the title's first airing in the window,
    ' which can be one already over. Upstream just plays the item from its
    ' start; here the player's clock reads the airing's slot, and an ended
    ' one would hand over again on the next tick, to the same pick, forever.
    ' So it airs as from now, for its slot's length. A copy: the schedule
    ' keeps its own.
    ' The same for a pick that began more than the overrun cap ago and starts
    ' from its beginning: after a tail past midnight, the new day's first
    ' airing has been on for the tail's length (65 min in #297), and its slot
    ' would end the file that far in. A tail runs to 59 s over on its own.
    late = pick.endSec <= t
    if not late and seek& = 0 then late = t - pick.startSec > NxOverrunCapSec()
    if late then
        shifted = {}
        shifted.Append(pick)
        shifted.endSec = t + (pick.endSec - pick.startSec)
        shifted.startSec = t
        pick = shifted
    end if
    return { block: pick, seek: seek& }
end function
