' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Settings > CONNECTION > RESCAN LIBRARY (#66), as upstream's row in
' Views/BundleManagerView.swift: what the app holds (LibraryDiagnostics
' .summary), when the library last loaded (libraryLastUpdatedText) and the
' last time playback was given up on (PlaybackDiagnostics.latestForSettings).
' The counts are taken when a load finishes and kept in the registry with the
' sign-in, so Settings reads them without the library in memory.

' LibraryDiagnostics.summary's counts. An episode's title is its show's.
function NxLibraryCounts(items as Object) as Object
    c = { titles: 0, movies: 0, episodes: 0, shows: 0, genres: 0, tmdb: 0 }
    shows = CreateObject("roAssociativeArray")
    shows.SetModeCaseSensitive()
    for each it in items
        c.titles = c.titles + 1
        kind = NxToStr(it.type)
        if kind = "movie" then c.movies = c.movies + 1
        if kind = "episode" then
            c.episodes = c.episodes + 1
            shows[NxToStr(it.title)] = true
        end if
        if NxList(it.genres).Count() > 0 then c.genres = c.genres + 1
        if it.tmdbID <> invalid and NxToStr(it.tmdbID) <> "" then c.tmdb = c.tmdb + 1
    end for
    c.shows = shows.Count()
    return c
end function

' summary(_:): "1,544 titles · 1,201 movies · 343 episodes from 12 shows ·
' 96% with genres · 88% matched to TMDB".
function NxLibrarySummaryText(c as Dynamic) as String
    if type(c) <> "roAssociativeArray" or NxNumberOr0(c.titles) = 0 then return "No titles loaded. The scan came back empty."
    total = c.titles
    parts = [NxGroupedInt(total) + " titles"]
    if NxNumberOr0(c.movies) > 0 then parts.Push(NxGroupedInt(c.movies) + " movies")
    if NxNumberOr0(c.episodes) > 0 then parts.Push(NxGroupedInt(c.episodes) + " episodes from " + NxGroupedInt(NxNumberOr0(c.shows)) + " shows")
    parts.Push(NxPercentOf(NxNumberOr0(c.genres), total).ToStr() + "% with genres")
    parts.Push(NxPercentOf(NxNumberOr0(c.tmdb), total).ToStr() + "% matched to TMDB")
    return parts.Join(" · ")
end function

' pct(_:_:): rounded half away from zero, 0 for an empty total.
function NxPercentOf(n as Integer, total as Integer) as Integer
    if total <= 0 then return 0
    return Int(n * 100# / total + 0.5#)
end function

' NumberFormatter .decimal in English: 1544 is "1,544".
function NxGroupedInt(n as Integer) as String
    ' Not Abs(): it returns a Float, which a TV prints as 1e+06.
    v = n
    if v < 0 then v = -v
    s = v.ToStr()
    out = ""
    while Len(s) > 3
        out = "," + Right(s, 3) + out
        s = Left(s, Len(s) - 3)
    end while
    out = s + out
    if n < 0 then out = "-" + out
    return out
end function

' RelativeDateTimeFormatter, .full and numeric, for a load `ago` seconds back:
' the largest whole unit, "1 minute ago", "3 hours ago", and "in 0 seconds"
' for now, as it says. A month is 30 days and a year 365 here; the formatter
' counts calendar ones.
function NxRelativeAgo(ago as LongInteger) as String
    future = ago <= 0
    s& = ago
    if s& < 0 then s& = -s&
    units = [["year", 31536000], ["month", 2592000], ["week", 604800], ["day", 86400], ["hour", 3600], ["minute", 60]]
    n& = s&
    name = "second"
    for each u in units
        if s& >= u[1] then
            n& = s& \ u[1]
            name = u[0]
            exit for
        end if
    end for
    if n& <> 1 then name = name + "s"
    if future then return "in " + n&.ToStr() + " " + name
    return n&.ToStr() + " " + name + " ago"
end function

' ── What the registry keeps ─────────────────────────────────────────────────

' After each load, with the sign-in, so a sign-out clears it as upstream's
' disconnect does.
sub NxSaveLibraryHeld(counts as Object, nowSec as LongInteger)
    reg = NxPlexRegistry()
    reg.Write("libraryHeld", FormatJson({ counts: counts, at: nowSec }))
    reg.Flush()
end sub

' { counts, at } from the last load, or invalid before one.
function NxLibraryHeld() as Dynamic
    ' ParseJson("") logs an error to the console, so an empty read is checked.
    raw = NxPlexRegistry().Read("libraryHeld")
    if raw = "" then return invalid
    held = ParseJson(raw)
    if type(held) <> "roAssociativeArray" or not NxIsNumber(held.at) then return invalid
    return held
end function

' PlaybackDiagnostics.record: the newest first, five kept.
sub NxRecordPlaybackVerdict(line as String)
    reg = NxRegSection("player")
    rows = invalid
    raw = reg.Read("verdicts")
    if raw <> "" then rows = ParseJson(raw)
    if type(rows) <> "roArray" then rows = []
    keep = [line]
    for each r in rows
        if keep.Count() >= 5 then exit for
        keep.Push(r)
    end for
    reg.Write("verdicts", FormatJson(keep))
    reg.Flush()
end sub

function NxLastPlaybackVerdict() as String
    raw = NxRegSection("player").Read("verdicts")
    if raw = "" then return ""
    rows = ParseJson(raw)
    if type(rows) <> "roArray" or rows.Count() = 0 then return ""
    return NxToStr(rows[0])
end function

' The row's three lines, as its subtitle: what is held; when it last loaded,
' and what the row does; the last verdict, when there is one.
function NxRescanLines(held as Dynamic, kindName as String, verdict as String, nowSec as LongInteger) as Object
    counts = invalid
    updated = "Never"
    if held <> invalid then
        counts = held.counts
        at& = held.at
        updated = NxRelativeAgo(nowSec - at&)
    end if
    lines = [NxLibrarySummaryText(counts), "Last updated " + updated + ". Pull a fresh copy of your " + kindName + " library after adding content"]
    if verdict <> "" then lines.Push("Last playback failure: " + verdict)
    return lines
end function
