' Server collections as channels from CH 500, and the fold that keeps a
' collection which is really a franchise from airing twice.
'
' Copyright (c) 2024 Chad Mueller / Muell Haus Inc. (Nostalgex), MIT License.
' Port copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Source: scripts/nostalgex-collections.js (the web tuner's port of
' AppState+Channels.swift scanCollections and materializeDynamicChannels,
' and CollectionMemberIndex.swift), at the commit in data/UPSTREAM. Checked
' against tests/vectors/collections.json, made by that module.
'
' The fold follows Services/FranchiseCollectionFold.swift, not the web
' tuner's foldTarget, because franchises here follow the Apple TV app
' (docs/PORTING.md): its targets are the stock franchise channels and the
' found franchises (CH 300 up), and it adds the dictionary signals the web
' tuner leaves out. Given only stock channels and no dictionary it answers as
' foldTarget, which the vectors check; the rest is checked by cases from
' CollectionShowsTests.swift and FranchiseSettingsTests.swift
' (tests/CollectionTests.brs).
'
' Not ported:
'   - Jellyfin and Emby BoxSets (fetchBoxSetCollections). The port reads
'     Plex only.
'   - The Apple TV app's FRANCHISES / OTHER COLLECTIONS split
'     (CollectionClassifier). The web tuner doesn't have it either; every
'     collection channel is in CH 500-699.
'
' Differences that don't change which channels air:
'   - Requests run one at a time; upstream asks for four collections'
'     children at once. Its results keep list order, so they are the same.
'   - Text is lowercased with NxFranchiseLower (JS toLowerCase), upper-cased
'     with UCase and sorted by code point, where upstream sorts by UTF-16
'     code unit. The two orders differ only between characters past U+FFFF
'     and those from U+E000 to U+FFFF. JS trim() also removes Unicode spaces
'     that Trim() keeps.
'   - An item's identity is its server and ratingKey (NxFranchiseItemKey).

' Collection channel ids: ChannelIDSpace.dynamicBase + 2 * categoryStride.
function NxCollectionsIDBase() as Integer
    return 1020000
end function

function NxCollectionsNumberBase() as Integer
    return 500
end function

' CH 500-699: anything switched on past the 200th is not built.
function NxCollectionsCapacity() as Integer
    return 200
end function

' A collection needs this many playable items, films plus episodes.
function NxCollectionsMinItems() as Integer
    return 3
end function

function NxCollectionsOverlapThreshold() as Integer
    return 60
end function

' ── Duplicate detection ─────────────────────────────────────────────────────

' cleanTitle: lowercased, "collection" removed, "'s" to "s", trimmed.
function NxCollectionsCleanTitle(title as Dynamic) as String
    s = NxFranchiseLower(NxToStr(title))
    s = s.Replace(" collection", "")
    s = s.Replace("collection", "")
    s = s.Replace("'s", "s")
    s = s.Replace(Chr(8217) + "s", "s")
    return s.Trim()
end function

' decadeNormalized: "2000s" -> "00s", "80s" -> "80s", else invalid. Only
' ASCII digits count.
function NxCollectionsDecade(clean as String) as Dynamic
    digits = ""
    for i = 1 to Len(clean)
        ch = Mid(clean, i, 1)
        if ch >= "0" and ch <= "9" and Len(ch) = 1 then digits = digits + ch
    end for
    if Len(digits) = 4 then
        n = digits.ToInt() mod 100
        if n < 10 then return "0" + n.ToStr() + "s"
        return n.ToStr() + "s"
    end if
    if Len(digits) = 2 then return digits + "s"
    return invalid
end function

' channelLabel: "CH 12 ACTION ADVENTURE".
function NxCollectionsChannelLabel(ch as Object) as String
    n = ch.number
    if n = invalid then n = ch.id
    return "CH " + NxToStr(n) + " " + NxToStr(ch.name)
end function

' True when `part` occurs in `whole`; the empty string occurs in everything.
function NxCollectionsIncludes(whole as String, part as String) as Boolean
    if part = "" then return true
    return Instr(1, whole, part) > 0
end function

