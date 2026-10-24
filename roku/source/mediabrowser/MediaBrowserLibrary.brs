' Jellyfin and Emby library loader, ported from Nostalgex's web tuner.
'
' Copyright (c) 2024 Chad Mueller / Muell Haus Inc. (Nostalgex), MIT License.
' Port copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Source: plex-tuner.html fetchJellyfinLibraryFromServer, its fetchItems,
' tmdbFromProviderIds, unixSecondsFromISO and mediaInfo, and pickBestVersion
' with the Jellyfin getters. Items come out in upstream's order (library,
' then show, then episode, each as the server sorts them by SortName) and
' with upstream's fields and fallbacks, into the same shape as a Plex item
' (source/plex/PlexLibrary.brs). tests/vectors/mediabrowser.json is
' upstream's own function run over saved answers, and the port has to match it.
'
' Jellyfin and Emby answer the same calls here except the libraries list
' (NxMbViewsPath). Upstream quirks kept, since the schedule reads the items:
'   - A music-video library is read for Movie items, as upstream asks, and
'     its items get type "movie".
'   - Episodes take the show's genres, year, ratings, studio and TMDB id, and
'     the show's name ("Unknown" without one), never the episode's SeriesName.
'   - viewCount is UserData.PlayCount, so a title marked played with no count
'     reads 0.
'
' Differences, none of which reach the filter or schedule:
'   - Items carry `serverIndex`, not a server address or token.
'   - `meta` is built by the guide, and `subtitles` aren't kept (the player
'     reads the stream's own tracks).
'   - Episodes also carry seasonNumber and episodeNumber for the info panel.
'   - A request that fails gets three tries (NxMbFetcher), and a server that
'     rejects the token, or whose libraries list fails, fails the scan
'     (invalid) as a Plex server does. Upstream reads either as no libraries.

' The libraries list: /UserViews on Jellyfin; Emby (4.8 to 4.10) answers that
' with 404 and has /Users/{id}/Views (scripts/nostalgex-jellyfin-urls.js).
function NxMbViewsPath(kind as String, userId as String) as String
    if kind = "emby" then return "/Users/" + NxUrlEncode(userId) + "/Views"
    return "/UserViews?userId=" + NxUrlEncode(userId)
end function

' One page of items under a parent, with the fields the channel rules read.
function NxMbItemsPath(userId as String, parentId as String, types as String, start as Integer) as String
    return "/Items?userId=" + NxUrlEncode(userId) + "&ParentId=" + NxUrlEncode(parentId) + "&Recursive=true" + "&IncludeItemTypes=" + types + "&Fields=ProviderIds,Overview,Genres,Studios,MediaSources,ProductionYear,PremiereDate,DateCreated,UserData" + "&StartIndex=" + start.ToStr() + "&Limit=200&SortBy=SortName"
end function

' Items per page, as upstream's Limit=200.
function NxMbPageSize() as Integer
    return 200
end function

' The TMDB id from ProviderIds, whatever the key's case, as a string.
function NxMbTmdb(ids as Dynamic) as Dynamic
    if type(ids) <> "roAssociativeArray" then return invalid
    for each k in ids
        if LCase(k) = "tmdb" then return NxToStr(ids[k])
    end for
    return invalid
end function

' Seconds since 1970 from an ISO 8601 DateCreated ("2023-08-15T07:19:45.0000000Z"),
' 0 when it doesn't parse, as upstream's Date.parse floored to seconds. A
' time without a zone reads as UTC here (Date.parse would take local time);
' Jellyfin and Emby always send one.
function NxMbUnixSeconds(iso as Dynamic) as Integer
    if not NxIsString(iso) then return 0
    hit = CreateObject("roRegex", "^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?)?(Z|[+-]\d{2}:\d{2})?$", "").Match(iso)
    if hit.Count() = 0 then return 0
    y = hit[1].ToInt()
    mo = hit[2].ToInt()
    d = hit[3].ToInt()
    if mo < 1 or mo > 12 or d < 1 or d > 31 then return 0
    ' Days from civil (Howard Hinnant's algorithm), in whole numbers.
    if mo <= 2 then y = y - 1
    era = Int(y / 400)
    yoe = y - era * 400
    mp = (mo + 9) mod 12
    doy = Int((153 * mp + 2) / 5) + d - 1
    doe = yoe * 365 + Int(yoe / 4) - Int(yoe / 100) + doy
    days = era * 146097 + doe - 719468
    ' A LongInteger, not a Double: Int() takes a Float on a Roku, which
    ' rounded these to float32 (up to 64 s off; Discussion #8).
    secs& = days * 86400&
    if hit.Count() > 4 and hit[4] <> "" then secs& = secs& + hit[4].ToInt() * 3600 + hit[5].ToInt() * 60
    if hit.Count() > 6 and hit[6] <> "" then secs& = secs& + hit[6].ToInt()
    if hit.Count() > 7 and hit[7] <> "" and hit[7] <> "Z" then
        sign = 1
        if Left(hit[7], 1) = "-" then sign = -1
        secs& = secs& - sign * (Mid(hit[7], 2, 2).ToInt() * 3600 + Mid(hit[7], 5, 2).ToInt() * 60)
    end if
    return secs&
