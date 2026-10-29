' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' The connect screens, ported from upstream's Apple TV sign-in redesign
' (Views/SettingsView.swift; the decisions are in SignInFlow.brs, the look is
' OnboardingStyle.swift's). As few presses as the server allows:
' - Picking Jellyfin or Emby starts the network search at once; FIND MY SERVER
'   is first and focused as the retry. One server answering goes straight to
'   it; several are listed; none leaves focus on TYPE AN ADDRESS.
' - The address is asked who it is before anyone types: a Jellyfin server with
'   Quick Connect on opens straight on the code, and a server that lists its
'   users shows them as tiles, so the name is a press; a user with no password
'   signs in on that press.
' - Closing the keyboard moves on: the address gets checked, the username goes
'   to the password, the password to SIGN IN (OK on the keyboard signs in).
'
' Screens: picker, find, type, signin, plexCreds. Over them, m.auth:
' "checking" (the address check), "quick" (the Quick Connect code),
' "signing", "plex" (the plex.tv/link code, driven by MainScene). Back is
' the screen's BACK or CANCEL; on the picker it is MainScene's, which
' leaves the app.
'
' plexCreds is Plex's other way in, on-device email and password straight
' to plex.tv (Roku certification rule 2.2), next to the plex.tv/link code:
' this view runs its own PlexSignInTask (mode "password") for it, the same
' as Jellyfin and Emby's password sign-in does with MediaBrowserSignInTask,
' rather than through MainScene's plexState/plexCode bridge, since it needs
' no second device and no code to show.
'
' The look: the focused control is a solid cyan slab with dark text that
' grows and glows, every other control an outline, so the one bright thing on
' screen is where the remote is. On the two code screens the buttons light up
' as a cyan outline and glow instead, so the code stays the brightest thing.
' The rounded shapes and glows are nine-patch art (images/look/ob_*.9.png,
' scripts/look-images.py) tinted here.

sub init()
    m.fonts = {}
    m.copy = NxSignInCopy()
    m.cyan = "0x00D4FF"
    m.colX = 1000
    m.colW = 820
    m.screen = "picker"
    m.auth = ""
    m.kind = ""
    m.discovery = "idle"
    m.found = []
    m.server = invalid
    m.flowMessage = ""
    m.authError = ""
    m.checkingLabel = ""
    m.address = ""
    m.username = ""
    m.password = ""
    m.plexEmail = ""
    m.plexPw = ""
    m.picked = invalid
    m.typingName = false
    m.qcCode = ""
    m.task = invalid
    m.plexTask = invalid
    m.keyboard = invalid
    m.focusId = ""
    m.controls = []
    m.wait = invalid
    m.waitBase = ""
    m.dots = ""
    m.waitTimer = CreateObject("roSGNode", "Timer")
    m.waitTimer.duration = 0.5
    m.waitTimer.repeat = true
    m.waitTimer.ObserveField("fire", "onWaitTick")
    m.top.AppendChild(m.waitTimer)
    m.fixtureTimer = invalid
    renderLeft()
    render()
    m.top.SetFocus(true)
end sub

' ── Drawing ────────────────────────────────────────────────────────────────

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

function newLabel(text as String, font as String, size as Integer, color as String) as Object
    lbl = CreateObject("roSGNode", "Label")
    lbl.text = text
    lbl.font = fontOf(font, size)
    lbl.color = color
    return lbl
end function

' A label `width` wide, centred, wrapping, at y; returns it.
function addText(parent as Object, text as String, font as String, size as Integer, color as String, y as Float, width as Float, align = "center" as String) as Object
    lbl = newLabel(text, font, size, color)
    lbl.width = width
    lbl.wrap = true
    lbl.lineSpacing = 4
    lbl.horizAlign = align
    lbl.translation = [0, y]
    parent.AppendChild(lbl)
    return lbl
end function

function heightOf(node as Object) as Float
    return node.boundingRect().height
end function

function textWidth(text as String, font as String, size as Integer) as Float
    lbl = newLabel(text, font, size, "0xFFFFFFFF")
    return lbl.boundingRect().width
end function

function lineHeight(font as String, size as Integer) as Float
    key = "h" + font + size.ToStr()
    if m.fonts[key] = invalid then m.fonts[key] = newLabel("Ag", font, size, "0xFFFFFFFF").boundingRect().height
    return m.fonts[key]
end function

' A nine-patch from images/look, tinted, at the box x, y, w, h with `margin`
' px of glow room around it.
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

' The left half: logo, CONNECT YOUR SERVER and the line under it, centred
' down the screen. The same on every connect screen.
sub renderLeft()
    g = m.top.FindNode("left")
    g.RemoveChildrenIndex(g.GetChildCount(), 0)
    logo = CreateObject("roSGNode", "Poster")
    logo.uri = "pkg:/images/logo.png"
    logo.width = 440
    logo.height = 58
    g.AppendChild(logo)
    y = 58 + 28
    title = newLabel(m.copy.screenTitle, "DMMono-Medium", 40, "0xFFFFFFE6")
    title.translation = [0, y]
    g.AppendChild(title)
    y = y + heightOf(title) + 28
    body = addText(g, m.copy.screenBody, "DMMono-Regular", 22, "0xFFFFFF73", y, 560, "left")
    y = y + heightOf(body) + 28
    ' Which build this is, before any sign-in exists, as upstream's connect
    ' screen: a support report has to be able to say.
    version = newLabel(NxVersionLabel(), "DMMono-Regular", 15, "0xFFFFFF40")
    version.translation = [0, y]
    g.AppendChild(version)
    y = y + heightOf(version)
    g.translation = [100, Int(540 - y / 2)]
