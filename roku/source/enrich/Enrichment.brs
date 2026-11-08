' TMDB and OMDb enrichment: the keywords, networks, production companies,
' franchise and IMDb rating/votes the channel filter and the franchise builder
' read from `item.enrichment`, so enrichment-gated channels (TEEN MOVIES,
' MUSICALS, TRUE CRIME, SPY GAMES, FOREIGN FILMS, CULT CLASSICS, ...) fill as
' they do on the web tuner and the Apple TV app.
'
' Copyright (c) 2024 Chad Mueller / Muell Haus Inc. (Nostalgex), MIT License.
' Port copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Source: upstream scripts/nostalgex-enrichment.js (at the commit in
' data/UPSTREAM), itself a mirror of EnrichmentService.swift:
'   1. one work item per TMDB id (the first item's media type wins)
'   2. a local cache, then the shared Supabase cache (`media_enrichments`)
'   3. the misses from TMDB through upstream's relay (api/tmdb.js)
'   4. OMDb, through the same relay, for at most 50 titles per load that could
'      land on an IMDb-gated channel, none until the next UTC midnight once
'      OMDb says the day's quota is gone
'   5. what was fetched upserted back to Supabase, TMDB and OMDb columns apart
' Only TMDB and IMDb ids leave the TV: no titles, no server details.
'
' What differs, and why:
'   - The relay is asked as `X-Nostalgex-Client: roku`, at
'     https://www.nostalgex.app/api/tmdb (the apex answers with a redirect).
'     The maintainer agreed to that value; the relay has to list it.
'   - The local cache is a file in cachefs: rather than IndexedDB, and times
'     are whole seconds rather than milliseconds. TTLs are the same.
'   - The steps are two calls, NxEnrichFromCaches and NxEnrichFromRemote, so
'     the library load can build the guide between them; upstream does the
'     same through its onCacheReady callback. NxEnrichLibrary runs both.
'   - Network goes through `opts.net.fetchAll(requests, limit)`, which runs up
'     to `limit` requests at once and returns { status, body } for each, status
'     0 for a network error. OMDb lookups go out in rounds of 4, so after a
'     daily-limit answer at most the rest of that round has been asked, as
'     upstream's "at most concurrency in flight".
'   - A relay round answered 403 throughout ends the TMDB step for that load:
'     the relay doesn't take this client value, and the rest would be
'     refused too. Upstream asks for every miss regardless.
'   - Record keys are quoted in their literals: the TV stores an unquoted
'     literal key lowercase, and the records keep upstream's camelCase.
'   - Attaching a record drops the filter's per-item cache (item.nxFilter),
'     since the filter reads keywords and companies from the record.

function NxEnrichConstants() as Object
    return {
        supabaseChunk: 200, relayConcurrency: 6, cacheTtlSec: 604800, missTtlSec: 86400,
        omdbPerLoad: 50, omdbConcurrency: 4,
        tmdbColumns: ["tmdb_id", "media_type", "keywords", "networks", "production_companies", "tmdb_genres", "franchise_id", "franchise_name", "fetched_at"],
        omdbColumns: ["tmdb_id", "media_type", "imdb_id", "imdb_rating", "imdb_votes", "rt_score", "metacritic_score", "awards"],
        relayURL: "https://www.nostalgex.app/api/tmdb",
        clientHeader: "X-Nostalgex-Client", clientValue: "roku"
    }
end function

' ── Pure: shapes ────────────────────────────────────────────────────────────

function NxEnrichNames(list as Dynamic) as Object
    out = []
    for each x in NxList(list)
        if type(x) = "roAssociativeArray" then
            if NxIsString(x.name) then out.Push(x.name)
        end if
    end for
    return out
end function

function NxEnrichStringList(v as Dynamic) as Object
    out = []
    for each x in NxList(v)
        if NxIsString(x) then out.Push(x)
    end for
    return out
end function

function NxEnrichNumOrNull(v as Dynamic) as Dynamic
    if NxIsNumber(v) then return v
    return invalid
end function

' Number.isInteger, for what ParseJson gives: 12 and 12.0 are, 12.5 is not.
function NxEnrichIsInt(v as Dynamic) as Boolean
    t = type(v)
    if t = "Integer" or t = "roInt" or t = "roInteger" or t = "LongInteger" or t = "roLongInteger" then return true
    if t = "Float" or t = "roFloat" or t = "Double" or t = "roDouble" then
        if v > 2147483647 or v < -2147483648 then return false
        ' v = Int(v) would compare as integers; the difference doesn't.
        return v - Int(v) = 0
    end if
    return false
end function

' /^tt\d{7,9}$/, with JS's end of input rather than PCRE's.
function NxEnrichIsImdbID(v as Dynamic) as Boolean
    if not NxIsString(v) then return false
    return NxRx("imdbID", "^tt\d{7,9}(?![\s\S])").IsMatch(v)
end function

' An ISO-8601 UTC time as JS toISOString writes it: 2026-10-11T12:00:00.000Z.
function NxEnrichIsoTime(nowSec as LongInteger) as String
    d = CreateObject("roDateTime")
    d.FromSeconds(nowSec)
    p2 = function(n as Integer) as String
        s = n.ToStr()
        if s.Len() < 2 then s = "0" + s
        return s
    end function
    return d.GetYear().ToStr() + "-" + p2(d.GetMonth()) + "-" + p2(d.GetDayOfMonth()) + "T" + p2(d.GetHours()) + ":" + p2(d.GetMinutes()) + ":" + p2(d.GetSeconds()) + ".000Z"
