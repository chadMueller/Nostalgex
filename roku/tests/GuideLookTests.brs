' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' The guide grid on the Apple TV 1.0.32's look (#263): its shape
' (NxGuideGeometry), textDim held to 4.5:1 on the grid's lightest background
' an unfocused title sits on (NxGuideLightestTitleBg), and the focused row's
' fill (NxGuideFocusFill) reading 4.5:1 with white titles for every distinct
' channel colour in channels.json, darkened no further than that needs. The
' colour helpers it rests on (NxTokOver, NxTokDarkenFor) are checked first.
' Returns the failure count.

function NxRunGuideLookTests(channelsPath as String) as Integer
    r = { pass: 0, fail: 0 }
    tc = NxTokens().color

    ' The helpers: a translucent colour over another, and a fill darkened for a ratio.
    NxCheck(r, "over: white at half over black", NxToStr(NxTokOver("0xFFFFFF80", "0x000000FF")), "0x808080FF")
    NxCheck(r, "over: opaque hides the bottom", NxToStr(NxTokOver("0x123456FF", "0xFFFFFFFF")), "0x123456FF")
    NxCheck(r, "over: clear shows the bottom", NxToStr(NxTokOver("0xFFFFFF00", "0x0D0D1FFF")), "0x0D0D1FFF")
    NxCheck(r, "over: not a colour", NxToStr(NxTokOver("white", "0x000000FF") = invalid), "true")
    NxCheck(r, "darken: a fill white already reads on is only made opaque", NxToStr(NxTokDarkenFor("#0064FF", "0xFFFFFFFF", 4.5)), "0x0064FFFF")
    w = NxTokDarkenFor("#FFFFFF", "0xFFFFFFFF", 4.5)
    NxCheck(r, "darken: white goes grey, just past 4.5:1", NxToStr(NxTokContrast("0xFFFFFFFF", w) >= 4.5 and NxTokContrast("0xFFFFFFFF", w) < 4.6), "true")
    NxCheck(r, "darken: not a colour", NxToStr(NxTokDarkenFor("#FFF", "0xFFFFFFFF", 4.5) = invalid), "true")

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

    ' The focused row's fill for every distinct channel colour: white titles
    ' at 4.5:1, a colour already there kept as it is, and a darkened one no
    ' darker than it needs (under 4.6:1).
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
    over = []
    kept = 0
    darkened = 0
    for each h in colours
        fill = NxGuideFocusFill(h)
        ratio = NxTokContrast(tc.text, fill)
        if ratio = invalid or ratio < 4.5 then short.Push(h)
        if NxTokContrast(tc.text, h) >= 4.5 then
            if fill = "0x" + Mid(h, 2) + "FF" then kept = kept + 1 else over.Push(h + " changed")
        else
            darkened = darkened + 1
            if ratio <> invalid and ratio >= 4.6 then over.Push(h + " " + NxTokRatio(tc.text, fill))
        end if
    end for
    NxCheck(r, "focus: every colour's fill reads 4.5:1 with white", short.Join(","), "")
    NxCheck(r, "focus: darkened no further than needed", over.Join(","), "")
    NxCheck(r, "focus: every colour kept or darkened", NxToStr(kept + darkened), NxToStr(colours.Count()))
    NxCheck(r, "focus: a colour with no # reads the same", NxGuideFocusFill("FFE500"), NxGuideFocusFill("#FFE500"))
    NxCheck(r, "focus: not a colour is darkened white, as colorOf", NxGuideFocusFill("nope"), NxGuideFocusFill("#FFFFFF"))

    print "guide look cases: "; r.pass; " passed, "; r.fail; " failed ("; colours.Count(); " colours, "; kept; " kept, "; darkened; " darkened)"
    return r.fail
end function
