' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Holds the weather channel (source/weather/Weather.brs) to scripts/weather-golden.json, copied
' unchanged to tests/vectors/: the web tuner's scripts/nostalgex-weather.js wrote it, and the Apple
' TV and Android ports hold to the same file.
'
'   loop, units, format, compass, symbols    the small rules
'   bands, frames, bbox, providers           radar: colours to bands, frame picking, the map window, the sources
'   postcode                                 which key a typed code is looked up by
'   cases                                    one forecast document and the model it gives at five moments
'
' Then what the golden does not hold: the time zone table against moments Intl gave, the place
' search on stand-in shard files (the accent rule, the shard split, a postcode before a city), the
' relay rules and what is stored. Returns the failure count.

function NxRunWeatherTests(goldenPath as String) as Integer
    r = { pass: 0, fail: 0 }
    g = ParseJson(ReadAsciiFile(goldenPath))
    if g = invalid then
        print "FAIL cannot read "; goldenPath
        return 1
    end if

    NxCheck(r, "loop: seconds", NxWxLoopSeconds().ToStr(), NxToStr(g.loop.seconds))
    screens = NxWxScreens()
    NxCheck(r, "loop: screens", screens.Count().ToStr(), g.loop.screens.Count().ToStr())
    for i = 0 to g.loop.screens.Count() - 1
        NxCheck(r, "loop: screen " + i.ToStr(), screens[i].id + "|" + screens[i].title + "|" + screens[i].seconds.ToStr(), g.loop.screens[i].id + "|" + g.loop.screens[i].title + "|" + NxToStr(g.loop.screens[i].seconds))
    end for
    for each c in g.loop.at
        at = NxWxScreenAt(c.s)
        NxCheck(r, "loop at " + NxToStr(c.s), at.id, c.id)
        NxWxNearCheck(r, "loop at " + NxToStr(c.s) + " elapsed", at.elapsed, c.elapsed, 0.001)
    end for

    for each c in g.units
        NxCheck(r, "units " + c.cc + " " + c.setting, NxWxUnitsFor({ cc: c.cc }, c.setting), c.units)
    end for

    ' Each golden row has a key "c" (the temperature) and a key "C" (the answers in Celsius), and a
    ' BrightScript associative array holds one key for both, so the temperatures are written here, in
    ' the golden's order, and the rest are read from it.
    celsius = [0, -0.4, 21.5, -17.8]
    NxCheck(r, "format: the golden's rows", g.format.Count().ToStr(), celsius.Count().ToStr())
    for i = 0 to g.format.Count() - 1
        c = g.format[i]
        for each u in ["F", "C"]
            want = c[u]
            NxCheck(r, "format temp " + u + " " + NxToStr(celsius[i]), NxWxFmtTemp(celsius[i], u), want.temp)
            NxCheck(r, "format wind " + u + " " + NxToStr(c.ms), NxWxFmtWind(c.ms, u), want.wind)
            NxCheck(r, "format pressure " + u + " " + NxToStr(c.hpa), NxWxFmtPressure(c.hpa, u), want.pressure)
            NxCheck(r, "format precip " + u + " " + NxToStr(c.mm), NxWxFmtPrecip(c.mm, u), want.precip)
        end for
    end for
    NxCheck(r, "format: no number", NxWxFmtTemp(invalid, "C") + NxWxFmtWind(invalid, "C") + NxWxFmtPressure(invalid, "C") + NxWxFmtPrecip(invalid, "C"), "--------")

    for each c in g.compass
        NxCheck(r, "compass " + NxToStr(c.deg), NxWxCompass(c.deg), c.dir)
    end for

    for each c in g.symbols
        info = NxWxSymbolInfo(c.code)
        NxCheck(r, "symbol " + c.code, info.icon + "|" + info.text + "|" + NxToStr(info.night), c.icon + "|" + c.text + "|" + NxToStr(c.night))
        NxCheck(r, "symbol day form " + c.code, NxWxDayForm(c.code), c.day)
    end for

    for each c in g.bands
        NxCheck(r, "band " + NxWxJoinNums(c.rgb), NxWxRadarBand(c.rgb[0], c.rgb[1], c.rgb[2]).ToStr(), c.band.ToStr())
    end for

    NxCheck(r, "frames: pick", NxWxPickFrameTimes(g.frames.times, 4, 10, invalid).Join(","), g.frames.pick.Join(","))
    cutoff = NxWxParseIso("2026-11-15T15:35:00Z")
    NxCheck(r, "frames: pick not after", NxWxPickFrameTimes(g.frames.times, 3, 10, cutoff).Join(","), g.frames.pickNotAfter.Join(","))
    range = "<Dimension name=" + Chr(34) + "time" + Chr(34) + " units=" + Chr(34) + "ISO8601" + Chr(34) + " default=" + Chr(34) + "2026-11-15T17:24:00Z" + Chr(34) + " nearestValue=" + Chr(34) + "0" + Chr(34) + ">2026-11-15T16:48:00Z/2026-11-15T17:24:00Z/PT6M</Dimension>"
    NxCheck(r, "frames: range", NxWxParseTimeDimension(range).Join(","), g.frames.range.Join(","))
    listed = "<Dimension name=" + Chr(34) + "time" + Chr(34) + " default=" + Chr(34) + "x" + Chr(34) + " units=" + Chr(34) + "ISO8601" + Chr(34) + " nearestValue=" + Chr(34) + "1" + Chr(34) + ">2026-11-15T15:24:06.000Z,2026-11-15T15:25:58.000Z</Dimension>"
    NxCheck(r, "frames: list", NxWxParseTimeDimension(listed).Join(","), g.frames.list.Join(","))
    ' The layer's own XML can have other tags before the time dimension.
    wrapped = "<Capability><Layer><Name>x</Name><Dimension name=" + Chr(34) + "elevation" + Chr(34) + ">0</Dimension>" + range + "</Layer></Capability>"
    NxCheck(r, "frames: range after another dimension", NxWxParseTimeDimension(wrapped).Join(","), g.frames.range.Join(","))
    NxCheck(r, "frames: none", NxWxParseTimeDimension("<Capability/>").Count().ToStr(), "0")

    for each c in g.bbox
        got = NxWxRadarBBox(c.lat, c.lon, c.aspect, c.span)
        for i = 0 to 3
            NxWxNearCheck(r, "bbox " + NxToStr(c.lat) + " " + i.ToStr(), got[i], c.bbox[i], 0.002)
        end for
    end for

    for each c in g.providers
        p = NxWxRadarProvider({ cc: c.cc, lat: c.lat, lon: c.lon })
        label = "provider " + c.cc + " " + NxToStr(c.lat)
        if c.provider = invalid then
            NxCheck(r, label + ": none", NxToStr(p <> invalid), "false")
        else if p = invalid then
            NxCheck(r, label + ": missing", "invalid", c.provider)
        else
            NxCheck(r, label, p.id + "|" + p.layers.Join(",") + "|" + p.credit + "|" + p.frames.ToStr() + "|" + p.stepMinutes.ToStr() + "|" + p.lagMinutes.ToStr() + "|" + NxWxJoinNums(p.ignoreBands), c.provider + "|" + c.layers.Join(",") + "|" + c.credit + "|" + NxToStr(c.frames) + "|" + NxToStr(c.stepMinutes) + "|" + NxToStr(c.lagMinutes) + "|" + NxWxJoinNums(c.ignoreBands))
        end if
    end for
    NxWxRadarUrlChecks(r)

    for each c in g.postcode
        NxCheck(r, "postcode " + c.cc + " " + c.text, NxWxPostcodeLookup(c.cc, c.text), NxToStr(c.key))
    end for

    ' The golden's times are milliseconds, past what an Integer holds, so they are read as the digits
    ' they are written with: per case the model's updatedMs, then current.timeMs, then four startMs.
    raw = ReadAsciiFile(goldenPath)
    updatedMs = NxWxRawNumbers(raw, "updatedMs")
    timeMs = NxWxRawNumbers(raw, "timeMs")
    startMs = NxWxRawNumbers(raw, "startMs")
    NxCheck(r, "golden: a time per case", updatedMs.Count().ToStr() + " " + timeMs.Count().ToStr() + " " + startMs.Count().ToStr(), g.cases.Count().ToStr() + " " + g.cases.Count().ToStr() + " " + (g.cases.Count() * 4).ToStr())
    for i = 0 to g.cases.Count() - 1
        times = { updated: updatedMs[i], current: timeMs[i], starts: [startMs[i * 4], startMs[i * 4 + 1], startMs[i * 4 + 2], startMs[i * 4 + 3]] }
        NxWxCaseChecks(r, g, g.cases[i], times)
    end for
    NxCheck(r, "model: a document that ends before now is empty", NxToStr(NxWxBuildModel(g.met, g.cases[0].place, NxWxParseIso("2026-12-30T00:00:00Z"))), "")
    NxCheck(r, "model: no document", NxToStr(NxWxBuildModel(invalid, g.cases[0].place, NxWxParseIso("2026-11-15T18:20:00Z"))), "")

    NxWxZoneChecks(r)
    NxWxTimeChecks(r)
    NxWxSearchChecks(r)
    NxWxRelayChecks(r, g)
    NxWxGuideChecks(r, g)

    print "weather: "; r.pass; " passed, "; r.fail; " failed"
    return r.fail
