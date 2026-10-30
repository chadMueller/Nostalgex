' Channel pool filter, ported from Nostalgex.
'
' Copyright (c) 2024 Chad Mueller / Muell Haus Inc. (Nostalgex), MIT License.
' Port copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Source: upstream scripts/nostalgex-channel-filter.cjs, which upstream keeps
' in parity with the Apple TV's AppState+Channels.swift `filterItems`. Every
' rule, and the order the rules run in, is upstream's, checked against
' tests/vectors/filter.json. Don't change channel logic here; propose it upstream.
'
' One structural difference, for speed only: upstream lowercases a channel's
' rule lists and an item's fields on every call. Here NxFilterChannel and
' NxFilterItem do that once, because a Roku filters thousands of items into
' ~130 channels at startup. For the same reason, an item's genre locks and
' its exclusive-rule matches are worked out once and kept with it, a channel's
' rule flags once when it is compiled, and the title patterns run only on the
' path that reads them. None of that changes which rule decides.
'
' The clock is an argument. Upstream reads the wall clock for the current year
' and the releasedWithinMonths cutoff; here the caller passes a context from
' NxFilterClock (local calendar date, time of day and Unix time), so the same
' instant gives the same answer and the vectors can pin it.

' ── Inputs ──────────────────────────────────────────────────────────────────

' Local calendar context for "now", as upstream's `new Date()` sees it.
function NxFilterClock(nowSec = invalid as Dynamic) as Object
    dt = CreateObject("roDateTime")
    if nowSec <> invalid then dt.FromSeconds(nowSec)
    utc = dt.AsSeconds()
    dt.ToLocalTime()
    return {
        nowSec: utc,
        year: dt.GetYear(),
        month: dt.GetMonth(),
        day: dt.GetDayOfMonth(),
        secOfDay: dt.GetHours() * 3600 + dt.GetMinutes() * 60 + dt.GetSeconds()
    }
end function

' Exclusive rules as plex-tuner.html normalises them from channels.json.
function NxFilterExclusiveRules(rawRules as Dynamic) as Object
    out = []
    for each r in NxList(rawRules)
        ids = NxList(r.channelIDs)
        if ids.Count() = 0 and r.channelID <> invalid then ids = [r.channelID]
        g = GetGlobalAA()
        if g.nxRuleSeq = invalid then g.nxRuleSeq = 0
        g.nxRuleSeq = g.nxRuleSeq + 1
        ' `type` and `source` scope a lock to one kind of item ("" for any).
        ruleType = ""
        if NxTruthy(r.type) then ruleType = NxToStr(r.type)
        ruleSource = ""
        if NxTruthy(r.source) then ruleSource = NxToStr(r.source)
        out.Push({
            uid: "x" + g.nxRuleSeq.ToStr(),
            ids: ids,
            ruleType: ruleType,
            ruleSource: ruleSource,
            genresLower: NxLowerList(r.genres),
            titleWordsRx: NxWordPatterns(r.titleContains),
            editorialLower: NxLowerList(r.editorialTitles),
            manifestExclusive: NxTruthy(r.manifestExclusive)
        })
    end for
    return out
end function

