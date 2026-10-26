' Plex library loader, ported from Nostalgex's web tuner.
'
' Copyright (c) 2024 Chad Mueller / Muell Haus Inc. (Nostalgex), MIT License.
' Port copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Source: plex-tuner.html scanOnePlexServer, fetchPlexSectionPaged,
' pickBestVersion and resolutionHeight, and parseMusicVideoFromPlex from
' scripts/nostalgex-music-brainz.js. Items come out in upstream's order
' (section, then show, then episode), because the schedule starts from that
' order (the pools stay in library order, as the Apple TV's loaders build
' them), and with upstream's fields and fallbacks.
'
' Differences, none of which reach the filter or schedule:
'   - Items carry `serverIndex`, not upstream's serverUrl and serverToken: the
'     token stays in the registry, never on an item.
'   - `meta` (a display string) is built by the guide, not here.
'   - Items also carry the chosen version's videoCodec, audioCodec,
'     videoProfile and audioChannels, for the player's direct-play decision
'     (source/util/DirectPlay.brs), and episodes their season and episode
'     numbers, for the info panel. No rule reads them.
'   - Shows' episodes are fetched five at a time, as upstream's are, and kept
'     in show order as its Promise.all keeps them; other requests run one at
'     a time. A failed fetch gets three tries here.
'   - MusicBrainz/Deezer enrichment of music videos is not ported yet.
'   - Items don't carry upstream's `serverID`. Its server collections key
'     items by server through it; here they use `serverIndex`
'     (source/collections/Collections.brs).

' One GET against a server: its home-network address when there is one,
' else HTTPS, with up to three tries, since a home network can drop a
' request. Two failures on the home-network address drop it for the rest of
' the load (on the server object only: the next load starts from the saved
' address again). Returns the MediaContainer, or invalid. Sets err.auth when the
' server rejected the token.
function NxPlexGetContainer(server as Object, path as String, err = invalid as Dynamic, timeoutMs = 15000 as Integer) as Dynamic
    base = NxPlexBase(server)
    for attempt = 1 to 3
        res = NxPlexServerGet(base + path, NxToStr(server.accessToken), timeoutMs)
        ' A scan told to stop waiting keeps an answer that came, and tries
        ' nothing again.
        if NxLoadStopped() and (res.code < 200 or res.code > 299) then return invalid
        if res.code = 401 or res.code = 403 or (res.code >= 200 and res.code <= 299) then exit for
        print "plex: a library request failed ("; res.code; "), try "; attempt; " of 3"
        if attempt = 2 and base <> NxToStr(server.uri) then
            ' The home-network address stays dropped for the rest of this load,
            ' so each later request doesn't spend two tries on it first.
            base = NxToStr(server.uri)
            server.lanUri = ""
            print "plex: the home-network address failed twice; using HTTPS for the rest of this load"
        end if
    end for
    if res.code = 401 or res.code = 403 then
        if err <> invalid then err.auth = true
        return invalid
    end if
    return NxPlexContainerOf(res)
end function

' The server's home-network address when there is one, else its HTTPS one.
function NxPlexBase(server as Object) as String
    if NxTruthy(server.lanUri) then return server.lanUri
    return NxToStr(server.uri)
end function

' A response's MediaContainer, or invalid unless it answered 2xx with one.
function NxPlexContainerOf(res as Object) as Dynamic
    if res.code < 200 or res.code > 299 then return invalid
    if type(res.json) <> "roAssociativeArray" then return invalid
    if type(res.json.MediaContainer) <> "roAssociativeArray" then return invalid
    return res.json.MediaContainer
end function

function NxMinInt(a as Integer, b as Integer) as Integer
    if a < b then return a
    return b
end function

