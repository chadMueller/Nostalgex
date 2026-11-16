' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Holds the Roku to scripts/library-picker-golden.json (N-016 option A), copied
' unchanged to tests/vectors/: one rule set for which servers and libraries are
' listed, start on and are read, written from the web tuner's
' scripts/nostalgex-library-picker.js (the Apple TV and Android hold to it too).
'
'   plexListing          NxPlexSectionRefs, NxSectionTypeLabel, NxIsMusicVideoName, NxSectionSubtitle
'   mediaBrowserListing  NxMbListSections (the plain list, the includeHidden list, the union)
'   serverDefaults       NxServersOn with nothing chosen
'   reads                NxSectionsRead under the two saved lists
'   choices              NxSectionRowToggle, library by library
'   hiddenSwitchUpgrade  NxCarryOverHiddenSwitch on stand-in registries
'   pickerOffered        NxPickerWanted
'   signInReset          NxResetLibraryChoices
'
' The collections sweep leaving a library that is off alone is checked after them
' (the golden has no vector for it). Returns the failure count.

function NxRunLibraryPickerGoldenTests(goldenPath as String) as Integer
    r = { pass: 0, fail: 0 }
    g = ParseJson(ReadAsciiFile(goldenPath))
    if g = invalid then
        print "FAIL cannot read "; goldenPath
        return 1
    end if

    for each c in g.plexListing
        refs = []
        for each srv in c.servers
            if srv.sections <> invalid then refs.Append(NxPlexSectionRefs({ machineIdentifier: srv.id, name: srv.name }, srv.sections))
        end for
        NxLpCheckListed(r, "plex: " + c.name, refs, c.listed, "")
    end for

    for each c in g.mediaBrowserListing
        server = { machineIdentifier: c.serverId, name: c.serverName }
        refs = NxMbListSections(server, c.shown, c.all)
        NxLpCheckListed(r, "mediabrowser: " + c.name, refs, c.listed, c.backend)
    end for

    for each c in g.serverDefaults
        servers = []
        for each s in c.servers
            servers.Push({ machineIdentifier: s.id, owned: s.owned })
        end for
        on = NxServersOn(servers, invalid)
        got = []
        for i = 0 to servers.Count() - 1
            if on[i] then got.Push(servers[i].machineIdentifier)
        end for
        ' With no servers the function has nothing to turn on, as the golden says.
        NxCheck(r, "server defaults: " + c.name, got.Join(","), NxLpJoin(c.on))
    end for

    for each c in g.reads
        sections = NxLpSections(c.libraries)
        got = NxSectionsRead(sections, NxLpSet(c.off), NxLpSet(c.includedHidden))
        NxCheck(r, "reads: " + c.name, got.Join(","), NxLpJoin(c.read))
    end for

    for each c in g.choices
        sections = NxLpSections(c.libraries)
        off = NxLpSet(c.off)
        included = NxLpSet(c.includedHidden)
        for each id in c.toggle
            for each s in sections
                if NxSectionKey(s.serverId, s.key) = id then NxSectionRowToggle(s, off, included)
            end for
        end for
        NxCheck(r, "choices, off: " + c.name, NxLpSorted(off), NxLpSortedList(c.offAfter))
        NxCheck(r, "choices, included hidden: " + c.name, NxLpSorted(included), NxLpSortedList(c.includedHiddenAfter))
    end for

    for each c in g.hiddenSwitchUpgrade
        reg = NxFakeRegistry()
        switchReg = NxFakeRegistry()
        if c.hiddenKnown = true then NxSaveSections(reg, NxLpSections(c.libraries))
        NxSaveDeselectedSections(reg, NxLpSet(c.off))
        NxSaveIncludedHiddenSections(reg, NxLpSet(c.includedHidden))
        if c.switchOn = true then switchReg.Write("includeHiddenLibraries", "1")
        done = NxCarryOverHiddenSwitch(reg, switchReg)
        NxCheck(r, "upgrade, done: " + c.name, NxToStr(done), NxToStr(c.done))
        NxCheck(r, "upgrade, included hidden: " + c.name, NxLpSorted(NxIncludedHiddenSections(reg)), NxLpSortedList(c.includedHiddenAfter))
        NxCheck(r, "upgrade, off is never rewritten: " + c.name, NxLpSorted(NxDeselectedSections(reg)), NxLpSortedList(c.offAfter))
        kept = switchReg.Read("includeHiddenLibraries")
        if c.done = true then
            NxCheck(r, "upgrade, switch cleared: " + c.name, kept, "")
        else
            NxCheck(r, "upgrade, switch kept for next time: " + c.name, kept, "1")
        end if
    end for

    for each c in g.pickerOffered
        NxCheck(r, "picker offered: " + c.name, NxToStr(NxPickerWanted(NxLpSections(c.libraries))), NxToStr(c.offered))
    end for

    for each c in g.signInReset
        reg = NxFakeRegistry()
        switchReg = NxFakeRegistry()
        NxSaveDeselectedSections(reg, NxLpSet(c.off))
        NxSaveIncludedHiddenSections(reg, NxLpSet(c.includedHidden))
        if c.legacySwitch = "on" then switchReg.Write("includeHiddenLibraries", "1")
        if c.legacySwitch = "off" then switchReg.Write("includeHiddenLibraries", "0")
        NxResetLibraryChoices(reg, switchReg)
        NxCheck(r, "sign-in reset, off: " + c.name, NxLpSorted(NxDeselectedSections(reg)), NxLpSortedList(c.offAfter))
        NxCheck(r, "sign-in reset, included hidden: " + c.name, NxLpSorted(NxIncludedHiddenSections(reg)), NxLpSortedList(c.includedHiddenAfter))
        NxCheck(r, "sign-in reset, the old switch: " + c.name, NxToStr(switchReg.Read("includeHiddenLibraries") = ""), NxToStr(c.legacySwitchAfter = invalid))
    end for

    ' The collections sweep leaves a library that is off alone.
    lists = {}
    lists["/library/sections"] = { key: "Directory", rows: [{ key: "1", type: "movie" }, { key: "2", type: "show" }] }
    for each sec in ["1", "2"]
        ck = (1000 + Val(sec)).ToStr()
        lists["/library/sections/" + sec + "/collections"] = { key: "Metadata", rows: [{ ratingKey: ck, title: "Collection " + sec }] }
        lists["/library/collections/" + ck + "/children"] = { key: "Metadata", rows: [{ ratingKey: "c" + sec + "a" }, { ratingKey: "c" + sec + "b" }] }
    end for
    srv = NxClPagingServer(lists, {})
    all = NxCollectionsFetchPlex("mid", srv)
    NxCheck(r, "collections: nothing off reads both libraries", NxToStr(all.Count()) + " " + NxToStr(NxClCountFor(srv.calls, "/library/sections/2/collections")), "2 1")
    srv = NxClPagingServer(lists, {})
    some = NxCollectionsFetchPlex("mid", srv, invalid, { "mid::2": true })
    NxCheck(r, "collections: a library that is off is not asked", NxToStr(some.Count()) + " " + NxToStr(NxClCountFor(srv.calls, "/library/sections/2/collections")) + " " + NxToStr(NxClCountFor(srv.calls, "/library/sections/1/collections")), "1 0 1")
    srv = NxClPagingServer(lists, {})
    other = NxCollectionsFetchPlex("mid", srv, invalid, { "other::2": true })
    NxCheck(r, "collections: the same key on another server leaves it on", NxToStr(other.Count()), "2")

    print "library picker golden cases (N-016):"; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' The golden's { id, hidden } libraries as the sections the code holds: the id