end function

function NxWxJoinNums(list as Dynamic) as String
    if type(list) <> "roArray" then return ""
    parts = []
    for each n in list
        parts.Push(NxToStr(n))
    end for
    return parts.Join(",")
end function

sub NxWxNearCheck(r as Object, name as String, got as Dynamic, want as Dynamic, tol as Double)
    if want = invalid or got = invalid then
        NxCheck(r, name, NxToStr(got), NxToStr(want))
        return
    end if
    if Abs(CDbl(got) - CDbl(want)) <= tol then
        r.pass = r.pass + 1
    else
        r.fail = r.fail + 1
        print "FAIL "; name
        print "    want "; want
        print "    got  "; got
    end if
end sub

' One field of the model against the golden's: numbers within a tolerance, the rest equal.
sub NxWxFieldCheck(r as Object, name as String, got as Dynamic, want as Dynamic)
    if NxIsNumber(want) then
        if not NxIsNumber(got) then
            NxCheck(r, name, NxToStr(got), NxToStr(want))
        else
            NxWxNearCheck(r, name, got, want, 0.0501)
        end if
    else
        NxCheck(r, name, NxToStr(got), NxToStr(want))
    end if
end sub

' The time fields: the golden has milliseconds, the port seconds.
sub NxWxMsCheck(r as Object, name as String, gotSec as Dynamic, wantMs as String)
    if wantMs = "null" then
        NxCheck(r, name, NxToStr(gotSec), "")
    else if gotSec = invalid then
        NxCheck(r, name, "invalid", wantMs)
    else
        NxCheck(r, name, gotSec.ToStr() + "000", wantMs)
    end if
