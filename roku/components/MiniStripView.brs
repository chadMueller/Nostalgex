' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' MiniChannelStrip's cards: a channel-colour bar on top, the number in the
' channel's colour, the name, and what airs now. The playing channel's card
' is tinted with its colour, the focused one is dark with a colour border,
' the rest light. Rounded corners are square here; the band behind is flat
' where upstream's fades in from the top.

sub init()
    m.fonts = {}
    m.focus = 0
    m.cardW = 310
    m.gap = 12
    m.cardH = 104
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

function newLabel(text as String, font as String, size as Integer, color as String, x as Float, y as Float, width as Float) as Object
    lbl = CreateObject("roSGNode", "Label")
    lbl.text = text
    lbl.font = fontOf(font, size)
    lbl.color = color
    lbl.translation = [x, y]
    if width > 0 then
        lbl.width = width
        lbl.ellipsizeOnBoundary = true
    end if
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

sub outline(g as Object, x as Float, y as Float, w as Float, h as Float, t as Float, color as String)
    g.AppendChild(newRect(x, y, w, t, color))
    g.AppendChild(newRect(x, y + h - t, w, t, color))
    g.AppendChild(newRect(x, y, t, h, color))
    g.AppendChild(newRect(x + w - t, y, t, h, color))
end sub

' A colour with another alpha: "0xRRGGBBFF" to "0xRRGGBB" + alpha.
function tint(color as String, alpha as String) as String
    return Left(color, 8) + alpha
end function

sub open(unused = invalid as Dynamic)
    m.focus = m.top.current
    render()
    m.top.SetFocus(true)
end sub

sub render()
    g = m.top.FindNode("cards")
    g.RemoveChildrenIndex(g.GetChildCount(), 0)
    chans = m.top.channels
    stride = m.cardW + m.gap
    ' The focused card stays centred, as scrollTo(anchor: .center).
    x0 = 960 - m.cardW / 2 - m.focus * stride
    y = 930
    first = m.focus - 4
    if first < 0 then first = 0
    last = m.focus + 4
    if last > chans.Count() - 1 then last = chans.Count() - 1
    for i = first to last
        ch = chans[i]
        x = x0 + i * stride
        focused = i = m.focus
        current = i = m.top.current
        fill = "0xFFFFFF24"
        if current and not focused then fill = tint(ch.color, "2E")
        if focused then fill = "0x0D0D12FF"
        g.AppendChild(newRect(x, y, m.cardW, m.cardH, fill))
        border = "0xFFFFFF40"
        if current then border = tint(ch.color, "99")
        if focused then border = ch.color
        t = 1
        if focused then t = 2
        outline(g, x, y, m.cardW, m.cardH, t, border)
        bar = 4
        if focused then bar = 5
        g.AppendChild(newRect(x, y, m.cardW, bar, ch.color))
        num = newLabel(NxToStr(ch.number), "DMMono-Medium", 26, ch.color, x + 16, y + 16, 0)
        g.AppendChild(num)
        numW = num.boundingRect().width
        g.AppendChild(newLabel(UCase(NxToStr(ch.name)), "DMMono-Medium", 18, "0xFFFFFFFF", x + 16 + numW + 10, y + 22, m.cardW - 42 - numW))
        lineColor = "0xFFFFFFB3"
        if focused then lineColor = "0xFFFFFFE6"
        g.AppendChild(newLabel(NxToStr(ch.line), "DMMono-Regular", 16, lineColor, x + 16, y + 62, m.cardW - 32))
    end for
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "left" and m.focus > 0 then
        m.focus = m.focus - 1
        render()
    else if key = "right" and m.focus < m.top.channels.Count() - 1 then
        m.focus = m.focus + 1
        render()
    else if key = "OK" then
        m.top.picked = m.focus
    else if key = "back" or NxOverlayKey("strip", key, false, false) = "close" then
        ' Down is the reverse of Up, which pushed the strip up from the bottom.
        m.top.closed = true
    end if
    ' Every other key stays here while the strip is up.
    return true
end function
