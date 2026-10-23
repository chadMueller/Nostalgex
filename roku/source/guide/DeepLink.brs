' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Deep links (Roku certification 5): the TV launches the app, or sends it an
' roInput event while it runs, with a contentId and a mediaType. Here a
' contentId names a guide channel, by its id or else by the number on the
' guide, and the app tunes it fullscreen. Any mediaType is taken, since every
' channel is live; one that names no channel leaves the guide as it is.
'
' A sideloaded build also takes contentId "item:<id>", a server's item id
' (Plex's ratingKey, Jellyfin's or Emby's Id): that film or episode plays
' fullscreen from its start, for trying a fix on a given file without
' waiting for it to air. A store build ignores it.

' The link in launch args or an roInput event's info, or invalid when it has
' no contentId and mediaType.
function NxDeepLinkFrom(args as Dynamic) as Dynamic
    if type(args) <> "roAssociativeArray" and type(args) <> "AssociativeArray" then return invalid
    contentId = NxDeepLinkText(args.contentId)
    mediaType = NxDeepLinkText(args.mediaType)
    if contentId = "" or mediaType = "" then return invalid
    return { contentId: contentId, mediaType: mediaType }
end function

function NxDeepLinkText(v as Dynamic) as String
    if v = invalid then return ""
    if type(v) = "roString" or type(v) = "String" then return v.Trim()
    ' A real Roku hands a number over as roInteger, which the interpreter
    ' never produces, so any numeric type is taken.
    if NxIsNumber(v) then return v.ToStr()
    return ""
end function

' The item id an "item:<id>" link names, or "" for any other link, and for
' every link when isDev is false (roAppInfo.IsDev(): not sideloaded).
function NxDeepLinkItem(link as Dynamic, isDev as Boolean) as String
    if not isDev or link = invalid then return ""
    ' An unset node field reads as {}, not invalid.
    id = NxDeepLinkText(link.contentId)
    if LCase(Left(id, 5)) <> "item:" then return ""
    return Mid(id, 6).Trim()
end function

' The index in channels of the channel the link names, or -1.
function NxDeepLinkChannel(channels as Dynamic, link as Dynamic) as Integer
    if channels = invalid or link = invalid then return -1
    ' An unset node field reads as {}, not invalid.
    if NxDeepLinkText(link.contentId) = "" then return -1
    for i = 0 to channels.Count() - 1
        if NxDeepLinkText(channels[i].id) = link.contentId then return i
    end for
    for i = 0 to channels.Count() - 1
        if NxDeepLinkText(channels[i].number) = link.contentId then return i
    end for
    return -1
end function
