' The viewer's collection switches, shared by the library load and Settings.
'
' Copyright (c) 2024 Chad Mueller / Muell Haus Inc. (Nostalgex), MIT License.
' Port copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Source: plex-tuner.html loadEnabledCollectionKeys and
' saveEnabledCollectionKeys (nostalgex_enabled_collections): one list of the
' switched-on collection ids, "<server>:<ratingKey>". Every collection starts
' off.

' The switched-on ids as a case-sensitive set. Nothing saved is none;
' ParseJson("") logs an error, so it is skipped.
function NxSavedCollectionKeys() as Object
    raw = NxRegSection("guide").Read("collectionsOn")
    parsed = invalid
    if raw <> "" then parsed = ParseJson(raw)
    return NxCollectionKeySet(parsed)
end function

function NxCollectionKeySet(list as Dynamic) as Object
    keys = {}
    keys.SetModeCaseSensitive()
    for each k in NxList(list)
        if NxIsString(k) then keys[k] = true
    end for
    return keys
end function

' Sorted, the form they're saved in.
function NxCollectionKeyList(keys as Object) as Object
    out = []
    for each k in keys
        out.Push(k)
    end for
    out.Sort()
    return out
end function

sub NxSaveCollectionKeys(keys as Object)
    reg = NxRegSection("guide")
    reg.Write("collectionsOn", FormatJson(NxCollectionKeyList(keys)))
    reg.Flush()
end sub
