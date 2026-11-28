' Runs source/enrich/Enrichment.brs over vectors from upstream's own
' scripts/nostalgex-enrichment.js (tests/gen-enrichment.mjs), then over cases
' transcribed from upstream's scripts/nostalgex-enrichment-smoke.mjs (at the
' commit in data/UPSTREAM), with a stub network so nothing leaves the
' machine. Smoke cases about the web page alone (meta tags, IndexedDB) aren't
' here. Returns the failure count.

function NxRunEnrichmentTests(vectorsPath as String) as Integer
    v = ParseJson(ReadAsciiFile(vectorsPath))
    if v = invalid then
        print "FAIL cannot read "; vectorsPath
        return 1
    end if
    r = { pass: 0, fail: 0 }
    nowSec& = v.nowSec
    k = NxEnrichConstants()

    ' ── Vectors ──
    c = v.constants
    NxCheck(r, "constants", FormatJson([k.supabaseChunk, k.relayConcurrency, k.cacheTtlSec, k.missTtlSec, k.omdbPerLoad, k.omdbConcurrency, k.tmdbColumns.Join(","), k.omdbColumns.Join(",")]), FormatJson([c.supabaseChunk, c.relayConcurrency, c.cacheTtlSec, c.missTtlSec, c.omdbPerLoad, c.omdbConcurrency, c.tmdbColumns, c.omdbColumns]))
    NxCheck(r, "fetchedAt format", NxEnrichIsoTime(nowSec&), v.fetchedAt)
    for i = 0 to v.tmdb.Count() - 1
        t = v.tmdb[i]
        got = NxParseTMDBResponse(ParseJson(t.doc), t.tmdbID, t.imdbID, t.mediaType, v.fetchedAt)
        NxCheck(r, "tmdb " + i.ToStr() + " " + Left(t.doc, 40), NxEnCanon(got), t.want)
    end for
    for i = 0 to v.omdb.Count() - 1
        t = v.omdb[i]
        doc = ParseJson(t.doc)
        NxCheck(r, "omdb " + i.ToStr() + " " + Left(t.doc, 40), NxEnCanon(NxParseOMDbResponse(doc)), t.want)
        NxCheck(r, "omdb limit " + i.ToStr(), NxEnBool(NxEnrichIsOMDbLimit(doc)), NxEnBool(t.limit))
    end for
    for i = 0 to v.rows.Count() - 1
        t = v.rows[i]
        e = NxEnrichFromSupabaseRow(ParseJson(t.row), nowSec&)
        NxCheck(r, "row " + i.ToStr(), NxEnCanon(e), t.want)
        tmdbRow = "null"
        omdbRow = "null"
        if e <> invalid then
            tmdbRow = NxEnCanon(NxEnrichToSupabaseRow(e))
            omdbRow = NxEnCanon(NxEnrichToOMDbRow(e))
        end if
        NxCheck(r, "row " + i.ToStr() + " TMDB upsert", tmdbRow, t.tmdbRow)
        NxCheck(r, "row " + i.ToStr() + " OMDb upsert", omdbRow, t.omdbRow)
    end for
    for i = 0 to v.work.Count() - 1
        NxCheck(r, "workItems " + i.ToStr(), NxEnCanon(NxEnrichWorkItems(ParseJson(v.work[i].items))), v.work[i].want)
    end for
    config = ParseJson(ReadAsciiFile("pkg:/data/channels.json"))
    gates = NxEnrichOMDbGates(config.channels)
    shown = []
    for each g in gates
        shown.Push({ "mediaType": g.mediaType, "keywords": g.keywords, "genres": g.genres })
    end for
    NxCheck(r, "gates from channels.json", NxEnCanon(shown), v.gates)
    for i = 0 to v.candidates.Count() - 1
        t = v.candidates[i]
        NxCheck(r, "candidate " + i.ToStr() + " " + FormatJson(t.keywords) + FormatJson(t.genres), NxEnBool(NxEnrichIsOMDbCandidate(t.mediaType, t.keywords, t.genres, gates)), NxEnBool(t.want))
    end for
    for each t in v.midnights
        NxCheck(r, "next UTC midnight " + NxToStr(t.nowSec), NxEnrichNextUTCMidnight(t.nowSec).ToStr(), NxToStr(t.want))
    end for

    ' ── Transcribed: the attached record is what the filter reads ──
    clock = NxFilterClock(1760000000)
    excl = NxFilterExclusiveRules([])
    spyGames = NxFilterChannel({ id: 219, rules: { type: "movie", keywords: ["spy", "espionage"], keywordsRequireAnyGenre: ["Action", "Thriller"] } })
    foreign = NxFilterChannel({ id: 212, rules: { type: "movie", keywords: ["french cinema"], imdbRatingMin: 6.5, imdbVotesMin: 5000 } })
    item = { title: "Spy Film", type: "movie", genres: ["Action"], duration: 100, tmdbID: 77, ratingKey: "1" }
    NxCheck(r, "unenriched item misses SPY GAMES", NxItemPasses(item, spyGames, invalid, excl, clock), "")
    records = {}
    records["movie:77"] = NxParseTMDBResponse(ParseJson("{""keywords"":{""keywords"":[{""name"":""Espionage""}]}}"), "77", invalid, "movie", v.fetchedAt)
    NxCheck(r, "attach count", NxEnrichAttach([item], records).ToStr(), "1")
    ' Port: the filter caches its view of an item, and attaching drops it, so
    ' the item that just missed now passes.
    NxCheck(r, "enriched item passes SPY GAMES", NxItemPasses(item, spyGames, invalid, excl, clock), "keyword")
    NxCheck(r, "enrichedValue reads keywords", FormatJson(NxEnriched(item, "keywords")), "[""Espionage""]")
    fr = { title: "Amelie", type: "movie", genres: ["Comedy"], duration: 120, tmdbID: 194, ratingKey: "2" }
    records = {}
    records["movie:194"] = NxEnrichFromSupabaseRow({ tmdb_id: "194", media_type: "movie", keywords: ["french cinema"], imdb_rating: 8.3, imdb_votes: 800000 }, nowSec&)
    NxEnrichAttach([fr], records)
    NxCheck(r, "OMDb row passes FOREIGN FILMS", NxEnBool(NxItemPasses(fr, foreign, invalid, excl, clock) <> ""), "true")
    frNoOmdb = { title: "Amelie", type: "movie", genres: ["Comedy"], duration: 120, tmdbID: 194, ratingKey: "2" }
    records["movie:194"] = NxParseTMDBResponse(ParseJson("{""keywords"":{""keywords"":[{""name"":""french cinema""}]}}"), "194", invalid, "movie", v.fetchedAt)
    NxEnrichAttach([frNoOmdb], records)
    NxCheck(r, "TMDB-only row still gated by OMDb (as on tvOS)", NxEnBool(NxItemPasses(frNoOmdb, foreign, invalid, excl, clock) <> ""), "false")

    ' ── Transcribed: Supabase batching ──
    cfg = { supabaseURL: "https://example.supabase.co", anonKey: "anon", relayURL: "https://nostalgex.app/api/tmdb", clientValue: "roku" }
    ids = []
    for i = 1 to 450
        ids.Push(i.ToStr())
    end for
    net = NxEnStubNet("evenRows")
    prog = NxEnProgress()
    rows = NxEnrichReadSupabase(ids, cfg, net, nowSec&, prog)
    NxCheck(r, "read: chunks of 200", net.calls.Count().ToStr(), "3")
    sizes = []
    for each call in net.calls
        sizes.Push(NxEnInList(call.url).Count().ToStr())
    end for
    NxCheck(r, "read: chunk sizes", sizes.Join(","), "200,200,50")
    NxCheck(r, "read: url shape", NxEnBool(Left(net.calls[0].url, 72) = "https://example.supabase.co/rest/v1/media_enrichments?tmdb_id=in.(1,2,3,"), "true")
    NxCheck(r, "read: select all", Right(net.calls[0].url, 10), ")&select=*")
    NxCheck(r, "read: headers", NxEnCanon(net.calls[0].headers), "{""Authorization"":""Bearer anon"",""Content-Type"":""application/json"",""apikey"":""anon""}")
    NxCheck(r, "read: rows", rows.Count().ToStr(), "225")
    NxCheck(r, "read: progress", prog.seen.Join(","), "1/3 cache,2/3 cache,3/3 cache")

    net = NxEnStubNet("failSecond")
    ids = []
    for i = 0 to 400
        ids.Push(i.ToStr())
    end for
    NxCheck(r, "read: failed chunk skipped, others kept", NxEnrichReadSupabase(ids, cfg, net, nowSec&, invalid).Count().ToStr(), "2")

    recs = []
    for i = 0 to 249
        recs.Push(NxParseTMDBResponse({}, i.ToStr(), invalid, "movie", v.fetchedAt))
    end for
    net = NxEnStubNet("created")
    written = NxEnrichUpsertSupabase(recs, cfg, net, false)
    sizes = []
    for each call in net.calls
        sizes.Push(ParseJson(call.body).Count().ToStr())
    end for
    NxCheck(r, "upsert: chunks of 200", sizes.Join(","), "200,50")
    NxCheck(r, "upsert: POST", net.calls[0].method, "POST")
    NxCheck(r, "upsert: merge duplicates", net.calls[0].headers.Prefer, "resolution=merge-duplicates,return=minimal")
    NxCheck(r, "upsert: columns named, a franchise nothing knows left out", net.calls[0].url, "https://example.supabase.co/rest/v1/media_enrichments?columns=tmdb_id,media_type,keywords,networks,production_companies,tmdb_genres,fetched_at")
    NxCheck(r, "upsert: written", written.ToStr(), "250")
    NxCheck(r, "upsert carries TMDB columns only, never a null", NxEnKeys(ParseJson(net.calls[0].body)[0]), "fetched_at,keywords,media_type,networks,production_companies,tmdb_genres,tmdb_id")
    NxCheck(r, "upsert sends no null", NxEnBool(Instr(1, net.calls[0].body, "null") > 0), "false")
    net = NxEnStubNet("down")
    NxCheck(r, "upsert: a network error writes nothing (port)", NxEnrichUpsertSupabase(recs, cfg, net, false).ToStr(), "0")

    ' A mixed batch (N-093, as the Apple TV's upsertBodies): rows with different columns go in their own requests,
    ' each naming its own columns, and a value nobody has is left out, so the table keeps what another device saved.
    withFranchise = NxEnRec("10", { franchiseID: 119, franchiseName: "The Lord of the Rings Collection" }, v.fetchedAt)
    plain = NxEnRec("11", {}, v.fetchedAt)
    aShow = NxParseTMDBResponse({}, "12", invalid, "tv", v.fetchedAt)
    net = NxEnStubNet("created")
    written = NxEnrichUpsertSupabase([withFranchise, plain, aShow], cfg, net, false)
    NxCheck(r, "mixed batch: two requests, one per set of columns", net.calls.Count().ToStr(), "2")
    NxCheck(r, "mixed batch: every row saved", written.ToStr(), "3")
    NxCheck(r, "mixed batch: the franchise row names the franchise columns", NxEnBool(Instr(1, net.calls[0].url, "franchise_id,franchise_name") > 0), "true")
    NxCheck(r, "mixed batch: the others do not", NxEnBool(Instr(1, net.calls[1].url, "franchise") > 0), "false")
    NxCheck(r, "mixed batch: rows per request", ParseJson(net.calls[0].body).Count().ToStr() + "," + ParseJson(net.calls[1].body).Count().ToStr(), "1,2")
    NxCheck(r, "mixed batch: the type stays with its row", ParseJson(net.calls[1].body)[1].media_type, "tv")
    for each call in net.calls
        n = 0
        for each row in ParseJson(call.body)
            n = n + row.Count()
        end for
        cols = Mid(call.url, Instr(1, call.url, "columns=") + 8).Split(",").Count()
        NxCheck(r, "mixed batch: every row has exactly the request's columns", n.ToStr(), (cols * ParseJson(call.body).Count()).ToStr())
    end for
    NxCheck(r, "mixed batch: no null sent", NxEnBool(Instr(1, net.calls[0].body + net.calls[1].body, "null") > 0), "false")
    ' A lookup that found no rating leaves the rating out; the Metacritic score it did find is still saved.
    noRating = NxEnrichMergeOMDb(NxEnRec("13", {}, v.fetchedAt), { imdbRating: invalid, imdbVotes: invalid, rottenTomatoesScore: invalid, metacriticScore: 61, awards: invalid }, "tt0000013")
    net = NxEnStubNet("created")
    NxEnrichUpsertSupabase([noRating], cfg, net, true)
    NxCheck(r, "omdb upsert leaves out a rating nobody found", Mid(net.calls[0].url, Instr(1, net.calls[0].url, "columns=") + 8), "tmdb_id,media_type,imdb_id,metacritic_score")
    NxCheck(r, "omdb upsert row", NxEnKeys(ParseJson(net.calls[0].body)[0]), "imdb_id,media_type,metacritic_score,tmdb_id")

    ' ── Transcribed: relay requests ──
    tvReq = NxEnrichRelayRequest({ tmdbID: "1399", mediaType: "tv" }, cfg)
    NxCheck(r, "relay tv url", tvReq.url, "https://nostalgex.app/api/tmdb?path=tv/1399")
    NxCheck(r, "relay movie url", NxEnrichRelayRequest({ tmdbID: "603", mediaType: "movie" }, cfg).url, "https://nostalgex.app/api/tmdb?path=movie/603")
    NxCheck(r, "relay client header", tvReq.headers["X-Nostalgex-Client"], "roku")
    NxCheck(r, "relay client header defaults to roku", NxEnrichRelayRequest({ tmdbID: "1", mediaType: "tv" }, { relayURL: "x" }).headers["X-Nostalgex-Client"], "roku")
    NxCheck(r, "relay is the www host", k.relayURL, "https://www.nostalgex.app/api/tmdb")

    ' ── Transcribed: enrichLibrary end to end ──
    cache = NxEnrichMemoryCache()
    items = NxEnLibrary()
    net = NxEnStubNet("backend")
    ready = { keys: invalid, run: sub(records as Object)
        m.keys = records.Keys()
    end sub }
    state = NxEnrichLibrary(items, { config: cfg, net: net, cache: cache, nowSec: nowSec&, onCacheReady: ready })
    s = state.stats
    NxCheck(r, "e2e: stats", FormatJson([s.ids, s.local, s.supabase, s.fetched, s.misses, s.failed, s.upserted]), "[5,0,1,2,1,1,2]")
    NxCheck(r, "e2e: early rebuild saw the cache hit only", NxEnJoin(ready.keys), "movie:1")
    NxCheck(r, "e2e: records", NxEnJoin(NxEnSorted(state.records.Keys())), "movie:1,movie:2,tv:3")
    titles = []
    for each it in items
        if it.enrichment <> invalid then titles.Push(it.title)
    end for
    NxCheck(r, "e2e: attached to every episode", titles.Join(","), "A,B,Show,Show")
    NxCheck(r, "e2e: tv parsed from results", FormatJson(items[2].enrichment.keywords), "[""sitcom""]")
    supa = []
    for each call in net.calls
        if Instr(1, call.url, "/rest/v1/") > 0 then supa.Push(call)
    end for
    methods = []
    for each call in supa
        methods.Push(call.method)
    end for
    NxCheck(r, "e2e: one read, one upsert", methods.Join(","), "GET,POST")
    upIDs = []
    for each row in ParseJson(supa[1].body)
        upIDs.Push(row.tmdb_id)
    end for
    NxCheck(r, "e2e: upsert carries the two fetched", NxEnJoin(NxEnSorted(upIDs)), "2,3")
    sent = []
    for each call in net.calls
        sent.Push(call.url)
    end for
    NxCheck(r, "e2e: only TMDB ids sent", NxEnBool(CreateObject("roRegex", "title|Show|Gone|tt\d", "").IsMatch(sent.Join(" "))), "false")
    NxCheck(r, "e2e: 404 cached as a miss", NxEnBool(cache.rows["movie:4"] <> invalid and cache.rows["movie:4"].record = invalid), "true")
    NxCheck(r, "e2e: 429 not cached", NxEnBool(cache.rows.DoesExist("movie:5")), "false")

    again = NxEnLibrary()
    net = NxEnStubNet("backend")
    second = NxEnrichLibrary(again, { config: cfg, net: net, cache: cache, nowSec: nowSec& + 3600 })
    NxCheck(r, "reload: local hits", second.stats.local.ToStr(), "3")
    paths = []
    for each call in net.calls
        paths.Push(NxRx("enTestHost", "^https://[^/]+").Replace(call.url, ""))
    end for
    NxCheck(r, "reload: only the failed id goes out", paths.Join(" "), "/rest/v1/media_enrichments?tmdb_id=in.(5)&select=* /api/tmdb?path=movie/5")
    NxCheck(r, "reload: attached from local", FormatJson(again[1].enrichment.keywords), "[""fresh""]")

    net = NxEnStubNet("backend")
    NxEnrichLibrary(NxEnLibrary(), { config: cfg, net: net, cache: cache, nowSec: nowSec& + k.cacheTtlSec + 1 })
    NxCheck(r, "expired: Supabase read again", NxEnBool(Instr(1, net.calls[0].url, "tmdb_id=in.(1,2,3,4,5)") > 0), "true")

    net = NxEnStubNet("backend")
    state = NxEnrichLibrary(NxEnLibrary(), { config: { relayURL: "/api/tmdb", supabaseURL: "", anonKey: "" }, net: net, cache: NxEnrichMemoryCache(), nowSec: nowSec& })
    NxCheck(r, "no config: skipped", NxEnBool(state.skipped), "true")
    NxCheck(r, "no config: no requests", net.calls.Count().ToStr(), "0")
    NxCheck(r, "unreadable config file: off (port)", NxEnJoin(NxEnrichMissingConfiguration(NxEnrichmentConfig("pkg:/manifest"))), "tmdb relay,supabase url,anon key")

    ' ── Transcribed: OMDb parse, merge and upsert ──
    doc = { imdbRating: "8.7", imdbVotes: "2,213,456", Metascore: "73", Awards: "Won 4 Oscars.", Ratings: [{ Source: "Internet Movie Database", Value: "8.7/10" }, { Source: "Rotten Tomatoes", Value: "83%" }], Response: "True" }
    base = NxParseTMDBResponse(ParseJson("{""keywords"":{""keywords"":[{""name"":""cult film""}]}}"), "1", invalid, "movie", v.fetchedAt)
    merged = NxEnrichMergeOMDb(base, NxParseOMDbResponse(doc), "tt0133093")
    NxCheck(r, "omdb merge keeps TMDB fields", FormatJson(merged.keywords), "[""cult film""]")
    NxCheck(r, "omdb merge fills imdb", NxEnCanon([merged.imdbID, merged.imdbRating, merged.imdbVotes]), "[""tt0133093"",8.7,2213456]")
    row = NxEnrichToOMDbRow(merged)
    NxCheck(r, "omdb upsert columns", NxEnKeys(row), "awards,imdb_id,imdb_rating,imdb_votes,media_type,metacritic_score,rt_score,tmdb_id")
    NxCheck(r, "omdb merge keeps an id it has", NxEnrichMergeOMDb(NxEnrichMergeOMDb(base, {}, "tt0000001"), {}, "tt0000002").imdbID, "tt0000001")

    ' ── Transcribed: OMDb gates and candidates ──
    channels = NxEnChannels()
    gates = NxEnrichOMDbGates(channels)
    NxCheck(r, "gates only from OMDb-ruled channels", gates.Count().ToStr(), "2")
    NxCheck(r, "gate media type", gates[0].mediaType + "," + gates[1].mediaType, "movie,movie")
    NxCheck(r, "gate keywords lowercased", gates[0].keywords.Join(","), "french cinema,subtitled")
    NxCheck(r, "candidate by keyword", NxEnBool(NxEnrichIsOMDbCandidate("movie", ["Cult Film"], [], gates)), "true")
    NxCheck(r, "candidate by genre substring", NxEnBool(NxEnrichIsOMDbCandidate("movie", [], ["Comedy Horror"], gates)), "true")
    NxCheck(r, "wrong media type", NxEnBool(NxEnrichIsOMDbCandidate("tv", ["cult film"], [], gates)), "false")
    NxCheck(r, "no keyword or genre", NxEnBool(NxEnrichIsOMDbCandidate("movie", ["spy"], ["Action"], gates)), "false")
    NxCheck(r, "no gates", NxEnBool(NxEnrichIsOMDbCandidate("movie", ["cult film"], [], [])), "false")
    real = NxEnrichOMDbGates(config.channels)
    NxCheck(r, "shipped channels.json gates CULT CLASSICS keywords", NxEnBool(NxEnrichIsOMDbCandidate("movie", ["cult film"], [], real)), "true")
    NxCheck(r, "shipped channels.json gates FOREIGN FILMS keywords", NxEnBool(NxEnrichIsOMDbCandidate("movie", ["french cinema"], [], real)), "true")
    NxCheck(r, "gate without a type admits tv (port)", NxEnBool(NxEnrichIsOMDbCandidate("tv", ["x"], [], NxEnrichOMDbGates([{ rules: { keywords: ["x"], imdbVotesMin: 1 } }]))), "true")

    recs = {}
    recs["movie:1"] = NxEnRec("1", { imdbID: "tt0000001", keywords: ["cult film"] }, v.fetchedAt)
    recs["movie:2"] = NxEnRec("2", { imdbID: "tt0000002", keywords: ["cult film"], imdbRating: 7.1 }, v.fetchedAt)
    recs["movie:3"] = NxEnRec("3", { keywords: ["cult film"] }, v.fetchedAt)
    recs["movie:4"] = NxEnRec("4", { imdbID: "tt0000004", keywords: ["romance"] }, v.fetchedAt)
    recs["movie:5"] = NxEnRec("5", { imdbID: "tt0000005" }, v.fetchedAt)
    work = []
    for each id in ["1", "2", "3", "4", "5", "6"]
        work.Push({ tmdbID: id, mediaType: "movie" })
    end for
    byID = NxEnrichGenresByTMDB([{ tmdbID: 5, genres: ["Horror"] }, { tmdbID: 5, genres: ["Thriller"] }])
    NxCheck(r, "genresByTMDB merges", byID["movie:5"].list.Join(","), "Horror,Thriller")
    picked = []
    for each cand in NxEnrichOMDbCandidates(work, recs, byID, gates)
        picked.Push(cand.tmdbID)
    end for
    NxCheck(r, "candidates: unrated, with id, gated (server genre counts)", picked.Join(","), "1,5")

    ' ── Transcribed: OMDb budget ──
    list = []
    for i = 0 to 399
        list.Push(i)
    end for
    rng = NxEnLcg(7)
    picked = NxEnrichPickOMDb(list, k.omdbPerLoad, rng)
    NxCheck(r, "pick limit is 50", k.omdbPerLoad.ToStr(), "50")
    NxCheck(r, "pick 50", picked.Count().ToStr(), "50")
    seen = {}
    for each p in picked
        seen[p.ToStr()] = true
    end for
    NxCheck(r, "pick no repeats", seen.Count().ToStr(), "50")
    firstFifty = []
    for i = 0 to 49
        firstFifty.Push(i)
    end for
    NxCheck(r, "pick random order", NxEnBool(FormatJson(picked) = FormatJson(firstFifty)), "false")
    NxCheck(r, "pick fewer than limit returns all", NxEnJoin(NxEnSorted(NxEnStrs(NxEnrichPickOMDb([1, 2, 3], 50, NxEnrichRandom())))), "1,2,3")
    NxCheck(r, "pick leaves input alone", FormatJson([list[0], list[1], list[2]]), "[0,1,2]")

    store = NxEnStore()
    b = NxEnrichOMDbBackoff(store)
    hit& = 1791732600 ' 2026-10-11T15:30:00Z
    NxCheck(r, "backoff starts open", NxEnBool(b.isBlocked(hit&)), "false")
    b.mark(hit&)
    NxCheck(r, "backoff blocks after limit", NxEnBool(b.isBlocked(hit&)), "true")
    NxCheck(r, "backoff holds to 23:59:59", NxEnBool(b.isBlocked(1791763199)), "true")
    NxCheck(r, "backoff opens at UTC midnight", NxEnBool(b.isBlocked(1791763200)), "false")
    NxCheck(r, "backoff persists", NxEnBool(NxEnrichOMDbBackoff(store).isBlocked(hit&)), "true")
    tb = NxEnrichOMDbBackoff(invalid)
    tb.mark(hit&)
    NxCheck(r, "backoff in memory only", NxEnBool(tb.isBlocked(hit&)), "true")

    ' ── Transcribed: OMDb relay request ──
    req = NxEnrichOMDbRequest("tt0133093", cfg)
    NxCheck(r, "omdb relay url", req.url, "https://nostalgex.app/api/tmdb?path=omdb/tt0133093")
    NxCheck(r, "omdb relay client header", req.headers["X-Nostalgex-Client"], "roku")
    NxCheck(r, "omdb bad id never sent", NxEnBool(NxEnrichOMDbRequest("tt12&apikey=x", cfg) = invalid), "true")

    ' ── Transcribed: OMDb end to end ──
    store = NxEnStore()
    items = NxEnOmdbLibrary(200)
    net = NxEnStubNet("omdb")
    state = NxEnrichLibrary(items, { config: cfg, net: net, cache: NxEnrichMemoryCache(), nowSec: nowSec&, channels: channels, backoff: NxEnrichOMDbBackoff(store) })
    asked = []
    for each call in net.calls
        if Instr(1, call.url, "path=omdb/") > 0 then asked.Push(call)
    end for
    NxCheck(r, "e2e omdb: only gated candidates (horror half)", state.omdb.candidates.ToStr(), "100")
    NxCheck(r, "e2e omdb: capped at 50", asked.Count().ToStr(), "50")
    odd = true
    for each call in asked
        n = NxRx("enTestTt", "tt(\d+)").Match(call.url)[1].ToInt()
        if n mod 2 <> 1 then odd = false
    end for
    NxCheck(r, "e2e omdb: every ask is a candidate", NxEnBool(odd), "true")
    NxCheck(r, "e2e omdb: found", state.omdb.fetched.ToStr(), "50")
    ups = []
    for each call in net.calls
        if call.method = "POST" then ups.Push(call)
    end for
    NxCheck(r, "e2e omdb: one OMDb upsert", ups.Count().ToStr(), "1")
    ' The request names the OMDb columns these rows have values for, and no others (N-093): a column the lookup found nothing for is left out.
    named = Mid(ups[0].url, Instr(1, ups[0].url, "columns=") + 8).Split(",")
    allOMDb = true
    for each cname in named
        if not NxHasValue(k.omdbColumns, cname) then allOMDb = false
    end for
    NxCheck(r, "e2e omdb: upsert pinned to OMDb columns", NxEnBool(allOMDb and named.Count() >= 5 and named[0] = "tmdb_id" and named[1] = "media_type"), "true")
    body = ParseJson(ups[0].body)
    NxCheck(r, "e2e omdb: the row carries just the columns the request names", NxEnKeys(body[0]), NxEnSorted(named).Join(","))
    NxCheck(r, "e2e omdb: upsert rows", body.Count().ToStr(), "50")
    NxCheck(r, "e2e omdb: votes parsed", NxToStr(body[0].imdb_votes), "45000")
    rated = []
    for each it in items
        if it.enrichment <> invalid then
            if it.enrichment.imdbRating <> invalid then
                if NxEnCanon(it.enrichment.imdbRating) = "7.4" then rated.Push(it)
            end if
        end if
    end for
    NxCheck(r, "e2e omdb: attached", rated.Count().ToStr(), "50")
    cult = NxFilterChannel(channels[1])
    allPass = true
    for each it in rated
        if NxItemPasses(it, cult, invalid, excl, clock) = "" then allPass = false
    end for
    NxCheck(r, "e2e omdb: rated items pass CULT CLASSICS votes gate", NxEnBool(allPass), "true")
    leaked = false
    for each call in net.calls
        if Instr(1, call.url, "Film") > 0 or Instr(1, NxToStr(call.body), "Film") > 0 then leaked = true
    end for
    NxCheck(r, "e2e omdb: no titles sent", NxEnBool(leaked), "false")
    n = 0
    for each id in state.records
        if state.records[id].imdbRating <> invalid then n = n + 1
    end for
    NxCheck(r, "e2e omdb: records updated", n.ToStr(), "50")

    store = NxEnStore()
    backoff = NxEnrichOMDbBackoff(store)
    net = NxEnStubNet("omdb")
    net.limitAfter = 3
    state = NxEnrichLibrary(NxEnOmdbLibrary(200), { config: cfg, net: net, cache: NxEnrichMemoryCache(), nowSec: nowSec&, channels: channels, backoff: backoff })
    NxCheck(r, "limit: flagged", NxEnBool(state.omdb.limited), "true")
    NxCheck(r, "limit: stops asking (at most concurrency in flight)", NxEnBool(net.omdbCalls <= 3 + k.omdbConcurrency), "true")
    NxCheck(r, "limit: blocked until UTC midnight", backoff.blockedUntil().ToStr(), "1791763200")
    net = NxEnStubNet("omdb")
    second = NxEnrichLibrary(NxEnOmdbLibrary(200), { config: cfg, net: net, cache: NxEnrichMemoryCache(), nowSec: nowSec& + 3600, channels: channels, backoff: backoff })
    NxCheck(r, "limit: next load same day asks nothing", net.omdbCalls.ToStr(), "0")
    NxCheck(r, "limit: reported paused", NxEnBool(second.omdb.paused), "true")
    net = NxEnStubNet("omdb")
    NxEnrichLibrary(NxEnOmdbLibrary(200), { config: cfg, net: net, cache: NxEnrichMemoryCache(), nowSec: 1791763201, channels: channels, backoff: backoff })
    NxCheck(r, "limit: asks again after UTC midnight", net.omdbCalls.ToStr(), "50")

    net = NxEnStubNet("omdb")
    state = NxEnrichLibrary(NxEnOmdbLibrary(20), { config: cfg, net: net, cache: NxEnrichMemoryCache(), nowSec: nowSec& })
    NxCheck(r, "no channels: no OMDb", state.omdb.gates.ToStr() + "," + net.omdbCalls.ToStr(), "0,0")

    ' ── Port: a relay that refuses the client is asked one round only ──
    big = []
    for i = 1 to 200
        big.Push({ title: "T", type: "movie", tmdbID: i })
    end for
    net = NxEnStubNet("refused")
    state = NxEnrichLibrary(big, { config: cfg, net: net, cache: NxEnrichMemoryCache(), nowSec: nowSec& })
    relayCalls = 0
    for each call in net.calls
        if Instr(1, call.url, "path=") > 0 then relayCalls = relayCalls + 1
    end for
    NxCheck(r, "refused: one round of 60 asked", relayCalls.ToStr(), "60")
    NxCheck(r, "refused: all counted failed", state.stats.failed.ToStr(), "200")
    net = NxEnStubNet("someRefused")
    state = NxEnrichLibrary(big, { config: cfg, net: net, cache: NxEnrichMemoryCache(), nowSec: nowSec& })
    relayCalls = 0
    for each call in net.calls
        if Instr(1, call.url, "path=") > 0 then relayCalls = relayCalls + 1
    end for
    NxCheck(r, "partly refused: every miss asked, as upstream", relayCalls.ToStr(), "200")

    ' ── Port: the two steps the library load calls ──
    cache = NxEnrichMemoryCache()
    items = NxEnLibrary()
    opts = { config: cfg, net: NxEnStubNet("backend"), cache: cache, nowSec: nowSec& }
    state = NxEnrichFromCaches(items, opts)
    NxCheck(r, "steps: caches leave relay work", NxEnBool(NxEnrichHasRemoteWork(state, opts)), "true")
    NxCheck(r, "steps: remote reports what it added", NxEnrichFromRemote(state, items, opts).ToStr(), "2")
    opts.net = NxEnStubNet("backend")
    state = NxEnrichFromCaches(NxEnLibrary(), opts)
    NxCheck(r, "steps: the failed id is still work", NxEnBool(NxEnrichHasRemoteWork(state, opts)), "true")
    opts.nowSec = nowSec& + 60
    for each w in state.needRemote
        cache.putMany([{ tmdbID: w.tmdbID, mediaType: w.mediaType, savedAt: nowSec&, record: invalid }])
    end for
    state = NxEnrichFromCaches(NxEnLibrary(), opts)
    NxCheck(r, "steps: nothing left without OMDb gates", NxEnBool(NxEnrichHasRemoteWork(state, opts)), "false")

    ' ── A film and a show with one TMDB number (the table's key is the number plus the type) ──
    ' TMDB numbers films and shows separately, and the shared table now holds a row for each. A title's own
    ' type picks the row, and a show is never skipped because a film with its number is stored.
    work = NxEnrichWorkItems(NxEnShared())
    NxCheck(r, "shared number: two titles, not one", NxEnCanon(work), "[{""mediaType"":""movie"",""tmdbID"":""603""},{""mediaType"":""tv"",""tmdbID"":""603""}]")
    NxCheck(r, "shared number: the key is the type and the number", NxEnrichKey("tv", 603), "tv:603")

    items = NxEnShared()
    net = NxEnStubNet("sharedBoth")
    state = NxEnrichLibrary(items, { config: cfg, net: net, cache: NxEnrichMemoryCache(), nowSec: nowSec& })
    NxCheck(r, "shared number: each type takes its own row", items[0].enrichment.keywords.Join(",") + "|" + items[1].enrichment.keywords.Join(",") + "|" + items[2].enrichment.keywords.Join(","), "film row|show row|show row")
    NxCheck(r, "shared number: one read, the relay not asked", net.calls.Count().ToStr(), "1")
    NxCheck(r, "shared number: the number is asked once", NxEnBool(Instr(1, net.calls[0].url, "tmdb_id=in.(603)&select=*") > 0), "true")
    NxCheck(r, "shared number: both rows counted from the table", state.stats.supabase.ToStr(), "2")
    NxCheck(r, "shared number: records keyed by type and number", NxEnJoin(NxEnSorted(state.records.Keys())), "movie:603,tv:603")

    items = NxEnShared()
    net = NxEnStubNet("filmOnlyShared")
    cache = NxEnrichMemoryCache()
    state = NxEnrichLibrary(items, { config: cfg, net: net, cache: cache, nowSec: nowSec& })
    NxCheck(r, "film row only: the show is still fetched", FormatJson([items[0].enrichment.keywords, items[1].enrichment.keywords]), "[[""film row""],[""show fetched""]]")
    paths = []
    for each call in net.calls
        if Instr(1, call.url, "path=") > 0 then paths.Push(NxRx("enTestHost", "^https://[^/]+").Replace(call.url, ""))
    end for
    NxCheck(r, "film row only: only the show goes to the relay", paths.Join(" "), "/api/tmdb?path=tv/603")
    NxCheck(r, "film row only: one row saved, for the show", FormatJson([state.stats.upserted, ParseJson(net.calls[net.calls.Count() - 1].body)[0].media_type]), "[1,""tv""]")
    NxCheck(r, "film row only: the local cache holds both", NxEnJoin(NxEnSorted(cache.rows.Keys())), "movie:603,tv:603")

    ' A show in a library of shows, a film with its number in the table: the film's row is not the show's.
    items = [{ title: "Show", type: "episode", tmdbID: 603 }]
    net = NxEnStubNet("filmOnlyShared")
    NxEnrichLibrary(items, { config: cfg, net: net, cache: NxEnrichMemoryCache(), nowSec: nowSec& })
    NxCheck(r, "show only: the film's row is not taken", FormatJson(items[0].enrichment.keywords), "[""show fetched""]")

    ' The local cache holding the film does not make the show cached.
    items = NxEnShared()
    cache = NxEnrichMemoryCache()
    cache.putMany([{ tmdbID: "603", mediaType: "movie", savedAt: nowSec&, record: NxEnRec("603", { keywords: ["film local"] }, v.fetchedAt) }])
    net = NxEnStubNet("filmOnlyShared")
    state = NxEnrichLibrary(items, { config: cfg, net: net, cache: cache, nowSec: nowSec& + 60 })
    NxCheck(r, "local film row: the film from the file, the show from the net", FormatJson([state.stats.local, items[0].enrichment.keywords, items[1].enrichment.keywords]), "[1,[""film local""],[""show fetched""]]")
    NxCheck(r, "local film row: the show is still asked of the table", NxEnBool(Instr(1, net.calls[0].url, "tmdb_id=in.(603)") > 0), "true")

    ' A saved miss for the show is the show's, not the film's.
    items = NxEnShared()
    cache = NxEnrichMemoryCache()
    cache.putMany([{ tmdbID: "603", mediaType: "tv", savedAt: nowSec&, record: invalid }])
    net = NxEnStubNet("filmOnlyShared")
    state = NxEnrichLibrary(items, { config: cfg, net: net, cache: cache, nowSec: nowSec& + 60 })
    NxCheck(r, "show miss saved: the film is read, the show is not asked", FormatJson([state.stats.misses, items[0].enrichment.keywords, items[1].enrichment]), "[1,[""film row""],null]")

    ' A file an earlier build wrote kept its rows under the bare number: a row with a record is kept under its
    ' own type, a saved miss (no type) is dropped.
    old = {}
    old["603"] = { tmdbID: "603", savedAt: nowSec&, record: NxEnRec("603", { keywords: ["film local"] }, v.fetchedAt) }
    old["1399"] = { tmdbID: "1399", savedAt: nowSec&, record: NxParseTMDBResponse({}, "1399", invalid, "tv", v.fetchedAt) }
    old["9"] = { tmdbID: "9", savedAt: nowSec&, record: invalid }
    rekeyed = NxEnrichRekeyRows(old)
    NxCheck(r, "old file: rows re-keyed by their own type", NxEnJoin(NxEnSorted(rekeyed.Keys())), "movie:603,tv:1399")
    NxCheck(r, "old file: a saved miss with no type is dropped", NxEnBool(rekeyed.DoesExist("movie:9") or rekeyed.DoesExist("tv:9") or rekeyed.DoesExist("9")), "false")
    NxCheck(r, "old file: the row now names its type", rekeyed["tv:1399"].mediaType, "tv")

    ' Server genres and OMDb candidates are per title: the film's do not reach the show.
    byID = NxEnrichGenresByTMDB(NxEnShared())
    NxCheck(r, "shared number: genres kept apart", byID["movie:603"].list.Join(",") + "|" + byID["tv:603"].list.Join(","), "Action|Drama")
    recs = {}
    recs["tv:603"] = NxEnRec("603", { imdbID: "tt0000603", keywords: ["cult film"], mediaType: "tv" }, v.fetchedAt)
    NxCheck(r, "shared number: the show's record is not the film's", NxEnrichOMDbCandidates(NxEnrichWorkItems(NxEnShared()), recs, byID, gates).Count().ToStr(), "0")
    recs = {}
    recs["movie:603"] = NxEnRec("603", { imdbID: "tt0000603", keywords: ["cult film"] }, v.fetchedAt)
    cands = NxEnrichOMDbCandidates(NxEnrichWorkItems(NxEnShared()), recs, byID, gates)
    NxCheck(r, "shared number: the film's record makes the film a candidate", FormatJson([cands.Count(), cands[0].mediaType, cands[0].tmdbID]), "[1,""movie"",""603""]")

    print "  enrichment: "; r.pass; " passed, "; r.fail; " failed"
    return r.fail