end function

' RunTimeTicks (100 ns) to whole minutes, truncated as
' JellyfinAPIService.minutes(fromTicks:) and minutesFromTicks do.
function NxMbMinutes(ticks as Dynamic) as Integer
    if not NxTruthy(ticks) or not NxIsNumber(ticks) then return 0
    if ticks <= 0 then return 0
    return NxFloorDouble(ticks / 600000000#)
end function

' The first stream of a type in a source's MediaStreams, or invalid.
function NxMbStream(source as Object, streamType as String) as Dynamic
    for each s in NxList(source.MediaStreams)
        if type(s) = "roAssociativeArray" then
            if s.Type = streamType then return s
        end if
    end for
    return invalid
end function

' The highest-bitrate source, ties to the taller picture; the first when none
' reports a bitrate. pickBestVersion with Bitrate and the video stream's Height.
function NxMbBestSource(sources as Dynamic) as Dynamic
    list = NxList(sources)
    if list.Count() = 0 then return invalid
    anyBitrate = false
    for each s in list
        if type(s) = "roAssociativeArray" then
            if s.Bitrate <> invalid then anyBitrate = true
        end if
    end for
    if not anyBitrate then return list[0]
    best = list[0]
    for i = 1 to list.Count() - 1
        s = list[i]
        bb = -1
        if best.Bitrate <> invalid then bb = best.Bitrate
        bs = -1
        if s.Bitrate <> invalid then bs = s.Bitrate
        if bs <> bb then
            if bs > bb then best = s
        else if NxMbHeight(s) > NxMbHeight(best) then
            best = s
        end if
    end for
    return best
end function

function NxMbHeight(source as Object) as Dynamic
    v = NxMbStream(source, "Video")
    if v = invalid or not NxIsNumber(v.Height) then return 0
    return v.Height
end function

' mediaInfo: the best source's id, container, and first video and audio
' codecs, with the video's profile and the audio's channel count for the
' direct-play decision (source/util/DirectPlay.brs), the source's bitrate
' for the server stream's (NxMbVideoQuery), and its audio tracks when it has
' more than one, for the pick at tune (NxMbPreferredAudioIndex).
function NxMbMediaInfo(item as Object) as Object
    src = NxMbBestSource(item.MediaSources)
    out = { msid: invalid, container: invalid, videoCodec: invalid, audioCodec: invalid, videoProfile: invalid, audioChannels: invalid, doviProfile: invalid, bitrate: invalid, videoWidth: invalid, videoHeight: invalid, audioTracks: invalid }
    if src = invalid then return out
    out.msid = src.Id
    if NxTruthy(src.Container) then out.container = src.Container
    if NxIsNumber(src.Bitrate) then out.bitrate = src.Bitrate
    v = NxMbStream(src, "Video")
    if v <> invalid then
        if NxTruthy(v.Codec) then out.videoCodec = LCase(NxToStr(v.Codec))
        if NxTruthy(v.Profile) then out.videoProfile = LCase(NxToStr(v.Profile))
        if NxIsNumber(v.Width) then out.videoWidth = v.Width
        if NxIsNumber(v.Height) then out.videoHeight = v.Height
        ' Emby only (Jellyfin has no ExtendedVideoSubType): a profile 5 file
        ' goes on no channel (NxIsLeftOffChannels).
        out.doviProfile = NxMbDoviProfile(v.ExtendedVideoSubType)
    end if
    a = NxMbStream(src, "Audio")
    if a <> invalid then
        if NxTruthy(a.Codec) then out.audioCodec = LCase(NxToStr(a.Codec))
        if NxIsNumber(a.Channels) then out.audioChannels = a.Channels
    end if
    out.audioTracks = NxMbAudioTracks(src)
    return out
end function

' A source's audio tracks as { index, language, channels, codec, isDefault },
' in the file's order, or invalid with fewer than two: one track is no
' choice, and most files have one, so they keep nothing extra.
function NxMbAudioTracks(src as Object) as Dynamic
    tracks = []
    for each s in NxList(src.MediaStreams)
        if type(s) = "roAssociativeArray" then
            if s.Type = "Audio" and NxIsNumber(s.Index) then
                t = { index: s.Index, language: invalid, channels: invalid, codec: invalid, isDefault: NxTruthy(s.IsDefault) }
                if NxTruthy(s.Language) then t.language = LCase(NxToStr(s.Language))
                if NxIsNumber(s.Channels) then t.channels = s.Channels
                if NxTruthy(s.Codec) then t.codec = LCase(NxToStr(s.Codec))
                tracks.Push(t)
            end if
        end if
    end for
    if tracks.Count() < 2 then return invalid
    return tracks
end function

' Mirrors embyDoviProfile (upstream scripts/nostalgex-jellyfin-urls.js): Emby
' names a file's Dolby Vision profile in ExtendedVideoSubType, "DoviProfile50"
' for profile 5 and "DoviProfile81" for 8.1, the last digit the base layer's
' compatibility id. Anything else is invalid, an unknown profile.
function NxMbDoviProfile(subType as Dynamic) as Dynamic
    if not NxIsString(subType) then return invalid
    hit = CreateObject("roRegex", "^doviprofile(\d{2,})$", "i").Match(subType)
    if hit.Count() <> 2 then return invalid
    digits = hit[1]
    return Left(digits, digits.Len() - 1).ToInt()
end function

' An episode's first-aired date as upstream keeps it: the episode's
' PremiereDate, else the show's, date part only; invalid with neither.
function NxMbAirDate(ep as Object, show as Object) as Dynamic
    d = ep.PremiereDate
    if not NxTruthy(d) then d = show.PremiereDate
    if not NxTruthy(d) then return invalid
    return Left(NxToStr(d), 10)
end function

function NxMbStudio(item as Object) as String
    list = NxList(item.Studios)
    if list.Count() = 0 or type(list[0]) <> "roAssociativeArray" then return ""
    return NxToStr(NxOr(list[0].Name, ""))
end function

function NxMbPlayCount(item as Object) as Dynamic
    if type(item.UserData) <> "roAssociativeArray" then return 0
    return NxOr(item.UserData.PlayCount, 0)
end function

' A movie-type library's item, or invalid when it has no running time.
function NxMbMovieItem(jf as Object, isMusicVideoSection as Boolean, musicGenre as Object) as Dynamic
    genres = NxList(jf.Genres)
    hasMusicGenre = false
    for each g in genres
        if musicGenre.IsMatch(NxToStr(g)) then hasMusicGenre = true
    end for
    if isMusicVideoSection and not hasMusicGenre then
        genres.Push("Music Video")
        hasMusicGenre = true
    end if
    durationMin = NxMbMinutes(jf.RunTimeTicks)
    if durationMin <= 0 then return invalid
    ' A music-video library, or a short item tagged with a Music genre (the
    ' 10-minute cap keeps musicals and biopics out).
    isMusicVideo = isMusicVideoSection or (durationMin <= 10 and hasMusicGenre)
    mi = NxMbMediaInfo(jf)
    displayTitle = NxOr(jf.Name, "Unknown")
    artist = invalid
    if isMusicVideo then
        parsed = NxParseMusicVideoFromPlex(jf, displayTitle)
        displayTitle = parsed.title
        artist = parsed.artist
    end if
    librarySource = "movie"
    if isMusicVideo then librarySource = "musicVideo"
    return {
        title: displayTitle,
        artist: artist,
        summary: NxOr(jf.Overview, ""),
        year: NxOr(jf.ProductionYear, ""),
        contentRating: NxOr(jf.OfficialRating, ""),
        duration: durationMin,
        ratingKey: jf.Id,
        partKey: mi.msid,
        container: mi.container,
        videoCodec: mi.videoCodec,
        audioCodec: mi.audioCodec,
        videoProfile: mi.videoProfile,
        audioChannels: mi.audioChannels,
        bitrate: mi.bitrate,
        audioTracks: mi.audioTracks,
        genres: genres,
        rating: NxOr(jf.CommunityRating, 0),
        userRating: 0,
        type: "movie",
        thumb: invalid,
        art: invalid,
        viewCount: NxMbPlayCount(jf),
        addedAt: NxMbUnixSeconds(jf.DateCreated),
        studio: NxMbStudio(jf),
        librarySource: librarySource,
        tmdbID: NxMbTmdb(jf.ProviderIds),
        doviProfile: mi.doviProfile,
        videoWidth: mi.videoWidth,
        videoHeight: mi.videoHeight
    }
end function

' An episode, with its show's fields; invalid when it has no running time.
function NxMbEpisodeItem(ep as Object, show as Object, showGenres as Object, showTmdb as Dynamic, isMusicVideoSection as Boolean) as Dynamic
    durationMin = NxMbMinutes(ep.RunTimeTicks)
    if durationMin <= 0 then return invalid
    mi = NxMbMediaInfo(ep)
    librarySource = "tv"
    if isMusicVideoSection then librarySource = "musicVideo"
    return {
        title: NxOr(show.Name, "Unknown"),
        episodeTitle: NxOr(ep.Name, ""),
        summary: NxOr(ep.Overview, NxOr(show.Overview, "")),
        year: NxOr(show.ProductionYear, ""),
        originallyAvailableAt: NxMbAirDate(ep, show),
        contentRating: NxOr(show.OfficialRating, NxOr(ep.OfficialRating, "")),
        duration: durationMin,
        ratingKey: ep.Id,
        partKey: mi.msid,
        container: mi.container,
        videoCodec: mi.videoCodec,
        audioCodec: mi.audioCodec,
        videoProfile: mi.videoProfile,
        audioChannels: mi.audioChannels,
        bitrate: mi.bitrate,
        audioTracks: mi.audioTracks,
        genres: showGenres,
        rating: NxOr(show.CommunityRating, 0),
        userRating: 0,
        type: "episode",
        ' The series id, which a collection of shows lists in place of its
        ' episodes.
        showKey: NxToStr(show.Id),
        thumb: invalid,
        art: invalid,
        viewCount: NxMbPlayCount(ep),
        addedAt: NxMbUnixSeconds(ep.DateCreated),
        studio: NxMbStudio(show),
        librarySource: librarySource,
        tmdbID: showTmdb,
        seasonNumber: ep.ParentIndexNumber,
        episodeNumber: ep.IndexNumber,
        doviProfile: mi.doviProfile,
        videoWidth: mi.videoWidth,
        videoHeight: mi.videoHeight
    }
end function

' The rest of a parent's items once its first page is in, page by page as
' fetchItems: it stops at TotalRecordCount, an empty page, or a page that
' failed (keeping what came before, as upstream's does).
function NxMbMorePages(fetcher as Object, userId as String, parentId as String, types as String, first as Dynamic) as Object
    all = []
    page = first
    while true
        if page = invalid then exit while
        items = NxList(page.Items)
        all.Append(items)
        total = all.Count()
        if NxIsNumber(page.TotalRecordCount) then total = page.TotalRecordCount
        if items.Count() = 0 or all.Count() >= total then exit while
        page = fetcher.getJSON(NxMbItemsPath(userId, parentId, types, all.Count()))
    end while
    return all