end function

' TMDBService.parseResponse. Movies carry keywords under keywords.keywords, TV
' under keywords.results. Franchise comes from belongs_to_collection (movies
' only). A movie document's imdb_id stands in when no IMDb id was passed. OMDb
' fields stay null; OMDb is asked separately.
function NxParseTMDBResponse(doc as Dynamic, tmdbID as String, imdbID as Dynamic, mediaType as String, fetchedAt as String) as Object
    if type(doc) <> "roAssociativeArray" then doc = {}
    keywords = []
    if type(doc.keywords) = "roAssociativeArray" then
        if mediaType = "tv" then keywords = NxEnrichNames(doc.keywords.results) else keywords = NxEnrichNames(doc.keywords.keywords)
    end if
    franchiseID = invalid
    franchiseName = invalid
    collection = doc.belongs_to_collection
    if type(collection) = "roAssociativeArray" then
        if NxEnrichIsInt(collection.id) then franchiseID = collection.id
        if NxIsString(collection.name) then franchiseName = collection.name
    end if
    if imdbID = invalid and NxEnrichIsImdbID(doc.imdb_id) then imdbID = doc.imdb_id
    return {
        "tmdbID": tmdbID, "imdbID": imdbID, "mediaType": mediaType,
        "keywords": keywords, "networks": NxEnrichNames(doc.networks),
        "productionCompanies": NxEnrichNames(doc.production_companies), "tmdbGenres": NxEnrichNames(doc.genres),
        "imdbRating": invalid, "imdbVotes": invalid, "rottenTomatoesScore": invalid, "metacriticScore": invalid, "awards": invalid,
        "franchiseID": franchiseID, "franchiseName": franchiseName, "fetchedAt": fetchedAt
    }
end function

' A Supabase row -> the attached record. Mirrors MediaEnrichment's resilient
' decoder. invalid for a row without an id or media type.
function NxEnrichFromSupabaseRow(row as Dynamic, nowSec as LongInteger) as Dynamic
    if type(row) <> "roAssociativeArray" then return invalid
    if row.tmdb_id = invalid or not NxIsString(row.media_type) then return invalid
    imdbID = invalid
    if NxIsString(row.imdb_id) then imdbID = row.imdb_id
    awards = invalid
    if NxIsString(row.awards) then awards = row.awards
    franchiseName = invalid
    if NxIsString(row.franchise_name) then franchiseName = row.franchise_name
    fetchedAt = row.fetched_at
    if not NxIsString(fetchedAt) then fetchedAt = NxEnrichIsoTime(nowSec)
    return {
        "tmdbID": NxToStr(row.tmdb_id), "imdbID": imdbID, "mediaType": row.media_type,
        "keywords": NxEnrichStringList(row.keywords), "networks": NxEnrichStringList(row.networks),
        "productionCompanies": NxEnrichStringList(row.production_companies), "tmdbGenres": NxEnrichStringList(row.tmdb_genres),
        "imdbRating": NxEnrichNumOrNull(row.imdb_rating), "imdbVotes": NxEnrichNumOrNull(row.imdb_votes),
        "rottenTomatoesScore": NxEnrichNumOrNull(row.rt_score), "metacriticScore": NxEnrichNumOrNull(row.metacritic_score),
        "awards": awards, "franchiseID": NxEnrichNumOrNull(row.franchise_id), "franchiseName": franchiseName,
        "fetchedAt": fetchedAt
    }
end function

' The TMDB upsert body for one record: the TMDB columns only, so it never
' touches OMDb values an Apple TV wrote.
function NxEnrichToSupabaseRow(e as Object) as Object
    return {
        tmdb_id: e.tmdbID, media_type: e.mediaType, keywords: e.keywords, networks: e.networks,
        production_companies: e.productionCompanies, tmdb_genres: e.tmdbGenres,
        franchise_id: e.franchiseID, franchise_name: e.franchiseName, fetched_at: e.fetchedAt
    }
end function

' The OMDb upsert body: the OMDb columns plus the key.
function NxEnrichToOMDbRow(e as Object) as Object
    return {
        tmdb_id: e.tmdbID, media_type: e.mediaType, imdb_id: e.imdbID, imdb_rating: e.imdbRating,
        imdb_votes: e.imdbVotes, rt_score: e.rottenTomatoesScore, metacritic_score: e.metacriticScore,
        awards: e.awards
    }
end function

' ── Pure: JS number parsing ─────────────────────────────────────────────────

function NxEnrichIsSpace(c as String) as Boolean
    return c = " " or c = Chr(9) or c = Chr(10) or c = Chr(11) or c = Chr(12) or c = Chr(13) or c = Chr(160) or c = Chr(65279) or c = Chr(8232) or c = Chr(8233)
end function

function NxEnrichTrim(s as String) as String
    a = 1
    b = s.Len()
    while a <= b and NxEnrichIsSpace(Mid(s, a, 1))
        a = a + 1
    end while
    while b >= a and NxEnrichIsSpace(Mid(s, b, 1))
        b = b - 1
    end while
    return Mid(s, a, b - a + 1)
