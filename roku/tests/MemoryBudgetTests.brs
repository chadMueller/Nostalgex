' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' The scan's memory budget from the device's reported limit (source/util/Values.brs, NxMemCeilingFor): a
' device at least as big as the Streaming Stick Plus keeps the ceiling it always had, 55%; a smaller one gets
' the ceiling that keeps the scan, the build's extra half and the app's fixed memory under 90% of its own
' limit. Returns the failure count.

function NxRunMemoryBudgetTests() as Integer
    r = { pass: 0, fail: 0 }
    NxCheck(r, "the Stick Plus: 55, as before", NxMemCeilingFor(501760).ToStr(), "55")
    NxCheck(r, "anything at or past the normal limit: 55", NxMemCeilingFor(480000).ToStr() + " " + NxMemCeilingFor(900000).ToStr() + " " + NxMemCeilingFor(2000000).ToStr(), "55 55 55")
    NxCheck(r, "a device that does not say: 55", NxMemCeilingFor(0).ToStr() + " " + NxMemCeilingFor(-1).ToStr(), "55 55")
    NxCheck(r, "just under the normal limit: a little under 55", NxMemCeilingFor(479999).ToStr(), "54")
    NxCheck(r, "a 256 MB limit: 50", NxMemCeilingFor(262144).ToStr(), "50")
    NxCheck(r, "a 128 MB limit: 40", NxMemCeilingFor(131072).ToStr(), "40")
    NxCheck(r, "a tiny limit never goes under 15", NxMemCeilingFor(50000).ToStr(), "15")
    ' The budget in titles at 7.5 KB a title (6 to 9 on the stick): what each limit holds before the scan stops.
    scanKB = NxMemCeilingFor(262144) * 262144 \ 100
    titles256 = scanKB * 2 \ 15
    NxCheck(r, "a 256 MB limit holds about 17,000 titles", NxToStr(titles256 > 16500 and titles256 < 18500), "true")
    ' Monotonic: a bigger limit never gets a lower ceiling.
    ok = true
    last = 0
    for kb = 60000 to 520000 step 20000
        c = NxMemCeilingFor(kb)
        if c < last then ok = false
        last = c
    end for
    NxCheck(r, "a bigger limit never gets a lower ceiling", NxToStr(ok), "true")
    ' The memory line of a load (source/util/MemTrace.brs): what ABOUT shows and what the registry keeps.
    trace = { limitKB: 501760, ceiling: 55, notes: [] }
    NxMemTraceAdd(trace, "SCAN", 21418, "TITLES", 33)
    NxMemTraceAdd(trace, "COLLECTIONS", 177, "COLLECTIONS", 35)
    NxMemTraceAdd(trace, "SCAN", 21418, "TITLES", 36)
    NxCheck(r, "trace: a step noted again replaces its line, the order stays", NxToStr(trace.notes.Count()) + " " + NxToStr(trace.notes[0].pct), "2 36")
    lines = NxMemTraceLines(trace)
    NxCheck(r, "trace: the limit line", lines[0], "APP LIMIT 501,760 KB. THE SCAN STOPS AT 55% OF IT.")
    NxCheck(r, "trace: a step line", lines[1], "SCAN: 21,418 TITLES, MEMORY AT 36%")
    NxCheck(r, "trace: collections line", lines[2], "COLLECTIONS: 177 COLLECTIONS, MEMORY AT 35%")
    NxMemTraceAdd(trace, "SAVED", 21418, "TITLES", -1)
    NxCheck(r, "trace: a percent the TV could not give is left out", NxMemTraceLines(trace)[3], "SAVED: 21,418 TITLES")
    NxCheck(r, "trace: no limit reported says so", NxMemTraceLines({ limitKB: 0, ceiling: 55, notes: [] })[0], "THIS TV DOES NOT REPORT ITS LIMIT. THE SCAN STOPS AT 55%.")
    NxCheck(r, "trace: nothing recorded, no lines", NxToStr(NxMemTraceLines(invalid).Count()), "0")
    reg = NxFakeRegistry()
    NxCheck(r, "trace: nothing saved reads as none", NxToStr(NxReadMemTrace(reg) = invalid), "true")
    NxMemTraceSave(reg, trace)
    back = NxReadMemTrace(reg)
    NxCheck(r, "trace: it round-trips through the registry", NxMemTraceLines(back).Join("|"), NxMemTraceLines(trace).Join("|"))
    reg.Write("memTrace", "not json")
    NxCheck(r, "trace: a damaged record reads as none", NxToStr(NxReadMemTrace(reg) = invalid), "true")
    NxCheck(r, "trace: a runtime with no memory monitor gives -1, not a crash", NxToStr(NxMemPercentSafe() >= -1), "true")
    ' The guard for a load that begins over the ceiling (a rescan, a library switch in Settings: the
    ' guide, the pools and the pages the process holds are already there): NxMemFullFor.
    NxCheck(r, "guard: under the ceiling never stops", NxToStr(NxMemFullFor(40, 43, 10)), "false")
    NxCheck(r, "guard: a load that began under the ceiling stops at it, as always", NxToStr(NxMemFullFor(43, 43, 10)) + NxToStr(NxMemFullFor(55, 55, 8)), "truetrue")
    NxCheck(r, "guard: base not known: the ceiling alone", NxToStr(NxMemFullFor(50, 43, invalid)) + NxToStr(NxMemFullFor(50, 43, -1)), "truetrue")
    NxCheck(r, "guard: began at 70% over a 43% ceiling, nothing read yet: goes on (it stopped on page one before)", NxToStr(NxMemFullFor(70, 43, 70)), "false")
    NxCheck(r, "guard: it goes on while the projected peak is under 90%", NxToStr(NxMemFullFor(80, 43, 70)), "false")
    NxCheck(r, "guard: and stops when the peak it is heading for reaches 90% (84 + half of 14 = 91)", NxToStr(NxMemFullFor(84, 43, 70)), "true")
    NxCheck(r, "guard: memory that fell below where it began does not count as growth", NxToStr(NxMemFullFor(60, 43, 70)), "false")
    NxCheck(r, "guard: never goes on at 90% or more, whatever it began at", NxToStr(NxMemFullFor(90, 43, 90)) + NxToStr(NxMemFullFor(95, 43, 95)), "truetrue")
    ' It reads the base the load stored (NxScanMemBaseSet); none stored is the ceiling alone.
    g = GetGlobalAA()
    g.nxScanMemBase = invalid
    fetcher = { memoryPercent: function() as Integer
        return 70
    end function }
    NxCheck(r, "guard: no base stored, 70% is over the ceiling", NxToStr(NxScanMemoryFull(fetcher)), "true")
    g.nxScanMemBase = 70
    NxCheck(r, "guard: a base of 70% stored, the same 70% is not", NxToStr(NxScanMemoryFull(fetcher)), "false")
    g.nxScanMemBase = invalid
    ' Room to build the channels (NxBuildRoomFor): the build takes half again what the load added.
    NxCheck(r, "build room: a first load at 51% from a 17% start builds (peak about 68%)", NxToStr(NxBuildRoomFor(51, 17)), "true")
    NxCheck(r, "build room: 45% from 26% builds (peak about 55%)", NxToStr(NxBuildRoomFor(45, 26)), "true")
    NxCheck(r, "build room: 70% from 17% is not built (peak about 96%)", NxToStr(NxBuildRoomFor(70, 17)), "false")
    NxCheck(r, "build room: just under, 69% from 17% (peak about 95%), is not built", NxToStr(NxBuildRoomFor(69, 17)), "false")
    NxCheck(r, "build room: 66% from 17% builds", NxToStr(NxBuildRoomFor(66, 17)), "true")
    NxCheck(r, "build room: a rescan that began at 70% and added nothing builds", NxToStr(NxBuildRoomFor(70, 70)), "true")
    NxCheck(r, "build room: 95% or more never builds, whatever it began at", NxToStr(NxBuildRoomFor(95, 95)) + NxToStr(NxBuildRoomFor(99, 99)), "falsefalse")
    NxCheck(r, "build room: base not known counts it as zero", NxToStr(NxBuildRoomFor(60, invalid)) + NxToStr(NxBuildRoomFor(64, invalid)), "truefalse")
    NxCheck(r, "build room: a TV that gives no reading is let through", NxToStr(NxBuildRoomFor(-1, invalid)), "true")
    NxCheck(r, "build room: memory that fell below where it began does not count as growth", NxToStr(NxBuildRoomFor(40, 60)), "true")
    ' The build takes about 22 MB and 1.9 KB an item of the largest server.
    g = GetGlobalAA()
    NxCheck(r, "build overhead: 19,700 items at a 501,760 KB limit", NxToStr(NxBuildOverheadPct(19700)), "11")
    NxCheck(r, "build overhead: 62,000 items at a 501,760 KB limit", NxToStr(NxBuildOverheadPct(62000)), "27")
    NxCheck(r, "build room: with the largest server's items counted, 58% heading for 90% is not built at a small limit", NxToStr(NxBuildRoomFor(58, 17, 600000)), "false")
    NxCheck(r, "build room: and a small server is", NxToStr(NxBuildRoomFor(40, 17, 3000)), "true")
    g.nxScanBiggest = 0
    guardNone = { memoryPercent: function() as Integer
        return 50
    end function }
    NxCheck(r, "guard: no items counted, the ceiling alone (50% is over 43, under 55 at the Plus's limit)", NxToStr(NxScanMemoryFull(guardNone)), "false")
    NxCheck(r, "guard: 50% with 100,000 items the largest: the build would take 42% more, so full", NxToStr(NxScanMemoryFull(guardNone, 100000)), "true")
    g.nxScanBiggest = 100000
    NxCheck(r, "guard: the largest server counted from the load's start", NxToStr(NxScanMemoryFull(guardNone)), "true")
    g.nxScanBiggest = 0
    NxCheck(r, "memory percent: 97,000 KB over a 153,600 KB limit is 63, not a multiple of the real percent's step", NxToStr(NxMemPercentOf(97000, 153600)) + " " + NxToStr(NxMemPercentOf(0, 153600)) + " " + NxToStr(NxMemPercentOf(5, 0)), "63 0 0")
    NxCheck(r, "build room: the words", NxBuildRoomLine(21093), "THIS TV RAN OUT OF ROOM BEFORE BUILDING CHANNELS FROM 21,093 TITLES. TURN OFF A LIBRARY TO FIT.")
    NxMarginRuleCases(r)
    NxPlexGuardCases(r)
    NxPlexSeedCases(r)
    print "memory budget cases: "; r.pass; " passed, "; r.fail; " failed"
    return r.fail
