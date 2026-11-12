' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' GUIDE TIMEOUT's rule (source/guide/GuideTimeout.brs, issue #274) held to the web
' tuner's module (scripts/nostalgex-guide-timeout.js, parity with the Apple TV's
' GuideTimeout.swift) through tests/vectors/guide-timeout.json
' (tests/gen-guide-timeout.mjs): what each stored value parses to (anything unknown
' is the default), what a press on the row moves to, the label and the seconds, and
' whether a guide left alone is due. Then the Roku's own hand-over rule: only with the
' guide in front and a channel playing.
' Returns the failure count.

function NxRunGuideTimeoutTests(vectorsPath as String) as Integer
    v = ParseJson(ReadAsciiFile(vectorsPath))
    if v = invalid or v.values = invalid or v.due = invalid then
        print "FAIL cannot read "; vectorsPath
        return 1
    end if
    r = { pass: 0, fail: 0 }
    NxCheck(r, "default: 5 MIN to start", NxGuideTimeoutDefault(), v.default)
    for each c in v.values
        stored = c.stored
        name = "stored " + FormatJson(stored)
        NxCheck(r, name + ": parse", NxGuideTimeoutParse(stored), c.parse)
        NxCheck(r, name + ": next", NxGuideTimeoutNext(stored), c.next)
        NxCheck(r, name + ": label", NxGuideTimeoutLabel(stored), c.label)
        NxCheck(r, name + ": seconds", NxToStr(NxGuideTimeoutSeconds(stored)), NxToStr(c.seconds))
    end for
    NxCheck(r, "the row goes OFF, 5 MIN, 15 MIN and round", NxGuideTimeoutLabel(NxGuideTimeoutNext("off")) + "|" + NxGuideTimeoutLabel(NxGuideTimeoutNext("5m")) + "|" + NxGuideTimeoutLabel(NxGuideTimeoutNext("15m")), "5 MIN|15 MIN|OFF")
    wrong = []
    for each c in v.due
        sec = NxGuideTimeoutSeconds(c.stored)
        got = NxGuideShouldGoFullscreen(sec, c.lastSec, c.nowSec, true, true)
        if got <> c.due then wrong.Push(FormatJson(c.stored) + " " + NxToStr(c.lastSec) + ".." + NxToStr(c.nowSec) + ": " + NxToStr(got))
    end for
    NxCheck(r, "due: every pair matches the web module", wrong.Join(" | "), "")
    NxCheck(r, "hand over: not while the guide is not in front", NxToStr(NxGuideShouldGoFullscreen(300, 0, 10000, false, true)), "false")
    NxCheck(r, "hand over: not with nothing playing", NxToStr(NxGuideShouldGoFullscreen(300, 0, 10000, true, false)), "false")
    NxCheck(r, "hand over: never with OFF", NxToStr(NxGuideShouldGoFullscreen(0, 0, 100000, true, true)), "false")
    NxCheck(r, "hand over: a press just now keeps the guide", NxToStr(NxGuideShouldGoFullscreen(300, 9999, 10000, true, true)), "false")
    NxCheck(r, "hand over: exactly at the time", NxToStr(NxGuideShouldGoFullscreen(300, 9700, 10000, true, true)), "true")
    print "guide timeout tests: "; r.pass; " passed, "; r.fail; " failed ("; v.values.Count(); " stored values, "; v.due.Count(); " due pairs)"
    return r.fail
end function