end function

' All of a server's playable items. `fetcher` reads the server
' (NxMbFetcher, or a test's): getJSON(path) gives the parsed answer or
' invalid, getMany(paths) one per path, and auth is set once the server
' rejected the token. `progress`, if given, gets `progress`, `bar` and
' `barCaption` as NxPlexScanServer's does. Returns invalid when the token
' was rejected or the libraries list failed.
function NxMbScanServer(fetcher as Object, kind as String, userId as String, serverIndex as Integer, progress = invalid as Dynamic) as Dynamic
    viewsAnswer = fetcher.getJSON(NxMbViewsPath(kind, userId))
    if viewsAnswer = invalid then return invalid
    views = NxList(viewsAnswer.Items)
    musicGenre = CreateObject("roRegex", "music", "i")
    out = []
    for each view in views
        if type(view) = "roAssociativeArray" then
            ct = LCase(NxToStr(view.CollectionType))
            name = NxToStr(NxOr(view.Name, "Library"))
            isMusicVideoSection = ct = "musicvideos"
            parentId = NxToStr(view.Id)
            if ct = "tvshows" then
                series = NxMbMorePages(fetcher, userId, parentId, "Series", fetcher.getJSON(NxMbItemsPath(userId, parentId, "Series", 0)))
                ' Five shows at a time, as upstream's BATCH_SIZE, kept in
                ' show order as its Promise.all keeps them.
                batch = 5
                for b = 0 to series.Count() - 1 step batch
                    shows = []
                    paths = []
                    for s = b to NxMinInt(b + batch, series.Count()) - 1
                        shows.Push(series[s])
                        paths.Push(NxMbItemsPath(userId, NxToStr(series[s].Id), "Episode", 0))
                    end for
                    answers = fetcher.getMany(paths)
                    for s = 0 to shows.Count() - 1
                        show = shows[s]
                        showGenres = NxList(show.Genres)
                        showTmdb = NxMbTmdb(show.ProviderIds)
                        for each ep in NxMbMorePages(fetcher, userId, NxToStr(show.Id), "Episode", answers[s])
                            if type(ep) = "roAssociativeArray" then
                                it = NxMbEpisodeItem(ep, show, showGenres, showTmdb, isMusicVideoSection)
                                if it <> invalid then
                                    it.serverIndex = serverIndex
                                    out.Push(it)
                                end if
                            end if
                        end for
                    end for
                    answers = invalid
                    if progress <> invalid then
                        done = NxMinInt(b + batch, series.Count())
                        progress.progress = name + ": " + done.ToStr() + " of " + series.Count().ToStr() + " shows"
                        progress.bar = done / series.Count()
                        progress.barCaption = done.ToStr() + " of " + series.Count().ToStr() + " shows"
                    end if
                end for
            else
                items = NxMbMorePages(fetcher, userId, parentId, "Movie", fetcher.getJSON(NxMbItemsPath(userId, parentId, "Movie", 0)))
                for each raw in items
                    if type(raw) = "roAssociativeArray" then
                        it = NxMbMovieItem(raw, isMusicVideoSection, musicGenre)
                        if it <> invalid then
                            it.serverIndex = serverIndex
                            out.Push(it)
                        end if
                    end if
                end for
                if progress <> invalid then
                    progress.progress = name + ": " + items.Count().ToStr() + " items"
                    progress.bar = -1
                end if
            end if
        end if
        if fetcher.auth then return invalid
    end for
    return out
end function

' ── By kind of server (source/mediabrowser/ServerKind.brs) ──

' The library's change signature now, or invalid. Jellyfin and Emby keep
' none (their libraries carry no updatedAt), so they are scanned each load,
' as upstream does.
function NxServerSignatureFor(server as Object) as Dynamic
    if NxServerKind(server) <> "plex" then return invalid
    return NxPlexServerSignature(server)
end function

' A server's items (NxPlexScanServer or NxMbScanServer), or invalid.
function NxScanServerFor(server as Object, serverIndex as Integer, progress as Dynamic, info as Object) as Dynamic
    kind = NxServerKind(server)
    if kind = "plex" then return NxPlexScanServer(server, serverIndex, progress, info)
    info.signature = invalid
    return NxMbScanServer(NxMbFetcher(server), kind, NxToStr(server.userId), serverIndex, progress)
end function