' A channel { id, category, rules } with its rule lists pre-lowercased and its
' title patterns compiled.
function NxFilterChannel(channel as Object) as Object
    r = channel.rules
    if type(r) <> "roAssociativeArray" then r = {}
    genres = r.genres
    if type(genres) <> "roAssociativeArray" then genres = {}
    category = channel.category
    include = NxList(genres.include)
    c = {
        id: channel.id,
        r: r,
        isKids: category <> invalid and category = "kids",
        includeLower: NxLowerList(include),
        excludeLower: NxLowerList(genres.exclude),
        requireAllLower: NxLowerList(genres.requireAll),
        titleContainsRx: NxWordPatterns(r.titleContains),
        titleExcludesRx: NxWordPatterns(r.titleExcludes),
        episodeTitleRx: NxWordPatterns(r.episodeTitleContains),
        episodeSummaryRx: NxWordPatterns(r.episodeSummaryContains),
        episodeSeasonalRx: NxWordPatterns(r.episodeSeasonalTitleContains),
        episodeExcludesRx: NxWordPatterns(r.episodeTitleExcludes),
        editorialLower: NxLowerList(r.editorialOverrides),
        editorialSet: NxSet(NxLowerList(r.editorialOverrides)),
        studiosLower: NxLowerList(r.studios),
        prodCoLower: NxLowerList(r.productionCompanies),
        networksLower: NxLowerList(r.networks),
        keywordsLower: NxLowerList(r.keywords),
        keywordsExcludeLower: NxLowerList(r.keywordsExclude),
        keywordGenreGateLower: NxLowerList(r.keywordsRequireAnyGenre),
        keywordGatedLower: NxLowerList(r.keywordGatedGenres),
        contentRatings: NxList(r.contentRatings)
    }
    c.hasGenreInclude = include.Count() > 0
    c.hasStudioRule = c.studiosLower.Count() > 0
    c.isStudioChannel = c.hasStudioRule and not c.hasGenreInclude
    ' From the raw lists: an empty needle gets no pattern but still makes a rule.
    c.hasTitleRule = NxList(r.titleContains).Count() > 0
    ' Upstream's hasEpisodeRules: any of the three makes the channel
    ' episode-curated, its episode rules the allowlist.
    c.isEpisodeCurated = NxList(r.episodeTitleContains).Count() > 0 or NxList(r.episodeSummaryContains).Count() > 0 or NxList(r.episodeSeasonalTitleContains).Count() > 0
    c.hasEpisodeSummaryRule = NxList(r.episodeSummaryContains).Count() > 0
    c.hasEpisodeSeasonalRule = NxList(r.episodeSeasonalTitleContains).Count() > 0
    c.airFrom = invalid
    c.airTo = invalid
    if type(r.episodeAirWindow) = "roAssociativeArray" then
        c.airFrom = NxMonthDay(r.episodeAirWindow.from)
        c.airTo = NxMonthDay(r.episodeAirWindow.to)
    end if
    c.matchTmdbGenres = NxTruthy(r.matchTmdbGenres)
    c.hasProdCoRule = c.prodCoLower.Count() > 0
    c.hasKeywordRule = c.keywordsLower.Count() > 0
    c.hasNetworkRule = c.networksLower.Count() > 0
    c.isFamilySafe = c.isKids or NxHasExact(c.includeLower, "family")

    locks = NxGenreLocks()
    ' Episode rules are a curated list as a title list is, so they open the
    ' Animation lock too.
    c.allowsAnimation = c.isStudioChannel or NxAnyIn(c.includeLower, locks.animation) or c.isKids or c.hasTitleRule or c.isEpisodeCurated
    c.allowsHorror = c.isStudioChannel or NxAnyIn(c.includeLower, locks.horror)
    c.allowsReality = c.isStudioChannel or NxAnyIn(c.includeLower, locks.reality)
    c.allowsDocumentary = c.isStudioChannel or NxAnyIn(c.includeLower, locks.documentary)
    c.allowsWar = c.isStudioChannel or NxAnyIn(c.includeLower, locks.war)
    c.allowsWestern = c.isStudioChannel or NxAnyIn(c.includeLower, locks.western)
    c.allowsTalkShow = c.isStudioChannel or NxAnyIn(c.includeLower, locks.talkShow)
    c.isExplicitReality = NxAnyIn(c.includeLower, locks.reality)
    c.isTitleCurated = c.hasTitleRule and not c.hasKeywordRule and not c.hasNetworkRule and not c.hasProdCoRule and not c.hasStudioRule

    ' The rule flags itemPasses reads, read once here.
    c.hasSource = NxTruthy(r.source)
    c.hasType = NxTruthy(r.type)
    c.manifestOnly = NxTruthy(r.manifestOnly)
    c.hasYearRange = type(r.yearRange) = "roAssociativeArray"
    c.allowUnrated = NxTruthy(r.allowUnrated)
    c.watchedOnly = NxTruthy(r.watchedOnly)
    c.unwatchedOnly = NxTruthy(r.unwatchedOnly)
    c.rewatched = NxTruthy(r.rewatched)
    c.hasImdbRatingMin = NxIsNumber(r.imdbRatingMin)
    c.hasImdbVotesMin = NxIsNumber(r.imdbVotesMin)
    c.hasRtScoreMin = NxIsNumber(r.rtScoreMin)
    c.hasMetacriticMin = NxIsNumber(r.metacriticMin)
    c.wonOscar = NxTruthy(r.wonOscar)
    c.hasAddedWithin = NxIsNumber(r.addedWithinDays)
    c.hasReleasedWithin = NxIsNumber(r.releasedWithinMonths)
    c.hasRatingMin = NxIsNumber(r.ratingMin)

    dr = r.durationRange
    c.durMin = invalid
    c.durMax = invalid
    if type(dr) = "roAssociativeArray" then
        c.durMin = dr.min
        if c.durMin = invalid then c.durMin = dr.minMinutes
        c.durMax = dr.max
        if c.durMax = invalid then c.durMax = dr.maxMinutes
    end if
    return c
end function