end sub

' One control on the right: a button, a field or a tile, for focus moves.
sub addControl(id as String, row as Integer, x as Float, w as Float, enabled as Boolean)
    m.controls.Push({ id: id, row: row, x: x, w: w, enabled: enabled })
end sub

function isFocused(id as String) as Boolean
    return m.focusId = id
end function

' A button in OnboardingButtonStyle at y in the column; returns its height.
' role: primary, secondary or quiet. o: { width (default the column), x,
' fontSize, quietFocus, enabled, detail (a second, smaller line), row }.
function addButton(col as Object, id as String, label as String, role as String, y as Float, o as Object) as Float
    focused = isFocused(id)
    quietFocus = NxTruthy(o.quietFocus)
    slab = focused and not quietFocus
    enabled = true
    if NxSignInIsBool(o.enabled) then enabled = o.enabled
    size = 28
    padV = 20
    padH = 36
    if role = "primary" then
        size = 34
        padV = 24
    else if role = "quiet" then
        size = 24
        padV = 12
        padH = 28
    end if
    if o.fontSize <> invalid then size = o.fontSize
    textH = lineHeight("DMMono-Medium", size)
    detailH = 0
    if o.detail <> invalid then detailH = 6 + lineHeight("DMMono-Regular", 20)
    h = textH + detailH + 2 * padV
    if role = "quiet" then
        w = textWidth(label, "DMMono-Medium", size) + 2 * padH
    else if o.width <> invalid then
        w = o.width
    else
        w = m.colInner
    end if
    x = (m.colInner - w) / 2
    if o.x <> invalid then x = o.x

    g = CreateObject("roSGNode", "Group")
    g.translation = [x, y]
    g.scaleRotateCenter = [w / 2, h / 2]
    if focused then
        if quietFocus then g.scale = [1.04, 1.04] else g.scale = [1.07, 1.07]
    end if
    if not enabled then g.opacity = 0.35
    cyan = m.cyan + "FF"
    if role = "quiet" then
        if slab then g.AppendChild(newPatch("ob_pill.9.png", cyan, 1.0, 0, 0, w, h, 44))
        if focused and quietFocus then g.AppendChild(newPatch("ob_pill_ring.9.png", cyan, 1.0, 0, 0, w, h, 32))
    else
        if slab then
            g.AppendChild(newPatch("ob_slab.9.png", cyan, 1.0, 0, 0, w, h, 44))
        else
            fill = 0.03
            if focused then fill = 0.07
            g.AppendChild(newPatch("ob_fill.9.png", "0xFFFFFFFF", fill, 0, 0, w, h, 0))
        end if
        if focused and quietFocus then
            g.AppendChild(newPatch("ob_ring.9.png", cyan, 1.0, 0, 0, w, h, 32))
        else if not focused then
            if role = "primary" then
                g.AppendChild(newPatch("ob_edge_primary.9.png", cyan, 0.75, 0, 0, w, h, 0))
            else
                g.AppendChild(newPatch("ob_edge.9.png", "0xFFFFFFFF", 0.28, 0, 0, w, h, 0))
            end if
        end if
    end if
    color = "0xFFFFFFFF"
    if slab then
        color = "0x000F17FF"
    else if not focused then
        if role = "primary" then
            color = cyan
        else if role = "secondary" then
            color = "0xFFFFFF9E"
        else
            color = "0xFFFFFF6B"
        end if
    end if
    lbl = newLabel(label, "DMMono-Medium", size, color)
    lbl.width = w - 2 * padH
    lbl.horizAlign = "center"
    lbl.translation = [padH, padV]
    g.AppendChild(lbl)
    if o.detail <> invalid then
        d = newLabel(o.detail, "DMMono-Regular", 20, color)
        d.opacity = 0.75
        d.width = w - 2 * padH
        d.horizAlign = "center"
        d.translation = [padH, padV + textH + 6]
        g.AppendChild(d)
    end if
    col.AppendChild(g)
    row = m.rowCount
    if o.row <> invalid then row = o.row else m.rowCount = m.rowCount + 1
    addControl(id, row, x, w, enabled)
    return h
end function

