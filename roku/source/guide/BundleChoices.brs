' The packages the viewer has switched on, shared by the library load,
' Settings and the guide.
'
' Port copyright (c) 2026 nostalgex-roku contributors, MIT License.

' Switched-on bundles: saved on the TV, upstream's default until changed.
function NxEnabledBundles() as Object
    raw = NxRegSection("guide").Read("bundles")
    if raw <> "" then
        saved = ParseJson(raw)
        if type(saved) = "roArray" then return saved
    end if
    return ["nostalgex"]
end function
