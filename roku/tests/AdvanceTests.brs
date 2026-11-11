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

    ' The skip takes the entry after the title's FIRST airing in the window,
    ' which can be one already over (short files, a small pool: a collection
    ' channel on a lab server, where the stick re-tuned the same file every
    ' 9 s). Channel 5 airs b, a, x, b, a; channel 9 has b on too. x ran 18 s
    ' over, so the pick is a, from its start, as upstream picks it; its slot
    ' then runs from now, or the clock ends it on the next tick.
    short = { id: 5, blocks: [
        { ratingKey: "b", startSec: 1000&, endSec: 1100& }, { ratingKey: "a", startSec: 1100&, endSec: 1200& },
        { ratingKey: "x", startSec: 1200&, endSec: 1300& }, { ratingKey: "b", startSec: 1300&, endSec: 1400& },
        { ratingKey: "a", startSec: 1400&, endSec: 1500& }
    ] }
    alsoB = { id: 9, blocks: [{ ratingKey: "b", startSec: 1300&, endSec: 1400& }] }
    pair = [short, alsoB]
    NxCheck(r, "skip to an airing already over: upstream's pick", NxAdvancePickLine(pair, 0, "x", 1318&, true), "a@0")
    p = NxAdvancePick(pair, 0, "x", 1318&, true)
    if p <> invalid then
        NxCheck(r, "skip to an airing already over: its slot from now", p.block.startSec.ToStr() + "-" + p.block.endSec.ToStr(), "1318-1418")
        NxCheck(r, "skip to an airing already over: not over on the next tick", NxAiringEnded(p.block, 1319&, "buffering").ToStr(), "false")
        NxCheck(r, "skip to an airing already over: the schedule is untouched", short.blocks[1].startSec.ToStr(), "1100")
    end if
    NxCheck(r, "skip to an airing already over: one hand-over in a minute", NxAdvanceLoopCount(pair, 0, "x", 1318&).ToStr(), "1")

    ' One title on two channels: the lowest channel id keeps it.
    low = { id: 3, blocks: [{ ratingKey: "b", startSec: 1500&, endSec: 1700& }, { ratingKey: "x", startSec: 1700&, endSec: 1900& }] }
    gave = NxGaveWay([chans[0], low, other], 1690&)
    NxCheck(r, "channel 5 gives b way to channel 3", (gave["0"] <> invalid).ToStr(), "true")
    NxCheck(r, "channel 3 keeps it", (gave["1"] = invalid).ToStr(), "true")
    NxCheck(r, "channel 9 gives b way to channel 3, nothing after it", (gave["2"] <> invalid).ToStr(), "true")
    if gave["0"] <> invalid then NxCheck(r, "channel 5 shows c as on now", gave["0"].gaveWay.ratingKey + " " + gave["0"].shown.ratingKey, "b c")
    if gave["2"] <> invalid then NxCheck(r, "channel 9 has nothing after b", gave["2"].shown.ratingKey, "b")

    ' An ordinary overrun keeps the next airing's own slot: only a start more
    ' than the overrun cap ago is shifted.
    NxCheck(r, "ran 25 s over, b keeps its slot", NxAdvanceBlockLine(chans, 0, "a", 1685&, true), "1660-2320")

    ' A tail past midnight (#297). Local midnight is mid. Channel 5's last
    ' airing t began at 22:30 the night before and runs 65 min past it; the new
    ' day's first airing f began at midnight, 95 min, and g follows it.
    g = GetGlobalAA()
    g.nxTzOffsetSec = 0
    mid& = 1794441600& ' 2026-11-12 00:00 UTC
    tail = { ratingKey: "t", startSec: mid& - 5400&, endSec: mid& + 3900& }
    first = { ratingKey: "f", startSec: mid&, endSec: mid& + 5700& }
    second = { ratingKey: "g", startSec: mid& + 5700&, endSec: mid& + 10800& }
    NxCheck(r, "midnight: kept 15 s after", NxKeepPlayingPastMidnight(tail, mid& + 15&).ToStr(), "true")
    NxCheck(r, "midnight: kept an hour after", NxKeepPlayingPastMidnight(tail, mid& + 3600&).ToStr(), "true")
    NxCheck(r, "midnight: not 5 s before it (the day it began in)", NxKeepPlayingPastMidnight(tail, mid& - 5&).ToStr(), "false")
    NxCheck(r, "midnight: not once its slot is over", NxKeepPlayingPastMidnight(tail, mid& + 3900&).ToStr(), "false")
    NxCheck(r, "midnight: not an airing of the new day", NxKeepPlayingPastMidnight(first, mid& + 15&).ToStr(), "false")
    NxCheck(r, "midnight: nothing playing", NxKeepPlayingPastMidnight(invalid, mid& + 15&).ToStr(), "false")
    ' The guide's day is the local one: the same airing at UTC midnight is
    ' kept in UTC and not in New York, where it is 7 PM.
    g.nxTzOffsetSec = -18000
    started = { ratingKey: "t", startSec: mid& - 3600&, endSec: mid& + 3600& }
    NxCheck(r, "midnight: UTC midnight is 7 PM in New York, not kept", NxKeepPlayingPastMidnight(started, mid& + 15&).ToStr(), "false")
    NxCheck(r, "midnight: New York's own midnight, kept", NxKeepPlayingPastMidnight({ ratingKey: "t", startSec: mid& + 5& * 3600& - 600&, endSec: mid& + 5& * 3600& + 3600& }, mid& + 5& * 3600& + 15&).ToStr(), "true")
    g.nxTzOffsetSec = 0
    ' The tail ends on its own at 01:05. The new day's first airing has been on
    ' 65 min, so it airs from now for its own length, not from 00:00.
    tonight = [{ id: 5, blocks: [first, second] }]
    NxCheck(r, "midnight: after the tail, f from its start", NxAdvancePickLine(tonight, 0, "t", mid& + 3900&, true), "f@0")
    NxCheck(r, "midnight: f airs from now for its 95 min", NxAdvanceBlockLine(tonight, 0, "t", mid& + 3900&, true), (mid& + 3900&).ToStr() + "-" + (mid& + 3900& + 5700&).ToStr())
    NxCheck(r, "midnight: the schedule's own f is not changed", first.startSec.ToStr() + "-" + first.endSec.ToStr(), mid&.ToStr() + "-" + (mid& + 5700&).ToStr())
    ' Not yet shifted at the cap: 300 s in, f keeps its slot.
    NxCheck(r, "midnight: 300 s in, f keeps its slot", NxAdvanceBlockLine(tonight, 0, "t", mid& + 300&, true), mid&.ToStr() + "-" + (mid& + 5700&).ToStr())
    NxCheck(r, "midnight: 301 s in, f airs from now", NxAdvanceBlockLine(tonight, 0, "t", mid& + 301&, true), (mid& + 301&).ToStr() + "-" + (mid& + 301& + 5700&).ToStr())
    ' The hand-over after a failure joins where the clock is, as before.
    NxCheck(r, "midnight: after a failure, f where the clock is", NxAdvancePickLine(tonight, 0, "t", mid& + 3900&, false), "f@3900")
    g.nxTzOffsetSec = invalid

    print "advance cases (upstream hand-over): "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' GuideView's hand-over, cut down: a natural end at t picks the next airing,
