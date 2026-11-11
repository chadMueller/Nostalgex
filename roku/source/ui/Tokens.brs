' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' The Apple TV 1.0.32 design tokens (#262): one type scale, one colour list
' and one row, so the screens read names and not literals. The Apple TV keeps
' them in DesignTokens.swift; the numbers are #262's, ported and not
' redesigned. The manifest is ui_resolutions=fhd, so 1 Apple TV point is 1 px
' on the 1920 by 1080 canvas; a 720p output scales the whole canvas by 2/3.
'
' Colours are the Roku's 0xRRGGBBAA, all opaque: white with an opacity is
' not a text colour, and secondary text is text2 (textDim only for the guide
' grid's titles that are neither live nor on the focused row). A channel's
' own colour is never text. Every text colour is held to 4.5:1 on the
' surfaces it sits on by tests/DesignTokensTests.brs (NxTokContrast).

' The tokens, built once per thread.
function NxTokens() as Object
    g = GetGlobalAA()
    if g.nxTokens <> invalid then return g.nxTokens
    t = {}
    c = {}
    ' main text
    c.text = "0xFFFFFFFF"
    ' hints, resting values, section labels, OFF
    c.text2 = "0xB9C3DEFF"
    ' only the guide's titles neither live nor on the focused row
    c.textDim = "0x80879AFF"
    ' selection, ON, links
    c.cyan = "0x00D4FFFF"
    ' live things only (sleep countdown)
    c.yellow = "0xFFE500FF"
    ' warnings
    c.amber = "0xFFB020FF"
    ' danger as text
    c.redText = "0xFF6B81FF"
    ' danger fill or outline only, never text
    c.red = "0xFF2244FF"
    ' text on a solid cyan fill
    c.onCyan = "0x00101AFF"
    ' screen and panel background
    c.panel = "0x0A0F1EFF"
    ' a resting row
    c.row = "0x141B33FF"
    ' the row under the cursor
    c.selectedRow = "0x0B2A3AFF"
    ' chosen but not under the cursor
    c.chosenNeutral = "0x2B3760FF"
    ' a resting row's outline, a boundary and not text
    c.restingOutline = "0x3A4670FF"
    t.color = c
    ' The type scale, px. caption is the floor: nothing the viewer reads is
    ' smaller, but for the guide's rows (guideRow).
    t.size = { hero: 96, title: 44, heading: 34, body: 29, caption: 25, tag: 36 }
    ' Settings and the Now Playing panel: one step down the scale.
    t.compactSize = { title: 38, heading: 29, body: 25, tag: 31 }
    t.guideRow = 22
    t.font = { text: "DMMono-Regular", label: "DMMono-Medium", tag: "VT323-Regular" }
    ' The row. outline is the resting outline (1.5 pt on the Apple TV, 2 px
    ' here); the selected row has the selectedRow fill, a selectedOutline px
    ' cyan outline, a glow (images/look/focus.9.png, glow px at glowAlpha)
    ' and a lift of `lift` of its size.
    t.row = { height: 76, gap: 12, radius: 12, padSide: 28, outline: 2, selectedOutline: 3, glow: 30, glowAlpha: 0.55, lift: 0.03 }
    t.compactRow = { height: 64, gap: 10, radius: 12, padSide: 20, outline: 2, selectedOutline: 3, glow: 30, glowAlpha: 0.55, lift: 0.03 }
    g.nxTokens = t
    return t
end function

' The WCAG relative luminance of a Roku colour ("0xRRGGBBAA" or "#RRGGBB"),
' alpha ignored; invalid when it isn't one.
function NxTokLuminance(colour as Dynamic) as Dynamic
    if not NxIsString(colour) then return invalid
    h = UCase(colour)
    if Left(h, 2) = "0X" and Len(h) = 10 then
        h = Mid(h, 3)
    else if Left(h, 1) = "#" and Len(h) = 7 then
        h = Mid(h, 2)
    else
        return invalid
    end if
    digits = "0123456789ABCDEF"
    lum = 0.0
    weights = [0.2126, 0.7152, 0.0722]
    for i = 0 to 2
        hi = Instr(1, digits, Mid(h, 2 * i + 1, 1)) - 1
        lo = Instr(1, digits, Mid(h, 2 * i + 2, 1)) - 1
        if hi < 0 or lo < 0 then return invalid
        c = (hi * 16 + lo) / 255.0
        if c <= 0.03928 then c = c / 12.92 else c = ((c + 0.055) / 1.055) ^ 2.4
        lum = lum + weights[i] * c
    end for
    return lum
end function

' The WCAG contrast ratio of two colours, 1 to 21; invalid when either
' isn't a colour.
function NxTokContrast(a as Dynamic, b as Dynamic) as Dynamic
    la = NxTokLuminance(a)
    lb = NxTokLuminance(b)
    if la = invalid or lb = invalid then return invalid
    if la < lb then
        t = la
        la = lb
        lb = t
    end if
    return (la + 0.05) / (lb + 0.05)
end function

' Black or white for text on a solid fill (a channel's own colour), whichever
' has the higher contrast; white on a tie.
function NxTokTextOn(fill as Dynamic) as String
    white = "0xFFFFFFFF"
    black = "0x000000FF"
    w = NxTokContrast(white, fill)
    b = NxTokContrast(black, fill)
    if w = invalid or b = invalid then return white
    if b > w then return black
    return white
end function
