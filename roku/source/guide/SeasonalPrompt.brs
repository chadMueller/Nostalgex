' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Seasonal packages, after upstream's scripts/nostalgex-season.js (Swift:
' ChannelBundle.swift, SeasonalPrompt.swift, GuideChannelOrder.swift), held to
' its scripts/season-golden.json. A seasonal package (`activeMonths` set) is
' never switched on for anyone and, once on, builds in every month. Its season
' only decides the invite above channel one and whether it leads the guide.
' `seasonStart` starts a season before the first of its first month: TIS THE
' SEASON is in season from local midnight a week before US Thanksgiving to
' the end of December. An anchor this build doesn't know is ignored.
'
' The invite, after SeasonalPrompt.swift: while a package is in season, off
' and not silenced, a row above channel one offers it; "not this year" holds
' until next year's season, "don't ask again" for good. Config order wins
' when two qualify, so one thing is asked at a time.
'
' `now` is a local calendar date { year, month, day }, as NxSeasonNow or
' NxFilterClock give it. Every rule here reads the date alone, never the
' time, so no zone enters.

' Today's local date.
function NxSeasonNow() as Object
    dt = CreateObject("roDateTime")
    dt.ToLocalTime()
    return { year: dt.GetYear(), month: dt.GetMonth(), day: dt.GetDayOfMonth() }
end function

function NxIsSeasonal(bundle as Dynamic) as Boolean
    if type(bundle) <> "roAssociativeArray" then return false
    return type(bundle.activeMonths) = "roArray"
end function

' US Thanksgiving, the fourth Thursday of November: its day of the month.
function NxUsThanksgivingDay(year as Integer) as Integer
    dt = CreateObject("roDateTime")
    dt.FromISO8601String(year.ToStr() + "-11-01T00:00:00Z")
    firstThursday = 1 + ((4 - dt.GetDayOfWeek() + 7) mod 7)
    return firstThursday + 21
end function

' `seasonStart` in `year` as { year, month, day }, or invalid (none, or an
' anchor this build doesn't know). `days` counts from the anchor; left out,
' or not a whole number, it is the anchor itself.
function NxSeasonStartDate(bundle as Dynamic, year as Integer) as Dynamic
    if not NxIsSeasonal(bundle) then return invalid
    start = bundle.seasonStart
    if type(start) <> "roAssociativeArray" then return invalid
    if not NxIsString(start.relativeTo) then return invalid
    if start.relativeTo <> "usThanksgiving" then return invalid
    days = 0
    t = type(start.days)
    if t = "roInt" or t = "roInteger" or t = "Integer" or t = "roLongInteger" or t = "LongInteger" then days = start.days
    dt = CreateObject("roDateTime")
    dt.FromISO8601String(year.ToStr() + "-11-" + Right("0" + NxUsThanksgivingDay(year).ToStr(), 2) + "T00:00:00Z")
    dt.FromSeconds(dt.AsSeconds() + days * 86400)
    return { year: dt.GetYear(), month: dt.GetMonth(), day: dt.GetDayOfMonth() }
end function

' Mirrors isInSeason. A package without activeMonths always is.
function NxIsInSeason(bundle as Dynamic, now as Object) as Boolean
    if not NxIsSeasonal(bundle) then return true
    if NxHasValue(bundle.activeMonths, now.month) then
        ' Late September gate: if September is in the list, only from the 15th.
        return now.month <> 9 or now.day >= 15
    end if
    ' A season that starts early: from `seasonStart` to the end of that month.
    start = NxSeasonStartDate(bundle, now.year)
    if start = invalid then return false
    nowKey = now.year * 10000 + now.month * 100 + now.day
    startKey = start.year * 10000 + start.month * 100 + start.day
    return nowKey >= startKey and now.month = start.month
end function

' The package to offer, or invalid. `silenced` answers
' NxSeasonalSilenced(id, year) or a stand-in for tests.
function NxSeasonalOffer(bundles as Object, enabled as Object, now as Object, silenced as Object) as Dynamic
    for each b in bundles
        if NxIsSeasonal(b) and NxIsInSeason(b, now) then
            if not NxHasValue(enabled, b.id) and not silenced.isSilenced(b.id, now.year) then return b
        end if
    end for
    return invalid
