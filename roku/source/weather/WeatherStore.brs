' What the weather channel keeps on the TV: the viewer's place, units and switch (the registry
' section "weather", as the web tuner keeps them in localStorage), and the last forecast (a file
' in the cache, so a restart does not ask again before the document's own Expires).
'
' Copyright (c) 2026 nostalgex-roku contributors, MIT License.

' The viewer's place, or invalid when none is set.
function NxWxReadPlace() as Dynamic
    raw = NxRegSection("weather").Read("place")
    if raw = invalid or raw = "" then return invalid
    return NxWxNormalizePlace(ParseJson(raw))
end function

sub NxWxSavePlace(place as Dynamic)
    reg = NxRegSection("weather")
    if place = invalid then
        reg.Delete("place")
    else
        reg.Write("place", FormatJson(place))
    end if
    reg.Flush()
end sub

' "auto", "F" or "C".
function NxWxReadUnits() as String
    u = NxRegSection("weather").Read("units")
    if u = "F" or u = "C" then return u
    return "auto"
end function

sub NxWxSaveUnits(units as String)
    reg = NxRegSection("weather")
    reg.Write("units", units)
    reg.Flush()
end sub

' AUTO, F, C, AUTO: what OK on the UNITS row does.
function NxWxNextUnits(units as String) as String
    if units = "auto" then return "F"
    if units = "F" then return "C"
    return "auto"
end function

function NxWxUnitsLabel(units as String) as String
    if units = "F" then return Chr(176) + "F"
    if units = "C" then return Chr(176) + "C"
    return "AUTO"
end function

' Whether LOCAL WEATHER is in the guide: on until the viewer turns it off, as on the web tuner.
function NxWxChannelOn() as Boolean
    return NxRegSection("weather").Read("channel") <> "0"
end function

sub NxWxSaveChannelOn(on as Boolean)
    reg = NxRegSection("weather")
    if on then reg.Write("channel", "1") else reg.Write("channel", "0")
    reg.Flush()
end sub

' The relay and the place files: the site's, and in a sideloaded build a manifest line (nx_weather_base)
' can point them at a stand-in server on the network. A signed build never reads that line.
function NxWxBase() as String
    info = CreateObject("roAppInfo")
    if info.IsDev() then
        b = NxToStr(info.GetValue("nx_weather_base"))
        if Left(b, 7) = "http://" or Left(b, 8) = "https://" then return b
    end if
    return "https://www.nostalgex.app"
end function

function NxWxForecastPath() as String
    return NxCacheRoot() + "/nostalgex-weather.json"
end function

' The last forecast kept: { key, savedSec, expiresSec, body }, or invalid when none, or for another place.
function NxWxReadForecast(key as String) as Dynamic
    raw = ReadAsciiFile(NxWxForecastPath())
    if raw = "" then return invalid
    v = ParseJson(raw)
    if type(v) <> "roAssociativeArray" or v.key <> key or type(v.body) <> "roAssociativeArray" or type(v.body.properties) <> "roAssociativeArray" then return invalid
    return v
end function

sub NxWxSaveForecast(key as String, savedSec as Integer, expiresSec as Integer, body as Object)
    WriteAsciiFile(NxWxForecastPath(), FormatJson({ key: key, savedSec: savedSec, expiresSec: expiresSec, body: body }))
end sub

sub NxWxDeleteForecast()
    DeleteFile(NxWxForecastPath())
end sub

' The place's key for the kept forecast: its coordinates at 2 decimals, as the relay is asked.
function NxWxPlaceKey(place as Object) as String
    lat# = place.lat
    lon# = place.lon
    return NxWxFixed(lat#, 2) + "," + NxWxFixed(lon#, 2)
end function

' The seconds a Cache-Control or Expires date gives, from an HTTP date ("Sun, 15 Nov 2026 14:00:00 GMT"),
' or invalid.
function NxWxParseHttpDate(text as Dynamic) as Dynamic
    s = NxToStr(text).Trim()
    if s = "" then return invalid
    comma = Instr(1, s, ",")
    if comma > 0 then s = Mid(s, comma + 1).Trim()
    parts = s.Split(" ")
    if parts.Count() < 4 then return invalid
    months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    mo = 0
    for i = 0 to 11
        if UCase(Left(parts[1], 3)) = months[i] then mo = i + 1
    end for
    clock = parts[3].Split(":")
    if mo = 0 or clock.Count() < 3 then return invalid
    day = parts[0].ToInt()
    year = parts[2].ToInt()
    if day < 1 or day > 31 or year < 1970 then return invalid
    return NxWxDaysFromCivil(year, mo, day) * 86400 + clock[0].ToInt() * 3600 + clock[1].ToInt() * 60 + clock[2].ToInt()
end function