' then onTick runs once a second for a minute with the new stream still
' buffering, and advances whenever NxAiringEnded says so. Returns how many
' hand-overs that made (1 is the natural one).
function NxAdvanceLoopCount(channels as Object, idx as Integer, prevKey as Dynamic, t as LongInteger) as Integer
    n = 0
    p = NxAdvancePick(channels, idx, prevKey, t, true)
    if p = invalid then return n
    n = n + 1
    playing = p.block
    s& = t + 1
    while s& <= t + 60
        if NxAiringEnded(playing, s&, "buffering") then
            p = NxAdvancePick(channels, idx, playing.ratingKey, s&, false)
            if p = invalid then return n
            n = n + 1
            playing = p.block
        end if
        s& = s& + 1
    end while
    return n
end function

function NxAdvancePickLine(channels as Object, idx as Integer, prevKey as Dynamic, t as LongInteger, natural as Boolean) as String
    p = NxAdvancePick(channels, idx, prevKey, t, natural)
    if p = invalid then return "none"
    return p.block.ratingKey + "@" + p.seek.ToStr()
end function

' "start-end" of the block NxAdvancePick returns, or "none".
function NxAdvanceBlockLine(channels as Object, idx as Integer, prevKey as Dynamic, t as LongInteger, natural as Boolean) as String
    p = NxAdvancePick(channels, idx, prevKey, t, natural)
    if p = invalid then return "none"
    return p.block.startSec.ToStr() + "-" + p.block.endSec.ToStr()
end function
