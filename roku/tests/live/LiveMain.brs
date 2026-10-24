' Live check entry point (scripts/deploy.sh --live): loads the library from
' the Plex servers this TV is signed in to, then prints fingerprints of every
' item, every channel's pool and what every channel airs today (after the
' daily shuffle, time restrictions and the session schedule cache), for
' tests/live/compare.mjs to check against upstream's own code run on the same
' library. Prints no token, no URL and no metadata, only ratingKeys, counts
' and SHA-1 prefixes.
sub Main(args = invalid as Dynamic)
    timer = CreateObject("roTimespan")
    servers = ParseJson(NxPlexRegistry().Read("servers"))
    if type(servers) <> "roArray" or servers.Count() = 0 then
        print "LIVE FAILED not signed in; run the app and sign in first"
        return
    end if

    items = []
    for i = 0 to servers.Count() - 1
        got = NxPlexScanServer(servers[i], i)
        if got = invalid then
            print "LIVE FAILED a server's library could not be read"
            return
        end if
        items.Append(got)
    end for
    print "LIVE LOADED "; items.Count(); " items in "; timer.TotalMilliseconds(); " ms"

    all = CreateObject("roEVPDigest")
    all.Setup("sha1")
    for each it in items
        line = NxLiveLine(it)
        print "LIVEITEM "; NxToStr(it.ratingKey); " "; Left(NxSha1(line), 12)
        all.Update(NxBytes(line + Chr(10)))
    end for
    print "LIVE ITEMS "; items.Count(); " "; all.Final()

    config = ParseJson(ReadAsciiFile("pkg:/data/channels.json"))
    manifest = ParseJson(ReadAsciiFile("pkg:/data/channels-memberships.json"))
    exclusive = NxFilterExclusiveRules(config.exclusiveRules)
    clock = NxFilterClock()
    dayStart = clock.nowSec - clock.secOfDay
    dayNumber = dayStart \ 86400 ' integer division: / would round through a single-precision Float
    print "LIVE CLOCK "; clock.nowSec; " "; dayStart; " "; dayNumber
    timer.Mark()
    NxClearManifests()
    for each ch in config.channels
        compiled = NxFilterChannel(ch)
        pool = NxFilterPool(items, compiled, manifest, exclusive, clock)
        parts = []
        poolItems = []
        for each row in pool
            parts.Push(NxToStr(row.item.ratingKey) + ":" + row.via)
            poolItems.Push(row.item)
        end for
        ' What the guide airs: the pool in library order, the hour's
        ' restrictions, then the day's schedule, exactly as LibraryTask builds it.
        blocks = []
        aired = NxManifestBlocks(ch, NxTimeFilteredPool(ch, poolItems, NxLocalDay(clock.nowSec).hour), clock.nowSec)
        for each b in aired
            blocks.Push(NxToStr(b.item.ratingKey) + "@" + b.startSec.ToStr() + "-" + b.endSec.ToStr())
        end for
        ' An empty pool prints its count only: roEVPDigest gives "" for empty input.
        print "LIVECH "; ch.id; " "; pool.Count(); " "; Left(NxSha1(parts.Join(",")), 12); " "; Left(NxSha1(blocks.Join(",")), 12)
    end for
    print "LIVE CHANNELS took "; timer.TotalMilliseconds(); " ms"
    print "LIVE DONE"
end sub

' One item as a canonical line; tests/live/compare.mjs builds the same.
function NxLiveLine(it as Object) as String
    fields = ["ratingKey", "type", "title", "episodeTitle", "artist", "year", "contentRating", "duration", "genres", "rating", "userRating", "viewCount", "addedAt", "studio", "librarySource", "tmdbID", "partKey", "container", "summary", "thumb", "art"]
    out = []
    for each f in fields
        v = it[f]
        if type(v) = "roArray" then
            g = []
            for each x in v
                g.Push(NxLiveValue(x))
            end for
            out.Push(g.Join("|"))
        else
            out.Push(NxLiveValue(v))
        end if
    end for
    return out.Join(Chr(9))
end function

function NxLiveValue(v as Dynamic) as String
    if v = invalid then return "~"
    s = NxToStr(v)
    s = s.Replace("\", "\\")
    s = s.Replace(Chr(9), "\t")
    s = s.Replace(Chr(10), "\n")
    s = s.Replace(Chr(13), "\r")
    return s
end function

function NxBytes(s as String) as Object
    ba = CreateObject("roByteArray")
    ba.FromAsciiString(s)
    return ba
end function

function NxSha1(s as String) as String
    d = CreateObject("roEVPDigest")
    d.Setup("sha1")
    return d.Process(NxBytes(s))
end function
