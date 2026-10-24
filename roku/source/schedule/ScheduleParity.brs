' What airs, as the Apple TV decides it: the guide's 24-hour window, one
' title on two channels, what tuning in plays and the next pick.
'
' Copyright (c) 2024 Chad Mueller / Muell Haus Inc. (Nostalgex), MIT License.
' Port copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Source: upstream scripts/nostalgex-daily-manifest.js (web tuner 1.0.7,
' f9b5562): blocksInRange, buildSchedule, scheduleIsCurrent,
' liveElapsedSeconds, tuneIn, resolveConflicts, findConflict and advancePick,
' which mirror the Apple TV's ChannelScheduleBuilder (Models/ChannelSchedule.
' swift) and AppState.advanceToNextItem (App/AppState+Playback.swift).
' Checked against scripts/schedule-parity-golden.json, which the Apple TV's
' own code writes (tests/ScheduleParityTests.brs). Port it, don't improve it.
'
' A block is { item, startSec, endSec } from NxManifestBlocks, or a guide
' block that carries ratingKey itself (source/guide/GuideSchedule.brs).
' buildSchedule's window and the next pick work on blocks alone, so they live
' in source/guide/Advance.brs, which the player loads: NxScheduleFromBlocks,
' NxAdvancePickFrom.

' ── Local time: the same clock time a calendar day on ───────────────────────

' Seconds the local clock is ahead of UTC at epochSec.
function NxLocalOffsetSec(epochSec as LongInteger) as LongInteger
    return NxLocalClock(epochSec).AsSeconds() - epochSec
end function

' calendar.date(byAdding: .day, value: 1, to:), as JS setDate(getDate() + 1)
' does it: the same wall-clock time the next day; where that time is
' skipped, the moment after the skip; where it happens twice, the first.
function NxSameClockNextDaySec(epochSec as LongInteger) as LongInteger
    before& = NxLocalOffsetSec(epochSec)
    wall& = epochSec + before& + 86400
    after& = NxLocalOffsetSec(epochSec + 2 * 86400)
    best& = -1
    for each o in [before&, after&]
        t& = wall& - o
        if NxLocalOffsetSec(t&) = o and (best& < 0 or t& < best&) then best& = t&
    end for
    if best& >= 0 then return best&
    return wall& - before&
end function

' ── The guide's schedule ────────────────────────────────────────────────────

' Every block of each local day from the day of fromSec to the day of toSec
' that overlaps [fromSec, toSec), in start order. blocksInRange: each day is
' built from one hour after its start.
function NxBlocksInRange(channel as Object, pool as Object, fromSec as LongInteger, toSec as LongInteger, memo = invalid as Dynamic) as Object
    out = []
    cursor& = NxLocalDay(fromSec).dayStartSec
    endDay& = NxLocalDay(toSec).dayStartSec
    while cursor& <= endDay&
        for each b in NxManifestBlocks(channel, pool, cursor& + 3600, memo)
            if b.endSec > fromSec and b.startSec < toSec then out.Push(b)
        end for
        cursor& = NxSameClockNextDaySec(cursor&)
    end while
    out.SortBy("startSec")
    return out
end function

function NxBuildSchedule(channel as Object, pool as Object, nowSec as LongInteger, memo = invalid as Dynamic) as Dynamic
    windowStart& = (nowSec \ 1800) * 1800
    return NxScheduleFromBlocks(NxBlocksInRange(channel, pool, windowStart&, windowStart& + 86400, memo), nowSec)
end function

' scheduleIsCurrent: the schedule still describes what is on at nowSec.
function NxScheduleIsCurrent(schedule as Dynamic, nowSec as LongInteger) as Boolean
    if schedule = invalid or schedule.nowPlaying = invalid then return false
    return schedule.nowPlaying.startSec <= nowSec and nowSec < schedule.nowPlaying.endSec
end function

' liveElapsedSeconds: seconds into what is on, capped at the programme's
' length. -1 when nothing is on.
function NxLiveElapsedSeconds(schedule as Dynamic, nowSec as LongInteger) as LongInteger
    if schedule = invalid or schedule.nowPlaying = invalid then return -1
    total& = 0
    item = schedule.nowPlaying.block.item
    if item <> invalid then total& = NxDuration(item) * 60
    if total& < 1 then total& = 1
    e& = nowSec - schedule.nowPlaying.startSec
    if e& > total& then e& = total&
    if e& < 0 then e& = 0
    return e&
end function

' tuneIn: what tuning to a channel plays and from where. The guide's
' schedule (precomputed, may be invalid) only while it still describes what
' is on, otherwise one built now. { block, seekSeconds }, or invalid.
function NxTuneIn(channel as Object, pool as Object, precomputed as Dynamic, nowSec as LongInteger) as Dynamic
    schedule = invalid
    if NxScheduleIsCurrent(precomputed, nowSec) then schedule = precomputed
    if schedule = invalid then schedule = NxBuildSchedule(channel, pool, nowSec)
    if schedule = invalid or schedule.nowPlaying = invalid then return invalid
    return { block: schedule.nowPlaying.block, seekSeconds: NxLiveElapsedSeconds(schedule, nowSec) }
end function

' resolveConflicts: one title on two channels, the lowest channel id keeps
' it; every other shows its next programme as on now, from its start. One
' pass. `rows` is [{ id, schedule }] in guide order; returns new rows.
function NxResolveConflicts(rows as Object) as Object
    out = []
    byKey = {}
    byKey.SetModeCaseSensitive()
    order = []
    for each row in rows
        out.Push({ id: row.id, schedule: row.schedule })
        s = row.schedule
        if s <> invalid and s.nowPlaying <> invalid then
            if byKey[s.nowPlaying.key] = invalid then
                byKey[s.nowPlaying.key] = []
                order.Push(s.nowPlaying.key)
            end if
            byKey[s.nowPlaying.key].Push(row.id)
        end if
    end for
    for each k in order
        ids = byKey[k]
        if ids.Count() >= 2 then
            ids.Sort()
            for i = 1 to ids.Count() - 1
                for each row in out
                    if row.id = ids[i] then row.schedule = NxGiveWay(row.schedule)
                end for
            end for
        end if
    end for
    return out
end function

function NxGiveWay(old as Object) as Object
    entries = []
    for each e in old.entries
        if e.isNowPlaying then
            c = {}
            c.Append(e)
            c.isNowPlaying = false
            c.isConflict = true
            entries.Push(c)
        else
            entries.Push(e)
        end if
    end for
    if old.upNext = invalid then return { entries: entries, nowPlaying: old.nowPlaying, upNext: old.upNext, elapsedSeconds: old.elapsedSeconds }
    np = {}
    np.Append(old.upNext)
    np.isNowPlaying = true
    np.isConflict = false
    upNext = invalid
    for j = 0 to entries.Count() - 1
        if entries[j].id = old.upNext.id then
            if j + 1 < entries.Count() then upNext = entries[j + 1]
            exit for
        end if
    end for
    return { entries: entries, nowPlaying: np, upNext: upNext, elapsedSeconds: 0 }
end function