' An item's lowercased and derived fields, computed once and kept on the item.
function NxFilterItem(item as Object) as Object
    p = item.nxFilter
    if p <> invalid then return p

    parts = []
    if NxTruthy(item.artist) then parts.Push(NxToStr(item.artist))
    if NxTruthy(item.title) then parts.Push(NxToStr(item.title))
    ' Mirrors Swift filterTitleHaystack: artist first, lowercased, " (YYYY)" stripped.
    ' (?![\s\S]) is the absolute end, as JS $ is; PCRE's $ also matches before a final newline.
    titleLower = NxRx("yearSuffix", " \(\d{4}\)(?![\s\S])").Replace(LCase(parts.Join(" ")), "")
    ' What an exclusive lock reads: the item's own title (the song, never the
    ' artist), raw and with the year suffix stripped and trimmed.
    ownTitleRaw = LCase(NxToStr(item.title))
    ownTitle = NxRx("yearSuffix", " \(\d{4}\)(?![\s\S])").Replace(ownTitleRaw, "").Trim()

    genres = []
    for each g in NxList(item.genres)
        genres.Push(LCase(NxToStr(g)))
    end for

    if type(item.tmdbKeywords) = "roArray" then
        keywords = NxLowerList(item.tmdbKeywords)
    else
        keywords = NxLowerList(NxEnriched(item, "keywords"))
    end if

    source = item.librarySource
    if not NxTruthy(source) then source = "movie"
    studioLower = ""
    if NxTruthy(item.studio) then studioLower = LCase(NxToStr(item.studio))
    companies = NxLowerList(NxEnriched(item, "productionCompanies"))
    prodCoHaystack = []
    prodCoHaystack.Append(companies)
    if NxTruthy(item.studio) then prodCoHaystack.Push(studioLower)
    mediaType = "movie"
    if item.type = "episode" then mediaType = "tv"
    manifestKey = invalid
    if NxTruthy(item.tmdbID) then manifestKey = mediaType + ":" + NxToStr(item.tmdbID)

    locks = NxGenreLocks()
    p = {
        titleLower: titleLower,
        ownTitleRaw: ownTitleRaw,
        ownTitle: ownTitle,
        genres: genres,
        inHorror: NxAnyIn(genres, locks.horror),
        inReality: NxAnyIn(genres, locks.reality),
        inAnimation: NxAnyIn(genres, locks.animation),
        inDocumentary: NxAnyIn(genres, locks.documentary),
        inWar: NxAnyIn(genres, locks.war),
        inWestern: NxAnyIn(genres, locks.western),
        inTalkShow: NxAnyIn(genres, locks.talkShow),
        exclusiveMatches: {},
        episodeTitleLower: LCase(NxToStr(item.episodeTitle)),
        keywords: keywords,
        networks: NxLowerList(NxEnriched(item, "networks")),
        companies: companies,
        prodCoHaystack: prodCoHaystack,
        studioLower: studioLower,
        source: source,
        year: NxParseYear(item),
        manifestKey: manifestKey,
        usRating: NxUsContentRating(item.contentRating, item.type)
    }
    item.nxFilter = p
    return p
end function

' What a `matchTmdbGenres` channel reads: the server's genres and the
' enrichment's TMDB genres together, with their genre locks, kept on the
' profile `p`. The profile itself when the item has no TMDB genres, as
' upstream then falls back to the server's. (`false` marks that case: the
' profile kept inside itself would be a cycle, never freed.)
function NxFilterTmdbGenres(item as Object, p as Object) as Object
    t = p.tmdbGenres
    if t = invalid then
        extra = NxLowerList(NxEnriched(item, "tmdbGenres"))
        if extra.Count() = 0 then
            p.tmdbGenres = false
            return p
        end if
        genres = []
        genres.Append(p.genres)
        seen = NxSet(genres)
        for each g in extra
            if not seen.DoesExist(g) then
                seen[g] = true
                genres.Push(g)
            end if
        end for
        locks = NxGenreLocks()
        t = {
            genres: genres,
            inHorror: NxAnyIn(genres, locks.horror),
            inReality: NxAnyIn(genres, locks.reality),
            inAnimation: NxAnyIn(genres, locks.animation),
            inDocumentary: NxAnyIn(genres, locks.documentary),
            inWar: NxAnyIn(genres, locks.war),
            inWestern: NxAnyIn(genres, locks.western),
            inTalkShow: NxAnyIn(genres, locks.talkShow)
        }
        p.tmdbGenres = t
    else if type(t) <> "roAssociativeArray" then
        return p
    end if
    return t
end function

' ── The filter ──────────────────────────────────────────────────────────────

' Items that belong on the channel, as [{ item, via }]. `channel` is from
' NxFilterChannel; `manifest` is channels-memberships.json (or invalid);
' `exclusiveRules` is from NxFilterExclusiveRules; `clock` from NxFilterClock.
' Mirrors filterPool's item list. Its `shows` summary is a devtools aid and
' is not ported.
' `backend` is the signed-in kind (plex, jellyfin or emby), upstream's
' `opts.backend`.
function NxFilterPool(items as Object, channel as Object, manifest as Dynamic, exclusiveRules as Object, clock as Object, backend = "plex" as String) as Object
    out = []
    for each it in items
        via = NxItemPasses(it, channel, manifest, exclusiveRules, clock, backend)
        if via <> "" then out.Push({ item: it, via: via })
    end for
    return out
end function

' Every channel in `defs` filtered one server's items at a time, instead of
' NxFilterPool's one pass over every enabled server's combined items. `defs`
' is [{ id (String), compiled (NxFilterChannel's result) }]; returns
' { <id>: [item] }, an empty list for an id with no matches.
'
' NxFilterItem (above) memoizes an item's lowercased, derived fields on
' item.nxFilter the first time any channel reads it, and nothing after the
' filter pass reads that cache (franchise and collection classification
' don't). With several large servers on at once, running every channel
' against the combined array keeps every server's cache alive for the rest
' of the build; with a Roku Streaming Stick 4K and a few large libraries,
' that is enough to crash partway through (I-065). NxFilterPool is a plain
' per-item scan with no state carried between items, so slicing the combined
' array by serverIndex, filtering a slice against every channel, then
' deleting its items' nxFilter before moving to the next slice, gives the
' same pools NxFilterPool would from one pass over everything, in the same
' order (items arrive server-contiguous; a server's slice keeps that order),
' while only ever holding one server's filter cache at a time.
' `progress`, when given, is a duck-typed { report: sub(done, total) },
' called once a server's slice is filtered against every def.
function NxFilterPoolsByServer(items as Object, defs as Object, manifest as Dynamic, exclusiveRules as Object, clock as Object, backend = "plex" as String, progress = invalid as Dynamic) as Object
    pools = {}
    for each d in defs
        pools[d.id] = []
    end for
    if defs.Count() = 0 then return pools
    slices = []
    bySlice = {}
    for each it in items
        sk = NxToStr(it.serverIndex)
        slice = bySlice[sk]
        if slice = invalid then
            slice = []
            bySlice[sk] = slice
            slices.Push(slice)
        end if
        slice.Push(it)
    end for
    done = 0
    for each slice in slices
        for each d in defs
            for each row in NxFilterPool(slice, d.compiled, manifest, exclusiveRules, clock, backend)
                pools[d.id].Push(row.item)
            end for
        end for
        ' This slice is done with every channel; nothing past this point
        ' reads item.nxFilter, so it only ever cost memory from here.
        for each it in slice
            it.Delete("nxFilter")
        end for
        done = done + 1
        if progress <> invalid then progress.report(done, slices.Count())
    end for
    return pools
end function

