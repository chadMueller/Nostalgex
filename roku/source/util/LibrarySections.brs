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
' N-016 option A (scripts/library-picker-golden.json, tests/LibraryPickerGoldenTests.brs):
' a library is on or off by two saved lists, the Apple TV's two sets.
'   "deselectedSections"       ids switched OFF; every library but a hidden one reads it.
'   "includedHiddenSections"   ids of hidden Jellyfin libraries switched ON; a hidden library reads only this.
' Everything starts on except a hidden Jellyfin library, one row each. The old
' single switch (INCLUDE LIBRARIES HIDDEN ON JELLYFIN) is carried over once
' (NxCarryOverHiddenSwitch) and every sign-in starts again (NxResetLibraryChoices).
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
    ' An empty read isn't handed to ParseJson, which logs an error for it.
    raw = reg.Read("deselectedSections")
    if raw = "" then return out
    list = ParseJson(raw)
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

' Whether a section is read: not in the set of those switched off. `set` may be
' invalid (nothing is off).
function NxSectionKept(set as Dynamic, serverId as Dynamic, sectionKey as Dynamic) as Boolean
    if type(set) <> "roAssociativeArray" then return true
    return NxSectionIsOn(set, serverId, sectionKey)
end function

' The sections the last scan or the picker saw: [{ serverId, serverName, key,
' title, type, hidden }].
function NxSavedSections(reg as Dynamic) as Object
    if reg = invalid then return []
    ' An empty read isn't handed to ParseJson, which logs an error for it.
    raw = reg.Read("librarySections")
    if raw = "" then return []
    list = ParseJson(raw)
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

' The hidden Jellyfin libraries the viewer switched on, as a set (the Apple
' TV's nostalgex_included_hidden_library_sections).
function NxIncludedHiddenSections(reg as Dynamic) as Object
    out = {}
    if reg = invalid then return out
    raw = reg.Read("includedHiddenSections")
    if raw = "" then return out
    list = ParseJson(raw)
    if type(list) <> "roArray" then return out
    for each k in list
        if NxIsString(k) and k <> "" then out[k] = true
    end for
    return out
end function

sub NxSaveIncludedHiddenSections(reg as Dynamic, set as Object)
    if reg = invalid then return
    keys = []
    for each k in set
        if set[k] = true then keys.Push(k)
    end for
    keys.Sort()
    reg.Write("includedHiddenSections", FormatJson(keys))
    reg.Flush()
end sub

' Whether a library is on under the two lists: a hidden one follows `included`
' only, every other follows `off`. A section is { serverId, key, hidden }.
function NxSectionRowOn(section as Object, off as Object, included as Object) as Boolean
    id = NxSectionKey(section.serverId, section.key)
    if section.hidden = true then return included[id] = true
    return off[id] <> true
end function

' The two lists after the viewer switches one library, changed in place: only
' its own id moves, every other saved id stays.
sub NxSectionRowToggle(section as Object, off as Object, included as Object)
    id = NxSectionKey(section.serverId, section.key)
    if NxSectionRowOn(section, off, included) then
        if section.hidden = true then included.Delete(id) else off[id] = true
    else
        if section.hidden = true then included[id] = true else off.Delete(id)
    end if
end sub

' The ids a scan reads, in listed order.
function NxSectionsRead(sections as Object, off as Object, included as Object) as Object
    out = []
    for each s in sections
        if NxSectionRowOn(s, off, included) then out.Push(NxSectionKey(s.serverId, s.key))
    end for
    return out
end function

' Whether any hidden Jellyfin library is switched on, so a scan has to ask for
' the hidden ones.
function NxAnyHiddenOn(sections as Object, included as Object) as Boolean
    for each s in sections
        if s.hidden = true and included[NxSectionKey(s.serverId, s.key)] = true then return true
    end for
    return false
end function

' How many of `sections` are on.
function NxSectionsOnCount(sections as Object, off as Object, included as Object) as Integer
    return NxSectionsRead(sections, off, included).Count()
end function

' What a scan leaves alone: the libraries switched off, and every saved hidden
' library not switched on (a scan asks once and cannot tell which are hidden,
' so it goes by the saved list). A set for NxSectionsKept.
function NxScanOffSet(reg as Dynamic) as Object
    out = NxDeselectedSections(reg)
    included = NxIncludedHiddenSections(reg)
    for each s in NxSavedSections(reg)
        if s.hidden = true and included[NxSectionKey(s.serverId, s.key)] <> true then out[NxSectionKey(s.serverId, s.key)] = true
    end for
    return out
end function

' UPGRADE from the one switch (INCLUDE LIBRARIES HIDDEN ON JELLYFIN, stored "1"
' or "0" under includeHiddenLibraries in `switchReg`). On, with the hidden
' libraries known (the saved list is there), each hidden library not switched
' off goes into the included list once and the switch is cleared. With them not
' known yet nothing changes and the switch stays (returns false). Off or never
' set: nothing to carry. Returns whether the switch is settled.
function NxCarryOverHiddenSwitch(reg as Dynamic, switchReg as Dynamic) as Boolean
    if reg = invalid or switchReg = invalid then return true
    stored = switchReg.Read("includeHiddenLibraries")
    if stored = "" then return true
    if stored = "1" then
        saved = NxSavedSections(reg)
        if saved.Count() = 0 then return false
        off = NxDeselectedSections(reg)
        included = NxIncludedHiddenSections(reg)
        for each s in saved
            if s.hidden = true and off[NxSectionKey(s.serverId, s.key)] <> true then included[NxSectionKey(s.serverId, s.key)] = true
        end for
        NxSaveIncludedHiddenSections(reg, included)
    end if
    switchReg.Delete("includeHiddenLibraries")
    switchReg.Flush()
    return true
end function

' Every sign-in starts again: both lists are emptied, the sections the last
' scan saw are forgotten and the old single switch is cleared.
sub NxResetLibraryChoices(reg as Dynamic, switchReg as Dynamic)
    if reg <> invalid then
        reg.Delete("deselectedSections")
        reg.Delete("includedHiddenSections")
        reg.Delete("librarySections")
        reg.Flush()
    end if
    if switchReg <> invalid then
        switchReg.Delete("includeHiddenLibraries")
        switchReg.Flush()
    end if
end sub

' A Plex library whose name says it holds music videos (HIGH ROTATION's name rule).
function NxIsMusicVideoName(title as Dynamic) as Boolean
    return CreateObject("roRegex", "music.?video|^music$|^mv[s]?$", "i").IsMatch(NxToStr(title).Trim())
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
        if NxIsMusicVideoName(title) then return "Music Videos"
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
' more than one library, or a hidden one (it starts off, so without the screen
' nothing would offer it).
function NxPickerWanted(sections as Object) as Boolean
    if sections.Count() > 1 then return true
    for each s in sections
        if s.hidden = true then return true
    end for
    return false
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
