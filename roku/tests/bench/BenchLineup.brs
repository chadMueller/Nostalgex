' Lineup schedule benchmark: a made-up large library (12,000 items, 600 shows),
' the real channel list from data/channels.json with pools that overlap the way
' real ones do (windows of the same library), and NxScheduleGuide timed as
' LibraryTask runs it: cold, as after a library load, again with the day's
' schedules in memory, as the hourly re-check runs it, and for channels built
' afresh with the schedules kept, as a package switch runs it. Nothing to
' load, so the same file runs off-device and on a TV (copy it over
' source/main.brs of a staged build, as scripts/deploy.sh --live does).
'
' Prints "DOUBLED": the share of the day's channel-minutes in which a title is
' on two or more channels at once, the number the lineup packing brings down.
' `NxSetLineup(ordered)` lines are the engine's registration of the lineup; a
' log from before the engine had one is made by deleting them.
'
'   BENCH <wide|crowded>: <channels> channels (<n> scheduled), <items> items: cold <ms>, warm <ms>, switch <ms>, doubled <pct>%
sub Main(args = invalid as Dynamic)
    config = ParseJson(ReadAsciiFile("pkg:/data/channels.json"))
    ' A fixed instant: 2026-10-15 20:00 UTC, 4 PM at UTC-4.
    nowSec& = 1792094400&
    GetGlobalAA().nxTzOffsetSec = -4 * 3600
    ' Wide: pools of hundreds to thousands out of 12,000 items, so a channel's day
    ' is a sliver of its pool and titles seldom meet.
    NxBenchScenario("wide", config, NxBenchItems(12000), [3000, 1500, 800, 400, 200, 120, 80], nowSec&)
    ' Crowded: pools of 40 to 200 out of 600 items, every title on dozens of
    ' channels, as a small library's channels are (94% of one device's minutes were
    ' a title on two channels at once).
    NxBenchScenario("crowded", config, NxBenchItems(600), [200, 120, 80, 60, 40], nowSec&)
    print "BENCH DONE"
    ' On a TV (it gets launch parameters) stay up, so the console can be read.
    if args <> invalid then
        while true
            Sleep(1000)
        end while
    end if
end sub

' One lineup of the real channels over `items`, each channel's pool a window of
' them (`sizes` in turn), timed cold, warm and as a package switch.
sub NxBenchScenario(label as String, config as Object, items as Object, sizes as Object, nowSec as LongInteger)
    ordered = []
    c = 0
    for each def in config.channels
        size = sizes[c mod sizes.Count()]
        stride = 1 + (c mod 3)
        start = (c * 211) mod items.Count()
        pool = []
        for j = 0 to size - 1
            pool.Push(items[(start + j * stride) mod items.Count()])
        end for
        ordered.Push({
            id: def.id, number: def.number, name: NxToStr(def.name), colorHex: NxToStr(def.colorHex),
            isPremiereChannel: def.isPremiereChannel, timeRestrictions: def.timeRestrictions,
            built: true, pool: pool
        })
        c = c + 1
    end for

    NxClearManifests()
    timer = CreateObject("roTimespan")
    NxSetLineup(ordered)
    cold = NxScheduleGuide(ordered, nowSec)
    coldMs = timer.TotalMilliseconds()
    timer.Mark()
    NxSetLineup(ordered)
    warm = NxScheduleGuide(ordered, nowSec + 30)
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
    NxSetLineup(rebuilt)
    switched = NxScheduleGuide(rebuilt, nowSec + 60)
    switchMs = timer.TotalMilliseconds()
    doubled = NxBenchDoubled(cold, NxLocalDay(nowSec).dayStartSec)
    ' By channel: the whole guide is a few MB of text, which a TV's FormatJson cut short once.
    same = cold.Count() = ordered.Count() and warm.Count() = ordered.Count() and switched.Count() = ordered.Count()
    for i = 0 to cold.Count() - 1
        if same then
            if FormatJson(cold[i]) <> FormatJson(warm[i]) or FormatJson(warm[i]) <> FormatJson(switched[i]) then same = false
        end if
    end for
    print "BENCH "; label; ": "; ordered.Count().ToStr(); " channels ("; cold.Count().ToStr(); " scheduled), "; items.Count().ToStr(); " items: cold "; coldMs.ToStr(); " ms, warm "; warmMs.ToStr(); " ms, switch "; switchMs.ToStr(); " ms, doubled "; Str(doubled); "%, same on re-check "; same
    NxClearManifests()
end sub

' 12,000 made-up items: two in five films (some in "Part n" families), the rest
' episodes of 600 shows. Deterministic.
function NxBenchItems(count as Integer) as Object
    items = []
    for i = 0 to count - 1
        it = { ratingKey: "k" + i.ToStr(), serverIndex: 0, librarySource: "plex", genres: [], year: 1980 + (i mod 40), summary: "", contentRating: "PG", rating: 6, userRating: 0, viewCount: 0, addedAt: 1500000000, studio: "" }
        if (i mod 5) < 2 then
            it.type = "movie"
            it.title = "Film " + i.ToStr()
            if (i mod 29) = 0 then it.title = "Saga " + (i \ 29).ToStr() + " Part 1"
            if (i mod 29) = 1 then it.title = "Saga " + (i \ 29).ToStr() + " Part 2"
            it.duration = 85 + ((i * 7) mod 50)
        else
            it.type = "episode"
            it.title = "Show " + (i mod 600).ToStr()
            it.episodeTitle = "Episode " + i.ToStr()
            it.duration = 22
            if (i mod 3) = 0 then it.duration = 44
        end if
        if (i mod 40) = 0 then it.addedAt = 1792094400& - 3 * 86400
        if (i mod 11) = 0 then it.contentRating = "R"
        items.Push(it)
    end for
    return items
end function

' The share (percent) of the day's channel-minutes in which a title is on two or more
' channels at once: per title, its blocks' total seconds less their union.
function NxBenchDoubled(channels as Object, dayStart as LongInteger) as Float
    dayEnd& = dayStart + 86400
    byKey = {}
    byKey.SetModeCaseSensitive()
    total& = 0
    for each ch in channels
        for each b in ch.blocks
            s = b.startSec
            e = b.endSec
            if s < dayStart then s = dayStart
            if e > dayEnd& then e = dayEnd&
            if e > s then
                total& = total& + (e - s)
                list = byKey[b.ratingKey]
                if list = invalid then
                    list = []
                    byKey[b.ratingKey] = list
                end if
                list.Push([s, e])
            end if
        end for
    end for
    if total& = 0 then return 0
    doubled& = 0
    for each key in byKey
        list = byKey[key]
        if list.Count() > 1 then
            ' Insertion sort by start.
            sorted = []
            for each iv in list
                i = sorted.Count()
                sorted.Push(iv)
                while i > 0 and sorted[i - 1][0] > iv[0]
                    sorted[i] = sorted[i - 1]
                    i = i - 1
                end while
                sorted[i] = iv
            end for
            sum& = 0
            union& = 0
            curS = sorted[0][0]
            curE = sorted[0][1]
            for each iv in sorted
                sum& = sum& + (iv[1] - iv[0])
            end for
            for k = 1 to sorted.Count() - 1
                if sorted[k][0] <= curE then
                    if sorted[k][1] > curE then curE = sorted[k][1]
                else
                    union& = union& + (curE - curS)
                    curS = sorted[k][0]
                    curE = sorted[k][1]
                end if
            end for
            union& = union& + (curE - curS)
            doubled& = doubled& + (sum& - union&)
        end if
    end for
    return doubled& * 100.0 / total&
end function