' The matching rule ("rules", "manifest", "editorial", "episode", "title",
' "keyword", "network", "prodco"), or "" when the item doesn't belong.
' Mirrors itemPasses.
function NxItemPasses(item as Object, c as Object, manifest as Dynamic, exclusiveRules as Object, clock as Object, backend = "plex" as String) as String
    ' Emby Dolby Vision profile 5: on no channel, whatever the rules say.
    if NxIsLeftOffChannels(item, backend) then return ""
    r = c.r
    p = NxFilterItem(item)
    titleLower = p.titleLower
    ' `g` has the genres this channel reads and their genre locks: the
    ' server's, or with `matchTmdbGenres` the TMDB ones added. An exclusive
    ' lock always reads the server's (p.genres).
    g = p
    if c.matchTmdbGenres then g = NxFilterTmdbGenres(item, p)
    itemGenres = g.genres

    if c.hasSource then
        if p.source <> r.source then return ""
    else if p.source = "musicVideo" then
        return ""
    end if

    ' A rating from another country counts as its US label (GB-18 is R).
    if c.isFamilySafe and NxTruthy(item.contentRating) then
        if NxGenreLocks().adultRatings.DoesExist(NxToStr(p.usRating)) then return ""
    end if

    if not c.allowsHorror and g.inHorror then return ""
    if not c.allowsReality and g.inReality then return ""
    if not c.allowsAnimation and g.inAnimation then return ""
    if not c.allowsDocumentary and g.inDocumentary then return ""
    if not c.allowsWar and g.inWar then return ""
    if not c.allowsWestern and g.inWestern then return ""
    if not c.allowsTalkShow and g.inTalkShow then return ""

    if c.isExplicitReality and not g.inReality then return ""

    if c.editorialSet.DoesExist(titleLower) or (titleLower = "" and NxHasExact(c.editorialLower, "")) then return "editorial"

    ' Every path below checks type and year range before it returns a match,
    ' so an item failing either can only end in "": stop here, for speed.
    ' The checks stay where upstream has them too.
    if c.hasType and item.type <> r.type then return ""
    if c.hasYearRange and not NxPassesYearRange(item, r) then return ""

    ' Manifest-level exclusivity: an item locked to one channel airs nowhere else.
    entry = invalid
    if manifest <> invalid and p.manifestKey <> invalid then
        if type(manifest.items) = "roAssociativeArray" then entry = manifest.items[p.manifestKey]
    end if
    if type(entry) = "roAssociativeArray" then
        if entry.exclusive <> invalid then
            if entry.exclusive <> c.id then return ""
        end if
    end if

    if NxManifestClaims(entry, c.id) then
        if c.hasType and item.type <> r.type then return ""
        if c.hasYearRange and not NxPassesYearRange(item, r) then return ""
        if c.hasTitleRule and not NxAnyWord(titleLower, c.titleContainsRx) then return ""
        ' Nor past the episode rules: a claim for an episode-curated channel
        ' still has to be a holiday episode.
        if c.isEpisodeCurated and not NxEpisodeRulesMatch(item, p, c) then return ""
        ' A channel's own exclusions outrank a manifest claim; includes don't.
        if NxAnyWord(titleLower, c.titleExcludesRx) then return ""
        if NxAnySubstring(itemGenres, c.excludeLower) then return ""
        return "manifest"
    end if

    ' manifestOnly: membership comes solely from the manifest.
    if c.manifestOnly then return ""

    if NxAnyWord(titleLower, c.titleExcludesRx) then return ""

    ' Channel exclusivity: block items owned by another channel.
    for each rule in exclusiveRules
        if not NxHasValue(rule.ids, c.id) and NxExclusiveRuleApplies(item, p, rule) then
            hit = p.exclusiveMatches[rule.uid]
            if hit = invalid then
                ' Server genres only, as Swift's ExclusiveRule.matches reads item.genres.
                hit = NxExclusiveRuleMatches(p, p.genres, rule)
                p.exclusiveMatches[rule.uid] = hit
            end if
            if hit then return ""
            if rule.manifestExclusive and manifest <> invalid and p.manifestKey <> invalid and type(manifest.items) = "roAssociativeArray" then
                owner = manifest.items[p.manifestKey]
                for each id in rule.ids
                    if NxManifestClaims(owner, id) then return ""
                end for
            end if
        end if
    end for

    if c.hasType and item.type <> r.type then return ""

    if c.hasYearRange and not NxPassesYearRange(item, r) then return ""

    if c.contentRatings.Count() > 0 then
        rating = ""
        if NxTruthy(item.contentRating) then rating = NxToStr(p.usRating)
        if not (rating = "" and c.allowUnrated) then
            if not NxHasValue(c.contentRatings, rating) then return ""
        end if
    end if

    if NxIsNumber(item.duration) then
        if c.durMin <> invalid then
            if item.duration < c.durMin then return ""
        end if
        if c.durMax <> invalid then
            if item.duration > c.durMax then return ""
        end if
    end if

    itemYear = 0
    if p.year <> invalid then itemYear = p.year
    isNewRelease = itemYear >= clock.year - 1
    viewCount = NxNumberOr0(item.viewCount)
    if c.watchedOnly and viewCount < 1 and not isNewRelease then return ""
    if c.unwatchedOnly and (viewCount > 0 or isNewRelease) then return ""
    if c.rewatched and viewCount < 3 then return ""

    ' Episode-curated channels: the episode rules are the allowlist, and
    ' nothing widens it. They read an episode's own title and summary, not
    ' the show: a Christmas special lives in "The One with the Holiday
    ' Armadillo", not in "Friends".
    if c.isEpisodeCurated and not NxEpisodeRulesMatch(item, p, c) then return ""

    if NxAnySubstring(itemGenres, c.excludeLower) then return ""

    ' Soft exclude: unenriched items pass. Keywords match by exact equality.
    if c.keywordsExcludeLower.Count() > 0 and p.keywords.Count() > 0 then
        for each kw in c.keywordsExcludeLower
            if NxHasExact(p.keywords, kw) then return ""
        end for
    end if

    ' Enrichment gates. OMDb gates are HARD: a missing value rejects the item,
    ' as Swift's `guard let` does.
    if c.hasImdbRatingMin then
        v = NxEnriched(item, "imdbRating")
        if not NxIsNumber(v) then return ""
        if v < r.imdbRatingMin then return ""
    end if
    if c.hasImdbVotesMin then
        v = NxEnriched(item, "imdbVotes")
        if not NxIsNumber(v) then return ""
        if v < r.imdbVotesMin then return ""
    end if
    if c.hasRtScoreMin then
        v = NxEnriched(item, "rottenTomatoesScore")
        if v = invalid then v = NxEnriched(item, "rtScore")
        if not NxIsNumber(v) then return ""
        if v < r.rtScoreMin then return ""
    end if
    if c.hasMetacriticMin then
        v = NxEnriched(item, "metacriticScore")
        if v = invalid then v = NxEnriched(item, "metacritic")
        if not NxIsNumber(v) then return ""
        if v < r.metacriticMin then return ""
    end if
    if c.wonOscar then
        awards = NxEnriched(item, "awards")
        if not NxIsString(awards) then return ""
        a = LCase(awards)
        if not (Instr(1, a, "won") > 0 and Instr(1, a, "oscar") > 0) then return ""
    end if

    ' addedWithinDays: an item with no addedAt (0) is rejected, as in Swift.
    if c.hasAddedWithin then
        if r.addedWithinDays > 0 then
            cutoff = clock.nowSec - r.addedWithinDays * 86400#
            if NxNumberOr0(item.addedAt) < cutoff then return ""
        end if
    end if

    ' releasedWithinMonths: month precision from originallyAvailableAt, else a
    ' year approximation.
    if c.hasReleasedWithin then
        if r.releasedWithinMonths > 0 then
            months = r.releasedWithinMonths
            hit = invalid
            if NxIsString(item.originallyAvailableAt) then
                hit = NxRx("isoDate", "^(\d{4})-(\d{2})-(\d{2})").Match(item.originallyAvailableAt)
            end if
            if hit <> invalid and hit.Count() = 4 then
                if NxReleasedBefore(hit[1].ToInt(), hit[2].ToInt(), hit[3].ToInt(), months, clock) then return ""
            else if p.year <> invalid then
                yearsBack = Int((months + 11) / 12) - 1
                if p.year < clock.year - yearsBack then return ""
            end if
        end if
    end if

    ' ratingMin: the Plex rating or the user rating clears the bar.
    if c.hasRatingMin then
        if NxNumberOr0(item.rating) < r.ratingMin and NxNumberOr0(item.userRating) < r.ratingMin then return ""
    end if

    matchesGenre = c.hasGenreInclude and NxAnySubstring(itemGenres, c.includeLower)
    for each need in c.requireAllLower
        if not NxAnySubstring(itemGenres, [need]) then return ""
    end for

    ' Plex studio first, then TMDB production companies and networks.
    matchesStudio = false
    if c.hasStudioRule then
        if p.studioLower <> "" and NxContainsAny(p.studioLower, c.studiosLower) then
            matchesStudio = true
        else if NxAnyContainsAny(p.companies, c.studiosLower) then
            matchesStudio = true
        else if NxAnyContainsAny(p.networks, c.studiosLower) then
            matchesStudio = true
        end if
    end if

    matchesProdCo = c.hasProdCoRule and p.prodCoHaystack.Count() > 0 and NxAnyContainsAny(p.prodCoHaystack, c.prodCoLower)

    ' An episode-curated channel has passed its allowlist and every gate above;
    ' Swift skips its content-matching block for these, and so does upstream.
    if c.isEpisodeCurated then return "episode"

    matchesTitleRule = c.hasTitleRule and NxAnyWord(titleLower, c.titleContainsRx)
    if c.isTitleCurated then
        ' The title list is the allowlist (e.g. ADULT CARTOONS).
        if not matchesTitleRule then return ""
        return "rules"
    end if

    ' Keywords are additive: they broaden membership, never gate it.
    matchesKeyword = false
    if c.hasKeywordRule and p.keywords.Count() > 0 then
        kwHit = false
        for each kw in c.keywordsLower
            if NxHasExact(p.keywords, kw) then
                kwHit = true
                exit for
            end if
        end for
        if kwHit then
            matchesKeyword = c.keywordGenreGateLower.Count() = 0 or NxAnySubstring(itemGenres, c.keywordGenreGateLower)
        end if
    end if

    matchesNetwork = c.hasNetworkRule and p.networks.Count() > 0 and NxAnyContainsAny(p.networks, c.networksLower)

    if c.hasTitleRule or c.hasStudioRule or c.hasGenreInclude or c.hasProdCoRule or c.hasKeywordRule or c.hasNetworkRule then
        if c.hasTitleRule and matchesTitleRule then return "title"
        if matchesKeyword then return "keyword"
        if matchesNetwork then return "network"
        if matchesProdCo then return "prodco"
        if c.hasStudioRule and c.hasGenreInclude then
            if not matchesStudio or not matchesGenre then return ""
        else if c.hasStudioRule then
            if not matchesStudio then return ""
        else if c.hasGenreInclude then
            if not matchesGenre then return ""
            ' Broad genres also need a keyword. Exact match, so gating "Music"
            ' leaves "Musical" alone.
            if c.keywordGatedLower.Count() > 0 and not matchesKeyword then
                for each g in c.keywordGatedLower
                    if NxHasExact(itemGenres, g) then return ""
                end for
            end if
        else
            return ""
        end if
        return "rules"
    end if

    return "rules"