' A text field drawn as OnboardingField: the caption, then a well. Focused:
' a dark well with a cyan frame and glow, white text and a caret. Not: a dim
' well with a thin grey edge. OK on it opens the TV's keyboard.
function addField(col as Object, id as String, caption as String, placeholder as String, text as String, secure as Boolean, y as Float) as Float
    focused = isFocused(id)
    w = m.colInner
    g = CreateObject("roSGNode", "Group")
    g.translation = [0, y]
    capColor = "0xFFFFFF73"
    if focused then capColor = m.cyan + "FF"
    cap = newLabel(caption, "DMMono-Medium", 20, capColor)
    g.AppendChild(cap)
    capH = heightOf(cap)
    wy = capH + 10
    if focused then
        g.AppendChild(newPatch("ob_fill.9.png", "0x081A21FF", 1.0, 0, wy, w, 78, 0))
        g.AppendChild(newPatch("ob_field_ring.9.png", m.cyan + "FF", 1.0, 0, wy, w, 78, 44))
    else
        g.AppendChild(newPatch("ob_fill.9.png", "0x0F0F0FFF", 1.0, 0, wy, w, 78, 0))
        g.AppendChild(newPatch("ob_edge.9.png", "0xFFFFFFFF", 0.18, 0, wy, w, 78, 0))
    end if
    shown = text
    if secure then
        shown = ""
        for i = 1 to Len(text)
            shown = shown + Chr(8226)
        end for
    end if
    textY = wy + (78 - lineHeight("DMMono-Regular", 28)) / 2
    caretX = 26
    if text = "" then
        if focused then caretX = 26 + 7
        ph = newLabel(placeholder, "DMMono-Regular", 28, "0xFFFFFF7A")
        if focused then ph.color = "0xFFFFFF99"
        ph.translation = [caretX, textY]
        g.AppendChild(ph)
        caretX = 26
    else
        t = newLabel(shown, "DMMono-Regular", 28, "0xFFFFFFC7")
        if focused then t.color = "0xFFFFFFFF"
        t.width = w - 60
        t.translation = [26, textY]
        g.AppendChild(t)
        tw = t.boundingRect().width
        if tw > w - 60 then tw = w - 60
        caretX = 26 + tw + 4
    end if
    if focused then
        caret = CreateObject("roSGNode", "Rectangle")
        caret.color = "0xFFFFFFE6"
        caret.width = 3
        caret.height = 34
        caret.translation = [caretX, wy + 22]
        g.AppendChild(caret)
        g.scaleRotateCenter = [w / 2, wy + 39]
        g.scale = [1.04, 1.04]
    end if
    col.AppendChild(g)
    addControl(id, m.rowCount, 0, w, true)
    m.rowCount = m.rowCount + 1
    return wy + 78
end function

' WAITING FOR ..., cyan, its dots counting up every half second.
function addWaiting(col as Object, message as String, y as Float) as Float
    lbl = addText(col, message, "DMMono-Medium", 24, "0x00C4FFFF", y, m.colInner)
    m.wait = lbl
    m.waitBase = message
    lbl.text = message + m.dots
    return lineHeight("DMMono-Medium", 24)
end function

sub onWaitTick()
    if m.wait = invalid then return
    if Len(m.dots) >= 3 then m.dots = "" else m.dots = m.dots + "."
    m.wait.text = m.waitBase + m.dots
end sub

' A sign-in code as upstream draws it: 108 pt, white, 16 px between digits.
function addCode(col as Object, code as String, x as Float, y as Float, centred as Boolean) as Float
    advance = textWidth("0", "DMMono-Medium", 108) + 16
    total = Len(code) * advance - 16
    if centred then x = (m.colInner - total) / 2
    for i = 1 to Len(code)
        d = newLabel(Mid(code, i, 1), "DMMono-Medium", 108, "0xFFFFFFFF")
        d.translation = [x + (i - 1) * advance, y]
        col.AppendChild(d)
    end for
    return lineHeight("DMMono-Medium", 108)
end function

' The plex.tv/link address with the code as a QR code, 200 px square on
' white, SCAN TO CONNECT under it (QRCodeView). One rectangle per run.
function addQr(col as Object, code as String, x as Float, y as Float) as Float
    g = CreateObject("roSGNode", "Group")
    g.translation = [x, y]
    side = 200
    url = "https://www.plex.tv/link/"
    if code <> "" then url = "https://www.plex.tv/link/?pin=" + code
    modules = NxQrMatrix(url)
    bg = CreateObject("roSGNode", "Rectangle")
    bg.width = side
    bg.height = side
    bg.color = "0xFFFFFFFF"
    g.AppendChild(bg)
    if modules <> invalid then
        size = modules.Count()
        ' Two light modules of quiet zone each side, inside the white square.
        cell = side \ (size + 4)
        origin = (side - cell * size) \ 2
        for row = 0 to size - 1
            line = modules[row]
            cx = 0
            while cx < size
                if line[cx] then
                    start = cx
                    while cx < size and line[cx]
                        cx = cx + 1
                    end while
                    r = CreateObject("roSGNode", "Rectangle")
                    r.translation = [origin + start * cell, origin + row * cell]
                    r.width = (cx - start) * cell
                    r.height = cell
                    r.color = "0x000000FF"
                    g.AppendChild(r)
                else
                    cx = cx + 1
                end if
            end while
        end for
    end if
    cap = newLabel(m.copy.plexScan, "DMMono-Regular", 20, "0x8E8E9399")
    cap.width = side
    cap.horizAlign = "center"
    cap.translation = [0, side + 12]
    g.AppendChild(cap)
    col.AppendChild(g)
    return side + 12 + heightOf(cap)
end function

' ── The right half ─────────────────────────────────────────────────────────

' Draws the right half for where the flow is, then keeps focus on a control
' that is there: the screen's first choice when it isn't
' (NxSignInDefaultFocus), as upstream moves focus on every section change.
sub render()
    build()
    if not focusValid() then
        m.focusId = NxSignInDefaultFocus(focusState())
        if not focusValid() then m.focusId = firstEnabled()
        build()
    end if
    print "signin: screen "; m.screen; " "; m.auth; " "; m.discovery; ", focus "; m.focusId
end sub

function focusState() as Object
    users = 0
    if m.server <> invalid then users = m.server.users.Count()
    return { screen: m.screen, auth: m.auth, discovery: m.discovery, picked: m.picked <> invalid, users: users, typingName: m.typingName }
