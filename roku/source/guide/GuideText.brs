' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' GUIDE TEXT SIZE (I-060), a Roku-only display choice in Settings: NORMAL, the
' Apple TV's sizes, or LARGE, for a couch further from the screen. Built in,
' two sizes and no choice of fonts. It sizes what the grid draws: the time
' header, the CHANNEL heading, each row's number and name, and the program
' titles. The panel above the grid stays as it is, its text is already laid out
' to fill 555 px.
'
' The saved choice is "large" under the guide's registry section; anything
' else, and a TV that never chose, is NORMAL.

function NxGuideTextLarge() as Boolean
    return NxGuideTextFrom(NxRegSection("guide").Read("textSize"))
end function

' From the saved value: only "large" is LARGE.
function NxGuideTextFrom(saved as String) as Boolean
    return saved = "large"
end function

sub NxSaveGuideTextLarge(on as Boolean)
    reg = NxRegSection("guide")
    if on then reg.Write("textSize", "large") else reg.Write("textSize", "normal")
    reg.Flush()
end sub

' The grid's shape (#263, the Apple TV 1.0.32's guide): rows 64 px tall, the
' time header 58, the channel column 340 wide and 395 px per 30 minutes, so
' four half hours fill the 1580 px after the column.
function NxGuideGeometry() as Object
    return { rowH: 64, headerH: 58, colX: 340, slotWidth: 395 }
end function

' The top of a line of text `size` px tall, centred in a space `height` px
' tall: the middle less half the line's height (about 1.3 times its size).
function NxGuideLineTop(height as Integer, size as Integer) as Integer
    return Int((height - size * 1.3) / 2 + 0.5)
end function

' The grid's type sizes and where each line sits, computed from the row and
' header heights (NxGuideGeometry), so the tops move with them. #263's sizes:
' NORMAL has titles, numbers and names at 22 and the times, the CHANNEL
' heading and the WATERSHED placeholder at 25; LARGE has them all at 29. The
' number box is three digits wide, 40 and 54. LARGE never moves a row or the
' column.
'   slot, slotY, slotH: a time label, and the rule beside it
'   title, titleY: a program's title
'   num, numW, numY: a channel's number, its width (three digits) and top
'   name, nameY, nameGap: the name, its top, and its start from the number's
'   head, headY: the CHANNEL heading
'   held, heldY: WATERSHED's placeholder (BROADCASTS RESUME AT 9 PM)
function NxGuideTextSizes(large as Boolean) as Object
    g = NxGuideGeometry()
    text = 22
    time = 25
    numW = 40
    if large then
        text = 29
        time = 29
        numW = 54
    end if
    return {
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
