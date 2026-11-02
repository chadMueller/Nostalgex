' Runs source/collections and source/guide/Franchises.brs against
' scripts/franchise-lineup-golden.json, the file the Apple TV's
' FranchiseLineupGoldenTests.swift and the web tuner's
' scripts/nostalgex-franchise-lineup-smoke.mjs read. Vendored unchanged as
' tests/vectors/franchise-lineup-golden.json by tests/gen-vectors.mjs. The
' answers in it were written by the Apple TV's own code, so a failure here is
' the Roku differing from the Apple TV for the same library, never a stale
' vector.
'
' Each lineup builds one library, applies the stated franchise choices, and
' compares what the Settings list, the folds and the guide's channels come to,
' through the same two steps the library load runs (NxFranchiseStep, then
' NxCollectionsStep). The classifier and the block ordering are checked on
' their own first. Returns the failure count.
'
' Known differences from the Apple TV are listed in NxFlKnownDifference, each
' with what the Roku does and why, and are not counted as failures; a case
' that stops differing is reported, so the list can't go stale.

function NxRunFranchiseLineupTests(goldenPath as String, configPath as String, dictionaryPath as String) as Integer
    golden = ParseJson(ReadAsciiFile(goldenPath))
    config = ParseJson(ReadAsciiFile(configPath))
    dictionary = ParseJson(ReadAsciiFile(dictionaryPath))
    if golden = invalid or config = invalid or dictionary = invalid then
        print "FAIL cannot read "; goldenPath; ", "; configPath; " or "; dictionaryPath
        return 1
    end if
    r = { pass: 0, fail: 0 }
    defs = NxFranchiseDefinitions(dictionary)

    for each c in golden.classifier
        items = []
        for each g in c.items
            items.Push(NxFlItem(g))
        end for
        label = "classifier: " + c.name
        got = NxCollectionClassify(c.title, items)
        NxFlCheck(r, label, got, NxToStr(c.expected))
    end for

    for each b in golden.blocks
        entries = []
        for each e in b.entries
            entries.Push({ name: e.name, id: e.id, films: e.films, value: e.id })
        end for
        k = NxBlockKept(entries, b.capacity)
        NxFlCheck(r, "block: " + b.name, k.kept.Join(",") + " skipped " + k.skipped.ToStr(), b.kept.Join(",") + " skipped " + b.skipped.ToStr())
    end for

    for each s in golden.lineups
        NxFlCheckLineup(r, s, config, defs)
    end for

    print "franchise lineup golden: "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' The Roku item for a golden item.
function NxFlItem(g as Object) as Object
    isEpisode = (g.type = "episode")
    it = { ratingKey: g.id, serverIndex: 0, title: g.title, year: 2000, duration: 7200000, type: g.type, librarySource: "movie", genres: [], tmdbID: g.id }
    if isEpisode then
        it.librarySource = "tv"
        it.duration = 2700000
        it.episodeTitle = "Pilot"
    end if
    if g.episodeTitle <> invalid then it.episodeTitle = g.episodeTitle
    if g.showKey <> invalid then it.showKey = g.showKey
    if g.tmdbID <> invalid then it.tmdbID = g.tmdbID
    if g.genres <> invalid then it.genres = g.genres
    if g.enrichment <> invalid then it.enrichment = g.enrichment
    return it
end function

' Counts a check, or notes a known difference without counting it a failure.
sub NxFlCheck(r as Object, label as String, got as String, want as String)
    known = NxFlKnownDifference(label)
    if known <> "" then
        if got = want then
            r.fail = r.fail + 1
            print "FAIL "; label; ": listed as a known difference ("; known; ") but it now agrees; take it off NxFlKnownDifference"
        else
            r.pass = r.pass + 1
        end if
        return
    end if
    NxCheck(r, label, got, want)
end sub

' Where the Roku and the Apple TV differ for the same library, one line each.
' The key is the check's label.
function NxFlKnownDifference(label as String) as String
    known = NxFlKnownDifferences()
    if known.DoesExist(label) then return known[label]
    return ""
end function

