' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Library selection (I-054 on the Apple TV, I-092 here; docs/LIBRARY-SELECTION.md
' in nostalgex-internal): the viewer turns off the library sections a scan
' should leave alone. A very large library left off is never read at all, not
' read and then dropped, which is the answer to a stick running out of memory
' (I-091). The Apple TV's LibrarySectionRef and LibrarySectionSelectionStore.
'
' Opting out, not in: a section never seen before is ON, so nobody lands on an
' empty guide by not noticing the screen or by a new library appearing later.
' The saved choice is the set of sections turned off, by "serverID::sectionKey"
' (a section key is only unique per server), in the plex registry section as
' "deselectedSections" (a JSON array), and the sections the last scan or the
' picker saw as "librarySections" (a JSON array), so Settings can list them
' without asking the server.
'
' The functions take the registry section, so the tests run on a stand-in.

' "serverID::sectionKey", as the Apple TV's LibrarySectionRef.storageKey.
function NxSectionKey(serverId as Dynamic, sectionKey as Dynamic) as String
    return NxToStr(serverId) + "::" + NxToStr(sectionKey)
end function

' The sections turned off, as a set: { "serverID::sectionKey": true }.
function NxDeselectedSections(reg as Dynamic) as Object
    out = {}
    if reg = invalid then return out
    list = ParseJson(reg.Read("deselectedSections"))
    if type(list) <> "roArray" then return out
    for each k in list
        if NxIsString(k) and k <> "" then out[k] = true
    end for
    return out
end function

sub NxSaveDeselectedSections(reg as Dynamic, set as Object)
    if reg = invalid then return
    keys = []
    for each k in set
        if set[k] = true then keys.Push(k)
    end for
    keys.Sort()
    reg.Write("deselectedSections", FormatJson(keys))
    reg.Flush()
end sub

function NxSectionIsOn(set as Object, serverId as Dynamic, sectionKey as Dynamic) as Boolean
    return set[NxSectionKey(serverId, sectionKey)] <> true
end function

' The sections the last scan or the picker saw: [{ serverId, serverName, key,
' title, type, hidden }].
function NxSavedSections(reg as Dynamic) as Object
    if reg = invalid then return []
    list = ParseJson(reg.Read("librarySections"))
    if type(list) <> "roArray" then return []
    return list
end function

sub NxSaveSections(reg as Dynamic, sections as Object)
    if reg = invalid then return
    reg.Write("librarySections", FormatJson(sections))
    reg.Flush()
end sub

' A new sign-in or a sign-out starts with every section on.
sub NxForgetSections(reg as Dynamic)
    if reg = invalid then return
    reg.Delete("deselectedSections")
    reg.Delete("librarySections")
    reg.Flush()
end sub

' A server's own list of libraries (Plex's Directory entries, keyed "key", or
' Jellyfin's views, keyed "Id") without the ones turned off. `deselected` may
' be invalid: nothing is off.
function NxSectionsKept(list as Object, deselected as Dynamic, serverId as Dynamic, keyField as String) as Object
    if type(deselected) <> "roAssociativeArray" then return list
    out = []
    for each s in list
        if type(s) = "roAssociativeArray" then
            if NxSectionIsOn(deselected, serverId, s[keyField]) then out.Push(s)
        else
            out.Push(s)
        end if
    end for
    return out
end function

' Whether any library the viewer hides on Jellyfin is turned on, so a scan has
' to ask for the hidden ones (the picker lists them off to start with; turning
' one on is the choice to read it, as INCLUDE LIBRARIES HIDDEN ON JELLYFIN is
' for all of them).
function NxAnyHiddenOn(sections as Object, set as Object) as Boolean
    for each s in sections
        if s.hidden = true and NxSectionIsOn(set, s.serverId, s.key) then return true
    end for
    return false
end function

' How many of `sections` are on.
function NxSectionsOnCount(sections as Object, set as Object) as Integer
    n = 0
    for each s in sections
        if NxSectionIsOn(set, s.serverId, s.key) then n = n + 1
    end for
    return n
end function

' Short label for a section's content type, as the Apple TV's typeLabel:
' "Library" for anything not recognized. A film library named like a music
' video library reads as one.
function NxSectionTypeLabel(kind as Dynamic, title as Dynamic) as String
    k = NxToStr(kind)
    if k = "show" then return "TV Shows"
    if k = "musicvideo" then return "Music Videos"
    if k = "artist" then return "Music"
    if k = "photo" then return "Photos"
    if k = "movie" then
        if CreateObject("roRegex", "music.?video|^music$|^mv[s]?$", "i").IsMatch(NxToStr(title).Trim()) then return "Music Videos"
        return "Movies"
    end if
    return "Library"
end function

' The line under a section's name: its kind, the server when more than one is
' in play, and HIDDEN ON JELLYFIN for a library the viewer hides from the
' Jellyfin home screen.
function NxSectionSubtitle(section as Object, multiServer as Boolean) as String
    base = NxSectionTypeLabel(section.type, section.title)
    if multiServer then base = NxToStr(section.serverName) + " · " + base
    if section.hidden = true then base = base + " · HIDDEN ON JELLYFIN"
    return base
end function

' Whether the picker is worth showing: only when there is something to choose,
' as the Apple TV skips it for a backend with exactly one section.
function NxPickerWanted(sections as Object) as Boolean
    return sections.Count() > 1
end function

' ── The sections a scan saw ────────────────────────────────────────────────
' Each scan adds the sections its server listed (before the ones turned off
' are left out), the library task saves them with the library, and Settings
' lists them. Held in the thread's global AA, as the scan's skipped count is.

sub NxScanSectionsReset()
    GetGlobalAA().nxScanSections = []
end sub

sub NxScanSectionsAdd(list as Object)
    g = GetGlobalAA()
    if g.nxScanSections = invalid then g.nxScanSections = []
    g.nxScanSections.Append(list)
end sub

function NxScanSections() as Object
    g = GetGlobalAA()
    if g.nxScanSections = invalid then return []
    return g.nxScanSections
end function

' What a load saves: the sections it saw, with each one's HIDDEN mark from the
' saved list (a scan asks once and cannot tell), and the saved sections of any
' server it did not scan this time.
function NxMergeSections(fresh as Object, old as Object) as Object
    out = []
    scanned = {}
    for each s in fresh
        scanned[NxToStr(s.serverId)] = true
        entry = {}
        entry.Append(s)
        for each o in old
            if o.serverId = s.serverId and o.key = s.key and o.hidden = true then entry.hidden = true
        end for
        out.Push(entry)
    end for
    for each o in old
        if scanned[NxToStr(o.serverId)] <> true then out.Push(o)
    end for
    return out
end function

' Each section's server name from the saved server list (a Jellyfin or Emby scan
' knows only the server's id).
function NxNameSections(sections as Object, servers as Dynamic) as Object
    names = {}
    for each s in NxList(servers)
        if type(s) = "roAssociativeArray" then names[NxToStr(s.machineIdentifier)] = NxToStr(s.name)
    end for
    for each sec in sections
        if names[NxToStr(sec.serverId)] <> invalid then sec.serverName = names[NxToStr(sec.serverId)]
    end for
    return sections
end function
