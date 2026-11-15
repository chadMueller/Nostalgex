' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' GUIDE TEXT SIZE (I-060), a Settings choice with three steps, as the Apple TV's
' GuideTextSize (appletv/guide-text-three-steps): SMALLER, DEFAULT and LARGER,
' for a couch nearer or further from the screen. Built in, no choice of fonts.
' It sizes what the grid draws: the time header, the CHANNEL heading, each
' row's number and name, and the program titles. The panel above the grid stays
' as it is, its text is already laid out to fill 555 px.
'
' The saved choice is "small", "normal" or "large" under the guide's registry
' section: the middle step is labelled DEFAULT but keeps the raw value
' "normal", "large" is the old LARGE's value, and anything else (nothing saved,
' an unknown word) is "normal", so a TV that never chose draws the default.
' The Apple TV's sync carries the same three raw values.

' The saved step: "small", "normal" or "large".
function NxGuideTextStep() as String
    return NxGuideTextStepFrom(NxRegSection("guide").Read("textSize"))
end function

' From the saved value: "small" and "large" as they are, anything else normal.
function NxGuideTextStepFrom(saved as String) as String
    if saved = "small" or saved = "large" then return saved
    return "normal"
end function

' True when the saved step is LARGER (what the two-step setting called LARGE).
function NxGuideTextLarge() as Boolean
    return NxGuideTextStep() = "large"
end function

function NxGuideTextFrom(saved as String) as Boolean
    return NxGuideTextStepFrom(saved) = "large"
end function

' SMALLER > DEFAULT > LARGER > SMALLER, what OK does on the Settings row.
function NxGuideTextNext(level as String) as String
    if level = "small" then return "normal"
    if level = "normal" then return "large"
    return "small"
end function

' What the Settings row shows.
function NxGuideTextLabel(level as String) as String
    if level = "small" then return "SMALLER"
    if level = "large" then return "LARGER"
    return "DEFAULT"
end function

sub NxSaveGuideTextStep(level as String)
    reg = NxRegSection("guide")
    reg.Write("textSize", NxGuideTextStepFrom(level))
    reg.Flush()
end sub

' SMALLER's two numbers (the Apple TV's GuideTextMetrics.small, Chad 2026-11-14,
' "the smaller should be smaller"): row text 17 and the times, heading and
' placeholder 19, in a number box 31 wide. 18 and 20 (box 33) is the fallback if
' 17 and 19 read too thin from the couch: change these three and nothing else.
function NxGuideSmallerText() as Integer
    return 17
end function

function NxGuideSmallerTime() as Integer
    return 19
end function

function NxGuideSmallerNumW() as Integer
    return 31
end function

' The grid's shape (#263, the Apple TV 1.0.32's guide): rows 64 px tall, the
' time header 58, the channel column 340 wide and 395 px per 30 minutes, so
' four half hours fill the 1580 px after the column.
function NxGuideGeometry() as Object
    return { rowH: 64, headerH: 58, colX: 340, slotWidth: 395 }
end function

' The same by GUIDE TEXT SIZE step (Chad 2026-11-15, the Apple TV's
' integration-1115): LARGER grows the row to 76 and the time header to 66 with
' its 29 px text, so the text keeps the room 20 px has in 64 (about 23 above and
' below); SMALLER and DEFAULT keep 64 and 58. The channel column and the
' half-hour width do not move. The bundle list's rows follow the row; the Now
' Playing panel's rows stay 64 (NxPanelMetrics).
function NxGuideGeometryFor(level as String) as Object
    g = NxGuideGeometry()
    if level = "large" then
        g.rowH = 76
        g.headerH = 66
    end if
    return g
end function

' The top of a line of text `size` px tall, centred in a space `height` px
' tall: the middle less half the line's height (about 1.3 times its size).
function NxGuideLineTop(height as Integer, size as Integer) as Integer
    return Int((height - size * 1.3) / 2 + 0.5)
end function

' The grid's type sizes and where each line sits, computed from the row and
' header heights (NxGuideGeometry), so the tops move with them. The Apple TV's
' three steps (px at 1080p, DM Mono Medium):
'                         SMALLER  DEFAULT  LARGER
'   title, number, name      17       20       29
'   times, heading, held     19       22       29
'   number box (3 digits)    31       36       54
' Only LARGER moves a row (76) and the header (66); the column does not move and LARGER gives the name fewer characters.
'   slot, slotY, slotH: a time label, and the rule beside it
'   title, titleY: a program's title
'   num, numW, numY: a channel's number, its width (three digits) and top
'   name, nameY, nameGap: the name, its top, and its start from the number's
'   head, headY: the CHANNEL heading
'   held, heldY: WATERSHED's placeholder (BROADCASTS RESUME AT 9 PM)
'   pkgRow, pkgHead: the bundle list's rows and its BUNDLES heading
function NxGuideTextSizes(large as Boolean) as Object
    if large then return NxGuideTextSizesFor("large")
    return NxGuideTextSizesFor("normal")
end function

function NxGuideTextSizesFor(level as String) as Object
    text = 20
    time = 22
    numW = 36
    if level = "large" then
        text = 29
        time = 29
        numW = 54
    else if level = "small" then
        text = NxGuideSmallerText()
        time = NxGuideSmallerTime()
        numW = NxGuideSmallerNumW()
    end if
    ' The bundle list's rows and its BUNDLES heading follow the step too
    ' (the Apple TV's packageRowText and packageHeading): 17 and 19, 20 and 22,
    ' and LARGER's 22 and 25, as they were at LARGE.
    pkgRow = 20
    pkgHead = 22
    if level = "large" then
        pkgRow = 22
        pkgHead = 25
    else if level = "small" then
        pkgRow = text
        pkgHead = time
    end if
    g = NxGuideGeometryFor(level)
    return {
        rowH: g.rowH, headerH: g.headerH,
        pkgRow: pkgRow, pkgHead: pkgHead,
        slot: time, slotY: NxGuideLineTop(g.headerH, time), slotH: Int(time * 1.3 + 0.5),
        title: text, titleY: NxGuideLineTop(g.rowH, text),
        num: text, numW: numW, numY: NxGuideLineTop(g.rowH, text),
        name: text, nameY: NxGuideLineTop(g.rowH, text), nameGap: numW + 8,
        head: time, headY: NxGuideLineTop(g.headerH, time),
        held: time, heldY: NxGuideLineTop(g.rowH, time)
    }
end function

' The grid's surfaces, as GuideView draws them: the grid under its rows, the
' header, an even row's stripe, a past programme's tint and the alpha of a
' live programme's cell in the channel's colour. The lightest background an
' unfocused title sits on is the stripe and the past tint over the grid
' (NxGuideLightestTitleBg), which tests/GuideLookTests.brs holds textDim to.
function NxGuideColors() as Object
    return { grid: "0x0D0D1FFF", header: "0x0A0A14FF", stripe: "0xFFFFFF08", past: "0xFFFFFF05", liveAlpha: "40" }
end function

' The focused programme's cell on the focused row (the programme cursor, Chad
' 2026-11-15: "the active state needs to be way more obvious, can we have a
' glow"): a fill brighter than the row's selected fill, a full-cyan ring, and
' a glow much stronger than the row's own, made by stacking the glow image
' (images/look/focus.9.png: a cyan ring with its halo) `layers` times, each
' laid over the last. The numbers are the Apple TV agent's to give; these are
' the structure's starting values.
function NxGuideCursorStyle() as Object
    return { fill: "0x0F4C6AFF", ring: "0x00D4FFFF", layers: 3 }
end function

function NxGuideLightestTitleBg() as String
    c = NxGuideColors()
    return NxTokOver(c.past, NxTokOver(c.stripe, c.grid))
end function

' The focused row's fill (#263): the channel's colour ("#RRGGBB" or
' "RRGGBB") at 32% over the panel #0A0F1E, as the Apple TV's
' GuideRowContrast, darkened only if white titles fall under 4.5:1 on it
' (NxTokDarkenFor; none of channels.json's colours do). Anything else is
' white, as GuideView's colorOf.
function NxGuideFocusFill(hex as Dynamic) as String
    return NxTokDarkenFor(NxTokOverAt(NxGuideHex(hex), NxTokens().color.panel, 0.32), "0xFFFFFFFF", 4.5)
end function

' The live cell on the focused row: the channel's colour at 55% over that
' row's fill, darkened only as far as white titles need for 4.5:1.
function NxGuideFocusLiveFill(hex as Dynamic) as String
    return NxTokDarkenFor(NxTokOverAt(NxGuideHex(hex), NxGuideFocusFill(hex), 0.55), "0xFFFFFFFF", 4.5)
end function

' WATERSHED's placeholder on the focused row (#301, the Apple TV's
' GuideRowContrast.secondaryText): text2 where it reads 4.5:1 on the past
' tint over that row's fill, and otherwise brightened toward white only as
' far as 4.5:1 needs. An unfocused row's placeholder stays text2.
function NxGuideFocusHeldText(hex as Dynamic) as String
    band = NxTokOver(NxGuideColors().past, NxGuideFocusFill(hex))
    return NxTokLightenFor(NxTokens().color.text2, band, 4.5)
end function

' "#RRGGBB" from a channel's colour, with or without its #; white when it
' isn't one, as GuideView's colorOf.
function NxGuideHex(hex as Dynamic) as String
    h = "#" + NxToStr(hex).Replace("#", "")
    if NxTokRgba(h) = invalid then h = "#FFFFFF"
    return h
end function
