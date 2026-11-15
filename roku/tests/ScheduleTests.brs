' Runs source/schedule/DailyManifest.brs against tests/vectors/schedule.json,
' the golden vectors generated from upstream's engine. Prints each failure and
' a summary line, and returns the failure count. The same file runs in the
' off-device interpreter (tests/run.sh) and on a TV (scripts/deploy.sh --test).

function NxRunScheduleTests(vectorsPath as String) as Integer
    v = ParseJson(ReadAsciiFile(vectorsPath))
    if v = invalid then
        print "FAIL cannot read "; vectorsPath
        return 1
    end if
    r = { pass: 0, fail: 0 }

    for each c in v.rng.splitmix64
        NxCheck(r, "splitmix64(" + c.in.ToStr() + ")", NxHex64(NxSplitmix64(c.in)), c.out)
    end for
    for each c in v.rng.next
        rng = NxSeededRng(c.seed)
        for i = 0 to c.out.Count() - 1
            NxCheck(r, "next seed " + c.seed.ToStr() + " #" + i.ToStr(), NxHex64(NxRngNext(rng)), c.out[i])
        end for
    end for
    for each c in v.rng.bounded
        rng = NxSeededRng(c.seed)
        for i = 0 to c.bounds.Count() - 1
            got = NxRngBounded(rng, c.bounds[i])
            NxCheck(r, "bounded seed " + c.seed.ToStr() + " #" + i.ToStr(), got.ToStr(), c.out[i].ToStr())
        end for
    end for

    NxCheckOffsets(r, "swift ", v.swift.premiereOffset)
    NxCheckOffsets(r, "", v.premiereOffset)
    NxCheckOrders(r, "swift ", v.swift.order, v.fixtures.A)
    NxCheckOrders(r, "", v.order, v.fixtures.B)

    for each c in v.packDay
        aired = {}
        aired.SetModeCaseSensitive()
        for each k in c.aired
            aired[k] = true
        end for
        got = NxPackDay(v.fixtures[c.pool].pool, c.dayStart, c.dayEnd, c.day, c.channel, aired, c.premiere, c.last)
        parts = []
        for each b in got
            parts.Push(b.ratingKey + "@" + b.startSec.ToStr() + "-" + b.endSec.ToStr())
        end for
        NxCheck(r, "packDay " + c.name, parts.Join(","), c.blocks)
    end for

    ' NxPackDay's goldenShift for pools past 2^24 s, where Int() would round
    ' to float32 on a TV, and NxFloorDouble around it (Math.floor in Python).
    for each c in [[27000000&, "16686917"], [70000000&, "43262379"], [123456789&, "76300491"]]
        total& = c[0]
        NxCheck(r, "goldenShift " + total&.ToStr(), NxFloorDouble(total& * 0.6180339887#).ToStr(), c[1])
    end for
    for each c in [[0#, "0"], [0.999#, "0"], [-1.5#, "-2"], [16777217.5#, "16777217"], [1684742353.25#, "1684742353"], [951868799#, "951868799"], [123456789012.75#, "123456789012"]]
        NxCheck(r, "floor " + Str(c[0]).Trim(), NxFloorDouble(c[0]).ToStr(), c[1])
    end for

    ' A programme's slot (#315): the file's real runtime in seconds, rounded up, with the minutes as the fallback.
    NxCheck(r, "slot: minutes only", NxSlotSeconds({ duration: 95 }).ToStr(), "5700")
    NxCheck(r, "slot: a runtime 61 s off is a bad value, the minutes", NxSlotSeconds({ duration: 90, exactDurationSeconds: 5461 }).ToStr(), "5400")
    NxCheck(r, "slot: a runtime in range is rounded up", NxSlotSeconds({ duration: 90, exactDurationSeconds: 5460.4# }).ToStr(), "5461")
    NxCheck(r, "slot: a runtime shorter than the minutes", NxSlotSeconds({ duration: 90, exactDurationSeconds: 5390 }).ToStr(), "5390")
    NxCheck(r, "slot: an exact minute", NxSlotSeconds({ duration: 60, exactDurationSeconds: 3600 }).ToStr(), "3600")
    NxCheck(r, "slot: 60 s off still counts", NxSlotSeconds({ duration: 90, exactDurationSeconds: 5459.5# }).ToStr(), "5460")
    NxCheck(r, "slot: a runtime under a second is no runtime", NxSlotSeconds({ duration: 0, exactDurationSeconds: 0.5# }).ToStr(), "0")
    NxCheck(r, "slot: no minutes, no slot", NxSlotSeconds({}).ToStr(), "0")
    NxCheck(r, "loader: Plex keeps the milliseconds as seconds", NxToStr(NxPlexRuntimeSec(5460400)), "5460.4")
    NxCheck(r, "loader: Plex has no runtime when none", NxToStr(NxPlexRuntimeSec(0)) + NxToStr(NxPlexRuntimeSec(invalid)), "")
    NxCheck(r, "loader: Jellyfin ticks as seconds", NxToStr(NxMbRuntimeSec(54604000000#)), "5460.4")
    NxCheck(r, "loader: Jellyfin has no runtime when none", NxToStr(NxMbRuntimeSec(0)) + NxToStr(NxMbRuntimeSec(invalid)), "")
    print "schedule vectors (upstream "; Left(v.upstream.commit, 7); "): "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

sub NxCheckOffsets(r as Object, label as String, cases as Object)
    for each key in cases
        sep = Instr(1, key, ":")
        ch = Left(key, sep - 1).ToInt()
        rk = Mid(key, sep + 1)
        NxCheck(r, label + "premiereOffset " + key, NxPremiereOffset(ch, rk).ToStr(), cases[key].ToStr())
    end for
end sub

' Keys are STAGE:seed:day. INTER interleaves; PROMO adds premieres; SEQ then
' groups sequels; SEQONLY groups sequels straight after the interleave.
sub NxCheckOrders(r as Object, label as String, cases as Object, fixture as Object)
    for each key in cases
        f = key.Split(":")
        seed = f[1].ToInt()
        day = f[2].ToInt()
        got = NxInterleaveByShow(fixture.pool, seed, day)
        if f[0] = "PROMO" or f[0] = "SEQ" then got = NxPromoteRecentlyAdded(got, fixture.dayStart, seed)
        if f[0] = "SEQ" or f[0] = "SEQONLY" then got = NxGroupSequelParts(got)
        keys = []
        for each item in got
            keys.Push(item.ratingKey)
        end for
        NxCheck(r, label + key, keys.Join(","), cases[key])
    end for
end sub

sub NxCheck(r as Object, name as String, got as String, want as String)
    if got = want then
        r.pass = r.pass + 1
    else
        r.fail = r.fail + 1
        print "FAIL "; name
        print "    want "; want
        print "    got  "; got
    end if
end sub

' Unsigned 16-digit hex of a 64-bit value.
function NxHex64(x as LongInteger) as String
    digits = "0123456789abcdef"
    s = ""
    for i = 1 to 16
        s = Mid(digits, (x and 15) + 1, 1) + s
        x = NxShr(x, 16&)
    end for
    return s
end function