' Every item in a section, 300 at a time, as fetchPlexSectionPaged. invalid
' if a page fails (upstream throws and skips the section), except when the
' scan was told to stop waiting: then the pages read so far, as the Apple
' TV's fetchSectionItemsPaged keeps them. includeGuids=1 puts
' the `Guid` list (`tmdb://603`, ...) on each item; without it, a library on
' Plex's current agents has only `plex://` guids and no TMDB ids.
function NxPlexSectionItems(server as Object, key as String) as Dynamic
    pageSize = 300
    all = []
    start = 0
    while true
        mc = NxPlexGetContainer(server, "/library/sections/" + key + "/all?includeGuids=1&X-Plex-Container-Start=" + start.ToStr() + "&X-Plex-Container-Size=" + pageSize.ToStr(), invalid, 30000)
        if mc = invalid then
            if NxLoadStopped() then return all
            return invalid
        end if
        page = NxList(mc.Metadata)
        all.Append(page)
        if page.Count() = 0 then exit while
        if NxIsNumber(mc.totalSize) then
            if all.Count() >= mc.totalSize then exit while
        else if page.Count() < pageSize then
            exit while
        end if
        start = start + pageSize
    end while
    return all
end function

' Port of LibraryChangeSignature.signature: each section's updatedAt and
' contentChangedAt (scannedAt is left out, since a scheduled scan bumps it
' when nothing changed). invalid when a section carries neither, so an
' unobservable library is never called unchanged.
function NxLibrarySignature(serverKey as String, sections as Object) as Dynamic
    parts = []
    for each s in sections
        if type(s) <> "roAssociativeArray" then return invalid
        if s.updatedAt = invalid and s.contentChangedAt = invalid then return invalid
        u = "0"
        if s.updatedAt <> invalid then u = NxToStr(s.updatedAt)
        c = "0"
        if s.contentChangedAt <> invalid then c = NxToStr(s.contentChangedAt)
        parts.Push(NxToStr(s.key) + "=u" + u + "/c" + c)
    end for
    if parts.Count() = 0 then return invalid
    parts.Sort()
    return serverKey + ":" + parts.Join(",")
end function

' The server's library signature now, from one small request; invalid when
' it can't be read or observed.
function NxPlexServerSignature(server as Object) as Dynamic
    mc = NxPlexGetContainer(server, "/library/sections")
    if mc = invalid then return invalid
    return NxLibrarySignature(NxToStr(server.machineIdentifier), NxList(mc.Directory))
end function

