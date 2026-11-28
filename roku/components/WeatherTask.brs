' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' The weather channel's work off the render thread. See WeatherTask.xml and source/weather/Weather.brs.

sub init()
    m.top.functionName = "doWeather"
end sub

sub doWeather()
    op = m.top.op
    args = m.top.args
    if args = invalid then args = {}
    if op = "forecast" then
        m.top.result = forecastJob(args)
    else if op = "search" then
        m.top.result = searchJob(args)
    else if op = "basemap" then
        m.top.result = basemapJob(args)
    else if op = "radar" then
        m.top.result = radarJob(args)
    else
        m.top.result = { ok: false, why: "no such job" }
    end if
end sub

' One GET: { code, text, headers }. code 0 is no answer in time (or a refused address).
function httpGet(address as String, headers as Object, limitMs as Integer) as Object
    xfer = CreateObject("roUrlTransfer")
    port = CreateObject("roMessagePort")
    xfer.SetMessagePort(port)
    xfer.SetUrl(address)
    xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    xfer.EnablePeerVerification(true)
    xfer.EnableHostVerification(true)
    xfer.EnableEncodings(true)
    for each k in headers
        xfer.AddHeader(k, headers[k])
    end for
    if not xfer.AsyncGetToString() then return { code: 0, text: "", headers: {} }
    msg = Wait(limitMs, port)
    if type(msg) <> "roUrlEvent" then
        xfer.AsyncCancel()
        return { code: 0, text: "", headers: {} }
    end if
    code = msg.GetResponseCode()
    if code < 0 then code = 0
    return { code: code, text: msg.GetString(), headers: msg.GetResponseHeaders() }
end function

' One GET, with a second try when nothing answered (NxWxGetRetrying).
function httpGetRetrying(address as String, headers as Object, limitMs as Integer) as Object
    return NxWxGetRetrying(httpGet, httpPause, address, headers, limitMs)
end function

sub httpPause(ms as Integer)
    Sleep(ms)
end sub

' One GET into a file: the response code, 0 when it did not arrive.
function httpGetFile(address as String, path as String, limitMs as Integer) as Integer
    xfer = CreateObject("roUrlTransfer")
    port = CreateObject("roMessagePort")
    xfer.SetMessagePort(port)
    xfer.SetUrl(address)
    xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    xfer.EnablePeerVerification(true)
    xfer.EnableHostVerification(true)
    if not xfer.AsyncGetToFile(path) then return 0
    msg = Wait(limitMs, port)
    if type(msg) <> "roUrlEvent" then
        xfer.AsyncCancel()
        return 0
    end if
    code = msg.GetResponseCode()
    if code < 0 then return 0
    return code
end function

' ── The forecast ─────────────────────────────────────────────────────────────

' The relay asks MET Norway for us and keeps its rules (the identifying User-Agent, Expires, the
' repeat window); this asks the relay, and only while the channel is on screen.
function forecastJob(args as Object) as Object
    place = args.place
    address = NxWxForecastUrl(NxWxBase() + "/api/weather", place)
    got = httpGetRetrying(address, { "X-Nostalgex-Client": "roku", "Accept": "application/json" }, 15000)
    if got.code <> 200 then return { ok: false, code: got.code }
    body = NxWxTrim(ParseJson(got.text))
    if body = invalid or body.properties.timeseries.Count() = 0 then return { ok: false, code: got.code, why: "empty" }
    saved = CreateObject("roDateTime").AsSeconds()
    expires = invalid
    if type(got.headers) = "roAssociativeArray" then expires = NxWxParseHttpDate(got.headers.expires)
    if expires = invalid then expires = saved + 1800
    return { ok: true, body: body, savedSec: saved, expiresSec: expires }
end function

' ── The place search ─────────────────────────────────────────────────────────

function searchJob(args as Object) as Object
    res = NxWxSearch(NxToStr(args.query), NxWxNetLoad)
    return { ok: true, places: res.places, hint: res.hint }
end function

' A file of the place list, parsed, or invalid.
function NxWxNetLoad(path as String) as Dynamic
    got = httpGetRetrying(NxWxBase() + "/weather/" + path, { "Accept": "application/json" }, 12000)
    if got.code <> 200 then return invalid
    return ParseJson(got.text)
end function

' ── Radar ────────────────────────────────────────────────────────────────────

