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

    ' GUIDE TEXT SIZE (I-060), Roku only: no Swift to transcribe. NORMAL is the
    ' sizes the grid always had, so a TV that never chose draws as before.
    n = NxGuideTextSizes(false)
    l = NxGuideTextSizes(true)
    NxCheck(r, "text: normal is the old grid", FormatJson([n.slot, n.slotY, n.slotH, n.title, n.titleY, n.num, n.numW, n.numY, n.name, n.nameY, n.nameGap, n.head, n.headY]), "[20,17,26,20,27,20,36,27,18,29,44,18,18]")
    NxCheck(r, "text: never chosen is normal", NxGuideTextFrom("").ToStr(), "false")
    NxCheck(r, "text: large is read", NxGuideTextFrom("large").ToStr(), "true")
    NxCheck(r, "text: normal is read", NxGuideTextFrom("normal").ToStr(), "false")
    NxCheck(r, "text: anything else is normal", NxGuideTextFrom("huge").ToStr(), "false")
    for each k in ["slot", "title", "num", "name", "head"]
        NxCheck(r, "text: large " + k + " is bigger", NxGuideTextBigger(l[k], n[k]).ToStr(), "true")
    end for
    ' Every line sits inside its 80 px row (the header's inside 60), a line
    ' being about 1.3 times its size tall.
    for each k in [["title", "titleY"], ["num", "numY"], ["name", "nameY"]]
        for each big in [false, true]
            z = NxGuideTextSizes(big)
            NxCheck(r, "text: " + k[0] + " fits the row, large " + FormatJson(big), NxGuideTextFits(z[k[0]], z[k[1]], 80).ToStr(), "true")
        end for
    end for
    for each big in [false, true]
        z = NxGuideTextSizes(big)
        NxCheck(r, "text: time label fits the header, large " + FormatJson(big), NxGuideTextFits(z.slot, z.slotY, 60).ToStr(), "true")
        NxCheck(r, "text: heading fits the header, large " + FormatJson(big), NxGuideTextFits(z.head, z.headY, 60).ToStr(), "true")
        ' A three-digit number (up to 216) in DM Mono, about 0.6 of its size wide.
        NxCheck(r, "text: three digits fit the number box, large " + FormatJson(big), NxGuideTextAtLeast(z.numW, Int(z.num * 0.6 * 3)).ToStr(), "true")
        NxCheck(r, "text: the name starts past the number box, large " + FormatJson(big), NxGuideTextBigger(z.nameGap, z.numW).ToStr(), "true")
    end for

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