end sub

sub NxWxCaseChecks(r as Object, g as Object, c as Object, times as Object)
    label = "case " + c.name + ": "
    now = NxWxParseIso(c.now)
    units = NxWxUnitsFor(c.place, c.units)
    NxCheck(r, label + "units", units, c.expect.units)
    model = NxWxBuildModel(g.met, c.place, now)
    if model = invalid then
        NxCheck(r, label + "model", "invalid", "a model")
        return
    end if
    want = c.expect.model
    NxCheck(r, label + "tz", model.tz, want.tz)
    NxWxMsCheck(r, label + "updated", model.updatedSec, times.updated)
    cur = model.current
    wc = want.current
    NxWxMsCheck(r, label + "current time", cur.timeSec, times.current)
    for each k in ["tempC", "feelsC", "humidity", "dewC", "windMs", "windDir", "pressureHpa", "cloud", "uv", "precipNextHourMm", "symbol", "isDay"]
        NxWxFieldCheck(r, label + "current " + k, cur[k], wc[k])
    end for
    NxCheck(r, label + "periods", model.periods.Count().ToStr(), want.periods.Count().ToStr())
    for i = 0 to want.periods.Count() - 1
        if i >= model.periods.Count() then exit for
        wp = want.periods[i]
        p = model.periods[i]
        NxWxMsCheck(r, label + "period " + i.ToStr() + " start", p.startSec, times.starts[i])
        for each k in ["name", "day", "tempC", "symbol", "precipMm", "windMs", "windDir"]
            NxWxFieldCheck(r, label + "period " + i.ToStr() + " " + k, p[k], wp[k])
        end for
    end for
    NxCheck(r, label + "days", model.days.Count().ToStr(), want.days.Count().ToStr())
    for i = 0 to want.days.Count() - 1
        if i >= model.days.Count() then exit for
        wd = want.days[i]
        d = model.days[i]
        for each k in ["date", "label", "highC", "lowC", "symbol", "precipMm", "windMaxMs"]
            NxWxFieldCheck(r, label + "day " + i.ToStr() + " " + k, d[k], wd[k])
        end for
    end for

    ' The text the golden composes from the model.
    wt = c.expect.text
    NxCheck(r, label + "text temp", NxWxFmtTemp(cur.tempC, units), wt.temp)
    NxCheck(r, label + "text feels", NxWxFmtTemp(cur.feelsC, units), wt.feels)
    NxCheck(r, label + "text wind", NxWxFmtWind(cur.windMs, units) + " " + NxWxCompass(cur.windDir), wt.wind)
    NxCheck(r, label + "text pressure", NxWxFmtPressure(cur.pressureHpa, units), wt.pressure)
    NxCheck(r, label + "text precip next hour", NxWxFmtPrecip(cur.precipNextHourMm, units), wt.precipNextHour)
    info = NxWxSymbolInfo(cur.symbol)
    NxCheck(r, label + "text condition", info.text, wt.condition)
    NxCheck(r, label + "text icon", info.icon, wt.icon)
    NxCheck(r, label + "text updated", NxWxFmtClock(model.updatedSec, model.tz), wt.updated)
    for i = 0 to wt.periods.Count() - 1
        if i >= model.periods.Count() then exit for
        p = model.periods[i]
        NxCheck(r, label + "text period " + i.ToStr(), p.name + " " + p.day + " " + NxWxFmtTemp(p.tempC, units) + " " + NxWxSymbolInfo(p.symbol).icon + " " + NxWxFmtPrecip(p.precipMm, units), wt.periods[i])
    end for
    for i = 0 to wt.days.Count() - 1
        if i >= model.days.Count() then exit for
        d = model.days[i]
        NxCheck(r, label + "text day " + i.ToStr(), d.label + " " + NxWxFmtTemp(d.highC, units) + "/" + NxWxFmtTemp(d.lowC, units) + " " + NxWxSymbolInfo(d.symbol).icon, wt.days[i])
    end for
