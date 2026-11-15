' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' The Now Playing panel's poster (#76), as upstream's posterURL(for:)
' (App/AppState+Playback.swift) and PlexAPIService.thumbnailURL: Plex only,
' 300 wide and half again as tall, through the server's thumbnail transcode.
' Upstream puts the token in that URL; here it goes in a header (the request
' is made by components/PosterTask), and the file lands in tmp:.

' What the panel needs to ask for the playing item's poster, or invalid when
' there is none to ask for: not Plex, as upstream's guard backendKind == .plex.
' The saved library keeps no artwork paths, so an item read back from it has
' no thumb, and the item's own thumb address stands in.
function NxPosterRef(b as Dynamic, kind as String) as Dynamic
    if b = invalid or kind <> "plex" then return invalid
    key = NxToStr(b.ratingKey)
    if key = "" or not NxIsNumber(b.serverIndex) then return invalid
    own = NxToStr(b.thumb)
    if own = "" then own = "/library/metadata/" + key + "/thumb"
    paths = NxPosterPaths(b, own)
    return { path: paths[0], paths: paths, serverIndex: b.serverIndex }
end function

' Which image the poster asks for, in order (#312, the Apple TV's
' PlexPosterChain). A film has one: its poster. A TV episode's own thumb is a
' frame grabbed from the episode, landscape and arbitrary, so it comes last:
' the season's poster first, then the series', and the frame only when
' neither loads. The paths are made from keys the item already holds (the
' season's `parentRatingKey`, kept only when that season has a poster of its
' own, and `showKey`), so no extra request finds them, and an item read back
' from an older saved library, which has no season key, has a shorter list.
function NxPosterPaths(b as Object, own as String) as Object
    paths = []
    if NxToStr(b.type) = "episode" then
        season = NxToStr(b.parentRatingKey)
        if season <> "" then paths.Push("/library/metadata/" + season + "/thumb")
        show = NxToStr(b.showKey)
        if show <> "" and show <> "invalid" then paths.Push("/library/metadata/" + show + "/thumb")
    end if
    seen = false
    for each p in paths
        if p = own then seen = true
    end for
    if not seen then paths.Push(own)
    return paths
end function

' thumbnailURL(for:width:), less the token.
function NxPlexPosterUrl(base as String, path as String, width as Integer) as String
    return base + "/photo/:/transcode?url=" + NxUrlEncode(path) + "&width=" + width.ToStr() + "&height=" + (width * 3 \ 2).ToStr()
end function

' Where a poster is saved, one file per address so a Poster node never shows
' a cached picture for another item. Earlier ones are deleted first.
function NxPosterFile(path as String) as String
    name = ""
    for i = 1 to Len(path)
        c = Mid(path, i, 1)
        if (c >= "0" and c <= "9") or (LCase(c) >= "a" and LCase(c) <= "z") then name = name + c else name = name + "_"
    end for
    return "tmp:/nx-poster-" + Right(name, 80) + ".jpg"
end function
