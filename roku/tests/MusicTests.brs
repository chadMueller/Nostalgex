' Runs source/music/MusicLookup.brs (#73) against tests/vectors/music.json,
' which upstream's own scripts/nostalgex-music-brainz.js made
' (tests/gen-music.mjs): genre mapping, Deezer's pick, the recording
' ranking, years, items with a cached row, and whole lookup passes over
' canned answers, the questions asked in order included. Then hand-written
' cases for what the vectors can't hold: the pacing and the cache rules.
' Returns the failure count.

function NxRunMusicTests(vectorsPath as String) as Integer
    r = { pass: 0, fail: 0 }
    v = ParseJson(ReadAsciiFile(vectorsPath)).music
    nowYear = v.nowYear

    for each t in v.tags
        NxCheck(r, "tags " + FormatJson(t.tags), NxEnCanon(NxMusicMapTags(t.tags)), t.want)
    end for
    for each t in v.deezer
        NxCheck(r, "deezer genres " + FormatJson(t.genres), NxEnCanon(NxMusicMapDeezerGenres(t.genres)), t.want)
    end for
    for each t in v.hits
        pick = NxMusicDeezerBestHit(ParseJson(t.hits), t.artist)
        got = invalid
        if pick <> invalid then got = pick.id
        NxCheck(r, "deezer pick " + t.artist, NxEnCanon(got), t.want)
    end for
    for each t in v.ranks
        best = NxMusicBestRecording(ParseJson(t.recordings), t.song, t.artist, t.year)
        got = invalid
        if best <> invalid then got = best.mbid
        NxCheck(r, "rank " + t.song, NxEnCanon(got), t.want)
    end for
    for each t in v.years
        NxCheck(r, "year " + FormatJson([t.title, t.mb, t.plex]), NxEnCanon(NxMusicResolveYear(t.title, t.mb, t.plex, nowYear)), t.want)
    end for
    for each t in v.titleYears
        NxCheck(r, "year in title " + t.title, NxEnCanon(NxMusicYearInTitle(t.title)), t.want)
    end for
    for each t in v.apply
        got = NxMusicApply(ParseJson(t.item), ParseJson(t.enr), nowYear)
        NxCheck(r, "apply " + Left(t.item, 40), NxEnCanon({ title: got.title, artist: got.artist, genres: got.genres, year: got.year }), t.want)
    end for
    for each t in v.display
        got = NxMusicItemsWithCache([ParseJson(t.item)], {}, nowYear)[0]
        NxCheck(r, "display " + Left(t.item, 40), NxEnCanon({ title: got.title, artist: got.artist, genres: got.genres, year: got.year }), t.want)
    end for
    for each t in v.useful
        NxCheck(r, "useful " + FormatJson(t.genres), FormatJson(NxMusicUsefulGenres(t.genres)), FormatJson(t.want))
    end for
    for each t in v.merges
        NxCheck(r, "merge " + FormatJson(t.a) + FormatJson(t.b), NxEnCanon(NxMusicMergeGenres(t.a, t.b)), t.want)
    end for

    now& = 1761480000
    for each p in v.passes
        net = NxMusicFakeNet(ParseJson(p.canned))
        cache = ParseJson(p.cache)
        ' Rows given as fetched now, as the generator writes them.
        for each k in cache
            cache[k].fetched = now&
            if not cache[k].DoesExist("deezerid") then cache[k].deezerid = invalid
        end for
        NxMusicEnrich(net, ParseJson(p.items), cache, now&)
        rows = {}
        for each k in cache
            row = {}
            for each f in cache[k]
                if f <> "fetched" then row[f] = cache[k][f]
            end for
            rows[k] = row
        end for
        NxCheck(r, "pass: " + p.name, NxEnCanon(rows), p.want)
        NxCheck(r, "pass asks: " + p.name, FormatJson(net.log), FormatJson(p.requests))
    end for

    ' ── By hand ──
    NxCheck(r, "musicbrainz pace", NxMusicMbIntervalMs().ToStr(), "1050")
    NxCheck(r, "deezer pace", NxMusicDzIntervalMs().ToStr(), "250")
    NxCheck(r, "answers time out", NxMusicTimeoutMs().ToStr(), "15000")
    old = { useful: true, fetched: now& - 91 * 86400 }
    NxCheck(r, "a row over 90 days is asked again", FormatJson(NxMusicIsSettled(old, now&)), "false")
    NxCheck(r, "a 89-day row stands", FormatJson(NxMusicIsSettled({ useful: true, fetched: now& - 89 * 86400 }, now&)), "true")
    NxCheck(r, "a checked row stands", FormatJson(NxMusicIsSettled({ useful: false, deezerchecked: true, fetched: now& }, now&)), "true")
    NxCheck(r, "an unnamed row isn't genre-only", FormatJson(NxMusicNeedsOnlyGenres({ useful: false, deezerchecked: false })), "false")
    stops = { n: 0 }
    stopper = function() as Boolean
        m.n = m.n + 1
        return m.n > 1
    end function
    stops.shouldStop = stopper
    items = [{ ratingKey: "a", title: "A - B", artist: invalid, genres: [], year: "", librarySource: "musicVideo", type: "movie" }, { ratingKey: "b", title: "C - D", artist: invalid, genres: [], year: "", librarySource: "musicVideo", type: "movie" }]
    net = NxMusicFakeNet({})
    cache = {}
    NxMusicEnrich(net, items, cache, now&, stops)
    NxCheck(r, "told to stop: what's done stands", FormatJson(cache.Keys()), "[" + Chr(34) + "a" + Chr(34) + "]")
    print "music cases (upstream nostalgex-music-brainz.js): "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' A net that answers from canned answers by logical key, and logs the keys
' asked, as tests/gen-music.mjs's fakes do.
function NxMusicFakeNet(canned as Object) as Object
    net = { canned: canned, log: [] }
    net.ask = function(key as String) as Dynamic
        m.log.Push(key)
        if m.canned.DoesExist(key) then return m.canned[key]
        return invalid
    end function
    net.mbSearch = function(q as String) as Dynamic
        return m.ask("mb:search:" + q)
    end function
    net.mbRecording = function(id as String) as Dynamic
        return m.ask("mb:recording:" + id)
    end function
    net.dzSearch = function(q as String) as Dynamic
        return m.ask("dz:search:" + q)
    end function
    net.dzAlbum = function(id as String) as Dynamic
        return m.ask("dz:album:" + id)
    end function
    return net
end function
