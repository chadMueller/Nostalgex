' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' INCLUDE LIBRARIES HIDDEN ON JELLYFIN (#231), as the web tuner's
' includeHiddenLibraries and INCLUDE_HIDDEN_DEFAULT
' (scripts/nostalgex-jellyfin-urls.js, point 13). A Jellyfin user can hide a
' library from the home screen (My Media), and /UserViews leaves it out
' unless asked with includeHidden=true, so its titles never reached a
' channel. Hiding can be on purpose and the Roku has no library picker, so
' asking is a switch, off unless the viewer turns it on. Jellyfin only: Emby
' lists a hidden library either way. Per TV, in the registry, sent nowhere
' but the viewer's own server.
'
' The functions take the registry section, so the tests run on a stand-in.

function NxHiddenLibrariesRegistry() as Object
    return NxRegSection("player")
end function

' The one line the default lives on.
function NxIncludeHiddenDefault() as Boolean
    return false
end function

' A stored "1" is on and a stored "0" is off; anything else, or no registry,
' is the default.
function NxIncludeHidden(reg as Dynamic) as Boolean
    if reg = invalid then return NxIncludeHiddenDefault()
    stored = reg.Read("includeHiddenLibraries")
    if stored = "1" then return true
    if stored = "0" then return false
    return NxIncludeHiddenDefault()
end function

sub NxSaveIncludeHidden(reg as Dynamic, on as Boolean)
    if reg = invalid then return
    if on then reg.Write("includeHiddenLibraries", "1") else reg.Write("includeHiddenLibraries", "0")
    reg.Flush()
end sub
