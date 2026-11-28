' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Runs upstream's scripts/watershed-golden.json (copied unchanged to
' tests/vectors/), the cases its Swift WatershedGoldenTests and web
' nostalgex-watershed-smoke.mjs both read: a pool, the local hour and the
' WATERSHED switch, and what the pool keeps and whether the channel is held.
' hasOwnBlockRatings is VHS VAULT's shape, as the web smoke builds it.
' Returns the failure count.

function NxRunWatershedGoldenTests(goldenPath as String) as Integer
    golden = ParseJson(ReadAsciiFile(goldenPath))
    if golden = invalid then
        print "FAIL cannot read "; goldenPath
        return 1
    end if
    r = { pass: 0, fail: 0 }
    for each c in golden.cases
        channel = { timeRestrictions: invalid }
        if c.hasOwnBlockRatings = true then
            channel.timeRestrictions = { blockRatings: { ratings: ["R", "NC-17"], blockBefore: 21, blockAfter: invalid } }
        end if
        pool = []
        for each p in c.pool
            pool.Push({ ratingKey: p.ratingKey, contentRating: p.contentRating, type: p.type })
        end for
        got = []
        for each it in NxTimeFilteredPool(channel, pool, c.hour, c.watershedEnabled)
            got.Push(it.ratingKey)
        end for
        NxCheck(r, "watershed " + c.name + " pool", FormatJson(got), FormatJson(c.expectPool))
        NxCheck(r, "watershed " + c.name + " hold", FormatJson(NxIsWatershedHold(channel, pool, c.hour, c.watershedEnabled)), FormatJson(c.expectHold))
    end for
    print "watershed golden cases (upstream watershed-golden.json):"; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' The Roku's own wiring around the rule: the pool memo and the re-check key
' change with the gate, so a schedule built with WATERSHED off is never
' reused with it on, and VHS VAULT's shape is never gated.
function NxRunWatershedGateTests() as Integer
    r = { pass: 0, fail: 0 }
    plain = { id: 1, timeRestrictions: invalid }
    vault = { id: 2, timeRestrictions: { blockRatings: { ratings: ["R", "NC-17"], blockBefore: 21 } } }
    NxCheck(r, "gate closed before 9 PM", FormatJson(NxWatershedClosed(plain, 14, true)), "true")
    NxCheck(r, "gate open at 9 PM", FormatJson(NxWatershedClosed(plain, 21, true)), "false")
    NxCheck(r, "gate open with the switch off", FormatJson(NxWatershedClosed(plain, 14, false)), "false")
    NxCheck(r, "VHS VAULT shape never gated", FormatJson(NxWatershedClosed(vault, 14, true)), "false")

    off = NxPoolMemo(plain, 14, false)
    off.mark = "off"
    NxCheck(r, "memo: switch on before 9 PM is its own", FormatJson(NxPoolMemo(plain, 14, true).mark = "off"), "false")
    NxCheck(r, "memo: switch off again is the first", FormatJson(NxPoolMemo(plain, 15, false).mark = "off"), "true")
    NxCheck(r, "memo: switch on after 9 PM is the open one", FormatJson(NxPoolMemo(plain, 22, true).mark = "off"), "true")
    vm = NxPoolMemo(vault, 14, false)
    vm.mark = "vault"
    NxCheck(r, "memo: VHS VAULT shape ignores the switch", FormatJson(NxPoolMemo(vault, 14, true).mark = "vault"), "true")

    at& = 1780000000
    NxCheck(r, "re-check key changes with the switch", FormatJson(NxScheduleHourKey(at&, true) <> NxScheduleHourKey(at&, false)), "true")
    NxCheck(r, "re-check key off is the old key", NxScheduleHourKey(at&), NxScheduleHourKey(at&, false))

    NxSetWatershed(true)
    NxCheck(r, "switch set", FormatJson(NxWatershedSet()), "true")
    NxSetWatershed(false)
    NxCheck(r, "switch cleared", FormatJson(NxWatershedSet()), "false")
    GetGlobalAA().Delete("nxWatershed")
    NxCheck(r, "switch unset is off", FormatJson(NxWatershedSet()), "false")

    ' ── The 9 PM crossing with a held channel tuned (#190): the re-check key moves at 21:00 and the held
    ' channel's schedule goes from empty to titles, as the library task's re-check sees it. ──
    g = GetGlobalAA()
    g.nxTzOffsets = invalid
    g.nxTzOffsetSec = 0
    NxClearManifests()
    held = []
    for i = 1 to 4
        held.Push({ ratingKey: "wr" + i.ToStr(), title: "Held " + i.ToStr(), duration: 5400, contentRating: "R", type: "movie", year: "1999" })
    end for
    lineup = [{ id: 31, number: 31, name: "VAULT", colorHex: "#00AAFF", pool: held }]
    dayStart& = NxLocalDay(1780000000).dayStartSec
    before& = dayStart& + 20 * 3600 + 59 * 60 + 30
    after& = dayStart& + 21 * 3600 + 30
    NxSetWatershed(true)
    NxSetLineup(lineup)
    last = NxScheduleHourKey(before&, NxWatershedSet())
    nowKey = NxScheduleHourKey(after&, NxWatershedSet())
    NxCheck(r, "9 PM: the re-check key moves with WATERSHED on", FormatJson(nowKey <> last), "true")
    a = NxScheduleGuide(lineup, before&)
    NxCheck(r, "9 PM: before, the channel is held and has no titles", FormatJson(a[0].held) + " " + a[0].blocks.Count().ToStr(), "true 0")
    b = NxScheduleGuide(lineup, after&)
    NxCheck(r, "9 PM: after, it is open with titles", FormatJson(b[0].held) + " " + FormatJson(b[0].blocks.Count() > 0), "false true")
    NxCheck(r, "9 PM: so the guide changes and the library task would publish it", FormatJson(FormatJson(a) <> FormatJson(b)), "true")
    NxSetWatershed(false)
    g.nxTzOffsetSec = invalid
    NxClearManifests()

    ' ── The catch-up after the OS stopped the app (#190): a tick or key after more than 90 s asks for the
    ' schedule re-check at once. ──
    NxCheck(r, "tick gap: no tick yet", FormatJson(NxTickGapDue(invalid, 5000)), "false")
    NxCheck(r, "tick gap: the next second", FormatJson(NxTickGapDue(5000, 5001)), "false")
    NxCheck(r, "tick gap: 30 s, a re-check's own interval", FormatJson(NxTickGapDue(5000, 5030)), "false")
    NxCheck(r, "tick gap: exactly 90 s is not a gap", FormatJson(NxTickGapDue(5000, 5090)), "false")
    NxCheck(r, "tick gap: 91 s is", FormatJson(NxTickGapDue(5000, 5091)), "true")
    NxCheck(r, "tick gap: ten minutes asleep", FormatJson(NxTickGapDue(5000, 5600)), "true")
    NxCheck(r, "tick gap: a shorter limit", FormatJson(NxTickGapDue(5000, 5011, 10)), "true")
    ' The gap crossing 9 PM: the key's hour is not the guide's, so the re-check the gap asks for re-packs.
    gz = GetGlobalAA()
    gz.nxTzOffsets = invalid
    gz.nxTzOffsetSec = 0
    nine& = NxLocalDay(1780000000).dayStartSec + 21 * 3600
    NxCheck(r, "tick gap: asleep across 9 PM, the re-check key has moved", FormatJson(NxScheduleHourKey(nine& + 30, true) <> NxScheduleHourKey(nine& - 600, true) and NxTickGapDue(nine& - 600, nine& + 30)), "true")
    NxCheck(r, "tick gap: not asleep across it, the 30 s ask sees the key move itself", FormatJson(NxTickGapDue(nine& - 5, nine& + 5)), "false")
    gz.nxTzOffsetSec = invalid
    ' The hold clip is restarted on an error at most twice, a third failure stops it (#190).
    NxCheck(r, "keep-alive: a finished clip loops", NxKeepAliveAction("finished", 0), "play")
    NxCheck(r, "keep-alive: a first error is tried again", NxKeepAliveAction("error", 1), "play")
    NxCheck(r, "keep-alive: a second error is tried again", NxKeepAliveAction("error", 2), "play")
    NxCheck(r, "keep-alive: a third error gives up", NxKeepAliveAction("error", 3), "giveup")
    NxCheck(r, "keep-alive: a fifth error still gives up", NxKeepAliveAction("error", 5), "giveup")
    NxCheck(r, "keep-alive: playing and buffering do nothing", NxKeepAliveAction("playing", 0) + NxKeepAliveAction("buffering", 0), "")
    ' A clip still buffering when the stall timer fires is a failure, through the same three tries (#334).
    NxCheck(r, "keep-alive stall: a first stall is tried again", NxKeepAliveStallAction("buffering", 1), "play")
    NxCheck(r, "keep-alive stall: a second is tried again", NxKeepAliveStallAction("buffering", 2), "play")
    NxCheck(r, "keep-alive stall: a third gives up", NxKeepAliveStallAction("buffering", 3), "giveup")
    NxCheck(r, "keep-alive stall: playing, finished or stopped by then does nothing", NxKeepAliveStallAction("playing", 1) + NxKeepAliveStallAction("finished", 1) + NxKeepAliveStallAction("stopped", 1), "")
    NxCheck(r, "keep-alive stall: a short wait, under a minute", FormatJson(NxKeepAliveStallSecs() > 0 and NxKeepAliveStallSecs() < 60), "true")

    print "watershed gate cases:"; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function
