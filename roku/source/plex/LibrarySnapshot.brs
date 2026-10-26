' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' The saved library, after the Apple TV app's LibrarySnapshotStore.swift: each
' server's scanned items and collections, kept on the TV so that switching a
' package, franchise, collection or server rebuilds the channels from it
' instead of reading every server again (Discussion #8, item 7: 3.5 minutes on
' the maintainer's stick).
'
' As on the Apple TV, the items go in chunk files and a small meta file says
' which are live. A save writes a new generation's chunks first and the meta
' last, so a save cut off part way leaves the previous generation readable.
' Kept per server, keyed by machine identifier, so turning a second server on
' reads only that one.
'
' A relaunch reuses a server's saved items while its library signature
' (LibraryChangeSignature.swift) is unchanged and they are under a day old,
' as the Apple TV app's refreshLibraryIfChanged does; otherwise it scans.
'
' Items are saved as the scan made them, less what only a build adds (the
' filter cache, the enrichment record) and the artwork paths, which nothing
' after the scan reads. Titles and schedules only, nothing secret.

function NxSnapshotDir() as String
    return NxCacheRoot() + "/nostalgex-library"
end function

' Bump when a saved item would no longer read the same; an old meta is ignored.
' 3: items carry videoProfile and audioChannels (source/util/DirectPlay.brs).
' 4: Jellyfin and Emby items carry bitrate (NxMbVideoQuery).
' 5: and audioTracks, when a file has more than one (NxMbAudioTracks).
' 6: and videoWidth and videoHeight, for the no-picture deadline (NxPictureDeadline).
function NxSnapshotFormat() as Integer
    return 6
end function

' Items per chunk file: about 1 MB of JSON, so a read or write never holds
' much more than that as one string.
function NxSnapshotChunkSize() as Integer
    return 2000
end function

' Past this age a server is scanned even when its signature is unchanged, since
' section stamps don't move for everything a guide reads (watch counts).
function NxSnapshotMaxAgeSec() as Integer
    return 86400
end function

' Whether a saved server can stand in for a scan: the signature matches and
' it is under a day old (LibraryChangeSignature.shouldSkipRefresh).
function NxSnapshotFresh(entry as Dynamic, signature as Dynamic, nowSec as LongInteger) as Boolean
    if type(entry) <> "roAssociativeArray" or signature = invalid then return false
    if not NxIsNumber(entry.savedAt) or entry.signature = invalid then return false
    if nowSec - entry.savedAt >= NxSnapshotMaxAgeSec() then return false
    return entry.signature = signature
end function

' { format, servers: { <machine id>: entry } }, empty when there is none or
' it is from another format. An entry is { gen, chunks, count, savedAt,
' signature, collections }.
function NxSnapshotReadMeta(dir as String) as Object
    empty = { format: NxSnapshotFormat(), servers: {} }
    text = NxSnapshotReadFile(dir + "/meta.json")
    if text = "" then return empty
    meta = ParseJson(text)
    if type(meta) <> "roAssociativeArray" then return empty
    if meta.format <> NxSnapshotFormat() or type(meta.servers) <> "roAssociativeArray" then return empty
    return meta
end function

' A server's saved items, each given this run's serverIndex, and its
' collections, as { items, collections, entry }; invalid when it isn't saved
' or a chunk is missing.
function NxSnapshotLoadServer(dir as String, meta as Object, key as String, serverIndex as Integer) as Dynamic
    entry = meta.servers[key]
    if type(entry) <> "roAssociativeArray" or not NxIsNumber(entry.chunks) then return invalid
    items = []
    for c = 0 to entry.chunks - 1
        text = NxSnapshotReadFile(NxSnapshotChunkPath(dir, key, entry.gen, c))
        if text = "" then return invalid
        chunk = ParseJson(text)
        text = ""
        if type(chunk) <> "roArray" then return invalid
        for each it in chunk
            it.serverIndex = serverIndex
            items.Push(it)
        end for
    end for
    if NxIsNumber(entry.count) and items.Count() <> entry.count then return invalid
    collections = entry.collections
    if type(collections) <> "roArray" then collections = invalid
    return { items: items, collections: collections, entry: entry }
end function

' The saved item whose ratingKey is ratingKey, given its server's index (its
' place in keys, the servers' save keys), or invalid. One chunk at a time,
' so a lookup never holds a whole library.
function NxSnapshotFindItem(dir as String, meta as Object, keys as Object, ratingKey as String) as Dynamic
    if ratingKey = "" then return invalid
    for i = 0 to keys.Count() - 1
        entry = meta.servers[keys[i]]
        if type(entry) = "roAssociativeArray" and NxIsNumber(entry.chunks) then
            for c = 0 to entry.chunks - 1
                text = NxSnapshotReadFile(NxSnapshotChunkPath(dir, keys[i], entry.gen, c))
                chunk = invalid
                if text <> "" then chunk = ParseJson(text)
                text = ""
                if type(chunk) = "roArray" then
                    for each it in chunk
                        if type(it) = "roAssociativeArray" and NxToStr(it.ratingKey) = ratingKey then
                            it.serverIndex = i
                            return it
                        end if
                    end for
                end if
            end for
        end if
    end for
    return invalid
end function

