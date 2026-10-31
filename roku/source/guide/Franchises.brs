' Franchise channels in the guide: what the builder found, turned into
' channels and Settings rows, as the Apple TV app does.
'
' Copyright (c) 2024 Chad Mueller / Muell Haus Inc. (Nostalgex), MIT License.
' Port copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Source: upstream Nostalgex/App/AppState+Franchises.swift (FoundFranchise,
' FranchiseListRow, franchiseListRows, isStockFranchiseOn,
' switchedOffStockFranchiseChannelIDs, rebuildFoundFranchises, stockPools,
' isLockedElsewhere, recordFranchiseChoice) and AppState+Channels.swift
' (materializeDynamicChannels, applyBundleFilter), at the commit in
' data/UPSTREAM. The web tuner doesn't call the franchise builder, so the
' Apple TV app is the reference here; the maintainer asked for that on
' Discussion #8 (discussioncomment-18953180). Cases are transcribed from
' FranchiseSettingsTests.swift and FranchiseNumberingTests.swift
' (tests/FranchiseGuideTests.brs).
'
' Folding server collections into franchises is in
' source/collections/Collections.brs. Differences that don't change which
' channels air:
'
' - Settings sorts by NxFranchiseNaturalLess, a case-insensitive compare with
'   digit runs compared as numbers. Swift's localizedStandardCompare does the
'   same for the upper-case ASCII names franchises.json and TMDB give.
' - An item's identity is its server and ratingKey (NxFranchiseItemKey), where
'   Swift uses the item's id.

' DynamicChannelBlock.foundFranchises: ids from 1,000,000
' (ChannelIDSpace.dynamicBase), display numbers 310 to 399, after the stock
' FRANCHISES package's 300-309. Each kind of runtime channel has its own
' fixed block (found franchises 310-399, franchise collections 400-449,
' other collections 450-499; HIGH ROTATION owns 500 up), so switching one
' kind never moves another's numbers or ids. Until 1.0.29 the blocks were
' 300-449, 450-499 and 500-699.
function NxFranchiseIDBase() as Integer
    return 1000000
end function

function NxFranchiseNumberBase() as Integer
    return 310
end function

function NxFranchiseCapacity() as Integer
    return 90
end function

' AppState.collectionColors.
function NxFranchiseColors() as Object
    return ["#E74C3C", "#3498DB", "#2ECC71", "#F39C12", "#9B59B6", "#1ABC9C", "#E67E22", "#00CED1", "#FF6B81", "#A29BFE"]
end function

function NxFranchiseItemKey(item as Object) as String
    return NxToStr(item.serverIndex) + "|" + NxToStr(item.ratingKey)
end function

' ── The library load's franchise step ───────────────────────────────────────

' Everything the FRANCHISES package adds to a lineup, run after the stock
' pools are built and before they are scheduled, as rebuildFoundFranchises
' then materializeDynamicChannels run after the pool build upstream.
'
' opts: channels (channels.json entries as LibraryTask builds them: `built`
' when the pool was filtered, `enabled` when it passed minItems), items (the
' library), defs (NxFranchiseDefinitions), choices (NxFranchiseChoices),
' bundleChannelIDs (the package's channel ids), manifest, exclusiveRules.
'
' Unions covered franchises into their stock pools, switches off the
' classics the viewer turned off, and returns { found, channels (the found
' franchise channels to add), overCap (switched on past CH 399), rows
' (Settings) }. Call it only while the
' package is on: upstream unions and shows found channels only then.
function NxFranchiseStep(opts as Object) as Object
    available = []
    for each ch in opts.channels
        if ch.built = true and ch.enabled and NxHasValue(opts.bundleChannelIDs, ch.id) then available.Push(ch.id)
    end for
    movies = []
    tv = []
    for each it in opts.items
        ' Music videos sit in movie-typed libraries; they are never franchise films.
        src = it.librarySource
        if not NxTruthy(src) then src = "movie"
        if it.type = "movie" and src = "movie" then movies.Push(it)
        if it.type = "episode" then tv.Push(it)
    end for
    groupings = NxFranchiseBuild({ movies: movies, tvItems: tv, defs: opts.defs, availableStockChannelIDs: available })
    found = NxFoundFranchises(groupings, opts.choices, opts.defs)

    ' Only channels kept after the minItems cut take the union.
    kept = []
    for each ch in opts.channels
        if ch.built = true and ch.enabled then kept.Push(ch)
    end for
    NxFranchiseUnionStockPools(kept, found, opts.manifest, opts.exclusiveRules)

    ' Rows count the kept pools, switched off or not.
    rows = NxFranchiseListRows(opts.bundleChannelIDs, kept, opts.channels, found, opts.defs, opts.choices)
    off = NxSwitchedOffStockFranchises(opts.defs, opts.choices)
    for each ch in opts.channels
        if off.DoesExist(ch.id.ToStr()) then ch.enabled = false
    end for
    block = NxFranchiseBlock(found)
    return { found: found, channels: block.channels, overCap: block.skipped, rows: rows }
