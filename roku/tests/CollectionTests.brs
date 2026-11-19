' Runs source/collections/Collections.brs against tests/vectors/collections.json,
' made by upstream's scripts/nostalgex-collections.js, and the fold and
' library-load cases transcribed from upstream's CollectionShowsTests.swift
' and FranchiseSettingsTests.swift (at the commit in data/UPSTREAM). Returns
' the failure count.

function NxRunCollectionTests(vectorsPath as String, configPath as String, dictionaryPath as String) as Integer
    v = ParseJson(ReadAsciiFile(vectorsPath))
    config = ParseJson(ReadAsciiFile(configPath))
    defs = NxFranchiseDefinitions(ParseJson(ReadAsciiFile(dictionaryPath)))
    if v = invalid or config = invalid or defs.Count() = 0 then
        print "FAIL cannot read "; vectorsPath; ", "; configPath; " or "; dictionaryPath
        return 1
    end if
    r = { pass: 0, fail: 0 }

    NxCheck(r, "id base", NxCollectionsIDBase().ToStr(), NxToStr(v.constants.ID_BASE))
    NxCheck(r, "number base", NxCollectionsNumberBase().ToStr(), NxToStr(v.constants.NUMBER_BASE))
    NxCheck(r, "capacity", NxCollectionsCapacity().ToStr(), NxToStr(v.constants.CAPACITY))

    for each t in v.text
        NxCheck(r, "cleanTitle " + FormatJson(t.title), NxCollectionsCleanTitle(t.title), t.clean)
        NxCheck(r, "decade " + FormatJson(t.title), NxClOrNull(NxCollectionsDecade(t.clean)), NxClOrNull(t.decade))
    end for

    for each t in v.match
        stock = v.lineup
        if t.stock = "smoke" then stock = v.smokeStock
        if t.stock = "unnamed" then stock = [{ id: 7, name: "" }]
        NxCheck(r, "match " + t.stock + " " + FormatJson(t.title), NxClOrNull(NxCollectionsMatchStatic(t.title, stock)), NxClOrNull(t.label))
    end for

    for each c in v.overlap
        threshold = 60
        if c.threshold <> invalid then threshold = c.threshold
        got = NxCollectionsContentOverlap(c.items, c.manifest, NxClByID(c.channels), threshold)
        NxCheck(r, "overlap " + c.name, NxClOverlap(got), NxClOverlap(c.overlap))
    end for

    for each c in v.candidates
        NxClCheckCandidates(r, c)
    end for

    for each c in v.plex
        fetcher = NxClStubFetcher(c.docs)
        got = NxCollectionsFetchPlex("mid", fetcher)
        NxCheck(r, "plex calls " + c.name, fetcher.calls.Join(","), NxClJoin(c.calls))
        want = "throws"
        if type(c.out) = "roArray" then want = NxClRaw(c.out)
        have = "throws"
        if got <> invalid then have = NxClRaw(got)
        NxCheck(r, "plex out " + c.name, have, want)
    end for

    ' Jellyfin and Emby BoxSets (fetchBoxSetCollections). Upstream's calls
    ' come sorted, as it reads four BoxSets at once.
    for each c in NxList(v.boxSets)
        fetcher = NxClStubFetcher(c.docs)
        got = NxCollectionsFetchBoxSets("srv", "u 1/2", fetcher)
        calls = []
        calls.Append(fetcher.calls)
        calls.Sort()
        NxCheck(r, "boxset calls " + c.name, calls.Join(","), NxClJoin(c.calls))
        want = "throws"
        if type(c.out) = "roArray" then want = NxClRaw(c.out)
        have = "throws"
        if got <> invalid then have = NxClRaw(got)
        NxCheck(r, "boxset out " + c.name, have, want)
    end for
    if NxList(v.boxSets).Count() = 0 then NxCheck(r, "boxset vectors present", "0", "7")

    NxClSwiftCases(r, config, defs)
    NxClClassifierCases(r)
    NxClSplitCases(r)
    NxClPagingCases(r)
    NxClSyntheticPlexCases(r)
    NxClBoxSetKnownCases(r)

    print "collection cases (upstream vectors and Swift tests): "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' One buildCandidates and materialize case. Items take their serverID as
' their serverIndex, so the index is keyed by it, as upstream's is.
sub NxClCheckCandidates(r as Object, c as Object)
    for each it in c.items
        it.serverIndex = it.serverID
    end for
    targets = []
    for each ch in c.franchiseChannels
        pool = []
        for each rf in ch.pool
            pool.Push({ serverIndex: rf.serverID, ratingKey: rf.ratingKey })
        end for
        targets.Push(NxCollectionFoldTarget(NxCollectionsChannelLabel(ch), pool, invalid, ch.id))
    end for
    channelsByID = invalid
    if c.channels <> invalid then channelsByID = NxClByID(c.channels)
    index = NxCollectionsIndexLibrary(c.items, {})
    list = NxCollectionsBuildCandidates(c.raw, index, {
        staticChannels: c.staticChannels, channelsByID: channelsByID, manifest: c.manifest,
        enabledKeys: NxCollectionKeySet(c.enabledKeys), foldTargets: targets, defs: []
    })
    label = "candidates " + c.name
    NxCheck(r, label + ": ids", NxClField(list, "id"), NxClField(c.candidates, "id"))
    if list.Count() <> c.candidates.Count() then return
    for i = 0 to list.Count() - 1
        got = list[i]
        want = c.candidates[i]
        at = label + " [" + want.id + "]"
        NxCheck(r, at + " title", got.title, want.title)
        NxCheck(r, at + " counts", NxClCounts(got), NxClCounts(want))
        keys = []
        for each it in got.items
            keys.Push(NxFranchiseItemKey(it))
        end for
        NxCheck(r, at + " items", keys.Join(","), NxClJoin(want.items))
        NxCheck(r, at + " enabled", NxClBool(got.enabled), NxClBool(want.enabled))
        NxCheck(r, at + " matchedChannel", NxClOrNull(got.matchedChannel), NxClOrNull(want.matchedChannel))
        NxCheck(r, at + " contentOverlap", NxClOverlap(got.contentOverlap), NxClOverlap(want.contentOverlap))
        NxCheck(r, at + " foldedInto", NxClOrNull(got.foldedInto), NxClOrNull(want.foldedInto))
        NxCheck(r, at + " warning", NxClOrNull(NxCollectionsDuplicateWarning(got)), NxClOrNull(want.warning))
        NxCheck(r, at + " summary", NxCollectionsMemberSummary(got), want.summary)
    end for
    m0 = NxCollectionsMaterialize(list)
    NxCheck(r, label + ": overCap", m0.overCap.ToStr(), NxToStr(c.materialized.overCap))
    NxCheck(r, label + ": channel count", m0.channels.Count().ToStr(), c.materialized.channels.Count().ToStr())
    if m0.channels.Count() <> c.materialized.channels.Count() then return
    for i = 0 to m0.channels.Count() - 1
        got = m0.channels[i]
        want = c.materialized.channels[i]
        keys = []
        for each it in got.pool
            keys.Push(NxFranchiseItemKey(it))
        end for
        NxCheck(r, label + ": channel " + i.ToStr(), NxClChannel(got.id, got.number, got.name, got.colorHex, got.minItems, got.enabled, got.collectionID, keys.Join(",")), NxClChannel(want.id, want.number, want.name, want.colorHex, want.minItems, want.enabled, want.collectionID, NxClJoin(want.pool)))
    end for
end sub

' ── Upstream's Swift cases ──────────────────────────────────────────────────

