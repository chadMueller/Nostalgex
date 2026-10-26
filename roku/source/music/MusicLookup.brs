' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Music-video genres for HIGH ROTATION (#73), ported from the web tuner's
' scripts/nostalgex-music-brainz.js, which mirrors the Apple TV's
' MusicEnrichmentService, MusicBrainzService and DeezerService: MusicBrainz
' first (about one request a second), Deezer for the genres it leaves blank
' (four a second), and a cache, so a lookup is made once. Held to that module
' by tests/vectors/music.json (tests/gen-music.mjs).
'
' The cache rows here are { title, artist, mbid, genres, year, useful,
' deezerchecked, deezerid, fetched } (upstream's recordingTitle, artist,
' musicBrainzID, genres, releaseYear, hasUsefulGenres, deezerCheckedAt,
' deezerID, fetchedAt), keyed by the item's ratingKey. Lowercase keys, as
' the TV's ParseJson gives them back case-sensitive.
'
' The lookups themselves go through `net`, an object with mbSearch(query),
' mbRecording(id), dzSearch(q) and dzAlbum(id), each giving the parsed answer
' or invalid when it failed (components/MusicLookupTask.brs; a fake in the
' tests). Nothing here waits on the network itself.

' ── Genres ──────────────────────────────────────────────────────────────────

' Adds g unless already there, case-insensitively.
sub NxMusicAddGenre(out as Object, g as String)
    lg = LCase(g)
    for each x in out
        if LCase(x) = lg then return
    end for
    out.Push(g)
end sub

' mapTagsToChannelGenres: MusicBrainz tags to the channel genres.
function NxMusicMapTags(tags as Object) as Object
    out = []
    for each tag in tags
        t = LCase(NxToStr(tag))
        if NxMusicHas(t, "pop") and not NxMusicHas(t, "k-pop") then NxMusicAddGenre(out, "Pop")
        if NxMusicHas(t, "rock") then
            if NxMusicHas(t, "alternative") or NxMusicHas(t, "indie") then
                NxMusicAddGenre(out, "Alternative Rock")
                NxMusicAddGenre(out, "Indie Rock")
            else if NxMusicHas(t, "hard rock") or NxMusicHas(t, "hard-rock") then
                NxMusicAddGenre(out, "Hard Rock")
            else if NxMusicHas(t, "classic rock") then
                NxMusicAddGenre(out, "Classic Rock")
            else
                NxMusicAddGenre(out, "Rock")
            end if
        end if
        if NxMusicHas(t, "country") then
            NxMusicAddGenre(out, "Country")
            if NxMusicHas(t, "rock") then NxMusicAddGenre(out, "Country Rock")
        end if
        if NxMusicHas(t, "hip hop") or NxMusicHas(t, "hip-hop") then
            NxMusicAddGenre(out, "Hip-Hop")
            NxMusicAddGenre(out, "Hip Hop")
        end if
        if t = "rap" or NxMusicHas(t, "gangsta") then NxMusicAddGenre(out, "Rap")
        if NxMusicHas(t, "r&b") or NxMusicHas(t, "rhythm and blues") or t = "soul" then
            NxMusicAddGenre(out, "R&B")
            NxMusicAddGenre(out, "Soul")
        end if
        if NxMusicHas(t, "acoustic") then NxMusicAddGenre(out, "Acoustic")
        if NxMusicHas(t, "electronic") or NxMusicHas(t, "dance") or NxMusicHas(t, "edm") or NxMusicHas(t, "house") or NxMusicHas(t, "techno") or NxMusicHas(t, "trance") then NxMusicAddGenre(out, "Dance")
        if NxMusicHas(t, "metal") then
            NxMusicAddGenre(out, "Metal")
            NxMusicAddGenre(out, "Hard Rock")
            NxMusicAddGenre(out, "Rock")
        end if
        if NxMusicHas(t, "punk") then
            NxMusicAddGenre(out, "Rock")
            NxMusicAddGenre(out, "Alternative")
        end if
        if NxMusicHas(t, "folk") then NxMusicAddGenre(out, "Acoustic")
        if NxMusicHas(t, "latin") or NxMusicHas(t, "reggaeton") or NxMusicHas(t, "reggaet" + Chr(243) + "n") then NxMusicAddGenre(out, "Latin")
        if NxMusicHas(t, "funk") then NxMusicAddGenre(out, "Funk")
        if NxMusicHas(t, "disco") then NxMusicAddGenre(out, "Disco")
    end for
    return out