end function

function NxEnrichPow10(e as Integer) as Double
    p# = 1
    for i = 1 to e
        p# = p# * 10
    end for
    return p#
end function

' JS Number(s) for a string: invalid for NaN and for +/-Infinity, which the
' callers treat alike (Number.isFinite). "" and blanks are 0, as in JS.
function NxEnrichJsNumber(s as String) as Dynamic
    t = NxEnrichTrim(s)
    if t = "" then return 0
    lower = LCase(t)
    if Left(lower, 2) = "0x" or Left(lower, 2) = "0o" or Left(lower, 2) = "0b" then
        base = 16
        if Mid(lower, 2, 1) = "o" then base = 8
        if Mid(lower, 2, 1) = "b" then base = 2
        digits = Mid(lower, 3)
        if digits = "" then return invalid
        v# = 0
        for i = 1 to digits.Len()
            d = Instr(1, "0123456789abcdef", Mid(digits, i, 1)) - 1
            if d < 0 or d >= base then return invalid
            v# = v# * base + d
        end for
        return v#
    end if
    rx = NxRx("jsNumber", "^([+-]?)(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?(?![\s\S])")
    parts = rx.Match(t)
    if parts.Count() = 0 then return invalid
    intPart = parts[2]
    frac = ""
    if parts.Count() > 3 then frac = parts[3]
    if intPart = "" and frac = "" then return invalid
    expo = 0
    if parts.Count() > 4 and parts[4] <> "" then
        es = parts[4]
        sign = 1
        if Left(es, 1) = "+" or Left(es, 1) = "-" then
            if Left(es, 1) = "-" then sign = -1
            es = Mid(es, 2)
        end if
        ' Anything past 400 is out of range either way.
        if es.Len() > 4 then es = "9999"
        expo = sign * es.ToInt()
    end if
    digits = intPart + frac
    while digits.Len() > 1 and Left(digits, 1) = "0"
        digits = Mid(digits, 2)
    end while
    expo = expo - frac.Len()
    mant# = 0
    for i = 1 to digits.Len()
        mant# = mant# * 10 + (Asc(Mid(digits, i, 1)) - 48)
    end for
    if mant# = 0 then return 0
    if digits.Len() + expo > 309 then return invalid
    if digits.Len() + expo < -324 then return 0
    if expo >= 0 then
        if expo > 290 then
            v# = mant# * NxEnrichPow10(290) * NxEnrichPow10(expo - 290)
        else
            v# = mant# * NxEnrichPow10(expo)
        end if
    else
        if -expo > 290 then
            v# = mant# / NxEnrichPow10(290) / NxEnrichPow10(-expo - 290)
        else
            v# = mant# / NxEnrichPow10(-expo)
        end if
    end if
    if parts[1] = "-" then v# = -v#
    return v#
end function

' JS parseInt(s, 10): leading blanks, a sign, then as many digits as there are.
function NxEnrichJsParseInt(s as String) as Dynamic
    t = NxEnrichTrim(s)
    m2 = NxRx("jsParseInt", "^([+-]?)(\d+)").Match(t)
    if m2.Count() = 0 then return invalid
    v# = 0
    for i = 1 to m2[2].Len()
        v# = v# * 10 + (Asc(Mid(m2[2], i, 1)) - 48)
    end for
    if m2[1] = "-" then v# = -v#
    if v# <= 2147483647 and v# >= -2147483648 then return Int(v#)
    return v#
end function

' Whole numbers as Integer where they fit, so they read like JSON integers.
function NxEnrichTidy(v as Dynamic) as Dynamic
    if v = invalid then return invalid
    if v <= 2147483647 and v >= -2147483648 then
        if v - Int(v) = 0 then return Int(v)
    end if
    return v
end function

' ── Pure: OMDb ──────────────────────────────────────────────────────────────

function NxEnrichOMDbValue(v as Dynamic) as Dynamic
    if NxIsString(v) and v <> "N/A" then return v
    return invalid
end function

' OMDBService.parseResponse. invalid for {"Response":"False"} (an unknown id,
' or the daily-limit error when it arrives without the relay's 429).
function NxParseOMDbResponse(doc as Dynamic) as Dynamic
    if type(doc) <> "roAssociativeArray" then return invalid
    if NxIsString(doc.Response) then
        if doc.Response = "False" then return invalid
    end if
    rating = NxEnrichOMDbValue(doc.imdbRating)
    votes = NxEnrichOMDbValue(doc.imdbVotes)
    meta = NxEnrichOMDbValue(doc.Metascore)
    rt = invalid
    for each r in NxList(doc.Ratings)
        if type(r) = "roAssociativeArray" then
            if NxIsString(r.Source) and NxIsString(r.Value) then
                if r.Source = "Rotten Tomatoes" then
                    ' String.replace('%', ''): the first one only.
                    v = r.Value
                    at = Instr(1, v, "%")
                    if at > 0 then v = Left(v, at - 1) + Mid(v, at + 1)
                    rt = NxEnrichJsParseInt(v)
                    exit for
                end if
            end if
        end if
    end for
    if rating <> invalid then rating = NxEnrichTidy(NxEnrichJsNumber(rating))
    if votes <> invalid then votes = NxEnrichTidy(NxEnrichJsNumber(NxRx("comma", ",").ReplaceAll(votes, "")))
    if meta <> invalid then meta = NxEnrichTidy(NxEnrichJsNumber(meta))
    return { "imdbRating": rating, "imdbVotes": votes, "rottenTomatoesScore": rt, "metacriticScore": meta, "awards": NxEnrichOMDbValue(doc.Awards) }