end function

' ── Helpers ─────────────────────────────────────────────────────────────────

function NxEnBool(b as Dynamic) as String
    if b = true then return "true"
    return "false"
end function

' Canonical JSON, as tests/gen-enrichment.mjs writes it: keys sorted,
' non-integers to 7 significant digits, non-ASCII as \uXXXX.
function NxEnCanon(v as Dynamic) as String
    if v = invalid then return "null"
    t = type(v)
    if t = "roArray" then
        parts = []
        for each x in v
            parts.Push(NxEnCanon(x))
        end for
        return "[" + parts.Join(",") + "]"
    end if
    if t = "roAssociativeArray" then
        parts = []
        for each key in NxEnSorted(v.Keys())
            parts.Push(NxEnString(key) + ":" + NxEnCanon(v[key]))
        end for
        return "{" + parts.Join(",") + "}"
    end if
    if t = "Boolean" or t = "roBoolean" then return NxEnBool(v)
    if NxIsNumber(v) then
        if v <= 2147483647 and v >= -2147483648 then
            if v - Int(v) = 0 then return Int(v).ToStr()
        end if
        ' Through a Float, for 7 significant digits (the interpreter's CSng truncates).
        f! = v
        s = Str(f!).Trim()
        if Left(s, 1) = "." then s = "0" + s
        if Left(s, 2) = "-." then s = "-0" + Mid(s, 2)
        return s
    end if
    return NxEnString(NxToStr(v))