end function

function NxMusicHas(s as String, part as String) as Boolean
    return Instr(1, s, part) > 0
end function

' mapDeezerGenres (DeezerService.mapGenres): Deezer album genres to the
' channel genres.
function NxMusicMapDeezerGenres(raw as Object) as Object
    out = []
    for each name in raw
        g = LCase(NxToStr(name))
        adds = []
        if g = "pop" or g = "international pop" or g = "indie pop" or g = "k-pop" or g = "j-pop" or g = "latin pop" then
            adds = ["Pop"]
            if g = "indie pop" then adds.Push("Alternative")
            if g = "latin pop" then adds.Push("Latin")
        else if g = "rock" then
            adds = ["Rock"]
        else if g = "hard rock" then
            adds = ["Hard Rock", "Rock"]
        else if g = "classic rock" then
            adds = ["Classic Rock", "Rock"]
        else if g = "indie rock" or g = "indie rock/rock pop" then
            adds = ["Indie Rock", "Alternative", "Rock"]
        else if g = "alternative" then
            adds = ["Alternative"]
        else if g = "punk" then
            adds = ["Punk", "Rock", "Alternative"]
        else if g = "metal" then
            adds = ["Metal", "Hard Rock", "Rock"]
        else if g = "rap/hip hop" then
            adds = ["Hip-Hop", "Hip Hop", "Rap"]
        else if g = "r&b" then
            adds = ["R&B"]
        else if g = "soul & funk" then
            adds = ["Soul", "Funk"]
        else if g = "disco" then
            adds = ["Disco", "Funk"]
        else if g = "dance" or g = "dancefloor" then
            adds = ["Dance", "Electronic"]
        else if g = "electro" or g = "dubstep" or g = "chill out/trip-hop/lounge" or g = "electro pop/electro rock" then
            adds = ["Electronic", "Dance"]
            if g = "electro pop/electro rock" then adds.Push("Pop")
        else if g = "techno/house" then
            adds = ["House", "Techno", "Electronic", "Dance"]
        else if g = "country" then
            adds = ["Country"]
        else if g = "latin music" or g = "brazilian music" then
            adds = ["Latin"]
        else if g = "reggaeton" then
            adds = ["Reggaeton", "Latin"]
        else if g = "reggae" then
            adds = ["Reggae"]
        else if g = "folk" then
            adds = ["Acoustic", "Folk"]
        else if g = "jazz" then
            adds = ["Jazz"]
        else if g = "blues" then
            adds = ["Blues"]
        end if
        for each a in adds
            NxMusicAddGenre(out, a)
        end for
    end for
    return out
end function

' usefulGenres: anything but "music video", "music" and "musical".
function NxMusicUsefulGenres(genres as Dynamic) as Boolean
    for each g in NxList(genres)
        l = LCase(NxToStr(g))
        if not NxMusicHas(l, "music video") and l <> "music" and l <> "musical" then return true
    end for
    return false
end function

' mergeGenres: a's, then b's that a lacks (case-insensitively).
function NxMusicMergeGenres(a as Dynamic, b as Dynamic) as Object
    out = []
    for each g in NxList(a)
        out.Push(g)
    end for
    for each g in NxList(b)
        NxMusicAddGenre(out, NxToStr(g))
    end for
    return out
end function

' ── Items and years ─────────────────────────────────────────────────────────

' isMusicVideoItem: a music video that isn't an episode.
function NxMusicIsMusicVideo(item as Object) as Boolean
    return NxToStr(item.librarySource) = "musicVideo" and NxToStr(item.type) <> "episode"
end function

' yearInTitle: the "(1988)" a filename carries, or invalid.
function NxMusicYearInTitle(raw as Dynamic) as Dynamic
    hit = CreateObject("roRegex", "\(((?:19|20)\d\d)\)", "").Match(NxToStr(raw))
    if hit.Count() < 2 then return invalid
    return hit[1].ToInt()
end function

