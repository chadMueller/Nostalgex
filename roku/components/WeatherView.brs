' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' CH 299 LOCAL WEATHER's picture. See WeatherView.xml. The rules and numbers are source/weather/Weather.brs
' (held to scripts/weather-golden.json); the layout is the web tuner's scripts/nostalgex-weather-screens.js,
' coordinates for a 1920 x 1080 picture and the Apple TV's type sizes (DM Mono 25 / 29 / 34 / 44, VT323
' for the big digits).

sub init()
    m.fonts = {}
    m.stage = m.top.FindNode("stage")
    m.tick = m.top.FindNode("tick")
    m.frames = m.top.FindNode("frames")
    m.tick.ObserveField("fire", "onTick")
    m.frames.ObserveField("fire", "onFrame")

    m.W = 1920
    m.H = 1080
    m.safeX = 90
    m.safeY = 56
    m.cardTop = 172
    m.cardH = 770
    m.c = {
        bg0: "0x0A0A1AFF", panel: "0x0A0F1EFF", row: "0x141B33FF", outline: "0x3A4670FF",
        text: "0xFFFFFFFF", text2: "0xB9C3DEFF", dim: "0x80879AFF",
        cyan: "0x00D4FFFF", yellow: "0xFFE500FF", pink: "0xFF2DB4FF", red: "0xFF2244FF", amber: "0xFFB020FF"
    }
    m.accents = { current: m.c.cyan, today: m.c.yellow, week: m.c.pink, radar: m.c.amber }

    m.place = invalid
    m.unitsSetting = "auto"
    m.status = "noplace"
    m.met = invalid
    m.metKey = ""
    m.savedSec = 0
    m.expiresSec = 0
    m.failedSec = 0
    m.loading = false
    m.model = invalid
    m.lastBuildSec = 0
    m.lastCheckSec = 0
    m.builtIndex = -1
    m.dirty = true
    m.textScale = 1.0
    m.dotOn = true
    m.clockText = ""
    m.gen = 0
    m.radar = { status: "none", key: "", files: [], times: [], bbox: invalid, cities: [], credit: "", base: "", loadedSec: 0, loading: false }
    m.frameTick = 0
    m.radarNodes = []
    m.fcTask = invalid
    m.baseTask = invalid
    m.radarTask = invalid
end sub

' ── Switching on and off ─────────────────────────────────────────────────────

sub onActive()
    if m.top.active then
        loadSettings()
        m.dirty = true
        m.builtIndex = -1
        m.tick.control = "start"
        ensureForecast(false)
        onTick()
    else
        m.tick.control = "stop"
        m.frames.control = "stop"
        ' Memory: the radar's pictures go when the channel does, and come again with it.
        clearRadar()
        removeStage()
    end if
end sub

sub onReload()
    loadSettings()
    m.dirty = true
    if m.top.active then
        ensureForecast(true)
        onTick()
    end if
end sub

sub loadSettings()
    place = NxWxReadPlace()
    m.unitsSetting = NxWxReadUnits()
    m.textScale = 1.0
    if NxGuideTextStep() = "large" then m.textScale = 1.16
    newKey = ""
    if place <> invalid then newKey = NxWxPlaceKey(place)
    if newKey <> m.metKey then
        m.met = invalid
        m.metKey = ""
        m.model = invalid
        m.savedSec = 0
        m.expiresSec = 0
        m.failedSec = 0
        clearRadar()
    end if
    m.place = place
    if place = invalid then
        m.status = "noplace"
        m.model = invalid
    else if m.status = "noplace" then
        m.status = "loading"
    end if
    publish()
end sub

function unitsNow() as String
    return NxWxUnitsFor(m.place, m.unitsSetting)
end function

function nowSec() as Integer
    return CreateObject("roDateTime").AsSeconds()
end function

' What the owner needs for the guide's row and info panel.
sub publish()
    if m.place = invalid then
        m.top.placeLabel = ""
        m.top.summary = ""
        m.top.tempLabel = ""
        return
    end if
    m.top.placeLabel = NxWxPlaceLabel(m.place)
    summary = ""
    if m.model <> invalid then summary = NxWxInfoSummary(m.model, unitsNow())
    m.top.summary = summary
    m.top.tempLabel = NxWxTempLabel(m.model, unitsNow())
end sub

' ── The forecast ─────────────────────────────────────────────────────────────

sub ensureForecast(force as Boolean)
    if m.place = invalid then
        m.status = "noplace"
        m.model = invalid
        return
    end if
    key = NxWxPlaceKey(m.place)
    now = nowSec()
    if m.metKey <> key then
        saved = NxWxReadForecast(key)
        m.met = invalid
        m.savedSec = 0
        m.expiresSec = 0
        if saved <> invalid then
            m.met = saved.body
            m.savedSec = NxNumberOr0(saved.savedSec)
            m.expiresSec = NxNumberOr0(saved.expiresSec)
        end if
        m.metKey = key
        m.model = invalid
    end if
    kept = { body: m.met <> invalid, savedSec: m.savedSec, expiresSec: m.expiresSec }
    if not force and m.met <> invalid and not NxWxForecastDue(kept, now, 1800) then
        if m.model = invalid then rebuildModel()
        return
    end if
    if m.loading then
        if m.model = invalid then rebuildModel()
        return
    end if
    if not force and m.failedSec > 0 and now - m.failedSec < 60 then
        if m.model = invalid then rebuildModel()
        return
    end if
    m.loading = true
    if m.met = invalid then m.status = "loading"
    m.fcTask = CreateObject("roSGNode", "WeatherTask")
    m.fcTask.op = "forecast"
    m.fcTask.args = { place: m.place }
    m.fcTask.ObserveField("result", "onForecast")
    m.fcTask.control = "run"
    m.fcKey = key
    if m.model = invalid then rebuildModel()
end sub

sub onForecast()
    res = m.fcTask.result
    m.loading = false
    m.fcTask = invalid
    if res = invalid then return
    if m.place = invalid or m.fcKey <> m.metKey then return
    if res.ok = true then
        m.met = res.body
        m.savedSec = res.savedSec
        m.expiresSec = res.expiresSec
        m.failedSec = 0
        NxWxSaveForecast(m.metKey, m.savedSec, m.expiresSec, m.met)
    else
        m.failedSec = nowSec()
        if m.met = invalid then m.status = "error"
        print "weather: the forecast did not come ("; NxToStr(res.code); ")"
    end if
    rebuildModel()
end sub

sub rebuildModel()
    m.lastBuildSec = nowSec()
    if m.place = invalid or m.met = invalid then
        m.model = invalid
        if m.place <> invalid and m.status <> "error" then m.status = "loading"
        publish()
        m.dirty = true
        return
    end if
    model = NxWxBuildModel(m.met, m.place, m.lastBuildSec)
    if model = invalid then
        ' A document that ends before now: ask again at the next check.
        m.model = invalid
        m.status = "error"
        m.expiresSec = 0
    else
        m.model = model
        m.status = "ready"
    end if
    publish()
    m.dirty = true
end sub

' ── The tick ─────────────────────────────────────────────────────────────────

sub onTick()
    if not m.top.active then return
    if m.tickClock <> invalid then
        gap = m.tickClock.TotalMilliseconds()
        if gap > 1500 then print "weather: the render thread was held "; gap; " ms between ticks"
    end if
    m.tickClock = CreateObject("roTimespan")
    now = nowSec()
    at = NxWxScreenAt(now)
    if now - m.lastBuildSec >= 60 then rebuildModel()
    if now - m.lastCheckSec >= 20 then
        m.lastCheckSec = now
        ensureForecast(false)
    end if
    ' The radar frames load from the TODAY screen on, so they are there when the radar comes up.
    ' Not at the first draw: the TV's CPU goes to the first screens, then the radar's work starts behind them.
    if at.index >= 1 then ensureRadar()
    if m.dirty or at.index <> m.builtIndex then buildScreen(at.index)
    ' The header's clock and the blinking dot.
    if m.place <> invalid and m.clockLbl <> invalid then
        text = NxWxFmtClock(now, m.place.tz)
        if text <> m.clockText then
            m.clockText = text
            m.clockLbl.text = text
        end if
    end if
    if m.dotNode <> invalid then
        m.dotOn = (now mod 2) = 0
        m.dotNode.visible = m.dotOn
    end if
end sub

' The radar's frames, one at a time, then a hold on the last.
sub onFrame()
    n = m.radarNodes.Count()
    if n = 0 then return
    m.frameTick = m.frameTick + 1
    showFrame(m.frameTick mod (n + 3))
end sub

sub showFrame(i as Integer)
    n = m.radarNodes.Count()
    if i > n - 1 then i = n - 1
    for k = 0 to n - 1
        m.radarNodes[k].visible = (k = i)
    end for
    if m.agoLbl <> invalid and m.radar.times.Count() > i then
        t = m.radar.times[i]
        ago = (nowSec() - t) \ 60
        if ago < 0 then ago = 0
        m.agoLbl.text = NxWxFmtClock(t, m.place.tz) + "  " + ago.ToStr() + " MIN AGO"
    end if
end sub

' ── Radar ────────────────────────────────────────────────────────────────────

sub clearRadar()
    m.frames.control = "stop"
    m.radarNodes = []
    ' The pictures in tmp: go with it (no file system object on this thread, so by name).
    if m.radar.base <> invalid and m.radar.base <> "" then DeleteFile(m.radar.base)
    for each f in m.radar.files
        DeleteFile(f)
    end for
    m.radar = { status: "none", key: "", files: [], times: [], bbox: invalid, cities: [], credit: "", base: "", loadedSec: 0, loading: false }
    m.baseTask = invalid
    m.radarTask = invalid
end sub

sub ensureRadar()
    if m.place = invalid then return
    R = m.radar
    provider = NxWxRadarProvider(m.place)
    if provider = invalid then
        if R.status <> "none" then
            R.status = "none"
            m.dirty = true
        end if
        return
    end if
    key = NxWxPlaceKey(m.place)
    now = nowSec()
    if R.loading then return
    if R.key = key and R.status = "ready" and now - R.loadedSec < 300 then return
    if R.key = key and R.status = "error" and now - R.loadedSec < 60 then return
    ' Memory: the app's limit first (the frames are pictures held in the TV's graphics memory).
    if CreateObject("roAppMemoryMonitor").GetMemoryLimitPercent() > 75 then
        R.status = "error"
        R.loadedSec = now
        m.dirty = true
        return
    end if
    R.loading = true
    if R.key <> key then
        R.files = []
        R.times = []
        R.status = "loading"
        R.base = ""
        R.cities = []
        m.dirty = true
    end if
    R.key = key
    R.credit = provider.credit
    m.gen = m.gen + 1
    if R.base = "" then
        m.baseTask = CreateObject("roSGNode", "WeatherTask")
        m.baseTask.op = "basemap"
        m.baseTask.args = { place: m.place, gen: m.gen }
        m.baseTask.ObserveField("result", "onBasemap")
        m.baseTask.control = "run"
    else
        startRadarTask()
    end if
end sub

sub startRadarTask()
    m.radarTask = CreateObject("roSGNode", "WeatherTask")
    m.radarTask.op = "radar"
    m.radarTask.args = { place: m.place, gen: m.gen }
    m.radarTask.ObserveField("result", "onRadar")
    m.radarTask.control = "run"
end sub

sub onBasemap()
    res = m.baseTask.result
    m.baseTask = invalid
    if m.place = invalid or NxWxPlaceKey(m.place) <> m.radar.key then
        m.radar.loading = false
        return
    end if
    if res <> invalid and res.ok = true then
        m.radar.base = res.file
        m.radar.bbox = res.bbox
        m.radar.cities = res.cities
    else
        print "weather: the map did not draw ("; NxToStr(res.why); ")"
    end if
    startRadarTask()
end sub

sub onRadar()
    res = m.radarTask.result
    m.radarTask = invalid
    R = m.radar
    R.loading = false
    R.loadedSec = nowSec()
    if m.place = invalid or NxWxPlaceKey(m.place) <> R.key then return
    if res <> invalid and res.ok = true then
        R.files = res.files
        R.times = res.times
        R.bbox = res.bbox
        R.status = "ready"
    else
        why = "?"
        if res <> invalid then why = NxToStr(res.why)
        print "weather: the radar did not load ("; why; ")"
        if R.files.Count() = 0 then R.status = "error"
    end if
    m.dirty = true
end sub

' ── Drawing ──────────────────────────────────────────────────────────────────

function fontOf(name as String, size as Integer) as Object
    key = name + size.ToStr()
    if m.fonts[key] = invalid then
        f = CreateObject("roSGNode", "Font")
        f.uri = "pkg:/fonts/" + name + ".ttf"
        f.size = size
        m.fonts[key] = f
    end if
    return m.fonts[key]
end function

sub removeStage()
    m.stage.RemoveChildrenIndex(m.stage.GetChildCount(), 0)
    m.clockLbl = invalid
    m.dotNode = invalid
    m.agoLbl = invalid
    m.radarNodes = []
    m.builtIndex = -1
end sub

function rect(parent as Object, x as Float, y as Float, w as Float, h as Float, color as String) as Object
    r = CreateObject("roSGNode", "Rectangle")
    r.translation = [x, y]
    r.width = w
    r.height = h
    r.color = color
    parent.AppendChild(r)
    return r
end function

' A box edge, t thick.
sub frame(parent as Object, x as Float, y as Float, w as Float, h as Float, color as String, t as Float)
    rect(parent, x, y, w, t, color)
    rect(parent, x, y + h - t, w, t, color)
    rect(parent, x, y, t, h, color)
    rect(parent, x + w - t, y, t, h, color)
end sub

sub card(parent as Object, x as Float, y as Float, w as Float, h as Float, accent as String)
    rect(parent, x, y, w, h, m.c.row)
    frame(parent, x, y, w, h, m.c.outline, 2)
    if accent <> "" then rect(parent, x + 12, y, w - 24, 8, accent)
end sub

' Text with its baseline at `baseline`, as the web's canvas draws it. align is "left", "center" or
' "right" about x; maxW holds the text to a width (cut with a dot) and is the box a centred or right
' aligned line sits in.
function txt(parent as Object, str as String, fontName as String, size as Float, color as String, x as Float, baseline as Float, align as String, maxW as Float) as Object
    lbl = CreateObject("roSGNode", "Label")
    px = Int(size + 0.5)
    lbl.font = fontOf(fontName, px)
    lbl.color = color
    lbl.text = str
    ascent = 0.80
    if fontName = "VT323-Regular" then ascent = 0.74
    top = baseline - px * ascent
    w = maxW
    if align = "left" then
        lbl.translation = [x, top]
        if maxW > 0 then
            lbl.width = maxW
            lbl.ellipsisText = Chr(8230)
        end if
    else
        if w <= 0 then w = 900
        lbl.width = w
        lbl.ellipsisText = Chr(8230)
        if align = "center" then
            lbl.horizAlign = "center"
            lbl.translation = [x - w / 2, top]
        else
            lbl.horizAlign = "right"
            lbl.translation = [x - w, top]
        end if
    end if
    parent.AppendChild(lbl)
    return lbl
end function

' Words wrapped to a width, at most maxLines lines. Returns the number of lines drawn.
function wrapTxt(parent as Object, str as String, fontName as String, size as Float, color as String, x as Float, baseline as Float, align as String, width as Float, maxLines as Integer, pitch as Float) as Integer
    lbl = CreateObject("roSGNode", "Label")
    px = Int(size + 0.5)
    lbl.font = fontOf(fontName, px)
    lbl.color = color
    lbl.text = str
    lbl.wrap = true
    lbl.maxLines = maxLines
    lbl.width = width
    lbl.ellipsisText = Chr(8230)
    if align = "center" then lbl.horizAlign = "center"
    ' The line height of this font, for the pitch the web uses.
    top = baseline - px * 0.80
    if align = "center" then
        lbl.translation = [x - width / 2, top]
    else
        lbl.translation = [x, top]
    end if
    one = CreateObject("roSGNode", "Label")
    one.font = lbl.font
    one.text = "X"
    lineH = one.boundingRect().height
    lines = 1
    if lineH > 0 then lines = Int(lbl.boundingRect().height / lineH + 0.5)
    if lines < 1 then lines = 1
    if lines > maxLines then lines = maxLines
    if pitch > lineH and lines > 1 then lbl.lineSpacing = pitch - lineH
    parent.AppendChild(lbl)
    return lines
end function

' A big temperature in VT323 with a drawn degree ring (the font's own degree sign floats away from its
' digits at this size), and the unit letter after it when given.
sub bigTemp(parent as Object, value as String, x as Float, baseline as Float, size as Float, color as String, align as String, unit as String)
    lbl = txt(parent, value, "VT323-Regular", size, color, 0, baseline, "left", 0)
    dw = lbl.boundingRect().width
    ring = Int(size * 0.125 + 0.5)
    gap = Int(size * 0.03 + 0.5)
    uw = 0
    ulbl = invalid
    if unit <> "" then
        ulbl = txt(parent, unit, "VT323-Regular", size * 0.42, color, 0, baseline - size * 0.2, "left", 0)
        uw = ulbl.boundingRect().width + gap
    end if
    total = dw + gap + ring + uw
    left = x
    if align = "center" then left = x - total / 2
    if align = "right" then left = x - total
    lbl.translation = [left, lbl.translation[1]]
    rx = Int(left + dw + gap + 0.5)
    ry = Int(baseline - size * 0.6 + 0.5)
    t = Int(size * 0.035 + 0.5)
    if t < 2 then t = 2
    frame(parent, rx, ry, ring, ring, color, t)
    if ulbl <> invalid then ulbl.translation = [rx + ring + gap, ulbl.translation[1]]
end sub

' An icon in the slot the web draws a 336, 192 or 168 icon in (the web's numbers), 15% smaller (288, 168, 144: whole
' pixel cells, so it stays crisp), centred in the old slot.
sub icon(parent as Object, name as String, x as Float, y as Float, slot as Integer)
    size = 288
    if slot = 192 then size = 168
    if slot = 168 then size = 144
    off = (slot - size) / 2
    x = x + off
    y = y + off
    p = CreateObject("roSGNode", "Poster")
    p.uri = "pkg:/images/weather/" + name + "-" + size.ToStr() + ".png"
    p.translation = [x, y]
    p.width = size
    p.height = size
    parent.AppendChild(p)
end sub

sub buildScreen(index as Integer)
    clock = CreateObject("roTimespan")
    buildScreenNow(index)
    print "weather: drew "; NxWxScreens()[index].id; " in "; clock.TotalMilliseconds(); " ms, "; m.stage.GetChildCount(); " nodes, memory "; CreateObject("roAppMemoryMonitor").GetMemoryLimitPercent(); "%"
end sub

sub buildScreenNow(index as Integer)
    removeStageKeepClock()
    m.dirty = false
    m.builtIndex = index
    screens = NxWxScreens()
    screen = screens[index]
    st = m.stage
    hasData = m.status <> "noplace" and m.model <> invalid
    title = "LOCAL WEATHER"
    accent = m.c.cyan
    if hasData then
        title = screen.title
        accent = m.accents[screen.id]
    end if
    header(st, title, accent)
    extra = ""
    if m.status = "noplace" then
        message(st, "SET YOUR LOCATION IN SETTINGS", "SETTINGS, CHANNELS AND BUNDLES, LOCAL WEATHER, LOCATION", m.c.cyan)
    else if m.status = "loading" and m.model = invalid then
        message(st, "LOADING THE FORECAST", "", m.c.cyan)
    else if m.status = "error" and m.model = invalid then
        message(st, "FORECAST UNAVAILABLE RIGHT NOW", "TRYING AGAIN SOON", m.c.amber)
    else if m.model = invalid then
        message(st, "LOADING THE FORECAST", "", m.c.cyan)
    else if screen.id = "current" then
        screenCurrent(st)
    else if screen.id = "today" then
        screenToday(st)
    else if screen.id = "week" then
        screenWeek(st)
    else if screen.id = "radar" then
        extra = screenRadar(st)
    end if
    footer(st, index, extra)
    if m.model <> invalid and screen.id = "radar" and m.radarNodes.Count() > 1 then
        m.frames.control = "start"
    else
        m.frames.control = "stop"
    end if
end sub

sub removeStageKeepClock()
    m.stage.RemoveChildrenIndex(m.stage.GetChildCount(), 0)
    m.clockLbl = invalid
    m.dotNode = invalid
    m.agoLbl = invalid
    m.radarNodes = []
    m.clockText = ""
end sub

' The strip at the top: the channel, the screen's name, the place and the local time.
sub header(parent as Object, title as String, accent as String)
    x = m.safeX
    y = m.safeY
    w = m.W - 2 * m.safeX
    h = 76
    rect(parent, x, y, w, h, m.c.panel)
    frame(parent, x, y, w, h, m.c.outline, 2)
    rect(parent, x, y + 12, 10, h - 24, accent)
    ' The blinking dot, a drawn square (the font has no dot).
    rect(parent, x + 34, y + 30, 18, 18, "0x00D4FF33")
    m.dotNode = rect(parent, x + 34, y + 30, 18, 18, m.c.cyan)
    txt(parent, "CH " + NxToStr(NxWxChannel().number), "VT323-Regular", 40, m.c.cyan, x + 72, y + 51, "left", 0)
    titleLbl = txt(parent, title, "DMMono-Medium", 40, m.c.text, x + 190, y + 51, "left", 0)
    titleW = titleLbl.boundingRect().width
    clockW = 0
    if m.place <> invalid then
        m.clockText = NxWxFmtClock(nowSec(), m.place.tz)
        m.clockLbl = txt(parent, m.clockText, "VT323-Regular", 44, m.c.yellow, x + w - 24, y + 52, "right", 260)
        clockW = m.clockLbl.boundingRect().width + 28
        scale = m.textScale
        if scale > 1 then scale = 1
        maxPlace = w - 190 - titleW - 80 - clockW
        if maxPlace < 200 then maxPlace = 200
        txt(parent, NxWxPlaceTitle(m.place), "DMMono-Medium", 30 * scale, m.c.text, x + w - 24 - clockW, y + 50, "right", maxPlace)
    end if
end sub

sub footer(parent as Object, screenIndex as Integer, extraCredit as String)
    base = m.H - m.safeY - 6
    ' The credits and the forecast's age are the least important things on screen: one small stack at the bottom
    ' left, about 60% of the old size (16 against 25), dim but readable at TV distance, and never dropped (the data
    ' sources require the credit).
    lines = []
    if extraCredit <> "" then lines.Push({ text: extraCredit, color: "0xB9C3DEB3" })
    lines.Push({ text: "DATA FROM MET NORWAY", color: "0xB9C3DEB3" })
    if m.model <> invalid and m.model.updatedSec <> invalid and m.place <> invalid then
        age = NxWxForecastAge(m.model.updatedSec, nowSec(), m.place.tz)
        if age.stale then
            lines.Push({ text: "OLD FORECAST FROM " + Mid(age.text, 9), color: "0xFFB020B3" })
        else
            lines.Push({ text: age.text, color: "0xB9C3DEB3" })
        end if
    end if
    y = base - (lines.Count() - 1) * 22
    for each l in lines
        txt(parent, l.text, "DMMono-Regular", 16, l.color, m.safeX, y, "left", 800)
        y = y + 22
    end for
    ' The loop's pips on the right.
    pips = NxWxScreens().Count()
    pw = 44
    gap = 10
    ids = ["current", "today", "week", "radar"]
    px = m.W - m.safeX - (pips * pw + (pips - 1) * gap)
    for i = 0 to pips - 1
        color = m.c.outline
        if i = screenIndex then color = m.accents[ids[i]]
        rect(parent, px, base - 12, pw, 10, color)
        px = px + pw + gap
    end for
end sub

' Cards without data.
sub message(parent as Object, title as String, subText as String, color as String)
    w = 1300
    h = 340
    x = (m.W - w) / 2
    y = 300
    card(parent, x, y, w, h, color)
    lines = wrapTxt(parent, title, "DMMono-Medium", 56, color, m.W / 2, y + 130 - 34, "center", w - 120, 2, 70)
    if subText <> "" then wrapTxt(parent, subText, "DMMono-Regular", 29, m.c.text2, m.W / 2, y + h - 80, "center", w - 140, 2, 42)
end sub

' ── The four screens ─────────────────────────────────────────────────────────

sub screenCurrent(parent as Object)
    s = m.textScale
    cur = m.model.current
    u = unitsNow()
    info = NxWxSymbolInfo(cur.symbol)
    top = m.cardTop
    lx = m.safeX
    lw = 860
    card(parent, lx, top, lw, m.cardH, m.c.cyan)
    icon(parent, info.icon, lx + 44, top + 80, 336)
    bigTemp(parent, NxWxFmtTemp(cur.tempC, u), lx + 400, top + 380, 340, m.c.text, "left", u)
    cy = top + 540
    lines = wrapTxt(parent, info.text, "DMMono-Medium", 44 * s, m.c.cyan, lx + 40, cy, "left", lw - 80, 2, 56 * s)
    cy = cy + (lines - 1) * 56 * s + 56 * s
    fy = cy + 14 - 56 * s + 56 * s
    if fy < top + 650 then fy = top + 650
    txt(parent, "FEELS LIKE " + NxWxFmtTemp(cur.feelsC, u) + Chr(176), "DMMono-Medium", 34 * s, m.c.text, lx + 40, fy, "left", 0)
    txt(parent, "AS OF " + NxWxFmtClock(cur.timeSec, m.model.tz), "DMMono-Regular", 25 * s, m.c.text2, lx + 40, top + m.cardH - 44, "left", 0)

    ' Right: rows, the app's row spec (88 high, the resting outline).
    dir = NxWxCompass(cur.windDir)
    wind = NxWxFmtWind(cur.windMs, u)
    if dir <> "" then wind = dir + " " + wind
    humidity = "--"
    if cur.humidity <> invalid then humidity = cur.humidity.ToStr() + "%"
    cloud = "--"
    if cur.cloud <> invalid then cloud = cur.cloud.ToStr() + "%"
    nextHour = "--"
    if cur.precipNextHourMm <> invalid then nextHour = NxWxFmtPrecip(cur.precipNextHourMm, u)
    rows = [
        ["WIND", wind],
        ["HUMIDITY", humidity],
        ["DEW POINT", NxWxFmtTemp(cur.dewC, u) + Chr(176)],
        ["PRESSURE", NxWxFmtPressure(cur.pressureHpa, u)],
        ["CLOUD COVER", cloud]
    ]
    if cur.uv <> invalid then rows.Push(["UV INDEX", cur.uv.ToStr()])
    rows.Push(["NEXT HOUR", nextHour])
    rx = lx + lw + 30
    rw = m.W - m.safeX - rx
    rowH = 88
    gap = 14
    total = rows.Count() * rowH + (rows.Count() - 1) * gap
    ry = top + (m.cardH - total) / 2
    for each row in rows
        rect(parent, rx, ry, rw, rowH, m.c.row)
        frame(parent, rx, ry, rw, rowH, m.c.outline, 2)
        label = txt(parent, row[0], "DMMono-Regular", 29 * s, m.c.text2, rx + 28, ry + 56, "left", 0)
        room = rw - 56 - label.boundingRect().width - 20
        txt(parent, row[1], "DMMono-Medium", 34 * s, m.c.text, rx + rw - 28, ry + 56, "right", room)
        ry = ry + rowH + gap
    end for
end sub

sub screenToday(parent as Object)
    s = m.textScale
    u = unitsNow()
    top = m.cardTop
    n = m.model.periods.Count()
    if n < 1 then n = 1
    gap = 30
    cw = (m.W - 2 * m.safeX - (n - 1) * gap) / n
    i = 0
    for each p in m.model.periods
        x = m.safeX + i * (cw + gap)
        info = NxWxSymbolInfo(p.symbol)
        card(parent, x, top, cw, m.cardH, m.c.yellow)
        cx = x + cw / 2
        txt(parent, p.name, "DMMono-Medium", 38 * s, m.c.text, cx, top + 76, "center", cw - 30)
        txt(parent, p.day, "DMMono-Regular", 25 * s, m.c.text2, cx, top + 118, "center", cw - 30)
        icon(parent, info.icon, cx - 96, top + 148, 192)
        bigTemp(parent, NxWxFmtTemp(p.tempC, u), cx, top + 520, 200, m.c.text, "center", "")
        wrapTxt(parent, info.text, "DMMono-Medium", 29 * s, m.c.cyan, cx, top + 590, "center", cw - 40, 2, 38 * s)
        dir = NxWxCompass(p.windDir)
        windLine = "WIND " + NxWxFmtWind(p.windMs, u)
        if dir <> "" then windLine = "WIND " + dir + " " + NxWxFmtWind(p.windMs, u)
        txt(parent, windLine, "DMMono-Regular", 25 * s, m.c.text2, cx, top + m.cardH - 84, "center", cw - 24)
        precipColor = m.c.text2
        if p.precipMm <> invalid and p.precipMm > 0 then precipColor = m.c.yellow
        txt(parent, "PRECIP " + NxWxFmtPrecip(p.precipMm, u), "DMMono-Regular", 25 * s, precipColor, cx, top + m.cardH - 40, "center", cw - 24)
        i = i + 1
    end for
end sub

sub screenWeek(parent as Object)
    s = m.textScale
    u = unitsNow()
    top = m.cardTop
    n = m.model.days.Count()
    if n < 1 then n = 1
    gap = 24
    cw = (m.W - 2 * m.safeX - (n - 1) * gap) / n
    i = 0
    for each d in m.model.days
        x = m.safeX + i * (cw + gap)
        info = NxWxSymbolInfo(d.symbol)
        card(parent, x, top, cw, m.cardH, m.c.pink)
        cx = x + cw / 2
        txt(parent, d.label, "DMMono-Medium", 40 * s, m.c.text, cx, top + 78, "center", cw - 20)
        icon(parent, info.icon, cx - 84, top + 104, 168)
        txt(parent, "HIGH", "DMMono-Regular", 25 * s, m.c.text2, cx, top + 336, "center", cw - 20)
        bigTemp(parent, NxWxFmtTemp(d.highC, u), cx, top + 440, 150, m.c.text, "center", "")
        txt(parent, "LOW", "DMMono-Regular", 25 * s, m.c.text2, cx, top + 486, "center", cw - 20)
        bigTemp(parent, NxWxFmtTemp(d.lowC, u), cx, top + 566, 100, m.c.cyan, "center", "")
        wrapTxt(parent, info.text, "DMMono-Medium", 25 * s, m.c.cyan, cx, top + 630, "center", cw - 32, 2, 34 * s)
        precip = "DRY"
        color = m.c.text2
        if d.precipMm <> invalid and d.precipMm > 0 then
            precip = NxWxFmtPrecip(d.precipMm, u)
            color = m.c.yellow
        end if
        txt(parent, precip, "DMMono-Regular", 25 * s, color, cx, top + m.cardH - 36, "center", cw - 20)
        i = i + 1
    end for
end sub

' The radar: the map and the frames, or the card that says why not. Returns the provider's credit line.
function screenRadar(parent as Object) as String
    R = m.radar
    mx = m.safeX
    my = m.cardTop
    mw = m.W - 2 * m.safeX
    mh = 700
    rect(parent, mx, my, mw, mh, "0x070C18FF")
    if R.status = "none" then
        message(parent, "RADAR NOT AVAILABLE IN YOUR AREA", "RADAR COVERS THE UNITED STATES, CANADA AND GERMANY", m.c.amber)
        return ""
    end if
    if R.status = "loading" and R.files.Count() = 0 then
        message(parent, "LOADING RADAR", "THE MAP DRAWS AS SOON AS THE FRAMES ARRIVE", m.c.amber)
        return R.credit
    end if
    if R.status = "error" and R.files.Count() = 0 then
        message(parent, "RADAR UNAVAILABLE RIGHT NOW", "TRYING AGAIN SOON", m.c.amber)
        return R.credit
    end if
    ' The map under the echoes.
    if R.base <> "" then
        base = CreateObject("roSGNode", "Poster")
        base.uri = R.base
        base.translation = [mx, my]
        base.width = mw
        base.height = mh
        parent.AppendChild(base)
    end if
    nodes = []
    for each f in R.files
        p = CreateObject("roSGNode", "Poster")
        p.uri = f
        p.translation = [mx, my]
        p.width = mw
        p.height = mh
        p.opacity = 0.9
        p.visible = false
        parent.AppendChild(p)
        nodes.Push(p)
    end for
    m.radarNodes = nodes
    if R.bbox <> invalid then
        drawCities(parent, R.bbox, R.cities, mx, my, mw, mh)
        drawPin(parent, R.bbox, mx, my, mw, mh)
    end if
    frame(parent, mx, my, mw, mh, m.c.outline, 3)
    ' The legend row under the map: the five bands, and the frame's time.
    ly = my + mh + 20
    lx = mx
    txt(parent, "RAIN AND SNOW", "DMMono-Regular", 25, m.c.text2, lx, ly + 24, "left", 0)
    lx = lx + 245
    for each b in NxWxRadarBands()
        rect(parent, lx, ly + 4, 26, 26, "0x" + Mid(b.color, 2) + "FF")
        label = txt(parent, b.name, "DMMono-Regular", 25, m.c.text, lx + 38, ly + 26, "left", 0)
        lx = lx + 38 + label.boundingRect().width + 34
    end for
    m.agoLbl = txt(parent, "", "VT323-Regular", 40, m.c.yellow, mx + mw, ly + 28, "right", 520)
    if nodes.Count() > 0 then
        m.frameTick = 0
        showFrame(0)
    end if
    return R.credit
end function

' Up to nine of the window's cities, named where they stand, none on top of another or of the pin.
sub drawCities(parent as Object, bbox as Object, cities as Object, mx as Integer, my as Integer, mw as Integer, mh as Integer)
    mine = project(bbox, m.place.lon, m.place.lat, mx, my, mw, mh)
    taken = []
    shown = 0
    font = fontOf("VT323-Regular", 34)
    for each c in cities
        if shown >= 9 then exit for
        pt = project(bbox, c.lon, c.lat, mx, my, mw, mh)
        name = NxWxUpper(c.name)
        probe = CreateObject("roSGNode", "Label")
        probe.font = font
        probe.text = name
        w = probe.boundingRect().width + 26
        spot = [pt[0] - 6, pt[1] - 30, pt[0] + w, pt[1] + 10]
        dx = pt[0] - mine[0]
        dy = pt[1] - mine[1]
        far = (dx * dx + dy * dy) >= 4900
        inside = pt[0] >= mx + 20 and pt[0] + w <= mx + mw - 10 and pt[1] >= my + 40 and pt[1] <= my + mh - 20
        clear = true
        for each b in taken
            if not (spot[2] < b[0] or spot[0] > b[2] or spot[3] < b[1] or spot[1] > b[3]) then clear = false
        end for
        if far and inside and clear then
            taken.Push(spot)
            rect(parent, pt[0] - 4, pt[1] - 4, 8, 8, m.c.text2)
            txt(parent, name, "VT323-Regular", 34, m.c.text2, pt[0] + 14, pt[1] + 8, "left", 0)
            shown = shown + 1
        end if
    end for
end sub

sub drawPin(parent as Object, bbox as Object, mx as Integer, my as Integer, mw as Integer, mh as Integer)
    pt = project(bbox, m.place.lon, m.place.lat, mx, my, mw, mh)
    rect(parent, pt[0] - 9, pt[1] - 9, 18, 18, m.c.pink)
    frame(parent, pt[0] - 9, pt[1] - 9, 18, 18, m.c.text, 3)
    frame(parent, pt[0] - 20, pt[1] - 20, 40, 40, m.c.pink, 3)
    label = NxWxUpper(m.place.name)
    probe = CreateObject("roSGNode", "Label")
    probe.font = fontOf("VT323-Regular", 42)
    probe.text = label
    lw = probe.boundingRect().width
    right = pt[0] + 30 + lw < mx + mw - 10
    if right then
        lx = pt[0] + 30
        rect(parent, lx - 8, pt[1] - 28, lw + 16, 40, "0x0A0A1AC7")
        txt(parent, label, "VT323-Regular", 42, m.c.yellow, lx, pt[1] + 4, "left", 0)
    else
        lx = pt[0] - 30
        rect(parent, lx - lw - 8, pt[1] - 28, lw + 16, 40, "0x0A0A1AC7")
        txt(parent, label, "VT323-Regular", 42, m.c.yellow, lx, pt[1] + 4, "right", lw + 20)
    end if
end sub

function project(bbox as Object, lon as Float, lat as Float, mx as Integer, my as Integer, mw as Integer, mh as Integer) as Object
    px = mx + (lon - bbox[0]) / (bbox[2] - bbox[0]) * mw
    py = my + (bbox[3] - lat) / (bbox[3] - bbox[1]) * mh
    return [px, py]
end function