end function

function NxEnString(s as String) as String
    out = Chr(34)
    for i = 1 to s.Len()
        ch = Mid(s, i, 1)
        code = Asc(ch)
        if ch = Chr(34) then
            out = out + "\" + Chr(34)
        else if ch = "\" then
            out = out + "\\"
        else if code = 8 then
            out = out + "\b"
        else if code = 9 then
            out = out + "\t"
        else if code = 10 then
            out = out + "\n"
        else if code = 12 then
            out = out + "\f"
        else if code = 13 then
            out = out + "\r"
        else if code < 32 or code >= 127 then
            h = LCase(StrI(code, 16))
            while h.Len() < 4
                h = "0" + h
            end while
            out = out + "\u" + h
        else
            out = out + ch
        end if
    end for
    return out + Chr(34)
end function

' Sorted by code unit, as JS sort() sorts strings.
function NxEnSorted(list as Object) as Object
    a = []
    for each x in list
        a.Push(NxToStr(x))
    end for
    for i = 1 to a.Count() - 1
        x = a[i]
        j = i - 1
        while j >= 0 and a[j] > x
            a[j + 1] = a[j]
            j = j - 1
        end while
        a[j + 1] = x
    end for
    return a
end function

function NxEnStrs(list as Object) as Object
    out = []
    for each x in list
        out.Push(NxToStr(x))
    end for
    return out
