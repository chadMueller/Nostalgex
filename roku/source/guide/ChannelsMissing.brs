' WHY ARE SOME CHANNELS MISSING? (I-004, #227): the row under CHANNEL PACKAGES
' and the MISSING CHANNELS page it opens, held to the Apple TV's. Which
' channels the page lists, each one's rules in plain words, and the line with
' how many titles match now. The drawing is SettingsView's.
'
' Source: upstream Nostalgex/Views/Settings/SettingsChannelsView.swift
' (ChannelsPage.missing, ChannelsPackagesPage's link row, ChannelsMissingPage),
' Views/Settings/SettingsSharedComponents.swift (ChannelRequirementCard) and
' Models/Channel.swift (ChannelRules.plainLanguageRequirements).
'
' Port copyright (c) 2026 nostalgex-roku contributors, MIT License.

' ── Which channels ──────────────────────────────────────────────────────────

' ChannelsMissingPage.groups: for each package in the lineup (every package
' but the per-category collection ones, FRANCHISES included) that is on, held
' by the guide when Settings opened (`built`) and not building, its channels
' not on air (`onAir`, NxOnAirSet) that channels.json defines with rules, in
' the package's order. `defs` maps a channel id, as text, to its channels.json
' entry (NxChannelDefsById). Returns [{ bundle, channels: [def] }], packages
' with none left out.
function NxMissingGroups(bundles as Dynamic, enabled as Dynamic, built as Dynamic, building as Dynamic, onAir as Object, defs as Object) as Object
    groups = []
    for each b in NxList(bundles)
        id = NxToStr(b.id)
        if Left(id, 12) <> "collections-" and NxHasValue(NxList(enabled), id) and NxHasValue(NxList(built), id) and not NxMissingBuilding(building, id) then
            channels = []
            for each cid in NxList(b.channelIDs)
                key = NxToStr(cid)
                def = defs[key]
                if not onAir.DoesExist(key) and def <> invalid and type(def.rules) = "roAssociativeArray" then channels.Push(def)
            end for
            if channels.Count() > 0 then groups.Push({ bundle: b, channels: channels })
        end if
    end for
    return groups
end function

function NxMissingBuilding(building as Dynamic, id as String) as Boolean
    if type(building) <> "roAssociativeArray" then return false
    return building.DoesExist(id)
end function

' The channels on the page, all packages together: the link row's "N CH".
function NxMissingCount(groups as Object) as Integer
    n = 0
    for each g in groups
        n = n + g.channels.Count()
    end for
    return n
end function

' The link row's value on CHANNEL PACKAGES: "n CH", n the channels the page
' lists.
function NxMissingLinkValue(count as Integer) as String
    return count.ToStr() + " CH"
end function

' channels.json's channels by id, as text.
function NxChannelDefsById(config as Dynamic) as Object
    defs = {}
    if type(config) <> "roAssociativeArray" then return defs
    for each def in NxList(config.channels)
        defs[NxToStr(def.id)] = def
    end for
    return defs
end function

' ── ChannelRequirementCard ──────────────────────────────────────────────────