end sub

' The radar addresses: the one thing the golden does not hold, and what a source answers to.
sub NxWxRadarUrlChecks(r as Object)
    bbox = [-86.751, 40.65, -72.009, 46.65]
    us = NxWxRadarProvider({ cc: "US", lat: 40.71, lon: -74.0 })
    NxCheck(r, "radar url noaa caps", NxWxCapabilitiesUrl(us, "conus_bref_qcd"), "https://opengeo.ncep.noaa.gov/geoserver/conus/conus_bref_qcd/ows?service=WMS&version=1.3.0&request=GetCapabilities")
    NxCheck(r, "radar url noaa map", NxWxMapUrl(us, "conus_bref_qcd", bbox, 435, 175, "2026-11-15T15:30:00.000Z"), "https://opengeo.ncep.noaa.gov/geoserver/conus/conus_bref_qcd/ows?service=WMS&version=1.3.0&request=GetMap&layers=conus_bref_qcd&styles=&crs=CRS:84&bbox=-86.751,40.65,-72.009,46.65&width=435&height=175&format=image/png&transparent=true&time=2026-11-15T15%3A30%3A00.000Z")
    ca = NxWxRadarProvider({ cc: "CA", lat: 43.65, lon: -79.38 })
    NxCheck(r, "radar url eccc caps", NxWxCapabilitiesUrl(ca, "RADAR_1KM_RRAI"), "https://geo.weather.gc.ca/geomet?service=WMS&version=1.3.0&request=GetCapabilities&layer=RADAR_1KM_RRAI")
    NxCheck(r, "radar url eccc map", NxWxMapUrl(ca, "RADAR_1KM_RSNO", bbox, 435, 175, ""), "https://geo.weather.gc.ca/geomet?service=WMS&version=1.3.0&request=GetMap&layers=RADAR_1KM_RSNO&styles=&crs=CRS:84&bbox=-86.751,40.65,-72.009,46.65&width=435&height=175&format=image/png&transparent=true")
    de = NxWxRadarProvider({ cc: "DE", lat: 52.5, lon: 13.4 })
    NxCheck(r, "radar url dwd caps", NxWxCapabilitiesUrl(de, "Niederschlagsradar"), "https://maps.dwd.de/geoserver/dwd/Niederschlagsradar/wms?service=WMS&version=1.3.0&request=GetCapabilities")
    NxCheck(r, "radar url dwd map", NxWxMapUrl(de, "Niederschlagsradar", bbox, 435, 175, ""), "https://maps.dwd.de/geoserver/dwd/wms?service=WMS&version=1.3.0&request=GetMap&layers=dwd:Niederschlagsradar&styles=&crs=CRS:84&bbox=-86.751,40.65,-72.009,46.65&width=435&height=175&format=image/png&transparent=true")
