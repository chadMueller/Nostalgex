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
    NxCheck(r, "swift fold: from CH 450", NxClChannelNumbers(cs), "450")
    NxCheck(r, "swift fold: row shows its channel", NxToStr(cs.rows[0].channelNumber), "450")
    NxCheck(r, "swift fold: row detail", cs.rows[0].detail, "3 movies")
    ' Turning the found franchise on gives exactly one JOHN WICK channel.
    s = NxFgStep(t, items, NxFranchiseChoices(["dict:JOHN WICK"], []))
    cs = NxClStep(t, s, items, raw, on)
    NxCheck(r, "swift fold: john wick on, one channel", NxFgChannelNames(s) + "|" + NxClChannelNames(cs), "JOHN WICK|TOM HANKS")
    NxCheck(r, "swift fold: still folded while it is on", NxClFoldedInto(cs, "JOHN WICK COLLECTION"), "JOHN WICK")

    ' With the FRANCHISES package off nothing folds here (upstream folds into
    ' found franchises even then; docs/PORTING.md), so every collection is
    ' listed and the switched-on ones air: the two movie series in their own
    ' block from CH 400, the actor set from CH 450.
    cs = NxCollectionsStep({ channels: NxClStockChannels(t, items), raw: raw, items: items, serverKeys: {}, manifest: invalid, enabledKeys: on })
    NxCheck(r, "package off: no folds", NxClRowIDs(cs), "0:c-wick,0:c-sw,0:c-hanks")
    NxCheck(r, "package off: three channels", NxClChannelNames(cs) + "|" + NxClChannelNumbers(cs), "JOHN WICK COLLECTION,STAR WARS COLLECTION,TOM HANKS|400,401,450")
    NxCheck(r, "package off: name match warns", cs.rows[1].detail, "Exists: " + starWars)

    ' testFranchiseCollectionsDoNotMoveWhenFoundFranchisesChange, through the
    ' steps as the library load runs them: PADDINGTON TRILOGY (a movie series
    ' no franchise holds) and TOM HANKS keep their numbers and ids with the
    ' package off, with it on and two found franchises on, and with one of
    ' those switched off.
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
    want = "PADDINGTON TRILOGY=franchises CH 400 id 1010000;TOM HANKS=custom CH 450 id 1020000"
    pkgOff = NxCollectionsStep({ channels: [], raw: rawSplit, items: lib, serverKeys: {}, manifest: invalid, enabledKeys: onSplit })
    NxCheck(r, "switch: package off", NxClNumbersAndIDs(pkgOff), want)
    s = NxFgStep(t, lib, NxFranchiseChoices(["dict:JOHN WICK", "dict:THE HUNGER GAMES"], []))
    NxCheck(r, "switch: two found franchises on", NxFgChannelNames(s), "JOHN WICK,THE HUNGER GAMES")
    pkgOn = NxClStep(t, s, lib, rawSplit, onSplit)
    NxCheck(r, "switch: package on, two found on", NxClNumbersAndIDs(pkgOn), want)
    NxCheck(r, "switch: rows show the same numbers", NxClRowNumbers(pkgOn), NxClRowNumbers(pkgOff))
    pkgOn = NxClStep(t, NxFgStep(t, lib, NxFranchiseChoices(["dict:JOHN WICK"], [])), lib, rawSplit, onSplit)
    NxCheck(r, "switch: one found switched off", NxClNumbersAndIDs(pkgOn), want)

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

' ── FranchiseNumberingTests.swift: fixed blocks ─────────────────────────────
' Found franchises CH 310-399 (ids from 1,000,000), franchise collections CH
' 400-449 (ids from 1,010,000), other collections CH 450-499 (ids from
' 1,020,000), each in its own hundred beside the channels.json blocks since
' 1.0.29 (before: 300-449, 450-499, 500-699). Transcribed from the Apple TV's
' FranchiseNumberingTests at renumber/channel-blocks; XCTest cases, so there
' is no JS vector.