end function

function NxEnrichIsOMDbLimit(doc as Dynamic) as Boolean
    if type(doc) <> "roAssociativeArray" then return false
    if not NxIsString(doc.Error) then return false
    return Instr(1, LCase(doc.Error), "limit reached") > 0
end function

' MediaEnrichment.merging(omdb:).
function NxEnrichMergeOMDb(record as Object, omdb as Object, imdbID as Dynamic) as Object
    out = {}
    out.Append(record)
    if out.imdbID = invalid then out["imdbID"] = imdbID
    out.Append(omdb)
    return out
end function

function NxEnrichNeedsOMDb(rules as Dynamic) as Boolean
    if type(rules) <> "roAssociativeArray" then return false
    if NxIsNumber(rules.imdbRatingMin) or NxIsNumber(rules.imdbVotesMin) or NxIsNumber(rules.rtScoreMin) or NxIsNumber(rules.metacriticMin) then return true
    if type(rules.wonOscar) = "Boolean" or type(rules.wonOscar) = "roBoolean" then return rules.wonOscar
    return false
end function

' OMDBGate.gates(from:): one gate per channel with an OMDb rule.
' { mediaType, keywords (in order), keywordSet, genres }.
function NxEnrichOMDbGates(channels as Dynamic) as Object
    out = []
    for each ch in NxList(channels)
        r = invalid
        if type(ch) = "roAssociativeArray" then r = ch.rules
        if NxEnrichNeedsOMDb(r) then
            mediaType = invalid
            if NxIsString(r.type) then
                if r.type = "movie" then mediaType = "movie"
                if r.type = "episode" then mediaType = "tv"
            end if
            keywords = []
            keywordSet = {}
            keywordSet.SetModeCaseSensitive()
            words = []
            words.Append(NxList(r.keywords))
            words.Append(NxList(r.keywordsRequireAll))
            for each k in words
                if NxIsString(k) then
                    lk = LCase(k)
                    if not keywordSet.DoesExist(lk) then
                        keywordSet[lk] = true
                        keywords.Push(lk)
                    end if
                end if
            end for
            genres = []
            if type(r.genres) = "roAssociativeArray" then
                for each g in NxList(r.genres.include)
                    if NxIsString(g) then genres.Push(LCase(g))
                end for
            end if
            out.Push({ mediaType: mediaType, keywords: keywords, keywordSet: keywordSet, genres: genres })
        end if
    end for
    return out
end function

' OMDBQuota.isCandidate: some gate admits the media type plus a keyword or genre.
function NxEnrichIsOMDbCandidate(mediaType as Dynamic, keywords as Dynamic, genres as Dynamic, gates as Object) as Boolean
    kw = []
    for each k in NxList(keywords)
        kw.Push(LCase(NxToStr(k)))
    end for
    gs = []
    for each g in NxList(genres)
        gs.Push(LCase(NxToStr(g)))
    end for
    for each gate in gates
        admits = gate.mediaType = invalid
        if not admits and NxIsString(mediaType) then admits = gate.mediaType = mediaType
        if admits then
            if gate.keywords.Count() = 0 and gate.genres.Count() = 0 then return true
            for each k in kw
                if gate.keywordSet.DoesExist(k) then return true
            end for
            for each g in gate.genres
                for each x in gs
                    if Instr(1, x, g) > 0 then return true
                end for
            end for
        end if
    end for
    return false
end function

' Server genres per TMDB id, merged across the id's items, in first-seen order.
function NxEnrichGenresByTMDB(items as Object) as Object
    out = {}
    for each item in items
        if type(item) = "roAssociativeArray" then
            if item.tmdbID <> invalid then
                id = NxToStr(item.tmdbID)
                entry = out[id]
                if entry = invalid then
                    entry = { list: [], seen: {} }
                    entry.seen.SetModeCaseSensitive()
                    out[id] = entry
                end if
                for each g in NxList(item.genres)
                    key = NxToStr(g)
                    if not entry.seen.DoesExist(key) then
                        entry.seen[key] = true
                        entry.list.Push(g)
                    end if
                end for
            end if
        end if
    end for
    return out
end function

' EnrichmentService.omdbCandidates: an unrated record with a valid IMDb id
' that some gate admits. Returns [{ tmdbID, imdbID, record }].
function NxEnrichOMDbCandidates(work as Object, records as Object, genresByID as Object, gates as Object) as Object
    out = []
    if gates.Count() = 0 then return out
    for each w in work
        e = records[w.tmdbID]
        if e <> invalid then
            if e.imdbRating = invalid and NxEnrichIsImdbID(e.imdbID) then
                genres = []
                genres.Append(NxList(e.tmdbGenres))
                byID = genresByID[w.tmdbID]
                if byID <> invalid then genres.Append(byID.list)
                if NxEnrichIsOMDbCandidate(e.mediaType, e.keywords, genres, gates) then
                    out.Push({ tmdbID: w.tmdbID, imdbID: e.imdbID, record: e })
                end if
            end if
        end if
    end for
    return out
