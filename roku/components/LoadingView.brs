' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Upstream's LoadingView with its step rail. The steps are LibraryLoadPhase's
' (App/LibraryLoadPhase.swift), titles, headlines and hints as upstream has
' them. Two differences: Collections is always a step, since the Roku reads
' a server's collections on every scan, not only for a collection package;
' and while channels build, the headline stays BUILDING CHANNELS rather than
' naming each channel.

sub init()
    m.fonts = {}
    m.dots = ""
    m.layout = ""
    m.cyan = "0x00D4FF"
    m.steps = [
        { id: "preparing", title: "Lineup", headline: "PREPARING LINEUP", hint: "Loading channel rules and bundles" },
        { id: "library", title: "Library", headline: "SCANNING PLEX LIBRARY", hint: "Reading movies, shows, and music from your server" },
        { id: "collections", title: "Collections", headline: "DISCOVERING COLLECTIONS", hint: "Finding smart collections in your library" },
        { id: "metadata", title: "Metadata", headline: "ENRICHING METADATA", hint: "TMDB and OMDb power the genre and network channels" },
        { id: "channels", title: "Channels", headline: "BUILDING CHANNELS", hint: "Matching your library to each channel" },
        { id: "finishing", title: "Ready", headline: "TUNING IN", hint: "Almost there" }
    ]
    m.timer = CreateObject("roSGNode", "Timer")
    m.timer.duration = 0.4
    m.timer.repeat = true
    m.timer.ObserveField("fire", "onDots")
    m.timer.control = "start"
end sub

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

' A label centred across the screen.
function centred(text as String, font as String, size as Integer, color as String, y as Float) as Object
    lbl = CreateObject("roSGNode", "Label")
    lbl.text = text
    lbl.font = fontOf(font, size)
    lbl.color = color
    lbl.width = 1920
    lbl.horizAlign = "center"
    lbl.translation = [0, y]
    return lbl
end function

function newRect(x as Float, y as Float, w as Float, h as Float, color as String) as Object
    r = CreateObject("roSGNode", "Rectangle")
    r.translation = [x, y]
    r.width = w
    r.height = h
    r.color = color
    return r
end function

function newIcon(name as String, x as Float, y as Float, w as Float, h as Float, color as String) as Object
    p = CreateObject("roSGNode", "Poster")
    p.uri = "pkg:/images/look/" + name + ".png"
    p.translation = [x, y]
    p.width = w
    p.height = h
    p.blendColor = color
    return p
end function

sub onTask()
    t = m.top.task
    for each f in ["phase", "progress", "bar", "barCaption", "firstRun", "savedBefore"]
        t.ObserveField(f, "render")
    end for
    render()
end sub

sub onDots()
    if Len(m.dots) >= 3 then m.dots = "" else m.dots = m.dots + "."
    if m.headline <> invalid then m.headline.text = m.headlineText + m.dots
end sub

function stepIndex(id as String) as Integer
    for i = 0 to m.steps.Count() - 1
        if m.steps[i].id = id then return i
    end for
    return 0
end function

' Every progress, bar and caption change lands here, three per collection
' read, so a change that keeps the layout only updates the detail line and
' the bar in place. Rebuilding the whole screen each time took the 55R617
' over 2.5 s per collection.
sub render()
    t = m.top.task
    if t = invalid then return
    current = stepIndex(t.phase)
    st = m.steps[current]
    detail = UCase(NxToStr(t.progress))
    if st.id = "channels" and t.bar >= 0 then detail = ""
    if detail = "" and st.id <> "channels" then detail = UCase(st.hint)
    value = t.bar
    if value > 1 then value = 1
    layout = st.id + "|" + t.firstRun.ToStr() + "|" + t.savedBefore.ToStr() + "|" + (detail <> "").ToStr() + "|" + (t.bar >= 0).ToStr() + "|" + m.top.stalling.ToStr()
    if layout = m.layout then
        if m.detail <> invalid then m.detail.text = detail
        if m.barFill <> invalid then
            m.barFill.width = 420 * value
            m.barFill.visible = value > 0
            m.barCaption.text = UCase(NxToStr(t.barCaption))
        end if
        return
    end if
    m.layout = layout
    m.detail = invalid
    m.barFill = invalid
    g = m.top.FindNode("content")
    g.RemoveChildrenIndex(g.GetChildCount(), 0)

    ' The stack, top to bottom, 28 apart, centred on the screen as a whole.
    gap = 28
    h = 66 + 20 + gap + 56 + gap + 42
    if t.firstRun then h = h + 30 + gap
    if detail <> "" then h = h + 30 + gap
    if t.bar >= 0 then h = h + 44 + gap
    if m.top.stalling then h = h + 12 + stallHeight()
    y = (1080 - h) / 2

    ' The brand wordmark, 500 wide as upstream's (scripts/icons.sh).
    logo = CreateObject("roSGNode", "Poster")
    logo.uri = "pkg:/images/logo.png"
    logo.width = 500
    logo.height = 66
    logo.translation = [710, y]
    g.AppendChild(logo)
    y = y + 66 + 20 + gap
    if t.firstRun then
        note = "First setup can take a few minutes to scan and build channels."
        if t.savedBefore then note = "The TV cleared the saved library, so it's being read again. This can take a few minutes."
        g.AppendChild(centred(note, "DMMono-Regular", 22, "0xFFFFFF8C", y))
        y = y + 30 + gap
    end if
    renderRail(g, y, current)
    y = y + 56 + gap
    m.headlineText = st.headline
    m.headline = centred(m.headlineText + m.dots, "DMMono-Medium", 32, m.cyan + "FF", y)
    g.AppendChild(m.headline)
    y = y + 42 + gap
    if detail <> "" then
        lbl = centred(detail, "DMMono-Regular", 22, "0xFFFFFF73", y)
        lbl.width = 1200
        lbl.translation = [360, y]
        lbl.wrap = false
        lbl.ellipsizeOnBoundary = true
        g.AppendChild(lbl)
        m.detail = lbl
        y = y + 30 + gap
    end if
    if t.bar >= 0 then
        x = (1920 - 420) / 2
        g.AppendChild(newRect(x, y, 420, 6, "0xFFFFFF26"))
        m.barFill = newRect(x, y, 420 * value, 6, m.cyan + "FF")
        m.barFill.visible = value > 0
        g.AppendChild(m.barFill)
        m.barCaption = centred(UCase(NxToStr(t.barCaption)), "DMMono-Regular", 19, "0xFFFFFF66", y + 16)
        g.AppendChild(m.barCaption)
        y = y + 44 + gap
    end if
    if m.top.stalling then renderStall(g, y + 12)