' All of a server's playable items. `progress`, if given, is a node whose
' `progress` string field shows how far the scan has got, and `bar` and
' `barCaption` how far through a section's shows. Returns invalid
' when the server rejected the token or its section list failed, as
' upstream's scan throws. `info`, if given, gets the library's `signature`
' as the scan found it (NxLibrarySignature). A scan told to stop waiting
' (NxLoadStopped) returns what it has read, as the Apple TV's
' LibraryScanInterrupted carries it.
function NxPlexScanServer(server as Object, serverIndex as Integer, progress = invalid as Dynamic, info = invalid as Dynamic) as Dynamic
    err = { auth: false }
    mc = NxPlexGetContainer(server, "/library/sections", err)
    if mc = invalid then return invalid
    sections = NxList(mc.Directory)
    if info <> invalid then info.signature = NxLibrarySignature(NxToStr(server.machineIdentifier), sections)
    mvSection = CreateObject("roRegex", "music.?video|^music$|^mv[s]?$", "i")
    musicGenre = CreateObject("roRegex", "music", "i")

    out = []
    for each section in sections
        title = NxToStr(section.title)
        items = NxPlexSectionItems(server, NxToStr(section.key))
        if items = invalid then
            print "plex: skipped a section that failed to load"
        else
            isMusicVideoSection = mvSection.IsMatch(title.Trim())
            if section.type = "show" then
                ' Episodes are fetched five shows at a time, as upstream's
                ' BATCH_SIZE, and kept in show order. A show whose fetch
                ' failed gets the usual three tries on its own.
                batch = 25
                for b = 0 to items.Count() - 1 step batch
                    shows = []
                    urls = []
                    for s = b to NxMinInt(b + batch, items.Count()) - 1
                        shows.Push(items[s])
                        urls.Push(NxPlexBase(server) + "/library/metadata/" + NxToStr(items[s].ratingKey) + "/allLeaves")
                    end for
                    answers = NxPlexServerGetMany(urls, NxToStr(server.accessToken), 5)
                    for s = 0 to shows.Count() - 1
                        show = shows[s]
                        showGenres = NxTags(show.Genre)
                        ' Episodes take the show's TMDB id, as on tvOS: allLeaves
                        ' carries no show Guid list.
                        showTmdb = NxParseTmdbIdFromPlex(show, false)
                        leaves = NxPlexContainerOf(answers[s])
                        if leaves = invalid and not NxLoadStopped() then leaves = NxPlexGetContainer(server, "/library/metadata/" + NxToStr(show.ratingKey) + "/allLeaves")
                        if leaves <> invalid then
                            for each ep in NxList(leaves.Metadata)
                                it = NxPlexEpisodeItem(ep, show, showGenres, showTmdb, isMusicVideoSection)
                                if it <> invalid then
                                    it.serverIndex = serverIndex
                                    out.Push(it)
                                end if
                            end for
                        end if
                    end for
                    answers = invalid
                    if progress <> invalid then
                        progress.progress = title + ": " + NxMinInt(b + batch, items.Count()).ToStr() + " of " + items.Count().ToStr() + " shows"
                        progress.bar = NxMinInt(b + batch, items.Count()) / items.Count()
                        progress.barCaption = NxMinInt(b + batch, items.Count()).ToStr() + " of " + items.Count().ToStr() + " shows"
                    end if
                    if NxLoadStopped() then exit for
                end for
            else
                for each raw in items
                    it = NxPlexMovieItem(raw, section, isMusicVideoSection, musicGenre)
                    if it <> invalid then
                        it.serverIndex = serverIndex
                        out.Push(it)
                    end if
                end for
                if progress <> invalid then
                    progress.progress = title + ": " + items.Count().ToStr() + " items"
                    progress.bar = -1
                end if
            end if
        end if
        if NxLoadStopped() then exit for
    end for
    return out
end function