end function

' ── Rule helpers ────────────────────────────────────────────────────────────

function NxManifestClaims(entry as Dynamic, channelId as Dynamic) as Boolean
    if type(entry) <> "roAssociativeArray" then return false
    return NxHasValue(NxList(entry.channels), channelId)
end function

' Mirrors ExclusiveRule.matches and the web filter's exclusiveRuleMatches
' (upstream 805c33e): the item's own title, never the artist; editorial
' titles exact (raw or year-stripped), title words whole words only, genres
' a substring of a tag. `p` is the item's NxFilterItem.
function NxExclusiveRuleMatches(p as Object, itemGenres as Object, rule as Object) as Boolean
    if NxHasExact(rule.editorialLower, p.ownTitle) or NxHasExact(rule.editorialLower, p.ownTitleRaw) then return true
    if NxAnyWord(p.ownTitle, rule.titleWordsRx) then return true
    if rule.genresLower.Count() > 0 and NxAnySubstring(itemGenres, rule.genresLower) then return true
    return false
end function

' Mirrors exclusiveRuleApplies: a lock scoped with `type` (movie|episode) or
' `source` (movie|tv|musicVideo) applies only to items of that kind. The
' holiday lock reads a film's title, so without it Santa Clarita Diet was
' locked to movie channels that never air it.
function NxExclusiveRuleApplies(item as Object, p as Object, rule as Object) as Boolean
    if rule.ruleType <> "" then
        itemType = "movie"
        if NxTruthy(item.type) then itemType = NxToStr(item.type)
        if itemType <> rule.ruleType then return false
    end if
    if rule.ruleSource <> "" and p.source <> rule.ruleSource then return false
    return true
