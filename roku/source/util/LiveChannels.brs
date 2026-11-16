' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' The live channels.json (Trello N-074). The app ships a channels.json; this
' keeps a newer copy of it from https://www.nostalgex.app/channels.json, so a
' channel change doesn't wait for a release. The same file the web tuner and
' the Apple TV read.
'
' How it fits:
'   - LiveChannelsTask fetches at launch (once the guide is up) and about every
'     24 h on a TV left on, off the render thread, with a short timeout. It
'     only stores: NxLiveChannelsStore accepts a copy or throws it away.
'   - A guide build reads the config through NxChannelsConfig: the newest
'     accepted copy, else the bundled one. A copy that arrives mid-session is
'     therefore applied at the next guide build (a rebuild, a package change,
'     the 6-hour refresh), never to a guide that is playing.
'
' What is accepted. channels.json has no format field; its `version` is a
' content counter that only goes up (50 today). A copy is taken when it
'   - parses to an object with non-empty channels, bundles and exclusiveRules;
'   - has an integer version, not below this build's own (an older live file
'     would take channels away) ;
'   - names a `formatVersion` this build understands, if it names one at all (1 today:
'     a file that ever changes shape must say so, and an old build then keeps
'     what it has);
'   - lists every channel as an object with an id and a name, no id twice;
'   - is under 2 MB.
' Anything else is rejected and the cache is left as it was.

function NxLiveChannelsUrl() as String
    return "https://www.nostalgex.app/channels.json"
end function

' The newest file format this build reads. A file without `formatVersion` is 1.
function NxLiveChannelsFormat() as Integer
    return 1
end function

function NxLiveChannelsMaxBytes() as Integer
    return 2000000
end function

' The time between fetches on a TV left on, after one that worked, and after
' one that didn't.
function NxLiveChannelsEverySec() as Integer
    return 86400
end function

function NxLiveChannelsRetrySec() as Integer
    return 3600
end function

function NxLiveChannelsPath(root as String) as String
    return root + "/nostalgex-channels.json"
end function

' { ok, reason, doc, version }: the text checked as the rules above say.
' bundledVersion is the version of the channels.json in the package.
function NxLiveChannelsAccept(text as Dynamic, bundledVersion as Integer) as Object
    if type(text) <> "String" and type(text) <> "roString" then return NxLiveReject("no text")
    if Len(text) = 0 then return NxLiveReject("empty")
    if Len(text) > NxLiveChannelsMaxBytes() then return NxLiveReject("too big")
    doc = ParseJson(text)
    if type(doc) <> "roAssociativeArray" then return NxLiveReject("not a JSON object")
    v = doc.version
    if type(v) <> "roInt" and type(v) <> "Integer" and type(v) <> "roInteger" and type(v) <> "LongInteger" then return NxLiveReject("no version")
    if v < 1 then return NxLiveReject("bad version")
    if v < bundledVersion then return NxLiveReject("older than this build's")
    fmt = doc.formatVersion
    if fmt <> invalid then
        if (type(fmt) <> "roInt" and type(fmt) <> "Integer" and type(fmt) <> "roInteger") or fmt < 1 then return NxLiveReject("bad formatVersion")
        if fmt > NxLiveChannelsFormat() then return NxLiveReject("formatVersion " + fmt.ToStr() + " is newer than this build reads")
    end if
    if type(doc.bundles) <> "roArray" or doc.bundles.Count() = 0 then return NxLiveReject("no bundles")
    if type(doc.exclusiveRules) <> "roArray" then return NxLiveReject("no exclusive rules")
    if type(doc.channels) <> "roArray" or doc.channels.Count() = 0 then return NxLiveReject("no channels")
    seen = {}
    for each ch in doc.channels
        if type(ch) <> "roAssociativeArray" then return NxLiveReject("a channel is not an object")
        if ch.id = invalid or ch.name = invalid then return NxLiveReject("a channel has no id or name")
        key = ch.id.ToStr()
        if seen[key] = true then return NxLiveReject("channel id " + key + " twice")
        seen[key] = true
    end for
    return { ok: true, reason: "", doc: doc, version: v }
end function

function NxLiveReject(reason as String) as Object
    return { ok: false, reason: reason, doc: invalid, version: 0 }
end function

' The `version` of a channels.json's text without parsing it: the key is the
' first in the file. -1 when it isn't found.
function NxLiveVersionOf(text as String) as Integer
    head = Left(text, 120)
    at = Instr(1, head, """version""")
    if at = 0 then return -1
    rest = Mid(head, at + 9)
    n = 0
    digits = 0
    for i = 1 to Len(rest)
        c = Asc(Mid(rest, i, 1))
        if c >= 48 and c <= 57 then
            n = n * 10 + (c - 48)
            digits = digits + 1
        else if digits > 0 then
            exit for
        else if c <> 32 and c <> 58 and c <> 10 and c <> 13 and c <> 9 then
            return -1
        end if
    end for
    if digits = 0 then return -1
    return n
end function

' A fetched body: accepted, it replaces the cache and is stamped on `store`
' (a registry section: Read, Write, Flush); rejected, nothing is touched but
' the time of the try. Returns the accept result, with `stored` true when the
' cache was written.
function NxLiveChannelsStore(body as Dynamic, root as String, store as Object, nowSec as LongInteger, bundledVersion as Integer) as Object
    res = NxLiveChannelsAccept(body, bundledVersion)
    res.stored = false
    if store <> invalid then store.Write("tried", nowSec.ToStr())
    if res.ok then
        path = NxLiveChannelsPath(root)
        tmp = path + ".new"
        DeleteFile(tmp)
        if NxLiveWriteFile(tmp, body) then
            ' A file that reads back as what was fetched replaces the cache; the rename is the commit.
            if NxLiveVersionOf(NxLiveReadFile(tmp)) = res.version then
                DeleteFile(path)
                if MoveFile(tmp, path) then res.stored = true
            end if
        end if
        DeleteFile(tmp)
        if not res.stored then
            res.ok = false
            res.reason = "could not save"
        end if
    end if
    if store <> invalid then
        if res.stored then
            store.Write("okAt", nowSec.ToStr())
            store.Write("version", res.version.ToStr())
        end if
        store.Flush()
    end if
    return res
end function

' Whether a TV left on should fetch again: a day after the last try that worked,
' an hour after one that didn't, at once with none. The launch fetch doesn't ask.
function NxLiveChannelsDue(store as Object, nowSec as LongInteger) as Boolean
    if store = invalid then return true
    tried = Val(store.Read("tried"))
    if tried <= 0 then return true
    ok = Val(store.Read("okAt"))
    gap = NxLiveChannelsRetrySec()
    if ok >= tried then gap = NxLiveChannelsEverySec()
    return nowSec - tried >= gap
end function

' The channels config a guide build reads: { config, source } where source is
' "cache" or "bundled". The cached copy is checked again here (an app update
' can leave a cache older than its own file, and a file can be damaged), and
' anything wrong with it means the bundled copy. bundledPath is pkg:/data/channels.json.
function NxChannelsConfig(root as String, bundledPath as String) as Object
    ' The package's own file always exists: ReadAsciiFile, as the loader always read it.
    bundledText = ReadAsciiFile(bundledPath)
    bundledVersion = NxLiveVersionOf(bundledText)
    path = NxLiveChannelsPath(root)
    if bundledVersion >= 0 then
        cached = NxLiveReadFile(path)
        cv = NxLiveVersionOf(cached)
        ' Equal to the bundled version is the same content: not worth parsing again.
        if cv > bundledVersion then
            parse = CreateObject("roTimespan")
            res = NxLiveChannelsAccept(cached, bundledVersion)
            print "channels: the saved live copy read and checked in "; parse.TotalMilliseconds(); " ms ("; Len(cached) \ 1024; " KB)"
            if res.ok then return { config: res.doc, source: "cache", version: res.version }
            print "channels: the saved live copy is not usable ("; res.reason; "); using the bundled one"
        end if
    end if
    return { config: ParseJson(bundledText), source: "bundled", version: bundledVersion }
end function

' A file's text, "" when it isn't there. Through bytes, as the saved library is
' (source/plex/LibrarySnapshot.brs): roFileSystem is invalid on the render
' thread, where Settings reads the config, and ReadAsciiFile refuses big files.
function NxLiveReadFile(path as String) as String
    bytes = CreateObject("roByteArray")
    if not bytes.ReadFile(path) then return ""
    return bytes.ToAsciiString()
end function

function NxLiveWriteFile(path as String, text as String) as Boolean
    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(text)
    return bytes.WriteFile(path)
end function