function NxFlKnownDifferences() as Object
    known = {}
    known.SetModeCaseSensitive()
    ' CollectionClassifier.brs counts and compares code points, where Swift compares
    ' Characters: "Ame" + a combining accent is not "Am" + e-acute to it, so the shared
    ' prefix of those titles is shorter. Only combining marks and emoji differ.
    known["classifier: accented prefix, decomposed in one title"] = "code points, not Characters"
    ' With the FRANCHISES package off the Roku folds nothing: its fold targets are the
    ' classics and the found franchises, which it only builds while the package is on
    ' (docs/PORTING.md). The Apple TV folds against the classics that are built and the
    ' franchises it found, package on or not. Franchise collections are out of the guide
    ' while the package is off on both, so only an OTHER COLLECTIONS set that the Apple TV
    ' would fold away (an "IMDb Top Rated" of Star Wars films) airs on the Roku and not there.
    known["lineup the same library, package off: collections"] = "no folds while the package is off"
    return known
end function

function NxFlN(v as Dynamic) as String
    if v = invalid then return "null"
    return NxToStr(v)
end function

function NxFlIds(list as Object) as String
    out = []
    for each it in list
        out.Push(NxToStr(it.ratingKey))
    end for
    return out.Join(",")
end function

function NxFlKind(id as Integer) as String
    if id >= 1020000 then return "otherCollection"
    if id >= 1010000 then return "franchiseCollection"
    return "found"
end function

function NxFlCap(cap as Object, key as String) as String
    if cap.DoesExist(key) then return NxToStr(cap[key])
    return "0"
end function

function NxFlSortedText(lines as Object) as String
    sorted = []
    sorted.Append(lines)
    sorted.Sort()
    return sorted.Join(" / ")
end function

