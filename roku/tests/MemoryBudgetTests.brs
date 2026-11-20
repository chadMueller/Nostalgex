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
    NxCheck(r, "build room: the words", NxBuildRoomLine(21093), "THIS TV RAN OUT OF ROOM BEFORE BUILDING CHANNELS FROM 21,093 TITLES. TURN OFF A LIBRARY TO FIT.")
    NxPlexGuardCases(r)
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