end function

' OMDBQuota.pick: at most `limit`, in random order (Fisher-Yates on a copy).
' `rng` is an AA whose draw() returns a number in [0, 1).
function NxEnrichPickOMDb(list as Object, limit as Integer, rng as Object) as Object
    a = []
    a.Append(list)
    for i = a.Count() - 1 to 1 step -1
        j = Int(rng.draw() * (i + 1))
        ' draw() is a Float: within 2^-24 of 1, times a big i + 1, it rounds up to i + 1.
        if j > i then j = i
        tmp = a[i]
        a[i] = a[j]
        a[j] = tmp
    end for
    out = []
    for i = 0 to a.Count() - 1
        if i >= limit then exit for
        out.Push(a[i])
    end for
    return out
end function

function NxEnrichRandom() as Object
    return { draw: function() as Float
        return Rnd(0)
    end function }
end function

' OMDb's daily quota resets at midnight UTC.
function NxEnrichNextUTCMidnight(nowSec as LongInteger) as LongInteger
    day& = nowSec \ 86400
    if nowSec < 0 and day& * 86400 <> nowSec then day& = day& - 1
    return (day& + 1) * 86400
end function

' OMDBBackoff: after a daily-limit answer, no OMDb lookups until the next UTC
' midnight. `store` is an AA with read() and write(seconds as String), or
' invalid for memory only; a store that fails falls back to memory.
function NxEnrichOMDbBackoff(store as Dynamic) as Object
    return {
        store: store, memory: 0&,
        blockedUntil: function() as LongInteger
            if m.store = invalid then return m.memory
            v = m.store.read()
            if NxIsString(v) and v <> "" then
                n& = v.ToInt()
                if n& > m.memory then return n&
            end if
            return m.memory
        end function,
        isBlocked: function(nowSec as LongInteger) as Boolean
            return nowSec < m.blockedUntil()
        end function,
        mark: sub(nowSec as LongInteger)
            m.memory = NxEnrichNextUTCMidnight(nowSec)
            if m.store <> invalid then m.store.write(m.memory.ToStr())
        end sub
    }
end function

' One work item per TMDB id. Episodes are tv, everything else movie. First
' item wins. Ids that aren't 1 to 10 digits never leave the TV.
function NxEnrichWorkItems(items as Object) as Object
    out = []
    seen = {}
    for each item in items
        if type(item) = "roAssociativeArray" then
            if item.tmdbID <> invalid then
                id = NxToStr(item.tmdbID)
                if NxRx("tmdbID", "^\d{1,10}(?![\s\S])").IsMatch(id) and not seen.DoesExist(id) then
                    seen[id] = true
                    mediaType = "movie"
                    if NxIsString(item.type) then
                        if item.type = "episode" then mediaType = "tv"
                    end if
                    out.Push({ "tmdbID": id, "mediaType": mediaType })
                end if
            end if
        end if
    end for
    return out
end function

function NxEnrichChunk(list as Object, size as Integer) as Object
    out = []
    part = []
    for each x in list
        part.Push(x)
        if part.Count() = size then
            out.Push(part)
            part = []
        end if
    end for
    if part.Count() > 0 then out.Push(part)
    return out
end function

' Sets item.enrichment on every item whose TMDB id has a record, and drops
' the filter's cached view of it. Returns how many.
function NxEnrichAttach(items as Object, records as Object) as Integer
    n = 0
    for each item in items
        if type(item) = "roAssociativeArray" then
            if item.tmdbID <> invalid then
                e = records[NxToStr(item.tmdbID)]
                if e <> invalid then
                    item.enrichment = e
                    NxFilterForget(item)
                    n = n + 1
                end if
            end if
        end if
    end for
    return n
end function

' ── Network ─────────────────────────────────────────────────────────────────

function NxEnrichSupabaseHeaders(anonKey as String) as Object
    return { "apikey": anonKey, "Authorization": "Bearer " + anonKey, "Content-Type": "application/json" }
end function

function NxEnrichParseBody(body as Dynamic) as Dynamic
    if not NxIsString(body) or body = "" then return invalid
    return ParseJson(body)
end function

' SupabaseService.fetchEnrichments, in chunks of 200. A failed chunk is
' skipped, not fatal.
function NxEnrichReadSupabase(ids as Object, cfg as Object, net as Object, nowSec as LongInteger, progress as Dynamic) as Object
    out = []
    size = NxEnrichConstants().supabaseChunk
    if cfg.chunkSize <> invalid then size = cfg.chunkSize
    chunks = NxEnrichChunk(ids, size)
    for i = 0 to chunks.Count() - 1
        res = net.fetchAll([{
            method: "GET",
            url: cfg.supabaseURL + "/rest/v1/media_enrichments?tmdb_id=in.(" + chunks[i].Join(",") + ")&select=*",
            headers: NxEnrichSupabaseHeaders(cfg.anonKey)
        }], 1)[0]
        if res.status <> 200 then
            print "enrichment: Supabase read failed: HTTP "; res.status
        else
            for each row in NxList(NxEnrichParseBody(res.body))
                e = NxEnrichFromSupabaseRow(row, nowSec)
                if e <> invalid then out.Push(e)
            end for
        end if
        if progress <> invalid then progress.report(i + 1, chunks.Count(), "cache")
    end for
    return out