sub NxClSwiftCases(r as Object, config as Object, defs as Object)
    ' CollectionShowsTests.testShowCollectionDoesNotFoldIntoAFilmsOnlyFranchise
    films = [NxClFilm("m1", "Star Wars"), NxClFilm("m2", "The Empire Strikes Back"), NxClFilm("m3", "Return of the Jedi")]
    mando = NxClEpisodes("The Mandalorian", "s1", 4)
    filmsOnlyTarget = NxCollectionFoldTarget("STAR WARS", films, invalid, invalid)
    mixedItems = []
    mixedItems.Append(films)
    mixedItems.Append(mando)
    mixed = NxClCollection("mixed", "STAR WARS", mixedItems, "STAR WARS")
    NxCheck(r, "swift: a show the target lacks", NxClBool(NxCollectionCarriesEveryShow(mixed, filmsOnlyTarget)), "false")
    withShowItems = []
    withShowItems.Append(films)
    withShowItems.Push(mando[2])
    withShow = NxCollectionFoldTarget("STAR WARS", withShowItems, invalid, invalid)
    NxCheck(r, "swift: one episode of the show is enough", NxClBool(NxCollectionCarriesEveryShow(mixed, withShow)), "true")
    filmsOnly = NxClCollection("films", "STAR WARS", films, invalid)
    NxCheck(r, "swift: films-only collections fold as before", NxClBool(NxCollectionCarriesEveryShow(filmsOnly, filmsOnlyTarget)), "true")

    ' CollectionShowsTests.testFoldsKeepsAMixedCollectionWhoseShowsTheFranchiseLacks
    films = [NxClFilm("m1", "John Wick"), NxClFilm("m2", "John Wick: Chapter 2"), NxClFilm("m3", "Parabellum")]
    continental = NxClEpisodes("The Continental", "s1", 3)
    label = "CH 104 JOHN WICK"
    target = NxCollectionFoldTarget(label, films, invalid, 104)
    mixedItems = []
    mixedItems.Append(films)
    mixedItems.Append(continental)
    mixed = NxClCollection("mixed", "JOHN WICK", mixedItems, label)
    filmsOnly = NxClCollection("films", "JOHN WICK", films, label)
    NxCheck(r, "swift: films-only folds on the name match", NxClOrNull(NxCollectionFold(filmsOnly, [target], [])), label)
    NxCheck(r, "swift: the mix stays its own channel", NxClOrNull(NxCollectionFold(mixed, [target], [])), "null")
    airsItems = []
    airsItems.Append(films)
    airsItems.Append(continental)
    airsShow = NxCollectionFoldTarget(label, airsItems, invalid, 104)
    NxCheck(r, "swift: the mix folds once the channel airs the show", NxClOrNull(NxCollectionFold(mixed, [airsShow], [])), label)

    ' FranchiseSettingsTests.testCollectionThatIsAFranchiseIsHiddenFromBothLists,
    ' through the franchise step and the collections step as the library load
    ' runs them. Star Wars, John Wick and Tom Hanks films, with the fixture
    ' enrichment; three collections, all switched on.
    t = { config: config, defs: defs }
    items = NxFgFilms(NxFgStarWars())
    items.Append(NxFgFilms(NxFgWick()))
    items.Append(NxFgFilms(NxFgHanks()))
    raw = [
        NxClRaw0("c-sw", "STAR WARS COLLECTION", ["sw1", "sw2", "sw3"]),
        NxClRaw0("c-wick", "JOHN WICK COLLECTION", ["w1", "w2", "w3"]),
        NxClRaw0("c-hanks", "TOM HANKS", ["t1", "t2", "t3"])
    ]
    on = NxCollectionKeySet(["0:c-sw", "0:c-wick", "0:c-hanks"])
    s = NxFgStep(t, items, NxFranchiseChoices([], []))
    NxCheck(r, "swift fold: star wars is covered by CH 100", NxFgFoundNames(s), "JOHN WICK")
    cs = NxClStep(t, s, items, raw, on)
    starWars = "CH " + NxClLiveNumber(config, 100) + " STAR WARS"
    NxCheck(r, "swift fold: star wars folds into the classic", NxClFoldedInto(cs, "STAR WARS COLLECTION"), starWars)
    NxCheck(r, "swift fold: john wick folds into the found franchise", NxClFoldedInto(cs, "JOHN WICK COLLECTION"), "JOHN WICK")
    NxCheck(r, "swift fold: the actor set stays listed", NxClRowIDs(cs), "0:c-hanks")
    NxCheck(r, "swift fold: only the actor set becomes a channel", NxClChannelNames(cs), "TOM HANKS")
    NxCheck(r, "swift fold: from CH 400", NxClChannelNumbers(cs), "400")
    NxCheck(r, "swift fold: row shows its channel", NxToStr(cs.rows[0].channelNumber), "400")
    NxCheck(r, "swift fold: row detail", cs.rows[0].detail, "3 movies")
    ' Turning the found franchise on gives exactly one JOHN WICK channel.
    s = NxFgStep(t, items, NxFranchiseChoices(["dict:JOHN WICK"], []))
    cs = NxClStep(t, s, items, raw, on)
    NxCheck(r, "swift fold: john wick on, one channel", NxFgChannelNames(s) + "|" + NxClChannelNames(cs), "JOHN WICK|TOM HANKS")
    NxCheck(r, "swift fold: still folded while it is on", NxClFoldedInto(cs, "JOHN WICK COLLECTION"), "JOHN WICK")

    ' With the FRANCHISES package off nothing folds here (upstream folds into
    ' found franchises even then; docs/PORTING.md), so every collection is
    ' listed and the switched-on ones air: the two movie series in their own
    ' franchise block from CH 310, the actor set from CH 400.
    cs = NxCollectionsStep({ channels: NxClStockChannels(t, items), raw: raw, items: items, serverKeys: {}, manifest: invalid, enabledKeys: on })
    NxCheck(r, "package off: no folds", NxClRowIDs(cs), "0:c-wick,0:c-sw,0:c-hanks")
    NxCheck(r, "package off: three channels", NxClChannelNames(cs) + "|" + NxClChannelNumbers(cs), "JOHN WICK COLLECTION,STAR WARS COLLECTION,TOM HANKS|310,311,400")
    NxCheck(r, "package off: name match warns", cs.rows[1].detail, "Exists: " + starWars)

    ' testFranchiseCollectionsAndFoundFranchisesInterleaveByName, through the
    ' steps as the library load runs them: PADDINGTON TRILOGY (a movie series
    ' no franchise holds) keeps its id and sorts among the found franchises by
    ' name; TOM HANKS never moves.
    lib = NxFgFilms(NxFgWick())
    lib.Append(NxFgFilms(NxFgHunger()))
    paddington = NxClFilms(["Paddington", "Paddington 2", "Paddington in Peru"])
    for each it in paddington
        it.serverIndex = 0
    end for
    lib.Append(paddington)
    lib.Append(NxFgFilms(NxFgHanks()))
    rawSplit = [
        NxClRaw0("c-pad", "Paddington Trilogy", ["Paddington", "Paddington 2", "Paddington in Peru"]),
        NxClRaw0("c-hanks", "TOM HANKS", ["t1", "t2", "t3"])
    ]
    onSplit = NxCollectionKeySet(["0:c-pad", "0:c-hanks"])
    pkgOff = NxCollectionsStep({ channels: [], raw: rawSplit, items: lib, serverKeys: {}, manifest: invalid, enabledKeys: onSplit })
    NxCheck(r, "switch: package off, the collection starts the block", NxClNumbersAndIDs(pkgOff), "PADDINGTON TRILOGY=franchises CH 310 id 1010000;TOM HANKS=custom CH 400 id 1020000")
    s = NxFgStep(t, lib, NxFranchiseChoices(["dict:JOHN WICK", "dict:THE HUNGER GAMES"], []))
    NxCheck(r, "switch: two found franchises on", NxFgChannelNames(s), "JOHN WICK,THE HUNGER GAMES")
    pkgOn = NxClStep(t, s, lib, rawSplit, onSplit)
    NxCheck(r, "switch: package on, two found on", NxClNumbersAndIDs(pkgOn), "PADDINGTON TRILOGY=franchises CH 311 id 1010000;TOM HANKS=custom CH 400 id 1020000")
    NxCheck(r, "switch: the found ones around it", NxClFoundNumbers(pkgOn), "JOHN WICK@310;THE HUNGER GAMES@312")
    NxCheck(r, "switch: rows show the numbers", NxClRowNumbers(pkgOn), "PADDINGTON TRILOGY@311;TOM HANKS@400")
    pkgOn = NxClStep(t, NxFgStep(t, lib, NxFranchiseChoices(["dict:JOHN WICK"], [])), lib, rawSplit, onSplit)
    NxCheck(r, "switch: one found switched off", NxClNumbersAndIDs(pkgOn) + "|" + NxClFoundNumbers(pkgOn), "PADDINGTON TRILOGY=franchises CH 311 id 1010000;TOM HANKS=custom CH 400 id 1020000|JOHN WICK@310")

    ' FranchiseCollectionFold step 4: a collection whose name says nothing
    ' folds into a found franchise that already airs most of it.
    s = NxFgStep(t, items, NxFranchiseChoices([], []))
    cs = NxClStep(t, s, items, [NxClRaw0("c-keanu", "KEANU NIGHTS", ["w1", "w2", "w3", "t1"])], on)
    NxCheck(r, "swift fold: 3 of 4 already in JOHN WICK", NxClFoldedInto(cs, "KEANU NIGHTS"), "JOHN WICK")

    ' Collections that hold shows, through the step: a show expands to its
    ' episodes, a Plex child that is a show key.
    eps = NxClEpisodes("Alpha Island", "s1", 4)
    eps.Append(NxClEpisodes("Bravo Kitchen", "s2", 5))
    for each it in eps
        it.serverIndex = 0
    end for
    lib = []
    lib.Append(items)
    lib.Append(eps)
    cs = NxCollectionsStep({ channels: NxClStockChannels(t, lib), raw: [{ id: "mid:tv", title: "Reality TV", childKeys: ["s1", "s2"], serverKey: "mid" }], items: lib, serverKeys: { "0": "mid" }, manifest: invalid, enabledKeys: NxCollectionKeySet(["mid:tv"]) })
    NxCheck(r, "shows: server key from the map", NxClRowIDs(cs), "mid:tv")
    NxCheck(r, "shows: detail", cs.rows[0].detail, "2 shows " + Chr(183) + " 9 episodes")
    NxCheck(r, "shows: the channel airs every episode", cs.channels[0].pool.Count().ToStr(), "9")
