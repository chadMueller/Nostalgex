' Library load stall watch, ported from Nostalgex's Apple TV app.
'
' Copyright (c) 2024 Chad Mueller / Muell Haus Inc. (Nostalgex), MIT License.
' Port copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Source: Services/LibraryLoadStallWatch.swift, LibraryLoadStallDetector.
' Only a load with no forward progress counts, never a slow one: any change
' in the sample is progress. The sample is the scan's progress fields plus
' its count of server answers (components/MainScene.brs), where upstream's
' is its phase, section and item counters and detail line.

' Quiet this long and the loading screen says so, with STOP WAITING.
function NxStallWarnAfterMs() as Integer
    return 60000
end function

' Quiet this long and the scan is abandoned. Upstream puts it above one
' request's whole retry ladder; here that is three tries at a 30 s timeout.
function NxStallStopAfterMs() as Integer
    return 210000
end function

' A watch starting from `sample` at nowMs.
function NxStallStart(sample as String, nowMs as Integer) as Object
    return { sample: sample, changedAt: nowMs }
end function

' "progressing", "slow" (tell the viewer) or "stalled" (abandon the scan).
function NxStallVerdict(watch as Object, sample as String, nowMs as Integer) as String
    if sample <> watch.sample then
        watch.sample = sample
        watch.changedAt = nowMs
        return "progressing"
    end if
    idle = nowMs - watch.changedAt
    if idle >= NxStallStopAfterMs() then return "stalled"
    if idle >= NxStallWarnAfterMs() then return "slow"
    return "progressing"
end function