end function

' ── Stock switches ──────────────────────────────────────────────────────────

' switchedOffStockFranchiseChannelIDs, as a set keyed by channel id.
function NxSwitchedOffStockFranchises(defs as Object, choices as Object) as Object
    out = {}
    for each d in defs
        if d.stockChannelID <> invalid then
            if not NxStockFranchiseOn("dict:" + d.canonicalName, choices) then out[d.stockChannelID.ToStr()] = true
        end if
    end for
    return out
end function

' ── Found franchises ────────────────────────────────────────────────────────

' rebuildFoundFranchises after the builder: each grouping with the stock
' channel it folds into (or invalid) and, for the rest, whether it is on.
function NxFoundFranchises(groupings as Object, choices as Object, defs as Object) as Object
    out = []
    for each g in groupings
        covered = invalid
        if g.placement.type = "stock" then covered = g.placement.channelID
        enabled = false
        if covered = invalid then enabled = NxFranchiseIsOn(g.stableID, choices.enabled, choices.disabled, defs)
        out.Push({
            id: g.stableID, name: g.name, movies: g.movies, tvItems: g.tvItems,
            coveredByChannelID: covered, fromDictionary: g.fromDictionary, enabled: enabled
        })
    end for
    return out
end function

function NxFranchiseShowCount(tvItems as Object) as Integer
    shows = {}
    shows.SetModeCaseSensitive()
    for each it in tvItems
        shows[NxToStr(it.title)] = true
    end for
    return shows.Count()
end function

' FoundFranchise.countLabel: "3 movies", "1 movie", "5 movies, 2 shows".
function NxFranchiseCountParts(movies as Integer, shows as Integer) as String
    parts = []
    if movies = 1 then parts.Push("1 movie")
    if movies > 1 then parts.Push(movies.ToStr() + " movies")
    if shows = 1 then parts.Push("1 show")
    if shows > 1 then parts.Push(shows.ToStr() + " shows")
    return parts.Join(", ")
end function

' FranchiseListRow.countLabel: the same, never empty.
function NxFranchiseCountLabel(movies as Integer, shows as Integer) as String
    s = NxFranchiseCountParts(movies, shows)
    if s = "" then return "None in your library yet"
    return s
end function

' ── Stock pools ─────────────────────────────────────────────────────────────

' stockPools: each covered franchise's movies and shows join its stock
' channel's pool, skipping what the pool already has and what another channel
' owns. Only for channels in `channels` that were built (`built` true), which
' are the ones upstream keeps after the minItems cut. Changes pools in place.
sub NxFranchiseUnionStockPools(channels as Object, found as Object, manifest as Dynamic, exclusiveRules as Object)
    extras = {}
    for each f in found
        if f.coveredByChannelID <> invalid then
            k = f.coveredByChannelID.ToStr()
            if extras[k] = invalid then extras[k] = []
            extras[k].Append(f.movies)
            extras[k].Append(f.tvItems)
        end if
    end for
    if extras.Count() = 0 then return
    for each ch in channels
        additions = extras[ch.id.ToStr()]
        if additions <> invalid and ch.built = true then
            seen = {}
            seen.SetModeCaseSensitive()
            for each it in ch.pool
                seen[NxFranchiseItemKey(it)] = true
            end for
            for each it in additions
                key = NxFranchiseItemKey(it)
                if not seen.DoesExist(key) and not NxFranchiseLockedElsewhere(it, ch.id, manifest, exclusiveRules) then
                    ch.pool.Push(it)
                    seen[key] = true
                end if
            end for
        end if
    end for
end sub

' isLockedElsewhere: a manifest lock to another channel, or an exclusive rule
' that doesn't list this channel and matches the item or claims it through
' the manifest. The same two locks the filter honours.
function NxFranchiseLockedElsewhere(item as Object, channelId as Integer, manifest as Dynamic, exclusiveRules as Object) as Boolean
    p = NxFilterItem(item)
    entry = invalid
    if manifest <> invalid and p.manifestKey <> invalid then
        if type(manifest.items) = "roAssociativeArray" then entry = manifest.items[p.manifestKey]
    end if
    if type(entry) = "roAssociativeArray" then
        if entry.exclusive <> invalid then
            if entry.exclusive <> channelId then return true
        end if
    end if
    for each rule in exclusiveRules
        if not NxHasValue(rule.ids, channelId) then
            if NxExclusiveRuleMatches(p, p.genres, rule) then return true
            if rule.manifestExclusive and type(entry) = "roAssociativeArray" then
                for each claimed in NxList(entry.channels)
                    if NxHasValue(rule.ids, claimed) then return true
                end for
            end if
        end if
    end for
    return false