' matchStaticChannel: the first stock channel whose name holds the cleaned
' title, or is held by it, or holds its decade. Its label, or invalid.
function NxCollectionsMatchStatic(title as Dynamic, staticChannels as Object) as Dynamic
    clean = NxCollectionsCleanTitle(title)
    if clean = "" then return invalid
    decade = NxCollectionsDecade(clean)
    for each ch in staticChannels
        name = NxFranchiseLower(NxToStr(ch.name))
        if NxCollectionsIncludes(name, clean) or NxCollectionsIncludes(clean, name) then return NxCollectionsChannelLabel(ch)
        if decade <> invalid then
            if NxCollectionsIncludes(name, decade) then return NxCollectionsChannelLabel(ch)
        end if
    end for
    return invalid
end function

' Math.round((count / total) * 100), in Doubles as JS has it: 23 of 40 is
' 57.49999999999999 there, so 57. Int() of a Double is exact here.
function NxCollectionsPercent(count as Integer, total as Integer) as Integer
    c# = count
    t# = total
    p# = (c# / t#) * 100#
    f = Int(p#)
    if p# - f >= 0.5# then f = f + 1
    return f
end function

' contentOverlap: the channel the membership manifest claims the most of these
' items for, when that is `threshold` percent or more of them, as
' { channelID, channelName, overlapCount, totalCount, percent }, else invalid.
' channelsByID is keyed by the channel id as a string.
function NxCollectionsContentOverlap(items as Object, manifest as Dynamic, channelsByID as Object, threshold = 60 as Integer) as Dynamic
    total = items.Count()
    if total = 0 or type(manifest) <> "roAssociativeArray" then return invalid
    if type(manifest.items) <> "roAssociativeArray" then return invalid
    counts = {}
    order = []
    for each it in items
        if it.tmdbID <> invalid then
            mediaType = "movie"
            if it.type = "episode" then mediaType = "tv"
            entry = manifest.items[mediaType + ":" + NxToStr(it.tmdbID)]
            if type(entry) = "roAssociativeArray" then
                for each cid in NxList(entry.channels)
                    k = NxToStr(cid)
                    if counts[k] = invalid then
                        counts[k] = 0
                        order.Push(cid)
                    end if
                    counts[k] = counts[k] + 1
                end for
            end if
        end if
    end for
    best = invalid
    bestCount = 0
    for each cid in order
        n = counts[NxToStr(cid)]
        if best = invalid or n > bestCount then
            best = cid
            bestCount = n
        end if
    end for
    if best = invalid then return invalid
    percent = NxCollectionsPercent(bestCount, total)
    if percent < threshold then return invalid
    ch = channelsByID[NxToStr(best)]
    label = "CH " + NxToStr(best)
    if ch <> invalid then label = NxCollectionsChannelLabel(ch)
    return { channelID: best, channelName: label, overlapCount: bestCount, totalCount: total, percent: percent }
end function

' ── Members (CollectionMemberIndex.swift) ───────────────────────────────────

' Which show an episode belongs to: its show key, else its show title.
function NxCollectionsShowIdentity(it as Object) as String
    if NxIsString(it.showKey) then
        if it.showKey <> "" then return "key:" + it.showKey
    else if it.showKey <> invalid then
        return "key:" + NxToStr(it.showKey)
    end if
    return "title:" + NxToStr(it.title)
end function

' indexLibrary: per server, every item by ratingKey and episodes grouped by
' their show key, as { serverKey: { byKey, byShow } }. An item's server key
' is serverKeys[its serverIndex], else the serverIndex itself.
function NxCollectionsIndexLibrary(items as Object, serverKeys as Object) as Object
    out = {}
    out.SetModeCaseSensitive()
    for each it in items
        if it <> invalid then
            si = NxToStr(it.serverIndex)
            sk = serverKeys[si]
            if sk = invalid then sk = si
            idx = out[sk]
            if idx = invalid then
                idx = { byKey: {}, byShow: {} }
                idx.byKey.SetModeCaseSensitive()
                idx.byShow.SetModeCaseSensitive()
                out[sk] = idx
            end if
            key = NxToStr(it.ratingKey)
            if not idx.byKey.DoesExist(key) then idx.byKey[key] = it
            if it.type = "episode" and it.showKey <> invalid then
                show = NxToStr(it.showKey)
                if show <> "" then
                    if idx.byShow[show] = invalid then idx.byShow[show] = []
                    list = idx.byShow[show]
                    list.Push(it)
                end if
            end if
        end if
    end for
    return out
end function

' resolveMembers: child keys to library items, each once, in child order. A
' film or episode key is that item; a show key is all its episodes.
function NxCollectionsResolve(childKeys as Dynamic, index as Dynamic) as Object
    items = []
    if index = invalid then return items
    seen = {}
    seen.SetModeCaseSensitive()
    for each k in NxList(childKeys)
        key = NxToStr(k)
        it = index.byKey[key]
        if it <> invalid then
            NxCollectionsAddOnce(items, seen, it)
        else if index.byShow.DoesExist(key) then
            for each ep in index.byShow[key]
                NxCollectionsAddOnce(items, seen, ep)
            end for
        end if
    end for
    return items
end function

sub NxCollectionsAddOnce(items as Object, seen as Object, it as Object)
    id = NxToStr(it.ratingKey)
    if not seen.DoesExist(id) then
        seen[id] = true
        items.Push(it)
    end if
end sub

' countMembers: { movies, shows, episodes }.
function NxCollectionsCountMembers(items as Object) as Object
    movies = 0
    shows = {}
    shows.SetModeCaseSensitive()
    for each it in items
        if it.type = "episode" then
            shows[NxCollectionsShowIdentity(it)] = true
        else
            movies = movies + 1
        end if
    end for
    return { movies: movies, shows: shows.Count(), episodes: items.Count() - movies }
end function

' titleRepresentatives: films plus the first episode of each show.
function NxCollectionsRepresentatives(items as Object) as Object
    seen = {}
    seen.SetModeCaseSensitive()
    out = []
    for each it in items
        if it.type <> "episode" then
            out.Push(it)
        else
            show = NxCollectionsShowIdentity(it)
            if not seen.DoesExist(show) then
                seen[show] = true
                out.Push(it)
            end if
        end if
    end for
    return out
end function

function NxCollectionsPlural(n as Integer, one as String, many as String) as String
    if n = 1 then return n.ToStr() + " " + one
    return n.ToStr() + " " + many
end function

' memberSummary: "12 movies", "3 shows · 47 episodes", "2 movies · 1 show".
function NxCollectionsMemberSummary(c as Object) as String
    dot = " " + Chr(183) + " "
    if c.showCount = 0 then return c.movieCount.ToStr() + " movies"
    if c.movieCount = 0 then return NxCollectionsPlural(c.showCount, "show", "shows") + dot + NxCollectionsPlural(c.episodeCount, "episode", "episodes")
    return NxCollectionsPlural(c.movieCount, "movie", "movies") + dot + NxCollectionsPlural(c.showCount, "show", "shows")
end function

' duplicateWarning, without the glyph: the overlap, else the name match.
function NxCollectionsDuplicateWarning(c as Object) as Dynamic
    if c.contentOverlap <> invalid then return c.contentOverlap.percent.ToStr() + "% already on " + c.contentOverlap.channelName
    if c.matchedChannel <> invalid then return "Exists: " + c.matchedChannel
    return invalid
end function

' ── Candidates and channels ─────────────────────────────────────────────────

' buildCandidates. raw: [{ id, title, childKeys, serverKey }].
' indexByServer: NxCollectionsIndexLibrary's result. ctx: staticChannels
' (the stock channels the lineup carries), channelsByID (every channel,
' keyed by id string; defaults to the static ones), manifest, enabledKeys (a
' set of collection ids), and for the fold foldTargets
' (NxCollectionFoldTarget) and defs (NxFranchiseDefinitions; [] for none).
' Returns the candidates in the order the list shows them: upper-cased
' title, stable.
function NxCollectionsBuildCandidates(raw as Object, indexByServer as Object, ctx as Object) as Object
    staticChannels = NxList(ctx.staticChannels)
    channelsByID = ctx.channelsByID
    if channelsByID = invalid then
        channelsByID = {}
        for each ch in staticChannels
            channelsByID[NxToStr(ch.id)] = ch
        end for
    end if
    enabledKeys = ctx.enabledKeys
    if enabledKeys = invalid then enabledKeys = {}
    targets = NxList(ctx.foldTargets)
    defs = NxList(ctx.defs)
    out = []
    for each c in raw
        items = NxCollectionsResolve(c.childKeys, indexByServer[NxToStr(c.serverKey)])
        if items.Count() >= NxCollectionsMinItems() then
            counts = NxCollectionsCountMembers(items)
            title = NxToStr(c.title)
            if title = "" then title = "Untitled"
            candidate = {
                id: NxToStr(c.id), title: UCase(title),
                movieCount: counts.movies, showCount: counts.shows, episodeCount: counts.episodes,
                items: items, enabled: enabledKeys.DoesExist(NxToStr(c.id)),
                matchedChannel: NxCollectionsMatchStatic(c.title, staticChannels),
                ' One entry per show, so a long show does not outweigh the rest.
                contentOverlap: NxCollectionsContentOverlap(NxCollectionsRepresentatives(items), ctx.manifest, channelsByID),
                foldedInto: invalid
            }
            candidate.foldedInto = NxCollectionFold(candidate, targets, defs)
            ' Stable insertion by title, code-point order.
            i = out.Count()
            out.Push(candidate)
            while i > 0 and NxFranchiseCompare(candidate.title, out[i - 1].title) < 0
                out[i] = out[i - 1]
                i = i - 1
            end while
            out[i] = candidate
        end if
    end for
    return out
end function

' materialize: switched-on, unfolded candidates in list order take CH 500
' up, 200 at most. Returns { channels, overCap }. The channels have the shape
' the library load builds; their pool is the collection, in its order, as
' the web tuner airs it.
function NxCollectionsMaterialize(candidates as Object) as Object
    channels = []
    overCap = 0
    slot = 0
    colors = NxFranchiseColors()
    for each c in candidates
        if c.enabled and c.foldedInto = invalid then
            if slot >= NxCollectionsCapacity() then
                overCap = overCap + 1
            else
                pool = []
                pool.Append(c.items)
                channels.Push({
                    id: NxCollectionsIDBase() + slot, number: NxCollectionsNumberBase() + slot,
                    name: c.title, colorHex: colors[slot mod colors.Count()],
                    minItems: NxCollectionsMinItems(), isPremiereChannel: false, timeRestrictions: invalid,
                    enabled: c.items.Count() >= NxCollectionsMinItems(), built: true,
                    collection: true, collectionID: c.id, pool: pool
                })
                slot = slot + 1
            end if
        end if
    end for
    return { channels: channels, overCap: overCap }
end function

' ── The franchise fold (FranchiseCollectionFold.swift) ──────────────────────

' A franchise a collection can fold into: one stock channel (label
' "CH 100 STAR WARS", stockChannelID set) or one found franchise (label its
' name, dictionaryName set when the dictionary made it). itemKeys is a set
' of NxFranchiseItemKey over what it already airs.
function NxCollectionFoldTarget(label as String, items as Object, dictionaryName as Dynamic, stockChannelID as Dynamic) as Object
    keys = {}
    keys.SetModeCaseSensitive()
    for each it in items
        keys[NxFranchiseItemKey(it)] = true
    end for
    return { label: label, itemKeys: keys, dictionaryName: dictionaryName, stockChannelID: stockChannelID }
end function

' The label of the franchise this candidate folds into, or invalid. A
' folded collection is hidden and never built, so it folds only into a
' franchise that already airs an episode of each show it holds.
function NxCollectionFold(collection as Object, targets as Object, defs as Object, threshold = 60 as Integer) as Dynamic
    if targets.Count() = 0 then return invalid
    target = NxCollectionFoldPick(collection, targets, defs, threshold)
    if target = invalid then return invalid
    if not NxCollectionCarriesEveryShow(collection, target) then return invalid
    return target.label
end function

function NxCollectionCarriesEveryShow(collection as Object, target as Object) as Boolean
    covered = {}
    covered.SetModeCaseSensitive()
    for each it in collection.items
        if it.type = "episode" then
            show = NxCollectionsShowIdentity(it)
            ' Once one episode of a show is aired there, the show is covered.
            already = false
            if covered.DoesExist(show) then already = covered[show]
            if not already then covered[show] = target.itemKeys.DoesExist(NxFranchiseItemKey(it))
        end if
    end for
    for each show in covered
        if not covered[show] then return false
    end for
    return true
end function

function NxCollectionFoldPick(collection as Object, targets as Object, defs as Object, threshold as Integer) as Dynamic
    stockByID = {}
    available = []
    for each t in targets
        if t.stockChannelID <> invalid then
            stockByID[NxToStr(t.stockChannelID)] = t
            available.Push(t.stockChannelID)
        end if
    end for

    ' 1. Dictionary truth from enrichment: 2+ members share a franchise id
    '    the dictionary maps to a stock channel in the lineup.
    sid = NxFranchiseCollectionStockChannel(collection.items, defs, available)
    if sid <> invalid then
        t = stockByID[NxToStr(sid)]
        if t <> invalid then
            collection.foldWhy = "franchise id"
            return t
        end if
    end if

    ' 2. Dictionary by title: into the stock channel when there is one, else
    '    the found franchise the same entry made.
    def = NxFranchiseMatchFilm(collection.title, defs)
    if def <> invalid then
        collection.foldWhy = "title (" + NxToStr(def.canonicalName) + ")"
        if def.stockChannelID <> invalid then
            t = stockByID[NxToStr(def.stockChannelID)]
            if t <> invalid then return t
        end if
        for each t in targets
            if t.dictionaryName <> invalid then
                if t.dictionaryName = def.canonicalName then return t
            end if
        end for
    end if

    ' 3. The scan's own signals, when they point at a stock franchise channel.
    if collection.matchedChannel <> invalid then
        for each t in targets
            if t.stockChannelID <> invalid and t.label = collection.matchedChannel then
                collection.foldWhy = "name match"
                return t
            end if
        end for
    end if
    if collection.contentOverlap <> invalid then
        t = stockByID[NxToStr(collection.contentOverlap.channelID)]
        if t <> invalid then
            collection.foldWhy = "manifest overlap"
            return t
        end if
    end if

    ' 4. Plain item overlap: most of the collection already in one pool.
    total = collection.items.Count()
    if total = 0 then return invalid
    best = invalid
    bestCount = 0
    for each t in targets
        n = 0
        for each it in collection.items
            if t.itemKeys.DoesExist(NxFranchiseItemKey(it)) then n = n + 1
        end for
        if n > bestCount then
            best = t
            bestCount = n
        end if
    end for
    if best <> invalid then
        if NxCollectionsPercent(bestCount, total) >= threshold then
            collection.foldWhy = "item overlap " + bestCount.ToStr() + " of " + total.ToStr()
            return best
        end if
    end if
    return invalid
end function

' ── Plex ────────────────────────────────────────────────────────────────────

' fetchPlexCollections: every collection in the server's movie and TV
' sections, deduped by ratingKey, with its child keys, as
' [{ id: "<serverKey>:<ratingKey>", title, childKeys, serverKey }], or
' invalid when the section list fails (upstream throws). A section whose
' collections fail is skipped, and a collection whose children fail is
' dropped. fetcher.getJSON(path) returns the parsed document or invalid;
' fetcher.getMany(paths), when it has one, returns them all in order, which
' lets the Plex fetcher keep several requests in flight.
function NxCollectionsFetchPlex(serverKey as String, fetcher as Object, progress = invalid as Dynamic) as Dynamic
    doc = fetcher.getJSON("/library/sections")
    if type(doc) <> "roAssociativeArray" then return invalid
    sections = []
    if type(doc.MediaContainer) = "roAssociativeArray" then sections = NxList(doc.MediaContainer.Directory)
    list = []
    seen = {}
    seen.SetModeCaseSensitive()
    for each section in sections
        if type(section) = "roAssociativeArray" then
            if section.type = "movie" or section.type = "show" then
                data = fetcher.getJSON("/library/sections/" + NxToStr(section.key) + "/collections")
                if type(data) = "roAssociativeArray" then
                    rows = []
                    if type(data.MediaContainer) = "roAssociativeArray" then rows = NxList(data.MediaContainer.Metadata)
                    for each c in rows
                        if type(c) = "roAssociativeArray" then
                            if c.ratingKey <> invalid then
                                k = NxToStr(c.ratingKey)
                                if not seen.DoesExist(k) then
                                    seen[k] = true
                                    list.Push(c)
                                end if
                            end if
                        end if
                    end for
                end if
            end if
        end if
    end for
    out = []
    done = 0
    batch = 25
    docs = []
    for i = 0 to list.Count() - 1
        c = list[i]
        if i mod batch = 0 then
            paths = []
            for j = i to i + batch - 1
                if j < list.Count() then paths.Push("/library/collections/" + NxToStr(list[j].ratingKey) + "/children")
            end for
            if fetcher.getMany <> invalid then
                docs = fetcher.getMany(paths)
            else
                docs = []
                for each path in paths
                    docs.Push(fetcher.getJSON(path))
                end for
            end if
        end if
        data = docs[i mod batch]
        done = done + 1
        if progress <> invalid then
            progress.progress = "Reading collections: " + done.ToStr() + " of " + list.Count().ToStr()
            progress.bar = done / list.Count()
            progress.barCaption = "Collection " + done.ToStr() + " of " + list.Count().ToStr()
        end if
        if type(data) = "roAssociativeArray" then
            childKeys = []
            if type(data.MediaContainer) = "roAssociativeArray" then
                for each row in NxList(data.MediaContainer.Metadata)
                    if type(row) = "roAssociativeArray" then childKeys.Push(NxToStr(row.ratingKey)) else childKeys.Push("")
                end for
            end if
            title = NxToStr(c.title)
            if not NxTruthy(c.title) then title = "Untitled"
            out.Push({ id: serverKey + ":" + NxToStr(c.ratingKey), title: title, childKeys: childKeys, serverKey: serverKey })
        end if
    end for
    return out
end function

' ── The library load's collections step ─────────────────────────────────────

' refreshCollectionChannels, run after the stock pools and the franchise
' step are built. opts: channels (every channel built so far, channels.json
' entries as LibraryTask builds them plus found franchise channels), raw (the
' scanned collections), items (the library), serverKeys (serverIndex string
' to the collection id's server key), manifest, enabledKeys
' (NxSavedCollectionKeys), and, while the FRANCHISES package is on,
' franchise (NxFranchiseStep's result), franchiseBundleIDs and defs.
'
' Returns { channels (the collection channels to add), rows (Settings: every
' collection that didn't fold, as { id, title, detail, enabled,
' channelNumber }), folded ([{ title, into }]), overCap }.
function NxCollectionsStep(opts as Object) as Object
    ' What the scan compares against: every stock channel built with enough
    ' to air, its package on or not (the web tuner's staticChannels).
    staticChannels = []
    channelsByID = {}
    for each ch in opts.channels
        if ch.id < NxFranchiseIDBase() then
            channelsByID[NxToStr(ch.id)] = ch
            minItems = 50
            if NxTruthy(ch.minItems) then minItems = ch.minItems
            if ch.built = true and ch.pool.Count() >= minItems then staticChannels.Push(ch)
        end if
    end for

    ' Fold targets: the package's classics among them, then the found
    ' franchises no classic covers, switched on or not (applyFranchiseFolds).
    targets = []
    defs = NxList(opts.defs)
    if opts.franchise <> invalid then
        for each ch in staticChannels
            if NxHasValue(NxList(opts.franchiseBundleIDs), ch.id) then
                dictName = invalid
                for each d in defs
                    if d.stockChannelID <> invalid then
                        if d.stockChannelID = ch.id and dictName = invalid then dictName = d.canonicalName
                    end if
                end for
                targets.Push(NxCollectionFoldTarget(NxCollectionsChannelLabel(ch), ch.pool, dictName, ch.id))
            end if
        end for
        for each f in opts.franchise.found
            if f.coveredByChannelID = invalid then
                members = []
                members.Append(f.movies)
                members.Append(f.tvItems)
                dictName = invalid
                if f.fromDictionary then dictName = f.name
                targets.Push(NxCollectionFoldTarget(f.name, members, dictName, invalid))
            end if
        end for
    end if

    index = NxCollectionsIndexLibrary(opts.items, opts.serverKeys)
    candidates = NxCollectionsBuildCandidates(opts.raw, index, {
        staticChannels: staticChannels, channelsByID: channelsByID, manifest: opts.manifest,
        enabledKeys: opts.enabledKeys, foldTargets: targets, defs: defs
    })
    built = NxCollectionsMaterialize(candidates)
    numberOf = {}
    numberOf.SetModeCaseSensitive()
    for each ch in built.channels
        numberOf[ch.collectionID] = ch.number
    end for
    rows = []
    folded = []
    for each c in candidates
        if c.foldedInto <> invalid then
            folded.Push({ title: c.title, into: c.foldedInto, why: NxToStr(c.foldWhy), items: c.items.Count() })
        else
            detail = NxCollectionsDuplicateWarning(c)
            if detail = invalid then detail = NxCollectionsMemberSummary(c)
            rows.Push({ id: c.id, title: c.title, detail: detail, enabled: c.enabled, channelNumber: numberOf[c.id] })
        end if
    end for
    return { channels: built.channels, rows: rows, folded: folded, overCap: built.overCap }
end function
