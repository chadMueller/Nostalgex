' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Where the loaded titles land, for the second line under Settings > RESCAN
' LIBRARY and the COVERAGE line in the console (#207). A port of the web
' tuner's scripts/nostalgex-library-coverage.js and the Apple TV's
' LibraryDiagnostics (coverage, coverageLine, orphanReport): same definitions,
' same wording.
'
'   ON A CHANNEL     in the pool of at least one channels.json channel whose
'                    pool reaches its minItems, whether or not its package is
'                    on (seasonal ones count), or in a collection or franchise
'                    channel already built.
'   ON NO CHANNEL    every other loaded title, split by kind (MOVIES,
'                    EPISODES, MUSIC VIDEOS) when more than one kind has some.
'   SKIPPED          movies and episodes the loaders dropped for having no
'   (NO RUNTIME)     runtime (NxScanSkipAdd in source/util/Values.brs, at
'                    their durationMin guards).
'
' The line itself is NxCoverageLine, in source/util/RescanInfo.brs with the
' rest of the row.
'
'   11,633 OF 11,809 ON CHANNELS · 176 ON NO CHANNEL (4 MOVIES, 172 EPISODES) · 12 SKIPPED (NO RUNTIME)
'
' The guide build filters only the switched-on packages' channels
' (NxPoolChannelIds), so the count reuses those results and filters every
' other channel itself, as the Apple TV does after a refresh. It runs in steps
' (NxCoverageStep) so the library task can answer a package switch or a new
' hour between them, one server's items at a time as NxFilterPoolsByServer
' does (I-065), and leaves no filter cache on the items when it is done.

' Over this many titles the count isn't run, as the Apple TV's
' ensureLibraryCoverage skips a library over 30,000.
function NxCoverageMaxTitles() as Integer
    return 30000
end function