end sub

' The time zone table against moments Intl gave when the table was made, each side of a change.
sub NxWxZoneChecks(r as Object)
    cases = [
        ["America/Toronto", "2026-03-08T06:59:59Z", "2026-03-08 01:59 dow 0"],
        ["America/Toronto", "2026-03-08T07:00:00Z", "2026-03-08 03:00 dow 0"],
        ["America/Toronto", "2026-11-01T05:59:59Z", "2026-11-01 01:59 dow 0"],
        ["America/Toronto", "2026-11-01T06:00:00Z", "2026-11-01 01:00 dow 0"],
        ["Europe/London", "2026-03-29T00:59:59Z", "2026-03-29 00:59 dow 0"],
        ["Europe/London", "2026-03-29T01:00:00Z", "2026-03-29 02:00 dow 0"],
        ["Australia/Sydney", "2026-04-04T15:59:59Z", "2026-04-05 02:59 dow 0"],
        ["Australia/Sydney", "2026-04-04T16:00:00Z", "2026-04-05 02:00 dow 0"],
        ["Asia/Kolkata", "2026-11-15T12:00:00Z", "2026-11-15 17:30 dow 0"],
        ["Asia/Kathmandu", "2026-11-15T12:00:00Z", "2026-11-15 17:45 dow 0"],
        ["Pacific/Auckland", "2026-11-15T12:00:00Z", "2026-11-16 01:00 dow 1"],
        ["America/Phoenix", "2026-07-01T12:00:00Z", "2026-07-01 05:00 dow 3"],
        ["America/Toronto", "2031-07-04T04:30:00Z", "2031-07-04 00:30 dow 5"],
        ["UTC", "2026-11-15T12:00:00Z", "2026-11-15 12:00 dow 0"]
    ]
    for each c in cases
        p = NxWxLocalParts(NxWxParseIso(c[1]), c[0])
        NxCheck(r, "zone " + c[0] + " " + c[1], p.key + " " + NxWxPad2(p.h) + ":" + NxWxPad2(p.mi) + " dow " + p.dow.ToStr(), c[2])
    end for
    NxCheck(r, "zone: unknown reads as UTC", NxWxFmtClock(NxWxParseIso("2026-07-01T12:00:00Z"), "Nope/Zone"), "12:00 PM")
    NxCheck(r, "zone: valid", NxToStr(NxWxValidZone("America/Toronto")) + NxToStr(NxWxValidZone("Nope/Zone")) + NxToStr(NxWxValidZone("")), "truefalsefalse")
    ' The table has to reach well past the clock, or the zones stop changing: run
    ' node tests/gen-weather-zones.mjs again.
    NxCheck(r, "zone table reaches 2033 at least", NxToStr(NxWxZoneTableEnd() > NxWxParseIso("2033-01-01T00:00:00Z")), "true")
end sub

sub NxWxTimeChecks(r as Object)
    NxCheck(r, "iso roundtrip", NxWxIso(NxWxParseIso("2026-11-15T15:24:06Z")), "2026-11-15T15:24:06.000Z")
    NxCheck(r, "iso with a fraction", NxWxIso(NxWxParseIso("2026-11-15T15:24:06.987Z")), "2026-11-15T15:24:06.000Z")
    NxCheck(r, "iso known second", NxToStr(NxWxParseIso("2026-11-15T18:20:00Z")), "1794766800")
    NxCheck(r, "iso leap day", NxWxIso(NxWxParseIso("2028-02-29T23:59:59Z")), "2028-02-29T23:59:59.000Z")
    NxCheck(r, "iso: not a time", NxToStr(NxWxParseIso("tomorrow")) + NxToStr(NxWxParseIso("2026-13-01T00:00:00Z")) + NxToStr(NxWxParseIso(invalid)), "")
    NxCheck(r, "clock: noon and midnight", NxWxFmtClock(NxWxParseIso("2026-11-15T12:05:00Z"), "UTC") + " " + NxWxFmtClock(NxWxParseIso("2026-11-15T00:05:00Z"), "UTC"), "12:05 PM 12:05 AM")
    NxCheck(r, "temps round halves up and never print a minus zero", NxWxFmtTemp(-0.4, "C") + NxWxFmtTemp(-0.5, "C") + NxWxFmtTemp(0.5, "C"), "001")
