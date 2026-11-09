' The filter's reads of enrichment fields (NxEnriched, source/filter/
' ChannelFilter.brs) against a library read back from its save. On a TV the
' keys FormatJson writes are lower case, and ParseJson gives case-sensitive
' AAs, so a saved title comes back holding "imdbrating", not "imdbRating", and
' a bracket read by the camelCase name misses it. A ratingMin channel then
' falls back to no rating where a fresh load had one, and the pools differ
' from one launch to the next. The off-TV interpreter keeps ParseJson's AAs
' case-insensitive, so the lower-cased copy below is built by hand, which is
' how the TV holds it; the round trip through FormatJson and ParseJson is
' checked too, for the TV. Returns the failure count.
function NxRunFilterCaseTests(configPath as String, manifestPath as String) as Integer
    r = { pass: 0, fail: 0 }
    config = ParseJson(ReadAsciiFile(configPath))
    manifest = ParseJson(ReadAsciiFile(manifestPath))
    exclusive = NxFilterExclusiveRules(config.exclusiveRules)
    clock = NxFilterClock(1792195200&)

    ' ── NxEnriched by either spelling ───────────────────────────────────────
    lower = NxFcLowerCopy({ imdbRating: 7.1, enrichment: { imdbVotes: 900, productionCompanies: ["A24"] } })
    NxCheck(r, "enriched: a field on the item, read back lower case", NxToStr(NxEnriched(lower, "imdbRating")), "7.1")
    NxCheck(r, "enriched: a field in the record, read back lower case", NxToStr(NxEnriched(lower, "imdbVotes")), "900")
    NxCheck(r, "enriched: a list in the record", NxToStr(NxList(NxEnriched(lower, "productionCompanies")).Count()), "1")
    NxCheck(r, "enriched: a field it doesn't hold", (NxEnriched(lower, "metacriticScore") = invalid).ToStr(), "true")
    fresh = { imdbRating: 6.5, enrichment: { imdbRating: 8.2 } }
    NxCheck(r, "enriched: as loaded, the record's value first", NxToStr(NxEnriched(fresh, "imdbRating")), "8.2")
    NxCheck(r, "enriched: as loaded, the item's when the record has none", NxToStr(NxEnriched({ imdbVotes: 40 }, "imdbVotes")), "40")
    both = NxFcLowerCopy({ enrichment: { imdbRating: 8.2 } })
    both.imdbRating = 6.5
    NxCheck(r, "enriched: read back, the record's value still comes first", NxToStr(NxEnriched(both, "imdbRating")), "8.2")

    ' ── The pools, fresh and read back ──────────────────────────────────────
    items = NxMultiServerFixture()
    ' The same library with its ratings in enrichment records, as the remote
    ' step attaches them, so the record's half of NxEnriched is read too.
    recs = NxMultiServerFixture()
    for each it in recs
        it.enrichment = { imdbRating: it.imdbRating, imdbVotes: it.imdbVotes }
        it.Delete("imdbRating")
        it.Delete("imdbVotes")
    end for
    defs = []
    for each def in config.channels
        defs.Push({ id: def.id.ToStr(), compiled: NxFilterChannel(def) })
    end for
    for each lib in [{ name: "ratings on the item", items: items }, { name: "ratings in a record", items: recs }]
        want = NxFcPools(lib.items, defs, manifest, exclusive, clock)
        NxFcSame(r, lib.name + ": the TV's lower-case copy gives every channel the same pool", NxFcPools(NxFcLowerCopy(lib.items), defs, manifest, exclusive, clock), want, defs)
        NxFcSame(r, lib.name + ": read back with ParseJson, every channel the same pool", NxFcPools(ParseJson(FormatJson(lib.items)), defs, manifest, exclusive, clock), want, defs)
    end for
    ' Information, not a check: the off-TV interpreter may answer otherwise.
    print "filter case: on this runtime FormatJson writes "; FormatJson({ imdbRating: 1 })

    print "filter case cases: "; r.pass; " passed, "; r.fail; " failed"
    return r.fail
end function

' Each channel's pool as its ratingKeys joined, by channel id. The filter's
' cache is dropped first, so each library is filtered afresh.
function NxFcPools(items as Object, defs as Object, manifest as Object, exclusive as Object, clock as Object) as Object
    for each it in items
        it.Delete("nxFilter")
        it.Delete("nxfilter")
    end for
    out = {}
    for each d in defs
        keys = []
        for each row in NxFilterPool(items, d.compiled, manifest, exclusive, clock, "plex")
            keys.Push(NxToStr(row.item.ratingKey))
        end for
        out[d.id] = keys.Join(",")
    end for
    return out
end function

' One check over every channel: how many match, with the ids of those that
' don't in the label.
sub NxFcSame(r as Object, label as String, got as Object, want as Object, defs as Object)
    differ = []
    for each d in defs
        if got[d.id] <> want[d.id] then differ.Push(d.id)
    end for
    if differ.Count() > 0 then label = label + " (differ: " + differ.Join(" ") + ")"
    NxCheck(r, label, (defs.Count() - differ.Count()).ToStr(), defs.Count().ToStr())
end sub

' A deep copy with every key lower-cased, in case-sensitive AAs: how a TV
' holds a title read back from its save.
function NxFcLowerCopy(v as Dynamic) as Dynamic
    if type(v) = "roAssociativeArray" then
        out = {}
        out.SetModeCaseSensitive()
        for each k in v
            out[LCase(k)] = NxFcLowerCopy(v[k])
        end for
        return out
    end if
    if type(v) = "roArray" then
        out = []
        for each x in v
            out.Push(NxFcLowerCopy(x))
        end for
        return out
    end if
    return v
end function
