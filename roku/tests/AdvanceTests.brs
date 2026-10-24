' Runs source/guide/Advance.brs against upstream's hand-over in
' advanceToNextItem (App/AppState+Playback.swift): the next item starts from
' its beginning when the file ends, and the clock never cuts a file still
' playing. Transcribed from the rule, not generated. Returns the failure count.

function NxRunAdvanceTests() as Integer
    r = { pass: 0, fail: 0 }
    ' Three 11-minute slots from t = 1000; the files are 11:25, 10:40, 11:00.
    a = { ratingKey: "a", startSec: 1000&, endSec: 1660& }
    b = { ratingKey: "b", startSec: 1660&, endSec: 2320& }
    c = { ratingKey: "c", startSec: 2320&, endSec: 2980& }
    blocks = [a, b, c]

    NxCheck(r, "inside the slot, not ended", NxAiringEnded(a, 1500&, "playing").ToStr(), "false")
    NxCheck(r, "past the slot, still playing", NxAiringEnded(a, 1685&, "playing").ToStr(), "false")
    NxCheck(r, "past the slot, buffering", NxAiringEnded(a, 1685&, "buffering").ToStr(), "true")
    NxCheck(r, "past the slot, finished", NxAiringEnded(a, 1685&, "finished").ToStr(), "true")
    NxCheck(r, "past the slot, stopped", NxAiringEnded(a, 1661&, "stopped").ToStr(), "true")
    NxCheck(r, "playing past the cap", NxAiringEnded(a, 1660& + NxOverrunCapSec(), "playing").ToStr(), "true")
    NxCheck(r, "nothing playing", NxAiringEnded(invalid, 1685&, "playing").ToStr(), "false")

    ' a ran 25 s over: b airs now, and starts from its beginning.
    NxCheck(r, "ran over, what airs now", NxNextAiring(blocks, a, 1685&).ratingKey, "b")
    ' b ended 20 s early: the schedule hasn't moved, so the one after it.
    NxCheck(r, "ended early, the one after", NxNextAiring(blocks, b, 2300&).ratingKey, "c")
    NxCheck(r, "ended on time", NxNextAiring(blocks, a, 1660&).ratingKey, "b")
    NxCheck(r, "last one, nothing after", NxToStr(NxNextAiring(blocks, c, 2990&)), "")

    ' The next pick is never what another channel has on now (advancePick):
    ' c is on channel 9, so channel 5 skips to the entry after it.
    d = { ratingKey: "d", startSec: 2980&, endSec: 3640& }
    mine = [a, b, c, d]
    guide = [{ id: 5, blocks: mine }, { id: 9, blocks: [{ ratingKey: "c", startSec: 2000&, endSec: 2600& }] }]
    NxCheck(r, "ended early, the one after is on elsewhere", NxNextAiring(mine, b, 2300&, guide, 5).ratingKey, "d")
    NxCheck(r, "ended early, its own channel doesn't count", NxNextAiring(mine, b, 2300&, [{ id: 5, blocks: mine }], 5).ratingKey, "c")

    print "advance cases (upstream hand-over): "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function
