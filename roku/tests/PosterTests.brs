' Runs source/plex/PlexPoster.brs: the Now Playing panel's poster (#76), after
' upstream's posterURL(for:) and PlexAPIService.thumbnailURL. Hand-written
' cases. Returns the failure count.

function NxRunPosterTests() as Integer
    r = { pass: 0, fail: 0 }

    movie = { ratingKey: "123", thumb: "/library/metadata/123/thumb/1700000000", serverIndex: 0 }
    ref = NxPosterRef(movie, "plex")
    NxCheck(r, "plex movie: its thumb", ref.path, "/library/metadata/123/thumb/1700000000")
    NxCheck(r, "plex movie: its server", ref.serverIndex.ToStr(), "0")
    ' Every backend has a poster (Chad 2026-11-15, parity unless a tech restriction): Jellyfin and Emby ask for the item's Primary image.
    NxCheck(r, "jellyfin movie: its Primary image", NxPosterRef(movie, "jellyfin").path, "/Items/123/Images/Primary?maxWidth=300&quality=90")
    NxCheck(r, "emby movie: the same", FormatJson(NxPosterRef(movie, "emby").paths), "[""/Items/123/Images/Primary?maxWidth=300&quality=90""]")
    NxCheck(r, "an unknown kind has none", FormatJson(NxPosterRef(movie, "kodi")), "null")
    mbEp = { ratingKey: "e1", type: "episode", showKey: "show9", parentRatingKey: "season4", serverIndex: 0 }
    NxCheck(r, "jellyfin episode: season, series, its own", FormatJson(NxPosterRef(mbEp, "jellyfin").paths), "[""/Items/season4/Images/Primary?maxWidth=300&quality=90"",""/Items/show9/Images/Primary?maxWidth=300&quality=90"",""/Items/e1/Images/Primary?maxWidth=300&quality=90""]")
    mbEp.parentRatingKey = invalid
    NxCheck(r, "jellyfin episode with no season id: series then its own", NxPosterRef(mbEp, "jellyfin").paths.Count().ToStr(), "2")
    NxCheck(r, "the ref says its kind", NxPosterRef(mbEp, "emby").kind + NxPosterRef(movie, "plex").kind, "embyplex")
    NxCheck(r, "nothing playing", FormatJson(NxPosterRef(invalid, "plex")), "null")
    saved = { ratingKey: "456", serverIndex: 1 }
    NxCheck(r, "read back from the saved library: the item's own thumb", NxPosterRef(saved, "plex").path, "/library/metadata/456/thumb")
    ' #312: an episode's poster is its season's, then its series', then its own frame.
    ep = { ratingKey: "900", type: "episode", showKey: "50", parentRatingKey: "60", thumb: "/library/metadata/900/thumb/1", serverIndex: 0 }
    NxCheck(r, "episode: season, series, then its frame", FormatJson(NxPosterRef(ep, "plex").paths), "[""/library/metadata/60/thumb"",""/library/metadata/50/thumb"",""/library/metadata/900/thumb/1""]")
    NxCheck(r, "episode: the first path is the season's", NxPosterRef(ep, "plex").path, "/library/metadata/60/thumb")
    ep.parentRatingKey = invalid
    NxCheck(r, "episode with no season poster: the series, then its frame", FormatJson(NxPosterRef(ep, "plex").paths), "[""/library/metadata/50/thumb"",""/library/metadata/900/thumb/1""]")
    older = { ratingKey: "901", type: "episode", serverIndex: 0 }
    NxCheck(r, "episode read back from an older library: its own thumb", FormatJson(NxPosterRef(older, "plex").paths), "[""/library/metadata/901/thumb""]")
    ep.showKey = "invalid"
    NxCheck(r, "a show key that was never kept is not asked for", FormatJson(NxPosterRef(ep, "plex").paths), "[""/library/metadata/900/thumb/1""]")
    NxCheck(r, "a movie has one path", FormatJson(NxPosterRef(movie, "plex").paths), "[""/library/metadata/123/thumb/1700000000""]")
    NxCheck(r, "season key: kept only with a season poster", FormatJson([NxPosterSeasonKey({ parentRatingKey: "60", parentThumb: "/x" }), NxPosterSeasonKey({ parentRatingKey: "60" }), NxPosterSeasonKey({ parentThumb: "/x" })]), "[""60"",null,null]")
    ' The guide's block carries the season and series keys of an episode, so the poster chain is real on a screen.
    blk = NxGuideBlock({ item: { ratingKey: "900", type: "episode", title: "Show", episodeTitle: "Ep", showKey: "50", parentRatingKey: "60", serverIndex: 0, duration: 30, summary: "", year: "" }, startSec: 0, endSec: 1800 })
    NxCheck(r, "a block keeps an episode's season and series keys", blk.parentRatingKey + "," + blk.showKey, "60,50")
    NxCheck(r, "and the chain from the block is season, series, its own", FormatJson(NxPosterRef(blk, "plex").paths), "[""/library/metadata/60/thumb"",""/library/metadata/50/thumb"",""/library/metadata/900/thumb""]")
    mov = NxGuideBlock({ item: { ratingKey: "7", type: "movie", title: "Film", showKey: "50", serverIndex: 0, duration: 90, summary: "", year: "" }, startSec: 0, endSec: 5400 })
    NxCheck(r, "a film's block keeps no show key", FormatJson(mov.DoesExist("showKey")), "false")
    NxCheck(r, "no rating key", FormatJson(NxPosterRef({ serverIndex: 0 }, "plex")), "null")
    NxCheck(r, "no server", FormatJson(NxPosterRef({ ratingKey: "1" }, "plex")), "null")

    ' thumbnailURL(for:width: 300): url, width, height; the token is a header.
    url = NxPlexPosterUrl("https://1-2-3-4.abc.plex.direct:32400", "/library/metadata/123/thumb/1700000000", 300)
    NxCheck(r, "transcode url", url, "https://1-2-3-4.abc.plex.direct:32400/photo/:/transcode?url=%2Flibrary%2Fmetadata%2F123%2Fthumb%2F1700000000&width=300&height=450")
    NxCheck(r, "no token in it", FormatJson(Instr(1, LCase(url), "token") = 0), "true")

    ' The request goes through NxServerTransfer's address rule, as every
    ' other Plex request: plain HTTP to a home-network server is allowed.
    lan = NxPlexPosterUrl("http://192.168.1.20:32400", "/library/metadata/123/thumb", 300)
    NxCheck(r, "home network http url", lan, "http://192.168.1.20:32400/photo/:/transcode?url=%2Flibrary%2Fmetadata%2F123%2Fthumb&width=300&height=450")
    NxCheck(r, "home network http allowed", FormatJson(NxServerUrlAllowed(lan)), "true")
    NxCheck(r, "https allowed", FormatJson(NxServerUrlAllowed(url)), "true")
    NxCheck(r, "public http refused", FormatJson(NxServerUrlAllowed(NxPlexPosterUrl("http://203.0.113.5:32400", "/library/metadata/1/thumb", 300))), "false")
    NxCheck(r, "file per address", NxPosterFile("/library/metadata/123/thumb/17"), "tmp:/nx-poster-_library_metadata_123_thumb_17.jpg")

    print "poster cases (upstream posterURL, thumbnailURL): "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function