end function

' ── Channels ────────────────────────────────────────────────────────────────

' materializeDynamicChannels, found franchises: one channel per found
' franchise that is switched on and not covered by a stock channel, in the
' block CH 300-449 (NxBlockKept). Their pools are the franchise's items,
' movies first. Returns { channels, skipped }.
function NxFranchiseBlock(found as Object) as Object
    entries = []
    for each f in found
        if f.enabled and f.coveredByChannelID = invalid then
            entries.Push({ name: NxToStr(f.name), id: NxToStr(f.id), films: NxList(f.movies).Count(), value: f })
        end if
    end for
    kept = NxBlockKept(entries, NxFranchiseCapacity())
    out = []
    colors = NxFranchiseColors()
    for slot = 0 to kept.kept.Count() - 1
        f = kept.kept[slot]
        pool = []
        pool.Append(f.movies)
        pool.Append(f.tvItems)
        out.Push({
            id: NxFranchiseIDBase() + slot, number: NxFranchiseNumberBase() + slot,
            name: f.name, colorHex: colors[slot mod colors.Count()],
            minItems: 3, isPremiereChannel: false, timeRestrictions: invalid,
            enabled: true, built: true, pool: pool
        })
    end for
    return { channels: out, skipped: kept.skipped }
end function

function NxFranchiseChannels(found as Object) as Object
    return NxFranchiseBlock(found).channels
end function

' ── Full blocks (DynamicChannelBlock.keptInDisplayOrder) ─────────────────────

' The switched-on entries a block keeps, in the order they are numbered.
' entries: [{ name, id, films, value }]. When more are on than fit, the ones
' with the most films stay; ties go to the name, then the stable id, so
' every platform drops the same ones. The kept ones are numbered by name,
' then id. Returns { kept (their values, in number order), skipped }.
function NxBlockKept(entries as Object, capacity as Integer) as Object
    for each e in entries
        e.key = NxBlockNameKey(NxToStr(e.name))
    end for
    skipped = 0
    pick = entries
    if entries.Count() > capacity then
        byFilms = NxBlockSort(entries, true)
        pick = []
        for i = 0 to capacity - 1
            pick.Push(byFilms[i])
        end for
        skipped = entries.Count() - capacity
    end if
    kept = []
    for each e in NxBlockSort(pick, false)
        kept.Push(e.value)
    end for
    return { kept: kept, skipped: skipped }
end function

' Swift's `<` on the names and ids: case-sensitive, character by character
' (upper case before lower), not the natural, case-insensitive order
' Settings lists by. Swift compares canonically equivalent text as equal
' (a precomposed é and e with a combining accent), ordering by NFC, so names
' compare by NxBlockNameKey. BrightScript's string `<` then compares the
' same way for the text names and ids hold (tests/CollectionTests.brs
' checks it on the TV); Swift orders by Unicode scalar, the interpreter by
' UTF-16 unit, which differ only past U+FFFF.
function NxBlockLess(a as Object, b as Object, byFilms as Boolean) as Boolean
    if byFilms and a.films <> b.films then return a.films > b.films
    if a.key <> b.key then return a.key < b.key
    return a.id < b.id
end function

' A name as Swift compares it: composed (NxFranchiseCompose).
function NxBlockNameKey(name as String) as String
    return NxFranchiseCompose(name)
end function

' A stable merge sort by NxBlockLess; a new list.
function NxBlockSort(list as Object, byFilms as Boolean) as Object
    n = list.Count()
    if n <= 1 then
        out = []
        out.Append(list)
        return out
    end if
    half = n \ 2
    left = []
    right = []
    for i = 0 to n - 1
        if i < half then left.Push(list[i]) else right.Push(list[i])
    end for
    left = NxBlockSort(left, byFilms)
    right = NxBlockSort(right, byFilms)
    out = []
    i = 0
    j = 0
    while i < left.Count() and j < right.Count()
        if NxBlockLess(right[j], left[i], byFilms) then
            out.Push(right[j])
            j = j + 1
        else
            out.Push(left[i])
            i = i + 1
        end if
    end while
    while i < left.Count()
        out.Push(left[i])
        i = i + 1
    end while
    while j < right.Count()
        out.Push(right[j])
        j = j + 1
    end while
    return out
end function

' ── Settings ────────────────────────────────────────────────────────────────

