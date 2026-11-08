' Runs source/util/LibraryCoverage.brs: the library line under Settings >
' RESCAN LIBRARY and the COVERAGE console line (#207).
'
' The parity cases come from tests/vectors/coverage.json, which
' tests/gen-coverage.mjs makes by running upstream's
' scripts/nostalgex-library-coverage.js and the filter's itemPasses as
' plex-tuner.html does, over the filter vectors' library and every real
' channel, with each case's minItems. The skipped cases feed the loaders
' saved answers with runtimes either side of a minute. Returns the failure
' count.

' `shard` ({ index, count }, from tests/run.sh) splits the work: part 0 runs
' the checks after the parity cases, and the other parts share the parity
' cases, the ones that also run stepped (every third) dealt out first, so each
' part gets as many of them as the next; invalid runs them all, as on a TV.
' Splitting by position alone put every stepped case in parts 0 and 3, and
' the other checks in part 0 too, which took four times as long as the rest.
function NxRunCoverageTests(vectorsPath as String, manifestPath as String, shard = invalid as Dynamic) as Integer
    r = { pass: 0, fail: 0 }
    v = ParseJson(ReadAsciiFile(vectorsPath))
    manifest = ParseJson(ReadAsciiFile(manifestPath))
    if v = invalid or manifest = invalid then
        print "FAIL cannot read "; vectorsPath; " or "; manifestPath
        return 1
    end if
    exclusive = NxFilterExclusiveRules(v.exclusiveRules)
    clocks = {}
    for each c in v.clocks
        clocks[c.name] = c
    end for

    shardIndex = 0
    shardCount = 1
    if shard <> invalid then
        shardIndex = shard.index
        shardCount = shard.count
    end if

    ' ── Parity with the web tuner, case by case ──
    mine = NxCoverageShardCases(v.cases.Count(), shardIndex, shardCount)
    for each ci in mine
        c = v.cases[ci]
        clock = clocks[c.clock]
        defs = NxCoverageDefs(v.channels, c.minItems)
        f = { manifest: manifest, exclusive: exclusive, clock: clock, backend: clock.backend, dv: true }
        dynamicPools = NxCoverageDynamic(v.items, c.dynamic)
        label = "coverage " + c.clock + " " + c.name

        ' In one go, with nothing built.
        job = NxCoverageStart(v.items, defs, [], f)
        NxCovCheck(r, label + ": done in one step", NxCoverageStep(job, 600000), true)
        NxCoverageCheckCase(r, label, NxCoverageTally(job, dynamicPools), c)

        ' A step at a time (16 titles a step), and with the first 10
        ' channels' filter results from a build, as when their packages are
        ' on: the same count. Every third case, for time off-device.
        if ci mod 3 = 0 then
            built = []
            for i = 0 to 9
                pool = []
                for each row in NxFilterPool(v.items, NxFilterChannel(defs[i]), manifest, exclusive, clock, clock.backend)
                    pool.Push(row.item)
                end for
                built.Push({ id: defs[i].id, filtered: pool, pool: pool })
            end for
            job = NxCoverageStart(v.items, defs, built, f)
            steps = 0
            while not NxCoverageStep(job, 0)
                steps = steps + 1
                if steps > 100000 then exit while
            end while
            NxCovCheck(r, label + ", stepped: took more than one step", steps > 1, true)
            NxCovCheck(r, label + ", stepped: 10 channels' results reused", job.reused, 10)
            NxCoverageCheckCase(r, label + ", stepped", NxCoverageTally(job, dynamicPools), c)
            leftover = 0
            for each it in v.items
                if it.nxFilter <> invalid then leftover = leftover + 1
            end for
            NxCovCheck(r, label + ": no filter cache left", leftover, 0)
        end if
    end for
    if shardCount > 1 and shardIndex <> 0 then
        print "coverage cases:"; r.pass; " passed,"; r.fail; " failed"
        return r.fail
    end if

    ' ── Switching a package doesn't move the number; changing the library does ──
    c = v.cases[1]
    clock = clocks[c.clock]
    defs = NxCoverageDefs(v.channels, c.minItems)
    f = { manifest: manifest, exclusive: exclusive, clock: clock, backend: clock.backend, dv: true }
    counts = []
    for each first in [0, 10, 25]
        built = []
        for i = first to NxMinInt(first + 9, defs.Count() - 1)
            pool = []
            for each row in NxFilterPool(v.items, NxFilterChannel(defs[i]), manifest, exclusive, clock, clock.backend)
                pool.Push(row.item)
            end for
            built.Push({ id: defs[i].id, filtered: pool, pool: pool })
        end for
        job = NxCoverageStart(v.items, defs, built, f)
        NxCoverageStep(job, 600000)
        counts.Push(NxCoverageTally(job, []).totalOnChannels)
    end for
    NxCovCheck(r, "packages: other channels built, same count", counts[1] = counts[0] and counts[2] = counts[0], true)
    fewer = []
    for i = 0 to v.items.Count() - 1
        if i mod 3 <> 0 then fewer.Push(v.items[i])
    end for
    job = NxCoverageStart(fewer, defs, [], f)
    NxCoverageStep(job, 600000)
    smaller = NxCoverageTally(job, [])
    NxCovCheck(r, "library: a third removed, fewer loaded", smaller.totalLoaded, fewer.Count())
    NxCovCheck(r, "library: a third removed, the count moves", smaller.totalOnChannels < counts[0], true)

    ' A Dolby Vision profile 5 file this display can't show is on no channel
    ' (#69), though its rules would take it.
    dvItems = []
    for i = 0 to 59
        dvItems.Push({ ratingKey: "dv" + i.ToStr(), type: "movie", title: "Lab " + i.ToStr(), genres: ["Comedy"], year: 1994, contentRating: "PG", duration: 90, doviProfile: 5 })
    end for
    defs1 = NxCoverageDefs(v.channels, NxCoverageOnes(v.channels.Count()))
    shown = NxCoverageStart(dvItems, defs1, [], { manifest: manifest, exclusive: exclusive, clock: clock, backend: "plex", dv: true })
    NxCoverageStep(shown, 600000)
    hidden = NxCoverageStart(dvItems, defs1, [], { manifest: manifest, exclusive: exclusive, clock: clock, backend: "plex", dv: false })
    NxCoverageStep(hidden, 600000)
    NxCovCheck(r, "dolby vision: on a channel where the display shows it", NxCoverageTally(shown, []).totalOnChannels > 0, true)
    NxCovCheck(r, "dolby vision: on none where it can't", NxCoverageTally(hidden, []).totalOnChannels, 0)

    ' ── The line's wording (scripts/nostalgex-library-coverage-smoke.mjs) ──
    cov = NxCoverageOf({ movie: 1792, episode: 8891, musicVideo: 1126 }, { movie: 1788, episode: 8719, musicVideo: 1126 })
    NxCovCheck(r, "line: the issue's example", NxCoverageLine(cov, 12), "11,633 OF 11,809 ON CHANNELS · 176 ON NO CHANNEL (4 MOVIES, 172 EPISODES) · 12 SKIPPED (NO RUNTIME)")
    cov = NxCoverageOf({ movie: 10, episode: 5, musicVideo: 0 }, { movie: 7, episode: 5, musicVideo: 0 })
    NxCovCheck(r, "line: one kind on no channel, no split", NxCoverageLine(cov, 0), "12 OF 15 ON CHANNELS · 3 ON NO CHANNEL")
    cov = NxCoverageOf({ movie: 10, episode: 5, musicVideo: 0 }, { movie: 10, episode: 5, musicVideo: 0 })
    NxCovCheck(r, "line: all on channels", NxCoverageLine(cov, 0), "15 OF 15 ON CHANNELS")
    NxCovCheck(r, "line: not counted yet, skipped only", NxCoverageLine(invalid, 1234), "1,234 SKIPPED (NO RUNTIME)")
    NxCovCheck(r, "line: not counted, none skipped", NxCoverageLine(invalid, 0), "")
    NxCovCheck(r, "line: nothing loaded", NxCoverageLine(NxCoverageOf({ movie: 0, episode: 0, musicVideo: 0 }, { movie: 0, episode: 0, musicVideo: 0 }), 0), "")

    ' ── Under RESCAN LIBRARY: the second line, before "Last updated" ──
    items = [NxRescanItem("movie", "Jaws"), NxRescanItem("episode", "Lost")]
    counts = NxLibraryCounts(items)
    counts.skipped = 3
    held = { counts: counts, at: 1000 }
    lines = NxRescanLines(held, "Plex", "", 1060)
    NxCovCheck(r, "rescan: skipped before the count", lines.Join("|"), "2 titles · 1 movies · 1 episodes from 1 shows · 100% with genres · 100% matched to TMDB|3 SKIPPED (NO RUNTIME)|Last updated 1 minute ago. Pull a fresh copy of your Plex library after adding content")
    held.coverage = NxCoverageOf({ movie: 1, episode: 1, musicVideo: 0 }, { movie: 1, episode: 0, musicVideo: 0 })
    lines = NxRescanLines(held, "Plex", "x", 1060)
    NxCovCheck(r, "rescan: counted, with a failure", lines.Join("|"), "2 titles · 1 movies · 1 episodes from 1 shows · 100% with genres · 100% matched to TMDB|1 OF 2 ON CHANNELS · 1 ON NO CHANNEL · 3 SKIPPED (NO RUNTIME)|Last updated 1 minute ago. Pull a fresh copy of your Plex library after adding content|Last playback failure: x")
    held = { counts: NxLibraryCounts(items), at: 1000 }
    NxCovCheck(r, "rescan: a record from before #207 has no second line", NxRescanLines(held, "Plex", "", 1060).Count(), 2)

    ' ── The loaders count what they drop for having no runtime ──
    ' Plex: milliseconds, floored to whole minutes. Missing, 0, 30 s and
    ' 59,999 ms are dropped; 60,000 ms is kept.
    mg = CreateObject("roRegex", "music", "i")
    NxScanSkipsReset()
    kept = 0
    for each ms in [invalid, 0, 30000, 59999, 60000]
        raw = { ratingKey: "m", title: "Film", type: "movie" }
        if ms <> invalid then raw.duration = ms
        if NxPlexMovieItem(raw, { key: "1", type: "movie" }, false, mg) <> invalid then kept = kept + 1
        ep = { ratingKey: "e", title: "Pilot", type: "episode" }
        if ms <> invalid then ep.duration = ms
        if NxPlexEpisodeItem(ep, { title: "Show", ratingKey: "s" }, [], invalid, false) <> invalid then kept = kept + 1
    end for
    NxCovCheck(r, "skipped: plex movies and episodes", NxScanSkips(), 8)
    NxCovCheck(r, "skipped: plex keeps a minute", kept, 2)
    ' A music video goes through the movie path, and counts with the movies.
    NxPlexMovieItem({ ratingKey: "mv", title: "Song", type: "movie", duration: 59999 }, { key: "2", type: "movie" }, true, mg)
    NxCovCheck(r, "skipped: a plex music video counts", NxScanSkips(), 9)

    ' Jellyfin and Emby: a scan from saved answers (100 ns ticks).
    for each kind in ["jellyfin", "emby"]
        fx = NxCoverageSkipFixture()
        NxScanSkipsReset()
        got = NxMbScanServer(NxMbFixtureFetcher(fx), kind, "u1", 0)
        NxCovCheck(r, "skipped: " + kind + " scan loads the minute-long ones", got.Count(), 3)
        NxCovCheck(r, "skipped: " + kind + " scan counts the rest once", NxScanSkips(), 12)
        NxScanSkipsReset()
        NxCovCheck(r, "skipped: reset", NxScanSkips(), 0)
    end for

    ' ── The orphan sample: A to Z, case ignored, 25 at most, stable ──
    list = []
    for each t in ["b", "A", "c", "a", "B"]
        NxCoverageKeepFirst(list, { key: LCase(t), it: t }, 3)
    end for
    got = []
    for each o in list
        got.Push(o.it)
    end for
    NxCovCheck(r, "sample: first three", got.Join(","), "A,a,b")

    ' ── Saved with the library, gone with the sign-in ──
    ' The registry is the TV's only: these run in deploy.sh --test, in a data
    ' space of their own.
    if NxTestRuntime() = "device" then
        g = GetGlobalAA()
        keepSpace = g.nxDataSpace
        g.nxDataSpace = "nxunittest"
        counts = NxLibraryCounts(items)
        counts.skipped = 5
        NxSaveLibraryHeld(counts, 5000)
        NxCovCheck(r, "saved: skipped survives a restart", NxRescanLines(NxLibraryHeld(), "Plex", "", 5060)[1], "5 SKIPPED (NO RUNTIME)")
        cov = NxCoverageOf({ movie: 1, episode: 1, musicVideo: 0 }, { movie: 1, episode: 1, musicVideo: 0 })
        NxSaveLibraryCoverage(cov, 4000)
        NxCovCheck(r, "saved: a count from an older load isn't kept", NxLibraryHeld().coverage = invalid, true)
        NxSaveLibraryCoverage(cov, 5000)
        NxCovCheck(r, "saved: the count for this load", NxRescanLines(NxLibraryHeld(), "Plex", "", 5060)[1], "2 OF 2 ON CHANNELS · 5 SKIPPED (NO RUNTIME)")
        NxSaveLibraryHeld(counts, 6000)
        NxCovCheck(r, "saved: a new load clears the count", NxRescanLines(NxLibraryHeld(), "Plex", "", 6060)[1], "5 SKIPPED (NO RUNTIME)")
        NxPlexClearAuth()
        NxCovCheck(r, "saved: gone after the server is disconnected", NxRescanLines(NxLibraryHeld(), "Plex", "", 6060).Count(), 2)
        CreateObject("roRegistry").Delete("nxunittest-plex")
        g.nxDataSpace = keepSpace
    end if

    ' ── The split itself: every case in exactly one part ──
    for each split in [{ total: 12, count: 7 }, { total: 12, count: 6 }, { total: 13, count: 7 }, { total: 2, count: 7 }, { total: 12, count: 1 }]
        seen = []
        for ci = 0 to split.total - 1
            seen.Push(0)
        end for
        for p = 0 to split.count - 1
            for each ci in NxCoverageShardCases(split.total, p, split.count)
                seen[ci] = seen[ci] + 1
            end for
        end for
        once = 0
        for each n in seen
            if n = 1 then once = once + 1
        end for
        NxCovCheck(r, "split: " + split.total.ToStr() + " cases over " + split.count.ToStr() + " parts, each in one part", once, split.total)
        if split.count > 1 then NxCovCheck(r, "split: part 0 has none of " + split.total.ToStr(), NxCoverageShardCases(split.total, 0, split.count).Count(), 0)
    end for
    heavy = 0
    for each ci in NxCoverageShardCases(12, 1, 7)
        if ci mod 3 = 0 then heavy = heavy + 1
    end for
    NxCovCheck(r, "split: 12 cases over 7 parts, part 1 has one stepped case", heavy, 1)
    print "coverage cases:"; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

