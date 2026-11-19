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
    print "memory budget cases: "; r.pass; " passed, "; r.fail; " failed"
    return r.fail
end function