' franchiseListRows: every stock classic in the package, built or not, and
' every found franchise that isn't covered by one, alphabetical. A stock row
' counts its channel's pool, less the films a non-stock dictionary franchise
' owns (Spider-Man's MCU films also pass MARVEL's studio rule). `channels`
' are the channels kept after the minItems cut; `bundleChannelIDs` the
' package's channel ids; `allChannels` every channel channels.json lists,
' kept or not, which a row's number comes from: a classic cut for too few
' films has no kept channel, and its number is still its channel's, not its
' id (STAR WARS is id 100 and CH 103), as the Apple TV reads allChannels.
' Rows: { id, name, countLabel, stockChannelID, channelNumber, enabled }.
function NxFranchiseListRows(bundleChannelIDs as Object, channels as Object, allChannels as Object, found as Object, defs as Object, choices as Object) as Object
    claimed = {}
    claimed.SetModeCaseSensitive()
    for each f in found
        if f.fromDictionary and f.coveredByChannelID = invalid then
            for each it in f.movies
                claimed[NxFranchiseItemKey(it)] = true
            end for
            for each it in f.tvItems
                claimed[NxFranchiseItemKey(it)] = true
            end for
        end if
    end for
    byStock = {}
    for each d in defs
        if d.stockChannelID <> invalid then byStock[d.stockChannelID.ToStr()] = d
    end for

    rows = []
    seen = {}
    seen.SetModeCaseSensitive()
    for each channelId in bundleChannelIDs
        def = byStock[channelId.ToStr()]
        if def <> invalid then
            ch = invalid
            for each c in channels
                if c.id = channelId then ch = c
            end for
            movies = 0
            tv = []
            number = channelId
            for each c in allChannels
                if c.id = channelId then number = NxChNum(c)
            end for
            if ch <> invalid then
                for each it in ch.pool
                    if not claimed.DoesExist(NxFranchiseItemKey(it)) then
                        if it.type = "movie" then movies = movies + 1
                        if it.type = "episode" then tv.Push(it)
                    end if
                end for
            end if
            id = "dict:" + def.canonicalName
            rows.Push({
                id: id, name: def.canonicalName,
                countLabel: NxFranchiseCountLabel(movies, NxFranchiseShowCount(tv)),
                stockChannelID: channelId, channelNumber: number,
                enabled: NxStockFranchiseOn(id, choices)
            })
            seen[id] = true
        end if
    end for
    for each f in found
        if f.coveredByChannelID = invalid and not seen.DoesExist(f.id) then
            rows.Push({
                id: f.id, name: f.name,
                countLabel: NxFranchiseCountParts(f.movies.Count(), NxFranchiseShowCount(f.tvItems)),
                stockChannelID: invalid, channelNumber: invalid, enabled: f.enabled
            })
        end if
    end for

    ' Insertion sort: name, then id.
    sorted = []
    for each r in rows
        i = sorted.Count()
        sorted.Push(r)
        while i > 0 and NxFranchiseRowLess(r, sorted[i - 1])
            sorted[i] = sorted[i - 1]
            i = i - 1
        end while
        sorted[i] = r
    end for
    return sorted
end function

function NxFranchiseRowLess(a as Object, b as Object) as Boolean
    c = NxFranchiseNaturalCompare(a.name, b.name)
    if c <> 0 then return c < 0
    return a.id < b.id
end function

' -1, 0 or 1. Case-insensitive; runs of ASCII digits compare as numbers.
function NxFranchiseNaturalCompare(a as String, b as String) as Integer
    x = LCase(a)
    y = LCase(b)
    i = 1
    j = 1
    while i <= Len(x) and j <= Len(y)
        cx = Mid(x, i, 1)
        cy = Mid(y, j, 1)
        if NxFranchiseIsDigit(cx) and NxFranchiseIsDigit(cy) then
            si = i
            while i <= Len(x) and NxFranchiseIsDigit(Mid(x, i, 1))
                i = i + 1
            end while
            sj = j
            while j <= Len(y) and NxFranchiseIsDigit(Mid(y, j, 1))
                j = j + 1
            end while
            nx = Val(Mid(x, si, i - si))
            ny = Val(Mid(y, sj, j - sj))
            if nx < ny then return -1
            if nx > ny then return 1
        else
            if cx < cy then return -1
            if cx > cy then return 1
            i = i + 1
            j = j + 1
        end if
    end while
    if Len(x) - i < Len(y) - j then return -1
    if Len(x) - i > Len(y) - j then return 1
    return 0
end function

function NxFranchiseIsDigit(ch as String) as Boolean
    return ch >= "0" and ch <= "9" and Len(ch) = 1
end function