end sub

' Upstream's stallBlock (App/Plex90App.swift): once the scan has gone quiet,
' a line saying so, STOP WAITING as the focused primary button
' (OnboardingButtonStyle, 24 pt) and what it does, 14 apart.
function stallHeight() as Float
    return 28 + 14 + 80 + 14 + 24
end function

sub renderStall(g as Object, y as Float)
    g.AppendChild(centred("Still waiting on your server. Nothing has come back for a while.", "DMMono-Regular", 20, "0xFFFFFF80", y))
    y = y + 28 + 14
    label = "STOP WAITING"
    font = fontOf("DMMono-Medium", 24)
    probe = CreateObject("roSGNode", "Label")
    probe.font = font
    probe.text = label
    w = probe.boundingRect().width + 2 * 36
    h = 80
    b = CreateObject("roSGNode", "Group")
    b.translation = [(1920 - w) / 2, y]
    b.scaleRotateCenter = [w / 2, h / 2]
    b.scale = [1.07, 1.07]
    slab = CreateObject("roSGNode", "Poster")
    slab.uri = "pkg:/images/look/ob_slab.9.png"
    slab.blendColor = m.cyan + "FF"
    slab.translation = [-44, -44]
    slab.width = w + 88
    slab.height = h + 88
    b.AppendChild(slab)
    lbl = CreateObject("roSGNode", "Label")
    lbl.text = label
    lbl.font = font
    lbl.color = "0x000F17FF"
    lbl.width = w
    lbl.height = h
    lbl.horizAlign = "center"
    lbl.vertAlign = "center"
    b.AppendChild(lbl)
    g.AppendChild(b)
    y = y + h + 14
    g.AppendChild(centred("Keeps whatever has loaded so far and finishes the rest later.", "DMMono-Regular", 17, "0xFFFFFF4D", y))
end sub

' LibraryLoadStepRail: a circle per step, done ones ticked, the current one
' dotted; short connectors between them, cyan behind a done step.
sub renderRail(g as Object, y as Float, current as Integer)
    n = m.steps.Count()
    connW = 36
    cellW = (900 - (n - 1) * connW) / n
    x = (1920 - 900) / 2
    for i = 0 to n - 1
        if i < current then
            ringColor = m.cyan + "FF"
            labelColor = "0xFFFFFF8C"
        else if i = current then
            ringColor = m.cyan + "FF"
            labelColor = m.cyan + "FF"
        else
            ringColor = "0xFFFFFF40"
            labelColor = "0xFFFFFF4D"
        end if
        cx = x + cellW / 2
        g.AppendChild(newIcon("step_ring", cx - 14, y, 28, 28, ringColor))
        if i < current then
            g.AppendChild(newIcon("step_check", cx - 7, y + 7, 14, 14, m.cyan + "FF"))
        else if i = current then
            g.AppendChild(newIcon("step_dot", cx - 5, y + 9, 10, 10, m.cyan + "FF"))
        end if
        lbl = CreateObject("roSGNode", "Label")
        lbl.text = UCase(m.steps[i].title)
        lbl.font = fontOf("DMMono-Regular", 16)
        lbl.color = labelColor
        lbl.width = cellW
        lbl.horizAlign = "center"
        lbl.translation = [x, y + 36]
        g.AppendChild(lbl)
        x = x + cellW
        if i < n - 1 then
            c = "0xFFFFFF26"
            if i < current then c = m.cyan + "80"
            g.AppendChild(newRect(x, y + 13, connW, 2, c))
            x = x + connW
        end if
    end for
end sub
