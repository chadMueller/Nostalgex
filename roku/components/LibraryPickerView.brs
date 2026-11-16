' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' The library picker (I-092; the Apple TV's library selection screen): branding
' and the explanation on the left, the library sections and CONTINUE on the
' right. Every section starts on (a hidden Jellyfin library off); OK on a row
' switches it; CONTINUE needs at least one. The look is the connect screens' (ConnectView, upstream's
' OnboardingStyle): the focused row a cyan slab with dark text, the others a
' dim box with a grey edge, CONTINUE a primary button.

sub init()
    m.fonts = {}
    m.focus = 0
    m.top0 = 0
    m.cyan = "0x00D4FF"
    m.rowH = 100
    m.rowGap = 12
    m.rowsVisible = 5
    m.colX = 1000
    m.colW = 820
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

function newLabel(text as String, font as String, size as Integer, color as String, x as Float, y as Float) as Object
    lbl = CreateObject("roSGNode", "Label")
    lbl.text = text
    lbl.font = fontOf(font, size)
    lbl.color = color
    lbl.translation = [x, y]
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

' A nine-patch from images/look (scripts/look-images.py), tinted, at the box
' x, y, w, h with `margin` px of glow room around it.
function newPatch(name as String, color as String, opacity as Float, x as Float, y as Float, w as Float, h as Float, margin as Integer) as Object
    p = CreateObject("roSGNode", "Poster")
    p.uri = "pkg:/images/look/" + name
    p.blendColor = color
    p.opacity = opacity
    p.translation = [x - margin, y - margin]
    p.width = w + 2 * margin
    p.height = h + 2 * margin
    return p
end function

' A group at x, y that grows by `scale` about its middle.
function newBox(x as Float, y as Float, w as Float, h as Float, scale as Float) as Object
    b = CreateObject("roSGNode", "Group")
    b.translation = [x, y]
    b.scaleRotateCenter = [w / 2, h / 2]
    b.scale = [scale, scale]
    return b
end function

sub render()
    if m.on = invalid then
        m.on = []
        multi = false
        first = invalid
        for each s in m.top.sections
            if first = invalid then first = s.serverId
            if s.serverId <> first then multi = true
        end for
        m.multi = multi
        for each s in m.top.sections
            ' Nothing chosen yet: every library on, a hidden Jellyfin one off.
            m.on.Push(NxSectionRowOn(s, {}, {}))
        end for
        ' Focus starts on CONTINUE: the usual choice is already ticked.
        if anyOn() then m.focus = continueIndex()
        renderLeft()
        m.top.SetFocus(true)
    end if
    renderList()
end sub

sub renderLeft()
    g = m.top.FindNode("left")
    ' The brand wordmark, 440 wide as upstream's (scripts/icons.sh).
    logo = CreateObject("roSGNode", "Poster")
    logo.uri = "pkg:/images/logo.png"
    logo.width = 440
    logo.height = 58
    g.AppendChild(logo)
    g.AppendChild(newLabel("CHOOSE YOUR LIBRARIES", "DMMono-Medium", 40, "0xFFFFFFE6", 0, 86))
    body = newLabel("Pick which libraries Nostalgex should build channels from. A library you turn off is never read, which keeps a big one from filling this TV's memory. You can change this later in Settings.", "DMMono-Regular", 22, "0xFFFFFF73", 0, 164)
    body.width = 560
    body.wrap = true
    body.lineSpacing = 4
    g.AppendChild(body)
    g.translation = [100, 540 - 150]
end sub

function continueIndex() as Integer
    return m.top.sections.Count()
end function

function anyOn() as Boolean
    return NxHasValue(m.on, true)
end function

sub renderList()
    servers = m.top.sections
    shown = servers.Count()
    if shown > m.rowsVisible then shown = m.rowsVisible
    listH = shown * m.rowH + (shown - 1) * m.rowGap
    contH = 80
    top = (1080 - (listH + 24 + contH)) / 2

    g = m.top.FindNode("list")
    g.RemoveChildrenIndex(g.GetChildCount(), 0)
    if m.focus < continueIndex() then
        if m.focus < m.top0 then m.top0 = m.focus
        if m.focus >= m.top0 + m.rowsVisible then m.top0 = m.focus - m.rowsVisible + 1
    end if
    y = top
    last = m.top0 + shown - 1
    cyan = m.cyan + "FF"
    dark = "0x000F17FF"
    for i = m.top0 to last
        s = servers[i]
        focused = i = m.focus
        on = m.on[i]
        scale = 1.0
        if focused then scale = 1.04
        row = newBox(m.colX, y, m.colW, m.rowH, scale)
        if focused then
            row.AppendChild(newPatch("ob_slab.9.png", cyan, 1.0, 0, 0, m.colW, m.rowH, 44))
        else
            row.AppendChild(newPatch("ob_fill.9.png", "0xFFFFFFFF", 0.03, 0, 0, m.colW, m.rowH, 0))
            row.AppendChild(newPatch("ob_edge.9.png", "0xFFFFFFFF", 0.18, 0, 0, m.colW, m.rowH, 0))
        end if
        nameColor = "0xFFFFFF8C"
        if on then nameColor = "0xFFFFFFFF"
        if focused then nameColor = dark
        row.AppendChild(newLabel(NxToStr(s.title), "DMMono-Medium", 28, nameColor, 32, 22))
        kind = NxSectionSubtitle(s, m.multi)
        kindColor = "0xFFFFFF66"
        if focused then kindColor = "0x000F17B3"
        row.AppendChild(newLabel(kind, "DMMono-Regular", 18, kindColor, 32, 60))
        state = newLabel("OFF", "DMMono-Medium", 22, "0xFFFFFF59", 32, 36)
        if on then
            state.text = "ON"
            state.color = cyan
        end if
        if focused then state.color = dark
        state.width = m.colW - 64
        state.horizAlign = "right"
        row.AppendChild(state)
        g.AppendChild(row)
        y = y + m.rowH + m.rowGap
    end for

    ' CONTINUE: a primary button, faded while nothing is on (it can't take
    ' focus then).
    c = m.top.FindNode("cont")
    c.RemoveChildrenIndex(c.GetChildCount(), 0)
    cy = top + listH + 24
    focused = m.focus = continueIndex()
    scale = 1.0
    if focused then scale = 1.07
    btn = newBox(m.colX, cy, m.colW, contH, scale)
    if not anyOn() then btn.opacity = 0.35
    color = cyan
    if focused then
        btn.AppendChild(newPatch("ob_slab.9.png", cyan, 1.0, 0, 0, m.colW, contH, 44))
        color = dark
    else
        btn.AppendChild(newPatch("ob_fill.9.png", "0xFFFFFFFF", 0.03, 0, 0, m.colW, contH, 0))
        btn.AppendChild(newPatch("ob_edge_primary.9.png", cyan, 0.75, 0, 0, m.colW, contH, 0))
    end if
    lbl = newLabel("CONTINUE", "DMMono-Medium", 30, color, 0, 22)
    lbl.width = m.colW
    lbl.horizAlign = "center"
    btn.AppendChild(lbl)
    c.AppendChild(btn)
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "down" and m.focus < continueIndex() then
        m.focus = m.focus + 1
        ' CONTINUE can't take focus while it's disabled, as on tvOS.
        if m.focus = continueIndex() and not anyOn() then m.focus = m.focus - 1
        renderList()
        return true
    end if
    if key = "up" and m.focus > 0 then
        m.focus = m.focus - 1
        renderList()
        return true
    end if
    if key = "OK" then
        if m.focus < continueIndex() then
            m.on[m.focus] = not m.on[m.focus]
            renderList()
        else if anyOn() then
            ' What differs from the start: a library turned off, a hidden one turned on.
            choices = { off: {}, included: {} }
            for i = 0 to m.top.sections.Count() - 1
                sec = m.top.sections[i]
                key = NxSectionKey(sec.serverId, sec.key)
                if sec.hidden = true then
                    if m.on[i] then choices.included[key] = true
                else if not m.on[i] then
                    choices.off[key] = true
                end if
            end for
            m.top.choices = choices
        end if
        return true
    end if
    ' Back and * are MainScene's (sign out from here).
    return false
end function