end function

' Mirrors seasonalLeadIDs: the channels of every seasonal package on and in
' season, in config order.
function NxSeasonalLeadIds(bundles as Object, enabled as Object, now as Object) as Object
    out = []
    for each b in NxList(bundles)
        if NxIsSeasonal(b) and NxHasValue(enabled, b.id) and NxIsInSeason(b, now) then out.Append(NxList(b.channelIDs))
    end for
    return out
end function

' What the cache keys need of the date: the month (a clock-free filter result
' reads only the year) and which packages are in season (the guide's lead).
function NxSeasonKey(bundles as Object, now as Object) as String
    ids = []
    for each b in NxList(bundles)
        if NxIsSeasonal(b) and NxIsInSeason(b, now) then ids.Push(NxToStr(b.id))
    end for
    return now.year.ToStr() + "-" + now.month.ToStr() + "|" + ids.Join(",")
end function

' The answers as the TV keeps them: per package for "never", per package and
' year for "not this year".
function NxSeasonalRegistry() as Object
    return {
        reg: NxRegSection("guide"),
        isSilenced: function(id as String, year as Integer) as Boolean
            if m.reg.Read("seasonalNever_" + id) = "1" then return true
            return m.reg.Read("seasonalDismissed_" + id + "_" + year.ToStr()) = "1"
        end function,
        record: function(answer as String, id as String, year as Integer) as Boolean
            if answer = "yes" then return true
            if answer = "never" then
                m.reg.Write("seasonalNever_" + id, "1")
            else
                m.reg.Write("seasonalDismissed_" + id + "_" + year.ToStr(), "1")
            end if
            m.reg.Flush()
            return false
        end function
    }
end function

' The invite's headline (inviteHeadline) and colour (SeasonalInviteRow).
' TIS THE SEASON only says December in December.
function NxSeasonalHeadline(b as Object, now as Object) as String
    if b.id = "seasonal" then return "IT'S OCTOBER. ARE YOU READY TO SCREAM?"
    if b.id = "tis-the-season" then
        if now.month = 12 then return "IT'S DECEMBER. DECK THE CHANNELS."
        return "THE HOLIDAYS ARE HERE. DECK THE CHANNELS."
    end if
    return NxToStr(b.name) + " IS IN SEASON."
end function

' Mirrors seasonalSpotlightLabel, the Settings row's note for a seasonal
' package outside its season: "SPOTLIGHTED OCT", or with `seasonStart`
' "SPOTLIGHTED NOV 19 TO DEC 31" (this year's dates). "" for any other.
function NxSeasonSpotlightLabel(b as Object, now as Object) as String
    if not NxIsSeasonal(b) then return ""
    months = b.activeMonths
    if months.Count() = 0 then return ""
    abbr = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    start = NxSeasonStartDate(b, now.year)
    last = months[months.Count() - 1]
    if start <> invalid and NxIsNumber(last) then
        if last >= 1 and last <= 12 then
            endYear = start.year
            if last < start.month then endYear = endYear + 1
            ' The month's last day: the day before the 1st of the next.
            dt = CreateObject("roDateTime")
            nextMonth = last + 1
            nextYear = endYear
            if nextMonth = 13 then
                nextMonth = 1
                nextYear = endYear + 1
            end if
            dt.FromISO8601String(nextYear.ToStr() + "-" + Right("0" + nextMonth.ToStr(), 2) + "-01T00:00:00Z")
            dt.FromSeconds(dt.AsSeconds() - 86400)
            return "SPOTLIGHTED " + abbr[start.month - 1] + " " + start.day.ToStr() + " TO " + abbr[last - 1] + " " + dt.GetDayOfMonth().ToStr()
        end if
    end if
    names = []
    for each mo in months
        if NxIsNumber(mo) then
            if mo >= 1 and mo <= 12 then names.Push(abbr[mo - 1])
        end if
    end for
    if names.Count() = 0 then return ""
    return "SPOTLIGHTED " + names.Join(", ")
end function

function NxSeasonalAccent(b as Object) as String
    if b.id = "seasonal" then return "#FF6B00"
    if b.id = "tis-the-season" then return "#E74C3C"
    return "#FFE500"
end function
