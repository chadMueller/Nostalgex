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