end function

' Mirrors isLeftOffChannels: on Emby a Dolby Vision profile 5 file
' (`doviProfile` 5, from its ExtendedVideoSubType) goes on no channel, as
' Emby 4.10.1 sends it in a form drawn green and purple. Profile 8, an
' unknown profile, and Plex and Jellyfin are untouched.
function NxIsLeftOffChannels(item as Object, backend as String) as Boolean
    if backend <> "emby" then return false
    return NxIsNumber(item.doviProfile) and item.doviProfile = 5
end function

' Mirrors episodeRulesMatch. They read the item's own title: the episode
' title for an episode, the title (year suffix stripped) for anything else,
' so a special stored as a film matches as an episode does. Whole words.
'   - episodeTitleExcludes: a word in the own title vetoes the item
'   - episodeTitleContains: a word in the own title
'   - episodeSummaryContains: a word in the summary
'   - episodeSeasonalTitleContains: a word in the own title, counting only
'     for an episode first aired inside `episodeAirWindow`
function NxEpisodeRulesMatch(item as Object, p as Object, c as Object) as Boolean
    if item.type = "episode" then
        own = p.episodeTitleLower
    else
        own = NxRx("yearSuffix", " \(\d{4}\)(?![\s\S])").Replace(p.ownTitleRaw, "")
    end if
    if own <> "" then
        if NxAnyWord(own, c.episodeExcludesRx) then return false
        if NxAnyWord(own, c.episodeTitleRx) then return true
    end if
    if c.hasEpisodeSummaryRule then
        summary = LCase(NxToStr(item.summary))
        if summary <> "" and NxAnyWord(summary, c.episodeSummaryRx) then return true
    end if
    if c.hasEpisodeSeasonalRule and item.type = "episode" and own <> "" then
        if NxInAirWindow(item, c.airFrom, c.airTo) and NxAnyWord(own, c.episodeSeasonalRx) then return true
    end if
    return false
end function

' "MM-DD" as month * 100 + day, or invalid.
function NxMonthDay(s as Dynamic) as Dynamic
    if not NxIsString(s) then return invalid
    hit = NxRx("monthDay", "^(\d{1,2})-(\d{1,2})$").Match(s.Trim())
    if hit.Count() <> 3 then return invalid
    return hit[1].ToInt() * 100 + hit[2].ToInt()
end function

' Whether the item first aired (originallyAvailableAt, YYYY-MM-DD...) inside
' from..to, inclusive, wrapping the new year when from > to.
function NxInAirWindow(item as Object, from as Dynamic, upTo as Dynamic) as Boolean
    if from = invalid or upTo = invalid or not NxIsString(item.originallyAvailableAt) then return false
    hit = NxRx("isoDate", "^(\d{4})-(\d{2})-(\d{2})").Match(item.originallyAvailableAt)
    if hit.Count() <> 4 then return false
    md = hit[2].ToInt() * 100 + hit[3].ToInt()
    if from <= upTo then return md >= from and md <= upTo
    return md >= from or md <= upTo
end function

function NxPassesYearRange(item as Object, r as Object) as Boolean
    yr = r.yearRange
    if type(yr) <> "roAssociativeArray" then return true
    year = NxReleaseYear(item)
    if year = invalid then return true
    if yr.min <> invalid then
        if year < yr.min then return false
    end if
    if yr.max <> invalid then
        if year > yr.max then return false
    end if
    return true
end function

' Plex `year`, parsed like JS parseInt; invalid when there is none.
function NxParseYear(item as Object) as Dynamic
    y = item.year
    if y = invalid then return invalid
    if NxIsNumber(y) then return y
    if not NxIsString(y) then return invalid
    if y = "" then return invalid
    hit = NxRx("leadingInt", "^\s*([+-]?\d+)").Match(y)
    if hit.Count() < 2 then return invalid
    return hit[1].ToInt()
end function