end function

' The Plex scan's guard (source/plex/PlexLibrary.brs): records a page at a time, memory checked per page and per
' batch of shows, a cut keeps what was read and counts the rest, as the Jellyfin scan does (I-091).
sub NxPlexGuardCases(r as Object)
    g = GetGlobalAA()
    server = { machineIdentifier: "srv", uri: "http://fake", lanUri: "", accessToken: "t", name: "Fake" }
    sections = [{ key: "1", title: "Movies", type: "movie" }, { key: "2", title: "TV Shows", type: "show" }]

    ' Memory low: everything is read, no cut.
    g.nxPlexTestNet = NxFakePlexNet(sections, 1000, 20, 3)
    g.nxMemPercentTest = 10
    g.nxScanMemBase = invalid
    NxScanCapSet(0)
    all = NxPlexScanServer(server, 0)
    NxCheck(r, "plex guard: memory low reads every title", NxToStr(all.Count()) + "," + NxToStr(NxScanCapped()), "1060,0")
    NxCheck(r, "plex guard: films come before episodes, one record each", all[0].title + "|" + all[999].title + "|" + NxToStr(all[1000].type), "Film 0|Film 999|episode")

    ' Memory full: the first page of films is kept, the rest counted, no section after it read.
    NxScanCapSet(0)
    g.nxMemPercentTest = 60
    cut = NxPlexScanServer(server, 0)
    NxCheck(r, "plex guard: memory full stops after the first page of films", NxToStr(cut.Count()) + "," + NxToStr(NxScanCapped()), "300,300")
    NxCheck(r, "plex guard: and counts the films left and the later section's episodes (type 4)", NxToStr(NxScanCapTotal()), "1060")

    ' A show section: stops after a batch of 25 shows, counting its episodes.
    g.nxPlexTestNet = NxFakePlexNet([{ key: "2", title: "TV Shows", type: "show" }], 0, 60, 3)
    NxScanCapSet(0)
    shows = NxPlexScanServer(server, 0)
    NxCheck(r, "plex guard: memory full stops a show section after a batch of 25 shows", NxToStr(shows.Count()) + "," + NxToStr(NxScanCapped()) + "," + NxToStr(NxScanCapTotal()), "75,75,180")

    ' Memory low in a show section reads all its shows.
    g.nxMemPercentTest = 10
    NxScanCapSet(0)
    NxCheck(r, "plex guard: memory low reads every episode of every show", NxToStr(NxPlexScanServer(server, 0).Count()) + "," + NxToStr(NxScanCapped()), "180,0")

    ' A last page that crosses the ceiling ends its section there, the next one counted and not started (N-090).
    g.nxPlexTestNet = NxFakePlexNet(sections, 250, 20, 3)
    g.nxMemPercentTest = 60
    g.nxScanMemBase = invalid
    NxScanCapSet(0)
    lastPage = NxPlexScanServer(server, 0)
    NxCheck(r, "plex guard: a film section whose one page crosses the ceiling ends the scan there, the shows counted", NxToStr(lastPage.Count()) + "," + NxToStr(NxScanCapped()) + "," + NxToStr(NxScanCapTotal()), "250,250,310")
    ' A load that began at 70% over the ceiling reads on while the peak stays under 90%.
    g.nxPlexTestNet = NxFakePlexNet(sections, 1000, 20, 3)
    g.nxMemPercentTest = 70
    g.nxScanMemBase = 70
    NxScanCapSet(0)
    NxCheck(r, "plex guard: a load that began at 70% reads everything while memory holds at 70%", NxToStr(NxPlexScanServer(server, 0).Count()) + "," + NxToStr(NxScanCapped()), "1060,0")

    ' A page that fails skips its section and leaves none of its records behind.
    g.nxMemPercentTest = 10
    g.nxScanMemBase = invalid
    net = NxFakePlexNet(sections, 1000, 20, 3)
    net.failFilmPage = 600
    g.nxPlexTestNet = net
    NxScanCapSet(0)
    kept = NxPlexScanServer(server, 0)
    NxCheck(r, "plex guard: a failed page skips the film section with none of its records left", NxToStr(kept.Count()) + "," + NxToStr(kept[0].type), "60,episode")

    g.nxPlexTestNet = invalid
    g.nxMemPercentTest = invalid
    g.nxScanMemBase = invalid
    NxScanCapSet(0)
