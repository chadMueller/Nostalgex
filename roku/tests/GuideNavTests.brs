' Runs source/guide/GuideNav.brs against upstream's guide wrap behaviour
' (ChannelGuideView.swift, 66033f6). Transcribed from the Swift, not
' generated. Returns the failure count.

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

    print "guide nav cases (upstream ChannelGuideView wrap): "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function