function NxPlexEpisodeItem(ep as Object, show as Object, showGenres as Object, showTmdb as Dynamic, isMusicVideoSection as Boolean) as Dynamic
    tmdbID = showTmdb
    if tmdbID = invalid then tmdbID = NxParseTmdbIdFromPlex(ep, true)
    durationMin = NxPlexMinutes(ep.duration)
    if durationMin <= 0 then return invalid
    media = NxPickBestVersion(ep.Media)
    partKey = invalid
    container = invalid
    codecs = { video: invalid, audio: invalid, videoProfile: invalid, audioChannels: invalid, width: invalid, height: invalid }
    if media <> invalid then
        container = media.container
        codecs = { video: media.videoCodec, audio: media.audioCodec, videoProfile: media.videoProfile, audioChannels: media.audioChannels, width: media.width, height: media.height }
        parts = NxList(media.Part)
        if parts.Count() > 0 then
            if type(parts[0]) = "roAssociativeArray" then partKey = parts[0].key
        end if
    end if
    librarySource = "tv"
    if isMusicVideoSection then librarySource = "musicVideo"
    return {
        title: NxOr(show.title, "Unknown"),
        episodeTitle: NxOr(ep.title, ""),
        summary: NxOr(ep.summary, NxOr(show.summary, "")),
        year: NxOr(show.year, ""),
        ' First aired, the episode's else the show's: the holiday TV channels
        ' read it (upstream 2d1e237).
        originallyAvailableAt: NxOr(ep.originallyAvailableAt, NxOr(show.originallyAvailableAt, invalid)),
        contentRating: NxOr(show.contentRating, NxOr(ep.contentRating, "")),
        duration: durationMin,
        ratingKey: ep.ratingKey,
        partKey: partKey,
        container: container,
        genres: showGenres,
        rating: NxOr(show.rating, 0),
        userRating: NxOr(show.userRating, 0),
        type: "episode",
        thumb: NxOr(ep.thumb, show.thumb),
        art: show.art,
        viewCount: NxOr(ep.viewCount, 0),
        addedAt: NxOr(ep.addedAt, 0),
        studio: NxOr(show.studio, ""),
        librarySource: librarySource,
        tmdbID: tmdbID,
        artist: invalid,
        ' The show's key (the episode's grandparentRatingKey), which a
        ' collection of shows lists in place of its episodes.
        showKey: NxToStr(show.ratingKey),
        seasonNumber: ep.parentIndex,
        episodeNumber: ep.index,
        videoCodec: codecs.video,
        audioCodec: codecs.audio,
        videoProfile: codecs.videoProfile,
        audioChannels: codecs.audioChannels,
        videoWidth: codecs.width,
        videoHeight: codecs.height
    }
end function

function NxPlexMovieItem(item as Object, section as Object, isMusicVideoSection as Boolean, musicGenre as Object) as Dynamic
    genres = NxTags(item.Genre)
    hasMusicGenre = false
    for each g in genres
        if musicGenre.IsMatch(g) then hasMusicGenre = true
    end for
    if isMusicVideoSection and not hasMusicGenre then genres.Push("Music Video")

    durationMin = NxPlexMinutes(item.duration)
    if durationMin <= 0 then return invalid

    ' A music-video library, or a short item tagged with a Music genre (the
    ' 10-minute cap keeps musicals and biopics out).
    isMusicVideo = isMusicVideoSection or (durationMin <= 10 and hasMusicGenre)

    media = NxPickBestVersion(item.Media)
    partKey = invalid
    container = invalid
    codecs = { video: invalid, audio: invalid, videoProfile: invalid, audioChannels: invalid, width: invalid, height: invalid }
    if media <> invalid then
        container = media.container
        codecs = { video: media.videoCodec, audio: media.audioCodec, videoProfile: media.videoProfile, audioChannels: media.audioChannels, width: media.width, height: media.height }
        parts = NxList(media.Part)
        if parts.Count() > 0 then
            if type(parts[0]) = "roAssociativeArray" then partKey = parts[0].key
        end if
    end if

    sectionType = NxToStr(section.type)
    librarySource = sectionType
    if sectionType = "movie" then librarySource = "movie"
    if isMusicVideo then librarySource = "musicVideo"
    itemType = sectionType
    if sectionType = "show" then itemType = "episode"

    displayTitle = NxOr(item.title, "Unknown")
    artist = invalid
    if isMusicVideo then
        parsed = NxParseMusicVideoFromPlex(item, displayTitle)
        displayTitle = parsed.title
        artist = parsed.artist
    end if

    return {
        title: displayTitle,
        artist: artist,
        summary: NxOr(item.summary, ""),
        year: NxOr(item.year, ""),
        contentRating: NxOr(item.contentRating, ""),
        duration: durationMin,
        ratingKey: item.ratingKey,
        partKey: partKey,
        container: container,
        genres: genres,
        rating: NxOr(item.rating, 0),
        userRating: NxOr(item.userRating, 0),
        type: itemType,
        thumb: item.thumb,
        art: item.art,
        viewCount: NxOr(item.viewCount, 0),
        addedAt: NxOr(item.addedAt, 0),
        studio: NxOr(item.studio, ""),
        librarySource: librarySource,
        tmdbID: NxParseTmdbIdFromPlex(item, false),
        videoCodec: codecs.video,
        audioCodec: codecs.audio,
        videoProfile: codecs.videoProfile,
        audioChannels: codecs.audioChannels,
        videoWidth: codecs.width,
        videoHeight: codecs.height
    }
end function

' Plex milliseconds to whole minutes, truncated as PlexAPIService and
' minutesFromPlexMs do: the schedule follows the Apple TV's minute for minute.
function NxPlexMinutes(ms as Dynamic) as Integer
    if not NxTruthy(ms) or not NxIsNumber(ms) then return 0
    if ms <= 0 then return 0
    return NxFloorDouble(ms / 60000#)
end function

function NxTags(list as Dynamic) as Object
    out = []
    for each t in NxList(list)
        if type(t) = "roAssociativeArray" then out.Push(t.tag) else out.Push(invalid)
    end for
    return out
end function

' The highest-bitrate version, ties to the taller picture; the first when none
' reports a bitrate. Mirrors pickBestVersion with Plex's getters.
function NxPickBestVersion(versions as Dynamic) as Dynamic
    list = NxList(versions)
    if list.Count() = 0 then return invalid
    anyBitrate = false
    for each v in list
        if type(v) = "roAssociativeArray" then
            if v.bitrate <> invalid then anyBitrate = true
        end if
    end for
    if not anyBitrate then return list[0]
    best = list[0]
    for i = 1 to list.Count() - 1
        v = list[i]
        bb = -1
        if best.bitrate <> invalid then bb = best.bitrate
        bv = -1
        if v.bitrate <> invalid then bv = v.bitrate
        if bv <> bb then
            if bv > bb then best = v
        else if NxResolutionHeight(v.videoResolution) > NxResolutionHeight(best.videoResolution) then
            best = v
        end if
    end for
    return best
end function

' Mirrors resolutionHeight, parseInt quirks included ("4k" is 4).
function NxResolutionHeight(res as Dynamic) as Integer
    if not NxTruthy(res) then return 0
    s = LCase(NxToStr(res))
    parts = s.Split("x")
    hit = CreateObject("roRegex", "^\s*([+-]?\d+)", "").Match(parts[parts.Count() - 1])
    if hit.Count() = 2 then return hit[1].ToInt()
    if Instr(1, s, "4k") > 0 then return 2160
    if Instr(1, s, "1080") > 0 then return 1080
    if Instr(1, s, "720") > 0 then return 720
    return 0
end function

' ── Music video titles (nostalgex-music-brainz.js) ──────────────────────────

function NxParseMusicVideoFromPlex(item as Object, rawTitle as String) as Object
    artistHint = invalid
    if NxTruthy(item.parentTitle) then
        artistHint = item.parentTitle
    else if NxTruthy(item.grandparentTitle) then
        artistHint = item.grandparentTitle
    end if
    parsed = NxParseMusicTitle(rawTitle)
    title = rawTitle
    if NxTruthy(parsed.song) then title = parsed.song
    artist = artistHint
    if artist = invalid and NxTruthy(parsed.artist) then artist = parsed.artist
    return { title: title, artist: artist }
end function

' What NxCollectionsFetchPlex reads a server through: getJSON(path) gives
' { MediaContainer } or invalid, as upstream's getJSON gives the document or
' throws.
function NxPlexCollectionsFetcher(server as Object) as Object
    return {
        server: server,
        getJSON: function(path as String) as Dynamic
            mc = NxPlexGetContainer(m.server, path)
            if mc = invalid then return invalid
            return { MediaContainer: mc }
        end function,
        ' Five at a time, as the episodes are; one that failed gets the usual
        ' three tries on its own.
        getMany: function(paths as Object) as Object
            urls = []
            for each path in paths
                urls.Push(NxPlexBase(m.server) + path)
            end for
            answers = NxPlexServerGetMany(urls, NxToStr(m.server.accessToken), 5)
            out = []
            for i = 0 to paths.Count() - 1
                mc = NxPlexContainerOf(answers[i])
                if mc = invalid then mc = NxPlexGetContainer(m.server, paths[i])
                if mc = invalid then out.Push(invalid) else out.Push({ MediaContainer: mc })
            end for
            return out
        end function
    }
end function
