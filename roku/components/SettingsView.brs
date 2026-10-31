' Copyright (c) 2026 nostalgex-roku contributors, MIT License.

sub init()
    m.focus = 0
    m.scroll = 0
    ' The list's height on the page, under the SETTINGS title.
    m.listTop = 100
    m.listH = 800
    m.fonts = {}
    m.franchisesChanged = false
    ' The first OK on SIGN OUT only arms it; a second one signs out.
    m.signOutArmed = false
    m.collectionsChanged = false
    ' The list open under SUBTITLE LANGUAGE ("subsLanguage"), AUDIO LANGUAGE
    ' ("audioLanguage") or STREAM QUALITY ("streamQuality"), "" when all are
    ' folded.
    m.languageOpen = ""
    ' Packages switched on whose channels are still being built: { id: true }.
    ' A package switch is saved and built at once, behind Settings, as
    ' upstream's toggleBundle; needRebuild is set when that couldn't be done
    ' and the whole guide has to be rebuilt on the way out instead.
    m.building = {}
    m.needRebuild = false
    m.dots = ""
    m.dotTimer = CreateObject("roSGNode", "Timer")
    m.dotTimer.duration = 0.4
    m.dotTimer.repeat = true
    m.dotTimer.ObserveField("fire", "onDots")
end sub

' The library load started or finished while Settings is open.
sub onRescanning()
    if m.rows <> invalid then render()
end sub

sub onDots()
    if m.building.Count() = 0 then
        m.dotTimer.control = "stop"
        return
    end if
    if Len(m.dots) >= 3 then m.dots = "" else m.dots = m.dots + "."
    render()
end sub

' The packages switched on whose channels are still being built.
function buildingIds(unused = invalid as Dynamic) as Object
    return m.building.Keys()
end function

' Builds the guide is still waiting on, from a visit before this one.
sub setBuilding(ids as Object)
    for each id in ids
        m.building[id] = true
    end for
    if m.building.Count() > 0 then m.dotTimer.control = "start"
end sub

' The library task's answer to a package switch (LibraryTask.bundleBuilt):
' the packages the guide now holds, or "rebuild".
sub onBundleBuilt()
    v = m.top.bundleBuilt
    if v = "rebuild" then
        m.needRebuild = true
        m.building = {}
    else
        built = ParseJson(v)
        if type(built) = "roArray" then
            for each id in m.building.Keys()
                if NxHasValue(built, id) then m.building.Delete(id)
            end for
        end if
    end if
    render()
end sub

' The guide was rebuilt while Settings is open: rows follow its franchise and
' collection lists, and focus stays on the same row.
sub refreshRows(unused = invalid as Dynamic)
    keep = m.rows[m.focus]
    buildRows()
    for i = 0 to rowCount() - 1
        r = m.rows[i]
        if r.kind = keep.kind and NxToStr(r.index) = NxToStr(keep.index) and NxToStr(r.category) = NxToStr(keep.category) then
            if r.kind <> "franchise" or r.franchise.id = keep.franchise.id then
                m.focus = i
                exit for
            end if
        end if
    end for
    if m.focus > rowCount() - 1 or not focusable(m.rows[m.focus]) then m.focus = nextFocusable(-1, 1)
    render()
end sub

function fontOf(name as String, size as Integer) as Object
    key = name + size.ToStr()
    if m.fonts[key] = invalid then
        f = CreateObject("roSGNode", "Font")
        f.uri = "pkg:/fonts/" + name + ".ttf"
        f.size = size
        m.fonts[key] = f
    end if
    return m.fonts[key]
end function

function newLabel(text as String, font as String, size as Integer, color as String, x as Float, y as Float) as Object
    lbl = CreateObject("roSGNode", "Label")
    lbl.text = text
    lbl.font = fontOf(font, size)
    lbl.color = color
    lbl.translation = [x, y]
    return lbl
end function

function newRect(x as Float, y as Float, w as Float, h as Float, color as String) as Object
    r = CreateObject("roSGNode", "Rectangle")
    r.translation = [x, y]
    r.width = w
    r.height = h
    r.color = color
    return r
end function