' The amber line: how many matching titles the channel needs (its minItems,
' 50 when unset, as the guide build reads it) and how many the library has.
' `count` is the number, "counting" before the library task has counted, or
' "none" when it won't (a library over NxCoverageMaxTitles, or a saved guide
' with no library behind it), when the line stops at what the channel needs.
function NxMissingNeedsLine(minItems as Dynamic, count as Dynamic) as String
    n = 50
    if NxTruthy(minItems) then n = minItems
    line = "Needs " + NxToStr(n) + " matching title"
    if n <> 1 then line = line + "s"
    line = line + "."
    if NxIsNumber(count) then return line + " You have " + NxToStr(count) + "."
    if NxToStr(count) = "counting" then return line + " Counting yours…"
    return line
end function

' A channel's count from the library task's matchCounts ({ state, byId }):
' its number once counted, else "counting" or "none".
function NxMissingCountOf(matchCounts as Dynamic, id as Dynamic) as Dynamic
    if type(matchCounts) <> "roAssociativeArray" then return "counting"
    state = NxToStr(matchCounts.state)
    if state = "counted" and type(matchCounts.byId) = "roAssociativeArray" then
        n = matchCounts.byId[NxToStr(id)]
        if NxIsNumber(n) then return n
        return 0
    end if
    if state = "none" then return "none"
    return "counting"
end function

' ChannelRules.plainLanguageRequirements: what the channel asks of the library,
' as short lines a viewer can read without knowing what Plex, TMDB or OMDb
' are, in the Apple TV's order and words. Not every field: the ones it leaves
' out are left out here too. A channel with none of them gets one line.
function NxPlainRequirements(rules as Dynamic) as Object
    lines = []
    r = rules
    if type(r) <> "roAssociativeArray" then r = {}

    t = NxToStr(r.type)
    if t = "movie" then lines.Push("Movies only")
    if t = "episode" then lines.Push("TV episodes only")

    if NxToStr(r.source) = "musicVideo" then lines.Push("Music videos only")

    g = r.genres
    if type(g) = "roAssociativeArray" then
        if NxList(g.include).Count() > 0 then lines.Push("Genre: " + NxMissingJoin(g.include, " or "))
        if NxList(g.requireAll).Count() > 0 then lines.Push("Needs every one of these genres: " + NxMissingJoin(g.requireAll, ", "))
        if NxList(g.exclude).Count() > 0 then lines.Push("Not genre: " + NxMissingJoin(g.exclude, ", "))
    end if

    if NxList(r.studios).Count() > 0 then lines.Push("Studio: " + NxMissingJoin(r.studios, " or "))
    if NxList(r.networks).Count() > 0 then lines.Push("Network: " + NxMissingJoin(r.networks, " or "))

    y = r.yearRange
    if type(y) = "roAssociativeArray" then
        if NxIsNumber(y.min) and NxIsNumber(y.max) then
            lines.Push("Released " + NxToStr(y.min) + " to " + NxToStr(y.max))
        else if NxIsNumber(y.min) then
            lines.Push("Released " + NxToStr(y.min) + " or later")
        else if NxIsNumber(y.max) then
            lines.Push("Released before " + NxToStr(y.max))
        end if
    end if

    if NxList(r.contentRatings).Count() > 0 then lines.Push("Rated: " + NxMissingJoin(r.contentRatings, ", "))

    if NxIsNumber(r.ratingMin) then lines.Push("Plex star rating " + NxRatingTenths(r.ratingMin) + " or higher")
    if NxIsNumber(r.imdbRatingMin) then lines.Push("IMDb rating " + NxRatingTenths(r.imdbRatingMin) + " or higher")
    if NxIsNumber(r.rtScoreMin) then lines.Push("Rotten Tomatoes score " + NxToStr(r.rtScoreMin) + " or higher")
    if NxIsNumber(r.metacriticMin) then lines.Push("Metacritic score " + NxToStr(r.metacriticMin) + " or higher")
    if r.wonOscar = true then lines.Push("Won an Oscar")

    if r.watchedOnly = true then lines.Push("Already watched titles only")
    if r.unwatchedOnly = true then lines.Push("Unwatched titles only")
    if r.rewatched = true then lines.Push("Watched three times or more")

    ' At most four keywords, so the card never runs long.
    kw = NxList(r.keywords)
    if kw.Count() > 0 then
        firstFour = []
        for each k in kw
            if firstFour.Count() < 4 then firstFour.Push(k)
        end for
        lines.Push("About: " + NxMissingJoin(firstFour, ", "))
    end if

    d = r.durationRange
    if type(d) = "roAssociativeArray" then
        if NxIsNumber(d.min) and NxIsNumber(d.max) then
            lines.Push("Runs " + NxToStr(d.min) + " to " + NxToStr(d.max) + " minutes")
        else if NxIsNumber(d.min) then
            lines.Push("Runs " + NxToStr(d.min) + " minutes or longer")
        else if NxIsNumber(d.max) then
            lines.Push("Runs " + NxToStr(d.max) + " minutes or shorter")
        end if
    end if

    if lines.Count() = 0 then lines.Push("A specific, curated list of titles rather than a general rule")
    return lines
end function

function NxMissingJoin(list as Dynamic, sep as String) as String
    parts = []
    for each x in NxList(list)
        parts.Push(NxToStr(x))
    end for
    return parts.Join(sep)
end function

' Swift's String(format: "%.1f"), for the ratings here (positive, a tenth or
' coarser): 5 reads 5.0, 8.2 reads 8.2.
function NxRatingTenths(v as Dynamic) as String
    tenths = Int(v * 10 + 0.5)
    return (tenths \ 10).ToStr() + "." + (tenths mod 10).ToStr()
end function

' ── Wrapping a card's lines ─────────────────────────────────────────────────

' `text` broken at spaces into lines of at most `width` characters (the
' Settings type is monospaced), so a card's height is known before it is
' drawn. A word longer than a line is cut. The Apple TV wraps the same lines
' (fixedSize vertical).
function NxWrapText(text as String, width as Integer) as Object
    lines = []
    if width < 1 then width = 1
    line = ""
    for each word in text.Split(" ")
        while Len(word) > width
            if line <> "" then
                lines.Push(line)
                line = ""
            end if
            lines.Push(Left(word, width))
            word = Mid(word, width + 1)
        end while
        if line = "" then
            line = word
        else if Len(line) + 1 + Len(word) <= width then
            line = line + " " + word
        else
            lines.Push(line)
            line = word
        end if
    end for
    if line <> "" or lines.Count() = 0 then lines.Push(line)
    return lines
end function