end function

function NxEnJoin(list as Dynamic) as String
    return NxEnStrs(NxList(list)).Join(",")
end function

function NxEnKeys(aa as Object) as String
    return NxEnSorted(aa.Keys()).Join(",")
end function

' The ids inside `in.(...)` of a Supabase read URL.
function NxEnInList(url as String) as Object
    got = NxRx("enTestIn", "in\.\(([^)]*)\)").Match(url)
    if got.Count() < 2 or got[1] = "" then return []
    return got[1].Split(",")
end function

function NxEnRec(id as String, extra as Object, fetchedAt as String) as Object
    e = NxParseTMDBResponse({}, id, invalid, "movie", fetchedAt)
    e.Append(extra)
    return e
end function

function NxEnLibrary() as Object
    return [
        { title: "A", type: "movie", tmdbID: 1 },
        { title: "B", type: "movie", tmdbID: 2 },
        { title: "Show", type: "episode", tmdbID: 3 },
        { title: "Show", type: "episode", tmdbID: 3 },
        { title: "Gone", type: "movie", tmdbID: 4 },
        { title: "Flaky", type: "movie", tmdbID: 5 },
        { title: "No id", type: "movie", tmdbID: invalid }
    ]
end function

' A film and a show (two episodes) with one TMDB number.
function NxEnShared() as Object
    return [
        { title: "Film", type: "movie", tmdbID: 603, genres: ["Action"] },
        { title: "Show", type: "episode", tmdbID: 603, genres: ["Drama"] },
        { title: "Show", type: "episode", tmdbID: 603 }
    ]