sub NxCoverageCheckCase(r as Object, label as String, got as Object, c as Object)
    for each k in ["movie", "episode", "musicVideo"]
        NxCovCheck(r, label + ": loaded " + k, got.loaded[k], NxNumberOr0(c.loaded[k]))
        NxCovCheck(r, label + ": on channels " + k, got.onChannels[k], NxNumberOr0(c.onChannels[k]))
    end for
    keys = []
    for each it in got.orphanSample
        keys.Push(NxToStr(it.ratingKey))
    end for
    want = []
    for each k in c.orphanSample
        want.Push(NxToStr(k))
    end for
    NxCovCheck(r, label + ": orphan sample", keys.Join(","), want.Join(","))
    NxCovCheck(r, label + ": line", NxCoverageLine(got, c.skipped), c.line)
    NxCovCheck(r, label + ": console line", NxCoverageReport(got, 7), c.report)
end sub

function NxCoverageDefs(channels as Object, minItems as Object) as Object
    out = []
    for i = 0 to channels.Count() - 1
        ch = channels[i]
        out.Push({ id: ch.id, category: ch.category, rules: ch.rules, minItems: minItems[i] })
    end for
    return out
end function

function NxCoverageOnes(n as Integer) as Object
    out = []
    for i = 1 to n
        out.Push(1)
    end for
    return out