sub NxClSplitCases(r as Object)
    ' testRangesSitClearOfEveryShippedNumber / testEachKindHasItsOwnFixedIDBase
    NxCheck(r, "blocks: found franchises", NxFranchiseNumberBase().ToStr() + "-" + (NxFranchiseNumberBase() + NxFranchiseCapacity() - 1).ToStr() + " from " + NxFranchiseIDBase().ToStr(), "310-399 from 1000000")
    NxCheck(r, "blocks: franchise collections", NxCollectionFranchiseNumberBase().ToStr() + "-" + (NxCollectionFranchiseNumberBase() + NxCollectionFranchiseCapacity() - 1).ToStr() + " from " + NxCollectionFranchiseIDBase().ToStr(), "400-449 from 1010000")
    NxCheck(r, "blocks: other collections", NxCollectionsNumberBase().ToStr() + "-" + (NxCollectionsNumberBase() + NxCollectionsCapacity() - 1).ToStr() + " from " + NxCollectionsIDBase().ToStr(), "450-499 from 1020000")

    ' testEightySixFranchisesNumber310Through395AndCollectionsKeepTheirOwnBlocks
    found = []
    for i = 0 to 85
        found.Push(NxClFoundN(i, true, 3))
    end for
    fb = NxFranchiseBlock(found)
    NxCheck(r, "86 found: 310-395", NxClNumberRange(fb.channels) + " " + fb.skipped.ToStr(), "310-395 0")
    cands = [
        NxClCandidate("saga-a", "franchises", true), NxClCandidate("saga-b", "franchises", true),
        NxClCandidate("hanks", "custom", true), NxClCandidate("nolan", "custom", true),
        NxClCandidate("off", "custom", false)
    ]
    mz = NxCollectionsMaterialize(cands)
    NxCheck(r, "86 found: franchise collections", NxClNumbersOf(mz.channels, "franchises") + " ids " + NxClIDsOf(mz.channels, "franchises"), "400,401 ids 1010000,1010001")
    NxCheck(r, "86 found: other collections", NxClNumbersOf(mz.channels, "custom") + " ids " + NxClIDsOf(mz.channels, "custom"), "450,451 ids 1020000,1020001")
    NxCheck(r, "86 found: nothing over", NxToStr(mz.overCap), "0")

    ' testFoundFranchisesKeepTheirIDs
    fb = NxFranchiseBlock([NxClFoundN(0, true, 3), NxClFoundN(1, true, 3), NxClFoundN(2, true, 3)])
    ids = []
    for each ch in fb.channels
        ids.Push(ch.id.ToStr())
    end for
    NxCheck(r, "found franchises keep their ids", ids.Join(","), "1000000,1000001,1000002")

    ' testFoundFranchiseRangeIsCappedAt399AndKeepsTheBiggest: 100 on, the ten
    ' with 3 films wait, numbering A to Z.
    found = []
    for i = 0 to 99
        films = 4
        if i mod 10 = 0 then films = 3
        found.Push(NxClFoundN(i, true, films))
    end for
    fb = NxFranchiseBlock(found)
    names = []
    for each ch in fb.channels
        names.Push(ch.name)
    end for
    NxCheck(r, "found block full: 90 kept, 310-399", fb.channels.Count().ToStr() + " " + NxClNumberRange(fb.channels), "90 310-399")
    NxCheck(r, "found block full: ten skipped", fb.skipped.ToStr(), "10")
    NxCheck(r, "found block full: A to Z", NxClBool(NxClSortedSwift(names)), "true")
    NxCheck(r, "found block full: the 3-film ones wait", NxClBool(NxHasValue(names, "FRANCHISE 000") or NxHasValue(names, "FRANCHISE 090")), "false")
    mz = NxCollectionsMaterialize([NxClCandidate("saga-a", "franchises", true), NxClCandidate("hanks", "custom", true)])
    NxCheck(r, "found block full: collections keep their numbers", NxClNumbersOf(mz.channels, "franchises") + "|" + NxClNumbersOf(mz.channels, "custom") + "|" + NxToStr(mz.overCap), "400|450|0")
    for i = 0 to 14
        found[i].enabled = false
    end for
    fb = NxFranchiseBlock(found)
    NxCheck(r, "found block: switching some off frees it", fb.skipped.ToStr() + " " + NxToStr(fb.channels.Peek().number), "0 394")

    ' testFranchiseCollectionRangeIsCappedAt449AndKeepsTheBiggest: 53 on,
    ' three with 3 films, the rest 5; ties on films go by name, then id.
    cands = []
    for i = 0 to 52
        films = 5
        if i = 7 or i = 20 or i = 41 then films = 3
        cands.Push(NxClCandidateN("saga-" + Right("0" + i.ToStr(), 2), "franchises", true, films))
    end for
    mz = NxCollectionsMaterialize(cands)
    kept = []
    for each ch in mz.channels
        if ch.category = "franchises" then kept.Push(ch.name)
    end for
    NxCheck(r, "collection block full: 400-449", NxClNumbersOf(mz.channels, "franchises"), NxClSeq(400, 449))
    NxCheck(r, "collection block full: ids", NxClIDsOf(mz.channels, "franchises"), NxClSeq(1010000, 1010049))
    NxCheck(r, "collection block full: the 3-film ones wait", NxClBool(NxHasValue(kept, "SAGA-07") or NxHasValue(kept, "SAGA-20") or NxHasValue(kept, "SAGA-41")), "false")
    NxCheck(r, "collection block full: A to Z", NxClBool(NxClSortedSwift(kept)), "true")
    NxCheck(r, "collection block full: three over, nothing spills", NxToStr(mz.overCapFranchises) + "/" + NxToStr(mz.overCapCustom) + " " + NxClNumbersOf(mz.channels, "custom"), "3/0 ")

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

    ' testCollectionRangeIsCappedAt499: unchanged rule, the first 50 A to Z.
    cands = []
    for i = 0 to 52
        cands.Push(NxClCandidate("set-" + Right("00" + i.ToStr(), 3), "custom", true))
    end for
    mz = NxCollectionsMaterialize(cands)
    NxCheck(r, "other block: 50, from 450, the last on 499", mz.channels.Count().ToStr() + "|" + NxToStr(mz.channels[0].number) + "|" + NxToStr(mz.channels[49].number) + "|" + mz.channels[49].name, "50|450|499|SET-049")
    NxCheck(r, "other block: three past 499", NxToStr(mz.overCapCustom), "3")

    ' The step: a movie series in CH 400-449, an actor set from 450, each row
    ' carrying its category; the found franchises don't move them.
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
    fr = { channels: NxFranchiseChannels(found), found: [] }
    cs = NxCollectionsStep({ channels: [], raw: raw, items: lib, serverKeys: {}, manifest: invalid, enabledKeys: NxCollectionKeySet(["0:wick", "0:hanks"]), franchise: fr, franchiseBundleIDs: [], defs: [] })
    NxCheck(r, "split step: channels", NxClChannelNames(cs) + "|" + NxClChannelNumbers(cs), "JOHN WICK,TOM HANKS|400,450")
    rows = []
    for each row in cs.rows
        rows.Push(row.title + "=" + NxToStr(row.category) + "@" + NxClOrNull(row.channelNumber))
    end for
    NxCheck(r, "split step: rows", rows.Join(";"), "JOHN WICK=franchises@400;TOM HANKS=custom@450;TOM HANKS TOO=custom@null")
    NxCheck(r, "split step: overCap by block", NxToStr(cs.overCapFranchises) + "/" + NxToStr(cs.overCapCustom), "0/0")
end sub

function NxClNumbersAndIDs(cs as Object) as String
    out = []
    for each ch in cs.channels
        out.Push(ch.name + "=" + NxToStr(ch.category) + " CH " + NxToStr(ch.number) + " id " + NxToStr(ch.id))
    end for
    return out.Join(";")
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
        getJSON: function(path as String) as Dynamic
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