' Rows: every package, with the franchise list under FRANCHISES while it is
' on (upstream's BundleManagerView), then RETRO MODE and subtitles (its
' PLAYBACK section), then sign-out.
sub open(unused = invalid as Dynamic)
    ' The saved packages, not the guide's: with a build still queued behind
    ' the one that landed, the guide's would bring back a package just
    ' switched off, and the next switch would save it again.
    m.enabled = NxEnabledBundles()
    m.subs = NxSubtitleSettings()
    m.report = NxReportPrefs()
    m.choices = NxSavedFranchiseChoices()
    m.collectionKeys = NxSavedCollectionKeys()
    reg = NxPlexRegistry()
    m.servers = ParseJson(reg.Read("servers"))
    if type(m.servers) <> "roArray" then m.servers = []
    m.serversOn = NxServersOn(m.servers, NxSavedServerChoices())
    ' A server switched on and back off in one visit changes nothing, so the
    ' way out compares with this rather than counting presses.
    m.serversOnAtOpen = FormatJson(m.serversOn)
    m.serversChanged = false
    ' Which MY COLLECTIONS categories are open, by category.
    m.collectionsOpen = {}
    m.languageOpen = ""
    buildRows()
    m.focus = nextFocusable(-1, 1)
    m.scroll = 0
    m.top.SetFocus(true)
    render()
end sub

' The row list, in the order of upstream's SettingsPageView
' (Views/BundleManagerView.swift): SUPPORT NOSTALGEX, CONNECTION (the servers,
' then sign-out), PLAYBACK, CHANNEL PACKAGES, then MY COLLECTIONS, each
' category folded closed behind a SHOW/HIDE row, as upstream's
' CollectionAccordionHeaderRow. Kinds:
'   header, subheader, info: text only, never focused
'   support, server, signOut, retro, guideText (GUIDE TEXT SIZE), quality
'   (STREAM QUALITY),
'   qualityChoice, subtitles, language (SUBTITLE or AUDIO LANGUAGE),
'   languageChoice, bundle, franchiseAll, franchise,
'   collectionsToggle, collection: rows
' The franchise rows are the last guide build's, so they show once the
' package was on for a build. MY COLLECTIONS has upstream's two categories,
' FRANCHISES then OTHER COLLECTIONS, each shown only when it has a row.
sub buildRows()
    m.rows = []
    m.rows.Push({ kind: "header", title: "SUPPORT NOSTALGEX", subtitle: "News, help and the Apple TV app are on its site" })
    m.rows.Push({ kind: "support" })

    m.rows.Push({ kind: "header", title: "CONNECTION", subtitle: "" })
    m.rows.Push({ kind: "subheader", text: "SERVERS" })
    for i = 0 to m.servers.Count() - 1
        m.rows.Push({ kind: "server", index: i })
    end for
    ' Upstream's RESCAN LIBRARY, after the servers.
    m.rows.Push({ kind: "rescan" })
    ' Upstream's two reporting switches, after the server, both off by
    ' default (issue #72, source/guide/PlaybackReport.brs).
    m.rows.Push({ kind: "reportNowPlaying" })
    m.rows.Push({ kind: "reportMarkWatched" })
    m.rows.Push({ kind: "signOut" })

    m.rows.Push({ kind: "header", title: "PLAYBACK", subtitle: "Picture and subtitles" })
    m.rows.Push({ kind: "retro" })
    m.rows.Push({ kind: "guideText" })
    pushQuality()
    m.rows.Push({ kind: "subtitles" })
    ' SUBTITLE LANGUAGE only while subtitles can show, as upstream's.
    if m.subs.always or m.subs.foreign then pushLanguage("subsLanguage")
    pushLanguage("audioLanguage")

    m.rows.Push({ kind: "header", title: "CHANNEL PACKAGES", subtitle: "Toggle packages to customize your lineup" })
    for i = 0 to m.top.bundles.Count() - 1
        b = m.top.bundles[i]
        m.rows.Push({ kind: "bundle", index: i })
        if b.id = NxFranchisesBundleID() and NxHasValue(m.enabled, b.id) and m.top.franchises.Count() > 0 then
            full = franchisesFullNote()
            if full <> "" then m.rows.Push({ kind: "info", text: full })
            m.rows.Push({ kind: "franchiseAll" })
            for each f in m.top.franchises
                m.rows.Push({ kind: "franchise", franchise: f })
            end for
        end if
    end for

    m.rows.Push({ kind: "header", title: "MY COLLECTIONS", subtitle: "Turn the server collections you want into channels" })
    note = collectionsNote()
    if note <> "" then m.rows.Push({ kind: "info", text: note })
    for each category in ["franchises", "custom"]
        rows = collectionRows(category)
        if rows.Count() > 0 then
            m.rows.Push({ kind: "collectionsToggle", category: category })
            full = collectionsFullNote(category)
            if full <> "" then m.rows.Push({ kind: "info", text: full })
            if m.collectionsOpen[category] = true then
                for each row in rows
                    m.rows.Push({ kind: "collection", collection: row })
                end for
            end if
        end if
    end for
    m.rows.Push({ kind: "version", text: NxVersionLabel() })
end sub

' A language row, and the presets under it while it is open, as upstream's
' picker sheet lists them.
sub pushLanguage(key as String)
    m.rows.Push({ kind: "language", key: key })
    if m.languageOpen <> key then return
    for each p in NxLanguagePresets()
        m.rows.Push({ kind: "languageChoice", key: key, code: p.code, label: p.label })
    end for
end sub

' STREAM QUALITY, and while it is open the Apple TV's picker sheet in place:
' its line, then the five levels, each with its detail.
sub pushQuality()
    m.rows.Push({ kind: "quality" })
    if m.languageOpen <> "streamQuality" then return
    m.rows.Push({ kind: "info", text: "Lower quality uses less bandwidth. Auto adjusts as your connection changes." })
    for each l in NxSqLevels()
        m.rows.Push({ kind: "qualityChoice", key: "streamQuality", code: l.id, label: l.name, detail: l.detail })
    end for
end sub

' The row of `kind` (and `key`, for the language rows), else -1.
function rowIndex(kind as String, key = "" as String, code = "" as String) as Integer
    for i = 0 to rowCount() - 1
        row = m.rows[i]
        if row.kind = kind and (key = "" or row.key = key) and (code = "" or row.code = code) then return i
    end for
    return -1
end function

' Folds the open list, focus back on its row.
sub foldLanguage()
    key = m.languageOpen
    m.languageOpen = ""
    buildRows()
    if key = "streamQuality" then m.focus = rowIndex("quality") else m.focus = rowIndex("language", key)
    render()
end sub

function focusable(row as Object) as Boolean
    return row.kind <> "header" and row.kind <> "subheader" and row.kind <> "info" and row.kind <> "support" and row.kind <> "version"
end function

' The next row focus can land on from i, going d (1 or -1); i if none.
function nextFocusable(i as Integer, d as Integer) as Integer
    j = i + d
    while j >= 0 and j < rowCount()
        if focusable(m.rows[j]) then return j
        j = j + d
    end while
    return i
end function

function rowHeight(row as Object) as Integer
    if row.kind = "header" then
        if row.subtitle = "" then return 84
        return 112
    end if
    if row.kind = "subheader" or row.kind = "info" then return 44
    if row.kind = "version" then return 56
    if row.kind = "rescan" then return 126
    ' Upstream's subtitle in two lines.
    if row.kind = "reportNowPlaying" or row.kind = "reportMarkWatched" then return 100
    return 74
end function

function rowCount() as Integer
    return m.rows.Count()
end function

' A row's switch: the viewer's choice since the last build, else the build's.
function franchiseOn(f as Object) as Boolean
    if m.choices.enabled.DoesExist(f.id) then return true
    if m.choices.disabled.DoesExist(f.id) then return false
    return f.enabled
end function

function collectionOn(row as Object) as Boolean
    return m.collectionKeys.DoesExist(row.id)
end function

' The rows of one category. A row from a build before the split has none
' and is OTHER COLLECTIONS, as every row was.
function collectionRows(category as String) as Object
    out = []
    c = m.top.collections
    if c = invalid then return out
    for each row in NxList(c.rows)
        cat = "custom"
        if NxToStr(row.category) = "franchises" then cat = "franchises"
        if cat = category then out.Push(row)
    end for
    return out
end function

' A line under MY COLLECTIONS when there is something to say beyond the
' accordions' counts: none found, or a read that failed. A full block says
' so under its own accordion (collectionsFullNote).
function collectionsNote() as String
    c = m.top.collections
    if c = invalid then return ""
    rows = NxList(c.rows)
    if NxNumberOr0(c.failed) > 0 and rows.Count() = 0 then return "COULD NOT READ COLLECTIONS FROM YOUR SERVER"
    if rows.Count() = 0 then
        if NxNumberOr0(c.scanned) > 0 then return "NO COLLECTIONS WITH 3 OR MORE MOVIES OR EPISODES"
        return "Your server's collections show here after the library is read"
    end if
    return ""
end function

' Under an accordion whose block is full, as upstream's: "Up to 50 of these
' fit in the guide. 3 more are switched on but not shown." Empty otherwise.
function collectionsFullNote(category as String) as String
    c = m.top.collections
    if c = invalid then return ""
    ' The block sizes come with the build that filled them.
    over = NxNumberOr0(c.overCapCustom)
    capacity = NxNumberOr0(c.capacityCustom)
    ' A build before the split counted only CH 699.
    if c.overCapCustom = invalid then over = NxNumberOr0(c.overCap)
    if category = "franchises" then
        over = NxNumberOr0(c.overCapFranchises)
        capacity = NxNumberOr0(c.capacityFranchises)
    end if
    if over <= 0 or capacity <= 0 then return ""
    return "Up to " + capacity.ToStr() + " of these fit in the guide. " + over.ToStr() + " more are switched on but not shown."
end function

' Under the franchise list when CH 300-449 is full, as upstream's.
function franchisesFullNote() as String
    over = NxNumberOr0(m.top.franchiseOverCap)
    capacity = NxNumberOr0(m.top.franchiseCapacity)
    if over <= 0 or capacity <= 0 then return ""
    return "Up to " + capacity.ToStr() + " franchise channels fit in the guide. " + over.ToStr() + " more are switched on but not shown."
end function

' An accordion's "n/m ON AIR", counting this visit's switches.
function collectionsOnAir(category as String) as String
    rows = collectionRows(category)
    onAir = 0
    for each row in rows
        if collectionOn(row) then onAir = onAir + 1
    end for
    return onAir.ToStr() + "/" + rows.Count().ToStr() + " ON AIR"
end function

function anyFranchiseOff() as Boolean
    for each f in m.top.franchises
        if not franchiseOn(f) then return true
    end for
    return false
end function

' Upstream's SUBTITLES row (BundleManagerView): one setting for both flags.
function subtitleModeLabel() as String
    if m.subs.always then return "ALWAYS"
    if m.subs.foreign then return "FOREIGN AUDIO"
    return "OFF"
end function

function subtitleModeExplanation() as String
    if m.subs.always then return "Shown in fullscreen whenever the video has them"
    if m.subs.foreign then return "Shown in fullscreen when the audio isn't in your language"
    return "Never shown. Press to change"
end function

' Off, then foreign audio only, then always, then back to off.
sub cycleSubtitleMode()
    if m.subs.always then
        m.subs.always = false
        m.subs.foreign = false
    else if m.subs.foreign then
        m.subs.always = true
    else
        m.subs.foreign = true
    end if
    NxSaveSubtitleSettings(m.subs)
end sub

sub render()
    page = m.top.FindNode("page")
    page.RemoveChildrenIndex(page.GetChildCount(), 0)
    page.AppendChild(newLabel("SETTINGS", "VT323-Regular", 56, "0xFFE500FF", 0, 0))

    ' Where each row sits in the whole list, then a scroll that keeps the
    ' focused row in view, with the headings just above it when they fit.
    tops = []
    y = 0
    for each row in m.rows
        tops.Push(y)
        y = y + rowHeight(row)
    end for
    top = tops[m.focus]
    bottom = top + rowHeight(m.rows[m.focus])
    k = m.focus - 1
    while k >= 0 and not focusable(m.rows[k]) and bottom - tops[k] <= m.listH
        top = tops[k]
        k = k - 1
    end while
    ' At the last row focus can reach, the lines after it (the VERSION line)
    ' come into view too, as the end of upstream's scroll does.
    if nextFocusable(m.focus, 1) = m.focus then
        last = rowCount() - 1
        if tops[last] + rowHeight(m.rows[last]) - top <= m.listH then bottom = tops[last] + rowHeight(m.rows[last])
    end if
    if top < m.scroll then m.scroll = top
    if bottom > m.scroll + m.listH then m.scroll = bottom - m.listH

    for i = 0 to rowCount() - 1
        row = m.rows[i]
        rt = tops[i]
        if rt >= m.scroll and rt + rowHeight(row) <= m.scroll + m.listH then
            y = m.listTop + rt - m.scroll
            if row.kind = "header" then
                ' A thin divider between sections, as settingsDivider.
                if i > 0 then page.AppendChild(newRect(0, y + 8, 1680, 1, "0xFFFFFF0F"))
                page.AppendChild(newLabel(row.title, "DMMono-Medium", 28, "0xFFFFFFCC", 0, y + 28))
                if row.subtitle <> "" then page.AppendChild(newLabel(row.subtitle, "DMMono-Regular", 20, "0xFFFFFFB3", 0, y + 68))
            else if row.kind = "subheader" or row.kind = "info" then
                page.AppendChild(newLabel(row.text, "DMMono-Regular", 20, "0xFFFFFFB3", 0, y + 8))
            else if row.kind = "support" then
                page.AppendChild(newLabel("NOSTALGEX.APP", "DMMono-Medium", 24, "0xFFFFFFBF", 30, y + 10))
                page.AppendChild(newLabel("Open it on a phone or computer", "VT323-Regular", 24, "0xFFFFFF80", 30, y + 40))
                page.AppendChild(newRect(0, y, 4, 72, "0xFFE50066"))
            else if row.kind = "version" then
                version = newLabel(row.text, "DMMono-Regular", 20, "0xFFFFFFB3", 0, y + 20)
                version.width = 1680
                version.horizAlign = "center"
                page.AppendChild(version)
            else
                drawRow(page, i, row, y)
            end if
        end if
    end for
    page.AppendChild(newLabel("OK toggles · BACK returns to the guide", "DMMono-Regular", 20, "0xFFFFFF59", 0, m.listTop + m.listH + 24))
end sub

function serversOnCount() as Integer
    n = 0
    for each x in m.serversOn
        if x then n = n + 1
    end for
    return n
end function

sub drawRow(page as Object, i as Integer, row as Object, y as Float)
    focused = i = m.focus
    accent = "0xFFE500"
    extra = []
    indent = 0
    faded = false
    if row.kind = "bundle" then
        b = m.top.bundles[row.index]
        on = NxHasValue(m.enabled, b.id)
        label = b.name
        detail = b.channelIDs.Count().ToStr() + " CHANNELS"
        ' A seasonal package works in every month; outside its season the row
        ' says when it's spotlighted, as upstream's rows do.
        if NxIsSeasonal(b) then
            now = NxSeasonNow()
            if NxIsInSeason(b, now) then
                detail = detail + " · SEASONAL"
            else
                detail = detail + " · " + NxSeasonSpotlightLabel(b, now)
            end if
        end if
        state = "OFF"
        stateColor = "0xFFFFFF59"
        if on then
            state = "ON"
            stateColor = "0xFFE500FF"
        end if
        if on and m.building.DoesExist(b.id) then
            n = b.channelIDs.Count()
            detail = "Finding " + n.ToStr() + " channel"
            if n <> 1 then detail = detail + "s"
            ' The build runs behind the guide too, which nothing said
            ' (Discussion #8); the maintainer's wording.
            detail = detail + " in your library · You can go back to the guide; they show up when ready"
            state = "BUILDING" + m.dots
        end if
    else if row.kind = "franchiseAll" then
        indent = 40
        label = "YOUR FRANCHISES"
        detail = "Every franchise below at once"
        state = "REMOVE ALL"
        if anyFranchiseOff() then state = "ADD ALL"
        stateColor = "0xFFE500FF"
    else if row.kind = "franchise" then
        indent = 40
        f = row.franchise
        label = f.name
        detail = f.countLabel
        if f.channelNumber <> invalid then detail = detail + " · CH " + f.channelNumber.ToStr()
        state = "OFF"
        stateColor = "0xFFFFFF59"
        if franchiseOn(f) then
            state = "ON"
            stateColor = "0xFFE500FF"
        end if
    else if row.kind = "collectionsToggle" then
        label = NxCollectionCategoryName(row.category)
        detail = NxCollectionCategoryDescription(row.category) + " · " + collectionsOnAir(row.category)
        if m.collectionsChanged then detail = "Changes air when you go back to the guide · " + collectionsOnAir(row.category)
        state = "SHOW"
        if m.collectionsOpen[row.category] = true then state = "HIDE"
        stateColor = "0xFFE500FF"
    else if row.kind = "collection" then
        indent = 40
        cr = row.collection
        label = cr.title
        detail = cr.detail
        if cr.channelNumber <> invalid then detail = detail + " · CH " + cr.channelNumber.ToStr()
        state = "OFF"
        stateColor = "0xFFFFFF59"
        if collectionOn(cr) then
            state = "ON"
            stateColor = "0xFFE500FF"
        else if cr.warned = true then
            ' Upstream dims a row that is off and already on another channel.
            faded = true
        end if
    else if row.kind = "server" then
        ' Upstream's server rows: INCLUDED or OFF, and no switch on the
        ' only server that is on, which can't be turned off.
        s = m.servers[row.index]
        label = UCase(NxToStr(s.name))
        detail = "Shared with you"
        if NxTruthy(s.owned) then detail = "Your server"
        state = "OFF"
        stateColor = "0xFFFFFF59"
        if m.serversOn[row.index] then
            state = "INCLUDED"
            stateColor = "0xFFE500FF"
            if serversOnCount() <= 1 then
                detail = detail + " · only connected server"
                state = ""
            end if
        end if
    else if row.kind = "rescan" then
        ' Upstream's subtitle, a line each: what the app holds, when it last
        ' loaded and what the row does, then the last playback failure.
        label = "RESCAN LIBRARY"
        now& = CreateObject("roDateTime").AsSeconds()
        lines = NxRescanLines(NxLibraryHeld(), NxKindName(NxSignedInKind()), NxLastPlaybackVerdict(), now&)
        detail = lines[0]
        extra = [lines[1]]
        if lines.Count() > 2 then extra.Push(lines[2])
        state = ""
        stateColor = "0xFFE500FF"
        if m.top.rescanning then state = "UPDATING…"
    else if row.kind = "reportNowPlaying" or row.kind = "reportMarkWatched" then
        kind = NxSignedInKind()
        isOn = m.report.markWatched = true
        if row.kind = "reportNowPlaying" then
            label = "SHOW NOW PLAYING ON " + UCase(NxKindName(kind))
            isOn = m.report.nowPlaying = true
            if kind = "plex" then
                detail = "Show the current program on Plex."
                extra = ["Leave Mark Watched off to keep watch history unchanged."]
            else
                detail = "Show the current program. Prior watch state is restored when playback ends;"
                extra = ["a working connection is required."]
            end if
        else
            label = "MARK WATCHED ON " + UCase(NxKindName(kind))
            detail = "Count a program as watched when you tune in during its first 15% and watch at least 75%."
            extra = ["Independent of Now Playing. Off by default."]
        end if
        state = "OFF"
        stateColor = "0xFFFFFF59"
        if isOn then
            state = "ON"
            stateColor = "0xFFE500FF"
        end if
    else if row.kind = "retro" then
        label = "RETRO MODE"
        detail = "CRT scanlines, vignette, VHS glitch, 4:3 aspect ratio"
        state = "OFF"
        stateColor = "0xFFFFFF59"
        if NxRetroMode() then
            state = "ON"
            stateColor = "0xFFE500FF"
        end if
    else if row.kind = "guideText" then
        ' Roku only (I-060): the guide's text, built-in sizes.
        label = "GUIDE TEXT SIZE"
        detail = "Bigger program titles and channel names in the guide"
        state = "NORMAL"
        stateColor = "0xFFFFFF59"
        if NxGuideTextLarge() then
            state = "LARGE"
            stateColor = "0xFFE500FF"
        end if
    else if row.kind = "quality" then
        label = "STREAM QUALITY"
        detail = "Lower this when your connection is slow or shared"
        state = NxSqLevel(NxSqCurrent()).name
        stateColor = "0xFFE500FF"
    else if row.kind = "qualityChoice" then
        ' The Apple TV's sheet marks the level in use ACTIVE.
        indent = 40
        label = row.label
        detail = row.detail
        state = ""
        stateColor = "0xFFE500FF"
        if NxSqCurrent() = row.code then state = "ACTIVE"
    else if row.kind = "subtitles" then
        label = "SUBTITLES"
        detail = subtitleModeExplanation()
        state = subtitleModeLabel()
        stateColor = "0xFFFFFF59"
        if state <> "OFF" then stateColor = "0xFFE500FF"
    else if row.kind = "language" then
        ' Upstream's SUBTITLE LANGUAGE and AUDIO LANGUAGE rows.
        if row.key = "subsLanguage" then
            label = "SUBTITLE LANGUAGE"
            detail = "When the video has multiple subtitle tracks, prefer this language"
        else
            label = "AUDIO LANGUAGE"
            detail = "When the video has multiple audio tracks, prefer this language"
        end if
        state = NxLanguageLabel(NxSavedLanguage(row.key))
        stateColor = "0xFFE500FF"
    else if row.kind = "languageChoice" then
        indent = 40
        label = row.label
        detail = ""
        state = ""
        stateColor = "0xFFE500FF"
        if NxSavedLanguage(row.key) = row.code then state = "SELECTED"
    else
        kindName = NxKindName(NxSignedInKind())
        label = "SIGN OUT OF " + UCase(kindName)
        detail = "Forget this TV's " + kindName + " sign-in"
        if m.signOutArmed then
            label = "PRESS OK AGAIN TO SIGN OUT"
            detail = "Up, Down or BACK cancels"
        end if
        state = ""
        stateColor = "0xFFFFFFFF"
        accent = "0xFF6B6B"
    end if
    h = rowHeight(row) - 2
    if focused then page.AppendChild(newRect(indent, y, 1680 - indent, h, accent + "52"))
    if focused then
        page.AppendChild(newRect(indent, y, 8, h, accent + "FF"))
    else
        page.AppendChild(newRect(indent, y, 4, h, accent + "66"))
    end if
    nameColor = "0xFFFFFFBF"
    detailColor = "0xFFFFFF80"
    if faded then
        ' Seven tenths of each, as upstream's 0.7 opacity.
        nameColor = "0xFFFFFF86"
        detailColor = "0xFFFFFF5A"
    end if
    if focused then nameColor = "0xFFFFFFFF"
    ' A row with no detail line (a language in the list) centres its name.
    nameY = y + 10
    if detail = "" then nameY = y + 22
    page.AppendChild(newLabel(label, "DMMono-Medium", 24, nameColor, indent + 30, nameY))
    page.AppendChild(newLabel(detail, "VT323-Regular", 24, detailColor, indent + 30, y + 40))
    if row.kind = "rescan" or extra.Count() > 0 then
        ' Its other lines, each cut to the row's width.
        ly = y + 66
        for each text in extra
            lbl = newLabel(text, "VT323-Regular", 24, "0xFFFFFF80", indent + 30, ly)
            lbl.width = 1600
            page.AppendChild(lbl)
            ly = ly + 26
        end for
    end if
    if state <> "" then
        stateLabel = newLabel(state, "DMMono-Medium", 24, stateColor, 1260, y + 22)
        stateLabel.width = 380
        stateLabel.horizAlign = "right"
        page.AppendChild(stateLabel)
    end if
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if m.signOutArmed and key <> "OK" then
        m.signOutArmed = false
        render()
    end if
    if key = "down" or key = "up" then
        d = 1
        if key = "up" then d = -1
        m.focus = nextFocusable(m.focus, d)
        ' Up from the first row shows the headings above it again.
        if key = "up" and nextFocusable(m.focus, -1) = m.focus then m.scroll = 0
        render()
        return true
    end if
    if key = "OK" then
        row = m.rows[m.focus]
        if row.kind = "bundle" then
            id = m.top.bundles[row.index].id
            kept = []
            found = false
            for each x in m.enabled
                if x = id then found = true else kept.Push(x)
            end for
            ' The last package on stays on, as upstream's toggleBundle keeps one.
            if found and kept.Count() = 0 then return true
            if not found then kept.Push(id)
            m.enabled = kept
            ' Saved now and built behind Settings: only the switched-on
            ' package's channels are built, and the guide updates when done.
            reg = NxRegSection("guide")
            reg.Write("bundles", FormatJson(m.enabled))
            reg.Flush()
            if not found then
                m.building[id] = true
                m.dotTimer.control = "start"
            else
                m.building.Delete(id)
            end if
            if found then print "settings: package "; id; " switched off" else print "settings: package "; id; " switched on"
            m.top.bundleChange = true
            buildRows()
            if m.focus > rowCount() - 1 then m.focus = rowCount() - 1
            if not focusable(m.rows[m.focus]) then m.focus = nextFocusable(m.focus, -1)
            render()
        else if row.kind = "franchiseAll" then
            ' setAllFranchises: one explicit choice for every row.
            turnOn = anyFranchiseOff()
            for each f in m.top.franchises
                NxFranchiseRecordChoice(m.choices, f.id, turnOn)
            end for
            m.franchisesChanged = true
            render()
        else if row.kind = "franchise" then
            NxFranchiseRecordChoice(m.choices, row.franchise.id, not franchiseOn(row.franchise))
            m.franchisesChanged = true
            render()
        else if row.kind = "collection" then
            ' toggleCollection: switch one on and it airs from CH 450 or 500.
            id = row.collection.id
            if m.collectionKeys.DoesExist(id) then m.collectionKeys.Delete(id) else m.collectionKeys[id] = true
            m.collectionsChanged = true
            render()
        else if row.kind = "collectionsToggle" then
            m.collectionsOpen[row.category] = not (m.collectionsOpen[row.category] = true)
            buildRows()
            render()
        else if row.kind = "server" then
            ' The last server on stays on, as upstream's picker keeps one.
            if not m.serversOn[row.index] or serversOnCount() > 1 then
                m.serversOn[row.index] = not m.serversOn[row.index]
                m.serversChanged = true
                render()
            end if
        else if row.kind = "rescan" then
            if not m.top.rescanning then m.top.rescan = true
        else if row.kind = "reportNowPlaying" then
            m.report.nowPlaying = not (m.report.nowPlaying = true)
            NxSaveReportPrefs(m.report)
            print "settings: show now playing "; m.report.nowPlaying
            render()
        else if row.kind = "reportMarkWatched" then
            m.report.markWatched = not (m.report.markWatched = true)
            NxSaveReportPrefs(m.report)
            print "settings: mark watched "; m.report.markWatched
            render()
        else if row.kind = "retro" then
            NxSaveRetroMode(not NxRetroMode())
            render()
        else if row.kind = "guideText" then
            NxSaveGuideTextLarge(not NxGuideTextLarge())
            print "settings: guide text size "; NxGuideTextLarge()
            render()
        else if row.kind = "subtitles" then
            cycleSubtitleMode()
            ' SUBTITLE LANGUAGE comes and goes with it.
            m.languageOpen = ""
            buildRows()
            m.focus = rowIndex("subtitles")
            render()
        else if row.kind = "language" then
            ' Opens its list on the saved choice; OK again folds it.
            if m.languageOpen = row.key then
                foldLanguage()
            else
                m.languageOpen = row.key
                buildRows()
                m.focus = rowIndex("languageChoice", row.key, NxSavedLanguage(row.key))
                if m.focus < 0 then m.focus = rowIndex("language", row.key)
                render()
            end if
        else if row.kind = "languageChoice" then
            NxSaveLanguage(row.key, row.code)
            print "settings: "; row.key; " set to "; row.code
            foldLanguage()
        else if row.kind = "quality" then
            ' As a language row: opens on the saved level, OK again folds it.
            if m.languageOpen = "streamQuality" then
                foldLanguage()
            else
                m.languageOpen = "streamQuality"
                buildRows()
                m.focus = rowIndex("qualityChoice", "streamQuality", NxSqCurrent())
                render()
            end if
        else if row.kind = "qualityChoice" then
            NxSqSave(row.code)
            print "settings: stream quality set to "; row.code
            foldLanguage()
        else if m.signOutArmed then
            m.top.result = "signOut"
        else
            m.signOutArmed = true
            render()
        end if
        return true
    end if
    if (key = "back" or key = "left") and m.languageOpen <> "" then
        foldLanguage()
        return true
    end if
    if key = "back" or key = "left" then
        if m.serversChanged then m.serversChanged = FormatJson(m.serversOn) <> m.serversOnAtOpen
        if m.serversChanged then
            ' Every server's switch is saved, so a later default can't move it.
            choices = {}
            for i = 0 to m.servers.Count() - 1
                choices[NxToStr(m.servers[i].machineIdentifier)] = m.serversOn[i]
            end for
            plex = NxPlexRegistry()
            plex.Write("serverChoices", FormatJson(choices))
            plex.Flush()
        end if
        if m.franchisesChanged or m.collectionsChanged then
            reg = NxRegSection("guide")
            if m.franchisesChanged then
                lists = NxFranchiseChoiceLists(m.choices)
                reg.Write("franchisesOn", FormatJson(lists.enabled))
                reg.Write("franchisesOff", FormatJson(lists.disabled))
            end if
            reg.Flush()
            if m.collectionsChanged then NxSaveCollectionKeys(m.collectionKeys)
        end if
        if m.needRebuild or m.serversChanged then
            print "settings: rebuilding the guide on the way out: packages "; m.needRebuild; ", franchises "; m.franchisesChanged; ", collections "; m.collectionsChanged; ", servers "; m.serversChanged
            m.top.result = "rebuild"
        else if m.franchisesChanged or m.collectionsChanged then
            ' Built behind the guide from the library in memory, as a package
            ' switch is: the guide and the channel on stay up.
            print "settings: building in place on the way out: franchises "; m.franchisesChanged; ", collections "; m.collectionsChanged
            m.top.bundleChange = true
            m.top.result = "close"
        else
            m.top.result = "close"
        end if
        return true
    end if
    return true
end function
