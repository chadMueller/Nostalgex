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
    return { sample: sample, changedAt: nowMs, lookedAt: nowMs }
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

' A look this long after the last one (the watch looks every 2 s) means the
' app was paused, not the server quiet: the Roku stops the whole app while
' its screensaver runs, timers and requests too, and roTimespan keeps
' counting (43S45, Roku OS 16.0.4, 2026-11-04: 39 min paused, then the
' first look after waking read it as 210 s with no progress and stopped the
' scan). The loading screen holds the screensaver off (LoadingView.xml);
' this covers any other pause. Upstream's watch has no such check: it
' compares wall-clock Date()s (LibraryLoadStallWatch.swift).
function NxStallPauseGapMs() as Integer
    return 20000
end function

' Called on every look before NxStallVerdict: a gap of NxStallPauseGapMs or
' more since the last look isn't counted as quiet. Returns the gap skipped,
' 0 when there was none.
function NxStallSkipPause(watch as Object, nowMs as Integer) as Integer
    skipped = 0
    if watch.lookedAt <> invalid then
        gap = nowMs - watch.lookedAt
        if gap >= NxStallPauseGapMs() then
            watch.changedAt = watch.changedAt + gap
            skipped = gap
        end if
    end if
    watch.lookedAt = nowMs
    return skipped
end function
