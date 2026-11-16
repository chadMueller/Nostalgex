' The weather channel's engine (Trello I-016), CH 299 LOCAL WEATHER. Pure logic: no screen, no
' network and no clock of its own; the view, the task and the tests pass those in.
'
' A port of the web tuner's scripts/nostalgex-weather.js, which is the reference: its rules and
' numbers are held here by scripts/weather-golden.json (tests/WeatherTests.brs). Where this file and
' the JS differ it is a bug here. Times are whole seconds since 1970 in an Integer (the golden's
' milliseconds are divided by 1000), so no LongInteger arithmetic is needed before 2038.
'
' Copyright (c) 2026 nostalgex-roku contributors, MIT License.

' ── The channel ──────────────────────────────────────────────────────────────

' CH 299, as the web tuner has it. The id sits in the next free dynamic block, so a channel the
' viewer makes later can never take it.
function NxWxChannel() as Object
    return { number: 299, id: 1030000, name: "LOCAL WEATHER", color: "#00D4FF" }
end function

' The loop, in seconds. Radar is longest: it plays its frames over and over.
function NxWxScreens() as Object
    return [
        { id: "current", title: "CURRENT CONDITIONS", seconds: 15 },
        { id: "today", title: "TODAY'S FORECAST", seconds: 15 },
        { id: "week", title: "5-DAY FORECAST", seconds: 15 },
        { id: "radar", title: "RADAR", seconds: 20 }
    ]
end function

function NxWxLoopSeconds() as Integer
    return 65
end function