' resolveMusicYear: the title's year, else MusicBrainz's, else the server's
' when it's after 1970 and before this year.
function NxMusicResolveYear(titleYear as Dynamic, mbYear as Dynamic, plexYear as Dynamic, thisYear as Integer) as Dynamic
    if NxIsNumber(titleYear) and titleYear <> 0 then return titleYear
    if NxIsNumber(mbYear) and mbYear <> 0 then return mbYear
    y = NxMusicLeadingInt(plexYear)
    if y = 0 then return invalid
    if y > 1970 and y < thisYear then return y
    return invalid
end function

' parseInt(String(v), 10), 0 for none.
function NxMusicLeadingInt(v as Dynamic) as Integer
    if NxIsNumber(v) then return Int(v)
    hit = CreateObject("roRegex", "^\s*([+-]?\d+)", "").Match(NxToStr(v))
    if hit.Count() < 2 then return 0
    return hit[1].ToInt()
end function

' applyEnrichmentToItem, less the meta line: a copy with the row's title,
' artist, genres and year.
function NxMusicApply(item as Object, enr as Object, thisYear as Integer) as Object
    if not NxMusicIsMusicVideo(item) then return item
    out = {}
    for each k in item
        out[k] = item[k]
    end for
    title = NxToStr(enr.title)
    if title = "" then title = NxToStr(item.title)
    title = title.Trim()
    if title = "" then title = item.title
    artist = enr.artist
    if not NxTruthy(artist) then artist = item.artist
    if not NxTruthy(artist) then artist = invalid
    out.title = title
    out.artist = artist
    out.genres = NxMusicMergeGenres(item.genres, enr.genres)
    year = NxMusicResolveYear(NxMusicYearInTitle(item.title), enr.year, item.year, thisYear)
    if year = invalid then year = ""
    out.year = year
    return out
end function

' itemsWithDisplayMetadata: each music video with its cached row applied,
' or with only its year settled; everything else as it is.
function NxMusicItemsWithCache(items as Object, cache as Object, thisYear as Integer) as Object
    out = []
    for each item in items
        if not NxMusicIsMusicVideo(item) then
            out.Push(item)
        else
            enr = cache[NxToStr(item.ratingKey)]
            if type(enr) = "roAssociativeArray" then
                out.Push(NxMusicApply(item, enr, thisYear))
            else
                year = NxMusicResolveYear(NxMusicYearInTitle(item.title), invalid, item.year, thisYear)
                if year = invalid then year = ""
                if NxToStr(year) = NxToStr(item.year) and type(year) = type(item.year) then
                    out.Push(item)
                else
                    copy = {}
                    for each k in item
                        copy[k] = item[k]
                    end for
                    copy.year = year
                    out.Push(copy)
                end if
            end if
        end if
    end for
    return out
end function

' ── MusicBrainz answers ─────────────────────────────────────────────────────

function NxMusicPrimaryArtist(rec as Object) as Dynamic
    credits = rec["artist-credit"]
    if type(credits) <> "roArray" then return invalid
    for each credit in credits
        if type(credit) = "roAssociativeArray" then
            if NxTruthy(credit.name) then return credit.name
            if type(credit.artist) = "roAssociativeArray" then
                if NxTruthy(credit.artist.name) then return credit.artist.name
            end if
        end if
    end for
    return invalid
end function

function NxMusicFirstReleaseYear(rec as Object) as Dynamic
    releases = rec.releases
    if type(releases) <> "roArray" then return invalid
    for each release in releases
        if type(release) = "roAssociativeArray" then
            d = NxToStr(release.date)
            if d.Len() >= 4 then
                hit = CreateObject("roRegex", "^\s*([+-]?\d+)", "").Match(Left(d, 4))
                if hit.Count() >= 2 then return hit[1].ToInt()
            end if
        end if
    end for
    return invalid
end function

function NxMusicTagNames(rec as Object) as Object
    out = []
    if type(rec.tags) <> "roArray" then return out
    for each t in rec.tags
        if type(t) = "roAssociativeArray" then
            if NxTruthy(t.name) then out.Push(t.name)
        end if
    end for
    return out
end function

' searchBestRecording's query: recording:"song" AND video:true, and the
' artist when known; double quotes dropped (escapeQuery).
function NxMusicSearchQuery(song as String, artist as Dynamic) as String
    q = "recording:" + Chr(34) + song.Replace(Chr(34), "") + Chr(34) + " AND video:true"
    if NxTruthy(artist) then q = q + " AND artist:" + Chr(34) + NxToStr(artist).Replace(Chr(34), "") + Chr(34)
    return q