end sub

' A stand-in set of shard files, read through the loader the task gives the real one.
function NxWxStandInFiles() as Object
    deg = {}
    deg["places/meta.json"] = { version: 1, tz: ["America/Toronto", "America/Chicago", "Europe/Berlin", "Europe/London", "America/Los_Angeles"], split: ["to"], postcodes: ["US", "CA", "GB"] }
    deg["places/c/tor.json"] = [["Toronto", "CA", "ON", 43.65, -79.38, 0], ["Torrance", "US", "CA", 33.84, -118.34, 4], ["Toronto", "US", "OH", 40.46, -80.6, 0]]
    deg["places/c/to.json"] = []
    deg["places/c/sp.json"] = [["Springfield", "US", "IL", 39.8, -89.64, 1], ["Springfield", "US", "MA", 42.1, -72.59, 0], ["Spring", "US", "TX", 30.08, -95.42, 1]]
    deg["places/c/mu.json"] = [["München", "DE", "Bavaria", 48.14, 11.58, 2], ["Munich Township", "US", "MI", 43.6, -83.8, 0]]
    deg["places/c/lo.json"] = [["London", "GB", "England", 51.51, -0.13, 3], ["London", "CA", "ON", 42.98, -81.25, 0]]
    deg["places/z/US/90.json"] = [["90210", "Beverly Hills", "CA", 34.1, -118.41, 4], ["90211", "Beverly Hills", "CA", 34.06, -118.38, 4], ["90001", "Los Angeles", "CA", 33.97, -118.25, 4]]
    deg["places/z/GB/SW.json"] = [["SW1A", "Westminster (Buckingham Palace / Parliament)", "England", 51.5, -0.13, 3]]
    deg["places/z/CA/M5.json"] = [["M5V", "Downtown Toronto (CN Tower / Rogers Centre)", "ON", 43.64, -79.4, 0]]
    return deg
end function

sub NxWxSearchChecks(r as Object)
    files = NxWxStandInFiles()
    load = function(path as String) as Dynamic
        return NxWxStandInFiles()[path]
    end function
    names = function(res as Object) as String
        out = []
        for each p in res.places
            out.Push(p.label)
        end for
        return out.Join(" | ")
    end function

    res = NxWxSearch("toronto", load)
    NxCheck(r, "search: a city, most people first, the shard split to three letters", names(res), "TORONTO, ON, CA | TORONTO, OH, US")
    NxCheck(r, "search: the place carries its zone and kind", res.places[0].tz + " " + res.places[0].kind + " " + NxToStr(res.places[0].lat), "America/Toronto city 43.65")
    res = NxWxSearch("to", load)
    NxCheck(r, "search: two letters of a split key asks for more", res.hint + "|" + res.places.Count().ToStr(), "KEEP TYPING|0")
    res = NxWxSearch("springfield il", load)
    NxCheck(r, "search: the state after the name", names(res), "SPRINGFIELD, IL, US")
    res = NxWxSearch("springfield, ma", load)
    NxCheck(r, "search: a comma before the state", names(res), "SPRINGFIELD, MA, US")
    res = NxWxSearch("springfield", load)
    NxCheck(r, "search: a name alone lists them all", res.places.Count().ToStr(), "2")
    res = NxWxSearch("london us", load)
    NxCheck(r, "search: nothing for a country with no such place", res.places.Count().ToStr(), "0")
    res = NxWxSearch("london ca", load)
    NxCheck(r, "search: the country after the name", names(res), "LONDON, ON, CA")
    res = NxWxSearch("munchen", load)
    NxCheck(r, "search: the mark on a letter is ignored, and the label keeps it", names(res), "MÜNCHEN, BAVARIA, DE")
    res = NxWxSearch("MÜNCHEN", load)
    NxCheck(r, "search: and typed with it", res.places.Count().ToStr(), "1")
    res = NxWxSearch("90210", load)
    NxCheck(r, "search: a postcode, the whole code before the longer ones", names(res), "90210 BEVERLY HILLS, CA, US")
    res = NxWxSearch("902", load)
    NxCheck(r, "search: part of a postcode lists its codes", names(res), "90210 BEVERLY HILLS, CA, US | 90211 BEVERLY HILLS, CA, US")
    res = NxWxSearch("sw1a 1aa", load)
    NxCheck(r, "search: a full UK postcode reads as its outward part, and the brackets go", names(res), "SW1A WESTMINSTER, ENGLAND, GB")
    res = NxWxSearch("m5v 3l9", load)
    NxCheck(r, "search: a Canadian code by its first three", names(res), "M5V DOWNTOWN TORONTO, ON, CA")
    NxCheck(r, "search: a postcode place has no country of its own until it is given one", res.places[0].cc + " " + res.places[0].code + " " + res.places[0].kind, "CA M5V postcode")
    res = NxWxSearch("nowhere", load)
    NxCheck(r, "search: nothing", res.places.Count().ToStr() + "|" + res.hint, "0|")
    res = NxWxSearch("  ", load)
    NxCheck(r, "search: nothing typed", res.places.Count().ToStr() + "|" + res.hint, "0|")
    gone = function(path as String) as Dynamic
        return invalid
    end function
    res = NxWxSearch("toronto", gone)
    NxCheck(r, "search: no place list", res.hint, "PLACE LIST NOT AVAILABLE")
    NxCheck(r, "plain", NxWxPlain("Torreón, São Paulo-1") + "|" + NxWxPlain("Łódź"), "torreonsaopaulo1|odz")
    NxCheck(r, "upper keeps the marks", NxWxUpper("Torreón, Zürich"), "TORREÓN, ZÜRICH")
    NxCheck(r, "files are what the loader reads", NxToStr(files.Count() > 0), "true")