end function

' SupabaseService.upsertEnrichments: chunks of 200, merge-duplicates.
' `omdb` picks the OMDb columns; otherwise the TMDB ones.
function NxEnrichUpsertSupabase(records as Object, cfg as Object, net as Object, omdb as Boolean) as Integer
    k = NxEnrichConstants()
    columns = k.tmdbColumns
    if omdb then columns = k.omdbColumns
    size = k.supabaseChunk
    if cfg.chunkSize <> invalid then size = cfg.chunkSize
    headers = NxEnrichSupabaseHeaders(cfg.anonKey)
    headers["Prefer"] = "resolution=merge-duplicates,return=minimal"
    written = 0
    for each part in NxEnrichChunk(records, size)
        rows = []
        for each e in part
            if omdb then rows.Push(NxEnrichToOMDbRow(e)) else rows.Push(NxEnrichToSupabaseRow(e))
        end for
        res = net.fetchAll([{
            method: "POST",
            url: cfg.supabaseURL + "/rest/v1/media_enrichments?columns=" + columns.Join(","),
            headers: headers, body: FormatJson(rows)
        }], 1)[0]
        if res.status < 200 or res.status >= 300 then
            print "enrichment: Supabase upsert failed: HTTP "; res.status
        else
            written = written + part.Count()
        end if
    end for
    return written
end function

function NxEnrichRelayHeaders(cfg as Object) as Object
    k = NxEnrichConstants()
    h = { "Accept": "application/json" }
    value = k.clientValue
    if NxIsString(cfg.clientValue) and cfg.clientValue <> "" then value = cfg.clientValue
    h[k.clientHeader] = value
    return h
end function

' The request for one TMDB document through the relay.
function NxEnrichRelayRequest(w as Object, cfg as Object) as Object
    kind = "movie"
    if w.mediaType = "tv" then kind = "tv"
    return { method: "GET", url: cfg.relayURL + "?path=" + kind + "/" + w.tmdbID, headers: NxEnrichRelayHeaders(cfg) }
end function

' The request for one OMDb answer through the relay; invalid for an id that
' isn't an IMDb id, which is never sent.
function NxEnrichOMDbRequest(imdbID as Dynamic, cfg as Object) as Dynamic
    if not NxEnrichIsImdbID(imdbID) then return invalid
    return { method: "GET", url: cfg.relayURL + "?path=omdb/" + imdbID, headers: NxEnrichRelayHeaders(cfg) }
end function

' ── Local cache ─────────────────────────────────────────────────────────────
' Rows: { tmdbID, savedAt (seconds), record or invalid }. An invalid record is
' a TMDB 404, kept for a day so a title TMDB doesn't know isn't asked for on
' every load.

function NxEnrichMemoryCache() as Object
    return {
        rows: {},
        getMany: function(ids as Object) as Object
            out = {}
            for each id in ids
                if m.rows.DoesExist(id) then out[id] = m.rows[id]
            end for
            return out
        end function,
        putMany: sub(rows as Object)
            for each r in rows
                m.rows[r.tmdbID] = r
            end for
        end sub
    }
end function

' The same, kept in one JSON file (cachefs: survives a relaunch until the OS
' needs the space).
function NxEnrichFileCache(path as String) as Object
    c = NxEnrichMemoryCache()
    c.path = path
    c.loaded = false
    c.memGet = c.getMany
    c.memPut = c.putMany
    c.load = sub()
        if m.loaded then return
        m.loaded = true
        ' The OS may have cleared it; reading a missing file logs an error.
        raw = ""
        if CreateObject("roFileSystem").Exists(m.path) then raw = ReadAsciiFile(m.path)
        if raw <> "" then
            saved = ParseJson(raw)
            if type(saved) = "roAssociativeArray" then m.rows = saved
        end if
    end sub
    c.getMany = function(ids as Object) as Object
        m.load()
        return m.memGet(ids)
    end function
    c.putMany = sub(rows as Object)
        m.load()
        m.memPut(rows)
        WriteAsciiFile(m.path, FormatJson(m.rows))
    end sub
    return c
end function

' ── Config ──────────────────────────────────────────────────────────────────

' pkg:/data/enrichment.json, which scripts/deploy.sh writes only when .env
' turns enrichment on: { supabaseURL, anonKey }, optionally relayURL and
' clientValue. No file means no enrichment.
function NxEnrichmentConfig(path = "pkg:/data/enrichment.json" as String) as Object
    k = NxEnrichConstants()
    cfg = { supabaseURL: "", anonKey: "", relayURL: k.relayURL, clientValue: k.clientValue }
    raw = ReadAsciiFile(path)
    if raw = "" then
        cfg.relayURL = ""
        return cfg
    end if
    saved = ParseJson(raw)
    if type(saved) <> "roAssociativeArray" then
        cfg.relayURL = ""
        return cfg
    end if
    if NxIsString(saved.supabaseURL) then
        url = saved.supabaseURL
        while Right(url, 1) = "/"
            url = Left(url, url.Len() - 1)
        end while
        cfg.supabaseURL = url
    end if
    if NxIsString(saved.anonKey) then cfg.anonKey = saved.anonKey
    if NxIsString(saved.relayURL) and saved.relayURL <> "" then cfg.relayURL = saved.relayURL
    if NxIsString(saved.clientValue) and saved.clientValue <> "" then cfg.clientValue = saved.clientValue
    return cfg
