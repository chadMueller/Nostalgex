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
    print "memory budget cases: "; r.pass; " passed, "; r.fail; " failed"
    return r.fail
end function
