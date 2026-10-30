' Runs source/guide/Franchises.brs, the franchise step of the library load,
' over cases transcribed from upstream's FranchiseSettingsTests.swift and
' FranchiseNumberingTests.swift (at the commit in data/UPSTREAM). Stock
' channels are built from their real channels.json rules through the filter,
' as the library load builds them. The server-collection fold cases are in
' tests/CollectionTests.brs. Returns the failure count.

function NxRunFranchiseGuideTests(configPath as String, dictionaryPath as String) as Integer
    config = ParseJson(ReadAsciiFile(configPath))
    defs = NxFranchiseDefinitions(ParseJson(ReadAsciiFile(dictionaryPath)))
    if config = invalid or defs.Count() = 0 then
        print "FAIL cannot read "; configPath; " or "; dictionaryPath
        return 1
    end if
    r = { pass: 0, fail: 0 }
    t = { config: config, defs: defs }

    ' testFoundFranchiseDefaultsOffAndItsSwitchPersistsAcrossRelaunch
    items = NxFgFilms(NxFgWick())
    s = NxFgStep(t, items, NxFranchiseChoices([], []))
    NxCheck(r, "found franchise listed", NxFgFoundNames(s), "JOHN WICK")
    NxCheck(r, "found franchise id", s.found[0].id, "dict:JOHN WICK")
    NxCheck(r, "found franchise count", NxFgRow(s, "JOHN WICK").countLabel, "3 movies")
    NxCheck(r, "found franchises default off", NxFgBool(s.found[0].enabled), "false")
    NxCheck(r, "no channel while off", s.channels.Count().ToStr(), "0")
    choices = NxFranchiseChoices([], [])
    NxFranchiseRecordChoice(choices, "dict:JOHN WICK", true)
    NxCheck(r, "choice saved as a plain list", NxFranchiseChoiceLists(choices).enabled.Join(","), "dict:JOHN WICK")
    s = NxFgStep(t, NxFgFilms(NxFgWick()), choices)
    NxCheck(r, "switched on: one channel", NxFgChannelNames(s), "JOHN WICK")
    NxFranchiseRecordChoice(choices, "dict:JOHN WICK", false)
    NxCheck(r, "switched off: enabled list empties", NxFranchiseChoiceLists(choices).enabled.Join(","), "")
    s = NxFgStep(t, NxFgFilms(NxFgWick()), choices)
    NxCheck(r, "switched off: channel leaves", s.channels.Count().ToStr(), "0")

    ' testAddAllThenRemoveAllRebuildTheLineup
    items = NxFgFilms(NxFgWick())
    items.Append(NxFgFilms(NxFgHunger()))
    items.Append(NxFgFilms(NxFgSpyKids()))
    s = NxFgStep(t, items, NxFranchiseChoices([], []))
    NxCheck(r, "found in builder order", NxFgFoundNames(s), "JOHN WICK,SPY KIDS,THE HUNGER GAMES")
    choices = NxFranchiseChoices([], [])
    for each f in s.found
        NxFranchiseRecordChoice(choices, f.id, true)
    end for
    NxCheck(r, "add all: saved ids", NxFranchiseChoiceLists(choices).enabled.Join(","), "dict:JOHN WICK,dict:THE HUNGER GAMES,tmdb:99999")
    s = NxFgStep(t, items, choices)
    NxCheck(r, "add all: channels", NxFgChannelNames(s), "JOHN WICK,SPY KIDS,THE HUNGER GAMES")
    nums = []
    ids = []
    for each ch in s.channels
        nums.Push(ch.number.ToStr())
        ids.Push(ch.id.ToStr())
    end for
    NxCheck(r, "add all: numbers from 300", nums.Join(","), "300,301,302")
    NxCheck(r, "add all: runtime ids", ids.Join(","), "1000000,1000001,1000002")
    for each f in s.found
        NxFranchiseRecordChoice(choices, f.id, false)
    end for
    s = NxFgStep(t, items, choices)
    NxCheck(r, "remove all: no channels", s.channels.Count().ToStr(), "0")

    ' testTVJoinShowsInTheCountLabel
    items = NxFgFilms(NxFgWick())
    items.Push(NxFgEpisode("e1", "The Continental: From the World of John Wick"))
    items.Push(NxFgEpisode("e2", "The Continental: From the World of John Wick"))
    s = NxFgStep(t, items, NxFranchiseChoices(["dict:JOHN WICK"], []))
    NxCheck(r, "tv join count label", NxFgRow(s, "JOHN WICK").countLabel, "3 movies, 1 show")
    NxCheck(r, "tv join pool", s.channels[0].pool.Count().ToStr(), "5")

    ' testStarWarsPoolMixesTheFilmsAndTheMandalorian
    items = NxFgFilms(NxFgStarWars())
    items.Push(NxFgEpisode("m1", "The Mandalorian"))
    items.Push(NxFgEpisode("m2", "The Mandalorian"))
    s = NxFgStep(t, items, NxFranchiseChoices([], []))
    NxCheck(r, "star wars pool: films and the show", NxFgPool(s, 100), "m1,m2,sw1,sw2,sw3")
    NxCheck(r, "star wars row", NxFgRow(s, "STAR WARS").countLabel, "3 movies, 1 show")

    ' testMarvelFilmsStayStudioRuledAndItsShowsJoinCH101
    items = NxFgFilms(NxFgStarWars())
    items.Append(NxFgMarvel())
    items.Push(NxFgMovie("echoFilm", "Echo"))
    items.Push(NxFgEpisode("loki1", "Loki"))
    items.Push(NxFgEpisode("loki2", "Loki"))
    items.Push(NxFgEpisode("wi1", "What If...?"))
    items.Push(NxFgEpisode("echo1", "Echo"))
    items.Push(NxFgEpisode("ep1", "Echo Park"))
    s = NxFgStep(t, items, NxFranchiseChoices([], []))
    NxCheck(r, "marvel pool", NxFgPool(s, 101), "echo1,loki1,loki2,mv1,mv2,mv3,wi1")
    marvel = invalid
    for each f in s.found
        if f.coveredByChannelID = 101 then marvel = f
    end for
    if marvel = invalid then
        NxCheck(r, "marvel covered by CH 101", "none", "MARVEL")
    else
        NxCheck(r, "marvel covered by CH 101", marvel.name, "MARVEL")
        NxCheck(r, "marvel films stay with the studio rule", marvel.movies.Count().ToStr(), "0")
    end if
    NxCheck(r, "a stock fold has no channel of its own", s.channels.Count().ToStr(), "0")

    ' testItemLockedToAnotherChannelIsNotTaken
    items = NxFgFilms(NxFgStarWars())
    items.Push(NxFgEpisode("m1", "The Mandalorian"))
    items.Push(NxFgEpisode("m2", "The Mandalorian"))
    items.Push(NxFgEpisode("a1", "Andor"))
    items.Push(NxFgEpisode("a2", "Andor"))
    rules = NxFilterExclusiveRules([{ channelIDs: [130], genres: [], titleContains: [], editorialTitles: ["The Mandalorian"], manifestExclusive: false }])
    manifest = { items: { "tv:a2": { channels: [60], exclusive: 60 } } }
    s = NxFgStepWith(t, items, NxFranchiseChoices([], []), manifest, rules)
    NxCheck(r, "locked items stay where they are", NxFgPool(s, 100), "a1,sw1,sw2,sw3")

    ' testListIsAlphabeticalStockAndFoundTogetherWithChannelNumbers
    s = NxFgListState(t, NxFranchiseChoices([], []))
    names = []
    for each row in s.rows
        names.Push(row.name)
    end for
    NxCheck(r, "list: alphabetical, stock and found", names.Join(","), "HARRY POTTER,JASON BOURNE,JOHN WICK,JURASSIC PARK,LORD OF THE RINGS,MARVEL,MISSION IMPOSSIBLE,STAR WARS,THE HUNGER GAMES")
    NxCheck(r, "list: star wars number", NxToStr(NxFgRow(s, "STAR WARS").channelNumber), NxFgLiveNumber(t.config, 100))
    ' Every stock classic's row shows its channel's number, in the library or
    ' not: a classic cut for too few films has no built channel, and its row
    ' must not fall back to the channel's id (100 to 106 are CH 103 to 109).
    for each row in s.rows
        if row.stockChannelID <> invalid then NxCheck(r, "list: " + row.name + " row number is its channel's", NxToStr(row.channelNumber), NxFgLiveNumber(t.config, row.stockChannelID))
    end for
    NxCheck(r, "list: stock classics default on", NxFgBool(NxFgRow(s, "STAR WARS").enabled), "true")
    NxCheck(r, "list: star wars count", NxFgRow(s, "STAR WARS").countLabel, "3 movies")
    NxCheck(r, "list: found has no number", NxToStr(NxFgRow(s, "JOHN WICK").channelNumber), "")
    NxCheck(r, "list: found defaults off", NxFgBool(NxFgRow(s, "JOHN WICK").enabled), "false")
    NxCheck(r, "list: classic not in the library", NxFgRow(s, "HARRY POTTER").countLabel, "None in your library yet")

    ' testMarvelIsListedWithItsFilmsAndMCUShows
    row = NxFgRow(s, "MARVEL")
    NxCheck(r, "list: marvel id", row.id, "dict:MARVEL")
    NxCheck(r, "list: marvel stock channel", NxToStr(row.stockChannelID), "101")
    NxCheck(r, "list: marvel count", row.countLabel, "3 movies, 1 show")

    ' testSwitchingAStockClassicOffTakesItsChannelOutAndPersists
    NxCheck(r, "star wars shown by default", NxFgBool(NxFgChannel(s, 100).enabled), "true")
    choices = NxFranchiseChoices([], [])
    NxFranchiseRecordChoice(choices, "dict:STAR WARS", false)
    NxCheck(r, "stock off: saved", NxFranchiseChoiceLists(choices).disabled.Join(","), "dict:STAR WARS")
    s = NxFgListState(t, choices)
    NxCheck(r, "stock off: CH 100 leaves the guide", NxFgBool(NxFgChannel(s, 100).enabled), "false")
    NxCheck(r, "stock off: the other classics stay", NxFgBool(NxFgChannel(s, 101).enabled), "true")
    NxCheck(r, "stock off: row shows off", NxFgBool(NxFgRow(s, "STAR WARS").enabled), "false")
    NxFranchiseRecordChoice(choices, "dict:STAR WARS", true)
    s = NxFgListState(t, choices)
    NxCheck(r, "stock back on", NxFgBool(NxFgChannel(s, 100).enabled), "true")
    NxCheck(r, "stock back on: disabled list empties", NxFranchiseChoiceLists(choices).disabled.Join(","), "")

    ' testAddAllAndRemoveAllCoverTheWholeList
    s = NxFgListState(t, NxFranchiseChoices([], []))
    choices = NxFranchiseChoices([], [])
    for each row in s.rows
        NxFranchiseRecordChoice(choices, row.id, false)
    end for
    s = NxFgListState(t, choices)
    NxCheck(r, "remove all: classics leave", NxFgBool(NxFgChannel(s, 100).enabled or NxFgChannel(s, 101).enabled), "false")
    NxCheck(r, "remove all: no found channels", s.channels.Count().ToStr(), "0")
    for each row in s.rows
        NxFranchiseRecordChoice(choices, row.id, true)
    end for
    s = NxFgListState(t, choices)
    NxCheck(r, "add all: classics back", NxFgBool(NxFgChannel(s, 100).enabled and NxFgChannel(s, 101).enabled), "true")
    NxCheck(r, "add all: found channels", NxFgChannelNames(s), "JOHN WICK,THE HUNGER GAMES")

    ' testMCUSpiderManFilmsCountOnSpiderManNotAlsoOnMarvel
    items = NxFgFilms(NxFgStarWars())
    mcu = { sm1: "Spider-Man: Homecoming", sm2: "Spider-Man: Far From Home", sm3: "Spider-Man: No Way Home" }
    for each id in ["sm1", "sm2", "sm3"]
        it = NxFgMovie(id, mcu[id])
        it.studio = "Marvel Studios"
        it.enrichment = { franchiseID: 531241, franchiseName: "Spider-Man (MCU) Collection" }
        items.Push(it)
    end for
    mv1 = NxFgMovie("mv1", "The Avengers")
    mv1.studio = "Marvel Studios"
    mv2 = NxFgMovie("mv2", "Iron Man")
    mv2.studio = "Marvel Studios"
    raimi = NxFgMovie("r1", "Spider-Man (2002)")
    raimi.enrichment = { franchiseID: 556, franchiseName: "Spider-Man Collection" }
    items.Append([mv1, mv2, raimi])
    s = NxFgStep(t, items, NxFranchiseChoices([], []))
    NxCheck(r, "CH 101 still airs all five", NxFgChannel(s, 101).pool.Count().ToStr(), "5")
    NxCheck(r, "spider-man row", NxFgRow(s, "SPIDER-MAN").countLabel, "4 movies")
    NxCheck(r, "MCU spider-man counted once", NxFgRow(s, "MARVEL").countLabel, "2 movies")

    ' testMergedFoundFranchiseIsOneRow
    items = []
    for each pair in [["p1", "American Pie", 2806], ["p2", "American Pie 2", 2806], ["q1", "American Pie Presents: Band Camp", 298820], ["q2", "American Pie Presents: The Naked Mile", 298820]]
        it = NxFgMovie(pair[0], pair[1])
        name = "American Pie Collection"
        if pair[2] = 298820 then name = "American Pie (Spin-off) Collection"
        it.enrichment = { franchiseID: pair[2], franchiseName: name }
        items.Push(it)
    end for
    s = NxFgStep(t, items, NxFranchiseChoices([], []))
    NxCheck(r, "merged: one row", NxFgFoundNames(s), "AMERICAN PIE")
    NxCheck(r, "merged: id", s.found[0].id, "tmdb:2806")
    NxCheck(r, "merged: count", NxFgRow(s, "AMERICAN PIE").countLabel, "4 movies")

    ' FranchiseNumberingTests: the default-on pair, and the 300-449 block.
    items = []
    for each title in ["Star Trek: The Motion Picture", "Star Trek II: The Wrath of Khan", "Star Trek III: The Search for Spock", "The Fast and the Furious", "2 Fast 2 Furious", "Fast Five"]
        it = NxFgMovie("d" + items.Count().ToStr(), title)
        if items.Count() < 3 then
            it.enrichment = { franchiseID: 151, franchiseName: "Star Trek: The Original Series Collection" }
        else
            it.enrichment = { franchiseID: 9485, franchiseName: "The Fast and the Furious Collection" }
        end if
        items.Push(it)
    end for
    items.Append(NxFgFilms(NxFgWick()))
    s = NxFgStep(t, items, NxFranchiseChoices([], []))
    NxCheck(r, "star trek and fast & furious start on", NxFgChannelNames(s), "FAST & FURIOUS,STAR TREK")
    choices = NxFranchiseChoices([], [])
    NxFranchiseRecordChoice(choices, "dict:STAR TREK", false)
    s = NxFgStep(t, items, choices)
    NxCheck(r, "star trek switched off stays off", NxFgChannelNames(s), "FAST & FURIOUS")
    s = NxFgStep(t, NxFgFilms(NxFgHanks()), NxFranchiseChoices([], []))
    NxCheck(r, "no channel when the library has none", s.channels.Count().ToStr(), "0")

    many = []
    for i = 0 to 249
        many.Push({ id: "tmdb:" + i.ToStr(), name: "F" + i.ToStr(), movies: [], tvItems: [], coveredByChannelID: invalid, fromDictionary: false, enabled: true })
    end for
    built = NxFranchiseChannels(many)
    NxCheck(r, "range capped at 150 channels", built.Count().ToStr(), "150")
    NxCheck(r, "range ends at 449", built.Peek().number.ToStr(), "449")
    NxCheck(r, "range colors cycle", built[10].colorHex, built[0].colorHex)

    NxCheck(r, "natural sort: digits as numbers", NxFgBool(NxFranchiseNaturalCompare("SAW 2", "SAW 10") < 0), "true")
    NxCheck(r, "natural sort: case-insensitive", NxFranchiseNaturalCompare("alien", "ALIEN").ToStr(), "0")

    print "franchise guide cases (upstream Swift tests): "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' ── Fixtures, as FranchiseSettingsTests.swift has them ──────────────────────