end sub

sub NxWxRelayChecks(r as Object, g as Object)
    place = { name: "Toronto", region: "ON", cc: "CA", lat: 43.6532, lon: -79.3832, tz: "America/Toronto", kind: "city" }
    NxCheck(r, "relay: two decimals, as the web", NxWxForecastUrl("https://www.nostalgex.app/api/weather", place), "https://www.nostalgex.app/api/weather?lat=43.65&lon=-79.38")
    NxCheck(r, "relay: a small negative", NxWxForecastUrl("https://x/api/weather", { lat: 0.004, lon: -0.004 }), "https://x/api/weather?lat=0.00&lon=0.00")
    NxCheck(r, "due: nothing kept", NxToStr(NxWxForecastDue(invalid, 1000, 1800)), "true")
    NxCheck(r, "due: before Expires", NxToStr(NxWxForecastDue({ body: true, savedSec: 100, expiresSec: 5000 }, 4000, 1800)), "false")
    NxCheck(r, "due: past Expires but inside the gap", NxToStr(NxWxForecastDue({ body: true, savedSec: 3000, expiresSec: 3500 }, 4000, 1800)), "false")
    NxCheck(r, "due: past Expires and the gap", NxToStr(NxWxForecastDue({ body: true, savedSec: 1000, expiresSec: 1500 }, 4000, 1800)), "true")
    age = NxWxForecastAge(NxWxParseIso("2026-11-15T13:19:35Z"), NxWxParseIso("2026-11-15T14:00:00Z"), "America/Toronto")
    NxCheck(r, "age: updated", age.text + "|" + NxToStr(age.stale), "UPDATED 8:19 AM|false")
    age = NxWxForecastAge(NxWxParseIso("2026-11-15T13:19:35Z"), NxWxParseIso("2026-11-15T20:00:00Z"), "America/Toronto")
    NxCheck(r, "age: stale past six hours", NxToStr(age.stale), "true")
    NxCheck(r, "age: none", NxWxForecastAge(invalid, 1000, "UTC").text, "")

    NxCheck(r, "place: kept at two decimals", NxToStr(NxWxNormalizePlace({ name: "Toronto", lat: 43.6532, lon: -79.3832, tz: "America/Toronto", cc: "ca", region: "ON" }).lat), "43.65")
    bad = NxToStr(NxWxNormalizePlace({ name: "", lat: 1, lon: 1 })) + NxToStr(NxWxNormalizePlace({ name: "X", lat: 91, lon: 1 })) + NxToStr(NxWxNormalizePlace({ name: "X", lat: 1 })) + NxToStr(NxWxNormalizePlace(invalid))
    NxCheck(r, "place: unusable ones are dropped", bad, "")
    p = NxWxNormalizePlace({ name: "X", lat: 1, lon: 2, tz: "Nope/Zone", cc: "us" })
    NxCheck(r, "place: an unknown zone is UTC, the country upper case", p.tz + " " + p.cc + " " + p.kind, "UTC US city")

    trimmed = NxWxTrim({ properties: { meta: { updated_at: "2026-11-15T13:19:35Z", units: {} }, timeseries: [{ time: "2026-11-15T14:00:00Z", data: { instant: { details: { air_temperature: 5.0, junk: 1 } }, next_1_hours: { summary: { symbol_code: "cloudy" } }, next_12_hours: { summary: { symbol_code: "cloudy" } }, extra: 1 } }] } })
    d = trimmed.properties.timeseries[0].data
    NxCheck(r, "trim: only what the channel reads", NxToStr(d.instant.details.junk <> invalid) + NxToStr(d.extra <> invalid) + NxToStr(d.next_1_hours <> invalid) + trimmed.properties.meta.updated_at, "falsefalsetrue2026-11-15T13:19:35Z")
    NxCheck(r, "trim: not a document", NxToStr(NxWxTrim({ a: 1 })) + NxToStr(NxWxTrim(invalid)), "")
    ' The trimmed document gives the same model as the whole one.
    c = g.cases[0]
    a = NxWxBuildModel(g.met, c.place, NxWxParseIso(c.now))
    b = NxWxBuildModel(NxWxTrim(g.met), c.place, NxWxParseIso(c.now))
    NxCheck(r, "trim: the same model", NxWxInfoSummary(a, "C") + "|" + a.days.Count().ToStr(), NxWxInfoSummary(b, "C") + "|" + b.days.Count().ToStr())