end sub

' A Plex server answering from memory: `films` films (300 a page, as the scan asks), `shows` shows of `eps`
' episodes each, a totalSize on every answer, type=4 counting episodes, allLeaves per show. get(url) answers
' { code, json } as NxPlexServerGet does.
function NxFakePlexNet(sections as Object, films as Integer, shows as Integer, eps as Integer) as Object
    return {
        sections: sections, films: films, shows: shows, eps: eps, failFilmPage: -1, calls: 0,
        get: function(url as String) as Object
            m.calls = m.calls + 1
            if Instr(1, url, "/allLeaves") > 0 then
                at = Instr(1, url, "/library/metadata/s") + 19
                idx = NxFakeQuery("n" + Mid(url, at), "n")
                rows = []
                for e = 0 to m.eps - 1
                    rows.Push({ ratingKey: "e" + idx.ToStr() + "-" + e.ToStr(), title: "Ep " + e.ToStr(), duration: 1500000, Media: [{ container: "mkv", videoCodec: "h264", audioCodec: "aac", Part: [{ key: "/p" }] }] })
                end for
                return { code: 200, json: { MediaContainer: { size: rows.Count(), Metadata: rows } } }
            end if
            if Instr(1, url, "/all?") = 0 then
                return { code: 200, json: { MediaContainer: { Directory: m.sections } } }
            end if
            isShow = Instr(1, url, "/library/sections/2/") > 0
            start = NxFakeQuery(url, "X-Plex-Container-Start=")
            size = NxFakeQuery(url, "X-Plex-Container-Size=")
            total = m.films
            if isShow then total = m.shows
            if isShow and Instr(1, url, "type=4") > 0 then total = m.shows * m.eps
            rows = []
            if size > 0 then
                if not isShow and m.failFilmPage >= 0 and start >= m.failFilmPage then return { code: 500, json: invalid }
                for i = start to NxMinInt(start + size, total) - 1
                    if isShow then
                        rows.Push({ ratingKey: "s" + i.ToStr(), title: "Show " + i.ToStr(), Genre: [{ tag: "Comedy" }] })
                    else
                        rows.Push({ ratingKey: "m" + i.ToStr(), title: "Film " + i.ToStr(), duration: 6000000, year: 1990, Genre: [{ tag: "Drama" }], Media: [{ container: "mkv", videoCodec: "h264", audioCodec: "aac", Part: [{ key: "/p" }] }] })
                    end if
                end for
            end if
            return { code: 200, json: { MediaContainer: { size: rows.Count(), totalSize: total, Metadata: rows } } }
        end function
    }