' Saves one server's items (only those with this serverIndex) and
' collections under a new generation, then the meta, then drops the old
' generation's chunks. `collections` may be invalid when they couldn't be read.
sub NxSnapshotSaveServer(dir as String, meta as Object, key as String, items as Object, serverIndex as Integer, collections as Dynamic, signature as Dynamic, nowSec as LongInteger)
    CreateDirectory(dir)
    old = meta.servers[key]
    gen = 1
    if type(old) = "roAssociativeArray" and NxIsNumber(old.gen) then gen = old.gen + 1
    size = NxSnapshotChunkSize()
    chunk = []
    chunks = 0
    count = 0
    for each it in items
        if it.serverIndex = serverIndex then
            copy = {}
            for each k in it
                lk = LCase(k)
                if lk <> "nxfilter" and lk <> "enrichment" and lk <> "thumb" and lk <> "art" and lk <> "serverindex" then copy[k] = it[k]
            end for
            chunk.Push(copy)
            count = count + 1
            if chunk.Count() >= size then
                NxSnapshotWriteFile(NxSnapshotChunkPath(dir, key, gen, chunks), FormatJson(chunk))
                chunks = chunks + 1
                chunk = []
            end if
        end if
    end for
    if chunk.Count() > 0 then
        NxSnapshotWriteFile(NxSnapshotChunkPath(dir, key, gen, chunks), FormatJson(chunk))
        chunks = chunks + 1
    end if
    meta.servers[key] = { gen: gen, chunks: chunks, count: count, savedAt: nowSec, signature: signature, collections: collections }
    NxSnapshotWriteMeta(dir, meta)
    if type(old) = "roAssociativeArray" and NxIsNumber(old.chunks) then
        for c = 0 to old.chunks - 1
            DeleteFile(NxSnapshotChunkPath(dir, key, old.gen, c))
        end for
    end if
end sub

' Drops saved servers the account no longer has.
sub NxSnapshotForgetServers(dir as String, meta as Object, keepKeys as Object)
    ' A key read back by `for each` may not keep its case on a TV, so the
    ' compare doesn't either: a kept server must never lose its save.
    keep = {}
    for each k in keepKeys
        keep[LCase(k)] = true
    end for
    gone = []
    for each key in meta.servers
        if keep[LCase(key)] <> true then gone.Push(key)
    end for
    if gone.Count() = 0 then return
    for each key in gone
        entry = meta.servers[key]
        meta.servers.Delete(key)
        if type(entry) = "roAssociativeArray" and NxIsNumber(entry.chunks) then
            for c = 0 to entry.chunks - 1
                DeleteFile(NxSnapshotChunkPath(dir, key, entry.gen, c))
            end for
        end if
    end for
    NxSnapshotWriteMeta(dir, meta)
end sub

sub NxSnapshotClear(dir as String)
    for each name in ListDir(dir)
        DeleteFile(dir + "/" + name)
    end for
    DeleteDirectory(dir)
end sub

' The saved library, guide, pools and enrichment cache (which TMDB ids the
' library has) are one account's library. They live in cachefs:, which
' outlasts deleting the app while the registry (the sign-in) does not, so a
' file beside them says whose they are: SHA-1 of the plex.tv account id.
' root is NxCacheRoot() (cachefs:, or a test build's own folder) except in
' the tests.
function NxCacheOwnerPath(root = "" as String) as String
    if root = "" then root = NxCacheRoot()
    return root + "/nostalgex-owner.txt"
end function

function NxCacheOwnerHash(accountID as String) as String
    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(accountID)
    d = CreateObject("roEVPDigest")
    d.Setup("sha1")
    return d.Process(bytes)
end function

sub NxClearAccountCaches(root = "" as String)
    if root = "" then root = NxCacheRoot()
    NxSnapshotClear(root + "/nostalgex-library")
    DeleteFile(root + "/nostalgex-guide.json")
    DeleteFile(root + "/nostalgex-pools.json")
    DeleteFile(root + "/nostalgex-enrichment.json")
    ' The music-video genre lookups (source/music/MusicLookup.brs, #73).
    DeleteFile(root + "/nostalgex-music-videos.json")
    DeleteFile(NxCacheOwnerPath(root))
end sub

' After a sign-in: a fresh one (no saved token, as after reinstalling)
' clears caches another account left, or that no account was recorded for.
' A saved sign-in only records the owner, since the library may already be
' reading the caches. Returns true when it cleared them.
function NxClaimAccountCaches(accountID as String, fresh as Boolean, root = "" as String) as Boolean
    if root = "" then root = NxCacheRoot()
    owner = NxCacheOwnerHash(accountID)
    saved = ""
    if CreateObject("roFileSystem").Exists(NxCacheOwnerPath(root)) then saved = ReadAsciiFile(NxCacheOwnerPath(root))
    if saved = owner then return false
    cleared = false
    if fresh then
        NxClearAccountCaches(root)
        cleared = true
    end if
    WriteAsciiFile(NxCacheOwnerPath(root), owner)
    return cleared
end function

sub NxSnapshotWriteMeta(dir as String, meta as Object)
    meta.format = NxSnapshotFormat()
    NxSnapshotWriteFile(dir + "/meta.json", FormatJson(meta))
end sub

' Machine identifiers are hex, but only letters and digits reach a file name.
function NxSnapshotChunkPath(dir as String, key as String, gen as Dynamic, index as Integer) as String
    safe = CreateObject("roRegex", "[^A-Za-z0-9]", "").ReplaceAll(key, "_")
    n = index.ToStr()
    while n.Len() < 4
        n = "0" + n
    end while
    return dir + "/" + safe + "-g" + NxToStr(gen) + "-" + n + ".json"
end function

' UTF-8 both ways, through bytes: ReadAsciiFile refuses big files.
sub NxSnapshotWriteFile(path as String, text as String)
    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(text)
    bytes.WriteFile(path)
end sub

function NxSnapshotReadFile(path as String) as String
    bytes = CreateObject("roByteArray")
    if not bytes.ReadFile(path) then return ""
    return bytes.ToAsciiString()
end function
