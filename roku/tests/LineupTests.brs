' Runs source/guide/Lineup.brs against tests/vectors/lineup.json:
' time-of-day restrictions, the pool fingerprint, and the
' session schedule cache across consecutive days. Pins the zone to UTC, as
' the vectors were made. Returns the failure count.

function NxRunLineupTests(vectorsPath as String) as Integer
    v = ParseJson(ReadAsciiFile(vectorsPath))
    if v = invalid then
        print "FAIL cannot read "; vectorsPath
        return 1
    end if
    r = { pass: 0, fail: 0 }
    g = GetGlobalAA()
    g.nxTzOffsetSec = 0

    for each c in v.timeFilter
        got = NxTimeFilteredPool({ timeRestrictions: c.tr }, v.rated, c.hour)
        NxCheck(r, "timeFilter " + FormatJson(c.tr) + " hour " + c.hour.ToStr(), NxLineupKeys(got), c.out)
    end for

    for each c in v.fingerprint
        part = []
        for i = 0 to c.n - 1
            part.Push(v.pool[i])
        end for
        NxCheck(r, "fingerprint n=" + c.n.ToStr(), NxPoolFingerprint(part), c.out)
    end for

    NxClearManifests()
    stepNo = 0
    for each c in v.manifests
        stepNo = stepNo + 1
        if c.clear = true then
            NxClearManifests()
        else
            part = []
            for i = 0 to c.n - 1
                part.Push(v.pool[i])
            end for
            parts = []
            for each b in NxManifestBlocks(c.channel, part, c.atSec)
                parts.Push(NxToStr(b.item.ratingKey) + "@" + b.startSec.ToStr() + "-" + b.endSec.ToStr())
            end for
            NxCheck(r, "manifest stepNo " + stepNo.ToStr(), parts.Join(","), c.out)
            ' NxScheduleGuide's memo: filled on the first call, read on the second.
            memo = {}
            for pass = 1 to 2
                parts = []
                for each b in NxManifestBlocks(c.channel, part, c.atSec, memo)
                    parts.Push(NxToStr(b.item.ratingKey) + "@" + b.startSec.ToStr() + "-" + b.endSec.ToStr())
                end for
                NxCheck(r, "manifest stepNo " + stepNo.ToStr() + " memo pass " + pass.ToStr(), parts.Join(","), c.out)
            end for
        end if
    end for

    ' A zone whose clocks change: the day's start, key and schedule as
    ' upstream has them, and tomorrow's schedule from the next midnight.
    g.nxTzOffsetSec = invalid
    g.nxTzOffsets = v.dst.zone
    small = []
    for i = 0 to 8
        small.Push(v.pool[i])
    end for
    for each c in v.dst.cases
        name = "dst at " + c.atSec.ToStr()
        day = NxLocalDay(c.atSec)
        NxCheck(r, name + " day", day.dayStartSec.ToStr() + " " + day.dayKey + " " + day.dayNumber.ToStr(), c.dayStartSec.ToStr() + " " + c.dayKey + " " + c.dayNumber.ToStr())
        NxClearManifests()
        parts = []
        for each b in NxManifestBlocks({ id: 7 }, small, c.atSec)
            parts.Push(NxToStr(b.item.ratingKey) + "@" + b.startSec.ToStr() + "-" + b.endSec.ToStr())
        end for
        NxCheck(r, name + " manifest", parts.Join(","), c.out)
        ' By index: a nested `for each` over the same array shares its place on
        ' a TV, so the outer loop would end after one case.
        nextStart& = 0
        for i = 0 to v.dst.cases.Count() - 1
            o = v.dst.cases[i]
            if o.dayStartSec > c.dayStartSec and (nextStart& = 0 or o.dayStartSec < nextStart&) then nextStart& = o.dayStartSec
        end for
        if nextStart& > 0 and nextStart& - c.dayStartSec <= 25 * 3600 then
            NxClearManifests()
            starts = 0
            for each b in NxScheduleGuide([{ id: 7, pool: small }], c.atSec)[0].blocks
                if b.startSec = nextStart& then starts = starts + 1
            end for
            NxCheck(r, name + " tomorrow from the next midnight", starts.ToStr(), "1")
        end if
    end for
    g.nxTzOffsets = invalid

    print "lineup vectors (upstream "; Left(v.upstream.commit, 7); "): "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

function NxLineupKeys(items as Object) as String
    keys = []
    for each it in items
        keys.Push(NxToStr(it.ratingKey))
    end for
    return keys.Join(",")
end function
