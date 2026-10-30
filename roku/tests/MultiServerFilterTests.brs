' I-065: with several large servers enabled at once, loadLibrary's combined
' items array and buildGuide's per-channel filter pass over it scale memory
' with the sum of every enabled server's library, not the largest one. A
' Roku Streaming Stick 4K crashed about 30 minutes into channel generation
' that way; one server of about 1,000 files worked.
'
' NxFilterPoolsByServer (source/filter/ChannelFilter.brs) answers this by
' filtering one server's items at a time, dropping each server's filter
' cache (item.nxFilter) before moving to the next, so no more of it is ever
' resident than the largest enabled server's items need. NxFilterPool is a
' plain per-item scan with no state carried between items, so this proves
' NxFilterPoolsByServer gives the exact same pools, in the exact same order,
' as NxFilterPool's one pass over a combined multi-server library, across
' every real channel in data/channels.json. Returns the failure count.
function NxRunMultiServerFilterTests(configPath as String, manifestPath as String) as Integer
    r = { pass: 0, fail: 0 }
    config = ParseJson(ReadAsciiFile(configPath))
    manifest = ParseJson(ReadAsciiFile(manifestPath))
    exclusive = NxFilterExclusiveRules(config.exclusiveRules)
    clock = NxFilterClock(1792195200&)

    items = NxMultiServerFixture()

    defs = []
    for each def in config.channels
        defs.Push({ id: def.id.ToStr(), compiled: NxFilterChannel(def) })
    end for

    ' The old way: one pass over every server's items combined.
    want = {}
    nonEmpty = 0
    for each d in defs
        rows = NxFilterPool(items, d.compiled, manifest, exclusive, clock, "plex")
        keys = []
        for each row in rows
            keys.Push(row.item.ratingKey)
        end for
        if keys.Count() > 0 then nonEmpty = nonEmpty + 1
        want[d.id] = keys.Join(",")
    end for
    NxCheck(r, "the fixture gives real channels something to match", FormatJson(nonEmpty > 10), "true")
    ' That pass memoized item.nxFilter on every item; the per-server split
    ' below must answer the same whether the cache starts warm or cold.
    for each it in items
        it.Delete("nxFilter")
    end for

    ' The new way: one server's items at a time.
    got = NxFilterPoolsByServer(items, defs, manifest, exclusive, clock, "plex")
    for each d in defs
        keys = []
        for each it in got[d.id]
            keys.Push(it.ratingKey)
        end for
        NxCheck(r, "channel " + d.id.ToStr() + " matches the single-pass filter", keys.Join(","), want[d.id])
    end for

    leaked = 0
    for each it in items
        if it.DoesExist("nxFilter") then leaked = leaked + 1
    end for
    NxCheck(r, "every item's filter cache is gone once its server is done", leaked.ToStr(), "0")

    print "multi-server filter cases: "; r.pass; " passed, "; r.fail; " failed"
    return r.fail
end function

' A small library spread over 4 fake servers (serverIndex 0 to 3), titles
' and genres drawn from data/channels.json's own vocabulary so real genre
' and studio channels get matches from more than one server, not just the
' catch-alls. Not meant to be realistic, only to spread the same matches a
' real multi-server library would across servers in a known, checkable way.
function NxMultiServerFixture() as Object
    genres = ["Comedy", "Drama", "Horror", "Documentary", "Action", "Science Fiction", "Animation", "Romance", "Thriller", "Family"]
    ratings = ["G", "PG", "PG-13", "R", "TV-14"]
    studios = ["Pixar", "A24", "Disney"]
    items = []
    for server = 0 to 3
        for i = 0 to 24
            g = [genres[(server * 7 + i) mod genres.Count()]]
            if i mod 5 = 0 then g.Push(genres[(i + 3) mod genres.Count()])
            it = {
                ratingKey: "s" + server.ToStr() + "-" + i.ToStr(), type: "movie", librarySource: "movie",
                title: "Server " + server.ToStr() + " Feature " + i.ToStr(), genres: g,
                year: 1975 + (server * 11 + i) mod 50, duration: 80 + (i mod 6) * 15,
                contentRating: ratings[(server + i) mod ratings.Count()],
                rating: 5.0 + ((server + i) mod 5) * 0.8, imdbRating: 5.0 + ((i * 3 + server) mod 5) * 0.9,
                imdbVotes: 1000 * (i + 1), viewCount: (i mod 3), serverIndex: server
            }
            if i mod 8 = 0 then it.studio = studios[i mod studios.Count()]
            if i mod 9 = 0 then it.networks = ["HBO"]
            if i mod 4 = 0 then
                it.type = "episode"
                it.episodeTitle = "Episode " + i.ToStr()
            end if
            items.Push(it)
        end for
    end for
    return items
end function
