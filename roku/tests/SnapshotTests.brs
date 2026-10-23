' Runs source/plex/LibrarySnapshot.brs and NxLibrarySignature: the saved
' library a rebuild reads instead of the servers. Hand-written cases; the
' signature's follow LibraryChangeSignatureTests.swift. Returns the failure
' count.

function NxRunSnapshotTests() as Integer
    r = { pass: 0, fail: 0 }

    ' ── Signature ──
    a = [{ key: "2", updatedAt: 20, contentChangedAt: 7 }, { key: "1", updatedAt: 10 }]
    NxSnapCheck(r, "signature sorted, missing field as 0", NxLibrarySignature("srv", a), "srv:1=u10/c0,2=u20/c7")
    NxSnapCheck(r, "signature ignores scannedAt", NxLibrarySignature("srv", [{ key: "1", updatedAt: 10, scannedAt: 99 }]), NxLibrarySignature("srv", [{ key: "1", updatedAt: 10, scannedAt: 5 }]))
    NxSnapCheck(r, "signature: a section with neither", NxLibrarySignature("srv", [{ key: "1", updatedAt: 10 }, { key: "2" }]) = invalid, true)
    NxSnapCheck(r, "signature: no sections", NxLibrarySignature("srv", []) = invalid, true)

    ' ── Fresh ──
    entry = { savedAt: 1000, signature: "s1" }
    NxSnapCheck(r, "fresh: same signature, young", NxSnapshotFresh(entry, "s1", 1000 + 3600), true)
    NxSnapCheck(r, "stale: signature changed", NxSnapshotFresh(entry, "s2", 1000 + 3600), false)
    NxSnapCheck(r, "stale: signature unreadable", NxSnapshotFresh(entry, invalid, 1000 + 3600), false)
    NxSnapCheck(r, "stale: a day old", NxSnapshotFresh(entry, "s1", 1000 + 86400), false)
    NxSnapCheck(r, "stale: saved without a signature", NxSnapshotFresh({ savedAt: 1000, signature: invalid }, invalid, 1001), false)
    NxSnapCheck(r, "stale: not saved", NxSnapshotFresh(invalid, "s1", 1001), false)

    ' ── Save and load ──
    dir = "tmp:/nx-snapshot-test"
    NxSnapshotClear(dir)
    meta = NxSnapshotReadMeta(dir)
    NxSnapCheck(r, "no meta reads empty", meta.servers.Count(), 0)
    items = []
    for n = 1 to 4500
        items.Push({ title: "T" + n.ToStr(), ratingKey: n.ToStr(), serverIndex: 0, genres: ["Drama", invalid], thumb: "/t", nxFilter: { x: 1 }, enrichment: { y: 2 } })
    end for
    items.Push({ title: "Other server", ratingKey: "9", serverIndex: 1 })
    coll = [{ id: "abc:1", title: "C", childKeys: ["1"], serverKey: "abc" }]
    NxSnapshotSaveServer(dir, meta, "abc", items, 0, coll, "sig", 5000)
    NxSnapCheck(r, "three chunks of 2000", meta.servers["abc"].chunks, 3)
    NxSnapCheck(r, "only that server's items", meta.servers["abc"].count, 4500)

    meta = NxSnapshotReadMeta(dir)
    got = NxSnapshotLoadServer(dir, meta, "abc", 3)
    NxSnapCheck(r, "loads", got <> invalid, true)
    if got <> invalid then
        NxSnapCheck(r, "every item back", got.items.Count(), 4500)
        NxSnapCheck(r, "order kept", got.items[4499].title, "T4500")
        NxSnapCheck(r, "takes this run's server index", got.items[0].serverIndex, 3)
        NxSnapCheck(r, "build-only fields dropped", got.items[0].nxFilter = invalid and got.items[0].enrichment = invalid and got.items[0].thumb = invalid, true)
        NxSnapCheck(r, "invalid in a list kept", FormatJson(got.items[0].genres), "[""Drama"",null]")
        NxSnapCheck(r, "collections back", got.collections[0].id, "abc:1")
        NxSnapCheck(r, "signature saved", got.entry.signature, "sig")
    end if
    NxSnapCheck(r, "an unsaved server", NxSnapshotLoadServer(dir, meta, "zzz", 0) = invalid, true)

    ' A second save is a new generation; the old one's chunks go.
    NxSnapshotSaveServer(dir, meta, "abc", [items[0]], 0, invalid, invalid, 6000)
    NxSnapCheck(r, "old generation deleted", NxSnapshotReadFile(NxSnapshotChunkPath(dir, "abc", 1, 0)) <> "", false)
    got = NxSnapshotLoadServer(dir, NxSnapshotReadMeta(dir), "abc", 0)
    NxSnapCheck(r, "new generation loads", got.items.Count(), 1)
    NxSnapCheck(r, "collections unread stay unknown", got.collections = invalid, true)

    ' A missing chunk means no save, so the server is scanned.
    DeleteFile(NxSnapshotChunkPath(dir, "abc", 2, 0))
    NxSnapCheck(r, "missing chunk", NxSnapshotLoadServer(dir, NxSnapshotReadMeta(dir), "abc", 0) = invalid, true)

    ' Servers the account no longer has are dropped.
    meta = NxSnapshotReadMeta(dir)
    NxSnapshotSaveServer(dir, meta, "def", items, 1, [], "s", 6000)
    NxSnapshotForgetServers(dir, meta, ["def"])
    meta = NxSnapshotReadMeta(dir)
    NxSnapCheck(r, "gone server forgotten", meta.servers.DoesExist("abc"), false)
    NxSnapCheck(r, "kept server stays", NxSnapshotLoadServer(dir, meta, "def", 1).items.Count(), 1)
    NxSnapshotForgetServers(dir, meta, ["DEF"])
    NxSnapCheck(r, "kept server stays whatever the key's case", NxSnapshotReadMeta(dir).servers.DoesExist("def"), true)

    ' A sideloaded build's item link (NxSnapshotFindItem), across servers.
    meta = NxSnapshotReadMeta(dir)
    NxSnapshotSaveServer(dir, meta, "abc", items, 0, invalid, invalid, 7000)
    keys = ["def", "abc"]
    found = NxSnapshotFindItem(dir, meta, keys, "4321")
    NxSnapCheck(r, "find: an item in a later chunk", found <> invalid, true)
    if found <> invalid then
        NxSnapCheck(r, "find: that item", found.title, "T4321")
        NxSnapCheck(r, "find: its server's place in keys", found.serverIndex, 1)
    end if
    found = NxSnapshotFindItem(dir, meta, keys, "9")
    NxSnapCheck(r, "find: the other server's", found <> invalid, true)
    if found <> invalid then NxSnapCheck(r, "find: the other server's index", found.serverIndex, 0)
    NxSnapCheck(r, "find: not saved", NxSnapshotFindItem(dir, meta, keys, "99999") = invalid, true)
    NxSnapCheck(r, "find: no id", NxSnapshotFindItem(dir, meta, keys, "") = invalid, true)
    NxSnapCheck(r, "find: a server not saved", NxSnapshotFindItem(dir, meta, ["zzz"], "9") = invalid, true)
    NxSnapCheck(r, "find: nothing saved", NxSnapshotFindItem(dir, { servers: {} }, keys, "9") = invalid, true)

    ' Another format is ignored.
    NxSnapshotWriteFile(dir + "/meta.json", "{""format"":0,""servers"":{""def"":{}}}")
    NxSnapCheck(r, "other format ignored", NxSnapshotReadMeta(dir).servers.Count(), 0)
    NxSnapshotClear(dir)
    NxSnapCheck(r, "cleared", ListDir("tmp:/").Count() > 0 and NxHasValue(ListDir("tmp:/"), "nx-snapshot-test"), false)

    ' ── Whose caches (NxClaimAccountCaches) ──
    ' roEVPDigest and roFileSystem are the TV's only: these run in deploy.sh --test.
    if NxTestRuntime() = "device" then
        root = "tmp:/nx-owner-test"
        CreateDirectory(root)
        NxSnapCheck(r, "owner: the id is hashed", Len(NxCacheOwnerHash("uuid-a")) = 40 and NxCacheOwnerHash("uuid-a") <> "uuid-a", true)
        WriteAsciiFile(root + "/nostalgex-guide.json", "{}")
        NxSnapCheck(r, "owner: saved sign-in, none recorded, keeps", NxClaimAccountCaches("uuid-a", false, root), false)
        NxSnapCheck(r, "owner: ...and the guide stays", ReadAsciiFile(root + "/nostalgex-guide.json") <> "", true)
        NxSnapCheck(r, "owner: ...and records the account", ReadAsciiFile(NxCacheOwnerPath(root)), NxCacheOwnerHash("uuid-a"))
        NxSnapCheck(r, "owner: fresh, same account, keeps", NxClaimAccountCaches("uuid-a", true, root), false)
        NxSnapCheck(r, "owner: ...and the guide stays", ReadAsciiFile(root + "/nostalgex-guide.json") <> "", true)
        NxSnapCheck(r, "owner: saved sign-in, another account, keeps", NxClaimAccountCaches("uuid-b", false, root), false)
        NxSnapCheck(r, "owner: ...and records that account", ReadAsciiFile(NxCacheOwnerPath(root)), NxCacheOwnerHash("uuid-b"))
        NxSnapCheck(r, "owner: fresh, another account, clears", NxClaimAccountCaches("uuid-a", true, root), true)
        NxSnapCheck(r, "owner: ...the guide is gone", ReadAsciiFile(root + "/nostalgex-guide.json") <> "", false)
        NxSnapCheck(r, "owner: ...and the new account recorded", ReadAsciiFile(NxCacheOwnerPath(root)), NxCacheOwnerHash("uuid-a"))
        DeleteFile(NxCacheOwnerPath(root))
        WriteAsciiFile(root + "/nostalgex-pools.json", "{}")
        NxSnapCheck(r, "owner: fresh, none recorded, clears", NxClaimAccountCaches("uuid-a", true, root), true)
        NxSnapCheck(r, "owner: ...the pools are gone", ReadAsciiFile(root + "/nostalgex-pools.json") <> "", false)
        NxClearAccountCaches(root)
        DeleteDirectory(root)
    end if

    print "snapshot cases: "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' NxCheck over any values, compared as JSON.
sub NxSnapCheck(r as Object, name as String, got as Dynamic, want as Dynamic)
    NxCheck(r, name, FormatJson(got), FormatJson(want))
end sub