function NxFgWick() as Object
    return { w1: "John Wick", w2: "John Wick: Chapter 2", w3: "John Wick: Chapter 3 - Parabellum" }
end function

function NxFgHunger() as Object
    return { h1: "The Hunger Games", h2: "The Hunger Games: Catching Fire", h3: "The Hunger Games: Mockingjay - Part 1" }
end function

function NxFgSpyKids() as Object
    return { s1: "Spy Kids", s2: "Spy Kids 2", s3: "Spy Kids 3" }
end function

function NxFgStarWars() as Object
    return { sw1: "Star Wars: Episode IV - A New Hope", sw2: "Star Wars: Episode V - The Empire Strikes Back", sw3: "Star Wars: Episode VI - Return of the Jedi" }
end function

function NxFgHanks() as Object
    return { t1: "Big", t2: "Cast Away", t3: "Forrest Gump" }
end function

function NxFgMarvel() as Object
    out = []
    for each pair in [["mv1", "The Avengers"], ["mv2", "Iron Man"], ["mv3", "Thor"]]
        it = NxFgMovie(pair[0], pair[1])
        it.studio = "Marvel Studios"
        out.Push(it)
    end for
    return out
end function

' fixtureLookup: real collection ids where the dictionary has them, an
' invented one for Spy Kids, none for the actor set.
function NxFgCollection(id as String) as Dynamic
    p = Left(id, 1)
    if Left(id, 2) = "sw" then return { franchiseID: 10, franchiseName: "Star Wars Collection" }
    if p = "w" then return { franchiseID: 404609, franchiseName: "John Wick Collection" }
    if p = "h" then return { franchiseID: 131635, franchiseName: "The Hunger Games Collection" }
    if p = "s" then return { franchiseID: 99999, franchiseName: "Spy Kids Collection" }
    return invalid