end sub

' The stock channels of the FRANCHISES package, built as the library load
' builds them, with minItems.
function NxClStockChannels(t as Object, items as Object) as Object
    s = NxFgStep(t, items, NxFranchiseChoices([], []))
    for each ch in s.stock
        for each def in t.config.channels
            if def.id = ch.id then ch.minItems = def.minItems
        end for
    end for
    return s.stock
end function

' ── CollectionClassifierTests.swift and CollectionShowsTests.swift ─────────

sub NxClClassifierCases(r as Object)
    ' testGeneratedListCollectionsAreCustom
    for each name in ["Anilist Popular", "IMDb Popular", "TMDb Popular", "Plex Popular", "MyAnimeList Favorited", "MyAnimeList Top Rated", "Anilist Top Rated", "Trakt Trending", "Letterboxd Top 250", "Recently Added"]
        NxCheck(r, "classify: " + name + " is a generated list", NxCollectionClassify(name, []), "custom")
    end for
    ' testPersonNamesAreCustom
    NxCheck(r, "classify: Tom Hanks, no films", NxCollectionClassify("Tom Hanks", []), "custom")
    NxCheck(r, "classify: Christopher Nolan, no films", NxCollectionClassify("Christopher Nolan", []), "custom")
    ' testFranchisesStillDetected
    NxCheck(r, "classify: James Bond Collection", NxCollectionClassify("James Bond Collection", []), "franchises")
    topGun = NxClFilms(["Top Gun", "Top Gun: Maverick", "Top Gun II"])
    NxCheck(r, "classify: Top Gun repeats a word", NxCollectionClassify("Top Gun Collection", topGun), "franchises")
    ' testFranchiseNamedLikeAPersonIsAFranchise
    wick = NxClFilms(["John Wick", "John Wick: Chapter 2", "Parabellum"])
    NxCheck(r, "classify: John Wick, name in two titles", NxCollectionClassify("John Wick", wick), "franchises")
    hunger = NxClFilms(["The Hunger Games", "Catching Fire", "The Hunger Games: Mockingjay - Part 1"])
    NxCheck(r, "classify: Hunger Games", NxCollectionClassify("Hunger Games", hunger), "franchises")
    ' testPersonCollectionsAreNotFranchises
    hanks = NxClFilms(["Big", "Cast Away", "Forrest Gump"])
    NxCheck(r, "classify: Tom Hanks films", NxCollectionClassify("Tom Hanks", hanks), "custom")
    jackson = NxClFilms(["Michael Jackson's This Is It", "Thriller", "Moonwalker"])
    NxCheck(r, "classify: Michael Jackson Collection", NxCollectionClassify("Michael Jackson Collection", jackson), "custom")
    ' testSharedFranchiseIDForcesFranchise
    night = NxClFilms(["Alpha", "Bravo", "Charlie"])
    NxCheck(r, "classify: Movie Night without enrichment", NxCollectionClassify("Movie Night", night), "custom")
    for each it in night
        it.enrichment = { franchiseID: 777 }
    end for
    NxCheck(r, "classify: Movie Night sharing a TMDB collection", NxCollectionClassify("Movie Night", night), "franchises")
    ' testGeneratedListBeatsFranchiseID
    batman = NxClFilms(["Batman Begins", "The Dark Knight"])
    for each it in batman
        it.enrichment = { franchiseID: 263 }
    end for
    NxCheck(r, "classify: IMDb Popular beats a shared TMDB collection", NxCollectionClassify("IMDb Popular", batman), "custom")
    ' testSingleFranchiseIDItemIsNotEnoughForFranchise
    solo = NxClFilms(["Solo Outing", "Different Movie"])
    solo[0].enrichment = { franchiseID: 500 }
    NxCheck(r, "classify: one film with a TMDB collection", NxCollectionClassify("Random Set", solo), "custom")
    ' CollectionShowsTests.testShowCollectionsAreNeverFranchises
    NxCheck(r, "classify: a show's episodes", NxCollectionClassify("Reality TV", NxClEpisodes("Survivor", "s1", 30)), "custom")
    trek = NxClEpisodes("Star Trek: The Next Generation", "s2", 8)
    trek.Append(NxClEpisodes("Star Trek: Voyager", "s3", 8))
    NxCheck(r, "classify: Star Trek Saga of shows", NxCollectionClassify("Star Trek Saga", trek), "custom")
    ' CollectionShowsTests.testMixedCollectionClassifiesOnItsFilms
    mixed = NxClFilms(["John Wick", "John Wick: Chapter 2", "Parabellum"])
    mixed.Append(NxClEpisodes("The Continental", "s1", 3))
    NxCheck(r, "classify: a mix on its films (John Wick)", NxCollectionClassify("John Wick", mixed), "franchises")
    band = NxClFilms(["Big", "Cast Away"])
    band.Append(NxClEpisodes("Band of Brothers", "s2", 10))
    NxCheck(r, "classify: a mix on its films (Tom Hanks)", NxCollectionClassify("Tom Hanks", band), "custom")

    ' The rest of upstream's rules, one case each.
    NxCheck(r, "classify: a franchise keyword", NxCollectionClassify("The Godfather Trilogy", NxClFilms(["The Godfather", "Part II", "Part III"])), "franchises")
    NxCheck(r, "classify: a shared title prefix", NxCollectionClassify("Go", NxClFilms(["Go Go", "Go Gone", "Go Goal"])), "franchises")
    NxCheck(r, "classify: punctuation trimmed from words", NxCollectionClassify("Set", NxClFilms(["Rocky", "Rocky II", "Rocky...", "Creed"])), "franchises")
    NxCheck(r, "classify: a curly 's is dropped", NxCollectionClassify("Rocky" + Chr(8217) + "s Story", NxClFilms(["Rocky Story", "Rocky Story II", "Other"])), "franchises")
    ' Upstream drops "'s" before its list, so this one misses "child's play".
    NxCheck(r, "classify: Child's Play Collection, as upstream", NxCollectionClassify("Child's Play Collection", []), "custom")
    NxCheck(r, "classify: stop words don't count", NxCollectionClassify("Mixed", NxClFilms(["The One", "The Two", "The Three"])), "custom")
end sub

' One film per title, keyed by its title.
function NxClFilms(titles as Object) as Object
    out = []
    for each t in titles
        out.Push(NxClFilm(t, t))
    end for
    return out
end function

' ── FranchiseNumberingTests.swift: the franchise block ──────────────────────
' Every franchise channel is in the 300s since 1.0.29: found franchises (ids
' from 1,000,000) and franchise collections (ids from 1,010,000) share CH
' 310-399 as one pool, numbered A to Z; other collections own CH 400-499 (ids
' from 1,020,000). Before: 300-449, 450-499, 500-699, then for a while
' 310-399, 400-449, 450-499. Transcribed from the Apple TV's
' FranchiseNumberingTests at renumber/franchise-block; XCTest cases, so there
' is no JS vector.