end function

function NxEnrichMissingConfiguration(cfg as Object) as Object
    missing = []
    if not NxTruthy(cfg.relayURL) then missing.Push("tmdb relay")
    if not NxTruthy(cfg.supabaseURL) then missing.Push("supabase url")
    if not NxTruthy(cfg.anonKey) then missing.Push("anon key")
    return missing
end function

' ── Orchestration ───────────────────────────────────────────────────────────
' opts: { config, net, cache, nowSec, channels (for the OMDb gates; none means
'         no OMDb lookups), backoff, omdbLimit, rng, progress (an AA with
'         report(done, total, phase)) }

function NxEnrichNewState() as Object
    records = {}
    return {
        records: records,
        stats: { ids: 0, local: 0, supabase: 0, fetched: 0, misses: 0, failed: 0, upserted: 0 },
        omdb: { gates: 0, candidates: 0, asked: 0, fetched: 0, misses: 0, failed: 0, limited: false, paused: false, upserted: 0 },
        skipped: false, work: [], needRemote: []
    }
end function

' Steps 1 and 2: the local cache, then Supabase for what it lacked. Attaches
' what they found. The guide can be built from this before any relay fetch.
function NxEnrichFromCaches(items as Object, opts as Object) as Object
    state = NxEnrichNewState()
    cfg = opts.config
    missing = NxEnrichMissingConfiguration(cfg)
    if missing.Count() > 0 then
        print "enrichment: off, missing "; missing.Join(", ")
        state.skipped = true
        return state
    end if
    k = NxEnrichConstants()
    nowSec& = opts.nowSec
    state.work = NxEnrichWorkItems(items)
    state.stats.ids = state.work.Count()
    if state.work.Count() = 0 then return state

    ids = []
    for each w in state.work
        ids.Push(w.tmdbID)
    end for
    localRows = opts.cache.getMany(ids)
    for each w in state.work
        row = localRows[w.tmdbID]
        fresh = false
        if row <> invalid then
            ttl = k.missTtlSec
            if row.record <> invalid then ttl = k.cacheTtlSec
            fresh = NxIsNumber(row.savedAt) and nowSec& - row.savedAt < ttl
        end if
        if fresh then
            if row.record <> invalid then
                state.records[w.tmdbID] = row.record
                state.stats.local = state.stats.local + 1
            else
                state.stats.misses = state.stats.misses + 1
            end if
        else
            state.needRemote.Push(w)
        end if
    end for

    toStore = []
    if state.needRemote.Count() > 0 then
        if opts.progress <> invalid then opts.progress.report(0, state.needRemote.Count(), "cache")
        remoteIDs = []
        for each w in state.needRemote
            remoteIDs.Push(w.tmdbID)
        end for
        for each e in NxEnrichReadSupabase(remoteIDs, cfg, opts.net, nowSec&, opts.progress)
            if not state.records.DoesExist(e.tmdbID) then
                state.records[e.tmdbID] = e
                toStore.Push({ tmdbID: e.tmdbID, savedAt: nowSec&, record: e })
                state.stats.supabase = state.stats.supabase + 1
            end if
        end for
    end if
    if toStore.Count() > 0 then opts.cache.putMany(toStore)
    NxEnrichAttach(items, state.records)
    return state
end function

' Whether NxEnrichFromRemote has anything to ask: relay misses, or OMDb gates.
function NxEnrichHasRemoteWork(state as Object, opts as Object) as Boolean
    if state.skipped or state.work.Count() = 0 then return false
    for each w in state.needRemote
        if not state.records.DoesExist(w.tmdbID) then return true
    end for
    return NxEnrichOMDbGates(opts.channels).Count() > 0
end function