' Which screen is up at nowSec and how far into it: the loop runs on the wall clock, so every
' viewer sees the same one. nowSec may carry a fraction.
function NxWxScreenAt(nowSec as Dynamic) as Object
    screens = NxWxScreens()
    total = NxWxLoopSeconds()
    n# = nowSec
    whole% = n# \ 1
    t# = (whole% mod total) + (n# - whole%)
    for i = 0 to screens.Count() - 1
        if t# < screens[i].seconds then return { index: i, id: screens[i].id, title: screens[i].title, elapsed: t#, remaining: screens[i].seconds - t# }
        t# = t# - screens[i].seconds
    end for
    return { index: 0, id: screens[0].id, title: screens[0].title, elapsed: 0#, remaining: screens[0].seconds }
end function

' ── Numbers ──────────────────────────────────────────────────────────────────

' Math.round: halves go up.
function NxWxRound(x as Double) as Integer
    return Int(x + 0.5#)
end function

function NxWxFinite(v as Dynamic) as Boolean
    return NxIsNumber(v)
end function

' Math.round(n * 10) / 10, or invalid when there is no number.
function NxWxR1(v as Dynamic) as Dynamic
    if not NxIsNumber(v) then return invalid
    d# = v
    r# = Int(d# * 10# + 0.5#)
    return r# / 10#
end function

' n.toFixed(places) for the places the channel uses (1 and 2).
function NxWxFixed(v as Double, places as Integer) as String
    scale% = 1
    for i = 1 to places
        scale% = scale% * 10
    end for
    neg = v < 0
    a# = Abs(v)
    scaled% = Int(a# * scale% + 0.5#)
    whole% = scaled% \ scale%
    frac% = scaled% - whole% * scale%
    fs = frac%.ToStr()
    while Len(fs) < places
        fs = "0" + fs
    end while
    s = whole%.ToStr()
    if places > 0 then s = s + "." + fs
    if neg and scaled% > 0 then s = "-" + s
    return s
end function

' ── Units ────────────────────────────────────────────────────────────────────

' F where the place's country is the US, otherwise C, unless the viewer chose: "auto", "F" or "C".
function NxWxUnitsFor(place as Dynamic, setting as Dynamic) as String
    if setting = "F" or setting = "C" then return setting
    if type(place) = "roAssociativeArray" and UCase(NxToStr(place.cc)) = "US" then return "F"
    return "C"
end function

function NxWxFmtTemp(c as Dynamic, units as String) as String
    if not NxIsNumber(c) then return "--"
    v# = c
    if units = "F" then v# = v# * 9# / 5# + 32#
    r% = NxWxRound(v#)
    return r%.ToStr()
end function

' mph on F, km/h on C (the MET value is metres per second).
function NxWxFmtWind(ms as Dynamic, units as String) as String
    if not NxIsNumber(ms) then return "--"
    v# = ms
    if units = "F" then
        r% = NxWxRound(v# * 2.2369363#)
        return r%.ToStr() + " MPH"
    end if
    r% = NxWxRound(v# * 3.6#)
    return r%.ToStr() + " KM/H"
end function

function NxWxFmtPressure(hpa as Dynamic, units as String) as String
    if not NxIsNumber(hpa) then return "--"
    v# = hpa
    if units = "F" then return NxWxFixed(v# * 0.02953#, 2) + " IN"
    r% = NxWxRound(v#)
    return r%.ToStr() + " HPA"
end function

' Rain and snow melt: inches to 2 places, or millimetres to 1 below 10 and whole above.
function NxWxFmtPrecip(mm as Dynamic, units as String) as String
    if not NxIsNumber(mm) then return "--"
    v# = mm
    if units = "F" then return NxWxFixed(v# / 25.4#, 2) + " IN"
    if v# < 10 then return NxWxFixed(v#, 1) + " MM"
    r% = NxWxRound(v#)
    return r%.ToStr() + " MM"
end function

function NxWxCompass(deg as Dynamic) as String
    if not NxIsNumber(deg) then return ""
    names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    d# = deg
    d# = ((d# - 360# * Int(d# / 360#)) + 360#)
    d# = d# - 360# * Int(d# / 360#)
    i% = NxWxRound(d# / 22.5#) mod 16
    return names[i%]
end function

' ── Symbols ──────────────────────────────────────────────────────────────────

' { icon, text, night } for a MET symbol code. Unknown codes read as cloud, never as a blank.
function NxWxSymbolInfo(code as Dynamic) as Object
    raw = NxToStr(code)
    base = raw
    suffix = ""
    for each sfx in ["_day", "_night", "_polartwilight"]
        if Len(raw) > Len(sfx) and Right(raw, Len(sfx)) = sfx then
            base = Left(raw, Len(raw) - Len(sfx))
            suffix = Mid(sfx, 2)
        end if
    end for
    night = suffix = "night"
    intensity = "mid"
    family = base
    if Left(base, 5) = "light" then
        intensity = "light"
        family = Mid(base, 6)
    else if Left(base, 5) = "heavy" then
        intensity = "heavy"
        family = Mid(base, 6)
    end if
    if Instr(1, family, "thunder") > 0 then
        text = "THUNDERSTORMS"
        if Instr(1, family, "snow") > 0 then text = "THUNDER SNOW"
        return { icon: "thunder", text: text, night: night }
    end if
    if family = "clearsky" then
        if night then return { icon: "moon", text: "CLEAR", night: night }
        return { icon: "sun", text: "SUNNY", night: night }
    else if family = "fair" then
        if night then return { icon: "fair-night", text: "MOSTLY CLEAR", night: night }
        return { icon: "fair-day", text: "MOSTLY SUNNY", night: night }
    else if family = "partlycloudy" then
        if night then return { icon: "partly-night", text: "PARTLY CLOUDY", night: night }
        return { icon: "partly-day", text: "PARTLY CLOUDY", night: night }
    else if family = "cloudy" then
        return { icon: "cloud", text: "CLOUDY", night: night }
    else if family = "fog" then
        return { icon: "fog", text: "FOG", night: night }
    else if family = "rain" then
        if intensity = "light" then return { icon: "drizzle", text: "LIGHT RAIN", night: night }
        if intensity = "heavy" then return { icon: "heavy-rain", text: "HEAVY RAIN", night: night }
        return { icon: "rain", text: "RAIN", night: night }
    else if family = "rainshowers" then
        icon = "showers-day"
        if night then icon = "showers-night"
        text = "SHOWERS"
        if intensity = "light" then text = "LIGHT SHOWERS"
        if intensity = "heavy" then text = "HEAVY SHOWERS"
        return { icon: icon, text: text, night: night }
    else if family = "sleet" or family = "sleetshowers" then
        word = "SLEET SHOWERS"
        if family = "sleet" then word = "SLEET"
        pre = ""
        if intensity = "light" then pre = "LIGHT "
        if intensity = "heavy" then pre = "HEAVY "
        return { icon: "sleet", text: pre + word, night: night }
    else if family = "snow" then
        text = "SNOW"
        if intensity = "light" then text = "LIGHT SNOW"
        if intensity = "heavy" then text = "HEAVY SNOW"
        return { icon: "snow", text: text, night: night }
    else if family = "snowshowers" then
        icon = "flurries-day"
        if night then icon = "flurries-night"
        text = "SNOW SHOWERS"
        if intensity = "light" then text = "FLURRIES"
        if intensity = "heavy" then text = "HEAVY SNOW SHOWERS"
        return { icon: icon, text: text, night: night }
    end if
    return { icon: "cloud", text: "CLOUDY", night: night }
end function

' The daytime form of a symbol code: the 5-day screen shows the day, so no moon on a day's icon.
function NxWxDayForm(code as Dynamic) as String
    raw = NxToStr(code)
    for each sfx in ["_night", "_polartwilight"]
        if Len(raw) > Len(sfx) and Right(raw, Len(sfx)) = sfx then return Left(raw, Len(raw) - Len(sfx)) + "_day"
    end for
    return raw
end function

' ── Dates and the place's time zone ──────────────────────────────────────────

' Days since 1970-01-01 of a civil date (Howard Hinnant's days_from_civil).
function NxWxDaysFromCivil(y as Integer, mo as Integer, d as Integer) as Integer
    yy = y
    if mo <= 2 then yy = y - 1
    era = yy \ 400
    if yy < 0 then era = (yy - 399) \ 400
    yoe = yy - era * 400
    mp = mo + 9
    if mo > 2 then mp = mo - 3
    doy = (153 * mp + 2) \ 5 + d - 1
    doe = yoe * 365 + yoe \ 4 - yoe \ 100 + doy
    return era * 146097 + doe - 719468
end function

' { y, mo, d } of a day count since 1970-01-01.
function NxWxCivilFromDays(days as Integer) as Object
    z = days + 719468
    era = z \ 146097
    if z < 0 then era = (z - 146096) \ 146097
    doe = z - era * 146097
    yoe = (doe - doe \ 1460 + doe \ 36524 - doe \ 146096) \ 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe \ 4 - yoe \ 100)
    mp = (5 * doy + 2) \ 153
    d = doy - (153 * mp + 2) \ 5 + 1
    mo = mp + 3
    if mp >= 10 then mo = mp - 9
    if mo <= 2 then y = y + 1
    return { y: y, mo: mo, d: d }
end function

' Whole seconds since 1970 of "2026-11-15T15:24:06Z" (a fraction of a second, ".000", is read and
' dropped), or invalid.
function NxWxParseIso(text as Dynamic) as Dynamic
    s = NxToStr(text)
    if Len(s) < 19 then return invalid
    if Mid(s, 5, 1) <> "-" or Mid(s, 8, 1) <> "-" or (Mid(s, 11, 1) <> "T" and Mid(s, 11, 1) <> " ") or Mid(s, 14, 1) <> ":" or Mid(s, 17, 1) <> ":" then return invalid
    parts = [Mid(s, 1, 4), Mid(s, 6, 2), Mid(s, 9, 2), Mid(s, 12, 2), Mid(s, 15, 2), Mid(s, 18, 2)]
    nums = []
    for each p in parts
        for i = 1 to Len(p)
            c = Asc(Mid(p, i, 1))
            if c < 48 or c > 57 then return invalid
        end for
        nums.Push(p.ToInt())
    end for
    if nums[1] < 1 or nums[1] > 12 or nums[2] < 1 or nums[2] > 31 or nums[3] > 23 or nums[4] > 59 or nums[5] > 60 then return invalid
    return NxWxDaysFromCivil(nums[0], nums[1], nums[2]) * 86400 + nums[3] * 3600 + nums[4] * 60 + nums[5]
end function

function NxWxPad2(n as Integer) as String
    if n < 10 then return "0" + n.ToStr()
    return n.ToStr()
end function

' "2026-11-15T15:24:06.000Z", as JS's toISOString.
function NxWxIso(sec as Integer) as String
    days = sec \ 86400
    secOfDay = sec - days * 86400
    if secOfDay < 0 then
        days = days - 1
        secOfDay = secOfDay + 86400
    end if
    c = NxWxCivilFromDays(days)
    h = secOfDay \ 3600
    mi = (secOfDay - h * 3600) \ 60
    s = secOfDay - h * 3600 - mi * 60
    return c.y.ToStr() + "-" + NxWxPad2(c.mo) + "-" + NxWxPad2(c.d) + "T" + NxWxPad2(h) + ":" + NxWxPad2(mi) + ":" + NxWxPad2(s) + ".000Z"
end function

' The zone's offsets, parsed once per thread from WeatherZones.brs.
function NxWxZone(tz as String) as Dynamic
    g = GetGlobalAA()
    if g.nxWxZones = invalid then
        t = NxWxZoneTable()
        g.nxWxZones = { table: t, parsed: {} }
    end if
    z = g.nxWxZones.parsed[tz]
    if z <> invalid then return z
    raw = g.nxWxZones.table.zones[tz]
    if raw = invalid then return invalid
    halves = raw.Split(";")
    z = { first: halves[0].ToInt(), at: [], off: [] }
    if halves.Count() > 1 and halves[1] <> "" then
        for each pair in halves[1].Split(",")
            ab = pair.Split(":")
            z.at.Push(ab[0].ToInt())
            z.off.Push(ab[1].ToInt())
        end for
    end if
    g.nxWxZones.parsed[tz] = z
    return z
end function

function NxWxValidZone(tz as Dynamic) as Boolean
    if not NxIsString(tz) or tz = "" then return false
    return NxWxZone(tz) <> invalid
end function

' The last second the zone table knows (the table ends a few years out).
function NxWxZoneTableEnd() as Integer
    g = GetGlobalAA()
    if g.nxWxZones = invalid then g.nxWxZones = { table: NxWxZoneTable(), parsed: {} }
    return g.nxWxZones.table.toSec
end function

' The zone's UTC offset in minutes at a moment.
function NxWxOffsetMin(tz as String, sec as Integer) as Integer
    z = NxWxZone(tz)
    if z = invalid then return 0
    off = z.first
    for i = 0 to z.at.Count() - 1
        if sec >= z.at[i] then
            off = z.off[i]
        else
            exit for
        end if
    end for
    return off
end function

' The place's wall clock at a moment: { y, mo, d, h, mi, dow (0 is Sunday), key "2026-11-15" }.
function NxWxLocalParts(sec as Integer, tz as String) as Object
    local = sec + NxWxOffsetMin(tz, sec) * 60
    days = local \ 86400
    secOfDay = local - days * 86400
    if secOfDay < 0 then
        days = days - 1
        secOfDay = secOfDay + 86400
    end if
    c = NxWxCivilFromDays(days)
    h = secOfDay \ 3600
    mi = (secOfDay - h * 3600) \ 60
    dow = (days + 4) mod 7
    if dow < 0 then dow = dow + 7
    return { y: c.y, mo: c.mo, d: c.d, h: h, mi: mi, dow: dow, key: c.y.ToStr() + "-" + NxWxPad2(c.mo) + "-" + NxWxPad2(c.d) }
end function

' "4:00 PM", the way the guide prints times.
function NxWxFmtClock(sec as Integer, tz as String) as String
    p = NxWxLocalParts(sec, tz)
    h12 = p.h mod 12
    if h12 = 0 then h12 = 12
    ap = "AM"
    if p.h >= 12 then ap = "PM"
    return h12.ToStr() + ":" + NxWxPad2(p.mi) + " " + ap
end function

' ── The forecast document ────────────────────────────────────────────────────

function NxWxStepSymbol(st as Object) as Dynamic
    d = st.data
    if d = invalid then return invalid
    for each k in ["next_1_hours", "next_6_hours", "next_12_hours"]
        c = NxWxSummaryCode(d[k])
        if c <> "" then return c
    end for
    return invalid
end function

' The symbol for a period starting at a step: the 6 hour one first, then 12, then 1.
function NxWxPeriodSymbol(st as Object) as Dynamic
    d = st.data
    if d = invalid then return invalid
    for each k in ["next_6_hours", "next_12_hours", "next_1_hours"]
        c = NxWxSummaryCode(d[k])
        if c <> "" then return c
    end for
    return invalid
end function

function NxWxSummaryCode(block as Dynamic) as String
    if type(block) <> "roAssociativeArray" then return ""
    if type(block.summary) <> "roAssociativeArray" then return ""
    return NxToStr(block.summary.symbol_code)
end function

function NxWxDetails(block as Dynamic) as Object
    if type(block) = "roAssociativeArray" and type(block.details) = "roAssociativeArray" then return block.details
    return {}
end function

function NxWxStepPrecip(st as Object) as Double
    d = st.data
    a = NxWxDetails(d.next_1_hours).precipitation_amount
    if NxIsNumber(a) then return a
    b = NxWxDetails(d.next_6_hours).precipitation_amount
    if NxIsNumber(b) then return b
    return 0#
end function

function NxWxInst(st as Object) as Object
    if type(st.data) = "roAssociativeArray" and type(st.data.instant) = "roAssociativeArray" and type(st.data.instant.details) = "roAssociativeArray" then return st.data.instant.details
    return {}
end function

function NxWxRoundOrInvalid(v as Dynamic) as Dynamic
    if not NxIsNumber(v) then return invalid
    d# = v
    return NxWxRound(d#)
end function

' The channel's numbers from one MET `complete` document, trimmed or not (the golden's shape):
'   place  { name, cc, tz, lat, lon }
'   nowSec the clock
' Returns { updatedSec, tz, current, periods[4], days[1-5] } in metric (times in seconds), or invalid
' when the document holds nothing from now on (the JS throws EMPTY).
function NxWxBuildModel(met as Dynamic, place as Object, nowSec as Integer) as Dynamic
    tz = "UTC"
    if NxWxValidZone(place.tz) then tz = place.tz
    series = []
    if type(met) = "roAssociativeArray" and type(met.properties) = "roAssociativeArray" and type(met.properties.timeseries) = "roArray" then
        for each s in met.properties.timeseries
            t = NxWxParseIso(s.time)
            if t <> invalid and type(s.data) = "roAssociativeArray" and type(s.data.instant) = "roAssociativeArray" then series.Push({ t: t, data: s.data })
        end for
    end if
    ordered = true
    for i = 1 to series.Count() - 1
        if series[i].t < series[i - 1].t then ordered = false
    end for
    if not ordered then series.SortBy("t")
    if series.Count() = 0 then return invalid
    if series[series.Count() - 1].t < nowSec then return invalid
    ' The step the clock is in: the last one that has begun, else the first.
    cur = -1
    for i = 0 to series.Count() - 1
        if series[i].t <= nowSec then
            cur = i
        else
            exit for
        end if
    end for
    if cur < 0 then cur = 0
    meta = {}
    if type(met.properties.meta) = "roAssociativeArray" then meta = met.properties.meta

    ' CURRENT CONDITIONS: the step the clock is in.
    cs = series[cur]
    d = NxWxInst(cs)
    sym = NxWxStepSymbol(cs)
    nowLocal = NxWxLocalParts(nowSec, tz)
    info = NxWxSymbolInfo(sym)
    hasSuffix = false
    if sym <> invalid then
        for each sfx in ["_day", "_night", "_polartwilight"]
            if Len(sym) > Len(sfx) and Right(sym, Len(sfx)) = sfx then hasSuffix = true
        end for
    end if
    if hasSuffix then
        isDay = not info.night
    else
        isDay = nowLocal.h >= 6 and nowLocal.h < 18
    end if
    nh = NxWxDetails(cs.data.next_1_hours)
    feels = d.apparent_air_temperature
    if not NxIsNumber(feels) then feels = d.air_temperature
    uv = invalid
    if NxIsNumber(d.ultraviolet_index_clear_sky) and isDay then uv = NxWxRoundOrInvalid(d.ultraviolet_index_clear_sky)
    current = {
        timeSec: cs.t,
        tempC: NxWxR1(d.air_temperature),
        feelsC: NxWxR1(feels),
        humidity: NxWxRoundOrInvalid(d.relative_humidity),
        dewC: NxWxR1(d.dew_point_temperature),
        windMs: NxWxR1(d.wind_speed),
        windDir: NxWxRoundOrInvalid(d.wind_from_direction),
        pressureHpa: NxWxR1(d.air_pressure_at_sea_level),
        cloud: NxWxRoundOrInvalid(d.cloud_area_fraction),
        uv: uv,
        precipNextHourMm: NxWxR1(nh.precipitation_amount),
        symbol: sym,
        isDay: isDay
    }

    ' TODAY'S FORECAST: the next four six-hour periods on the place's wall clock, the first from now.
    groups = []
    i = cur
    while i < series.Count() and groups.Count() <= 4
        p = NxWxLocalParts(series[i].t, tz)
        block = p.h \ 6
        key = p.key + "|" + block.ToStr()
        last = invalid
        if groups.Count() > 0 then last = groups[groups.Count() - 1]
        if last <> invalid and last.key = key then
            last.steps.Push(series[i])
        else
            groups.Push({ key: key, date: p.key, block: block, steps: [series[i]] })
        end if
        i = i + 1
    end while
    names = ["OVERNIGHT", "MORNING", "AFTERNOON", "EVENING"]
    periods = []
    for gi = 0 to groups.Count() - 1
        if gi >= 4 then exit for
        g = groups[gi]
        middle = g.steps[(g.steps.Count() - 1) \ 2]
        md = NxWxInst(middle)
        winds = []
        for each s in g.steps
            w = NxWxInst(s).wind_speed
            if NxIsNumber(w) then winds.Push(w)
        end for
        first = g.steps[0]
        hourly = true
        for each s in g.steps
            if type(s.data.next_1_hours) <> "roAssociativeArray" then hourly = false
        end for
        precip# = 0#
        if hourly then
            for each s in g.steps
                precip# = precip# + NxWxStepPrecip(s)
            end for
        else
            precip# = NxWxStepPrecip(first)
        end if
        dayWord = "TOMORROW"
        if g.date = nowLocal.key then dayWord = "TODAY"
        windAvg = invalid
        if winds.Count() > 0 then
            sum# = 0#
            for each w in winds
                sum# = sum# + w
            end for
            windAvg = NxWxR1(sum# / winds.Count())
        end if
        periods.Push({
            name: names[g.block], day: dayWord, startSec: first.t,
            tempC: NxWxR1(md.air_temperature), symbol: NxWxPeriodSymbol(first), precipMm: NxWxR1(precip#),
            windMs: windAvg, windDir: NxWxRoundOrInvalid(md.wind_from_direction)
        })
    end for

    ' 5-DAY FORECAST: steps grouped by the place's local date.
    byDate = []
    index = {}
    for i = cur to series.Count() - 1
        p = NxWxLocalParts(series[i].t, tz)
        if index[p.key] = invalid then
            index[p.key] = byDate.Count()
            byDate.Push({ key: p.key, dow: p.dow, steps: [] })
        end if
        byDate[index[p.key]].steps.Push({ s: series[i], h: p.h })
    end for
    dates = []
    for each g in byDate
        if g.steps.Count() >= 2 then dates.Push(g)
    end for
    start = 0
    if dates.Count() > 0 then
        if dates[0].key = nowLocal.key and nowLocal.h >= 18 and dates.Count() > 5 then start = 1
    end if
    dows = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
    days = []
    for di = start to dates.Count() - 1
        if days.Count() >= 5 then exit for
        g = dates[di]
        hi = invalid
        lo = invalid
        windMax = invalid
        precip# = 0#
        pick = invalid
        for each e in g.steps
            s = e.s
            dd = NxWxInst(s)
            temps = []
            if NxIsNumber(dd.air_temperature) then temps.Push(dd.air_temperature)
            six = NxWxDetails(s.data.next_6_hours)
            if type(s.data.next_6_hours) = "roAssociativeArray" then
                if NxIsNumber(six.air_temperature_max) then temps.Push(six.air_temperature_max)
                if NxIsNumber(six.air_temperature_min) then temps.Push(six.air_temperature_min)
            end if
            for each tv in temps
                if hi = invalid or tv > hi then hi = tv
                if lo = invalid or tv < lo then lo = tv
            end for
            if NxIsNumber(dd.wind_speed) then
                if windMax = invalid or dd.wind_speed > windMax then windMax = dd.wind_speed
            end if
            if type(s.data.next_1_hours) = "roAssociativeArray" then
                precip# = precip# + NxWxStepPrecip(s)
            else if type(s.data.next_6_hours) = "roAssociativeArray" and NxIsNumber(six.precipitation_amount) then
                precip# = precip# + six.precipitation_amount
            end if
            if NxWxPeriodSymbol(s) <> invalid then
                if pick = invalid or Abs(e.h - 13) < Abs(pick.h - 13) then pick = e
            end if
        end for
        code = invalid
        if pick <> invalid then code = NxWxPeriodSymbol(pick.s)
        label = dows[g.dow]
        symbol = NxWxDayForm(code)
        if code = invalid then symbol = invalid
        if g.key = nowLocal.key then
            label = "TODAY"
            symbol = code
        end if
        days.Push({ date: g.key, label: label, highC: NxWxR1(hi), lowC: NxWxR1(lo), symbol: symbol, precipMm: NxWxR1(precip#), windMaxMs: NxWxR1(windMax) })
    end for

    return { updatedSec: NxWxParseIso(meta.updated_at), tz: tz, current: current, periods: periods, days: days }
end function

' ── Radar ────────────────────────────────────────────────────────────────────
' Region-limited on purpose: no open source covers the world and allows commercial use without a
' key. US on NOAA MRMS, Canada on Environment Canada GeoMet, Germany on DWD; anywhere else the
' channel says RADAR NOT AVAILABLE IN YOUR AREA.

function NxWxNoaaLayer(lat as Double, lon as Double) as String
    if lon >= 140 and lon <= 150 and lat >= 10 and lat <= 22 then return "guam"
    if lat >= 15 and lat <= 20 and lon >= -68 and lon <= -63 then return "carib"
    if lat >= 18 and lat <= 23 and lon >= -161 and lon <= -154 then return "hawaii"
    if lat > 51 and (lon <= -129 or lon >= 170) then return "alaska"
    return "conus"
end function

' The radar source for a place, or invalid: the card says RADAR NOT AVAILABLE IN YOUR AREA.
function NxWxRadarProvider(place as Dynamic) as Dynamic
    if type(place) <> "roAssociativeArray" then return invalid
    cc = UCase(NxToStr(place.cc))
    if cc = "US" then
        ws = NxWxNoaaLayer(place.lat, place.lon)
        return { id: "noaa", ws: ws, credit: "RADAR: NOAA NATIONAL WEATHER SERVICE", layers: [ws + "_bref_qcd"], stepMinutes: 10, frames: 8, lagMinutes: 0, ignoreBands: [] }
    else if cc = "CA" then
        return { id: "eccc", ws: "", credit: "DATA SOURCE: ENVIRONMENT AND CLIMATE CHANGE CANADA", layers: ["RADAR_1KM_RRAI", "RADAR_1KM_RSNO"], stepMinutes: 6, frames: 6, lagMinutes: 0, ignoreBands: [] }
    else if cc = "DE" then
        ' The newest observation is minutes behind, and the range runs into the nowcast, so frames
        ' stop lagMinutes short of the clock. The style draws the edge of the radar's coverage in
        ' magenta, our EXTREME colour, so that band is dropped.
        return { id: "dwd", ws: "", credit: "Datenbasis: Deutscher Wetterdienst, Rasterdaten bildlich wiedergegeben", layers: ["Niederschlagsradar"], stepMinutes: 10, frames: 8, lagMinutes: 10, ignoreBands: [4] }
    end if
    return invalid
end function

function NxWxRadarHost(provider as Object) as String
    if provider.id = "noaa" then return "https://opengeo.ncep.noaa.gov/geoserver"
    if provider.id = "eccc" then return "https://geo.weather.gc.ca/geomet"
    return "https://maps.dwd.de/geoserver/dwd"
end function

function NxWxCapabilitiesUrl(provider as Object, layer as String) as String
    host = NxWxRadarHost(provider)
    if provider.id = "noaa" then return host + "/" + provider.ws + "/" + layer + "/ows?service=WMS&version=1.3.0&request=GetCapabilities"
    if provider.id = "eccc" then return host + "?service=WMS&version=1.3.0&request=GetCapabilities&layer=" + layer
    return host + "/Niederschlagsradar/wms?service=WMS&version=1.3.0&request=GetCapabilities"
end function

function NxWxBBoxText(bbox as Object) as String
    return NxWxBBoxNum(bbox[0]) + "," + NxWxBBoxNum(bbox[1]) + "," + NxWxBBoxNum(bbox[2]) + "," + NxWxBBoxNum(bbox[3])
end function

function NxWxBBoxNum(v as Dynamic) as String
    d# = v
    s = NxWxFixed(d#, 3)
    ' JS prints the number as it is: 3 decimals at most, no trailing zeros.
    while Len(s) > 1 and Right(s, 1) = "0" and Instr(1, s, ".") > 0
        s = Left(s, Len(s) - 1)
    end while
    if Right(s, 1) = "." then s = Left(s, Len(s) - 1)
    return s
end function

' The GetMap address for one layer at one frame time ("2026-11-15T15:30:00.000Z" or "").
function NxWxMapUrl(provider as Object, layer as String, bbox as Object, w as Integer, h as Integer, time as String) as String
    host = NxWxRadarHost(provider)
    tail = "&styles=&crs=CRS:84&bbox=" + NxWxBBoxText(bbox) + "&width=" + w.ToStr() + "&height=" + h.ToStr() + "&format=image/png&transparent=true"
    ' Whole seconds ("...00Z"): Environment Canada rejects milliseconds.
    if time <> "" then tail = tail + "&time=" + time.Replace(".000Z", "Z").Replace(":", "%3A")
    if provider.id = "dwd" then return host + "/wms?service=WMS&version=1.3.0&request=GetMap&layers=dwd:" + layer + tail
    if provider.id = "noaa" then return host + "/" + provider.ws + "/" + layer + "/ows?service=WMS&version=1.3.0&request=GetMap&layers=" + layer + tail
    return host + "?service=WMS&version=1.3.0&request=GetMap&layers=" + layer + tail
end function

' The map window: span degrees tall, centred on the place, as wide as the picture needs so that a
' degree of longitude is drawn cos(latitude) as wide as a degree of latitude. [minLon, minLat,
' maxLon, maxLat], CRS:84 order, to 3 decimals.
function NxWxRadarBBox(lat as Double, lon as Double, aspect as Double, span as Double) as Object
    c# = Cos(lat * 3.14159265358979# / 180#)
    if c# < 0.2# then c# = 0.2#
    spanLon# = span * aspect / c#
    return [NxWxR3(lon - spanLon# / 2#), NxWxR3(lat - span / 2#), NxWxR3(lon + spanLon# / 2#), NxWxR3(lat + span / 2#)]
end function

function NxWxR3(v as Double) as Double
    n# = v * 1000#
    return Int(n# + 0.5#) / 1000#
end function

' The times inside a WMS time dimension: "a,b,c" or "start/end/PT6M", as ISO strings, newest last.
function NxWxParseTimeDimension(xml as Dynamic) as Object
    out = []
    s = NxToStr(xml)
    searchFrom = 1
    text = invalid
    while true
        a = Instr(searchFrom, s, "<Dimension")
        if a = 0 then exit while
        b = Instr(a, s, ">")
        if b = 0 then exit while
        tag = Mid(s, a, b - a)
        if Instr(1, tag, "name=" + Chr(34) + "time" + Chr(34)) > 0 then
            e = Instr(b, s, "<")
            if e = 0 then exit while
            text = NxWxStrTrim(Mid(s, b + 1, e - b - 1))
            exit while
        end if
        searchFrom = b
    end while
    if text = invalid or text = "" then return out
    if Instr(1, text, "/") > 0 and Instr(1, text, ",") = 0 then
        pieces = text.Split("/")
        start = NxWxParseIso(pieces[0])
        finish = invalid
        if pieces.Count() > 1 then finish = NxWxParseIso(pieces[1])
        stepSec = 0
        if pieces.Count() > 2 then stepSec = NxWxDurationSec(pieces[2])
        if start = invalid or finish = invalid or stepSec <= 0 then
            if finish <> invalid then out.Push(NxWxIso(finish))
            return out
        end if
        t = start
        while t <= finish
            out.Push(NxWxIso(t))
            t = t + stepSec
        end while
        return out
    end if
    for each piece in text.Split(",")
        t = NxWxParseIso(NxWxStrTrim(piece))
        if t <> invalid then out.Push(NxWxIso(t))
    end for
    return out
end function

function NxWxStrTrim(s as String) as String
    return s.Trim()
end function

' "PT6M", "PT1H" and "PT1H30M" in seconds, or 0.
function NxWxDurationSec(text as String) as Integer
    if Left(text, 2) <> "PT" then return 0
    total = 0
    num = ""
    for i = 3 to Len(text)
        c = Mid(text, i, 1)
        if c = "H" then
            total = total + num.ToInt() * 3600
            num = ""
        else if c = "M" then
            total = total + num.ToInt() * 60
            num = ""
        else if c = "S" then
            total = total + num.ToInt()
            num = ""
        else if Asc(c) >= 48 and Asc(c) <= 57 then
            num = num + c
        else
            return 0
        end if
    end for
    return total
end function

' count frames ending at the newest time, about stepMinutes apart, oldest first. Times after
' notAfterSec (when it is a number) are not used.
function NxWxPickFrameTimes(allTimes as Object, count as Integer, stepMinutes as Integer, notAfterSec as Dynamic) as Object
    times = []
    secs = []
    for each t in allTimes
        sec = NxWxParseIso(t)
        if sec <> invalid then
            if not NxIsNumber(notAfterSec) or sec <= notAfterSec then
                times.Push(t)
                secs.Push(sec)
            end if
        end if
    end for
    if times.Count() = 0 then return []
    out = [times[times.Count() - 1]]
    want = secs[secs.Count() - 1]
    for n = 1 to count - 1
        want = want - stepMinutes * 60
        best = -1
        for i = 0 to secs.Count() - 1
            if best < 0 or Abs(secs[i] - want) < Abs(secs[best] - want) then best = i
        end for
        if best >= 0 and times[best] <> out[0] and Abs(secs[best] - want) <= stepMinutes * 30 then out.Unshift(times[best])
    end for
    return out
end function

' One radar pixel, from the source's colours to our five bands: 0 (light) to 4 (extreme), or -1
' for a pixel that is not an echo (white, grey, black and near-white).
function NxWxRadarBand(r as Integer, g as Integer, b as Integer) as Integer
    mx = r
    if g > mx then mx = g
    if b > mx then mx = b
    mn = r
    if g < mn then mn = g
    if b < mn then mn = b
    if mx - mn < 28 then return -1
    d = mx - mn
    if mx = r then
        h! = (g - b) / d
        h! = h! - 6 * Fix(h! / 6)
    else if mx = g then
        h! = (b - r) / d + 2
    else
        h! = (r - g) / d + 4
    end if
    h! = h! * 60 + 360
    if h! >= 360 then h! = h! - 360
    if h! >= 190 and h! < 280 then return 0
    if h! >= 90 and h! < 190 then return 1
    if h! >= 40 and h! < 90 then return 2
    if h! >= 12 and h! < 40 then return 3
    if h! >= 280 and h! < 345 then return 4
    return 3
end function

' The five bands' colours as 0xRRGGBBAA, and their names (the web's RADAR_BANDS).
function NxWxRadarBands() as Object
    return [
        { name: "LIGHT", color: "#00D4FF", rgb: [0, 212, 255] },
        { name: "MODERATE", color: "#FFE500", rgb: [255, 229, 0] },
        { name: "HEAVY", color: "#FFB020", rgb: [255, 176, 32] },
        { name: "SEVERE", color: "#FF2244", rgb: [255, 34, 68] },
        { name: "EXTREME", color: "#FF2DB4", rgb: [255, 45, 180] }
    ]
end function

' ── Places ───────────────────────────────────────────────────────────────────

' The web's plain(): NFKD, marks dropped, lower case, then only a-z and 0-9. A letter NFKD does not
' take apart (the stroked o, the sharp s) is dropped, as it is there.
function NxWxPlain(text as Dynamic) as String
    s = NxToStr(text)
    out = ""
    table = NxWxAccents().plainOf
    for i = 1 to Len(s)
        ch = Mid(s, i, 1)
        a = Asc(ch)
        if a >= 97 and a <= 122 then
            out = out + ch
        else if a >= 65 and a <= 90 then
            out = out + Chr(a + 32)
        else if a >= 48 and a <= 57 then
            out = out + ch
        else if a > 127 then
            base = table[ch]
            if base <> invalid then out = out + base
        end if
    end for
    return out
end function

' The Latin letters with a mark, as [plain letter, lower case marked letters, upper case marked letters]
' with the two lists in step, so the nth lower case letter has the nth upper case one.
function NxWxAccentSets() as Object
    return [
        ["a", "àáâãäåāăąǎ", "ÀÁÂÃÄÅĀĂĄǍ"], ["c", "çćĉċč", "ÇĆĈĊČ"], ["d", "ď", "Ď"], ["e", "èéêëēĕėęěȩ", "ÈÉÊËĒĔĖĘĚȨ"],
        ["g", "ĝğġģ", "ĜĞĠĢ"], ["h", "ĥ", "Ĥ"], ["i", "ìíîïĩīĭįǐ", "ÌÍÎÏĨĪĬĮǏ"], ["j", "ĵ", "Ĵ"], ["k", "ķ", "Ķ"],
        ["l", "ĺļľ", "ĹĻĽ"], ["n", "ñńņňǹ", "ÑŃŅŇǸ"], ["o", "òóôõöōŏőǒ", "ÒÓÔÕÖŌŎŐǑ"], ["r", "ŕŗř", "ŔŖŘ"],
        ["s", "śŝşšș", "ŚŜŞŠȘ"], ["t", "ţťț", "ŢŤȚ"], ["u", "ùúûüũūŭůűųǔ", "ÙÚÛÜŨŪŬŮŰŲǓ"], ["w", "ŵ", "Ŵ"],
        ["y", "ýÿŷ", "ÝŸŶ"], ["z", "źżž", "ŹŻŽ"]
    ]
end function

' A marked letter, lower or upper case, to its plain letter; and a lower case one to its capital.
function NxWxAccents() as Object
    g = GetGlobalAA()
    if g.nxWxAccents <> invalid then return g.nxWxAccents
    plainOf = {}
    upperOf = {}
    for each set in NxWxAccentSets()
        for i = 1 to Len(set[1])
            plainOf[Mid(set[1], i, 1)] = set[0]
            plainOf[Mid(set[2], i, 1)] = set[0]
            upperOf[Mid(set[1], i, 1)] = Mid(set[2], i, 1)
        end for
    end for
    g.nxWxAccents = { plainOf: plainOf, upperOf: upperOf }
    return g.nxWxAccents
end function

function NxWxStartsWith(text as String, prefix as String) as Boolean
    return Left(text, Len(prefix)) = prefix
end function

' Upper case for the screen: UCase leaves a marked letter alone, so its capital is looked up.
function NxWxUpper(text as Dynamic) as String
    s = NxToStr(text)
    table = NxWxAccents().upperOf
    out = ""
    for i = 1 to Len(s)
        ch = Mid(s, i, 1)
        if Asc(ch) > 127 then
            cap = table[ch]
            if cap <> invalid then ch = cap
        else
            ch = UCase(ch)
        end if
        out = out + ch
    end for
    return out
end function

' [name, region, cc] joined with ", " and upper case.
function NxWxPlaceLabel(place as Object) as String
    parts = []
    if NxToStr(place.name) <> "" then parts.Push(NxToStr(place.name))
    if NxToStr(place.region) <> "" then parts.Push(NxToStr(place.region))
    if NxToStr(place.cc) <> "" then parts.Push(NxToStr(place.cc))
    return NxWxUpper(parts.Join(", "))
end function

' The key a postcode is looked up by, in each country's shard set, or "" when the text cannot be
' one of its codes.
function NxWxPostcodeLookup(cc as String, text as String) as String
    t = ""
    for i = 1 to Len(text)
        c = UCase(Mid(text, i, 1))
        a = Asc(c)
        if (a >= 65 and a <= 90) or (a >= 48 and a <= 57) or a = 32 then t = t + c
    end for
    t = t.Trim()
    squashed = t.Replace(" ", "")
    if cc = "US" or cc = "DE" then
        if NxWxAllDigits(squashed) and Len(squashed) >= 3 and Len(squashed) <= 5 then return squashed
        return ""
    else if cc = "AU" then
        if NxWxAllDigits(squashed) and Len(squashed) >= 3 and Len(squashed) <= 4 then return squashed
        return ""
    else if cc = "CA" then
        if Len(squashed) >= 3 and NxWxIsLetter(Left(squashed, 1)) and NxWxIsDigit(Mid(squashed, 2, 1)) and NxWxIsLetter(Mid(squashed, 3, 1)) then return Left(squashed, 3)
        return ""
    else if cc = "GB" then
        ' One or two letters, then a digit.
        n = 0
        while n < Len(squashed) and n < 2 and NxWxIsLetter(Mid(squashed, n + 1, 1))
            n = n + 1
        end while
        if n < 1 or n > 2 or Len(squashed) <= n or not NxWxIsDigit(Mid(squashed, n + 1, 1)) then return ""
        ' A full postcode ends in digit-letter-letter: the outward part is what is before it.
        if Len(squashed) >= 5 and Len(squashed) <= 7 then
            tail = Right(squashed, 3)
            if NxWxIsDigit(Left(tail, 1)) and NxWxIsLetter(Mid(tail, 2, 1)) and NxWxIsLetter(Mid(tail, 3, 1)) then
                outward = Left(squashed, Len(squashed) - 3)
                if Len(outward) >= n + 1 and Len(outward) <= n + 2 then return outward
            end if
        end if
        if Instr(1, t, " ") > 0 then return t.Split(" ")[0]
        return squashed
    end if
    return ""
end function

function NxWxAllDigits(s as String) as Boolean
    if s = "" then return false
    for i = 1 to Len(s)
        if not NxWxIsDigit(Mid(s, i, 1)) then return false
    end for
    return true
end function

function NxWxIsDigit(c as String) as Boolean
    a = Asc(c)
    return a >= 48 and a <= 57
end function

function NxWxIsLetter(c as String) as Boolean
    a = Asc(c)
    return a >= 65 and a <= 90
end function

' A place from one shard row. City rows are [name, cc, region, lat, lon, tzIndex]; postcode rows are
' [code, name, region, lat, lon, tzIndex].
function NxWxRowToPlace(row as Object, meta as Object, kind as String) as Object
    tzi = row[5]
    tz = "UTC"
    if NxIsNumber(tzi) and type(meta.tz) = "roArray" and tzi >= 0 and tzi < meta.tz.Count() then tz = meta.tz[tzi]
    if kind = "city" then return { name: row[0], cc: row[1], region: row[2], lat: row[3], lon: row[4], tz: tz, kind: "city" }
    ' GeoNames names some codes with their landmarks in brackets ("DOWNTOWN TORONTO (CN TOWER / ...)"): keep the name.
    nm = NxToStr(row[1])
    br = Instr(1, nm, "(")
    if br > 0 then nm = Left(nm, br - 1)
    nm = nm.Trim()
    if nm = "" then nm = NxToStr(row[1])
    return { name: nm, cc: "", region: row[2], lat: row[3], lon: row[4], tz: tz, kind: "postcode", code: NxToStr(row[0]) }
end function

' A place finder over the static place files. load(path) returns the parsed JSON of a path under
' /weather/ ("places/meta.json") or invalid. Returns { places: [up to 8, most people first], hint }.
function NxWxSearch(query as String, load as Function) as Object
    q = query.Trim()
    meta = load("places/meta.json")
    if type(meta) <> "roAssociativeArray" or q = "" then
        hint = ""
        if q <> "" then hint = "PLACE LIST NOT AVAILABLE"
        return { places: [], hint: hint }
    end if
    out = []
    seen = {}

    ' A postcode: digits, or a letter-digit pattern, looked up in every country it could belong to.
    ' A whole code (2000 is Sydney) comes before the longer codes that only begin with it.
    zips = []
    for each cc in NxList(meta.postcodes)
        code = NxWxPostcodeLookup(cc, q)
        if code <> "" then
            rows = load("places/z/" + cc + "/" + Left(code, 2) + ".json")
            if type(rows) = "roArray" then
                for each row in rows
                    if NxWxStartsWith(NxToStr(row[0]), code) then
                        p = NxWxRowToPlace(row, meta, "postcode")
                        p.cc = cc
                        whole = 1
                        if NxToStr(row[0]) = code then whole = 0
                        zips.Push({ place: p, whole: whole })
                    end if
                end for
            end if
        end if
    end for
    for w = 0 to 1
        for each z in zips
            if z.whole = w then NxWxPushPlace(out, seen, z.place)
        end for
    end for

    ' A city: "toronto", or "springfield il" / "portland, or" with the state, province or country after it.
    attempts = []
    comma = Instr(1, q, ",")
    if comma > 1 then attempts.Push([Left(q, comma - 1), Mid(q, comma + 1).Trim()])
    attempts.Push([q, ""])
    words = q.Split(" ")
    if words.Count() > 1 then
        last = words[words.Count() - 1]
        head = words.Join(" ")
        head = Left(head, Len(head) - Len(last)).Trim()
        attempts.Push([head, last])
    end if
    hint = ""
    splitKeys = NxList(meta.split)
    for each at in attempts
        key = NxWxPlain(at[0])
        if Len(key) >= 2 then
            shard = Left(key, 2)
            skip = false
            if NxHasValue(splitKeys, shard) then
                if Len(key) < 3 then
                    hint = "KEEP TYPING"
                    skip = true
                else
                    shard = Left(key, 3)
                end if
            end if
            if not skip then
                rows = load("places/c/" + shard + ".json")
                if type(rows) = "roArray" then
                    qualN = NxWxPlain(at[1])
                    for each row in rows
                        if NxWxStartsWith(NxWxPlain(row[0]), key) then
                            ok = true
                            if qualN <> "" then ok = NxWxStartsWith(NxWxPlain(row[2]), qualN) or NxWxPlain(row[1]) = qualN
                            if ok then NxWxPushPlace(out, seen, NxWxRowToPlace(row, meta, "city"))
                        end if
                    end for
                end if
                found = false
                for each p in out
                    if p.kind = "city" then found = true
                end for
                if found then exit for
            end if
        end if
    end for
    if out.Count() > 0 then hint = ""
    return { places: out, hint: hint }
end function

sub NxWxPushPlace(out as Object, seen as Object, p as Object)
    if out.Count() >= 8 then return
    code = ""
    if p.code <> invalid then code = p.code
    key = p.kind + "|" + NxToStr(p.name) + "|" + NxToStr(p.region) + "|" + NxToStr(p.cc) + "|" + code
    if seen[key] <> invalid then return
    seen[key] = true
    if p.kind = "postcode" then
        p.label = NxWxUpper(p.code + " " + NxToStr(p.name) + ", " + NxWxJoinNonEmpty([NxToStr(p.region), NxToStr(p.cc)]))
    else
        p.label = NxWxPlaceLabel(p)
    end if
    out.Push(p)
end sub

function NxWxJoinNonEmpty(list as Object) as String
    keep = []
    for each s in list
        if s <> "" then keep.Push(s)
    end for
    return keep.Join(", ")
end function

' A place read back from storage, or invalid if it is not usable. Coordinates are kept at 2 decimals.
function NxWxNormalizePlace(p as Dynamic) as Dynamic
    if type(p) <> "roAssociativeArray" then return invalid
    if not NxIsNumber(p.lat) or not NxIsNumber(p.lon) then return invalid
    lat# = p.lat
    lon# = p.lon
    if Abs(lat#) > 90 or Abs(lon#) > 180 then return invalid
    if not NxIsString(p.name) or p.name = "" then return invalid
    out = {
        name: Left(p.name, 80), region: "", cc: "",
        lat: Int(lat# * 100# + 0.5#) / 100#, lon: Int(lon# * 100# + 0.5#) / 100#, tz: "UTC", kind: "city"
    }
    if NxIsString(p.region) then out.region = Left(p.region, 60)
    if NxIsString(p.cc) then out.cc = Left(UCase(p.cc), 2)
    if NxWxValidZone(p.tz) then out.tz = p.tz
    if p.kind = "postcode" then out.kind = "postcode"
    if NxIsString(p.code) then out.code = Left(p.code, 8)
    return out
end function

' ── The relay ────────────────────────────────────────────────────────────────

' The relay call for a place. Coordinates leave the TV rounded to 2 decimals, about 1 km.
function NxWxForecastUrl(base as String, place as Object) as String
    lat# = place.lat
    lon# = place.lon
    return base + "?lat=" + NxWxFixed(lat#, 2) + "&lon=" + NxWxFixed(lon#, 2)
end function

' Whether to ask again: never before the document's own Expires, and not more than every minSec
' after the last answer.
function NxWxForecastDue(entry as Dynamic, nowSec as Integer, minSec as Integer) as Boolean
    if type(entry) <> "roAssociativeArray" or not NxTruthy(entry.body) then return true
    if NxIsNumber(entry.expiresSec) and nowSec < entry.expiresSec then return false
    return nowSec - NxNumberOr0(entry.savedSec) >= minSec
end function

' How old the forecast is, for the card: "UPDATED 2:18 PM", stale when it is over 6 hours old.
function NxWxForecastAge(updatedSec as Dynamic, nowSec as Integer, tz as String) as Object
    if not NxIsNumber(updatedSec) then return { text: "", stale: false }
    return { text: "UPDATED " + NxWxFmtClock(updatedSec, tz), stale: nowSec - updatedSec > 6 * 3600 }
end function

' Only what the channel reads, so the copy kept on the TV is a third of the size.
function NxWxTrim(met as Dynamic) as Dynamic
    if type(met) <> "roAssociativeArray" or type(met.properties) <> "roAssociativeArray" or type(met.properties.timeseries) <> "roArray" then return invalid
    keep = ["air_pressure_at_sea_level", "air_temperature", "apparent_air_temperature", "cloud_area_fraction", "dew_point_temperature", "relative_humidity", "ultraviolet_index_clear_sky", "wind_from_direction", "wind_speed"]
    ts = []
    for each s in met.properties.timeseries
        if type(s.data) = "roAssociativeArray" and type(s.data.instant) = "roAssociativeArray" and type(s.data.instant.details) = "roAssociativeArray" then
            details = {}
            for each k in keep
                if s.data.instant.details[k] <> invalid then details[k] = s.data.instant.details[k]
            end for
            data = { instant: { details: details } }
            for each k in ["next_1_hours", "next_6_hours", "next_12_hours"]
                if s.data[k] <> invalid then data[k] = s.data[k]
            end for
            ts.Push({ time: s.time, data: data })
        end if
    end for
    updated = ""
    if type(met.properties.meta) = "roAssociativeArray" then updated = NxToStr(met.properties.meta.updated_at)
    return { properties: { meta: { updated_at: updated }, timeseries: ts } }
end function

' ── The guide row and the info panel ─────────────────────────────────────────

' The channel's row in the guide: one block that never starts or ends (an unlimited loop, so no
' programme times), in the shape NxGuideBlock gives the guide's other airings. The row reads
' "LOCAL WEATHER" and the current temperature when there is one ("LOCAL WEATHER  46" + degrees + "F").
function NxWxGuideBlocks(placeName as String, summary as String, tempLabel as String) as Object
    line = "LOCAL WEATHER"
    if tempLabel <> "" then line = line + "  " + tempLabel
    text = summary
    if text = "" then text = "Current conditions, today" + Chr(8217) + "s forecast, the 5-day forecast and radar, in a loop."
    return [{
        startSec: 0, endSec: 2147483000, weather: true,
        ratingKey: "", line: line, title: "LOCAL WEATHER", episodeTitle: placeName,
        seasonNumber: invalid, episodeNumber: invalid, summary: text, year: "", partKey: invalid,
        container: invalid, videoCodec: invalid, audioCodec: invalid, videoProfile: invalid, audioChannels: invalid,
        bitrate: invalid, audioTracks: invalid, forcedSubs: invalid, fullSubs: invalid, duration: 60, exactDurationSeconds: 3600,
        videoWidth: invalid, videoHeight: invalid, serverIndex: 0, contentRating: "", rating: 0, type: ""
    }]
end function

' The current temperature for the row: "46" + degrees + "F", or "" with no forecast.
function NxWxTempLabel(model as Dynamic, units as String) as String
    if type(model) <> "roAssociativeArray" then return ""
    if model.current.tempC = invalid then return ""
    return NxWxFmtTemp(model.current.tempC, units) + Chr(176) + units
end function

' The line the info panel shows under the place: "Cloudy, 6C. Feels like 3. High 7, low 5. Wind NNW 17 km/h."
function NxWxInfoSummary(model as Dynamic, units as String) as String
    if type(model) <> "roAssociativeArray" then return ""
    c = model.current
    deg = Chr(176)
    cond = NxWxSymbolInfo(c.symbol).text
    cond = Left(cond, 1) + LCase(Mid(cond, 2))
    parts = [cond + ", " + NxWxFmtTemp(c.tempC, units) + deg + units + ".", "Feels like " + NxWxFmtTemp(c.feelsC, units) + deg + "."]
    if model.days.Count() > 0 then
        first = model.days[0]
        if first.highC <> invalid then parts.Push("High " + NxWxFmtTemp(first.highC, units) + deg + ", low " + NxWxFmtTemp(first.lowC, units) + deg + ".")
    end if
    if c.windMs <> invalid then
        wind = LCase(NxWxFmtWind(c.windMs, units))
        dir = NxWxCompass(c.windDir)
        if dir <> "" then parts.Push("Wind " + dir + " " + wind + ".") else parts.Push("Wind " + wind + ".")
    end if
    return parts.Join(" ")
end function

' The place as the header and the guide row say it: "TORONTO, ON" for the US, Canada and Australia,
' "BERLIN, DE" elsewhere.
function NxWxPlaceTitle(place as Object) as String
    base = NxWxUpper(place.name)
    cc = UCase(NxToStr(place.cc))
    if NxToStr(place.region) <> "" and (cc = "US" or cc = "CA" or cc = "AU") then return base + ", " + NxWxUpper(place.region)
    if cc <> "" then return base + ", " + cc
    return base
end function

' Where LOCAL WEATHER sits in the guide's list: where its number puts it, before the first channel numbered 300 or
' more (the FRANCHISES block, then the collections and HIGH ROTATION), after the regular bundles; the end of the
' list when none is that high. `channels` are the guide's channels ({ number }) in their order.
function NxWxInsertIndex(channels as Object) as Integer
    at = NxWxChannel().number
    for i = 0 to channels.Count() - 1
        if NxIsNumber(channels[i].number) then
            if channels[i].number >= 300 then return i
        end if
    end for
    return channels.Count()
end function

' The index of the weather channel in the guide's list, or -1.
function NxWxChannelIndex(channels as Object) as Integer
    for i = 0 to channels.Count() - 1
        if channels[i].weather = true then return i
    end for
    return -1
end function
