' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' The loading pattern (source/guide/LoadState.brs): the guide area's block while the
' library loads or the guide is changing, the progress line, the header's
' UPDATING LIBRARY and GUIDE READY lines. Returns the failure count.

function NxRunLoadStateTests() as Integer
    r = { pass: 0, fail: 0 }
    NxCheck(r, "title: a server switch", NxLoadTitle("changing"), "CHANNEL GUIDE IS CHANGING")
    NxCheck(r, "title: a first load or a rescan", NxLoadTitle("load"), "LOADING YOUR LIBRARY")
    NxCheck(r, "title: a failure", NxLoadTitle("error"), "COULD NOT READ YOUR LIBRARY")
    NxCheck(r, "progress: a count", NxLoadProgressLine(4210), "READ 4,210 TITLES")
    NxCheck(r, "progress: one title", NxLoadProgressLine(1), "READ 1 TITLE")
    NxCheck(r, "progress: nothing read yet says nothing", NxLoadProgressLine(0), "")
    NxCheck(r, "library: how far through, when the server gave a total", NxLoadLibraryLine("Movies", 40, 40), "MOVIES: 40 OF 40")
    NxCheck(r, "library: grouped", NxLoadLibraryLine("Movies", 3000, 12000), "MOVIES: 3,000 OF 12,000")
    NxCheck(r, "library: no total, the name alone", NxLoadLibraryLine("Movies", -1, 0), "MOVIES")
    NxCheck(r, "library: a total below the count is not shown", NxLoadLibraryLine("Movies", 50, 40), "MOVIES")
    NxCheck(r, "library: a server's name first", NxLoadLibraryLine("Stand-in B · Shows", 5, 400), "STAND-IN B · SHOWS: 5 OF 400")
    NxCheck(r, "note: the Settings notice", NxLoadNote(), "SETTINGS OPENS WHEN IT FINISHES")
    NxCheck(r, "header: updating with a count", NxUpdatingLine(4210), "UPDATING LIBRARY: 4,210 TITLES READ")
    NxCheck(r, "header: updating before a count", NxUpdatingLine(0), "UPDATING LIBRARY")
    NxCheck(r, "header: ready", NxReadyLine(11813), "GUIDE READY: 11,813 TITLES")
    NxCheck(r, "header: ready for one", NxReadyLine(1), "GUIDE READY: 1 TITLE")
    NxCheck(r, "header: ready shows for 4 s", NxToStr(NxReadyShowSec()), "4")
    ' Which state shows: (changing, error, seeded, busy, rows)
    NxCheck(r, "kind: nothing loading", NxLoadKind(false, false, false, false, 20), "")
    NxCheck(r, "kind: a rebuild behind rows shows no block", NxLoadKind(false, false, false, true, 20), "")
    NxCheck(r, "kind: a load with no rows", NxLoadKind(false, false, false, true, 0), "load")
    NxCheck(r, "kind: the seed's lone channel while it loads", NxLoadKind(false, false, true, true, 1), "load")
    NxCheck(r, "kind: a switch clears the rows", NxLoadKind(true, false, false, true, 0), "changing")
    NxCheck(r, "kind: a failure wins", NxLoadKind(true, true, false, false, 0), "error")
    NxCheck(r, "kind: busy ended with the seed still up shows nothing", NxLoadKind(false, false, true, false, 1), "")
    ' The header: ready for its seconds, updating behind rows, else nothing.
    NxCheck(r, "note: ready while its seconds last", NxHeaderNote("", false, 20, 0, 11813, 1004, 1000), "GUIDE READY: 11,813 TITLES")
    NxCheck(r, "note: ready is over", NxHeaderNote("", false, 20, 0, 11813, 1000, 1000), "")
    NxCheck(r, "note: updating behind rows", NxHeaderNote("", true, 20, 4210, 0, 0, 1000), "UPDATING LIBRARY: 4,210 TITLES READ")
    NxCheck(r, "note: no updating line while the block shows", NxHeaderNote("load", true, 0, 4210, 0, 0, 1000), "")
    NxCheck(r, "note: ready with no titles says nothing", NxHeaderNote("", false, 20, 0, 0, 1004, 1000), "")
    NxCheck(r, "error: the retry sentence is left off", NxLoadErrorText("Can't reach plex.tv. Check the TV's internet connection. Press OK to try again."), "Can't reach plex.tv. Check the TV's internet connection.")
    NxCheck(r, "error: no retry sentence kept as is", NxLoadErrorText("Something failed."), "Something failed.")
    ' A load ended by sign-out, a switch or a newer load keeps nothing (LoadEpoch).
    reg = NxFakeRegistry()
    began = NxLoadEpoch(reg)
    NxCheck(r, "epoch: a running load is current", NxToStr(NxLoadStale(began, reg)), "false")
    NxLoadEpochBump(reg)
    NxCheck(r, "epoch: a load ended by sign-out or a switch is stale", NxToStr(NxLoadStale(began, reg)), "true")
    NxCheck(r, "epoch: it stays stale", NxToStr(NxLoadStale(began, reg)), "true")
    began2 = NxLoadEpoch(reg)
    NxCheck(r, "epoch: the next load begun after it is current", NxToStr(NxLoadStale(began2, reg)), "false")
    NxLoadEpochBump(reg)
    NxLoadEpochBump(reg)
    NxCheck(r, "epoch: two ends in a row", NxToStr(NxLoadStale(began2, reg)), "true")
    NxCheck(r, "step: collections", NxLoadStepName("collections"), "collections")
    NxCheck(r, "step: channels", NxLoadStepName("channels"), "building channels")
    NxCheck(r, "step: the read itself has none", NxLoadStepName("library"), "")
    print "load state tests: "; r.pass; " passed, "; r.fail; " failed"
    return r.fail
end function
