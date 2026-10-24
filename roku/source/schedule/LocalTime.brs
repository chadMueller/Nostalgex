' The local day, as nostalgex-daily-manifest.js reads it: startOfLocalDayMs,
' startOfNextLocalDayMs, localDayKey, localDayNumber and previousLocalDayKey.
' Moved out of source/guide/Lineup.brs unchanged, so the player can read the
' guide's window (source/guide/Advance.brs) without the scheduler.
'
' Copyright (c) 2024 Chad Mueller / Muell Haus Inc. (Nostalgex), MIT License.
' Port copyright (c) 2026 nostalgex-roku contributors, MIT License.

' { dayStartSec, dayKey, dayNumber } for the local day holding epochSec, as
' startOfLocalDayMs, localDayKey and localDayNumber. Tests pin the zone by
' setting GetGlobalAA().nxTzOffsetSec, or nxTzOffsets for a zone whose
' clocks change.
function NxLocalDay(epochSec as LongInteger) as Object
    dt = NxLocalClock(epochSec)
    secOfDay = NxClockSecOfDay(dt)
    dayStart& = epochSec - secOfDay
    ' On a day the clocks change, the clock's time since midnight is an hour
    ' off the real one, so look at what the clock says at that guess. Where
    ' midnight itself is skipped, the day starts at its first moment, as
    ' setHours(0, 0, 0, 0) has it.
    at = NxLocalClock(dayStart&)
    if NxClockSameDate(at, dt) then
        s = NxClockSecOfDay(at)
        if s > 0 and NxClockSameDate(NxLocalClock(dayStart& - s), dt) then dayStart& = dayStart& - s
    else
        dayStart& = dayStart& + 86400 - NxClockSecOfDay(at)
    end if
    key = dt.GetYear().ToStr() + "-" + NxPad2(dt.GetMonth()) + "-" + NxPad2(dt.GetDayOfMonth())
    return { dayStartSec: dayStart&, dayKey: key, dayNumber: NxFloorDivLong(dayStart&, 86400), hour: dt.GetHours(), month: dt.GetMonth() }
end function

' The start of the local day after the one holding epochSec, as
' startOfNextLocalDayMs. A day is 23 to 25 hours long where the clocks change
' (23.5 or 24.5 on Lord Howe), so its start plus 86,400 s falls an hour short
' of the next midnight when they go back and an hour into the next day when
' they go forward. 36 hours after a day's start is always inside the next
' day, and that day's start is the answer, even where midnight is skipped.
function NxStartOfNextLocalDaySec(epochSec as LongInteger) as LongInteger
    return NxLocalDay(NxLocalDay(epochSec).dayStartSec + 36 * 3600).dayStartSec
end function

' The key of the local day before the one holding epochSec, as
' previousLocalDayKey. 12 hours before a day's start is always inside the day
' before; 24 hours before the day after the clocks go forward is two days back.
function NxPreviousLocalDayKey(epochSec as LongInteger) as String
    return NxLocalDay(NxLocalDay(epochSec).dayStartSec - 12 * 3600).dayKey
end function

' An roDateTime showing the local wall clock at epochSec. nxTzOffsets is
' [{ fromSec, offsetSec }] in time order, each offset holding from its
' fromSec on.
function NxLocalClock(epochSec as LongInteger) as Object
    g = GetGlobalAA()
    off = g.nxTzOffsetSec
    if type(g.nxTzOffsets) = "roArray" then
        for each z in g.nxTzOffsets
            if epochSec >= z.fromSec then off = z.offsetSec
        end for
    end if
    dt = CreateObject("roDateTime")
    if off <> invalid then
        dt.FromSeconds(epochSec + off)
    else
        dt.FromSeconds(epochSec)
        dt.ToLocalTime()
    end if
    return dt
end function

function NxClockSecOfDay(dt as Object) as Integer
    return dt.GetHours() * 3600 + dt.GetMinutes() * 60 + dt.GetSeconds()
end function

function NxClockSameDate(a as Object, b as Object) as Boolean
    return a.GetDayOfMonth() = b.GetDayOfMonth() and a.GetMonth() = b.GetMonth() and a.GetYear() = b.GetYear()
end function

function NxPad2(n as Integer) as String
    if n < 10 then return "0" + n.ToStr()
    return n.ToStr()
end function

function NxFloorDivLong(a as LongInteger, b as LongInteger) as Integer
    q = a \ b
    if (a mod b) <> 0 and a < 0 then q = q - 1
    return q
end function
