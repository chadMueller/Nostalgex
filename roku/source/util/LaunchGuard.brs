' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Unfinished loads, as upstream's LaunchGuard (Services/LaunchGuard.swift):
' a registry marker is set when a load the viewer waits on starts, and cleared
' when the app lives to see it end. Still set at the next launch means the app
' closed inside a load, whether it crashed or was sent Home. After two in a row,
' MainScene asks first (LOADING DIDN'T FINISH: TRY AGAIN or START OVER) instead
' of starting the same load a third time.
'
' Each function takes the registry section, so the tests can hand it a stand-in.
' The section is NxLaunchGuardRegistry(): its own, so a sign-out's clearing of
' the plex section leaves it to NxLoadEnded.

function NxLaunchGuardRegistry() as Object
    return NxRegSection("launch")
end function

' Unfinished loads in a row before the app asks instead of loading.
function NxUnfinishedLoadLimit() as Integer
    return 2
end function

' Once per launch, before anything starts a load. Returns the count in a row.
function NxLoadRecordLaunch(reg as Object) as Integer
    if reg.Read("loadInFlight") = "" then return NxUnfinishedLoads(reg)
    reg.Delete("loadInFlight")
    count = NxUnfinishedLoads(reg) + 1
    reg.Write("unfinishedLoads", count.ToStr())
    reg.Flush()
    print "launch: the previous launch ended inside a library load ("; count; " in a row)"
    return count
end function

function NxUnfinishedLoads(reg as Object) as Integer
    n = Val(reg.Read("unfinishedLoads"))
    if n < 0 then return 0
    return Int(n)
end function

' Whether a load carries the marker: only one the viewer waits on. A refresh
' behind a guide already on screen does not, so a TV that closes the app while
' it refreshes never puts LOADING DIDN'T FINISH in front of a library that loads
' fine (upstream's tracksLoad).
function NxLoadTracked(guideShown as Boolean) as Boolean
    return not guideShown
end function

sub NxLoadStarted(reg as Object)
    reg.Write("loadInFlight", "1")
    reg.Flush()
end sub

' Any end the app lived to see: the guide up, an error, a sign-out. resetCount
' false only clears the marker, for a saved guide shown first, which proves
' nothing about whether the full load can finish.
sub NxLoadEnded(reg as Object, resetCount = true as Boolean)
    changed = false
    if reg.Read("loadInFlight") <> "" then
        reg.Delete("loadInFlight")
        changed = true
    end if
    if resetCount and reg.Read("unfinishedLoads") <> "" then
        reg.Delete("unfinishedLoads")
        changed = true
    end if
    if changed then reg.Flush()
end sub

function NxLoadShouldAsk(reg as Object) as Boolean
    return NxUnfinishedLoads(reg) >= NxUnfinishedLoadLimit()
end function

' TRY AGAIN: the next load gets the full allowance again.
sub NxLoadResetUnfinished(reg as Object)
    if reg.Read("unfinishedLoads") = "" then return
    reg.Delete("unfinishedLoads")
    reg.Flush()
end sub