end function

function focusValid() as Boolean
    for each c in m.controls
        if c.id = m.focusId and c.enabled then return true
    end for
    return false
end function

function firstEnabled() as String
    for each c in m.controls
        if c.enabled then return c.id
    end for
    return ""
end function

sub build()
    col = m.top.FindNode("right")
    col.RemoveChildrenIndex(col.GetChildCount(), 0)
    m.controls = []
    m.rowCount = 0
    m.wait = invalid
    width = 720
    if m.auth = "quick" then
        width = 760
    else if m.auth = "" and m.screen = "picker" then
        width = 600
    end if
    m.colInner = width
    if m.auth = "quick" then
        h = buildQuick(col)
    else if m.auth = "signing" then
        h = buildWaiting(col, m.copy.signingIn)
    else if m.auth = "plex" then
        h = buildPlex(col)
    else if m.auth = "checking" then
        h = buildWaiting(col, NxSignInConnecting(m.checkingLabel))
    else if m.screen = "find" then
        h = buildFind(col)
    else if m.screen = "type" then
        h = buildType(col)
    else if m.screen = "signin" then
        h = buildSignIn(col)
    else if m.screen = "plexCreds" then
        h = buildPlexCreds(col)
    else
        h = buildPicker(col)
    end if
    col.translation = [Int(m.colX + (m.colW - m.colInner) / 2), Int(540 - h / 2)]
    if m.wait <> invalid then m.waitTimer.control = "start" else m.waitTimer.control = "stop"
end sub

function stepTitle(col as Object, text as String, y as Float) as Float
    return heightOf(addText(col, text, "DMMono-Medium", 34, m.cyan + "FF", y, m.colInner))
end function

function caption(col as Object, text as String, y as Float) as Float
    return heightOf(addText(col, text, "DMMono-Medium", 20, "0xFFFFFF73", y, m.colInner))
end function

function buildPicker(col as Object) as Float
    y = 0
    if m.authError <> "" then
        y = y + heightOf(addText(col, UCase(m.authError), "DMMono-Medium", 26, "0xFF2244FF", y, m.colInner)) + 22
    end if
    y = y + addButton(col, "plex", m.copy.connectPlex, "primary", y, {}) + 22
    y = y + addButton(col, "plexCreds", m.copy.useEmailPassword, "secondary", y, {}) + 22 + 10
    y = y + heightOf(addText(col, m.copy.orConnectWith, "DMMono-Regular", 20, "0xFFFFFF59", y, m.colInner)) + 22
    y = y + addButton(col, "jellyfin", "JELLYFIN", "secondary", y, {}) + 22
    y = y + addButton(col, "emby", "EMBY", "secondary", y, {})
    return y
end function

' SIGN IN TO PLEX: email and password straight to plex.tv, the other way
' in next to the link code. The SSO line is always on screen, not only
' after a failed try, since a 401 from plex.tv looks the same whether the
' password was wrong or the account has none at all (Google or Apple
' sign-in); the Roku can't tell those apart, so the note goes up front.
function buildPlexCreds(col as Object) as Float
    y = stepTitle(col, "SIGN IN TO PLEX", 0) + 22
    y = y + heightOf(addText(col, m.copy.plexCredsNote, "DMMono-Regular", 19, "0xFFFFFF66", y, m.colInner)) + 22
    if m.authError <> "" then y = y + heightOf(addText(col, UCase(m.authError), "DMMono-Medium", 22, "0xFF2244FF", y, m.colInner)) + 22
    y = y + addField(col, "plexEmail", m.copy.plexEmailLabel, m.copy.pressToType, m.plexEmail, false, y) + 20
    y = y + addField(col, "plexPw", m.copy.password, m.copy.pressToType, m.plexPw, true, y) + 20
    y = y + addButton(col, "plexCredsSignIn", m.copy.signIn, "primary", y, { enabled: m.plexEmail.Trim() <> "" and m.plexPw <> "" }) + 20 + 6
    y = y + addButton(col, "back", m.copy.back, "quiet", y, {})
    return y
end function

function buildFind(col as Object) as Float
    y = stepTitle(col, NxSignInConnectTitle(m.kind), 0) + 22
    y = y + heightOf(addText(col, NxSignInFindIntro(m.kind), "DMMono-Regular", 22, "0xFFFFFF80", y, m.colInner)) + 22
    if m.flowMessage <> "" then y = y + heightOf(addText(col, m.flowMessage, "DMMono-Regular", 20, "0xFFB020F2", y, m.colInner)) + 22
    if m.discovery = "several" then
        y = y + caption(col, m.copy.pickServer, y) + 22
        for i = 0 to m.found.Count() - 1
            s = m.found[i]
            y = y + addButton(col, "found-" + i.ToStr(), s.name, "secondary", y, { detail: s.address }) + 22
        end for
    end if
    if m.discovery = "none" then y = y + heightOf(addText(col, m.copy.noneFound, "DMMono-Regular", 20, "0xFFB020F2", y, m.colInner)) + 22
    label = m.copy.findButton
    role = "primary"
    if m.discovery = "searching" then
        label = m.copy.searching
    else if m.discovery = "none" or m.discovery = "several" then
        label = m.copy.searchAgain
        role = "secondary"
    end if
    y = y + addButton(col, "find", label, role, y, {}) + 22
    y = y + addButton(col, "type", m.copy.typeAddress, "secondary", y, {}) + 22 + 6
    y = y + addButton(col, "back", m.copy.back, "quiet", y, {})
    return y
