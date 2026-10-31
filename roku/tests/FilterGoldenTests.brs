' Runs upstream's scripts/filter-golden.json (copied unchanged to
' tests/vectors/), the cases its Swift FilterGoldenTests and web
' nostalgex-filter-golden-smoke.mjs both read: one item each against the
' shipped channels.json, its exclusive rules and channels-memberships.json.
' `in` lists channel ids the item must reach, `out` ids it must not. The
' generated filter vectors don't reach these (the exclusive locks' whole-word
' and own-title rules of upstream 805c33e). `item.backend` is the case's
' server kind (Plex when absent). Returns the failure count.

function NxRunFilterGoldenTests(goldenPath as String, configPath as String, manifestPath as String) as Integer
    golden = ParseJson(ReadAsciiFile(goldenPath))
    config = ParseJson(ReadAsciiFile(configPath))
    manifest = ParseJson(ReadAsciiFile(manifestPath))
    if golden = invalid or config = invalid or manifest = invalid then
        print "FAIL cannot read "; goldenPath; ", "; configPath; " or "; manifestPath
        return 1
    end if
    r = { pass: 0, fail: 0 }
    exclusive = NxFilterExclusiveRules(config.exclusiveRules)
    defs = {}
    for each c in config.channels
        defs[NxToStr(c.id)] = c
    end for
    clock = NxFilterClock()
    for each c in golden.cases
        for each want in [true, false]
            ids = c.out
            if want then ids = c.in
            for each id in NxList(ids)
                def = defs[NxToStr(id)]
                if def = invalid then
                    NxCheck(r, c.name + ": channel " + NxToStr(id) + " is in channels.json", "missing", "present")
                else
                    ' A fresh item each time: the filter keeps a profile on it.
                    backend = "plex"
                    if NxTruthy(c.item.backend) then backend = c.item.backend
                    got = NxItemPasses(NxGoldenItem(c.item), NxFilterChannel(def), manifest, exclusive, clock, backend) <> ""
                    label = c.name + ": on " + NxToStr(id) + " " + NxToStr(def.name)
                    if not want then label = c.name + ": not on " + NxToStr(id) + " " + NxToStr(def.name)
                    NxCheck(r, label, NxToStr(got), NxToStr(want))
                end if
            end for
        end for
    end for
    print "filter golden cases (upstream filter-golden.json):"; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' The golden item as the web smoke test's toItem fills it in.
function NxGoldenItem(g as Object) as Object
    source = g.librarySource
    if source = invalid then
        source = "movie"
        if g.type = "episode" then source = "tv"
    end if
    item = {
        title: g.title, artist: g.artist, episodeTitle: g.episodeTitle, summary: NxOr(g.summary, ""),
        originallyAvailableAt: g.originallyAvailableAt, year: g.year,
        type: "movie", librarySource: source, genres: NxList(g.genres),
        contentRating: g.contentRating, duration: 100, rating: 0, userRating: 0,
        viewCount: 0, addedAt: 0, studio: g.studio, tmdbID: g.tmdbID, ratingKey: "golden",
        doviProfile: g.doviProfile
    }
    if NxTruthy(g.type) then item.type = g.type
    if g.duration <> invalid then item.duration = g.duration
    if g.rating <> invalid then item.rating = g.rating
    if type(g.enrichment) = "roAssociativeArray" then
        item.enrichment = {
            keywords: NxList(g.enrichment.keywords),
            productionCompanies: NxList(g.enrichment.productionCompanies),
            networks: NxList(g.enrichment.networks),
            tmdbGenres: NxList(g.enrichment.tmdbGenres),
            imdbRating: g.enrichment.imdbRating
        }
    end if
    return item
end function