' Steps 3 to 5: the relay for whatever neither cache had, OMDb for titles
' that could land on an IMDb-gated channel, then saving what was fetched,
' locally and to the shared cache. Attaches everything. Returns how many
' records it added or changed.
function NxEnrichFromRemote(state as Object, items as Object, opts as Object) as Integer
    if state.skipped or state.work.Count() = 0 then return 0
    k = NxEnrichConstants()
    cfg = opts.config
    nowSec& = opts.nowSec
    fetchedAt = NxEnrichIsoTime(nowSec&)

    toFetch = []
    for each w in state.needRemote
        if not state.records.DoesExist(w.tmdbID) then toFetch.Push(w)
    end for
    fresh = []
    freshStore = []
    if toFetch.Count() > 0 then
        if opts.progress <> invalid then opts.progress.report(0, toFetch.Count(), "fetch")
        done = 0
        ' Rounds of 60 keep progress moving; inside a round, 6 at a time.
        for each round in NxEnrichChunk(toFetch, k.relayConcurrency * 10)
            requests = []
            for each w in round
                requests.Push(NxEnrichRelayRequest(w, cfg))
            end for
            results = opts.net.fetchAll(requests, k.relayConcurrency)
            refused = 0
            for i = 0 to round.Count() - 1
                w = round[i]
                res = results[i]
                if res.status = 200 then
                    e = NxParseTMDBResponse(NxEnrichParseBody(res.body), w.tmdbID, invalid, w.mediaType, fetchedAt)
                    state.records[w.tmdbID] = e
                    fresh.Push(e)
                    freshStore.Push({ tmdbID: w.tmdbID, savedAt: nowSec&, record: e })
                    state.stats.fetched = state.stats.fetched + 1
                else if res.status = 404 then
                    freshStore.Push({ tmdbID: w.tmdbID, savedAt: nowSec&, record: invalid })
                    state.stats.misses = state.stats.misses + 1
                else
                    state.stats.failed = state.stats.failed + 1
                    if res.status = 403 then refused = refused + 1
                end if
            end for
            done = done + round.Count()
            if opts.progress <> invalid then opts.progress.report(done, toFetch.Count(), "fetch")
            ' Port: a round the relay refused outright means it doesn't take this
            ' client value; asking for the rest would only be refused too.
            if refused = round.Count() then
                print "enrichment: the relay refused this client; no more TMDB requests this load"
                state.stats.failed = state.stats.failed + toFetch.Count() - done
                exit for
            end if
        end for
    end if

    omdbFresh = []
    gates = NxEnrichOMDbGates(opts.channels)
    state.omdb.gates = gates.Count()
    if gates.Count() > 0 then
        backoff = opts.backoff
        if backoff = invalid then backoff = NxEnrichOMDbBackoff(invalid)
        if backoff.isBlocked(nowSec&) then
            state.omdb.paused = true
        else
            candidates = NxEnrichOMDbCandidates(state.work, state.records, NxEnrichGenresByTMDB(items), gates)
            state.omdb.candidates = candidates.Count()
            limit = k.omdbPerLoad
            if opts.omdbLimit <> invalid then limit = opts.omdbLimit
            rng = opts.rng
            if rng = invalid then rng = NxEnrichRandom()
            picked = NxEnrichPickOMDb(candidates, limit, rng)
            halted = false
            for each round in NxEnrichChunk(picked, k.omdbConcurrency)
                if halted then exit for
                requests = []
                asked = []
                for each c in round
                    req = NxEnrichOMDbRequest(c.imdbID, cfg)
                    if req <> invalid then
                        requests.Push(req)
                        asked.Push(c)
                    else
                        state.omdb.failed = state.omdb.failed + 1
                    end if
                end for
                state.omdb.asked = state.omdb.asked + requests.Count()
                results = []
                if requests.Count() > 0 then results = opts.net.fetchAll(requests, k.omdbConcurrency)
                for i = 0 to asked.Count() - 1
                    c = asked[i]
                    res = results[i]
                    doc = NxEnrichParseBody(res.body)
                    if res.status = 429 or NxEnrichIsOMDbLimit(doc) then
                        if not state.omdb.limited then backoff.mark(nowSec&)
                        halted = true
                        state.omdb.limited = true
                    else if res.status <> 200 then
                        state.omdb.failed = state.omdb.failed + 1
                        ' Bad key or relay down: stop for this load, as the app does.
                        if res.status = 401 or res.status = 403 or res.status >= 500 then halted = true
                    else
                        parsed = NxParseOMDbResponse(doc)
                        if parsed = invalid then
                            state.omdb.misses = state.omdb.misses + 1
                        else
                            merged = NxEnrichMergeOMDb(c.record, parsed, c.imdbID)
                            state.records[c.tmdbID] = merged
                            omdbFresh.Push(merged)
                            freshStore.Push({ tmdbID: c.tmdbID, savedAt: nowSec&, record: merged })
                            state.omdb.fetched = state.omdb.fetched + 1
                        end if
                    end if
                end for
            end for
        end if
    end if

    if freshStore.Count() > 0 then opts.cache.putMany(freshStore)
    if fresh.Count() > 0 then state.stats.upserted = NxEnrichUpsertSupabase(fresh, cfg, opts.net, false)
    if omdbFresh.Count() > 0 then state.omdb.upserted = NxEnrichUpsertSupabase(omdbFresh, cfg, opts.net, true)
    NxEnrichAttach(items, state.records)
    s = state.stats
    print "enrichment: "; s.ids; " TMDB ids: "; s.local; " local, "; s.supabase; " Supabase, "; s.fetched; " fetched, "; s.misses; " not on TMDB, "; s.failed; " failed, "; s.upserted; " saved"
    o = state.omdb
    if o.gates > 0 then
        if o.paused then
            print "enrichment: OMDb paused until UTC midnight (daily limit)"
        else
            print "enrichment: OMDb: "; o.gates; " gated channels, "; o.candidates; " candidates, "; o.asked; " asked, "; o.fetched; " found, "; o.misses; " unknown, "; o.failed; " failed, "; o.upserted; " saved"
        end if
    end if
    return s.fetched + o.fetched
end function

' Both steps, as upstream's enrichLibrary: opts.onCacheReady, an AA with
' run(records), is called between them when the caches found anything.
function NxEnrichLibrary(items as Object, opts as Object) as Object
    state = NxEnrichFromCaches(items, opts)
    if state.skipped then return state
    if state.records.Count() > 0 and opts.onCacheReady <> invalid then opts.onCacheReady.run(state.records)
    NxEnrichFromRemote(state, items, opts)
    return state
end function
