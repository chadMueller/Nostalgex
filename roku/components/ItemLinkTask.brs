' Copyright (c) 2026 nostalgex-roku contributors, MIT License.

sub init()
    m.top.functionName = "find"
end sub

sub find()
    found = invalid
    servers = ParseJson(NxPlexRegistry().Read("servers"))
    if type(servers) = "roArray" then
        ' Each server's save key, as LibraryTask keys them.
        keys = []
        for each s in servers
            key = NxToStr(s.machineIdentifier)
            if key = "" then key = "plex"
            keys.Push(key)
        end for
        dir = NxSnapshotDir()
        found = NxSnapshotFindItem(dir, NxSnapshotReadMeta(dir), keys, m.top.itemId)
    end if
    if found = invalid then
        m.top.airing = {}
    else
        m.top.airing = NxLinkedAiring(found, CreateObject("roDateTime").AsSeconds())
    end if
end sub