sub NxFlCheckLineup(r as Object, s as Object, config as Object, defs as Object)
    label = "lineup " + s.name + ": "
    items = []
    byID = {}
    byID.SetModeCaseSensitive()
    for each g in s.items
        it = NxFlItem(g)
        items.Push(it)
        byID[g.id] = it
    end for
    bundleIDs = []
    for each b in config.bundles
        if b.id = NxFranchisesBundleID() then bundleIDs = b.channelIDs
    end for

    ' The classics in the lineup, with the pools the lineup states.
    channels = []
    for each def in config.channels
        if NxHasValue(bundleIDs, def.id) then
            ids = s.stock[def.id.ToStr()]
            if ids <> invalid then
                pool = []
                for each id in ids
                    pool.Push(byID[id])
                end for
                channels.Push({ id: def.id, number: def.number, name: def.name, minItems: def.minItems, isPremiereChannel: false, timeRestrictions: invalid, enabled: true, built: true, pool: pool })
            end if
        end if
    end for

    choices = NxFranchiseChoices(s.enabledFranchiseIDs, s.disabledFranchiseIDs)
    rules = NxFilterExclusiveRules(s.exclusiveRules)
    fr = invalid
    if s.packageOn then
        fr = NxFranchiseStep({ channels: channels, items: items, defs: defs, choices: choices, bundleChannelIDs: bundleIDs, manifest: s.manifest, exclusiveRules: rules })
    end if

    allChannels = []
    allChannels.Append(channels)
    if fr <> invalid then allChannels.Append(fr.channels)
    raw = []
    for each c in s.collections
        raw.Push({ id: "0:" + c.id, title: c.title, childKeys: c.members, serverKey: "0" })
    end for
    on = []
    for each id in s.enabledCollectionIDs
        on.Push("0:" + id)
    end for
    cs = NxCollectionsStep({
        channels: allChannels, raw: raw, items: items, serverKeys: {}, manifest: s.manifest,
        enabledKeys: NxCollectionKeySet(on), franchise: fr, franchiseBundleIDs: bundleIDs, defs: defs
    })
    want = s.expected

    ' What the builder found, the classics' pools and the switches: only while the
    ' package is on, as the Roku only runs the franchise step then.
    if fr <> invalid then
        gotFound = []
        for each f in fr.found
            gotFound.Push(f.id + "|" + f.name + "|" + NxFlN(f.coveredByChannelID) + "|" + NxFgBool(f.fromDictionary) + "|" + NxFgBool(f.enabled) + "|" + NxFlIds(f.movies) + "|" + NxFlIds(f.tvItems))
        end for
        wantFound = []
        for each f in want.found
            wantFound.Push(f.id + "|" + f.name + "|" + NxFlN(f.covered) + "|" + NxFgBool(f.fromDictionary) + "|" + NxFgBool(f.enabled) + "|" + f.movies.Join(",") + "|" + f.tvItems.Join(","))
        end for
        NxFlCheck(r, label + "found franchises", gotFound.Join(" / "), wantFound.Join(" / "))

        gotRows = []
        for each row in fr.rows
            gotRows.Push(row.id + "|" + row.name + "|" + row.countLabel + "|" + NxFlN(row.stockChannelID) + "|" + NxFlN(row.channelNumber) + "|" + NxFgBool(row.enabled))
        end for
        wantRows = []
        for each row in want.rows
            wantRows.Push(row.id + "|" + row.name + "|" + row.countLabel + "|" + NxFlN(row.stockChannelID) + "|" + NxFlN(row.channelNumber) + "|" + NxFgBool(row.enabled))
        end for
        NxFlCheck(r, label + "Settings rows", gotRows.Join(" / "), wantRows.Join(" / "))

        off = NxSwitchedOffStockFranchises(defs, choices)
        gotOff = []
        for each k in off
            gotOff.Push(k)
        end for
        wantOff = []
        for each id in want.switchedOffStock
            wantOff.Push(NxToStr(id))
        end for
        NxFlCheck(r, label + "classics switched off", NxFlSortedText(gotOff), NxFlSortedText(wantOff))

        gotPools = []
        for each ch in channels
            gotPools.Push(ch.id.ToStr() + "=" + NxFlIds(ch.pool))
        end for
        wantPools = []
        for each id in want.stockPools
            wantPools.Push(id + "=" + want.stockPools[id].Join(","))
        end for
        NxFlCheck(r, label + "classics' pools", NxFlSortedText(gotPools), NxFlSortedText(wantPools))
    end if

    ' Each collection's category and fold, in the order the lineup lists them.
    gotCollections = []
    wantCollections = []
    for each c in s.collections
        members = []
        for each id in c.members
            members.Push(byID[id])
        end for
        into = "null"
        for each f in cs.folded
            if f.title = UCase(c.title) then into = f.into
        end for
        gotCollections.Push(c.id + "|" + NxCollectionClassify(c.title, members) + "|" + into)
    end for
    for each c in want.collections
        wantCollections.Push(c.id + "|" + c.category + "|" + NxFlN(c.foldedInto))
    end for
    NxFlCheck(r, label + "collections", gotCollections.Join(" / "), wantCollections.Join(" / "))

    ' Every runtime channel: number, id, name, kind and members.
    gotChannels = []
    for each ch in cs.found
        gotChannels.Push(NxFlChannelText(ch))
    end for
    for each ch in cs.channels
        gotChannels.Push(NxFlChannelText(ch))
    end for
    gotChannels.Sort()
    wantChannels = []
    for each ch in want.channels
        wantChannels.Push(NxFlLeftPad(ch.number.ToStr()) + "|" + ch.id.ToStr() + "|" + ch.name + "|" + ch.kind + "|" + ch.items.Join(","))
    end for
    wantChannels.Sort()
    NxFlCheck(r, label + "runtime channels", gotChannels.Join(" / "), wantChannels.Join(" / "))

    ' Found franchises past CH 399 are counted twice over: the franchise step keeps 90
    ' of them, and the collections step trims again when collections share the block.
    ' LibraryTask adds the two, so this does.
    foundPast = cs.overCapFound
    if fr <> invalid then foundPast = foundPast + fr.overCap
    gotCap = "found " + foundPast.ToStr() + " collections " + cs.overCapFranchises.ToStr() + " other " + cs.overCapCustom.ToStr()
    wantCap = "found " + NxFlCap(want.overCap, "foundFranchises") + " collections " + NxFlCap(want.overCap, "collectionFranchises") + " other " + NxFlCap(want.overCap, "otherCollections")
    NxFlCheck(r, label + "channels past their block", gotCap, wantCap)
end sub

' Numbers sort as text, so pad them.
function NxFlLeftPad(s as String) as String
    while Len(s) < 4
        s = "0" + s
    end while
    return s
end function

function NxFlChannelText(ch as Object) as String
    return NxFlLeftPad(ch.number.ToStr()) + "|" + ch.id.ToStr() + "|" + ch.name + "|" + NxFlKind(ch.id) + "|" + NxFlIds(ch.pool)
end function