end function

' Films in id order, as films() sorts its keys.
function NxFgFilms(table as Object) as Object
    keys = []
    for each k in table
        keys.Push(k)
    end for
    keys.Sort()
    out = []
    for each k in keys
        it = NxFgMovie(k, table[k])
        it.enrichment = NxFgCollection(k)
        out.Push(it)
    end for
    return out
end function

function NxFgMovie(id as String, title as String) as Object
    return { ratingKey: id, serverIndex: 0, title: title, year: 2000, duration: 7200000, type: "movie", librarySource: "movie", genres: [], tmdbID: id }
end function

function NxFgEpisode(id as String, show as String) as Object
    return { ratingKey: id, serverIndex: 0, title: show, episodeTitle: "Pilot", year: 2020, duration: 2700000, type: "episode", librarySource: "tv", genres: [], tmdbID: id }
end function

' ── The library load, cut down ──────────────────────────────────────────────

function NxFgStep(t as Object, items as Object, choices as Object) as Object
    return NxFgStepWith(t, items, choices, invalid, [])
end function

' Builds the FRANCHISES package's stock channels from channels.json through
' the filter, with LibraryTask's minItems cut, then runs the franchise step.
function NxFgStepWith(t as Object, items as Object, choices as Object, manifest as Dynamic, exclusiveRules as Object) as Object
    bundleIDs = []
    for each b in t.config.bundles
        if b.id = NxFranchisesBundleID() then bundleIDs = b.channelIDs
    end for
    clock = NxFilterClock(1760000000)
    channels = []
    for each def in t.config.channels
        if NxHasValue(bundleIDs, def.id) then
            pool = []
            for each row in NxFilterPool(items, NxFilterChannel(def), manifest, exclusiveRules, clock)
                pool.Push(row.item)
            end for
            channels.Push({ id: def.id, number: def.number, name: def.name, built: true, enabled: pool.Count() >= def.minItems, pool: pool })
        end if
    end for
    s = NxFranchiseStep({ channels: channels, items: items, defs: t.defs, choices: choices, bundleChannelIDs: bundleIDs, manifest: manifest, exclusiveRules: exclusiveRules })
    s.stock = channels
    return s
