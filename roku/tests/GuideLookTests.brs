' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' The guide grid on the Apple TV 1.0.32's look (#263): its shape
' (NxGuideGeometry), textDim held to 4.5:1 on the grid's lightest background
' an unfocused title sits on (NxGuideLightestTitleBg), text2 on the CHANNEL
' heading and the WATERSHED placeholder's band, and for every distinct
' channel colour in channels.json the focused row's fill (NxGuideFocusFill,
' the Apple TV's 32% wash, never darkened) and its live cell
' (NxGuideFocusLiveFill, 55% over that, darkened no further than white
' needs) reading 4.5:1 with white titles, and WATERSHED's placeholder on
' that row (NxGuideFocusHeldText, #301) reading 4.5:1 on its band: text2
' where text2 does, brightened no further than needed where it doesn't. The
' colour helpers it rests on (NxTokOver, NxTokOverAt, NxTokDarkenFor,
' NxTokLightenFor) are checked first.
' Returns the failure count.

function NxRunGuideLookTests(channelsPath as String) as Integer
    r = { pass: 0, fail: 0 }
    tc = NxTokens().color

    ' The helpers: a translucent colour over another, and a fill darkened for a ratio.
    NxCheck(r, "over: white at half over black", NxToStr(NxTokOver("0xFFFFFF80", "0x000000FF")), "0x808080FF")
    NxCheck(r, "over: opaque hides the bottom", NxToStr(NxTokOver("0x123456FF", "0xFFFFFFFF")), "0x123456FF")
    NxCheck(r, "over: clear shows the bottom", NxToStr(NxTokOver("0xFFFFFF00", "0x0D0D1FFF")), "0x0D0D1FFF")
    NxCheck(r, "over: not a colour", NxToStr(NxTokOver("white", "0x000000FF") = invalid), "true")
    NxCheck(r, "over at: 32% ignores the top's own alpha", NxToStr(NxTokOverAt("0xFFFFFF00", "0x000000FF", 0.32)), "0x525252FF")
    NxCheck(r, "over at: not a colour", NxToStr(NxTokOverAt("#FFF", "0x000000FF", 0.5) = invalid), "true")
    NxCheck(r, "darken: a fill white already reads on is only made opaque", NxToStr(NxTokDarkenFor("#0064FF", "0xFFFFFFFF", 4.5)), "0x0064FFFF")
    w = NxTokDarkenFor("#FFFFFF", "0xFFFFFFFF", 4.5)
    NxCheck(r, "darken: white goes grey, just past 4.5:1", NxToStr(NxTokContrast("0xFFFFFFFF", w) >= 4.5 and NxTokContrast("0xFFFFFFFF", w) < 4.6), "true")
    NxCheck(r, "darken: not a colour", NxToStr(NxTokDarkenFor("#FFF", "0xFFFFFFFF", 4.5) = invalid), "true")
    NxCheck(r, "lighten: text that already reads is only made opaque", NxToStr(NxTokLightenFor("#B9C3DE", "0x0D0D1FFF", 4.5)), "0xB9C3DEFF")
    lit = NxTokLightenFor("#808080", "0x404040FF", 4.5)
    NxCheck(r, "lighten: grey goes lighter, just past 4.5:1", NxToStr(NxTokContrast(lit, "0x404040FF") >= 4.5 and NxTokContrast(lit, "0x404040FF") < 4.6), "true")
    NxCheck(r, "lighten: a ratio white can't reach ends at white", NxToStr(NxTokLightenFor("#808080", "0xC0C0C0FF", 4.5)), "0xFFFFFFFF")
    NxCheck(r, "lighten: not a colour", NxToStr(NxTokLightenFor("#FFF", "0x000000FF", 4.5) = invalid), "true")

    ' The shape: 64 px rows, a 58 px header, a 340 px column and four 395 px
    ' half hours filling the 1920 px row.
    g = NxGuideGeometry()
    NxCheck(r, "shape: #263's numbers", FormatJson([g.rowH, g.headerH, g.colX, g.slotWidth]), "[64,58,340,395]")
    NxCheck(r, "shape: four half hours fill the row after the column", NxToStr(g.colX + 4 * g.slotWidth), "1920")
    NxCheck(r, "shape: rows below the header in the 525 px grid", NxToStr((525 - (g.headerH + 1)) \ (g.rowH + 1)), "7")

    ' textDim, every unfocused programme title that isn't live: 4.5:1 on the
    ' lightest background it sits on (an even row's stripe and the past tint),
    ' and on the bare grid.
    lightest = NxGuideLightestTitleBg()
    NxCheck(r, "textDim: the lightest title background", NxToStr(lightest), "0x1A1A2AFF")
    NxCheck(r, "textDim: 4.5:1 on it (" + NxTokRatio(tc.textDim, lightest) + ")", NxToStr(NxTokContrast(tc.textDim, lightest) >= 4.5), "true")
    NxCheck(r, "textDim: 4.5:1 on the bare grid (" + NxTokRatio(tc.textDim, NxGuideColors().grid) + ")", NxToStr(NxTokContrast(tc.textDim, NxGuideColors().grid) >= 4.5), "true")

    ' text2: the CHANNEL heading on the header, and the WATERSHED placeholder
    ' on an unfocused row's past tint (the stripe's, the lighter).
    heldBg = NxTokOver(NxGuideColors().past, NxTokOver(NxGuideColors().stripe, NxGuideColors().grid))
    NxCheck(r, "text2: 4.5:1 on the header (" + NxTokRatio(tc.text2, NxGuideColors().header) + ")", NxToStr(NxTokContrast(tc.text2, NxGuideColors().header) >= 4.5), "true")
    NxCheck(r, "text2: 4.5:1 on the WATERSHED band (" + NxTokRatio(tc.text2, heldBg) + ")", NxToStr(NxTokContrast(tc.text2, heldBg) >= 4.5), "true")

    ' The Apple TV's own two: the focused wash for cyan and yellow.
    NxCheck(r, "focus: cyan's wash", NxGuideFocusFill("#00D4FF"), "0x074E66FF")
    NxCheck(r, "focus: yellow's wash", NxGuideFocusFill("#FFE500"), "0x585314FF")

    ' Every distinct channel colour: the focused row's wash reads 4.5:1 with
    ' white as it is, never darkened; the live cell on it reads 4.5:1, kept
    ' when 55% over the wash already does and otherwise darkened no further
    ' than it needs (under 4.6:1).
    stock = ParseJson(ReadAsciiFile(channelsPath))
    chans = stock
    if type(stock) = "roAssociativeArray" then chans = stock.channels
    seen = {}
    colours = []
    for each ch in chans
        h = UCase(NxToStr(ch.colorHex))
        if not seen.DoesExist(h) then
            seen[h] = true
            colours.Push(h)
        end if
    end for
    NxCheck(r, "focus: channels.json has colours", NxToStr(colours.Count() > 50), "true")
    short = []
    changed = []
    liveShort = []
    over = []
    kept = 0
    darkened = 0
    heldShort = []
    heldOver = []
    heldKept = 0
    heldLifted = []
    for each h in colours
        wash = NxTokOverAt(h, tc.panel, 0.32)
        fill = NxGuideFocusFill(h)
        ratio = NxTokContrast(tc.text, fill)
        if ratio = invalid or ratio < 4.5 then short.Push(h)
        if fill <> wash then changed.Push(h)
        live = NxGuideFocusLiveFill(h)
        laid = NxTokOverAt(h, fill, 0.55)
        liveRatio = NxTokContrast(tc.text, live)
        if liveRatio = invalid or liveRatio < 4.5 then liveShort.Push(h)
        if NxTokContrast(tc.text, laid) >= 4.5 then
            if live = laid then kept = kept + 1 else over.Push(h + " changed")
        else
            darkened = darkened + 1
            if liveRatio <> invalid and liveRatio >= 4.6 then over.Push(h + " " + NxTokRatio(tc.text, live))
        end if
        ' The placeholder on the focused row's band, the past tint over the fill.
        band = NxTokOver(NxGuideColors().past, fill)
        held = NxGuideFocusHeldText(h)
        heldRatio = NxTokContrast(held, band)
        if heldRatio = invalid or heldRatio < 4.5 then heldShort.Push(h)
        if NxTokContrast(tc.text2, band) >= 4.5 then
            if held = tc.text2 then heldKept = heldKept + 1 else heldOver.Push(h + " changed")
        else
            heldLifted.Push(h + " " + NxTokRatio(held, band))
            if heldRatio <> invalid and heldRatio >= 4.6 then heldOver.Push(h + " " + NxTokRatio(held, band))
        end if
    end for
    NxCheck(r, "focus: every colour's wash reads 4.5:1 with white", short.Join(","), "")
    NxCheck(r, "focus: no colour's wash is darkened", changed.Join(","), "")
    NxCheck(r, "live: every colour's cell reads 4.5:1 with white", liveShort.Join(","), "")
    NxCheck(r, "live: darkened no further than needed", over.Join(","), "")
    NxCheck(r, "live: every colour kept or darkened", NxToStr(kept + darkened), NxToStr(colours.Count()))
    NxCheck(r, "held: every colour's focused placeholder reads 4.5:1 on its band", heldShort.Join(","), "")
    NxCheck(r, "held: text2 kept where it reads, brightened no further than needed", heldOver.Join(","), "")
    NxCheck(r, "held: every colour kept or brightened", NxToStr(heldKept + heldLifted.Count()), NxToStr(colours.Count()))
    NxCheck(r, "held: not a colour is white's, as colorOf", NxGuideFocusHeldText("nope"), NxGuideFocusHeldText("#FFFFFF"))
    NxCheck(r, "focus: a colour with no # reads the same", NxGuideFocusFill("FFE500"), NxGuideFocusFill("#FFE500"))
    NxCheck(r, "focus: not a colour is white's wash, as colorOf", NxGuideFocusFill("nope"), NxGuideFocusFill("#FFFFFF"))
    NxCheck(r, "live: not a colour is white's, as colorOf", NxGuideFocusLiveFill("nope"), NxGuideFocusLiveFill("#FFFFFF"))

    print "guide look cases: "; r.pass; " passed, "; r.fail; " failed ("; colours.Count(); " colours, live cells "; kept; " kept, "; darkened; " darkened; placeholder "; heldKept; " kept, brightened "; heldLifted.Join(", "); ")"
    return r.fail
end function
