' Runs source/util/LoadStall.brs, upstream's LibraryLoadStallDetector, and
' the stop it leads to: NxLoadStopped, NxServerWait and a Jellyfin scan that
' was told to stop waiting. Hand-written cases from the Swift's thresholds
' (Services/LibraryLoadStallWatch.swift). Returns the failure count.

function NxRunStallTests(fixturePath as String) as Integer
    r = { pass: 0, fail: 0 }

    w = NxStallStart("a", 0)
    NxCheck(r, "quiet 59.9 s", NxStallVerdict(w, "a", 59999), "progressing")
    NxCheck(r, "quiet 60 s", NxStallVerdict(w, "a", 60000), "slow")
    NxCheck(r, "quiet 209.9 s", NxStallVerdict(w, "a", 209999), "slow")
    NxCheck(r, "quiet 210 s", NxStallVerdict(w, "a", 210000), "stalled")
    w = NxStallStart("a", 0)
    NxCheck(r, "slow", NxStallVerdict(w, "a", 100000), "slow")
    NxCheck(r, "a change is progress", NxStallVerdict(w, "b", 150000), "progressing")
    NxCheck(r, "the clock restarts at the change", NxStallVerdict(w, "b", 209999), "progressing")
    NxCheck(r, "quiet 60 s after the change", NxStallVerdict(w, "b", 210000), "slow")
    NxCheck(r, "quiet 210 s after the change", NxStallVerdict(w, "b", 360000), "stalled")
    w = NxStallStart("a", 0)
    for t = 2000 to 600000 step 2000
        verdict = NxStallVerdict(w, "a" + t.ToStr(), t)
        if verdict <> "progressing" then exit for
    end for
    NxCheck(r, "slow but moving for 10 min", verdict, "progressing")

    ' Outside a scan nothing is stopped, and a wait is a plain Wait.
    m.nxLoadWatch = invalid
    NxCheck(r, "no scan, not stopped", NxLoadStopped().ToStr(), "false")
    m.nxLoadWatch = { stopWaiting: "", scanAnswers: 0 }
    NxCheck(r, "scan running", NxLoadStopped().ToStr(), "false")
    clock = CreateObject("roTimespan")
    msg = NxServerWait(600, CreateObject("roMessagePort"))
    NxCheck(r, "a quiet wait times out", NxToStr(msg = invalid), "true")
    NxCheck(r, "after its timeout", NxToStr(clock.TotalMilliseconds() >= 500), "true")
    m.nxLoadWatch.stopWaiting = "viewer"
    NxCheck(r, "stopped", NxLoadStopped().ToStr(), "true")
    clock.Mark()
    msg = NxServerWait(30000, CreateObject("roMessagePort"))
    NxCheck(r, "a stopped wait ends", NxToStr(msg = invalid), "true")
    NxCheck(r, "at once", NxToStr(clock.TotalMilliseconds() < 1000), "true")

    ' A Jellyfin scan stopped after its first library: that library's items,
    ' and no request after the stop.
    fx = ParseJson(ReadAsciiFile(fixturePath))
    if fx = invalid then
        print "FAIL cannot read "; fixturePath
        return r.fail + 1
    end if
    m.nxLoadWatch = invalid
    firstOnly = { userId: fx.userId, views: [fx.views[0]], items: fx.items, fail: fx.fail }
    want = NxMbScanServer(NxMbFixtureFetcher(firstOnly), "jellyfin", fx.userId, 0)
    m.nxLoadWatch = { stopWaiting: "", scanAnswers: 0 }
    f = NxStallFetcher(NxMbFixtureFetcher(fx), "ParentId=" + NxToStr(fx.views[0].Id))
    got = NxMbScanServer(f, "jellyfin", fx.userId, 0)
    NxCheck(r, "stopped scan returns items", NxToStr(got <> invalid), "true")
    if got <> invalid then NxCheck(r, "the first library's items", got.Count().ToStr(), want.Count().ToStr())
    NxCheck(r, "requests up to the stop", f.inner.requests.Count().ToStr(), "2")

    ' Stopped while reading shows: the batch in hand finishes, no more.
    m.nxLoadWatch = { stopWaiting: "", scanAnswers: 0 }
    f = NxStallFetcher(NxMbFixtureFetcher(fx), "IncludeItemTypes=Series")
    got = NxMbScanServer(f, "jellyfin", fx.userId, 0)
    m.nxLoadWatch = invalid
    firstTwo = { userId: fx.userId, views: [fx.views[0], fx.views[1]], items: fx.items, fail: fx.fail }
    want = NxMbScanServer(NxMbFixtureFetcher(firstTwo), "jellyfin", fx.userId, 0)
    NxCheck(r, "stopped in shows returns items", NxToStr(got <> invalid), "true")
    if got <> invalid then NxCheck(r, "the first two libraries' items", got.Count().ToStr(), want.Count().ToStr())
    for each p in f.inner.requests
        if Instr(1, p, "ParentId=v-mv") > 0 or Instr(1, p, "ParentId=v-home") > 0 then NxCheck(r, "no library after the stop", p, "")
    end for
    m.nxLoadWatch = invalid

    print "stall cases: "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' A fetcher that stops the scan (the global nxLoadWatch, as NxLoadStopped
' reads it) once it has answered a path containing `stopAt`.
function NxStallFetcher(inner as Object, stopAt as String) as Object
    return {
        inner: inner,
        stopAt: stopAt,
        auth: false,
        getJSON: function(path as String) as Dynamic
            answer = m.inner.getJSON(path)
            if Instr(1, path, m.stopAt) > 0 then GetGlobalAA().nxLoadWatch.stopWaiting = "viewer"
            return answer
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