end function

' searchBestRecording's ranking over a search answer's recordings: score,
' +40 for the same title (+20 if one holds the other), +25 when the artist
' holds the hint, +15 for the same year (+8 within one). The first best
' wins. { mbid, title, artist, year } or invalid.
function NxMusicBestRecording(recordings as Dynamic, song as String, artist as Dynamic, year as Dynamic) as Dynamic
    songLower = LCase(song)
    best = invalid
    bestRank = -1
    for each rec in NxList(recordings)
        if type(rec) = "roAssociativeArray" then
            if NxTruthy(rec.id) and NxTruthy(rec.title) then
                rank = 0
                if NxIsNumber(rec.score) then rank = rec.score
                artistName = NxMusicPrimaryArtist(rec)
                recYear = NxMusicFirstReleaseYear(rec)
                titleLower = LCase(NxToStr(rec.title))
                if titleLower = songLower then
                    rank = rank + 40
                else if Instr(1, titleLower, songLower) > 0 or Instr(1, songLower, titleLower) > 0 then
                    rank = rank + 20
                end if
                if NxTruthy(artist) and NxTruthy(artistName) then
                    if Instr(1, LCase(NxToStr(artistName)), LCase(NxToStr(artist))) > 0 then rank = rank + 25
                end if
                if NxIsNumber(year) and recYear <> invalid then
                    if recYear = year then
                        rank = rank + 15
                    else if Abs(year - recYear) <= 1 then
                        rank = rank + 8
                    end if
                end if
                if rank > bestRank then
                    bestRank = rank
                    best = { mbid: rec.id, title: rec.title, artist: artistName, year: recYear }
                end if
            end if
        end if
    end for
    return best
end function

