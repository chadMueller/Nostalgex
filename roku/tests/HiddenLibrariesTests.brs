' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' INCLUDE LIBRARIES HIDDEN ON JELLYFIN (#231): the old single switch
' (source/mediabrowser/HiddenLibraries.brs, kept to carry its value over to the
' per-library rows, N-016) on a stand-in registry, and a scan
' against a stub that lists a hidden library only when asked with
' includeHidden=true, as Jellyfin's /UserViews does and as the web tuner's
' nostalgex-jellyfin-library-smoke.mjs stubs it. The request paths themselves
' are the golden file's `views`, read in NxRunPlaylistLeakTests.
' Returns the failure count.

function NxRunHiddenLibrariesTests(fixturePath as String) as Integer
    r = { pass: 0, fail: 0 }
    fx = ParseJson(ReadAsciiFile(fixturePath))
    if fx = invalid then
        print "FAIL cannot read "; fixturePath
        return 1
    end if

    ' The switch: off unless the viewer turns it on.
    reg = NxFakeRegistry()
    NxCheck(r, "the default is off", NxIncludeHiddenDefault().ToStr(), "false")
    NxCheck(r, "never chosen is off", NxIncludeHidden(reg).ToStr(), "false")
    NxCheck(r, "no registry is off", NxIncludeHidden(invalid).ToStr(), "false")
    NxSaveIncludeHidden(reg, true)
    NxCheck(r, "switched on is on", NxIncludeHidden(reg).ToStr(), "true")
    NxSaveIncludeHidden(reg, false)
    NxCheck(r, "switched off is off", NxIncludeHidden(reg).ToStr(), "false")
    reg.Write("includeHiddenLibraries", "yes")
    NxCheck(r, "anything else stored is the default", NxIncludeHidden(reg).ToStr(), "false")
    NxCheck(r, "the single switch has no row any more, each hidden library has its own", NxSettingsTabOf("includeHidden"), "")

    ' The shared fixture's libraries, plus two the user hides from the home
    ' screen (films, and a show with its episodes) and one the user has no
    ' access to, which the server lists in neither position.
    fx.views.Push({ Id: "v-hidden-films", Name: "Hidden Films", CollectionType: "movies" })
    fx.views.Push({ Id: "v-hidden-tv", Name: "Hidden TV", CollectionType: "tvshows" })
    fx.hidden = ["v-hidden-films", "v-hidden-tv"]
    ticks& = 90& * 60& * 10000000&
    fx.items["v-hidden-films"] = [
        { Id: "hf-1", Name: "Hidden Film One", Type: "Movie", RunTimeTicks: ticks&, ProductionYear: 1994, MediaSources: [{ Id: "hf-1", Container: "mkv" }] },
        { Id: "hf-2", Name: "Hidden Film Two", Type: "Movie", RunTimeTicks: ticks&, ProductionYear: 1996, MediaSources: [{ Id: "hf-2", Container: "mkv" }] }
    ]
    fx.items["v-hidden-tv"] = [{ Id: "hs-1", Name: "Hidden Show", Type: "Series", ProductionYear: 1991 }]
    ep& = 22& * 60& * 10000000&
    fx.items["hs-1"] = [
        { Id: "he-1", Name: "Pilot", Type: "Episode", SeriesName: "Hidden Show", SeriesId: "hs-1", ParentIndexNumber: 1, IndexNumber: 1, RunTimeTicks: ep&, MediaSources: [{ Id: "he-1", Container: "mkv" }] },
        { Id: "he-2", Name: "Second", Type: "Episode", SeriesName: "Hidden Show", SeriesId: "hs-1", ParentIndexNumber: 1, IndexNumber: 2, RunTimeTicks: ep&, MediaSources: [{ Id: "he-2", Container: "mkv" }] }
    ]
    fx.items["v-no-access"] = [{ Id: "na-1", Name: "No Access Film", Type: "Movie", RunTimeTicks: ticks&, ProductionYear: 1990, MediaSources: [{ Id: "na-1", Container: "mkv" }] }]

    ' Switch off: the request is the one the Roku always sent, and nothing
    ' of a hidden library is asked for or scanned.
    off = NxMbFixtureFetcher(fx)
    gotOff = NxMbScanServer(off, "jellyfin", fx.userId, 0)
    NxCheck(r, "off: the libraries are asked for as before", off.requests[0], "/UserViews?userId=" + NxUrlEncode(fx.userId))
    NxCheck(r, "every Jellyfin scan also asks for the hidden list, as the web tuner and Android do", off.requests[1], "/UserViews?userId=" + NxUrlEncode(fx.userId) + "&includeHidden=true")
    NxCheck(r, "off: no hidden library is asked for items", NxHiddenAsked(off.requests, "v-hidden").ToStr(), "0")
    NxCheck(r, "off: no hidden title is scanned", NxHiddenTitles(gotOff), "")

    ' Switched on (each hidden library has its own row now): the hidden libraries'
    ' films and episodes are scanned too, and everything the scan read with them
    ' off is still there.
    on = NxMbFixtureFetcher(fx)
    gotOn = NxMbScanServer(on, "jellyfin", fx.userId, 0, invalid, false, invalid, "srv", { "srv::v-hidden-films": true, "srv::v-hidden-tv": true })
    NxCheck(r, "on: the libraries are asked for both ways", on.requests[0] + " " + on.requests[1], "/UserViews?userId=" + NxUrlEncode(fx.userId) + " /UserViews?userId=" + NxUrlEncode(fx.userId) + "&includeHidden=true")
    ' The old single switch, not yet carried over, reads them too, unless one is off.
    legacy = NxMbScanServer(NxMbFixtureFetcher(fx), "jellyfin", fx.userId, 0, invalid, true, invalid, "srv")
    NxCheck(r, "the old switch on: the hidden libraries are read", (legacy.Count() - gotOff.Count()).ToStr(), "4")
    legacyOff = NxMbScanServer(NxMbFixtureFetcher(fx), "jellyfin", fx.userId, 0, invalid, true, { "srv::v-hidden-tv": true }, "srv")
    NxCheck(r, "the old switch on, one hidden library off: it stays off", (legacyOff.Count() - gotOff.Count()).ToStr(), "2")
    ' A second ask that fails leaves the plain list: nothing hidden, nothing extra.
    NxCheck(r, "hidden libraries not switched on are never read", (NxMbScanServer(NxMbFixtureFetcher(fx), "jellyfin", fx.userId, 0, invalid, false, invalid, "srv", {}).Count() - gotOff.Count()).ToStr(), "0")
    ' An episode's title is its show's name, as the scan has always kept it.
    NxCheck(r, "on: the hidden films and both episodes are scanned", NxHiddenTitles(gotOn), "Hidden Film One|Hidden Film Two|Hidden Show|Hidden Show")
    NxCheck(r, "on: the rest of the library is as it was", (gotOn.Count() - gotOff.Count()).ToStr(), "4")

    ' A library the server never lists is never asked for items, on or off.
    NxCheck(r, "off: the library with no access is never asked", NxHiddenAsked(off.requests, "v-no-access").ToStr(), "0")
    NxCheck(r, "on: the library with no access is never asked", NxHiddenAsked(on.requests, "v-no-access").ToStr(), "0")
    NxCheck(r, "on: its film is not scanned", NxToStr(Instr(1, NxHiddenTitles(gotOn, "No Access"), "No Access") > 0), "false")

    ' Emby's list has a hidden library either way, and its request never changes.
    embyOff = NxMbFixtureFetcher(fx)
    gotEmbyOff = NxMbScanServer(embyOff, "emby", fx.userId, 0)
    embyOn = NxMbFixtureFetcher(fx)
    gotEmbyOn = NxMbScanServer(embyOn, "emby", fx.userId, 0, invalid, true)
    NxCheck(r, "emby: one ask for the libraries, no hidden list", NxToStr(embyOff.requests.Count() < 2 or Instr(1, embyOff.requests[1], "includeHidden") = 0), "true")
    NxCheck(r, "emby: the same request with the switch on", embyOn.requests[0], embyOff.requests[0])
    NxCheck(r, "emby: the same request as always", embyOff.requests[0], "/Users/" + NxUrlEncode(fx.userId) + "/Views")
    NxCheck(r, "emby: the same scan either way", gotEmbyOn.Count().ToStr(), gotEmbyOff.Count().ToStr())

    print "hidden library cases (#231):"; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' How many of the requests name a parent whose id starts with `prefix`.
function NxHiddenAsked(requests as Object, prefix as String) as Integer
    n = 0
    for each p in requests
        if Instr(1, p, "ParentId=" + prefix) > 0 then n = n + 1
    end for
    return n
end function

' The scanned titles that start with "Hidden" (or that hold `also`), in scan
' order, joined with "|".
function NxHiddenTitles(items as Dynamic, also = "" as String) as String
    out = []
    for each it in NxList(items)
        title = NxToStr(it.title)
        if Left(title, 6) = "Hidden" then out.Push(title)
        if also <> "" and Instr(1, title, also) > 0 then out.Push(title)
    end for
    return out.Join("|")
end function
