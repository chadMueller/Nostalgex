' Runs source/guide/GuideNav.brs against upstream's guide wrap behaviour
' (ChannelGuideView.swift, 66033f6). Transcribed from the Swift, not
' generated, except the GUIDE TEXT SIZE cases, which are the Roku's own.
' Returns the failure count.

function NxRunGuideNavTests() as Integer
    r = { pass: 0, fail: 0 }

    NxCheck(r, "down middle", NxGuideStep(3, 17, "down").ToStr(), "4")
    NxCheck(r, "down to last", NxGuideStep(15, 17, "down").ToStr(), "16")
    NxCheck(r, "down wraps", NxGuideStep(16, 17, "down").ToStr(), "0")
    NxCheck(r, "down wraps two", NxGuideStep(1, 2, "down").ToStr(), "0")
    NxCheck(r, "down one channel", NxGuideStep(0, 1, "down").ToStr(), "-1")
    NxCheck(r, "up middle", NxGuideStep(4, 17, "up").ToStr(), "3")
    NxCheck(r, "up first no wrap", NxGuideStep(0, 17, "up").ToStr(), "-1")
    NxCheck(r, "other key", NxGuideStep(3, 17, "left").ToStr(), "-1")

    NxCheck(r, "back off live returns", NxGuideBack(5, 2, 0, true), "live")
    NxCheck(r, "back later in the row returns", NxGuideBack(2, 2, 3, false), "live")
    NxCheck(r, "back on live stops an encode", NxGuideBack(2, 2, 0, true), "stop")
    NxCheck(r, "back on live, direct play, leaves", NxGuideBack(2, 2, 0, false), "leave")

    ' GUIDE TEXT SIZE (I-060), the Apple TV's three steps (appletv/guide-text-three-steps):
    ' DEFAULT (raw "normal") titles, numbers and names 20, times and the heading
    ' 22, a 36 px number box; LARGER (raw "large") all 29 and a 54 px box;
    ' SMALLER (raw "small") 17 and 19 and a 31 px box. The tops are computed from
    ' the 64 px row and 58 px header.
    n = NxGuideTextSizesFor("normal")
    l = NxGuideTextSizesFor("large")
    s = NxGuideTextSizesFor("small")
    NxCheck(r, "text: the two-level call is DEFAULT and LARGER", FormatJson([NxGuideTextSizes(false), NxGuideTextSizes(true)]), FormatJson([n, l]))
    NxCheck(r, "text: DEFAULT is the Apple TV's", FormatJson([n.slot, n.slotY, n.slotH, n.title, n.titleY, n.num, n.numW, n.numY, n.name, n.nameY, n.nameGap, n.head, n.headY, n.held, n.heldY]), "[22,15,29,20,19,20,36,19,20,19,44,22,15,22,18]")
    NxCheck(r, "text: LARGER is the old LARGE, in a 76 px row and a 66 px header", FormatJson([l.slot, l.slotY, l.slotH, l.title, l.titleY, l.num, l.numW, l.numY, l.name, l.nameY, l.nameGap, l.head, l.headY, l.held, l.heldY]), "[29,14,38,29,19,29,54,19,29,19,62,29,14,29,19]")
    NxCheck(r, "text: SMALLER is 17 and 19", FormatJson([s.slot, s.slotY, s.slotH, s.title, s.titleY, s.num, s.numW, s.numY, s.name, s.nameY, s.nameGap, s.head, s.headY, s.held, s.heldY]), "[19,17,25,17,21,17,31,21,17,21,39,19,17,19,20]")
    NxCheck(r, "text: the bundle list rows and heading follow the level", FormatJson([s.pkgRow, s.pkgHead, n.pkgRow, n.pkgHead, l.pkgRow, l.pkgHead]), "[17,19,20,22,22,25]")
    NxCheck(r, "text: the row and the header by step (integration-1115): 64 and 58, 64 and 58, 76 and 66", FormatJson([s.rowH, s.headerH, n.rowH, n.headerH, l.rowH, l.headerH]), "[64,58,64,58,76,66]")
    NxCheck(r, "text: the geometry's other numbers do not move", FormatJson([NxGuideGeometryFor("large").colX, NxGuideGeometryFor("large").slotWidth, NxGuideGeometryFor("small").colX]), "[340,395,340]")
    NxCheck(r, "text: the default geometry is DEFAULT's", FormatJson(NxGuideGeometry()), FormatJson(NxGuideGeometryFor("normal")))
    NxCheck(r, "text: SMALLER's constants", FormatJson([NxGuideSmallerText(), NxGuideSmallerTime(), NxGuideSmallerNumW()]), "[17,19,31]")
    ' The saved value: nothing, or anything unknown, is DEFAULT.
    NxCheck(r, "text: never chosen is normal", NxGuideTextStepFrom(""), "normal")
    NxCheck(r, "text: large is read", NxGuideTextStepFrom("large"), "large")
    NxCheck(r, "text: small is read", NxGuideTextStepFrom("small"), "small")
    NxCheck(r, "text: normal is read", NxGuideTextStepFrom("normal"), "normal")
    NxCheck(r, "text: anything else is normal", NxGuideTextStepFrom("huge"), "normal")
    NxCheck(r, "text: a wrong case is normal", NxGuideTextStepFrom("Large"), "normal")
    NxCheck(r, "text: the two-level read still says large", NxGuideTextFrom("large").ToStr() + NxGuideTextFrom("small").ToStr() + NxGuideTextFrom("").ToStr(), "truefalsefalse")
    NxCheck(r, "text: the cycle is SMALLER, DEFAULT, LARGER and round", NxGuideTextNext("small") + NxGuideTextNext("normal") + NxGuideTextNext("large"), "normallargesmall")
    NxCheck(r, "text: the labels", NxGuideTextLabel("small") + "," + NxGuideTextLabel("normal") + "," + NxGuideTextLabel("large"), "SMALLER,DEFAULT,LARGER")
    ' Each step is at least as big as the one below it, in everything the grid draws.
    for each k in ["slot", "title", "num", "name", "head", "held", "numW", "pkgRow", "pkgHead"]
        NxCheck(r, "text: DEFAULT " + k + " is bigger than SMALLER", NxGuideTextBigger(n[k], s[k]).ToStr(), "true")
        NxCheck(r, "text: LARGER " + k + " is bigger than DEFAULT", NxGuideTextBigger(l[k], n[k]).ToStr(), "true")
    end for
    ' Every line sits inside its 64 px row (the header's inside 58), a line
    ' being about 1.3 times its size tall.
    for each level in ["small", "normal", "large"]
        z = NxGuideTextSizesFor(level)
        for each k in [["title", "titleY"], ["num", "numY"], ["name", "nameY"], ["held", "heldY"]]
            NxCheck(r, "text: " + k[0] + " fits the row, " + level, NxGuideTextFits(z[k[0]], z[k[1]], z.rowH).ToStr(), "true")
        end for
        NxCheck(r, "text: time label fits the header, " + level, NxGuideTextFits(z.slot, z.slotY, z.headerH).ToStr(), "true")
        NxCheck(r, "text: heading fits the header, " + level, NxGuideTextFits(z.head, z.headY, z.headerH).ToStr(), "true")
        ' A three-digit number (up to 216) in DM Mono, about 0.6 of its size wide.
        NxCheck(r, "text: three digits fit the number box, " + level, NxGuideTextAtLeast(z.numW, Int(z.num * 0.6 * 3)).ToStr(), "true")
        NxCheck(r, "text: the name starts past the number box, " + level, NxGuideTextBigger(z.nameGap, z.numW).ToStr(), "true")
    end for

    ' ── The packages sidebar (bundleJumpTargets): guide order, one FRANCHISES ──
    ' The packages in channels.json's order, as the guide config lists them,
    ' with the collections as LibraryTask hands them over.
    bundles = [
        { id: "nostalgex", name: "NOSTALGEX", channelIDs: [1] },
        { id: "truecrime", name: "CASE FILES", channelIDs: [40] },
        { id: "essentials", name: "PRIME TIME", channelIDs: [50] },
        { id: "franchises", name: "FRANCHISES", channelIDs: [100], jumpIDs: [100, 1000000, 1010000] },
        { id: "seasonal", name: "SCREAM", channelIDs: [131] },
        { id: "high-rotation", name: "HIGH ROTATION", channelIDs: [150] },
        { id: "decades", name: "DECADES", channelIDs: [90] }
    ]
    on = ["nostalgex", "truecrime", "essentials", "franchises", "seasonal", "high-rotation"]
    jumps = [{ name: "OTHER COLLECTIONS", ids: [1020000] }]
    ' The guide in number order: 1, 50, 120 (id 40), 180 (id 131), 300, 310, 311, 400, 500.
    guide = [
        { id: 1, color: "#1" }, { id: 50, color: "#2" }, { id: 40, color: "#3" }, { id: 131, color: "#4" },
        { id: 100, color: "#5" }, { id: 1010000, color: "#6" }, { id: 1000000, color: "#7" },
        { id: 1020000, color: "#8" }, { id: 150, color: "#9" }
    ]
    NxCheck(r, "jump list: guide order, one FRANCHISES, HIGH ROTATION last", NxGnJumpNames(NxGuideJumpTargets(bundles, on, jumps, guide)), "NOSTALGEX@0,PRIME TIME@1,CASE FILES@2,SCREAM@3,FRANCHISES@4,OTHER COLLECTIONS@7,HIGH ROTATION@8")
    ' SCREAM leading the guide in October leads the list.
    lead = [guide[3], guide[0], guide[1], guide[2], guide[4], guide[5], guide[6], guide[7], guide[8]]
    NxCheck(r, "jump list: a seasonal lead leads", NxGnJumpNames(NxGuideJumpTargets(bundles, on, jumps, lead)), "SCREAM@0,NOSTALGEX@1,PRIME TIME@2,CASE FILES@3,FRANCHISES@4,OTHER COLLECTIONS@7,HIGH ROTATION@8")
    ' No classic shown: FRANCHISES jumps to the first franchise channel there is.
    noClassic = [guide[0], guide[5], guide[6]]
    NxCheck(r, "jump list: FRANCHISES without a classic", NxGnJumpNames(NxGuideJumpTargets(bundles, on, invalid, noClassic)), "NOSTALGEX@0,FRANCHISES@1")
    NxCheck(r, "jump list: a package off, or nothing shown", NxGnJumpNames(NxGuideJumpTargets(bundles, ["decades"], jumps, guide)), "OTHER COLLECTIONS@7")

    ' An empty guide takes every vertical key without a step to take (#93), on to SETTINGS: Up and Down answer -1
    ' whatever the focus was left at (Back from SETTINGS on the empty guide left it at -1), and the stripe and
    ' bundle list have nothing to walk.
    NxCheck(r, "empty guide: Up", NxGuideStep(0, 0, "up").ToStr(), "-1")
    NxCheck(r, "empty guide: Up from a focus left at -1", NxGuideStep(-1, 0, "up").ToStr(), "-1")
    NxCheck(r, "empty guide: Down", NxGuideStep(0, 0, "down").ToStr(), "-1")
    NxCheck(r, "empty guide: Down from a focus left at -1", NxGuideStep(-1, 0, "down").ToStr(), "-1")
    NxCheck(r, "empty guide: no jump list", NxGnJumpNames(NxGuideJumpTargets(bundles, on, jumps, [])), "")

    print "guide nav cases (upstream ChannelGuideView wrap): "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' a > b, as text for NxCheck.
function NxGuideTextBigger(a as Integer, b as Integer) as Boolean
    return a > b
end function

' a >= b, as text for NxCheck.
function NxGuideTextAtLeast(a as Integer, b as Integer) as Boolean
    return a >= b
end function

' A line `size` tall (about 1.3 times) from `top` ends inside `height`.
function NxGuideTextFits(size as Integer, top as Integer, height as Integer) as Boolean
    return top >= 0 and top + Int(size * 1.3 + 0.5) <= height
end function

function NxGnJumpNames(targets as Object) as String
    out = []
    for each t in targets
        out.Push(t.name + "@" + t.channel.ToStr())
    end for
    return out.Join(",")
end function
