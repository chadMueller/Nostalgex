' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Library selection (I-092, source/util/LibrarySections.brs): the saved set of
' sections turned off, the lists a scan and the picker read, and a scan that
' leaves the ones that are off alone (Plex through its section list, Jellyfin
' through its views). Returns the failure count.

function NxRunLibrarySectionsTests() as Integer
    r = { pass: 0, fail: 0 }

    ' The saved choice: opting out, nothing saved is everything on.
    reg = NxFakeRegistry()
    off = NxDeselectedSections(reg)
    NxCheck(r, "never chosen: every section is on", NxToStr(NxSectionIsOn(off, "srv1", "3")), "true")
    NxCheck(r, "no registry: every section is on", NxToStr(NxSectionIsOn(NxDeselectedSections(invalid), "srv1", "3")), "true")
    off = { "srv1::3": true, "srv2::1": true }
    NxSaveDeselectedSections(reg, off)
    back = NxDeselectedSections(reg)
    NxCheck(r, "a turned off section reads back off", NxToStr(NxSectionIsOn(back, "srv1", "3")) + NxToStr(NxSectionIsOn(back, "srv2", "1")), "falsefalse")
    NxCheck(r, "the same key on another server is on", NxToStr(NxSectionIsOn(back, "srv2", "3")), "true")
    NxCheck(r, "a section never seen is on", NxToStr(NxSectionIsOn(back, "srv1", "99")), "true")
    NxCheck(r, "stored sorted", reg.Read("deselectedSections"), "[""srv1::3"",""srv2::1""]")
    reg.Write("deselectedSections", "not json")
    NxCheck(r, "an unreadable value is everything on", NxToStr(NxDeselectedSections(reg).Count()), "0")
    NxSaveDeselectedSections(reg, { "a::1": true, "a::2": false })
    NxCheck(r, "a false entry is not saved", reg.Read("deselectedSections"), "[""a::1""]")

    ' The Apple TV's labels.
    NxCheck(r, "type label: show", NxSectionTypeLabel("show", "Shows"), "TV Shows")
    NxCheck(r, "type label: movies", NxSectionTypeLabel("movie", "Films"), "Movies")
    NxCheck(r, "type label: a film library named like music videos", NxSectionTypeLabel("movie", "Music Videos"), "Music Videos")
    NxCheck(r, "type label: musicvideo", NxSectionTypeLabel("musicvideo", "x"), "Music Videos")
    NxCheck(r, "type label: unknown", NxSectionTypeLabel("mixed", "x"), "Library")
    s = { serverName: "Home", title: "Films", type: "movie", hidden: false }
    NxCheck(r, "subtitle: one server", NxSectionSubtitle(s, false), "Movies")
    NxCheck(r, "subtitle: several servers", NxSectionSubtitle(s, true), "Home · Movies")
    s.hidden = true
    NxCheck(r, "subtitle: hidden on Jellyfin", NxSectionSubtitle(s, false), "Movies · HIDDEN ON JELLYFIN")

    ' The picker is for a choice between sections.
    NxCheck(r, "picker: none, none to choose", NxToStr(NxPickerWanted([])), "false")
    NxCheck(r, "picker: one, none to choose", NxToStr(NxPickerWanted([{}])), "false")
    NxCheck(r, "picker: two", NxToStr(NxPickerWanted([{}, {}])), "true")
    NxCheck(r, "picker: one hidden library (it starts off, so the screen offers it)", NxToStr(NxPickerWanted([{ hidden: true }])), "true")
    NxCheck(r, "picker: one library that is not hidden", NxToStr(NxPickerWanted([{ hidden: false }])), "false")

    ' Plex sections: movie and show sections only.
    server = { machineIdentifier: "srv1", name: "Home" }
    refs = NxPlexSectionRefs(server, [{ key: "1", title: "Films", type: "movie" }, { key: "2", title: "Shows", type: "show" }, { key: "3", title: "Photos", type: "photo" }, { key: "4", title: "Music", type: "artist" }])
    NxCheck(r, "plex: movie and show sections are listed", NxToStr(refs.Count()) + " " + refs[0].key + refs[1].key + " " + refs[0].serverId + " " + refs[1].serverName, "2 12 srv1 Home")

    ' Jellyfin libraries, with the ones the plain list leaves out marked hidden.
    views = [{ Id: "a", Name: "Films", CollectionType: "movies" }, { Id: "b", Name: "Shows", CollectionType: "tvshows" }, { Id: "c", Name: "Playlists", CollectionType: "playlists" }, { Id: "d", Name: "Secret", CollectionType: "movies" }]
    refs = NxMbSectionRefs(server, views, { d: true })
    NxCheck(r, "jellyfin: libraries with videos, playlists left out", NxToStr(refs.Count()) + " " + refs[0].key + refs[1].key + refs[2].key, "3 abd")
    NxCheck(r, "jellyfin: the hidden one is marked", NxToStr(refs[2].hidden) + NxToStr(refs[0].hidden), "truefalse")
    NxCheck(r, "hidden off: none switched on", NxToStr(NxAnyHiddenOn(refs, {})), "false")
    NxCheck(r, "hidden on: switched on", NxToStr(NxAnyHiddenOn(refs, { "srv1::d": true })), "true")
    NxCheck(r, "sections on count: the hidden one starts off", NxToStr(NxSectionsOnCount(refs, { "srv1::a": true }, {})), "1")
    NxCheck(r, "sections on count: the hidden one switched on", NxToStr(NxSectionsOnCount(refs, { "srv1::a": true }, { "srv1::d": true })), "2")

    ' What a load saves.
    old = [{ serverId: "s1", key: "d", title: "Secret", type: "movie", hidden: true }, { serverId: "s2", key: "1", title: "Other", type: "movie", hidden: false }]
    fresh = [{ serverId: "s1", key: "a", title: "Films", type: "movie", hidden: false }, { serverId: "s1", key: "d", title: "Secret", type: "movie", hidden: false }]
    merged = NxMergeSections(fresh, old)
    NxCheck(r, "merge: a scan keeps a hidden mark it cannot see, and the other server's sections", NxToStr(merged.Count()) + " " + NxToStr(merged[1].hidden) + " " + merged[2].serverId, "3 true s2")
    NxCheck(r, "merge: the server name from the saved server list", NxNameSections([{ serverId: "s1", serverName: "s1" }], [{ machineIdentifier: "s1", name: "Home" }])[0].serverName, "Home")

    ' A scan leaves the sections that are turned off alone.
    NxScanSectionsReset()
    fetcher = NxMbSectionFetcher()
    all = NxMbScanServer(fetcher, "jellyfin", "u", 0, invalid, false, invalid, "s1")
    NxCheck(r, "scan: with nothing off it reads both libraries", NxToStr(all.Count()) + " " + NxToStr(fetcher.asked.Count()), "4 2")
    NxCheck(r, "scan: and saw both sections", NxToStr(NxScanSections().Count()), "2")
    NxScanSectionsReset()
    fetcher = NxMbSectionFetcher()
    some = NxMbScanServer(fetcher, "jellyfin", "u", 0, invalid, false, { "s1::lib1": true }, "s1")
    NxCheck(r, "scan: a library turned off is never asked for", NxToStr(some.Count()) + " " + NxToStr(fetcher.asked.Count()) + " " + fetcher.asked[0], "2 1 lib2")
    NxCheck(r, "scan: it still lists it for Settings", NxToStr(NxScanSections().Count()), "2")
    NxCheck(r, "the same set on another server leaves it on", NxToStr(NxMbScanServer(NxMbSectionFetcher(), "jellyfin", "u", 0, invalid, false, { "s1::lib1": true }, "s2").Count()), "4")
    ' A scan leaves a saved hidden library alone unless it is switched on.
    scanReg = NxFakeRegistry()
    NxSaveSections(scanReg, [{ serverId: "s1", key: "lib1", title: "A", type: "movie", hidden: false }, { serverId: "s1", key: "lib2", title: "B", type: "movie", hidden: true }])
    NxCheck(r, "scan set: a saved hidden library is left out", NxToStr(NxScanOffSet(scanReg).Count()) + NxToStr(NxScanOffSet(scanReg).DoesExist("s1::lib2")), "1true")
    NxSaveIncludedHiddenSections(scanReg, { "s1::lib2": true })
    NxCheck(r, "scan set: switched on, it is read", NxToStr(NxScanOffSet(scanReg).Count()), "0")
    kept = NxSectionsKept([{ key: "1" }, { key: "2" }, { key: "3" }], { "srv::2": true }, "srv", "key")
    NxCheck(r, "plex: the section list without the turned off one", NxToStr(kept.Count()) + kept[0].key + kept[1].key, "213")

    ' The library pick a sign-in owes (#331): the launch asks for it again
    ' instead of reading every library, until it is answered or not needed.
    for each kind in ["plex", "jellyfin", "emby"]
        reg = NxFakeRegistry()
        reg.Write("servers", "[{}]")
        NxCheck(r, kind + ": a saved sign-in, nothing owed, reads at launch", NxToStr(NxLaunchReadsLibrary(reg, kind, "tok")), "true")
        NxOweLibraryPick(reg)
        NxCheck(r, kind + ": owed after the sign-in saves its servers", NxToStr(NxLibraryPickOwed(reg)), "true")
        NxCheck(r, kind + ": a pick owed doesn't read at launch", NxToStr(NxLaunchReadsLibrary(reg, kind, "tok")), "false")
        NxLibraryPickSettled(reg)
        NxCheck(r, kind + ": settled, the next launch reads", NxToStr(NxLaunchReadsLibrary(reg, kind, "tok")), "true")
        NxCheck(r, kind + ": settled is no longer owed", NxToStr(NxLibraryPickOwed(reg)), "false")
    end for
    reg = NxFakeRegistry()
    NxOweLibraryPick(reg)
    NxCheck(r, "no servers saved: no launch read, owed or not", NxToStr(NxLaunchReadsLibrary(reg, "jellyfin", "")), "false")
    reg = NxFakeRegistry()
    reg.Write("servers", "[{}]")
    NxCheck(r, "plex: no token, no launch read", NxToStr(NxLaunchReadsLibrary(reg, "plex", "")), "false")
    reg.Write("needsPick", "1")
    NxCheck(r, "plex: a server pick owed, no launch read", NxToStr(NxLaunchReadsLibrary(reg, "plex", "tok")), "false")
    NxCheck(r, "no registry: nothing owed, no launch read", NxToStr(NxLibraryPickOwed(invalid)) + " " + NxToStr(NxLaunchReadsLibrary(invalid, "emby", "")), "false false")
    ' A sign-in's reset of the library choices leaves the pick owed: the flag is
    ' written beside it, and the reset must not clear it.
    reg = NxFakeRegistry()
    NxOweLibraryPick(reg)
    NxResetLibraryChoices(reg, NxFakeRegistry())
    NxCheck(r, "the sign-in reset keeps the pick owed", NxToStr(NxLibraryPickOwed(reg)), "true")

    print "library section tests: "; r.pass; " passed, "; r.fail; " failed"
    return r.fail
end function

' A Jellyfin of two movie libraries of two films each, remembering what it was asked.
function NxMbSectionFetcher() as Object
    return {
        asked: [], auth: false,
        getJSON: function(path as String) as Dynamic
            if Instr(1, path, "/UserViews") > 0 then
                return { Items: [{ Name: "One", Id: "lib1", CollectionType: "movies" }, { Name: "Two", Id: "lib2", CollectionType: "movies" }] }
            end if
            at = Instr(1, path, "ParentId=")
            id = Mid(path, at + 9, 4)
            m.asked.Push(id)
            items = []
            for i = 0 to 1
                items.Push({ Id: id + "-" + i.ToStr(), Name: "Film " + id + i.ToStr(), Type: "Movie", RunTimeTicks: 54000000000#, ProductionYear: 2000, Genres: [], MediaSources: [] })
            end for
            return { Items: items, TotalRecordCount: 2, StartIndex: 0 }
        end function,
        getMany: function(paths as Object) as Object
            out = []
            for each p in paths
                out.Push(m.getJSON(p))
            end for
            return out
        end function
    }
end function