sub NxClSplitCases(r as Object)
    ' testRangesSitClearOfEveryShippedNumber / testEachKindHasItsOwnFixedIDBase
    NxCheck(r, "blocks: found franchises", NxFranchiseNumberBase().ToStr() + "-" + (NxFranchiseNumberBase() + NxFranchiseCapacity() - 1).ToStr() + " from " + NxFranchiseIDBase().ToStr(), "310-399 from 1000000")
    NxCheck(r, "blocks: franchise collections share it", NxCollectionFranchiseNumberBase().ToStr() + "-" + (NxCollectionFranchiseNumberBase() + NxCollectionFranchiseCapacity() - 1).ToStr() + " from " + NxCollectionFranchiseIDBase().ToStr(), "310-399 from 1010000")
    NxCheck(r, "blocks: other collections", NxCollectionsNumberBase().ToStr() + "-" + (NxCollectionsNumberBase() + NxCollectionsCapacity() - 1).ToStr() + " from " + NxCollectionsIDBase().ToStr(), "400-499 from 1020000")

    ' testEightySixFranchisesAndTwoFranchiseCollectionsShareCH310Through397
    found = []
    for i = 0 to 85
        found.Push(NxClFoundN(i, true, 3))
    end for
    fb = NxFranchiseBlock(found)
    cands = [
        NxClCandidate("saga-a", "franchises", true), NxClCandidate("saga-b", "franchises", true),
        NxClCandidate("hanks", "custom", true), NxClCandidate("nolan", "custom", true),
        NxClCandidate("off", "custom", false)
    ]
    mz = NxCollectionsMaterialize(cands, fb)
    NxCheck(r, "86 found: 310-395", NxClNumberRange(mz.found) + " " + fb.skipped.ToStr() + " " + mz.overCapFound.ToStr(), "310-395 0 0")
    NxCheck(r, "86 found: franchise collections after them by name", NxClNumbersOf(mz.channels, "franchises") + " ids " + NxClIDsOf(mz.channels, "franchises"), "396,397 ids 1010000,1010001")
    NxCheck(r, "86 found: other collections", NxClNumbersOf(mz.channels, "custom") + " ids " + NxClIDsOf(mz.channels, "custom"), "400,401 ids 1020000,1020001")
    NxCheck(r, "86 found: nothing over", NxToStr(mz.overCap), "0")

    ' testFoundFranchisesKeepTheirIDs
    fb = NxFranchiseBlock([NxClFoundN(0, true, 3), NxClFoundN(1, true, 3), NxClFoundN(2, true, 3)])
    mz = NxCollectionsMaterialize([], fb)
    ids = []
    for each ch in mz.found
        ids.Push(ch.id.ToStr())
    end for
    NxCheck(r, "found franchises keep their ids", ids.Join(","), "1000000,1000001,1000002")

    ' testFranchiseBlockIsCappedAt399AndKeepsTheBiggestOfBothKinds: 94 found
    ' (five with 3 films) and two franchise collections (5 and 3 films); the
    ' six 3-film ones wait, whatever their kind.
    found = []
    for i = 0 to 93
        films = 4
        if i < 5 then films = 3
        found.Push(NxClFoundN(i, true, films))
    end for
    fb = NxFranchiseBlock(found)
    cands = [NxClCandidateN("saga-a", "franchises", true, 5), NxClCandidateN("saga-b", "franchises", true, 3), NxClCandidate("hanks", "custom", true)]
    mz = NxCollectionsMaterialize(cands, fb)
    names = []
    for each ch in mz.found
        names.Push(ch.name)
    end for
    NxCheck(r, "franchise block full: 89 found, 310-398", mz.found.Count().ToStr() + " " + NxClNumberRange(mz.found), "89 310-398")
    NxCheck(r, "franchise block full: A to Z", NxClBool(NxClSortedSwift(names)), "true")
    NxCheck(r, "franchise block full: the 3-film ones wait", NxClBool(NxHasValue(names, "FRANCHISE 000") or NxHasValue(names, "FRANCHISE 004")), "false")
    NxCheck(r, "franchise block full: the 5-film collection stays", NxClChannelNamesOf(mz.channels, "franchises") + "@" + NxClNumbersOf(mz.channels, "franchises"), "SAGA-A@399")
    NxCheck(r, "franchise block full: counted per kind", (fb.skipped + mz.overCapFound).ToStr() + "/" + NxToStr(mz.overCapFranchises), "5/1")
    NxCheck(r, "franchise block full: other collections keep their numbers", NxClNumbersOf(mz.channels, "custom"), "400")
    for i = 5 to 10
        found[i].enabled = false
    end for
    fb = NxFranchiseBlock(found)
    mz = NxCollectionsMaterialize(cands, fb)
    NxCheck(r, "franchise block: switching some off frees it", NxToStr(fb.skipped + mz.overCapFound + mz.overCapFranchises) + " " + NxToStr(mz.found.Count() + 2) + " " + NxClNumbersOf(mz.channels, "franchises"), "0 90 398,399")

    ' testFranchiseCollectionsAloneFillTheBlockAndKeepTheBiggest: 93 on,
    ' three with 3 films, the rest 5; ties on films go by name, then id.
    cands = []
    for i = 0 to 92
        films = 5
        if i = 7 or i = 20 or i = 41 then films = 3
        cands.Push(NxClCandidateN("saga-" + Right("0" + i.ToStr(), 2), "franchises", true, films))
    end for
    mz = NxCollectionsMaterialize(cands)
    kept = []
    for each ch in mz.channels
        if ch.category = "franchises" then kept.Push(ch.name)
    end for
    NxCheck(r, "collections alone: 310-399", NxClNumbersOf(mz.channels, "franchises"), NxClSeq(310, 399))
    NxCheck(r, "collections alone: ids", NxClIDsOf(mz.channels, "franchises"), NxClSeq(1010000, 1010089))
    NxCheck(r, "collections alone: the 3-film ones wait", NxClBool(NxHasValue(kept, "SAGA-07") or NxHasValue(kept, "SAGA-20") or NxHasValue(kept, "SAGA-41")), "false")
    NxCheck(r, "collections alone: A to Z", NxClBool(NxClSortedSwift(kept)), "true")
    NxCheck(r, "collections alone: three over, nothing spills", NxToStr(mz.overCapFranchises) + "/" + NxToStr(mz.overCapCustom) + " " + NxClNumbersOf(mz.channels, "custom"), "3/0 ")

    ' testOverflowOrderIsFilmsThenNameThenStableID
    entries = [
        { id: "b", name: "SAME", films: 4 }, { id: "a", name: "SAME", films: 4 },
        { id: "z", name: "ZED", films: 9 }, { id: "c", name: "ALPHA", films: 4 },
        { id: "d", name: "SMALL", films: 2 }
    ]
    NxCheck(r, "overflow order: kept, numbered A to Z", NxClKeptIDs(entries, 3), "c,a,z skipped 2")
    NxCheck(r, "overflow order: under capacity, A to Z", NxClKeptIDs(entries, 10), "c,a,b,d,z skipped 0")
    reversed = []
    for i = entries.Count() - 1 to 0 step -1
        reversed.Push(entries[i])
    end for
    NxCheck(r, "overflow order: input order never matters", NxClKeptIDs(reversed, 3), "c,a,z skipped 2")
    ' Swift's `<`: case-sensitive by code point (upper case before lower),
    ' digits as characters. Checked on the TV by the on-device suite.
    swift = [
        { id: "1", name: "alpha", films: 3 }, { id: "2", name: "Zed", films: 3 },
        { id: "3", name: "SAW 2", films: 3 }, { id: "4", name: "SAW 10", films: 3 }, { id: "5", name: "ZED", films: 3 }
    ]
    NxCheck(r, "swift order: case-sensitive, digits as characters", NxClKeptIDs(swift, 10), "4,3,5,2,1 skipped 0")

    ' Swift compares Strings by canonical equivalence (NFC) and uppercases
    ' with Unicode's mappings. A precomposed É (U+00C9) and E + a combining
    ' acute (U+0301) are the same name to Swift, so the id breaks the tie;
    ' raw code units would put the decomposed one first. É (U+00C9) sorts
    ' after F by scalar. Expected values from running the same comparisons
    ' in Swift 6 (sorted ids c,d,a,b; the two names ==; uppercased()).
    precomposed = "CAF" + Chr(201)
    decomposed = "CAFE" + Chr(769)
    accents = [
        { id: "b", name: decomposed, films: 3 }, { id: "a", name: precomposed, films: 3 },
        { id: "c", name: "CAFE", films: 3 }, { id: "d", name: "CAFF", films: 3 }
    ]
    NxCheck(r, "unicode: precomposed and decomposed are one name", NxClKeptIDs(accents, 10), "c,d,a,b skipped 0")
    NxCheck(r, "unicode: NFC key", NxClBool(NxBlockNameKey(decomposed) = precomposed), "true")
    NxCheck(r, "unicode: uppercase", NxFranchiseUpper("am" + Chr(233) + "lie, stra" + Chr(223) + "e, " + Chr(1076) + Chr(1086) + Chr(1084) + ", " + Chr(940)), "AM" + Chr(201) + "LIE, STRASSE, " + Chr(1044) + Chr(1054) + Chr(1052) + ", " + Chr(902))
    NxCheck(r, "unicode: uppercase leaves the rest", NxFranchiseUpper("abc 123 " + Chr(201) + " " + Chr(8364)), "ABC 123 " + Chr(201) + " " + Chr(8364))
    ' Through the step: a lowercase accented server title is upper-cased as
    ' Swift's collection.title.uppercased().
    films = NxClFilms(["Am" + Chr(233) + "lie 1", "Am" + Chr(233) + "lie 2", "Am" + Chr(233) + "lie 3"])
    for each it in films
        it.serverIndex = 0
    end for
    cs = NxCollectionsStep({ channels: [], raw: [NxClRaw0("am", "am" + Chr(233) + "lie", ["Am" + Chr(233) + "lie 1", "Am" + Chr(233) + "lie 2", "Am" + Chr(233) + "lie 3"])], items: films, serverKeys: {}, manifest: invalid, enabledKeys: NxCollectionKeySet(["0:am"]) })
    NxCheck(r, "unicode: collection title upper-cased", cs.rows[0].title, "AM" + Chr(201) + "LIE")

    ' testCollectionRangeIsCappedAt499: unchanged rule, the first 100 A to Z.
    cands = []
    for i = 0 to 102
        cands.Push(NxClCandidate("set-" + Right("00" + i.ToStr(), 3), "custom", true))
    end for
    mz = NxCollectionsMaterialize(cands)
    NxCheck(r, "other block: 100, from 400, the last on 499", mz.channels.Count().ToStr() + "|" + NxToStr(mz.channels[0].number) + "|" + NxToStr(mz.channels[99].number) + "|" + mz.channels[99].name, "100|400|499|SET-099")
    NxCheck(r, "other block: three past 499", NxToStr(mz.overCapCustom), "3")

    ' The step: a movie series numbered with the found franchises, A to Z, an
    ' actor set from 400, each row carrying its category.
    wick = NxClFilms(["John Wick", "John Wick: Chapter 2", "Parabellum"])
    hanks = NxClFilms(["Big", "Cast Away", "Forrest Gump"])
    lib = []
    lib.Append(wick)
    lib.Append(hanks)
    for each it in lib
        it.serverIndex = 0
    end for
    raw = [
        NxClRaw0("wick", "John Wick", ["John Wick", "John Wick: Chapter 2", "Parabellum"]),
        NxClRaw0("hanks", "Tom Hanks", ["Big", "Cast Away", "Forrest Gump"]),
        NxClRaw0("spare", "Tom Hanks Too", ["Big", "Cast Away", "Forrest Gump"])
    ]
    found = [NxClFound(0, true), NxClFound(1, true), NxClFound(2, false)]
    fb = NxFranchiseBlock(found)
    fr = { channels: fb.channels, kept: fb.kept, found: [] }
    cs = NxCollectionsStep({ channels: [], raw: raw, items: lib, serverKeys: {}, manifest: invalid, enabledKeys: NxCollectionKeySet(["0:wick", "0:hanks"]), franchise: fr, franchiseBundleIDs: [], defs: [] })
    NxCheck(r, "split step: channels", NxClChannelNames(cs) + "|" + NxClChannelNumbers(cs), "JOHN WICK,TOM HANKS|312,400")
    rows = []
    for each row in cs.rows
        rows.Push(row.title + "=" + NxToStr(row.category) + "@" + NxClOrNull(row.channelNumber))
    end for
    NxCheck(r, "split step: rows", rows.Join(";"), "JOHN WICK=franchises@312;TOM HANKS=custom@400;TOM HANKS TOO=custom@null")
    NxCheck(r, "split step: overCap by block", NxToStr(cs.overCapFranchises) + "/" + NxToStr(cs.overCapCustom), "0/0")