end function

function NxEnOmdbLibrary(n as Integer) as Object
    items = []
    for i = 1 to n
        genres = ["Drama"]
        if i mod 2 = 1 then genres = ["Horror"]
        items.Push({ title: "Film " + i.ToStr(), type: "movie", tmdbID: i, genres: genres })
    end for
    return items
end function

function NxEnChannels() as Object
    return [
        { id: 212, name: "FOREIGN FILMS", rules: { type: "movie", keywords: ["French Cinema", "subtitled"], imdbRatingMin: 6.5, imdbVotesMin: 5000 } },
        { id: 214, name: "CULT CLASSICS", rules: { type: "movie", keywords: ["cult film"], genres: { include: ["Horror"] }, imdbVotesMin: 30000 } },
        { id: 219, name: "SPY GAMES", rules: { type: "movie", keywords: ["spy"] } },
        { id: 1, name: "NO RULES" }
    ]
end function

' The smoke test's linear congruential generator, so the shuffle is fixed.
function NxEnLcg(seed as Integer) as Object
    ' LongInteger, not Double: the TV's Int() of a large Double is off.
    s& = seed
    return { seed: s&, draw: function() as Double
        x& = m.seed * 1103515245& + 12345&
        m.seed = x& - (x& \ 2147483648&) * 2147483648&
        d# = m.seed
        return d# / 2147483648#
    end function }