' Mirrors Swift itemReleaseYear: `year`, else the year of originallyAvailableAt.
function NxReleaseYear(item as Object) as Dynamic
    y = NxFilterItem(item).year
    if y <> invalid then return y
    if NxIsString(item.originallyAvailableAt) then
        hit = NxRx("isoYear", "^(\d{4})-\d{2}-\d{2}").Match(item.originallyAvailableAt)
        if hit.Count() = 2 then return hit[1].ToInt()
    end if
    return invalid
end function

' Upstream: new Date(y, mo - 1, d) < (now with setMonth(getMonth() - months)),
' both in local time. JS rolls an out-of-range day or month forward (Mar 31
' minus one month is "Feb 31", which is Mar 3), which day serials reproduce.
function NxReleasedBefore(y as Integer, mo as Integer, d as Integer, months as Integer, clock as Object) as Boolean
    released = NxDaySerial(y, mo - 1, d) * 86400&
    cutoff = NxDaySerial(clock.year, clock.month - 1 - months, clock.day) * 86400& + clock.secOfDay
    return released < cutoff
end function

' Days since 1970-01-01 for a JS-style (year, zero-based month, day), any of
' which may be out of range. Hinnant's days_from_civil.
function NxDaySerial(y as Integer, monthIndex as Integer, d as Integer) as LongInteger
    yy = y + NxFloorDiv(monthIndex, 12)
    mm = monthIndex - NxFloorDiv(monthIndex, 12) * 12 + 1
    if mm <= 2 then yy = yy - 1
    era = NxFloorDiv(yy, 400)
    yoe = yy - era * 400
    mp = mm + 9
    if mm > 2 then mp = mm - 3
    doy = Int((153 * mp + 2) / 5)
    doe = yoe * 365 + Int(yoe / 4) - Int(yoe / 100) + doy
    serial& = era
    return serial& * 146097 + doe - 719468 + d - 1
end function

function NxFloorDiv(a as Integer, b as Integer) as Integer
    return Int(a / b) ' Int() floors, and / is float division
end function

' The genre locks and adult ratings, built once per thread.
function NxGenreLocks() as Object
    g = GetGlobalAA()
    if g.nxGenreLocks = invalid then
        g.nxGenreLocks = {
            horror: NxSet(["horror"]),
            reality: NxSet(["reality", "game show", "game-show", "reality-tv"]),
            animation: NxSet(["animation", "animated", "cartoon"]),
            documentary: NxSet(["documentary", "docuseries"]),
            war: NxSet(["war", "war & politics"]),
            western: NxSet(["western"]),
            talkShow: NxSet(["talk show", "talk", "news"]),
            adultRatings: NxSet(["R", "NC-17", "TV-MA", "18", "18+", "X", "NR"])
        }
    end if
    return g.nxGenreLocks
end function

' Ratings from other countries, read as the US labels the channel rules use.
' Mirrors upstream's usContentRating (scripts/nostalgex-channel-filter.cjs)
' and the Swift ContentRating.usLabel; scripts/rating-golden.json holds all
' three to it (tests/RatingGoldenTests.brs). Jellyfin and Emby store a
' certificate from outside the US with its country in front ("GB-15", and
' Germany as "FSK-16"), Plex as "gb/15", and some libraries carry the bare
' label ("12A") or "TV-12A". A label it recognises becomes the US label of
' the same age band, a TV label for an episode and a film label for anything
' else. Anything else comes back as it went in, every US label included.
function NxUsContentRating(raw as Dynamic, itemType as Dynamic) as Dynamic
    if not NxIsString(raw) then return raw
    t = NxRatingTables()
    key = t.space.ReplaceAll(UCase(raw), "")
    if key = "" or t.us.DoesExist(key) then return raw
    country = invalid
    label = key
    if Left(key, 3) = "FSK" then
        country = "DE"
        label = Mid(key, 4)
        if Left(label, 1) = "-" then label = Mid(label, 2)
    else
        parts = t.prefix.Match(key)
        if parts.Count() = 3 then
            ' "TV-12A" is a bare 12A, not a country called TV.
            if parts[1] <> "TV" then
                country = parts[1]
                if country = "UK" then country = "GB"
            end if
            label = parts[2]
        end if
    end if
    band = NxRatingAgeBand(label, t)
    if band = invalid then
        if country <> invalid then
            words = t.words[country]
            if words <> invalid then band = words[label]
            if band = invalid and label = "X" then band = "adult"
        else
            band = t.bare[label]
        end if
    end if
    if band = invalid then return raw
    if NxToStr(itemType) = "episode" then return t.bands[band][1]
    return t.bands[band][0]
end function

' One or two digits, then an optional "+": an age. 0 is everyone, up to 10 is
' PG, up to 14 is PG-13 / TV-14, older is R / TV-MA.
function NxRatingAgeBand(label as String, t as Object) as Dynamic
    digits = t.age.Match(label)
    if digits.Count() < 2 then return invalid
    age = digits[1].ToInt()
    if age = 0 then return "all"
    if age <= 10 then return "pg"
    if age <= 14 then return "teen"
    return "mature"
end function