end function

function buildType(col as Object) as Float
    y = stepTitle(col, NxSignInConnectTitle(m.kind), 0) + 24
    if m.flowMessage <> "" then y = y + heightOf(addText(col, m.flowMessage, "DMMono-Regular", 20, "0xFFB020F2", y, m.colInner)) + 24
    y = y + addField(col, "address", m.copy.addressTitle, m.copy.addressPlaceholder, m.address, false, y) + 24
    y = y + heightOf(addText(col, m.copy.addressHint, "DMMono-Regular", 19, "0xFFFFFF66", y, m.colInner)) + 24
    y = y + addButton(col, "connect", m.copy.connect, "primary", y, { enabled: m.address.Trim() <> "" }) + 24 + 6
    y = y + addButton(col, "back", m.copy.back, "quiet", y, {})
    return y
end function

function buildSignIn(col as Object) as Float
    s = m.server
    y = caption(col, m.copy.signInTo, 0) + 6
    y = y + heightOf(addText(col, UCase(s.name), "DMMono-Medium", 34, m.cyan + "FF", y, m.colInner)) + 6
    y = y + heightOf(addText(col, UCase(NxKindName(s.kind)) + "  " + s.url, "DMMono-Regular", 18, "0xFFFFFF59", y, m.colInner)) + 20
    if m.flowMessage <> "" then y = y + heightOf(addText(col, m.flowMessage, "DMMono-Regular", 19, "0xFFFFFF8C", y, m.colInner)) + 20
    if m.authError <> "" then y = y + heightOf(addText(col, UCase(m.authError), "DMMono-Medium", 22, "0xFF2244FF", y, m.colInner)) + 20
    tiles = s.users.Count() > 0 and not m.typingName
    if tiles then
        y = y + caption(col, m.copy.whoIsWatching, y) + 20
        y = y + addTiles(col, y) + 20
    else
        y = y + addField(col, "username", m.copy.username, m.copy.pressToType, m.username, false, y) + 20
    end if
    passwordOn = not tiles
    if m.picked <> invalid then passwordOn = m.picked.hasPassword
    if passwordOn then
        cap = m.copy.password
        if m.picked <> invalid then cap = "PASSWORD FOR " + UCase(m.picked.name)
        y = y + addField(col, "password", cap, m.copy.pressToType, m.password, true, y) + 20
        y = y + addButton(col, "signin", m.copy.signIn, "primary", y, { enabled: m.picked <> invalid or m.username.Trim() <> "" }) + 20
    end if
    if NxSignInOffersQuickConnect(s.kind, s.quickConnect) then
        y = y + addButton(col, "quick", m.copy.useQuickConnect, "secondary", y, {}) + 20
    end if
    y = y + 6 + addButton(col, "back", m.copy.back, "quiet", y + 6, {})
    return y
end function