end sub

sub NxWxGuideChecks(r as Object, g as Object)
    c = g.cases[0]
    model = NxWxBuildModel(g.met, c.place, NxWxParseIso(c.now))
    deg = Chr(176)
    NxCheck(r, "info summary", NxWxInfoSummary(model, "C"), "Cloudy, 6" + deg + "C. Feels like 3" + deg + ". High 7" + deg + ", low 5" + deg + ". Wind NNW 17 km/h.")
    f = NxWxBuildModel(g.met, g.cases[2].place, NxWxParseIso(g.cases[2].now))
    NxCheck(r, "info summary in F", Left(NxWxInfoSummary(f, "F"), 15), "Cloudy, 44" + deg + "F. F")
    now = NxWxParseIso("2026-11-15T18:20:00Z")
    blocks = NxWxGuideBlocks("TORONTO, ON, CA", now, 26, "")
    NxCheck(r, "guide: 26 hour blocks from the hour before", blocks.Count().ToStr() + " " + NxWxIso(blocks[0].startSec), "26 2026-11-15T17:00:00.000Z")
    NxCheck(r, "guide: back to back", NxToStr(blocks[1].startSec = blocks[0].endSec) + NxToStr(blocks[25].endSec - blocks[0].startSec), "true93600")
    NxCheck(r, "guide: the row's line", blocks[0].line + "|" + blocks[0].title + "|" + blocks[0].episodeTitle, "LOCAL WEATHER: TORONTO, ON, CA|LOCAL WEATHER|TORONTO, ON, CA")
    NxCheck(r, "guide: the channel", NxToStr(NxWxChannel().number) + " " + NxToStr(NxWxChannel().id) + " " + NxWxChannel().name, "299 1030000 LOCAL WEATHER")
    plain = NxWxGuideBlocks("", now, 2, "")
    NxCheck(r, "guide: no place, no colon", plain[0].line, "LOCAL WEATHER")
end sub

' Every value written after `"key": ` in the raw JSON, as text ("null" for null), in order.
function NxWxRawNumbers(raw as String, key as String) as Object
    out = []
    needle = Chr(34) + key + Chr(34) + ":"
    at = 1
    while true
        found = Instr(at, raw, needle)
        if found = 0 then exit while
        i = found + Len(needle)
        while Mid(raw, i, 1) = " "
            i = i + 1
        end while
        word = ""
        while i <= Len(raw)
            c = Mid(raw, i, 1)
            if c = "," or c = "}" or c = Chr(10) or c = Chr(13) or c = " " then exit while
            word = word + c
            i = i + 1
        end while
        out.Push(word)
        at = i
    end while
    return out
end function