end function

' The number after `name` in a URL. Digits are read by hand: the off-device interpreter's Val() gives 0 for "300&X-Plex-..."
' where a TV's gives 300, which made a fake server answer the first page for ever (the hang of the first Plex guard run
' was this, not the app).
function NxFakeQuery(url as String, name as String) as Integer
    at = Instr(1, url, name)
    if at = 0 then return 0
    at = at + Len(name)
    digits = ""
    while at <= Len(url) and Asc(Mid(url, at, 1)) >= 48 and Asc(Mid(url, at, 1)) <= 57
        digits = digits + Mid(url, at, 1)
        at = at + 1
    end while
    return Val(digits)
end function

' A sideload's seed (NxPlexApplySeed): saved as a sign-in saves its own, with nothing looked up at plex.tv.
sub NxPlexSeedCases(r as Object)
    reg = NxFakeRegistry()
    seed = { token: "tok", account: { id: "1", name: "Stand-in" }, servers: [{ name: "A", machineIdentifier: "ida", uri: "http://192.0.2.45:32401" }, { name: "B", machineIdentifier: "idb", uri: "http://192.0.2.45:32402" }, { name: "no address", machineIdentifier: "idc", uri: "" }] }
    NxCheck(r, "seed: the account's name comes back", NxPlexApplySeed(reg, seed), "Stand-in")
    saved = ParseJson(reg.Read("servers"))
    NxCheck(r, "seed: two servers with an address are saved, one without is not", NxToStr(saved.Count()), "2")
    NxCheck(r, "seed: each is reached at its address as given, already checked", NxToStr(saved[0].checked) + " " + saved[0].lanUri + " " + saved[0].accessToken, "true http://192.0.2.45:32401 tok")
    NxCheck(r, "seed: the token and the kind", reg.Read("token") + " " + reg.Read("kind"), "tok plex")
    NxCheck(r, "seed: every server is on, no server pick owed, the library pick is", NxToStr(ParseJson(reg.Read("serverChoices")).Count()) + " [" + reg.Read("needsPick") + "] " + reg.Read("needsLibraryPick"), "2 [] 1")
    NxCheck(r, "seed: it marks the sign-in as a seed", reg.Read("devSeed"), "1")
    NxCheck(r, "seed: no token, no servers, or no page is no sign-in", NxPlexApplySeed(NxFakeRegistry(), { servers: seed.servers }) + NxPlexApplySeed(NxFakeRegistry(), { token: "t", servers: [] }) + NxPlexApplySeed(NxFakeRegistry(), invalid), "")
end sub

' The margin rule (source/util/Values.brs, NxScanProjectedFull, NxBuildRoomFor): a device under the Stick Plus's limit stops
' reading where the app's reading, the build's cost and the collections sweep's reserve reach 80% and refuses the build at
' 90%, so a cut scan leaves room for what it read; a device at or over that limit keeps the stops it had (90 and 95).
sub NxMarginRuleCases(r as Object)
    g = GetGlobalAA()
    ' Constants at the limits the stick runs used.
    NxCheck(r, "margin: build cost at 150 MB for 9,675 items, as a percent of the limit", NxToStr(NxBuildOverheadPctFor(9675, 153600)), "29")
    NxCheck(r, "margin: build cost at 256 MB for 19,700 items", NxToStr(NxBuildOverheadPctFor(19700, 262144)), "25")
    NxCheck(r, "margin: the sweep's reserve at 150 MB and 256 MB", NxToStr(NxSweepReservePct(153600)) + " " + NxToStr(NxSweepReservePct(262144)), "8 5")
    NxCheck(r, "margin: no reserve at or over the Stick Plus's limit", NxToStr(NxSweepReservePct(480000)) + " " + NxToStr(NxSweepReservePct(501760)) + " " + NxToStr(NxSweepReservePct(0)), "0 0 0")
    NxCheck(r, "margin: the stops, small and normal", NxToStr(NxScanStopPct(153600)) + " " + NxToStr(NxBuildRefusePct(153600)) + " " + NxToStr(NxScanStopPct(501760)) + " " + NxToStr(NxBuildRefusePct(501760)), "80 90 90 95")
    ' The scan's edge at 150 MB with 9,675 items: 29 + 8 = 37 points on top of the reading.
    NxCheck(r, "margin: 150 MB, 42% with 9,675 items still reads, 43% stops", NxToStr(NxScanProjectedFull(42, 9675, 153600)) + NxToStr(NxScanProjectedFull(43, 9675, 153600)), "falsetrue")
    ' The same reading with the normal limit is not a stop (the old rule: 90).
    NxCheck(r, "margin: a Stick Plus at 43% with 9,675 items reads on", NxToStr(NxScanProjectedFull(43, 9675, 501760)), "false")
    ' A normal device's rule is the one it had: reading + Int((22000 + 1.9 x items) x 100 / limit) >= 90.
    same = true
    for each lim in [501760, 480000, 900000, 2000000, 0]
        eff = lim
        if eff = 0 then eff = 501760
        for each items in [0, 100, 5000, 19700, 62000, 100000]
            for pct = 20 to 89 step 3
                was = pct + Int((22000# + items * 1.9#) * 100# / eff) >= 90
                if was <> NxScanProjectedFull(pct, items, lim) then same = false
            end for
        end for
    end for
    NxCheck(r, "margin: at or over 480,000 KB the stop is exactly the one it was", NxToStr(same), "true")
    ' The build's refusal at 150 MB: 90, with the build's cost counted.
    g.nxMemLimitTest = 153600
    NxCheck(r, "margin: 150 MB, 60% with 9,675 items to build is built (89), 62% is not (91)", NxToStr(NxBuildRoomFor(60, 40, 9675)) + NxToStr(NxBuildRoomFor(62, 40, 9675)), "truefalse")
    NxCheck(r, "margin: 150 MB, three servers read (growth 40 points) with 9,675 items the largest: the build's cost is the measure, not half the growth", NxToStr(NxBuildRoomFor(55, 15, 9675)) + NxToStr(NxBuildRoomFor(62, 15, 9675)), "truefalse")
    NxCheck(r, "margin: 150 MB, 90% is never built, 89% that added nothing is", NxToStr(NxBuildRoomFor(90, 90)) + NxToStr(NxBuildRoomFor(89, 89)), "falsetrue")
    ' What the limit the test sets says for the scan's own check (NxScanMemoryFull).
    g.nxScanMemBase = 26
    g.nxScanBiggest = 0
    guard42 = { memoryPercent: function() as Integer
        return 42
    end function }
    NxCheck(r, "margin: the scan at 150 MB, 42% with nothing counted yet: 24 MB and the reserve make 24, so it reads on", NxToStr(NxScanMemoryFull(guard42, 0)), "false")
    NxCheck(r, "margin: and with 9,675 items counted at 42% it still reads (79); at 43% it stops", NxToStr(NxScanMemoryFull(guard42, 9675)), "false")
    guard44 = { memoryPercent: function() as Integer
        return 44
    end function }
    NxCheck(r, "margin: 150 MB, 44% with 1,000 items is past the old ceiling of 43 and reads on (44 + 17 + 8 = 69)", NxToStr(NxScanMemoryFull(guard44, 1000)), "false")
    g.nxMemLimitTest = 501760
    g.nxScanMemBase = 26
    NxCheck(r, "margin: a Stick Plus keeps its ceiling: 55% stops, 54% reads on", NxToStr(NxScanMemoryFull({ memoryPercent: function() as Integer
        return 55
    end function }, 100)) + NxToStr(NxScanMemoryFull({ memoryPercent: function() as Integer
        return 54
    end function }, 100)), "truefalse")
    g.nxMemLimitTest = 153600
    g.nxScanBiggest = 20000
    NxCheck(r, "margin: with 20,000 items the largest, 42% stops at 150 MB (42 + 41 + 8)", NxToStr(NxScanMemoryFull(guard42, 0)), "true")
    g.nxScanBiggest = 0
    ' A cut scan leaves room to build what it read: whatever the scan did not stop at, the check before the build,
    ' after the sweep's measured 6 points at 150 MB, lets through (base 26 and 40, sizes from 0 to 60,000 items).
    ok = true
    worst = 0
    for each lim in [153600, 200000, 262144, 400000]
        g.nxMemLimitTest = lim
        sweep = Int(9000# * 100# / lim + 0.999#)
        for each items in [1, 300, 3000, 10000, 20000, 40000, 60000]
            for each base in [26, 40]
                for pct = base to 95
                    if not NxScanProjectedFull(pct, items, lim) then
                        if not NxBuildRoomFor(pct + sweep, base, items) then ok = false
                        peak = pct + sweep + Int((22000# + items * 1.9#) * 100# / lim)
                        if peak > worst then worst = peak
                    end if
                end for
            end for
        end for
    end for
    NxCheck(r, "margin: a scan that was not stopped is never refused after the sweep, 150 to 400 MB", NxToStr(ok), "true")
    NxCheck(r, "margin: and its peak by the measured cost stays under 85%", NxToStr(worst < 85), "true")
    g.nxMemLimitTest = invalid
    g.nxScanMemBase = invalid
    g.nxScanBiggest = 0
end sub