end function

function NxCoverageDynamic(items as Object, idx as Dynamic) as Object
    pools = []
    for each pool in NxList(idx)
        p = []
        for each i in pool
            p.Push(items[i])
        end for
        pools.Push(p)
    end for
    return pools
end function

function NxCoverageOf(loaded as Object, onCh as Object) as Object
    total = loaded.movie + loaded.episode + loaded.musicVideo
    onTotal = onCh.movie + onCh.episode + onCh.musicVideo
    return { loaded: loaded, onChannels: onCh, totalLoaded: total, totalOnChannels: onTotal, totalOnNoChannel: total - onTotal, orphanSample: [] }
end function

' A Movies library and a Shows library, each with a title of no runtime, 0,
' 30 s, 59.999 s, 60 s and 90 min (ticks are 100 ns). The show has two seasons'
' worth of episodes under it, read through the per-show request.
function NxCoverageSkipFixture() as Object
    ticks = [invalid, 0, 300000000, 599990000, 600000000]
    movies = []
    episodes = []
    for i = 0 to ticks.Count() - 1
        mv = { Id: "m" + i.ToStr(), Name: "Film " + i.ToStr(), Type: "Movie", ProductionYear: 1990 }
        e = { Id: "e" + i.ToStr(), Name: "Episode " + i.ToStr(), Type: "Episode", SeriesName: "Show" }
        e2 = { Id: "f" + i.ToStr(), Name: "Episode " + i.ToStr() + "b", Type: "Episode", SeriesName: "Show" }
        if ticks[i] <> invalid then
            mv.RunTimeTicks = ticks[i]
            e.RunTimeTicks = ticks[i]
            e2.RunTimeTicks = ticks[i]
        end if
        movies.Push(mv)
        episodes.Push(e)
        episodes.Push(e2)
    end for
    return {
        views: [{ Id: "lib-movies", Name: "Movies", CollectionType: "movies" }, { Id: "lib-shows", Name: "Shows", CollectionType: "tvshows" }],
        items: {
            "lib-movies": movies,
            "lib-shows": [{ Id: "s1", Name: "Show", Type: "Series" }],
            "s1": episodes
        }
    }
end function

sub NxCovCheck(r as Object, name as String, got as Dynamic, want as Dynamic)
    NxCheck(r, name, FormatJson(got), FormatJson(want))
end sub

' The parity cases (by position) that part `index` of `count` runs. One part
' runs them all. Otherwise part 0 runs none (it has the other checks) and the
' rest share them: the cases that also run stepped (position mod 3 = 0) first,
' then the others, dealt out in turn, so every case runs in exactly one part.
function NxCoverageShardCases(total as Integer, index as Integer, count as Integer) as Object
    out = []
    if count <= 1 then
        for ci = 0 to total - 1
            out.Push(ci)
        end for
        return out
    end if
    if index = 0 then return out
    order = []
    for ci = 0 to total - 1 step 3
        order.Push(ci)
    end for
    for ci = 0 to total - 1
        if ci mod 3 <> 0 then order.Push(ci)
    end for
    k = 0
    for each ci in order
        if k mod (count - 1) = index - 1 then out.Push(ci)
        k = k + 1
    end for
    return out
end function