' is "<serverId>::<sectionKey>", split at the first "::".
function NxLpSections(libraries as Object) as Object
    out = []
    for each l in libraries
        at = Instr(1, l.id, "::")
        out.Push({ serverId: Left(l.id, at - 1), key: Mid(l.id, at + 2), title: "", type: "movie", hidden: l.hidden = true })
    end for
    return out
end function

function NxLpSet(ids as Object) as Object
    out = {}
    for each id in ids
        out[id] = true
    end for
    return out
end function

function NxLpJoin(ids as Object) as String
    return ids.Join(",")
end function

' A set's ids, sorted and joined, to compare as sets.
function NxLpSorted(set as Object) as String
    keys = []
    for each k in set
        if set[k] = true then keys.Push(k)
    end for
    keys.Sort()
    return keys.Join(",")
end function

function NxLpSortedList(ids as Object) as String
    keys = []
    for each k in ids
        keys.Push(k)
    end for
    keys.Sort()
    return keys.Join(",")
end function

' Each listed row against the golden's: id, title, type, label, the music video
' name rule, hidden, starts on and the line under the name.
sub NxLpCheckListed(r as Object, name as String, refs as Object, want as Object, backend as String)
    NxCheck(r, name + ": how many are listed", NxToStr(refs.Count()), NxToStr(want.Count()))
    multi = false
    for each s in refs
        if s.serverId <> refs[0].serverId then multi = true
    end for
    for i = 0 to want.Count() - 1
        if i < refs.Count() then
            s = refs[i]
            w = want[i]
            label = name + ": " + NxToStr(w.id)
            NxCheck(r, label + " id", NxSectionKey(s.serverId, s.key), w.id)
            NxCheck(r, label + " title", NxToStr(s.title), w.title)
            NxCheck(r, label + " type", NxToStr(s.type), w.type)
            NxCheck(r, label + " label", NxSectionTypeLabel(s.type, s.title), w.label)
            musicVideo = NxIsMusicVideoName(s.title) or s.type = "musicvideo"
            NxCheck(r, label + " music video", NxToStr(musicVideo), NxToStr(w.musicVideo))
            NxCheck(r, label + " hidden", NxToStr(s.hidden), NxToStr(w.hidden))
            NxCheck(r, label + " starts on", NxToStr(NxSectionRowOn(s, {}, {})), NxToStr(w.startsOn))
            NxCheck(r, label + " subtitle", NxSectionSubtitle(s, multi), w.subtitle)
        end if
    end for
end sub