' The web's kindOf: an episode, a music video (a music video library's item),
' or a movie.
function NxCoverageKind(it as Object) as String
    if NxToStr(it.type) = "episode" then return "episode"
    if NxToStr(it.librarySource) = "musicVideo" then return "musicVideo"
    return "movie"
end function

' A title's identity across the pools, as NxPoolsFingerprint keys them.
function NxCoverageKey(it as Object) as String
    return NxToStr(it.ratingKey) + "@" + NxToStr(it.serverIndex)
end function

function NxCoverageMinItems(def as Object) as Integer
    if NxTruthy(def.minItems) then return def.minItems
    return 50
end function

' A count over `items` (every loaded title) and `defs` (config.channels).
' `built` is buildGuide's channels: each one built from a channels.json
' channel carries its filter result as `filtered`, which stands for that
' channel's filter pass. `f` is what the filter reads: { manifest,
' exclusive, clock, backend, dv (NxDisplayShowsDolbyVision) }. Returns the job NxCoverageStep advances.
function NxCoverageStart(items as Object, defs as Object, built as Object, f as Object) as Object
    job = { items: items, f: f, todo: [], hits: [], minItems: [], covered: {}, slices: [], slice: 0, channel: 0, pos: 0, phase: "filter", done: false, filtered: 0, reused: 0, steps: 0, longestMs: 0 }
    job.covered.SetModeCaseSensitive()
    filtered = {}
    for each ch in NxList(built)
        if type(ch.filtered) = "roArray" then filtered[NxToStr(ch.id)] = ch.filtered
    end for
    for each def in NxList(defs)
        got = filtered[NxToStr(def.id)]
        if got <> invalid then
            job.reused = job.reused + 1
            if got.Count() >= NxCoverageMinItems(def) then
                for each it in got
                    job.covered[NxCoverageKey(it)] = true
                end for
            end if
        else
            job.todo.Push(NxFilterChannel(def))
            job.hits.Push([])
            job.minItems.Push(NxCoverageMinItems(def))
        end if
    end for
    ' One server's items at a time, in library order.
    bySlice = {}
    for i = 0 to items.Count() - 1
        ' A Dolby Vision profile 5 file this display can't show is on no
        ' channel, as buildGuide leaves it out of the filter (#69).
        if not NxLeftOffForDisplay(items[i], f.dv) then
            sk = NxToStr(items[i].serverIndex)
            slice = bySlice[sk]
            if slice = invalid then
                slice = []
                bySlice[sk] = slice
                job.slices.Push(slice)
            end if
            slice.Push(i)
        end if
    end for
    if job.todo.Count() = 0 or job.slices.Count() = 0 then job.phase = "mark"
    return job
end function

' Works for about budgetMs, then returns; true once the count's channel
' part is done. Keeps how many steps it took and the longest, for the log. Each slice is filtered against every channel left, then its
' items' filter cache is dropped.
function NxCoverageStep(job as Object, budgetMs as Integer) as Boolean
    if job.done then return true
    t = CreateObject("roTimespan")
    done = NxCoverageWork(job, budgetMs, t)
    ms = t.TotalMilliseconds()
    job.steps = job.steps + 1
    if ms > job.longestMs then job.longestMs = ms
    return done
end function

' One step's work, in three phases, each giving the step back once its
' budget is used: "filter" runs a slice's titles through each channel left;
' "clear" drops that slice's filter cache, then the next slice is filtered;
' "mark" takes the titles of each channel that reached its minimum. On a 43"
' TCL with 5,492 titles, clearing and marking in one go took a step to
' 366 ms.
function NxCoverageWork(job as Object, budgetMs as Integer, t as Object) as Boolean
    f = job.f
    while true
        if job.phase = "filter" then
            slice = job.slices[job.slice]
            c = job.todo[job.channel]
            hits = job.hits[job.channel]
            n = slice.Count()
            while job.pos < n
                idx = slice[job.pos]
                if NxItemPasses(job.items[idx], c, f.manifest, f.exclusive, f.clock, f.backend) <> "" then hits.Push(idx)
                job.pos = job.pos + 1
                ' Every 16 titles: a title's first pass builds its filter
                ' cache, and at 128 a step on the 43" ran to 455 ms.
                if (job.pos mod 16) = 0 and t.TotalMilliseconds() >= budgetMs then return false
            end while
            job.pos = 0
            job.channel = job.channel + 1
            if job.channel >= job.todo.Count() then
                job.channel = 0
                job.phase = "clear"
            end if
        else if job.phase = "clear" then
            slice = job.slices[job.slice]
            while job.pos < slice.Count()
                ' Lower case: the filter sets it as item.nxFilter, which on a
                ' TV is the key "nxfilter" in an item read back with
                ' ParseJson (a case-sensitive AA there), and Delete("nxFilter")
                ' leaves that one in place (43S45, Roku OS 16.0.4).
                job.items[slice[job.pos]].Delete("nxfilter")
                job.pos = job.pos + 1
                if (job.pos mod 256) = 0 and t.TotalMilliseconds() >= budgetMs then return false
            end while
            job.pos = 0
            job.slice = job.slice + 1
            job.phase = "filter"
            if job.slice >= job.slices.Count() then job.phase = "mark"
        else
            while job.channel < job.todo.Count()
                hits = job.hits[job.channel]
                if hits.Count() >= job.minItems[job.channel] then
                    while job.pos < hits.Count()
                        job.covered[NxCoverageKey(job.items[hits[job.pos]])] = true
                        job.pos = job.pos + 1
                        if (job.pos mod 256) = 0 and t.TotalMilliseconds() >= budgetMs then return false
                    end while
                end if
                job.hits[job.channel] = []
                job.pos = 0
                job.channel = job.channel + 1
                job.filtered = job.filtered + 1
                if t.TotalMilliseconds() >= budgetMs and job.channel < job.todo.Count() then return false
            end while
            job.hits = []
            job.todo = []
            job.slices = []
            job.done = true
            return true
        end if
        if t.TotalMilliseconds() >= budgetMs then return false
    end while
    return false
end function

' The count, once NxCoverageStep is done, with `dynamicPools` the pools of
' the collection and franchise channels built now (they count by their pools,
' whatever their size). { loaded, onChannels, totalLoaded, totalOnChannels,
' totalOnNoChannel, orphanSample }, as the web's compute returns.
function NxCoverageTally(job as Object, dynamicPools as Object, sampleSize = 25 as Integer) as Object
    inBuilt = {}
    inBuilt.SetModeCaseSensitive()
    for each pool in NxList(dynamicPools)
        for each it in NxList(pool)
            inBuilt[NxCoverageKey(it)] = true
        end for
    end for
    loaded = { movie: 0, episode: 0, musicVideo: 0 }
    onCh = { movie: 0, episode: 0, musicVideo: 0 }
    orphans = []
    for each it in job.items
        k = NxCoverageKey(it)
        kind = NxCoverageKind(it)
        loaded[kind] = loaded[kind] + 1
        if job.covered.DoesExist(k) or inBuilt.DoesExist(k) then
            onCh[kind] = onCh[kind] + 1
        else
            NxCoverageKeepFirst(orphans, { key: LCase(NxToStr(it.title)), it: it }, sampleSize)
        end if
    end for
    sample = []
    for each o in orphans
        sample.Push(o.it)
    end for
    total = loaded.movie + loaded.episode + loaded.musicVideo
    onTotal = onCh.movie + onCh.episode + onCh.musicVideo
    return { loaded: loaded, onChannels: onCh, totalLoaded: total, totalOnChannels: onTotal, totalOnNoChannel: total - onTotal, orphanSample: sample }
end function

' Keeps `list` the first `n` rows A to Z by key (a title, lower case, as the
' web's localeCompare at base sensitivity compares it); a later row with the
' same key goes after the earlier one.
sub NxCoverageKeepFirst(list as Object, row as Object, n as Integer)
    if n <= 0 then return
    if list.Count() >= n and row.key >= list[list.Count() - 1].key then return
    i = list.Count()
    while i > 0 and row.key < list[i - 1].key
        i = i - 1
    end while
    if i = list.Count() then
        list.Push(row)
    else
        tail = []
        for j = i to list.Count() - 1
            tail.Push(list[j])
        end for
        while list.Count() > i
            list.Pop()
        end while
        list.Push(row)
        list.Append(tail)
    end if
    while list.Count() > n
        list.Pop()
    end while
end sub

' The console line, as the web's orphanReport: counts, then the first titles
' on no channel with the fields the rules read. Console only: nothing here
' is sent anywhere.
function NxCoverageReport(cov as Object, onEnabled as Dynamic) as String
    counts = []
    for each k in ["movie", "episode", "musicVideo"]
        counts.Push(k + " " + NxNumberOr0(cov.onChannels[k]).ToStr() + "/" + NxNumberOr0(cov.loaded[k]).ToStr())
    end for
    guideNow = "?"
    if onEnabled <> invalid then guideNow = onEnabled.ToStr()
    line = "COVERAGE: " + cov.totalOnChannels.ToStr() + " of " + cov.totalLoaded.ToStr() + " on a channel with every package on, " + cov.totalOnNoChannel.ToStr() + " on none; " + guideNow + " on the channels in the guide now (" + counts.Join(", ") + ")"
    if cov.orphanSample.Count() = 0 then return line
    rows = []
    for each it in cov.orphanSample
        year = "no year"
        if NxToStr(it.year) <> "" and NxToStr(it.year) <> "0" then year = NxToStr(it.year)
        rating = "no rating"
        if NxIsNumber(it.rating) then
            if it.rating > 0 then rating = NxOneDecimal(it.rating)
        end if
        genres = "no genre"
        if NxList(it.genres).Count() > 0 then genres = NxList(it.genres).Join("|")
        studio = "no studio"
        if NxToStr(it.studio) <> "" then studio = NxToStr(it.studio)
        cert = "unrated"
        if NxToStr(it.contentRating) <> "" then cert = NxToStr(it.contentRating)
        tmdb = "no TMDB"
        if it.tmdbID <> invalid and NxToStr(it.tmdbID) <> "" then tmdb = "TMDB"
        name = NxToStr(it.title)
        if NxToStr(it.type) = "episode" and NxToStr(it.episodeTitle) <> "" then name = name + ": " + NxToStr(it.episodeTitle)
        rows.Push(Chr(34) + name + Chr(34) + " (" + year + ", " + cert + ", " + rating + ", " + genres + ", " + studio + ", " + NxToStr(it.duration) + "m, " + tmdb + ")")
    end for
    return line + ". Not on any channel (first " + rows.Count().ToStr() + "): " + rows.Join("; ")
end function

' toFixed(1), for a rating: 6.1, 7.0.
function NxOneDecimal(x as Dynamic) as String
    tenths = Int(x * 10 + 0.5)
    return (tenths \ 10).ToStr() + "." + (tenths mod 10).ToStr()
end function