end sub

function NxClNumbersAndIDs(cs as Object) as String
    out = []
    for each ch in cs.channels
        out.Push(ch.name + "=" + NxToStr(ch.category) + " CH " + NxToStr(ch.number) + " id " + NxToStr(ch.id))
    end for
    return out.Join(";")
end function

function NxClFoundNumbers(cs as Object) as String
    out = []
    for each ch in cs.found
        out.Push(ch.name + "@" + NxToStr(ch.number))
    end for
    return out.Join(";")
end function

function NxClChannelNamesOf(channels as Object, category as String) as String
    out = []
    for each ch in channels
        if NxToStr(ch.category) = category then out.Push(ch.name)
    end for
    return out.Join(",")
end function

function NxClRowNumbers(cs as Object) as String
    out = []
    for each row in cs.rows
        out.Push(row.title + "@" + NxClOrNull(row.channelNumber))
    end for
    return out.Join(";")
end function

function NxClFoundN(i as Integer, enabled as Boolean, films as Integer) as Object
    list = []
    for k = 1 to films
        list.Push(NxClFilm("f" + i.ToStr() + "-" + k.ToStr(), "f" + i.ToStr() + " " + k.ToStr()))
    end for
    return { id: "tmdb:" + (10000 + i).ToStr(), name: "FRANCHISE " + Right("00" + i.ToStr(), 3), movies: list, tvItems: [], coveredByChannelID: invalid, fromDictionary: false, enabled: enabled }
end function

function NxClCandidateN(id as String, category as String, enabled as Boolean, films as Integer) as Object
    list = []
    for k = 1 to films
        list.Push(NxClFilm(id + "-" + k.ToStr(), id + " " + k.ToStr()))
    end for
    return { id: id, title: UCase(id), items: list, movieCount: films, enabled: enabled, foldedInto: invalid, category: category }
end function

function NxClIDsOf(channels as Object, category as String) as String
    out = []
    for each ch in channels
        if NxToStr(ch.category) = category then out.Push(NxToStr(ch.id))
    end for
    return out.Join(",")
end function

function NxClSeq(a as Integer, b as Integer) as String
    out = []
    for i = a to b
        out.Push(i.ToStr())
    end for
    return out.Join(",")
end function

' Whether names are in Swift's `<` order (NxBlockLess on names alone).
function NxClSortedSwift(names as Object) as Boolean
    for i = 1 to names.Count() - 1
        if names[i] < names[i - 1] then return false
    end for
    return true
end function

function NxClKeptIDs(entries as Object, capacity as Integer) as String
    wrapped = []
    for each e in entries
        wrapped.Push({ name: e.name, id: e.id, films: e.films, value: e })
    end for
    k = NxBlockKept(wrapped, capacity)
    ids = []
    for each e in k.kept
        ids.Push(e.id)
    end for
    return ids.Join(",") + " skipped " + k.skipped.ToStr()
end function

function NxClFound(i as Integer, enabled as Boolean) as Object
    films = []
    for k = 1 to 3
        films.Push(NxClFilm("f" + i.ToStr() + "-" + k.ToStr(), "f" + i.ToStr() + " " + k.ToStr()))
    end for
    return { name: "FRANCHISE " + i.ToStr(), movies: films, tvItems: [], coveredByChannelID: invalid, fromDictionary: false, enabled: enabled }
end function

function NxClCandidate(id as String, category as String, enabled as Boolean) as Object
    films = []
    for k = 1 to 3
        films.Push(NxClFilm(id + "-" + k.ToStr(), id + " " + k.ToStr()))
    end for
    return { id: id, title: UCase(id), items: films, movieCount: films.Count(), enabled: enabled, foldedInto: invalid, category: category }
end function

function NxClNumberRange(channels as Object) as String
    if channels.Count() = 0 then return ""
    return NxToStr(channels[0].number) + "-" + NxToStr(channels[channels.Count() - 1].number)
end function

function NxClNumbersOf(channels as Object, category as String) as String
    out = []
    for each ch in channels
        if NxToStr(ch.category) = category then out.Push(NxToStr(ch.number))
    end for
    return out.Join(",")
end function

function NxClStep(t as Object, s as Object, items as Object, raw as Object, on as Object) as Object
    bundleIDs = []
    for each b in t.config.bundles
        if b.id = NxFranchisesBundleID() then bundleIDs = b.channelIDs
    end for
    for each ch in s.stock
        for each def in t.config.channels
            if def.id = ch.id then ch.minItems = def.minItems
        end for
    end for
    channels = []
    channels.Append(s.stock)
    channels.Append(s.channels)
    return NxCollectionsStep({
        channels: channels, raw: raw, items: items, serverKeys: {}, manifest: invalid, enabledKeys: on,
        franchise: s, franchiseBundleIDs: bundleIDs, defs: t.defs
    })
end function

function NxClRaw0(id as String, title as String, childKeys as Object) as Object
    return { id: "0:" + id, title: title, childKeys: childKeys, serverKey: "0" }
end function

