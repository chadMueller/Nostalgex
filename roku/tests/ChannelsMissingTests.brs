' Runs source/guide/ChannelsMissing.brs against the Apple TV's WHY ARE SOME
' CHANNELS MISSING? (I-004, #227). The plain-words cases are upstream's
' NostalgexTests/ChannelEmptyExplainerTests.swift, one for one, with the
' same rules and the same expected lines; the rest cover which channels the
' page lists, the card's amber line and the wrapping. The last cases read
' every channel in data/channels.json.
' Returns the failure count.

function NxRunChannelsMissingTests(configPath as String) as Integer
    r = { pass: 0, fail: 0 }

    ' ── plainLanguageRequirements (ChannelEmptyExplainerTests) ──────────────
    NxCheck(r, "words: no rules falls back to one line", NxMissingLines({}), "A specific, curated list of titles rather than a general rule")
    lines = NxPlainRequirements({ genres: { include: ["Horror", "Thriller"], exclude: ["Comedy"] }, yearRange: { min: 1980, max: 1999 }, contentRatings: ["R", "NC-17"], studios: ["A24"] })
    NxCheck(r, "words: genre", NxMissingYes(NxHasValue(lines, "Genre: Horror or Thriller")), "yes")
    NxCheck(r, "words: not genre", NxMissingYes(NxHasValue(lines, "Not genre: Comedy")), "yes")
    NxCheck(r, "words: years", NxMissingYes(NxHasValue(lines, "Released 1980 to 1999")), "yes")
    NxCheck(r, "words: rated", NxMissingYes(NxHasValue(lines, "Rated: R, NC-17")), "yes")
    NxCheck(r, "words: studio", NxMissingYes(NxHasValue(lines, "Studio: A24")), "yes")
    NxCheck(r, "words: never a raw invalid", NxMissingYes(Instr(1, NxMissingJoin(lines, "|"), "invalid") = 0), "yes")
    NxCheck(r, "words: from a year on", NxMissingLines({ yearRange: { min: 2000 } }), "Released 2000 or later")
    NxCheck(r, "words: up to a year", NxMissingLines({ yearRange: { max: 1989 } }), "Released before 1989")
    lines = NxPlainRequirements({ source: "musicVideo", keywords: ["christmas", "holiday", "snow", "santa", "winter"] })
    NxCheck(r, "words: music videos", NxMissingYes(NxHasValue(lines, "Music videos only")), "yes")
    NxCheck(r, "words: four keywords at most", NxMissingYes(NxHasValue(lines, "About: christmas, holiday, snow, santa")), "yes")
    NxCheck(r, "words: rewatched", NxMissingLines({ rewatched: true }), "Watched three times or more")
    NxCheck(r, "words: unwatched", NxMissingLines({ unwatchedOnly: true }), "Unwatched titles only")

    ' ── plainLanguageRequirements: the other fields, in its order ───────────
    NxCheck(r, "words: every field in order", NxMissingLines({
        type: "movie", source: "musicVideo",
        genres: { include: ["Drama"], requireAll: ["Sport", "Documentary"], exclude: ["Anime"] },
        studios: ["Pixar", "Disney"], networks: ["HBO", "AMC"], yearRange: { min: 1990, max: 1999 },
        contentRatings: ["PG"], ratingMin: 7, imdbRatingMin: 6.5, rtScoreMin: 80, metacriticMin: 70, wonOscar: true,
        watchedOnly: true, unwatchedOnly: true, rewatched: true, keywords: ["a", "b"], durationRange: { min: 70, max: 120 }
    }), "Movies only|Music videos only|Genre: Drama|Needs every one of these genres: Sport, Documentary|Not genre: Anime|Studio: Pixar or Disney|Network: HBO or AMC|Released 1990 to 1999|Rated: PG|Plex star rating 7.0 or higher|IMDb rating 6.5 or higher|Rotten Tomatoes score 80 or higher|Metacritic score 70 or higher|Won an Oscar|Already watched titles only|Unwatched titles only|Watched three times or more|About: a, b|Runs 70 to 120 minutes")
    NxCheck(r, "words: episodes", NxMissingLines({ type: "episode" }), "TV episodes only")
    NxCheck(r, "words: a type it doesn't know says nothing", NxMissingLines({ type: "show" }), "A specific, curated list of titles rather than a general rule")
    NxCheck(r, "words: another source says nothing", NxMissingLines({ source: "movie" }), "A specific, curated list of titles rather than a general rule")
    NxCheck(r, "words: empty lists say nothing", NxMissingLines({ genres: { include: [], requireAll: [], exclude: [] }, studios: [], networks: [], contentRatings: [], keywords: [] }), "A specific, curated list of titles rather than a general rule")
    NxCheck(r, "words: an empty year range says nothing", NxMissingLines({ yearRange: {} }), "A specific, curated list of titles rather than a general rule")
    NxCheck(r, "words: from a length on", NxMissingLines({ durationRange: { min: 85 } }), "Runs 85 minutes or longer")
    NxCheck(r, "words: up to a length", NxMissingLines({ durationRange: { max: 65 } }), "Runs 65 minutes or shorter")
    NxCheck(r, "words: false switches say nothing", NxMissingLines({ wonOscar: false, watchedOnly: false, rewatched: false }), "A specific, curated list of titles rather than a general rule")
    NxCheck(r, "words: fields it leaves out", NxMissingLines({ titleContains: ["Christmas"], allowUnrated: true, manifestOnly: true }), "A specific, curated list of titles rather than a general rule")
    NxCheck(r, "one decimal: whole", NxRatingTenths(5), "5.0")
    NxCheck(r, "one decimal: 8.2", NxRatingTenths(8.2), "8.2")
    NxCheck(r, "one decimal: 5.5", NxRatingTenths(5.5), "5.5")
    NxCheck(r, "one decimal: 6.5 from a Double", NxRatingTenths(ParseJson("6.5")), "6.5")

    ' ── ChannelsMissingPage.groups ──────────────────────────────────────────
    defs = NxChannelDefsById({ channels: [
        { id: 1, name: "ONE", minItems: 5, rules: { type: "movie" } },
        { id: 2, name: "TWO", rules: { type: "episode" } },
        { id: 3, name: "THREE", rules: { type: "movie" } },
        { id: 4, name: "FOUR" },
        { id: 5, name: "FIVE", rules: {} }
    ] })
    bundles = [
        { id: "a", channelIDs: [1, 2, 3] },
        { id: "b", channelIDs: [3, 4, 5, 99] },
        { id: "c", channelIDs: [2] },
        { id: "collections-custom", channelIDs: [2] }
    ]
    onAir = NxOnAirSet([1])
    all = ["a", "b", "c", "collections-custom"]
    NxCheck(r, "groups: missing channels by package, in its order", NxMissingDesc(NxMissingGroups(bundles, all, all, {}, onAir, defs)), "a:2,3|b:3,5|c:2")
    NxCheck(r, "groups: count", NxMissingCount(NxMissingGroups(bundles, all, all, {}, onAir, defs)).ToStr(), "5")
    NxCheck(r, "groups: an off package is left out", NxMissingDesc(NxMissingGroups(bundles, ["a"], all, {}, onAir, defs)), "a:2,3")
    NxCheck(r, "groups: not while it builds", NxMissingDesc(NxMissingGroups(bundles, all, all, { a: true }, onAir, defs)), "b:3,5|c:2")
    NxCheck(r, "groups: not before the guide held it", NxMissingDesc(NxMissingGroups(bundles, all, ["b"], {}, onAir, defs)), "b:3,5")
    NxCheck(r, "groups: every channel on air", NxMissingDesc(NxMissingGroups(bundles, all, all, {}, NxOnAirSet([1, 2, 3, 5]), defs)), "")
    NxCheck(r, "groups: nothing on air lists every channel with rules", NxMissingDesc(NxMissingGroups(bundles, ["a"], ["a"], {}, NxOnAirSet(invalid), defs)), "a:1,2,3")
    NxCheck(r, "groups: an id as text", NxMissingDesc(NxMissingGroups([{ id: "a", channelIDs: ["2"] }], ["a"], ["a"], invalid, onAir, defs)), "a:2")
    NxCheck(r, "groups: no packages", NxMissingDesc(NxMissingGroups(invalid, all, all, {}, onAir, defs)), "")

    ' ── ChannelRequirementCard's amber line ─────────────────────────────────
    NxCheck(r, "needs: counted", NxMissingNeedsLine(30, 12), "Needs 30 matching titles. You have 12.")
    NxCheck(r, "needs: one", NxMissingNeedsLine(1, 0), "Needs 1 matching title. You have 0.")
    NxCheck(r, "needs: unset is 50", NxMissingNeedsLine(invalid, 7), "Needs 50 matching titles. You have 7.")
    NxCheck(r, "needs: counting", NxMissingNeedsLine(30, "counting"), "Needs 30 matching titles. Counting yours…")
    NxCheck(r, "needs: not counted", NxMissingNeedsLine(30, "none"), "Needs 30 matching titles.")
    counts = { state: "counted", byId: { "7": 12 } }
    NxCheck(r, "count of: counted", NxToStr(NxMissingCountOf(counts, 7)), "12")
    NxCheck(r, "count of: counted, none matched", NxToStr(NxMissingCountOf(counts, 8)), "0")
    NxCheck(r, "count of: before the task says", NxToStr(NxMissingCountOf(invalid, 7)), "counting")
    NxCheck(r, "count of: counting", NxToStr(NxMissingCountOf({ state: "counting" }, 7)), "counting")
    NxCheck(r, "count of: not counted", NxToStr(NxMissingCountOf({ state: "none" }, 7)), "none")

    ' ── The link row and the page's place ───────────────────────────────────
    NxCheck(r, "link: N CH", NxMissingLinkValue(4), "4 CH")
    NxCheck(r, "parent: MISSING CHANNELS steps up to CHANNEL PACKAGES", NxChannelsPageParent("missing"), "packages")
    NxCheck(r, "parent: the others step up to the list", NxChannelsPageParent("packages") + "|" + NxChannelsPageParent("franchises") + "|" + NxChannelsPageParent("collections"), "||")
    NxCheck(r, "tab: a card is on CHANNELS & BUNDLES", NxSettingsTabOf("missingCard") + "|" + NxSettingsTabOf("missingNone"), "channels|channels")
    NxCheck(r, "focus: a card and the none line take focus", NxMissingYes(NxSettingsRowFocusable("missingCard") and NxSettingsRowFocusable("missingNone")), "yes")
    NxCheck(r, "keys: Back on the page steps up", NxSettingsKeyAction("rows", "back", false, true), "pageUp")
    rows = [{ kind: "bundle" }, { kind: "channelsLink", page: "missing" }, { kind: "header" }]
    NxCheck(r, "link row: Back from the page lands on it", NxSettingsLinkRowOf(rows, "missing").ToStr(), "1")

    ' ── Wrapping ────────────────────────────────────────────────────────────
    NxCheck(r, "wrap: fits", NxMissingJoin(NxWrapText("Genre: Horror", 20), "|"), "Genre: Horror")
    NxCheck(r, "wrap: at a space", NxMissingJoin(NxWrapText("About: high school, coming of age", 20), "|"), "About: high school,|coming of age")
    NxCheck(r, "wrap: exactly the width", NxMissingJoin(NxWrapText("abcde fghij", 11), "|"), "abcde fghij")
    NxCheck(r, "wrap: one over", NxMissingJoin(NxWrapText("abcde fghijk", 11), "|"), "abcde|fghijk")
    NxCheck(r, "wrap: a word longer than a line", NxMissingJoin(NxWrapText("ab abcdefghij", 4), "|"), "ab|abcd|efgh|ij")
    NxCheck(r, "wrap: empty", NxWrapText("", 10).Count().ToStr(), "1")

    ' ── Every channel in channels.json ──────────────────────────────────────
    config = ParseJson(ReadAsciiFile(configPath))
    defs = NxChannelDefsById(config)
    bad = []
    fallback = 0
    for each def in NxList(config.channels)
        lines = NxPlainRequirements(def.rules)
        text = NxMissingJoin(lines, "|")
        if lines.Count() = 0 or Instr(1, text, "invalid") > 0 or Instr(1, text, ": |") > 0 then bad.Push(NxToStr(def.id))
        if text = "A specific, curated list of titles rather than a general rule" then fallback = fallback + 1
    end for
    NxCheck(r, "channels.json: every channel has lines, none blank", NxMissingJoin(bad, ","), "")
    NxCheck(r, "channels.json: every channel has rules", NxToStr(defs.Count()), NxToStr(NxList(config.channels).Count()))
    print "channels-missing: "; fallback; " of "; NxList(config.channels).Count(); " channels read as the curated-list line"
    allIds = []
    for each b in NxList(config.bundles)
        allIds.Push(b.id)
    end for
    groups = NxMissingGroups(config.bundles, allIds, allIds, {}, NxOnAirSet(invalid), defs)
    total = 0
    for each b in NxList(config.bundles)
        total = total + NxList(b.channelIDs).Count()
    end for
    NxCheck(r, "channels.json: with nothing on air every package channel is listed", NxMissingCount(groups).ToStr(), total.ToStr())

    print "channels-missing tests: "; r.pass; " passed, "; r.fail; " failed"
    return r.fail
end function

function NxMissingYes(b as Boolean) as String
    if b then return "yes"
    return "no"
end function

function NxMissingLines(rules as Dynamic) as String
    return NxMissingJoin(NxPlainRequirements(rules), "|")
end function

function NxMissingDesc(groups as Object) as String
    parts = []
    for each g in groups
        ids = []
        for each def in g.channels
            ids.Push(NxToStr(def.id))
        end for
        parts.Push(NxToStr(g.bundle.id) + ":" + ids.Join(","))
    end for
    return parts.Join("|")
end function
