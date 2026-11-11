' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Runs source/ui/Tokens.brs (#262): the text and surface pairs the issue
' holds, textDim on the panel and resting row only, at 4.5:1 or more (WCAG contrast, NxTokContrast), checked against known
' ratios first and shown to catch a pair below 4.5:1; no colour with an
' opacity; nothing the viewer reads below the caption floor but the guide's
' rows; black or white on a solid fill. Returns the failure count.

function NxRunDesignTokensTests() as Integer
    r = { pass: 0, fail: 0 }
    t = NxTokens()
    c = t.color

    ' The contrast sum against known WCAG ratios, so a pass below means
    ' something: white on black is 21:1, #767676 on white 4.54:1.
    NxCheck(r, "contrast: white on black", NxTokRatio("0xFFFFFFFF", "0x000000FF"), "21.00")
    NxCheck(r, "contrast: either order", NxTokRatio("0x000000FF", "#FFFFFF"), "21.00")
    NxCheck(r, "contrast: #767676 on white", NxTokRatio("#767676", "0xFFFFFFFF"), "4.54")
    NxCheck(r, "contrast: a colour with itself", NxTokRatio(c.panel, c.panel), "1.00")
    NxCheck(r, "contrast: not a colour", NxToStr(NxTokContrast("0xFFFFFF", c.panel) = invalid), "true")
    NxCheck(r, "contrast: not a string", NxToStr(NxTokContrast(invalid, c.panel) = invalid), "true")

    ' The pairs #262 holds at 4.5:1.
    pairs = []
    for each name in ["text", "text2", "cyan", "yellow", "amber", "redText"]
        for each surface in ["panel", "row", "selectedRow"]
            pairs.Push([name, surface])
        end for
    end for
    ' textDim on the guide's backgrounds only: the panel and the resting row.
    pairs.Push(["textDim", "panel"])
    pairs.Push(["textDim", "row"])
    pairs.Push(["text", "chosenNeutral"])
    pairs.Push(["text2", "chosenNeutral"])
    pairs.Push(["onCyan", "cyan"])
    held = 0
    for each p in pairs
        ratio = NxTokContrast(c[p[0]], c[p[1]])
        ok = ratio <> invalid
        if ok then ok = ratio >= 4.5
        NxCheck(r, "4.5:1: " + p[0] + " on " + p[1] + " (" + NxTokRatio(c[p[0]], c[p[1]]) + ")", NxToStr(ok), "true")
        if ok then held = held + 1
    end for
    NxCheck(r, "4.5:1: every listed pair", NxToStr(held) + " of " + NxToStr(pairs.Count()), "23 of 23")
    ' The check above fails a pair below 4.5:1: textDim on the selected row,
    ' which #262 keeps it off, is 4.16:1.
    NxCheck(r, "4.5:1: textDim on the selected row is below, so kept off it", NxToStr(NxTokContrast(c.textDim, c.selectedRow) < 4.5), "true")

    ' No colour with an opacity: white with an opacity is not a text colour.
    see = 0
    for each name in c
        if Len(c[name]) = 10 and UCase(Right(c[name], 2)) = "FF" and NxTokLuminance(c[name]) <> invalid then see = see + 1
    end for
    NxCheck(r, "colours: all opaque 0xRRGGBBFF", NxToStr(see) + " of " + NxToStr(c.Count()), "14 of 14")

    ' The type scale: nothing below the caption floor but the guide's rows.
    low = []
    for each name in t.size
        if t.size[name] < t.size.caption then low.Push("size." + name)
    end for
    for each name in t.compactSize
        if t.compactSize[name] < t.size.caption then low.Push("compactSize." + name)
    end for
    NxCheck(r, "type: nothing below the 25 px floor", low.Join(","), "")
    NxCheck(r, "type: the guide's rows, the one size below it", NxToStr(t.guideRow), "22")
    NxCheck(r, "type: compact is one step down the scale", NxToStr(t.compactSize.body) + " " + NxToStr(t.compactSize.heading) + " " + NxToStr(t.compactSize.title) + " " + NxToStr(t.compactSize.tag), "25 29 38 31")

    ' Text on a solid channel-coloured fill: black or white, whichever reads.
    NxCheck(r, "text on: yellow takes black", NxTokTextOn("0xFFE500FF"), "0x000000FF")
    NxCheck(r, "text on: cyan takes black", NxTokTextOn(c.cyan), "0x000000FF")
    NxCheck(r, "text on: navy takes white", NxTokTextOn(c.chosenNeutral), "0xFFFFFFFF")
    NxCheck(r, "text on: not a colour takes white", NxTokTextOn("pink"), "0xFFFFFFFF")

    print "design token cases: "; r.pass; " passed, "; r.fail; " failed"
    return r.fail
end function

' A contrast ratio to two decimals, for the case names and exact checks.
function NxTokRatio(a as Dynamic, b as Dynamic) as String
    v = NxTokContrast(a, b)
    if v = invalid then return "invalid"
    n = Int(v * 100 + 0.5)
    s = NxToStr(n Mod 100)
    if Len(s) < 2 then s = "0" + s
    return NxToStr(Int(n / 100)) + "." + s
end function
