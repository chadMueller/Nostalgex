' Schedule benchmark, run by `tests/bench/run.sh schedule <pools log>`: the
' pools from a channel-build log (POOL lines, tests/bench/run.sh) over
' out/bench/library.json, every channel with enough items in the guide, then
' NxScheduleGuide timed as LibraryTask runs it: cold, as after a library load,
' again with the day's schedules in memory, as the hourly re-check runs it,
' and for channels built afresh with the schedules kept, as a package switch
' runs it. Prints each channel's schedule, so two runs' logs
' can be diffed, BENCH line aside, for an identical schedule.
sub Main(args = invalid as Dynamic)
    lib = ParseJson(ReadAsciiFile("pkg:/out/bench/library.json"))
    byKey = {}
    for each it in lib.items
        it.serverIndex = 0
        byKey[NxToStr(it.ratingKey)] = it
    end for
    config = ParseJson(ReadAsciiFile("pkg:/data/channels.json"))
    pools = {}
    for each line in ReadAsciiFile("pkg:/out/bench/pools.log").Split(Chr(10))
        if Left(line, 5) = "POOL " then
            parts = line.Split(" ")
            pool = []
            if parts.Count() > 3 then
                for each kv in parts[3].Split(",")
                    it = byKey[kv.Split(":")[0]]
                    if it <> invalid then pool.Push(it)
                end for
            end if
            pools[parts[1]] = pool
        end if
    end for
    ' A fixed instant: 2026-10-15 20:00 UTC, 4 PM at UTC-4.
    nowSec& = 1792094400&
    GetGlobalAA().nxTzOffsetSec = -4 * 3600
    ordered = []
    for each def in config.channels
        pool = pools[def.id.ToStr()]
        minItems = 50
        if NxTruthy(def.minItems) then minItems = def.minItems
        if pool <> invalid and pool.Count() >= minItems then
            ordered.Push({
                id: def.id, number: def.number, name: NxToStr(def.name), colorHex: NxToStr(def.colorHex),
                isPremiereChannel: def.isPremiereChannel, timeRestrictions: def.timeRestrictions,
                built: true, pool: pool
            })
        end if
    end for

    NxClearManifests()
    timer = CreateObject("roTimespan")
    cold = NxScheduleGuide(ordered, nowSec&)
    coldMs = timer.TotalMilliseconds()
    timer.Mark()
    warm = NxScheduleGuide(ordered, nowSec& + 30)
    warmMs = timer.TotalMilliseconds()
    ' A package switch: every channel built afresh, the day's schedules kept.
    rebuilt = []
    for each ch in ordered
        copy = {}
        for each k in ch
            if LCase(k) <> "nxmemo" then copy[k] = ch[k]
        end for
        rebuilt.Push(copy)
    end for
    timer.Mark()
    switched = NxScheduleGuide(rebuilt, nowSec& + 60)
    switchMs = timer.TotalMilliseconds()
    for each ch in cold
        print "COLD "; FormatJson(ch)
    end for
    for each ch in warm
        print "WARM "; FormatJson(ch)
    end for
    for each ch in switched
        print "SWITCH "; FormatJson(ch)
    end for
    print "BENCH "; ordered.Count().ToStr(); " channels: cold "; coldMs.ToStr(); " ms, warm "; warmMs.ToStr(); " ms, switch "; switchMs.ToStr(); " ms"
end sub
