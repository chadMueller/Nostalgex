' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' The guide's schedules from the built pools, as LibraryTask hands them to
' the render thread.

' What each channel airs today and tomorrow, as buildChannelSchedule
' computes it: the hour's time restrictions, then the day's schedule from the
' session cache.
' todayOnly leaves tomorrow out, for a launch that needs the guide up first;
' tomorrow is packed from today's schedule either way, so scheduling it
' afterwards gives the same blocks.
function NxScheduleGuide(ordered as Object, nowSec as LongInteger, todayOnly = false as Boolean) as Object
    day = NxLocalDay(nowSec)
    ' A day is 23 to 25 hours long, so 26 hours on is always tomorrow.
    tomorrowAt& = NxLocalDay(day.dayStartSec + 26 * 3600).dayStartSec + 60
    tomorrowHour = NxLocalDay(tomorrowAt&).hour
    out = []
    for each ch in ordered
        today = NxManifestBlocks(ch, NxTimeFilteredPool(ch, ch.pool, day.hour), nowSec, NxPoolMemo(ch, day.hour))
        tomorrow = []
        if not todayOnly then tomorrow = NxManifestBlocks(ch, NxTimeFilteredPool(ch, ch.pool, tomorrowHour), tomorrowAt&, NxPoolMemo(ch, tomorrowHour))
        blocks = []
        for each b in today
            blocks.Push(NxGuideBlock(b))
        end for
        for each b in tomorrow
            blocks.Push(NxGuideBlock(b))
        end for
        out.Push({ id: ch.id, number: NxChNum(ch), name: ch.name, color: ch.colorHex, blocks: blocks })
    end for
    return out
end function

' The local day and hour, the only things besides the pools that
' NxScheduleGuide's result depends on.
function NxScheduleHourKey(nowSec as LongInteger) as String
    day = NxLocalDay(nowSec)
    return day.dayKey + " " + day.hour.ToStr()
end function

' The channel's NxManifestBlocks memo for its pool at a local hour. A
' channel without time restrictions has one pool all day; one with them
' keeps a memo per hour, the last few only. Lives on the channel, so it goes
' when a build replaces the channel or its pool (ch.pool is never changed in
' place once scheduled).
function NxPoolMemo(ch as Object, hour as Integer) as Object
    if ch.nxMemo = invalid then ch.nxMemo = {}
    key = "all"
    if type(ch.timeRestrictions) = "roAssociativeArray" then key = hour.ToStr()
    memo = ch.nxMemo[key]
    if memo = invalid then
        if ch.nxMemo.Count() >= 4 then ch.nxMemo = {}
        memo = {}
        ch.nxMemo[key] = memo
    end if
    return memo
end function

' What the guide and player need from one airing; nothing secret.
function NxGuideBlock(b as Object) as Object
    it = b.item
    out = {
        startSec: b.startSec, endSec: b.endSec,
        ratingKey: NxToStr(it.ratingKey), line: NxGuideTitle(it), title: NxToStr(it.title),
        episodeTitle: NxToStr(it.episodeTitle), seasonNumber: it.seasonNumber, episodeNumber: it.episodeNumber,
        summary: NxToStr(it.summary), year: NxToStr(it.year), partKey: it.partKey,
        container: it.container, videoCodec: it.videoCodec, audioCodec: it.audioCodec,
        videoProfile: it.videoProfile, audioChannels: it.audioChannels, bitrate: it.bitrate,
        audioTracks: it.audioTracks,
        videoWidth: it.videoWidth, videoHeight: it.videoHeight,
        serverIndex: it.serverIndex, contentRating: NxToStr(it.contentRating), rating: 0,
        type: NxToStr(it.type)
    }
    if NxIsNumber(it.rating) then out.rating = it.rating
    ' Music videos also show their artist and genres (PlexMediaItem+MusicDisplay.swift).
    if it.librarySource = "musicVideo" then
        out.music = true
        out.artist = NxToStr(it.artist)
        out.genreLine = NxMusicGenreLine(it.genres)
    end if
    return out
end function

' A deep-linked item (NxDeepLinkItem) as an airing from nowSec for its
' length. linked: it ends with its file, not its slot, and a guide refresh
' leaves it playing.
function NxLinkedAiring(item as Object, nowSec as LongInteger) as Object
    minutes = 0
    if NxIsNumber(item.duration) then minutes = Int(item.duration)
    if minutes <= 0 then minutes = 120
    b = NxGuideBlock({ item: item, startSec: nowSec, endSec: nowSec + minutes * 60 })
    b.linked = true
    return b
end function

' musicGenreDisplay: up to four genres, less the generic music ones.
function NxMusicGenreLine(genres as Dynamic) as String
    useful = []
    for each g in NxList(genres)
        l = LCase(NxToStr(g))
        if l <> "" and Instr(1, l, "music video") = 0 and l <> "music" and l <> "musical" and useful.Count() < 4 then useful.Push(NxToStr(g))
    end for
    return useful.Join(" · ")
end function