end function

' listState: Star Wars and Marvel films, Loki, John Wick and The Hunger Games.
function NxFgListState(t as Object, choices as Object) as Object
    items = NxFgFilms(NxFgStarWars())
    items.Append(NxFgMarvel())
    items.Append(NxFgFilms(NxFgWick()))
    items.Append(NxFgFilms(NxFgHunger()))
    items.Push(NxFgEpisode("loki1", "Loki"))
    items.Push(NxFgEpisode("loki2", "Loki"))
    return NxFgStep(t, items, choices)
end function

function NxFgFoundNames(s as Object) as String
    out = []
    for each f in s.found
        if f.coveredByChannelID = invalid then out.Push(f.name)
    end for
    return out.Join(",")
end function

function NxFgChannelNames(s as Object) as String
    out = []
    for each ch in s.channels
        out.Push(ch.name)
    end for
    return out.Join(",")
end function

function NxFgRow(s as Object, name as String) as Object
    for each row in s.rows
        if row.name = name then return row
    end for
    return { id: "", countLabel: "(no row)", enabled: invalid, channelNumber: invalid, stockChannelID: invalid }
end function

' The number channels.json gives the channel with this id, as text. The Swift
' cases make their own channels (Channel(id: 100, number: 100)); these build
' the stock channels from the real channels.json, whose numbers are not its ids
' (the three 80s channels took CH 20 to 22 on 2026-10-29 and every later
' channel moved up by 3), so what a row should say is read from it too.
function NxFgLiveNumber(config as Object, id as Integer) as String
    for each c in config.channels
        if c.id = id then return NxToStr(c.number)
    end for
    return "no channel " + id.ToStr()
end function

function NxFgChannel(s as Object, id as Integer) as Object
    for each ch in s.stock
        if ch.id = id then return ch
    end for
    return { enabled: false, pool: [] }
end function

function NxFgPool(s as Object, id as Integer) as String
    keys = []
    for each it in NxFgChannel(s, id).pool
        keys.Push(NxToStr(it.ratingKey))
    end for
    keys.Sort()
    return keys.Join(",")
end function

function NxFgBool(b as Dynamic) as String
    if b = true then return "true"
    return "false"
end function
