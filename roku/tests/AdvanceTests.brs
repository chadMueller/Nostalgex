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

    ' NxAdvancePick, the Apple TV's next pick. Channel 5 airs a, b, c.
    chans = [{ id: 5, blocks: blocks }]
    ' a ran 25 s over: b airs now, and starts from its beginning.
    NxCheck(r, "ran over, what airs now", NxAdvancePickLine(chans, 0, "a", 1685&, true), "b@0")
    ' b ended 20 s early: the schedule hasn't moved, so the one after it.
    NxCheck(r, "ended early, the one after", NxAdvancePickLine(chans, 0, "b", 2300&, true), "c@0")
    NxCheck(r, "ended on time", NxAdvancePickLine(chans, 0, "a", 1660&, true), "b@0")
    NxCheck(r, "last one, nothing after", NxAdvancePickLine(chans, 0, "c", 2990&, true), "none")
    ' After a failure the one airing now joins where the clock is.
    NxCheck(r, "after a failure, what airs now where it is", NxAdvancePickLine(chans, 0, "a", 1700&, false), "b@40")
    ' A title another channel has on at that moment is skipped: the one after it, from its start.
    other = { id: 9, blocks: [{ ratingKey: "b", startSec: 1600&, endSec: 1800& }] }
    NxCheck(r, "b on channel 9 too, so c", NxAdvancePickLine([chans[0], other], 0, "a", 1685&, true), "c@0")
    NxCheck(r, "after a failure, b on channel 9 too, so c from its start", NxAdvancePickLine([chans[0], other], 0, "a", 1700&, false), "c@0")
    NxCheck(r, "a channel is no conflict for itself", NxAdvancePickLine([other], 0, "b", 1700&, true), "b@0")

    ' One title on two channels: the lowest channel id keeps it.
    low = { id: 3, blocks: [{ ratingKey: "b", startSec: 1500&, endSec: 1700& }, { ratingKey: "x", startSec: 1700&, endSec: 1900& }] }
    gave = NxGaveWay([chans[0], low, other], 1690&)
    NxCheck(r, "channel 5 gives b way to channel 3", (gave["0"] <> invalid).ToStr(), "true")
    NxCheck(r, "channel 3 keeps it", (gave["1"] = invalid).ToStr(), "true")
    NxCheck(r, "channel 9 gives b way to channel 3, nothing after it", (gave["2"] <> invalid).ToStr(), "true")
    if gave["0"] <> invalid then NxCheck(r, "channel 5 shows c as on now", gave["0"].gaveWay.ratingKey + " " + gave["0"].shown.ratingKey, "b c")
    if gave["2"] <> invalid then NxCheck(r, "channel 9 has nothing after b", gave["2"].shown.ratingKey, "b")

    print "advance cases (upstream hand-over): "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

function NxAdvancePickLine(channels as Object, idx as Integer, prevKey as Dynamic, t as LongInteger, natural as Boolean) as String
    p = NxAdvancePick(channels, idx, prevKey, t, natural)
    if p = invalid then return "none"
    return p.block.ratingKey + "@" + p.seek.ToStr()
end function