' The picture is chunky on purpose: one pixel of the frame is four of the screen.
function mapW() as Integer
    return 435
end function

function mapH() as Integer
    return 175
end function

function mapBBox(place as Object) as Object
    return NxWxRadarBBox(place.lat, place.lon, 1740# / 700#, 5#)
end function

' The map under the echoes: the basemap's lines for the radar window at half the screen's size, as one
' PNG, and the cities in the window for the view to name. 870 by 350 shows as 1740 by 700.
function basemapJob(args as Object) as Object
    place = args.place
    bbox = mapBBox(place)
    clock = CreateObject("roTimespan")
    base = ParseJson(ReadAsciiFile("pkg:/weather/basemap.json"))
    print "weather: the basemap file read in "; clock.TotalMilliseconds(); " ms"
    if type(base) <> "roAssociativeArray" or type(base.layers) <> "roAssociativeArray" then return { ok: false, why: "no basemap" }
    bw = 870
    bh = 350
    bmp = CreateObject("roBitmap", { width: bw, height: bh, AlphaEnable: true })
    if bmp = invalid then return { ok: false, why: "no bitmap" }
    bmp.Clear(0)
    unit# = 1000#
    if NxIsNumber(base.unit) then unit# = base.unit
    minLon# = bbox[0]
    minLat# = bbox[1]
    maxLon# = bbox[2]
    maxLat# = bbox[3]
    padLon# = (maxLon# - minLon#) * 0.05#
    padLat# = (maxLat# - minLat#) * 0.05#
    sx# = bw / (maxLon# - minLon#)
    sy# = bh / (maxLat# - minLat#)
    ' [layer, colour, and whether to draw it thicker]: lakes, states, borders, coast, as the web draws them.
    styles = [["lakes", &h00D4FF73, false], ["states", &hB9C3DE61, false], ["borders", &hFF2DB4D9, true], ["coast", &h00D4FFF2, true]]
    lineCount = 0
    for each style in styles
        for each flat in NxList(base.layers[style[0]])
            ' The TV has little CPU to spare: a pause now and then gives the render thread (the clock, the icons) its turn.
            lineCount = lineCount + 1
            if lineCount mod 16 = 0 then Sleep(3)
            n = flat.Count()
            if n >= 4 then
                x# = flat[0]
                y# = flat[1]
                inside = false
                xs = []
                ys = []
                i = 0
                while i < n
                    if i > 0 then
                        x# = x# + flat[i]
                        y# = y# + flat[i + 1]
                    end if
                    lon# = x# / unit#
                    lat# = y# / unit#
                    if lon# >= minLon# - padLon# and lon# <= maxLon# + padLon# and lat# >= minLat# - padLat# and lat# <= maxLat# + padLat# then inside = true
                    xs.Push(clampPx((lon# - minLon#) * sx#, bw))
                    ys.Push(clampPx((maxLat# - lat#) * sy#, bh))
                    i = i + 2
                end while
                if inside then
                    for j = 1 to xs.Count() - 1
                        if not (xs[j] = xs[j - 1] and ys[j] = ys[j - 1]) then
                            bmp.DrawLine(xs[j - 1], ys[j - 1], xs[j], ys[j], style[1])
                            if style[2] then bmp.DrawLine(xs[j - 1] + 1, ys[j - 1], xs[j] + 1, ys[j], style[1])
                        end if
                    end for
                end if
            end if
        end for
    end for
    png = bmp.GetPng(0, 0, bw, bh)
    if png = invalid then return { ok: false, why: "no png" }
    path = "tmp:/wx-base-" + NxToStr(args.gen) + ".png"
    if not png.WriteFile(path) then return { ok: false, why: "no file" }
    print "weather: the basemap drawn in "; clock.TotalMilliseconds(); " ms"
    cities = []
    for each c in NxList(base.cities)
        if c[2] > minLon# and c[2] < maxLon# and c[1] > minLat# and c[1] < maxLat# then cities.Push({ name: c[0], lat: c[1], lon: c[2] })
    end for
    return { ok: true, file: path, bbox: bbox, cities: cities }
end function

' A pixel position held to a range around the picture, so a coastline that runs off it far away does
' not make a line a million pixels long.
function clampPx(v as Float, size as Integer) as Integer
    if v < -50 then return -50
    if v > size + 50 then return size + 50
    return Int(v)
end function

' The frames of the last hour or so, recoloured to our five bands, one PNG each in tmp:. Done in
' order, one frame's pictures at a time, so memory holds a frame and no more.
function radarJob(args as Object) as Object
    place = args.place
    provider = NxWxRadarProvider(place)
    if provider = invalid then return { ok: false, why: "none" }
    ' Memory: the channel gives the frames up before it goes over three quarters of the app's limit.
    if CreateObject("roAppMemoryMonitor").GetMemoryLimitPercent() > 75 then return { ok: false, why: "memory" }
    now = CreateObject("roDateTime").AsSeconds()
    caps = httpGetRetrying(NxWxCapabilitiesUrl(provider, provider.layers[0]), { "Accept": "text/xml" }, 15000)
    if caps.code <> 200 then return { ok: false, why: "capabilities " + caps.code.ToStr() }
    stamps = NxWxPickFrameTimes(NxWxParseTimeDimension(caps.text), provider.frames, provider.stepMinutes, now - provider.lagMinutes * 60)
    if stamps.Count() = 0 then return { ok: false, why: "no frames" }
    bbox = mapBBox(place)
    w = mapW()
    h = mapH()
    bands = NxWxRadarBands()
    colors = [&h00D4FFEB, &hFFE500EB, &hFFB020EB, &hFF2244EB, &hFF2DB4EB]
    files = []
    times = []
    frameClock = CreateObject("roTimespan")
    for i = 0 to stamps.Count() - 1
        outBmp = CreateObject("roBitmap", { width: w, height: h, AlphaEnable: true })
        if outBmp = invalid then return { ok: false, why: "no bitmap" }
        outBmp.Clear(0)
        any = false
        for each layer in provider.layers
            rawPath = "tmp:/wx-raw.png"
            code = httpGetFile(NxWxMapUrl(provider, layer, bbox, w, h, stamps[i]), rawPath, 15000)
            if code = 200 then
                src = CreateObject("roBitmap", rawPath)
                if src <> invalid then
                    if recolorInto(outBmp, src, colors, provider.ignoreBands) then any = true
                    src = invalid
                end if
            end if
            DeleteFile(rawPath)
        end for
        if any then
            png = outBmp.GetPng(0, 0, w, h)
            path = "tmp:/wx-" + NxToStr(args.gen) + "-" + files.Count().ToStr() + ".png"
            if png <> invalid then
                if png.WriteFile(path) then
                    files.Push(path)
                    times.Push(NxWxParseIso(stamps[i]))
                end if
            end if
        end if
        outBmp = invalid
        print "weather: radar frame "; i + 1; " of "; stamps.Count(); " done at "; frameClock.TotalMilliseconds(); " ms"
    end for
    if files.Count() = 0 then return { ok: false, why: "no pictures" }
    return { ok: true, files: files, times: times, bbox: bbox, credit: provider.credit, w: w, h: h }
end function

' The echoes of one downloaded frame, drawn into the output in our colours: a pixel is clear, or one of
' the five bands (NxWxRadarBand). Same-band runs along a row go down as one rectangle.
function recolorInto(outBmp as Object, src as Object, colors as Object, ignored as Object) as Boolean
    w = src.GetWidth()
    h = src.GetHeight()
    bytes = src.GetByteArray(0, 0, w, h)
    if bytes = invalid then return false
    drew = false
    skip = {}
    for each b in ignored
        skip[b.ToStr()] = true
    end for
    for y = 0 to h - 1
        ' A pause every few rows: this loop is most of a frame's work, and the render thread must not wait for it.
        if y mod 4 = 3 then Sleep(4)
        runBand = -1
        runStart = 0
        rowAt = y * w * 4
        for x = 0 to w
            band = -1
            if x < w then
                p = rowAt + x * 4
                if bytes[p + 3] >= 40 then
                    band = NxWxRadarBand(bytes[p], bytes[p + 1], bytes[p + 2])
                    if band >= 0 then
                        if skip[band.ToStr()] = true then band = -1
                    end if
                end if
            end if
            if band <> runBand then
                if runBand >= 0 then
                    outBmp.DrawRect(runStart, y, x - runStart, 1, colors[runBand])
                    drew = true
                end if
                runBand = band
                runStart = x
            end if
        end for
    end for
    return drew
end function
