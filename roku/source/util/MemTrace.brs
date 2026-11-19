' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' The memory line of a load: the app's own limit, the scan's ceiling for it, and what the app held at
' each step of the last load (the scan, the collections, the channels, the schedule, the save), as a
' percent of its limit. Kept in the registry with the library's other records, so ABOUT can show it
' and a viewer whose app closes while loading can read the numbers out. A step that is noted again
' (a package change builds again) replaces its line.

function NxMemPercentSafe() as Integer
    pct = -1
    try
        pct = NxMemPercentNow()
    catch e
        pct = -1
    end try
    return pct
end function

sub NxMemTraceReset()
    GetGlobalAA().nxMemTrace = { limitKB: NxMemLimitKB(), ceiling: NxScanMemoryCeiling(), notes: [] }
end sub

' `phase` is the label shown ("SCAN"), `count` how many of `unit` the step holds ("TITLES").
sub NxMemTraceNote(phase as String, count as Integer, unit as String)
    g = GetGlobalAA()
    if g.nxMemTrace = invalid then NxMemTraceReset()
    NxMemTraceAdd(g.nxMemTrace, phase, count, unit, NxMemPercentSafe())
    NxMemTraceSave(NxPlexRegistry(), g.nxMemTrace)
end sub

sub NxMemTraceAdd(trace as Object, phase as String, count as Integer, unit as String, pct as Integer)
    note = { phase: phase, count: count, unit: unit, pct: pct }
    for i = 0 to trace.notes.Count() - 1
        if trace.notes[i].phase = phase then
            trace.notes[i] = note
            return
        end if
    end for
    trace.notes.Push(note)
end sub

sub NxMemTraceSave(reg as Dynamic, trace as Object)
    if reg = invalid then return
    reg.Write("memTrace", FormatJson(trace))
    reg.Flush()
end sub

function NxReadMemTrace(reg as Dynamic) as Dynamic
    if reg = invalid then return invalid
    raw = reg.Read("memTrace")
    if raw = "" then return invalid
    trace = ParseJson(raw)
    if type(trace) <> "roAssociativeArray" then return invalid
    if type(trace.notes) <> "roArray" then return invalid
    return trace
end function

' The lines ABOUT shows, upper case as the page is: the limit first, then each step in the order it ran.
function NxMemTraceLines(trace as Dynamic) as Object
    out = []
    if type(trace) <> "roAssociativeArray" then return out
    limit = NxNumberOr0(trace.limitKB)
    if limit > 0 then
        out.Push("APP LIMIT " + NxGroupedInt(limit) + " KB. THE SCAN STOPS AT " + NxToStr(NxNumberOr0(trace.ceiling)) + "% OF IT.")
    else
        out.Push("THIS TV DOES NOT REPORT ITS LIMIT. THE SCAN STOPS AT " + NxToStr(NxNumberOr0(trace.ceiling)) + "%.")
    end if
    if type(trace.notes) = "roArray" then
        for each n in trace.notes
            line = NxToStr(n.phase) + ": " + NxGroupedInt(NxNumberOr0(n.count)) + " " + NxToStr(n.unit)
            if NxNumberOr0(n.pct) >= 0 and n.pct <> invalid then line = line + ", MEMORY AT " + NxToStr(n.pct) + "%"
            out.Push(line)
        end for
    end if
    return out
end function