function NxClFoldedInto(cs as Object, title as String) as String
    for each f in cs.folded
        if f.title = title then return f.into
    end for
    return "null"
end function

function NxClRowIDs(cs as Object) as String
    out = []
    for each row in cs.rows
        out.Push(row.id)
    end for
    return out.Join(",")
end function

function NxClChannelNames(cs as Object) as String
    out = []
    for each ch in cs.channels
        out.Push(ch.name)
    end for
    return out.Join(",")
end function

function NxClChannelNumbers(cs as Object) as String
    out = []
    for each ch in cs.channels
        out.Push(ch.number.ToStr())
    end for
    return out.Join(",")
end function

' ── Fixtures, as CollectionShowsTests.swift has them ────────────────────────

function NxClFilm(key as String, title as String) as Object
    return { ratingKey: key, serverIndex: "", title: title, type: "movie", duration: 100, librarySource: "movie", genres: [] }
end function

' `count` episodes of one show, keys "<showKey>-e<n>".
function NxClEpisodes(show as String, showKey as String, count as Integer) as Object
    out = []
    for i = 1 to count
        out.Push({ ratingKey: showKey + "-e" + i.ToStr(), serverIndex: "", title: show, showKey: showKey, type: "episode", duration: 22, librarySource: "tv", genres: [] })
    end for
    return out
end function

function NxClCollection(id as String, title as String, items as Object, matched as Dynamic) as Object
    return { id: id, title: title, items: items, matchedChannel: matched, contentOverlap: invalid }
end function

' ── Comparison helpers ──────────────────────────────────────────────────────

function NxClStubFetcher(docs as Object) as Object
    return {
        docs: docs, calls: [],
        getJSON: function(path as String, win = invalid as Dynamic) as Dynamic
            m.calls.Push(path)
            if m.docs.DoesExist(path) then return m.docs[path]
            return invalid
        end function
    }
end function

' The number channels.json gives the channel with this id, as text. The Swift
' cases make their own channels (Channel(id: 100, number: 100)); these build
' the stock channels from the real channels.json, whose numbers are not its ids
' (the three 80s channels took CH 20 to 22 on 2026-10-29 and every later
' channel moved up by 3), so the label a case expects is read from it too.
function NxClLiveNumber(config as Object, id as Integer) as String
    for each c in config.channels
        if c.id = id then return NxToStr(c.number)
    end for
    return "no channel " + id.ToStr()
end function

function NxClByID(channels as Object) as Object
    out = {}
    for each ch in channels
        out[NxToStr(ch.id)] = ch
    end for
    return out
end function

function NxClOrNull(v as Dynamic) as String
    if v = invalid then return "null"
    return NxToStr(v)
end function

function NxClBool(b as Dynamic) as String
    if b = true then return "true"
    return "false"
end function

function NxClJoin(list as Dynamic) as String
    out = []
    for each x in NxList(list)
        out.Push(NxToStr(x))
    end for
    return out.Join(",")
end function

function NxClField(list as Object, field as String) as String
    out = []
    for each x in list
        out.Push(NxToStr(x[field]))
    end for
    return out.Join(",")
end function

function NxClCounts(c as Object) as String
    return NxToStr(c.movieCount) + "/" + NxToStr(c.showCount) + "/" + NxToStr(c.episodeCount)
end function

function NxClOverlap(o as Dynamic) as String
    if o = invalid then return "null"
    return NxToStr(o.channelID) + "|" + NxToStr(o.channelName) + "|" + NxToStr(o.overlapCount) + "|" + NxToStr(o.totalCount) + "|" + NxToStr(o.percent)
end function

function NxClChannel(id as Dynamic, number as Dynamic, name as Dynamic, colorHex as Dynamic, minItems as Dynamic, enabled as Dynamic, collectionID as Dynamic, pool as String) as String
    return NxToStr(id) + "|" + NxToStr(number) + "|" + NxToStr(name) + "|" + NxToStr(colorHex) + "|" + NxToStr(minItems) + "|" + NxClBool(enabled) + "|" + NxToStr(collectionID) + "|" + pool
end function

' Scanned collections as text.
function NxClRaw(list as Object) as String
    out = []
    for each c in list
        out.Push(NxToStr(c.id) + "=" + NxToStr(c.title) + "@" + NxToStr(c.serverKey) + "[" + NxClJoin(c.childKeys) + "]")
    end for
    return out.Join(";")
end function

' ── Plex paging (#189) ───────────────────────────────────────────────────────

' A server that answers each list in windows, from saved full answers
' (lists: path -> array of rows, listKey per path). It caps a window at `cap`
' when set, as a server may, sends totalSize unless noTotal, ignores the
' start when ignoreStart, and fails the window starting at failAt[path].
' It records every request with its window, and whether it came bare.
function NxClPagingServer(lists as Object, opts as Object) as Object
    return {
        lists: lists, opts: opts, calls: [], bare: 0, sizes: {},
        getJSON: function(path as String, win = invalid as Dynamic) as Dynamic
            if win = invalid then
                m.bare = m.bare + 1
                m.calls.Push(path)
            else
                m.calls.Push(path + " " + NxToStr(win.start) + "+" + NxToStr(win.size))
                m.sizes[path] = win.size
            end if
            if not m.lists.DoesExist(path) then return invalid
            rows = m.lists[path].rows
            if win = invalid then return NxClPagingDoc(m.lists[path].key, rows, rows.Count(), m.opts)
            if m.opts.failAt <> invalid then
                if m.opts.failAt[path] <> invalid then
                    if m.opts.failAt[path] = win.start then return invalid
                end if
            end if
            size = win.size
            if m.opts.cap <> invalid then
                if size > m.opts.cap then size = m.opts.cap
            end if
            start = win.start
            if m.opts.ignoreStart = true then start = 0
            page = []
            for i = start to start + size - 1
                if i < rows.Count() then page.Push(rows[i])
            end for
            return NxClPagingDoc(m.lists[path].key, page, rows.Count(), m.opts)
        end function,
        getMany: function(paths as Object, win = invalid as Dynamic) as Object
            out = []
            for each p in paths
                out.Push(m.getJSON(p, win))
            end for
            return out
        end function
    }
end function

function NxClPagingDoc(key as String, page as Object, total as Integer, opts as Object) as Object
    mc = { size: page.Count() }
    mc[key] = page
    if opts.noTotal <> true then mc.totalSize = total
    return { MediaContainer: mc }
end function

' A movie section with `nCollections` collections; collection 1 has
' `bigKids` children, the rest 3 each.
function NxClPagingLists(nCollections as Integer, bigKids as Integer) as Object
    lists = {}
    lists["/library/sections"] = { key: "Directory", rows: [{ key: "1", type: "movie" }, { key: "2", type: "artist" }] }
    cols = []
    for i = 1 to nCollections
        cols.Push({ ratingKey: (1000 + i).ToStr(), title: "Collection " + i.ToStr() })
        kids = []
        n = 3
        if i = 1 then n = bigKids
        for k = 1 to n
            kids.Push({ ratingKey: (i * 10000 + k).ToStr() })
        end for
        lists["/library/collections/" + (1000 + i).ToStr() + "/children"] = { key: "Metadata", rows: kids }
    end for
    lists["/library/sections/1/collections"] = { key: "Metadata", rows: cols }
    return lists
end function