' The server's users as tiles, three to a row, then SOMEONE ELSE (up to eight
' users, as upstream). Left and right move along a row.
function addTiles(col as Object, y as Float) as Float
    users = []
    for i = 0 to m.server.users.Count() - 1
        if i < 8 then users.Push(i)
    end for
    users.Push(-1)
    top = y
    i = 0
    while i < users.Count()
        n = users.Count() - i
        if n > 3 then n = 3
        w = (m.colInner - 16 * (n - 1)) / n
        row = m.rowCount
        rowH = 0
        for k = 0 to n - 1
            idx = users[i + k]
            x = k * (w + 16)
            if idx < 0 then
                h = addButton(col, "someone", m.copy.someoneElse, "secondary", y, { width: w, x: x, fontSize: 22, row: row })
            else
                u = m.server.users[idx]
                role = "secondary"
                if m.picked <> invalid then
                    if m.picked.id = u.id then role = "primary"
                end if
                h = addButton(col, "user-" + idx.ToStr(), u.name, role, y, { width: w, x: x, fontSize: 26, row: row })
            end if
            if h > rowH then rowH = h
        end for
        m.rowCount = m.rowCount + 1
        y = y + rowH + 16
        i = i + n
    end while
    return y - 16 - top
end function

function buildQuick(col as Object) as Float
    y = stepTitle(col, m.copy.quickConnectTitle, 0) + 22
    y = y + heightOf(addText(col, m.copy.quickConnectSteps, "DMMono-Regular", 22, "0xFFFFFF99", y, m.colInner)) + 22
    code = m.qcCode
    if code = "" then code = "------"
    y = y + addCode(col, code, 0, y, true) + 22
    y = y + addWaiting(col, m.copy.waitingForApproval, y) + 22
    if m.server <> invalid then
        y = y + heightOf(addText(col, UCase(m.server.name) + "  " + m.server.url, "DMMono-Regular", 18, "0xFFFFFF59", y, m.colInner)) + 22
    end if
    y = y + 10 + addButton(col, "usePassword", m.copy.usePassword, "secondary", y + 10, { quietFocus: true }) + 22
    y = y + addButton(col, "back", m.copy.back, "quiet", y, { quietFocus: true })
    return y
end function

function buildWaiting(col as Object, message as String) as Float
    y = addWaiting(col, message, 0) + 28
    y = y + addButton(col, "cancel", m.copy.cancel, "quiet", y, {})
    return y
end function

' plex.tv/link: the code, what it's waiting for and CANCEL, the QR code to the
' right (pinDisplaySection). MainScene's PlexSignInTask drives it.
function buildPlex(col as Object) as Float
    state = m.top.plexState
    code = m.top.plexCode
    if code = "" then code = "----"
    waiting = m.copy.plexWaiting
    if state = "finding" then
        waiting = m.copy.plexFinding
    else if m.top.plexCode = "" then
        waiting = m.copy.plexConnecting
    end if
    goW = textWidth(m.copy.plexGoTo, "DMMono-Medium", 28)
    codeW = Len(code) * (textWidth("0", "DMMono-Medium", 108) + 16) - 16
    waitW = textWidth(m.copy.plexWaiting + "...", "DMMono-Medium", 24)
    leftW = goW
    if codeW > leftW then leftW = codeW
    if waitW > leftW then leftW = waitW
    total = leftW + 80 + 200
    m.colInner = total
    lft = CreateObject("roSGNode", "Group")
    col.AppendChild(lft)
    y = heightOf(addText(lft, m.copy.plexGoTo, "DMMono-Medium", 28, m.cyan + "FF", 0, leftW, "left")) + 24
    y = y + addCode(lft, code, 0, y, false) + 24
    lbl = addText(lft, waiting, "DMMono-Medium", 24, "0x00C4FFFF", y, leftW, "left")
    m.wait = lbl
    m.waitBase = waiting
    lbl.text = waiting + m.dots
    y = y + lineHeight("DMMono-Medium", 24) + 24
    saved = m.colInner
    m.colInner = leftW
    y = y + addButton(lft, "cancel", m.copy.cancel, "quiet", y, { quietFocus: true, x: 0 })
    m.colInner = saved
    qrH = addQr(col, m.top.plexCode, leftW + 80, 0)
    h = y
    if qrH > h then h = qrH
    ' Both halves centred on each other, as the HStack does.
    lft.translation = [0, (h - y) / 2]
    col.GetChild(col.GetChildCount() - 1).translation = [leftW + 80, (h - qrH) / 2]
    return h
end function

' ── Moving around ──────────────────────────────────────────────────────────

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if m.keyboard <> invalid then return false
    if key = "up" or key = "down" or key = "left" or key = "right" then
        moveFocus(key)
        return true
    end if
    if key = "OK" then
        activate(m.focusId)
        return true
    end if
    if key = "back" then return goBack()
    return false
end function

' Up and down go to the nearest enabled control in the next row that has
' one; left and right along a row (the user tiles).
sub moveFocus(key as String)
    cur = invalid
    for each c in m.controls
        if c.id = m.focusId then cur = c
    end for
    if cur = invalid then return
    best = invalid
    if key = "left" or key = "right" then
        for each c in m.controls
            if c.enabled and c.row = cur.row and c.id <> cur.id then
                if (key = "right" and c.x > cur.x) or (key = "left" and c.x < cur.x) then
                    if best = invalid or Abs(c.x - cur.x) < Abs(best.x - cur.x) then best = c
                end if
            end if
        end for
    else
        target = invalid
        for each c in m.controls
            if c.enabled and ((key = "down" and c.row > cur.row) or (key = "up" and c.row < cur.row)) then
                if target = invalid or Abs(c.row - cur.row) < Abs(target - cur.row) then target = c.row
            end if
        end for
        if target <> invalid then
            centre = cur.x + cur.w / 2
            for each c in m.controls
                if c.enabled and c.row = target then
                    if best = invalid or Abs(c.x + c.w / 2 - centre) < Abs(best.x + best.w / 2 - centre) then best = c
                end if
            end for
        end if
    end if
    if best = invalid then return
    m.focusId = best.id
    render()
end sub

sub activate(id as String)
    if id = "" then return
    for each c in m.controls
        if c.id = id and not c.enabled then return
    end for
    if id = "plex" then
        m.top.done = "plex"
    else if id = "plexCreds" then
        m.kind = "plex"
        go("plexCreds")
        render()
    else if id = "plexEmail" or id = "plexPw" then
        openKeyboard(id)
    else if id = "plexCredsSignIn" then
        plexPasswordSignIn()
    else if id = "jellyfin" or id = "emby" then
        m.kind = id
        go("find")
        findServers()
    else if id = "find" then
        findServers()
    else if id = "type" then
        go("type")
        render()
    else if Left(id, 6) = "found-" then
        s = m.found[Mid(id, 7).ToInt()]
        checkServer(s.address, s.name)
    else if id = "address" or id = "username" or id = "password" then
        openKeyboard(id)
    else if id = "connect" then
        submitAddress()
    else if id = "signin" then
        signIn()
    else if id = "quick" then
        startQuickConnect()
    else if Left(id, 5) = "user-" then
        pickUser(m.server.users[Mid(id, 6).ToInt()])
    else if id = "someone" then
        m.picked = invalid
        m.typingName = true
        m.username = ""
        m.focusId = "username"
        render()
    else if id = "usePassword" then
        stopTask()
        m.auth = ""
        if m.server.users.Count() > 0 and not m.typingName then m.focusId = "user-0" else m.focusId = "username"
        render()
    else if id = "back" or id = "cancel" then
        goBack()
    end if
end sub

' BACK and CANCEL, and the remote's Back: one step back, as upstream's buttons.
function goBack() as Boolean
    if m.auth = "checking" then
        stopTask()
        stopPlexTask()
        m.auth = ""
        m.checkingLabel = ""
        m.focusId = ""
        render()
    else if m.auth = "signing" then
        stopTask()
        stopPlexTask()
        m.auth = ""
        m.focusId = ""
        render()
    else if m.auth = "quick" then
        go("find")
        render()
    else if m.auth = "plex" then
        m.auth = ""
        m.top.plexCancel = true
        go("picker")
        render()
    else if m.screen = "find" then
        go("picker")
        render()
    else if m.screen = "type" or m.screen = "signin" then
        go("find")
        render()
    else if m.screen = "plexCreds" then
        go("picker")
        render()
    else
        return false
    end if
    return true
end function

' A new screen, as upstream's go(to:): anything in flight is dropped, the
' sign-in fields are cleared (the typed address stays), and focus moves to
' the screen's first choice. Coming back to find does not search again, or
' one server answering would bounce the viewer straight back.
sub go(nextScreen as String)
    stopTask()
    stopPlexTask()
    if m.fixtureTimer <> invalid then m.fixtureTimer.control = "stop"
    m.auth = ""
    m.checkingLabel = ""
    m.discovery = "idle"
    m.flowMessage = ""
    m.authError = ""
    m.username = ""
    m.password = ""
    m.plexEmail = ""
    m.plexPw = ""
    m.picked = invalid
    m.typingName = false
    m.qcCode = ""
    m.screen = nextScreen
    m.focusId = ""
end sub

' ── The flow ───────────────────────────────────────────────────────────────

sub findServers()
    if m.discovery = "searching" then return
    m.flowMessage = ""
    m.authError = ""
    m.discovery = "searching"
    m.focusId = ""
    fixture = NxSignInDiscoveryFixture(m.top.discoveryFixture)
    if fixture <> invalid then
        ' The tour's stand-in answers after a second, as upstream's.
        m.fixture = fixture
        if m.fixtureTimer = invalid then
            m.fixtureTimer = CreateObject("roSGNode", "Timer")
            m.fixtureTimer.duration = 1
            m.fixtureTimer.ObserveField("fire", "onFixture")
            m.top.AppendChild(m.fixtureTimer)
        end if
        m.fixtureTimer.control = "start"
    else
        runTask("discover")
    end if
    render()
end sub

sub onFixture()
    if m.screen = "find" and m.discovery = "searching" then onDiscovered(m.fixture)
end sub

sub onDiscovered(list as Object)
    if m.screen <> "find" then return
    out = NxSignInOutcome(list)
    print "signin: search found "; out.servers.Count(); " servers ("; list.Count(); " answers)"
    if out.kind = "single" then
        m.discovery = "idle"
        s = out.servers[0]
        checkServer(s.address, s.name)
        return
    end if
    m.discovery = out.kind
    m.found = out.servers
    m.focusId = ""
    render()
end sub

sub submitAddress()
    typed = m.address.Trim()
    if typed = "" then
        render()
        return
    end if
    checkServer(typed, typed)
end sub

' Asks the address who it is, then opens the right way in. On failure the
' viewer stays on the screen they came from, with the reason.
sub checkServer(address as String, label as String)
    m.flowMessage = ""
    m.authError = ""
    m.checkingLabel = label
    m.auth = "checking"
    m.focusId = ""
    runTask("probe", address)
    render()
end sub

sub open(server as Object)
    asked = m.kind
    go("signin")
    m.server = server
    m.kind = server.kind
    if server.kind <> asked then m.flowMessage = NxSignInSwitchedKind(server.kind)
    if NxSignInPreferredMethod(server.kind, server.quickConnect) = "quickConnect" then
        startQuickConnect()
    else
        render()
    end if
end sub

sub startQuickConnect()
    m.authError = ""
    m.auth = "quick"
    m.qcCode = ""
    m.focusId = ""
    runTask("quickConnect")
    render()
end sub

sub pickUser(user as Object)
    m.picked = user
    m.username = user.name
    m.password = ""
    if user.hasPassword then
        m.focusId = "password"
        render()
    else
        signIn()
    end if
end sub

sub signIn()
    name = m.username
    if m.picked <> invalid then name = m.picked.name
    if name.Trim() = "" then return
    m.authError = ""
    m.auth = "signing"
    m.focusId = ""
    runTask("password", name, m.password)
    render()
end sub

' ── The keyboard ───────────────────────────────────────────────────────────

' The TV's keyboard for a field. Closing it, with OK or Back, keeps what was
' typed and moves on, as closing the Apple TV's does.
sub openKeyboard(field as String)
    kb = CreateObject("roSGNode", "StandardKeyboardDialog")
    if field = "address" then
        kb.title = m.copy.addressTitle
        kb.message = [m.copy.addressHint]
        kb.text = m.address
    else if field = "username" then
        kb.title = m.copy.username
        kb.text = m.username
    else if field = "plexEmail" then
        kb.title = m.copy.plexEmailLabel
        kb.text = m.plexEmail
    else if field = "plexPw" then
        kb.title = m.copy.password
        kb.text = m.plexPw
        kb.textEditBox.secureMode = true
        ' Voice keyboards take it as a password (Roku certification 4.12).
        kb.keyboardDomain = "password"
    else
        kb.title = m.copy.password
        if m.picked <> invalid then kb.title = "PASSWORD FOR " + UCase(m.picked.name)
        kb.text = m.password
        kb.textEditBox.secureMode = true
        ' Voice keyboards take it as a password (Roku certification 4.12).
        kb.keyboardDomain = "password"
    end if
    kb.buttons = ["OK"]
    kb.ObserveField("buttonSelected", "onKeyboardButton")
    kb.ObserveField("wasClosed", "onKeyboardClosed")
    m.keyboardField = field
    m.keyboard = kb
    m.top.GetScene().dialog = kb
end sub

sub onKeyboardButton()
    keyboardDone(true)
end sub

sub onKeyboardClosed()
    keyboardDone(false)
end sub

' viaOK: the keyboard's OK, upstream's Done. On the password it signs in;
' Back moves to SIGN IN instead.
sub keyboardDone(viaOK as Boolean)
    kb = m.keyboard
    if kb = invalid then return
    text = kb.text
    ' Its closing notice can arrive after the next keyboard is up, and would
    ' close that one too.
    kb.UnobserveField("buttonSelected")
    kb.UnobserveField("wasClosed")
    kb.close = true
    m.keyboard = invalid
    m.top.SetFocus(true)
    field = m.keyboardField
    if field = "address" then
        m.address = text
        submitAddress()
    else if field = "username" then
        m.username = text
        m.focusId = "password"
        render()
    else if field = "plexEmail" then
        m.plexEmail = text
        m.focusId = "plexPw"
        render()
    else if field = "plexPw" then
        m.plexPw = text
        if viaOK then
            plexPasswordSignIn()
        else
            m.focusId = "plexCredsSignIn"
            render()
        end if
    else if field = "password" then
        m.password = text
        if viaOK then
            signIn()
        else
            m.focusId = "signin"
            render()
        end if
    end if
end sub

' ── The network ────────────────────────────────────────────────────────────

sub runTask(action as String, a = "" as String, b = "" as String)
    stopTask()
    t = CreateObject("roSGNode", "MediaBrowserSignInTask")
    t.action = action
    t.kind = m.kind
    t.dryRun = m.top.dryRun
    if action = "probe" then t.address = a
    if m.server <> invalid then t.server = { kind: m.server.kind, base: m.server.url, name: m.server.name, id: m.server.id }
    if action = "password" then
        t.username = a
        t.password = b
    end if
    t.ObserveField("status", "onTaskStatus")
    m.task = t
    t.control = "run"
end sub

sub stopTask()
    if m.task = invalid then return
    m.task.UnobserveField("status")
    m.task.cancel = true
    m.task = invalid
end sub

sub onTaskStatus()
    t = m.task
    if t = invalid then return
    status = t.status
    if status = "found" then
        list = []
        for each s in t.found
            list.Push(s)
        end for
        stopTask()
        onDiscovered(list)
    else if status = "checked" then
        server = t.server
        stopTask()
        m.auth = ""
        m.checkingLabel = ""
        open(server)
    else if status = "code" then
        m.qcCode = t.code
        render()
    else if status = "signedIn" then
        stopTask()
        m.top.done = m.kind
    else if status = "error" then
        message = t.message
        stopTask()
        if m.auth = "quick" or m.auth = "signing" then
            m.authError = message
        else
            m.flowMessage = message
        end if
        m.auth = ""
        m.checkingLabel = ""
        m.focusId = ""
        render()
    end if
end sub

' ── Plex, on-device ─────────────────────────────────────────────────────────

sub plexPasswordSignIn()
    email = m.plexEmail.Trim()
    pw = m.plexPw
    if email = "" or pw = "" then return
    m.authError = ""
    m.auth = "signing"
    m.focusId = ""
    runPlexTask(email, pw)
    render()
end sub

sub runPlexTask(email as String, pw as String)
    stopPlexTask()
    t = CreateObject("roSGNode", "PlexSignInTask")
    t.mode = "password"
    t.email = email
    t.password = pw
    t.ObserveField("status", "onPlexTaskStatus")
    m.plexTask = t
    t.control = "run"
end sub

' Stops the task's thread outright, as MainScene's own cancel of the link
' code does (m.signIn.control = "stop"): this run has no poll loop to let
' finish on its own, so there is nothing a cooperative cancel flag would add.
sub stopPlexTask()
    if m.plexTask = invalid then return
    m.plexTask.UnobserveField("status")
    m.plexTask.control = "stop"
    m.plexTask = invalid
end sub

sub onPlexTaskStatus()
    t = m.plexTask
    if t = invalid then return
    status = t.status
    if status = "ready" then
        stopPlexTask()
        m.top.done = "plexSignedIn"
    else if status = "error" then
        message = t.message
        stopPlexTask()
        m.authError = message
        m.auth = ""
        m.focusId = ""
        render()
    end if
end sub

' ── From MainScene ─────────────────────────────────────────────────────────

sub onNotice()
    m.authError = m.top.notice
    if m.screen = "picker" and m.auth = "" then render()
end sub

' Plex's code, as MainScene's PlexSignInTask reports it.
sub onPlex()
    if m.top.plexState = "" then
        if m.auth = "plex" then
            m.auth = ""
            m.focusId = ""
            render()
        end if
        return
    end if
    if m.auth <> "plex" then
        go("picker")
        m.auth = "plex"
    end if
    render()
end sub