' The rating tables, built once per thread. Keys are upper case, and the
' labels looked up in them are upper-cased first.
function NxRatingTables() as Object
    g = GetGlobalAA()
    if g.nxRatingTables = invalid then
        g.nxRatingTables = {
            bands: {
                all: ["G", "TV-G"],
                pg: ["PG", "TV-PG"],
                teen: ["PG-13", "TV-14"],
                mature: ["R", "TV-MA"],
                adult: ["NC-17", "TV-MA"]
            },
            us: NxSet(["G", "PG", "PG-13", "R", "NC-17", "NR", "TV-Y", "TV-Y7", "TV-Y7-FV", "TV-G", "TV-PG", "TV-14", "TV-MA"]),
            ' Word labels by country. Numbers go by age, for any country.
            words: {
                GB: { "U": "all", "UC": "all", "PG": "pg", "12A": "teen", "12PG": "teen", "R18": "adult" },
                IE: { "G": "all", "PG": "pg", "12A": "teen", "12PG": "teen", "15A": "mature", "15PG": "mature" },
                AU: { "P": "all", "C": "all", "G": "all", "PG": "pg", "M": "mature", "MA15+": "mature", "AV15+": "mature", "R18+": "mature", "X18+": "adult" },
                NZ: { "G": "all", "PG": "pg", "R13": "teen", "RP13": "teen", "M": "mature", "R15": "mature", "R16": "mature", "RP16": "mature", "R18": "mature", "RP18": "mature", "R": "adult" },
                CA: { "C": "all", "G": "all", "C8": "pg", "PG": "pg", "14A": "teen", "18A": "mature", "R": "adult", "A": "adult" },
                FR: { "U": "all", "TP": "all" },
                NL: { "AL": "all", "MG6": "pg" }
            },
            ' A label with no country, or after "TV-": only labels with one
            ' meaning everywhere.
            bare: { "U": "all", "UC": "all", "12A": "teen", "12PG": "teen", "14A": "teen", "15A": "mature", "18A": "mature", "MA15+": "mature", "R18+": "mature", "R18": "adult", "X18+": "adult" },
            space: CreateObject("roRegex", "\s+", ""),
            prefix: CreateObject("roRegex", "^([A-Z]{2})[-/](.+)$", ""),
            age: CreateObject("roRegex", "^(\d{1,2})\+?$", "")
        }
    end if
    return g.nxRatingTables
end function

' Regexes, compiled once per thread.
function NxRx(name as String, pattern as String) as Object
    g = GetGlobalAA()
    if g.nxRx = invalid then g.nxRx = {}
    rx = g.nxRx[name]
    if rx = invalid then
        rx = CreateObject("roRegex", pattern, "")
        g.nxRx[name] = rx
    end if
    return rx
end function

' `\bneedle\b` patterns over lowercased text, as upstream's titleContainsWord.
' An empty needle never matches, so it gets no pattern.
function NxWordPatterns(list as Dynamic) as Object
    out = []
    for each t in NxList(list)
        n = LCase(NxToStr(t))
        if n <> "" then
            escaped = ""
            for i = 1 to n.Len()
                ch = Mid(n, i, 1)
                if Instr(1, ".*+?^${}()|[]\", ch) > 0 then escaped = escaped + "\"
                escaped = escaped + ch
            end for
            out.Push(CreateObject("roRegex", "\b" + escaped + "\b", ""))
        end if
    end for
    return out
end function

function NxAnyWord(haystack as String, patterns as Object) as Boolean
    for each rx in patterns
        if rx.IsMatch(haystack) then return true
    end for
    return false
end function

' ── Small helpers ───────────────────────────────────────────────────────────

' Upstream's enrichedValue: under item.enrichment, else flat on the item.
function NxEnriched(item as Object, key as String) as Dynamic
    e = item.enrichment
    if type(e) = "roAssociativeArray" then
        if e[key] <> invalid then return e[key]
    end if
    return item[key]
end function

function NxLowerList(v as Dynamic) as Object
    out = []
    for each x in NxList(v)
        out.Push(LCase(NxToStr(x)))
    end for
    return out
end function

function NxSet(list as Object) as Object
    s = {}
    s.SetModeCaseSensitive()
    for each x in list
        s[x] = true
    end for
    return s
end function

' Some element of `list` is a key of `set` (case-sensitive).
function NxAnyIn(list as Object, set as Object) as Boolean
    for each x in list
        if set.DoesExist(x) then return true
    end for
    return false
end function

function NxHasExact(list as Object, s as String) as Boolean
    for each x in list
        if x = s then return true
    end for
    return false
end function

' Some haystack in `list` contains some needle in `needles`, as upstream's
' `itemGenres.some((g) => needles.some((n) => g.includes(n)))`.
function NxAnySubstring(list as Object, needles as Object) as Boolean
    for each h in list
        if NxContainsAny(h, needles) then return true
    end for
    return false
end function

function NxAnyContainsAny(list as Object, needles as Object) as Boolean
    return NxAnySubstring(list, needles)
end function

function NxContainsAny(haystack as String, needles as Object) as Boolean
    for each n in needles
        if n = "" or Instr(1, haystack, n) > 0 then return true
    end for
    return false
end function

' Plex GUIDs: `tmdb://456`, or agent URLs containing `tmdb://456`. Takes the
' Plex metadata AA; returns the TMDB id as an Integer, or invalid.
'
' Plex sends both `guid` (a string) and `Guid` (a list), so each is read by
' its exact key. tests/vectors/filter.json has both key orders, which fail on a
' device where the two collide.
function NxParseTmdbIdFromPlex(raw as Object, isEpisode = false as Boolean) as Dynamic
    candidates = []
    if type(raw["Guid"]) = "roArray" then
        for each g in raw["Guid"]
            if type(g) = "roAssociativeArray" then candidates.Push(g.id) else candidates.Push(invalid)
        end for
    end if
    if NxTruthy(raw["guid"]) then candidates.Push(raw["guid"])
    if isEpisode and NxTruthy(raw.grandparentGuid) then candidates.Push(raw.grandparentGuid)
    if isEpisode and NxTruthy(raw.parentGuid) then candidates.Push(raw.parentGuid)
    rx = NxRx("tmdbGuid", "tmdb://(\d+)")
    for each id in candidates
        hit = rx.Match(NxToStr(id))
        if hit.Count() = 2 then return hit[1].ToInt()
    end for
    return invalid
end function