function NxClPagingCases(r as Object)
    ' 650 collections, one with 700 children: the same result as a server
    ' that answers every list whole, every request sized, no size over the
    ' measured caps.
    lists = NxClPagingLists(650, 700)
    whole = NxCollectionsFetchPlex("mid", NxClStubFetcher(NxClWholeDocs(lists)))
    srv = NxClPagingServer(lists, {})
    got = NxCollectionsFetchPlex("mid", srv)
    NxCheck(r, "paged: same collections as a whole answer", NxClRaw(got), NxClRaw(whole))
    NxCheck(r, "paged: 650 collections", NxToStr(got.Count()), "650")
    NxCheck(r, "paged: 700 children kept", NxToStr(NxClFirstKids(got)), "700")
    NxCheck(r, "paged: no request without a size", NxToStr(srv.bare), "0")
    NxCheck(r, "paged: children read 120 at a time", NxToStr(srv.sizes["/library/collections/1001/children"]), "120")
    NxCheck(r, "paged: collections read 300 at a time", NxToStr(srv.sizes["/library/sections/1/collections"]), "300")
    NxCheck(r, "paged: collection windows", NxClCallsFor(srv.calls, "/library/sections/1/collections "), "/library/sections/1/collections 0+300,/library/sections/1/collections 300+300,/library/sections/1/collections 600+300")
    NxCheck(r, "paged: 700 children in 6 windows", NxToStr(NxClCountFor(srv.calls, "/library/collections/1001/children ")), "6")
    NxCheck(r, "paged: a small collection in one window", NxToStr(NxClCountFor(srv.calls, "/library/collections/1002/children ")), "1")

    ' A server that caps the window below the size: the walk starts each
    ' window where the last ended, and still reads everything.
    srv = NxClPagingServer(lists, { cap: 50 })
    got = NxCollectionsFetchPlex("mid", srv)
    NxCheck(r, "capped: same collections", NxClRaw(got), NxClRaw(whole))
    windows = NxClCallsFor(srv.calls, "/library/collections/1001/children ").Split(",")
    second = ""
    if windows.Count() > 1 then second = windows[1]
    NxCheck(r, "capped: children windows start by what came back", second, "/library/collections/1001/children 50+120")

    ' No totalSize: a short page ends the walk.
    srv = NxClPagingServer(lists, { noTotal: true })
    got = NxCollectionsFetchPlex("mid", srv)
    NxCheck(r, "no total: same collections", NxClRaw(got), NxClRaw(whole))
    NxCheck(r, "no total: 700 children in 6 windows", NxToStr(NxClCountFor(srv.calls, "/library/collections/1001/children ")), "6")

    ' A server that ignores the start answers the first window again: nothing
    ' new, so the walk ends after two windows and keeps no duplicate.
    srv = NxClPagingServer(lists, { ignoreStart: true })
    got = NxCollectionsFetchPlex("mid", srv)
    NxCheck(r, "ignores start: 300 collections, no duplicate", NxToStr(got.Count()), "300")
    NxCheck(r, "ignores start: two collection windows", NxToStr(NxClCountFor(srv.calls, "/library/sections/1/collections ")), "2")
    NxCheck(r, "ignores start: 120 children, no duplicate", NxToStr(NxClFirstKids(got)), "120")

    ' A failed later window drops the collection, never keeps it short.
    srv = NxClPagingServer(lists, { failAt: { "/library/collections/1001/children": 240 } })
    got = NxCollectionsFetchPlex("mid", srv)
    NxCheck(r, "failed window: the collection is dropped", NxToStr(got.Count()), "649")
    firstID = ""
    if got <> invalid then
        if got.Count() > 0 then firstID = got[0].id
    end if
    NxCheck(r, "failed window: the others kept", firstID, "mid:1002")

    ' A failed later window of a section's collections skips the section.
    srv = NxClPagingServer(lists, { failAt: { "/library/sections/1/collections": 300 } })
    got = NxCollectionsFetchPlex("mid", srv)
    NxCheck(r, "failed collections window: the section is skipped", NxToStr(got.Count()), "0")
end function

' The first collection's child count, or -1 when there is none.
function NxClFirstKids(got as Dynamic) as Integer
    if got = invalid then return -1
    if got.Count() = 0 then return -1
    return got[0].childKeys.Count()
end function

' Each list as one whole answer, as a server that ignores the window would.
function NxClWholeDocs(lists as Object) as Object
    docs = {}
    for each path in lists
        docs[path] = NxClPagingDoc(lists[path].key, lists[path].rows, lists[path].rows.Count(), {})
    end for
    return docs
end function

function NxClCallsFor(calls as Object, prefix as String) as String
    out = []
    for each c in calls
        if Left(c, prefix.Len()) = prefix then out.Push(c)
    end for
    return out.Join(",")
end function

function NxClCountFor(calls as Object, prefix as String) as Integer
    n = 0
    for each c in calls
        if Left(c, prefix.Len()) = prefix then n = n + 1
    end for
    return n
end function

' ── A big Plex library, I-068 ────────────────────────────────────────────────

