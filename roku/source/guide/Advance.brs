' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' When an airing hands over to the next, after upstream's advanceToNextItem
' (App/AppState+Playback.swift). The schedule counts whole minutes, but a file
' runs to its own length, which can be up to a minute past its slot (Plex's
' milliseconds rounded) or short of it. Upstream moves on when the file ends,
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

' The airing to start from its beginning when the playing one's file ends at
' t, as advanceToNextItem picks it (via advancePick in upstream's
' nostalgex-daily-manifest.js): what airs now if the schedule has moved on
' (the file ran over), else the one after it (the file ended early), but
' never a title another channel has on now: then the entry after it.
' `channels` ([{ id, blocks }], the guide's) and `channelId` are optional;
' without them no other channel is checked. invalid when nothing is left.
function NxNextAiring(blocks as Object, playing as Object, t as LongInteger, channels = invalid as Dynamic, channelId = invalid as Dynamic) as Dynamic
    others = []
    if type(channels) = "roArray" then
        for each ch in channels
            others.Push({ id: ch.id, schedule: NxScheduleFromBlocks(ch.blocks, t) })
        end for
    end if
    p = NxAdvancePickFrom(NxScheduleFromBlocks(blocks, t), playing.ratingKey, t, channelId, others, true)
    if p = invalid then return invalid
    return p.block
end function

' ── What airs (scheduled from blocks), shared with source/schedule/ScheduleParity.brs ──

function NxBlockKey(b as Object) as String
    if b.item <> invalid then return NxToStr(b.item.ratingKey)
    return NxToStr(b.ratingKey)
end function

' The guide's view of a channel at nowSec from its blocks: a 24-hour window
' from the current half hour, what is on, what is next and how far in.
' buildSchedule. invalid when nothing falls in the window.
function NxScheduleFromBlocks(blocks as Object, nowSec as LongInteger) as Dynamic
    windowStart& = (nowSec \ 1800) * 1800
    windowEnd& = windowStart& + 86400
    entries = []
    nowIdx = -1
    for each b in blocks
        if b.endSec > windowStart& and b.startSec < windowEnd& then
            isNow = b.startSec <= nowSec and b.endSec > nowSec
            entries.Push({ id: NxBlockKey(b) + "_" + NxToStr(b.startSec), block: b, key: NxBlockKey(b), startSec: b.startSec, endSec: b.endSec, isNowPlaying: isNow, isConflict: false })
            if isNow then nowIdx = entries.Count() - 1
        end if
    end for
    if entries.Count() = 0 then return invalid
    nowPlaying = invalid
    upNext = invalid
    elapsed& = 0
    if nowIdx >= 0 then
        nowPlaying = entries[nowIdx]
        if nowIdx + 1 < entries.Count() then upNext = entries[nowIdx + 1]
        elapsed& = nowSec - nowPlaying.startSec
        if elapsed& < 0 then elapsed& = 0
    end if
    return { entries: entries, nowPlaying: nowPlaying, upNext: upNext, elapsedSeconds: elapsed& }
end function

' findConflict: whether another channel has `key` on now. `others` is
' [{ id, schedule }] built at the same instant, in guide order.
function NxKeyOnElsewhere(key as String, excludingId as Dynamic, others as Object) as Boolean
    for each o in others
        if o.id <> excludingId and o.schedule <> invalid then
            if o.schedule.nowPlaying <> invalid then
                if o.schedule.nowPlaying.key = key then return true
            end if
        end if
    end for
    return false
end function

' advancePick: what a channel plays next when its programme ends, and from
' where. The schedule's programme if it has moved on, otherwise the next
' one; never the title another channel has on now (skip one entry); from 0
' on a natural end. { block, seekSeconds }, or invalid.
function NxAdvancePickFrom(schedule as Dynamic, prevKey as Dynamic, nowSec as LongInteger, channelId as Dynamic, others as Object, fromNaturalEnd = true as Boolean) as Dynamic
    if schedule = invalid then return invalid
    nowKey = invalid
    if schedule.nowPlaying <> invalid then nowKey = schedule.nowPlaying.key
    moved = NxToStr(nowKey) <> NxToStr(prevKey)
    pick = invalid
    if moved then
        pick = schedule.nowPlaying
    else if schedule.upNext <> invalid then
        pick = schedule.upNext
    else
        pick = schedule.nowPlaying
    end if
    seek& = 0
    if moved and pick <> invalid and not fromNaturalEnd then seek& = schedule.elapsedSeconds
    if pick <> invalid then
        if NxKeyOnElsewhere(pick.key, channelId, others) then
            for idx = 0 to schedule.entries.Count() - 1
                if schedule.entries[idx].key = pick.key then
                    if idx + 1 < schedule.entries.Count() then
                        pick = schedule.entries[idx + 1]
                        seek& = 0
                    end if
                    exit for
                end if
            end for
        end if
    end if
    if pick = invalid then return invalid
    return { block: pick.block, seekSeconds: seek& }
end function