' resolveRecording: search, then the recording's own answer (tags, first
' release); its search hit if that second answer fails. invalid when the
' search found nothing or failed.
function NxMusicResolveRecording(net as Object, song as String, artist as Dynamic, year as Dynamic) as Dynamic
    song = CreateObject("roRegex", "\s+\(\d{4}\)$", "").ReplaceAll(song, "").Trim()
    if song = "" then return invalid
    json = net.mbSearch(NxMusicSearchQuery(song, artist))
    if type(json) <> "roAssociativeArray" then return invalid
    hit = NxMusicBestRecording(json.recordings, song, artist, year)
    if hit = invalid then return invalid
    ' A failed or titleless answer leaves the search hit, as upstream's
    ' lookupRecording null or throw does.
    rec = net.mbRecording(NxToStr(hit.mbid))
    if type(rec) = "roAssociativeArray" then
        if NxTruthy(rec.title) then
            return { mbid: hit.mbid, title: rec.title, artist: NxMusicPrimaryArtist(rec), genres: NxMusicMapTags(NxMusicTagNames(rec)), year: NxMusicFirstReleaseYear(rec) }
        end if
    end if
    return { mbid: hit.mbid, title: hit.title, artist: hit.artist, genres: [], year: hit.year }
end function

' ── Deezer answers ──────────────────────────────────────────────────────────

' deezerBestHit: the first hit whose artist shares a word of 3 letters or
' more with the hint, else the first.
function NxMusicDeezerBestHit(hits as Dynamic, artistHint as Dynamic) as Dynamic
    list = NxList(hits)
    if list.Count() = 0 then return invalid
    hint = LCase(NxToStr(artistHint))
    if hint = "" then return list[0]
    words = {}
    for each w in NxMusicWords(hint)
        if w.Len() > 2 then words[w] = true
    end for
    if words.Count() = 0 then return list[0]
    for each h in list
        name = ""
        if type(h) = "roAssociativeArray" then
            if type(h.artist) = "roAssociativeArray" then name = LCase(NxToStr(h.artist.name))
        end if
        for each w in NxMusicWords(name)
            if words.DoesExist(w) then return h
        end for
    end for
    return list[0]
end function

' split(/[^a-z0-9]+/) on lowercase text.
function NxMusicWords(s as String) as Object
    return CreateObject("roRegex", "[^a-z0-9]+", "").Split(s)
end function

' deezerResolve: artist and song first, the bare song second; one album
' answer for the genres. invalid when nothing matched; "error" when an
' answer failed, which ends the attempt, as upstream's throw does.
function NxMusicDeezerResolve(net as Object, song as Dynamic, artist as Dynamic) as Dynamic
    s = NxToStr(song).Trim()
    if s = "" then return invalid
    queries = [s]
    if NxTruthy(artist) then queries = [NxToStr(artist) + " " + s, s]
    for each q in queries
        res = net.dzSearch(q)
        if type(res) <> "roAssociativeArray" then return "error"
        pick = NxMusicDeezerBestHit(res.data, artist)
        if pick <> invalid then
            if type(pick.album) = "roAssociativeArray" then
                album = net.dzAlbum(NxToStr(pick.album.id))
                if type(album) <> "roAssociativeArray" then return "error"
                raw = []
                if type(album.genres) = "roAssociativeArray" then
                    for each g in NxList(album.genres.data)
                        if type(g) = "roAssociativeArray" then
                            if NxTruthy(g.name) then raw.Push(g.name)
                        end if
                    end for
                end if
                name = invalid
                if type(pick.artist) = "roAssociativeArray" then name = pick.artist.name
                return { trackid: pick.id, artist: name, genres: NxMusicMapDeezerGenres(raw) }
            end if
        end if
    end for
    return invalid
end function

' withDeezerGenres: one Deezer round trip for a row with a name and no
' genre. Fills the genres, and the artist when the row had none. Always
' marks the row as shown to Deezer, so a dead lookup isn't repeated.
function NxMusicWithDeezer(net as Object, row as Object, item as Object) as Object
    parsed = NxParseMusicTitle(NxToStr(item.title))
    song = row.title
    if not NxTruthy(song) then song = parsed.song
    artist = row.artist
    if not NxTruthy(artist) then artist = parsed.artist
    if not NxTruthy(artist) then artist = invalid
    out = {}
    for each k in row
        out[k] = row[k]
    end for
    out.deezerchecked = true
    match = NxMusicDeezerResolve(net, song, artist)
    if type(match) = "roAssociativeArray" then
        out.genres = NxMusicMergeGenres(row.genres, match.genres)
        out.deezerid = match.trackid
        if not NxTruthy(out.artist) then out.artist = match.artist
    end if
    out.useful = NxMusicUsefulGenres(out.genres)
    return out
end function

' ── The pass ────────────────────────────────────────────────────────────────

' isSettled: under 90 days old, and it has genres or Deezer was asked.
function NxMusicIsSettled(row as Dynamic, nowSec as LongInteger) as Boolean
    if type(row) <> "roAssociativeArray" then return false
    fetched& = 0
    if NxIsNumber(row.fetched) then fetched& = row.fetched
    if nowSec - fetched& > 90 * 86400 then return false
    return row.useful = true or row.deezerchecked = true
end function

' needsOnlyGenres: named, no genre, never shown to Deezer.
function NxMusicNeedsOnlyGenres(row as Dynamic) as Boolean
    if type(row) <> "roAssociativeArray" then return false
    if row.useful = true or row.deezerchecked = true then return false
    return NxTruthy(row.artist) or NxTruthy(row.mbid)
end function

' The music videos a pass looks at, as small copies a task field can carry.
function NxMusicCandidates(items as Object) as Object
    out = []
    for each it in items
        if NxMusicIsMusicVideo(it) then
            out.Push({ ratingKey: NxToStr(it.ratingKey), title: NxToStr(it.title), artist: it.artist, year: it.year, genres: NxList(it.genres), librarySource: it.librarySource, type: it.type })
        end if
    end for
    return out
end function

' enrichMusicVideos over `items` (NxMusicCandidates), changing `cache` in
' place. Returns how many rows it wrote. `halt`, if given, is an object
' whose shouldStop() says to give up early (the task told to stop, or HIGH
' ROTATION switched off); rows already written stand. `saver`, if given,
' gets save(cache) every NxMusicSaveEvery() rows written, so a long first
' pass isn't lost when the app closes (upstream saves once, at the end).
function NxMusicEnrich(net as Object, items as Object, cache as Object, nowSec as LongInteger, halt = invalid as Dynamic, saver = invalid as Dynamic) as Integer
    updated = 0
    savedAt = 0
    for each item in items
        if halt <> invalid then
            if halt.shouldStop() then exit for
        end if
        if saver <> invalid and updated - savedAt >= NxMusicSaveEvery() then
            saver.save(cache)
            savedAt = updated
        end if
        if NxMusicIsMusicVideo(item) then
            key = NxToStr(item.ratingKey)
            existing = cache[key]
            if NxMusicIsSettled(existing, nowSec) then
                ' cached
            else if NxMusicNeedsOnlyGenres(existing) then
                ' Named by MusicBrainz, never got a genre: Deezer only.
                row = NxMusicWithDeezer(net, existing, item)
                row.fetched = existing.fetched
                cache[key] = row
                updated = updated + 1
            else if type(existing) = "roAssociativeArray" and NxMusicUsefulGenres(item.genres) and NxTruthy(existing.artist) then
                ' The server's own genres, and a name: nothing to ask.
            else
                parsed = NxParseMusicTitle(NxToStr(item.title))
                artistHint = item.artist
                if not NxTruthy(artistHint) then artistHint = parsed.artist
                if not NxTruthy(artistHint) then artistHint = invalid
                song = NxToStr(parsed.song)
                year = invalid
                y = NxMusicLeadingInt(item.year)
                if y <> 0 then year = y
                match = NxMusicResolveRecording(net, song, artistHint, year)
                row = { title: song, artist: artistHint, mbid: invalid, genres: NxMusicMergeGenres(item.genres, []), year: invalid, deezerchecked: false, deezerid: invalid, fetched: nowSec }
                if match <> invalid then
                    row.title = match.title
                    if NxTruthy(match.artist) then row.artist = match.artist
                    row.mbid = match.mbid
                    row.genres = NxMusicMergeGenres(item.genres, match.genres)
                    row.year = match.year
                end if
                row.useful = NxMusicUsefulGenres(row.genres)
                if not row.useful then row = NxMusicWithDeezer(net, row, item)
                cache[key] = row
                updated = updated + 1
            end if
        end if
    end for
    return updated
end function

' ── The cache on the TV ─────────────────────────────────────────────────────

' Rows between saves during a pass.
function NxMusicSaveEvery() as Integer
    return 25
end function

' The cache kept to the library's music videos: rows for anything that's
' no longer one are dropped before a save, so the file can't outgrow the
' library (a TV's memory is tighter than a browser's).
function NxMusicCapCache(cache as Object, items as Object) as Object
    keep = {}
    for each it in items
        keep[NxToStr(it.ratingKey)] = true
    end for
    out = {}
    for each k in cache
        if keep.DoesExist(k) then out[k] = cache[k]
    end for
    return out
end function

' Whether a pass stops: the task told to stop, or HIGH ROTATION off.
function NxMusicShouldStop(taskStopped as Boolean, enabledBundles as Object) as Boolean
    return taskStopped or not NxHasValue(enabledBundles, NxMusicBundleID())
end function

' Rebuildable: cachefs: may be cleared, and then the lookups run again. It
' is keyed by the server's ratingKeys, so a sign-out clears it with the
' library (NxClearAccountCaches).
function NxMusicCachePath(root = "cachefs:" as String) as String
    return root + "/nostalgex-music-videos.json"
end function

function NxMusicLoadCache() as Object
    if not CreateObject("roFileSystem").Exists(NxMusicCachePath()) then return {}
    raw = ReadAsciiFile(NxMusicCachePath())
    if raw = "" then return {}
    c = ParseJson(raw)
    if type(c) <> "roAssociativeArray" then return {}
    return c
end function

sub NxMusicSaveCache(cache as Object)
    WriteAsciiFile(NxMusicCachePath(), FormatJson(cache))
end sub

' The pacing upstream keeps: MusicBrainz asks for about one request a
' second (MIN_INTERVAL_MS), Deezer's is four (DEEZER_MIN_INTERVAL_MS), and
' an answer that hasn't come in 15 s is a failure.
function NxMusicMbIntervalMs() as Integer
    return 1050
end function

function NxMusicDzIntervalMs() as Integer
    return 250
end function

function NxMusicTimeoutMs() as Integer
    return 15000
end function

' HIGH ROTATION, the package whose channels read these genres: the lookups
' run only while it's on, as upstream's isMusicBundleEnabled.
function NxMusicBundleID() as String
    return "high-rotation"
end function