end function

function NxEnStore() as Object
    return { value: invalid, read: function() as Dynamic
        return m.value
    end function, write: sub(s as String)
        m.value = s
    end sub }
end function

function NxEnProgress() as Object
    return { seen: [], report: sub(done as Integer, total as Integer, phase as String)
        m.seen.Push(done.ToStr() + "/" + total.ToStr() + " " + phase)
    end sub }
end function

' A network that answers from a script, recording every request.
function NxEnStubNet(mode as String) as Object
    return {
        mode: mode, calls: [], omdbCalls: 0, limitAfter: 1000000,
        fetchAll: function(requests as Object, limit as Integer) as Object
            out = []
            for each req in requests
                m.calls.Push(req)
                out.Push(NxEnStubAnswer(m, req))
            end for
            return out
        end function
    }
end function

function NxEnStubAnswer(net as Object, req as Object) as Object
    url = req.url
    isSupa = Instr(1, url, "/rest/v1/") > 0
    isRead = isSupa and req.method <> "POST"
    if net.mode = "evenRows" then
        rows = []
        for each id in NxEnInList(url)
            if id.ToInt() mod 2 = 0 then rows.Push({ tmdb_id: id, media_type: "movie", keywords: [] })
        end for
        return { status: 200, body: FormatJson(rows) }
    else if net.mode = "failSecond" then
        if net.calls.Count() = 2 then return { status: 500, body: "{}" }
        return { status: 200, body: FormatJson([{ tmdb_id: "1", media_type: "movie" }]) }
    else if net.mode = "sharedBoth" then
        if isRead then return { status: 200, body: FormatJson([{ tmdb_id: "603", media_type: "movie", keywords: ["film row"] }, { tmdb_id: "603", media_type: "tv", keywords: ["show row"] }]) }
        if isSupa then return { status: 201, body: "" }
        return { status: 404, body: "{}" }
    else if net.mode = "filmOnlyShared" then
        if isRead then return { status: 200, body: FormatJson([{ tmdb_id: "603", media_type: "movie", keywords: ["film row"] }]) }
        if isSupa then return { status: 201, body: "" }
        if Right(url, 11) = "path=tv/603" then return { status: 200, body: "{""keywords"":{""results"":[{""name"":""show fetched""}]}}" }
        return { status: 404, body: "{}" }
    else if net.mode = "created" then
        return { status: 201, body: "" }
    else if net.mode = "refused" or net.mode = "someRefused" then
        if isRead then return { status: 200, body: "[]" }
        if isSupa then return { status: 201, body: "" }
        if net.mode = "someRefused" and Right(url, 1) = "0" then return { status: 200, body: "{}" }
        return { status: 403, body: "{""error"":""forbidden""}" }
    else if net.mode = "down" then
        return { status: 0, body: "" }
    else if net.mode = "backend" then
        if isRead then return { status: 200, body: FormatJson([{ tmdb_id: "1", media_type: "movie", keywords: ["cached"] }]) }
        if isSupa then return { status: 201, body: "" }
        if Right(url, 12) = "path=movie/2" then return { status: 200, body: "{""keywords"":{""keywords"":[{""name"":""fresh""}]}}" }
        if Right(url, 9) = "path=tv/3" then return { status: 200, body: "{""keywords"":{""results"":[{""name"":""sitcom""}]},""networks"":[{""name"":""NBC""}]}" }
        if Right(url, 12) = "path=movie/4" then return { status: 404, body: "{}" }
        return { status: 429, body: "{}" }
    else if net.mode = "omdb" then
        if isRead then
            rows = []
            for each id in NxEnInList(url)
                imdb = id
                while imdb.Len() < 7
                    imdb = "0" + imdb
                end while
                rows.Push({ tmdb_id: id, media_type: "movie", imdb_id: "tt" + imdb, keywords: [] })
            end for
            return { status: 200, body: FormatJson(rows) }
        end if
        if isSupa then return { status: 201, body: "" }
        if Instr(1, url, "path=omdb/") > 0 then
            net.omdbCalls = net.omdbCalls + 1
            if net.omdbCalls > net.limitAfter then return { status: 429, body: "{""Response"":""False"",""Error"":""Request limit reached!""}" }
            return { status: 200, body: "{""imdbRating"":""7.4"",""imdbVotes"":""45,000"",""Response"":""True""}" }
        end if
        return { status: 404, body: "{}" }
    end if
    return { status: 0, body: "" }
end function