' captamajora's library (Discussion #8): 318 collections, 4,535 movies and 399
' shows, on Plex 1.43.5. The real NxPlexCollectionsFetcher and
' NxCollectionsFetchPlex read a model of that server through a clock, not a
' network. The model answers what 1.43.5 was measured to answer: a list read
' with no size is refused (the 400 the server logs it will send), a size over
' 1000 for the lists or 120 for the children is refused, and anything else is
' one window. A request that gets no answer costs what the real transport
' costs: 15 s for the five-at-a-time read, and three tries of 15 s for a read
' on its own (NxPlexGetContainer).
'
' What this does not show is a real server or a TV. Nobody has said what
' their server did when the launch hung; these are the ways a hang can be
' built from the code, each one tried.
function NxClSyntheticPlexCases(r as Object)
    lib = NxClBigLibrary()

    ' 1. A server that answers: all 318 collections, every request sized, no
    ' request refused, every child key a film or show in the library.
    net = NxClPlexNet(lib, {})
    f = NxPlexCollectionsFetcher({ uri: "https://plex.test", accessToken: "t" }, net)
    got = NxCollectionsFetchPlex("mid", f)
    NxCheck(r, "318: collections read", NxToStr(got.Count()), "318")
    NxCheck(r, "318: none refused for size", NxToStr(net.refused), "0")
    NxCheck(r, "318: the server isn't given up on", NxClBool(f.dead), "false")
    kids = 0
    for each c in got
        kids = kids + c.childKeys.Count()
    end for
    NxCheck(r, "318: every child key read", NxToStr(kids), NxToStr(lib.kids))
    index = NxCollectionsIndexLibrary(lib.items, { "0": "mid" })
    NxCheck(r, "318: 4,535 films and 399 shows indexed", NxToStr(index.mid.byKey.Count()) + "/" + NxToStr(index.mid.byShow.Count()), "5333/399")
    missing = 0
    for each c in got
        if NxCollectionsResolve(c.childKeys, index.mid).Count() = 0 then missing = missing + 1
    end for
    NxCheck(r, "318: every collection resolves to library items", NxToStr(missing), "0")
    NxCheck(r, "318: under a minute at 120 ms a request", NxClBool(net.clock < 60000), "true")

    ' 2. Children that never answer. The first five-at-a-time read gets no
    ' answer in 15 s, then three one-on-one reads of three tries each end it:
    ' 15 s + 3 x 45 s. Without the give-up the same server costs 318 x 45 s
    ' + 13 x 15 s = 4 hours with the loading screen on DISCOVERING
    ' COLLECTIONS and no way out (the scan's stall watch ends before this
    ' step starts).
    net = NxClPlexNet(lib, { silentChildren: true })
    f = NxPlexCollectionsFetcher({ uri: "https://plex.test", accessToken: "t" }, net)
    got = NxCollectionsFetchPlex("mid", f)
    NxCheck(r, "silent children: given up on", NxClBool(f.dead), "true")
    NxCheck(r, "silent children: ends in 150 s", NxToStr(net.clock), "150360")
    NxCheck(r, "silent children: no collection kept", NxToStr(got.Count()), "0")
    net = NxClPlexNet(lib, { silentChildren: true })
    f = NxPlexCollectionsFetcher({ uri: "https://plex.test", accessToken: "t" }, net)
    f.note = sub(code as Integer)
    end sub
    NxCollectionsFetchPlex("mid", f)
    NxCheck(r, "silent children: without the give-up it is 14505 s", NxToStr(net.clock \ 1000), "14505")

    ' 3. A server that is only slow under five requests at once answers them
    ' one by one: nothing given up, everything read.
    net = NxClPlexNet(lib, { silentBurst: true })
    f = NxPlexCollectionsFetcher({ uri: "https://plex.test", accessToken: "t" }, net)
    got = NxCollectionsFetchPlex("mid", f)
    NxCheck(r, "burst timeouts: not given up on", NxClBool(f.dead), "false")
    NxCheck(r, "burst timeouts: all 318 read", NxToStr(got.Count()), "318")

    ' 4. Two collections that don't answer in a row, then the rest do: the
    ' count starts over at an answer. Those two are dropped.
    net = NxClPlexNet(lib, { silentIds: { "100010": true, "100011": true } })
    f = NxPlexCollectionsFetcher({ uri: "https://plex.test", accessToken: "t" }, net)
    got = NxCollectionsFetchPlex("mid", f)
    NxCheck(r, "two silent: not given up on", NxClBool(f.dead), "false")
    NxCheck(r, "two silent: 316 read", NxToStr(got.Count()), "316")

    ' 5. An error status is an answer, not silence: ten in a row cost nothing
    ' and never give up.
    ids = {}
    for i = 20 to 29
        ids[(100000 + i).ToStr()] = true
    end for
    net = NxClPlexNet(lib, { errorIds: ids })
    f = NxPlexCollectionsFetcher({ uri: "https://plex.test", accessToken: "t" }, net)
    got = NxCollectionsFetchPlex("mid", f)
    NxCheck(r, "ten errors: not given up on", NxClBool(f.dead), "false")
    NxCheck(r, "ten errors: 308 read", NxToStr(got.Count()), "308")
end function

' { items, kids, kidRows, collections }: 4,535 films (keys 1 to 4535), 399 shows (20001 to 20399)
' of two episodes each, and what the 318 collections list, as
' NxClPlexNet builds them.
function NxClBigLibrary() as Object
    items = []
    for k = 1 to 4535
        items.Push({ ratingKey: k.ToStr(), type: "movie", serverIndex: 0 })
    end for
    for s = 20001 to 20399
        for e = 1 to 2
            items.Push({ ratingKey: (s * 10 + e).ToStr(), type: "episode", showKey: s.ToStr(), serverIndex: 0 })
        end for
    end for
    total = 0
    rows = {}
    for i = 1 to 318
        kids = []
        for each k in NxClChildKeys(i)
            kids.Push({ ratingKey: k })
        end for
        rows[(100000 + i).ToStr()] = kids
        total = total + kids.Count()
    end for
    cols = []
    for i = 1 to 318
        cols.Push({ ratingKey: (100000 + i).ToStr(), title: "Collection " + i.ToStr() })
    end for
    return { items: items, kids: total, kidRows: rows, collections: cols }
end function

' Collection i's children: a film collection (1 to 280) of 1 to 40 films, now
' and then 150 or 400; a show collection (281 to 318) of 1 to 12 shows.
function NxClChildKeys(i as Integer) as Object
    keys = []
    if i <= 280 then
        n = 1 + ((i * 7) mod 40)
        if i mod 50 = 0 then n = 150
        if i = 100 then n = 400
        for k = 1 to n
            keys.Push((((i * 37) + k) mod 4535 + 1).ToStr())
        end for
    else
        n = 1 + ((i * 5) mod 12)
        for k = 1 to n
            keys.Push((20001 + ((i * 5) + k) mod 399).ToStr())
        end for
    end if
    return keys
end function

' The transport NxPlexCollectionsFetcher takes, over the model. opts:
' silentChildren (no children read is answered), silentBurst (no five-at-a-time
' read is answered, one-on-one reads are), silentIds and errorIds (a collection
' by ratingKey whose children get no answer, or a 500). clock counts the
' milliseconds the requests would have taken; refused, the requests the model
' turned away for their size.
function NxClPlexNet(lib as Object, opts as Object) as Object
    return {
        lib: lib, opts: opts, clock: 0, refused: 0,
        ' A request's answer: { code, json }, from "<path>?<query>" with the
        ' base address already off.
        answer: function(pathQuery as String, burst as Boolean) as Object
            q = pathQuery.Split("?")
            path = q[0]
            size = invalid
            start = 0
            if q.Count() > 1 then
                for each pair in q[1].Split("&")
                    kv = pair.Split("=")
                    if kv.Count() = 2 then
                        if kv[0] = "X-Plex-Container-Size" then size = Val(kv[1], 10)
                        if kv[0] = "X-Plex-Container-Start" then start = Val(kv[1], 10)
                    end if
                end for
            end if
            isKids = Right(path, 9) = "/children"
            id = ""
            if isKids then
                parts = path.Split("/")
                id = parts[3]
                if m.opts.silentChildren = true then return { code: -28, json: invalid }
                if m.opts.silentBurst = true and burst then return { code: -28, json: invalid }
                if m.opts.silentIds <> invalid and m.opts.silentIds[id] = true then return { code: -28, json: invalid }
                if m.opts.errorIds <> invalid and m.opts.errorIds[id] = true then return { code: 500, json: invalid }
            end if
            cap = 1000
            if isKids then cap = 120
            if size = invalid or size > cap then
                m.refused = m.refused + 1
                return { code: 400, json: invalid }
            end if
            rows = []
            key = "Metadata"
            if path = "/library/sections" then
                key = "Directory"
                rows = [{ key: "1", type: "movie" }, { key: "2", type: "show" }, { key: "3", type: "artist" }]
            else if path = "/library/sections/1/collections" then
                for i = 0 to 279
                    rows.Push(m.lib.collections[i])
                end for
            else if path = "/library/sections/2/collections" then
                for i = 280 to 317
                    rows.Push(m.lib.collections[i])
                end for
            else if isKids then
                rows = m.lib.kidRows[id]
            else
                return { code: 404, json: invalid }
            end if
            page = []
            for i = start to start + size - 1
                if i < rows.Count() then page.Push(rows[i])
            end for
            mc = { size: page.Count(), totalSize: rows.Count() }
            mc[key] = page
            return { code: 200, json: { MediaContainer: mc } }
        end function,
        ' Five at a time: the batch costs a round of 120 ms per five, or 15 s
        ' if any of it gets no answer.
        many: function(urls as Object, token as String, width as Integer) as Object
            out = []
            silent = false
            for each u in urls
                a = m.answer(Mid(u, Len("https://plex.test") + 1), true)
                if a.code < 0 then silent = true
                out.Push(a)
            end for
            if silent then
                m.clock = m.clock + 15000
            else
                m.clock = m.clock + 120 * ((urls.Count() + width - 1) \ width)
            end if
            return out
        end function,
        ' One on its own, as NxPlexGetContainer: three tries, 15 s each when
        ' nothing answers.
        one: function(server as Object, path as String, err as Object) as Dynamic
            a = m.answer(path, false)
            err.code = a.code
            if a.code < 0 then
                m.clock = m.clock + 45000
            else
                m.clock = m.clock + 120
            end if
            return NxPlexContainerOf(a)
        end function
    }
end function

' BoxSets and the libraries the scan did not read (Jellyfin and Emby): a member that is not among the
' scan's items is not kept, a BoxSet left with none is not kept, and with nothing read the sweep
' has nothing to ask. Without `known` the sweep keeps every member, as upstream's does.
sub NxClBoxSetKnownCases(r as Object)
    list = "/Items?userId=u&IncludeItemTypes=BoxSet&Recursive=true&Fields=ChildCount&SortBy=SortName&StartIndex=0&Limit=500"
    docs = {}
    docs[list] = { Items: [{ Id: "bA", Name: "All read" }, { Id: "bB", Name: "Half read" }, { Id: "bC", Name: "None read" }], TotalRecordCount: 3 }
    for each b in [["bA", ["m1", "s1"]], ["bB", ["m2", "x9"]], ["bC", ["x1", "x2"]]]
        rows = []
        for each id in b[1]
            rows.Push({ Id: id, Type: "Movie" })
        end for
        docs[NxBoxSetPagePath("u", b[0], 0)] = { Items: rows, TotalRecordCount: rows.Count() }
    end for
    items = [
        { serverIndex: 0, ratingKey: "m1", type: "movie" },
        { serverIndex: 0, ratingKey: "m2", type: "movie" },
        { serverIndex: 0, ratingKey: "e5", type: "episode", showKey: "s1" },
        { serverIndex: 1, ratingKey: "x1", type: "movie" }
    ]
    known = NxCollectionsKnownKeys(items, 0)
    NxCheck(r, "boxsets known: this server's items and an episode's show", known.Count().ToStr() + NxToStr(known.DoesExist("m1")) + NxToStr(known.DoesExist("s1")) + NxToStr(known.DoesExist("x1")), "4truetruefalse")
    NxCheck(r, "boxsets known: a server that read nothing has no known keys", NxCollectionsKnownKeys(items, 2).Count().ToStr(), "0")
    got = NxCollectionsFetchBoxSets("srv", "u", NxClStubFetcher(docs), invalid, known)
    have = ""
    for each c in got
        have = have + c.title + "=" + c.childKeys.Join("+") + ";"
    end for
    NxCheck(r, "boxsets known: unread members and an empty BoxSet are left out", have, "All read=m1+s1;Half read=m2;")
    all = NxCollectionsFetchBoxSets("srv", "u", NxClStubFetcher(docs))
    NxCheck(r, "boxsets without known: every BoxSet and member, as before", all.Count().ToStr() + " " + all[2].childKeys.Join("+"), "3 x1+x2")
    ' What resolves is the same either way: only the keys the library has can resolve.
    index = NxCollectionsIndexLibrary(items, {})
    a = NxCollectionsResolve(all[1].childKeys, index["0"])
    b = NxCollectionsResolve(got[1].childKeys, index["0"])
    NxCheck(r, "boxsets known: the half-read BoxSet resolves to the same items", a.Count().ToStr() + NxToStr(a[0].ratingKey), b.Count().ToStr() + NxToStr(b[0].ratingKey))
end sub
