' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Which library load is still the app's. Settings stays reachable while a load
' runs behind the guide, so SIGN OUT or a server switch can come in the middle
' of one. Every end of a load (releaseLibrary in MainScene: sign-out, a switch,
' a new load) bumps this count, and a load compares it with the one it began
' under before it saves a library, hands over a guide or says it is done. A
' load that was ended keeps nothing and shows nothing: it never saves the old
' server's library again after sign-out, nor tunes the viewer back to it.
'
' Stored in the registry because the load runs on a task thread of its own.

function NxLoadEpochRegistry() as Object
    return NxRegSection("loadepoch")
end function

' `reg` is the registry section, given by the tests (NxFakeRegistry).
function NxLoadEpoch(reg = invalid as Dynamic) as Integer
    if reg = invalid then reg = NxLoadEpochRegistry()
    raw = reg.Read("n")
    if raw = "" then return 0
    return raw.ToInt()
end function

' Called each time a load is ended or another begins.
sub NxLoadEpochBump(reg = invalid as Dynamic)
    if reg = invalid then reg = NxLoadEpochRegistry()
    reg.Write("n", (NxLoadEpoch(reg) + 1).ToStr())
    reg.Flush()
end sub

' True when a load that began under `began` has been ended since.
function NxLoadStale(began as Integer, reg = invalid as Dynamic) as Boolean
    return NxLoadEpoch(reg) <> began
end function
