' Copyright (c) 2026 nostalgex-roku contributors, MIT License.

sub init()
    ' Settings' cyan, the Apple TV's BrandCyan, for the rail and the rows.
    m.accent = "0x00D4FF"
    ' The rail down the left (SettingsRailView: 470 wide, rows 76 high), and
    ' the pane beside it: the hero pinned at the top, the rows under a divider.
    m.railW = 470
    m.paneX = 550
    m.rowW = 1290
    ' The rows' window in the pane, under the hero and its divider.
    m.listTop = 224
    m.listH = 776
    ' Where focus is: on the "rail", or in the tab's "rows".
    m.where = "rail"
    m.tabs = NxSettingsTabs()
    m.tabIndex = 0
    ' The CHANNELS & BUNDLES page on show (ChannelsPage): "packages",
    ' "franchises", "collections" or "missing" (one level under CHANNEL
    ' PACKAGES), or "" for the tab's list. Back to the list whenever another
    ' tab is picked.
    m.channelsPage = ""
    ' channels.json's channels by id, read the first time Settings needs them
    ' (WHY ARE SOME CHANNELS MISSING?), and the page's channel count.
    m.defs = invalid
    m.missingCount = 0
    ' The page the rows being added belong to (buildRows).
    m.addPage = ""
    m.focus = -1
    m.scroll = 0
    ' The site, as upstream's user agents give it; SUPPORT NOSTALGEX's QR code.
    m.supportUrl = "https://www.nostalgex.app"
    m.fonts = {}
    m.advance = {}
    m.onAir = {}
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
    keep = ""
    if m.focus >= 0 then keep = rowKey(m.rows[m.focus])
    buildRows()
    m.focus = NxSettingsFirstFocusable(m.rows)
    if keep <> "" then
        for i = 0 to rowCount() - 1
            if rowKey(m.rows[i]) = keep then
                m.focus = i
                exit for
            end if
        end for
    end if
    render()
end sub

' What a row is, to put focus back on it after a rebuild: its kind and the one
' thing that tells two of that kind apart. A collection row used to carry
' neither, so focus went to the first collection row of the list.
function rowKey(row as Object) as String
    key = row.kind
    if row.franchise <> invalid then key = key + "|" + NxToStr(row.franchise.id)
    if row.collection <> invalid then key = key + "|" + NxToStr(row.collection.id)
    if row.index <> invalid then key = key + "|" + NxToStr(row.index)
    if row.category <> invalid then key = key + "|" + NxToStr(row.category)
    if row.key <> invalid then key = key + "|" + NxToStr(row.key)
    if row.code <> invalid then key = key + "|" + NxToStr(row.code)
    if row.page <> invalid then key = key + "|" + NxToStr(row.page)
    return key
end function

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

' Settings opens on the rail at SUPPORT NOSTALGEX, as the Apple TV's does
' (SettingsContainerView). The saved choices are read once here.
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
    m.tabIndex = 0
    m.channelsPage = ""
    m.where = "rail"
    buildRows()
    m.focus = NxSettingsFirstFocusable(m.rows)
    m.scroll = 0
    m.top.SetFocus(true)
    render()
end sub

' Every row of every tab, then the selected tab's (source/guide/SettingsRail.brs
' says which tab a row kind sits in; a text row takes its section's). The
' tabs follow the Apple TV's Views/Settings/ (N-028):
'   SUPPORT NOSTALGEX: the QR card, never focused.
'   PLAYBACK & PICTURE (SettingsPlaybackView): RETRO MODE, GUIDE TEXT SIZE,
'   STREAM QUALITY, SUBTITLES, the languages, then WATCH HISTORY with the two
'   reporting switches.
'   CHANNELS & BUNDLES (SettingsChannelsView): a list of three link rows, each
'   with its value on the right, then WATERSHED. Each link opens a page in the
'   pane: CHANNEL PACKAGES (every package but FRANCHISES), FRANCHISES (its
'   switch, then one A to Z list of the classics, the found franchises and the
'   server's franchise collections) and MY COLLECTIONS (the viewer's own,
'   folded closed behind a SHOW/HIDE row, as upstream's accordion). A page's
'   rows are its section's from when the tab was one scroll.
'   SERVERS & ACCOUNTS (SettingsServersView): the servers, RESCAN LIBRARY,
'   SIGN OUT.
'   ABOUT (SettingsAboutView): VERSION, then LINKS with GITHUB.
' Kinds:
'   header, subheader, info: text only, never focused
'   support: the QR card, never focused
'   server, rescan, signOut, retro, guideText (GUIDE TEXT SIZE), quality
'   (STREAM QUALITY), qualityChoice, subtitles, language (SUBTITLE or AUDIO
'   LANGUAGE), languageChoice, reportNowPlaying, reportMarkWatched, bundle,
'   franchiseAll, franchise, franchiseCollection, collectionsToggle,
'   collection, version, github: rows
'   channelsLink: a CHANNELS & BUNDLES link row; `page` is the page it opens
' Every row has `inTab`, and `inPage` for the CHANNELS & BUNDLES page it is
' on ("" for the tab's list, and for every other tab's rows).
' The franchise rows are the last guide build's, so they show once the package
' was on for a build. MY COLLECTIONS holds the viewer's own collections only
' (OTHER COLLECTIONS), shown only when it has a row.
sub buildRows()
    m.all = []
    ' Which channels are on air, for the count on a package short of content.
    m.onAir = NxOnAirSet(m.top.onAirIds)

    ' Text and a QR code, never focused: scanning it is the action (#147).
    add({ kind: "support" })

    add({ kind: "retro" })
    add({ kind: "guideText" })
    pushQuality()
    add({ kind: "subtitles" })
    ' SUBTITLE LANGUAGE only while subtitles can show, as upstream's.
    if m.subs.always or m.subs.foreign then pushLanguage("subsLanguage")
    pushLanguage("audioLanguage")
    ' Upstream's two reporting switches, both off by default (issue #72,
    ' source/guide/PlaybackReport.brs), under WATCH HISTORY as on the Apple TV.
    add({ kind: "header", title: "WATCH HISTORY", subtitle: "What " + NxKindName(NxSignedInKind()) + " is told about what you watch" }, "playback")
    add({ kind: "reportNowPlaying" })
    add({ kind: "reportMarkWatched" })

    ' The list: a link row for each page (ChannelsHomePage), then WATERSHED.
    for each p in NxChannelsPages()
        add({ kind: "channelsLink", page: p.id, title: p.title })
    end for

    m.addPage = "packages"
    add({ kind: "header", title: "CHANNEL PACKAGES", subtitle: "Toggle packages to customize your lineup" }, "channels")
    franchisesAt = -1
    for i = 0 to m.top.bundles.Count() - 1
        if m.top.bundles[i].id = NxFranchisesBundleID() then
            franchisesAt = i
        else
            pushPackage(i)
        end if
    end for
    pushMissing()
    m.addPage = "franchises"
    if franchisesAt >= 0 then pushFranchises(franchisesAt)
    m.addPage = "collections"
    add({ kind: "header", title: "MY COLLECTIONS", subtitle: "Turn the server collections you want into channels" }, "channels")
    note = NxCollectionsNote(m.top.collections)
    if note <> "" then add({ kind: "info", text: note }, "channels")
    ' The franchise collections are on the FRANCHISES page; only OTHER
    ' COLLECTIONS is left here.
    category = "custom"
    rows = collectionRows(category)
    if rows.Count() > 0 then
        add({ kind: "collectionsToggle", category: category })
        full = collectionsFullNote(category)
        if full <> "" then add({ kind: "info", text: full }, "channels")
        if m.collectionsOpen[category] = true then
            for each row in rows
                add({ kind: "collection", collection: row })
            end for
        end if
    end if

    m.addPage = ""
    ' WATERSHED (#190) ends the CHANNELS & BUNDLES list, after the three links,
    ' as on the Apple TV.
    add({ kind: "watershed" })

    add({ kind: "subheader", text: "SERVERS" }, "servers")
    for i = 0 to m.servers.Count() - 1
        add({ kind: "server", index: i })
    end for
    ' Upstream's RESCAN LIBRARY, after the servers.
    add({ kind: "rescan" })
    add({ kind: "signOut" })

    add({ kind: "version" })
    add({ kind: "header", title: "LINKS", subtitle: "" }, "about")
    add({ kind: "github" })

    pickTab()
end sub

' The current tab's rows from every tab's (m.all), as buildRows left them: on
' CHANNELS & BUNDLES, the page on show's.
sub pickTab()
    m.rows = NxSettingsRowsInTab(m.all, m.tabs[m.tabIndex].id, shownPage())
end sub

' The CHANNELS & BUNDLES page on show, or "" on its list and on any other tab.
function shownPage() as String
    if m.tabs[m.tabIndex].id = "channels" then return m.channelsPage
    return ""
end function

' Opens a CHANNELS & BUNDLES page from its link row, or steps back to the list
' (page "") onto the row that opened `from`, as showChannelsPage. A page opens
' scrolled to its top, on its first row; one with nothing to focus (MY
' COLLECTIONS before any collection is read) leaves focus nowhere, and Back or
' Left still leaves it.
sub showPage(page as String, from = "" as String)
    m.channelsPage = page
    pickTab()
    m.focus = NxSettingsFirstFocusable(m.rows)
    if from <> "" then
        at = NxSettingsLinkRowOf(m.rows, from)
        if at >= 0 then m.focus = at
    end if
    m.scroll = 0
    render()
end sub

' WHY ARE SOME CHANNELS MISSING? (ChannelsPackagesPage's link row, after the
' packages) and the MISSING CHANNELS page it opens (ChannelsMissingPage): the
' packages that are on and built, and their channels not on air, each as a
' card under its package's name. The link row shows only while some channel
' is missing; the page says so when none is. A card's lines are wrapped here,
' so its height is known before it is drawn.
sub pushMissing()
    if m.defs = invalid then m.defs = NxChannelDefsById(ParseJson(ReadAsciiFile("pkg:/data/channels.json")))
    groups = NxMissingGroups(m.top.bundles, m.enabled, m.top.builtBundles, m.building, m.onAir, m.defs)
    m.missingCount = NxMissingCount(groups)
    if m.missingCount > 0 then add({ kind: "channelsLink", page: "missing", title: "WHY ARE SOME CHANNELS MISSING?" })
    m.addPage = "missing"
    add({ kind: "header", title: "MISSING CHANNELS", subtitle: "A channel goes on air once your library has enough titles that fit it" }, "channels")
    if groups.Count() = 0 then
        add({ kind: "missingNone" })
        return
    end if
    cols = Int((m.rowW - 40) / advanceOf("DMMono-Regular", 20))
    for each g in groups
        add({ kind: "subheader", text: NxToStr(g.bundle.name) }, "channels")
        for each def in g.channels
            ' The amber line at its longest, so the height holds once counted.
            needs = NxWrapText(NxMissingNeedsLine(def.minItems, 99999), cols).Count()
            bullets = []
            for each line in NxPlainRequirements(def.rules)
                bullets.Append(NxWrapText("• " + line, cols))
            end for
            add({ kind: "missingCard", key: NxToStr(g.bundle.id) + ":" + NxToStr(def.id), def: def, needsLines: needs, bullets: bullets, cols: cols })
        end for
    end for
end sub

' The counts arrived, or changed: only the MISSING CHANNELS page shows them.
sub onMatchCounts()
    if m.rows <> invalid and shownPage() = "missing" then render()
end sub

' One row into the full list, in its tab: the rule's for a row with something
' to press, the section's (`tabId`) for a text row.
sub add(row as Object, tabId = "" as String)
    if tabId = "" then tabId = NxSettingsTabOf(row.kind)
    row.inTab = tabId
    row.inPage = m.addPage
    m.all.Push(row)
end sub

' A package's row, with how many of its channels are on air counted once here,
' not on every draw. `built` is whether the guide held the package when Settings
' opened: one switched on during the visit has nothing on air to count yet.
sub pushPackage(i as Integer)
    b = m.top.bundles[i]
    row = { kind: "bundle", index: i, built: NxHasValue(m.top.builtBundles, b.id), avail: NxBundleAvailability(b.channelIDs, m.onAir) }
    add(row)
end sub

' The FRANCHISES section (ChannelsFranchisesPage): the package's switch, then
' while it is on the over-capacity note and ADD ALL / REMOVE ALL, then the one
' A to Z list. The franchise collections stay listed while the switch is off,
' as on the Apple TV, where the switch gates their channels (CH 310-399) and
' each one keeps its own choice for when it is on again.
sub pushFranchises(at as Integer)
    id = m.top.bundles[at].id
    on = NxHasValue(m.enabled, id)
    add({ kind: "header", title: "FRANCHISES", subtitle: "" }, "channels")
    add({ kind: "bundle", index: at })
    entries = NxFranchisePageEntries(m.top.franchises, collectionRows("franchises"), on)
    if entries.Count() = 0 then
        if on and not m.building.DoesExist(id) then add({ kind: "info", text: "Franchises you own show up here once your library has been enriched." }, "channels")
        return
    end if
    if on then
        full = franchisesFullNote()
        if full <> "" then add({ kind: "info", text: full }, "channels")
        add({ kind: "franchiseAll" })
    end if
    for each e in entries
        if e.kind = "franchise" then
            add({ kind: "franchise", franchise: e.franchise })
        else
            add({ kind: "franchiseCollection", collection: e.collection })
        end if
    end for
end sub

' A language row, and the presets under it while it is open, as upstream's
' picker sheet lists them.
sub pushLanguage(key as String)
    add({ kind: "language", key: key })
    if m.languageOpen <> key then return
    for each p in NxLanguagePresets()
        add({ kind: "languageChoice", key: key, code: p.code, label: p.label })
    end for
end sub

' STREAM QUALITY, and while it is open the Apple TV's picker sheet in place:
' its line, then the five levels, each with its detail.
sub pushQuality()
    add({ kind: "quality" })
    if m.languageOpen <> "streamQuality" then return
    add({ kind: "info", text: "Lower quality uses less bandwidth. Auto adjusts as your connection changes." }, "playback")
    for each l in NxSqLevels()
        add({ kind: "qualityChoice", key: "streamQuality", code: l.id, label: l.name, detail: l.detail })
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
    return NxSettingsRowFocusable(row.kind)
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
    if row.kind = "support" then return 184
    ' ChannelRequirementCard: 14 px above and below, the name, the amber
    ' line(s) and the rules, 26 px a line, and 6 px between cards.
    if row.kind = "missingCard" then return 14 + 34 + 26 * (row.needsLines + row.bullets.Count()) + 14 + 6
    if row.kind = "missingNone" then return 60
    ' Two lines under its detail, and a third when the library line (#207)
    ' and a playback failure are both there.
    if row.kind = "rescan" then
        n = NxRescanLines(NxLibraryHeld(), "", NxLastPlaybackVerdict(), 0).Count() - 1
        if n < 2 then n = 2
        return 74 + 26 * n
    end if
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

' Under the OTHER COLLECTIONS accordion when its block is full, as upstream's:
' "Up to 100 of these fit in the guide. 3 more are switched on but not shown."
' Empty otherwise. (The franchise collections' block is the FRANCHISES page's,
' franchisesFullNote.)
function collectionsFullNote(category as String) as String
    c = m.top.collections
    if c = invalid then return ""
    ' The block sizes come with the build that filled them.
    over = NxNumberOr0(c.overCapCustom)
    capacity = NxNumberOr0(c.capacityCustom)
    ' A build before the split counted only CH 699.
    if c.overCapCustom = invalid then over = NxNumberOr0(c.overCap)
    if over <= 0 or capacity <= 0 then return ""
    return "Up to " + capacity.ToStr() + " of these fit in the guide. " + over.ToStr() + " more are switched on but not shown."
end function

' Under the franchise switch when CH 310-399 is full, as upstream's: the found
' franchises and the franchise collections past it share the one note.
function franchisesFullNote() as String
    c = m.top.collections
    overCollections = 0
    if c <> invalid then overCollections = c.overCapFranchises
    return NxFranchiseBlockNote(m.top.franchiseOverCap, overCollections, m.top.franchiseCapacity)
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

' The counts behind the link rows' values (NxChannelsLinkValue), from this
' visit's switches, as the Apple TV's list reads its live state.
function linkCounts() as Object
    n = { packagesOn: 0, franchisesOn: false, franchiseRowsOn: 0, franchiseCollectionsOn: 0, collectionsOn: 0 }
    for each b in m.top.bundles
        if NxHasValue(m.enabled, b.id) then
            if b.id = NxFranchisesBundleID() then n.franchisesOn = true else n.packagesOn = n.packagesOn + 1
        end if
    end for
    for each f in NxList(m.top.franchises)
        if franchiseOn(f) then n.franchiseRowsOn = n.franchiseRowsOn + 1
    end for
    for each row in collectionRows("franchises")
        if collectionOn(row) then n.franchiseCollectionsOn = n.franchiseCollectionsOn + 1
    end for
    for each row in collectionRows("custom")
        if collectionOn(row) then n.collectionsOn = n.collectionsOn + 1
    end for
    return n
end function

' ADD ALL / REMOVE ALL covers the whole FRANCHISES list: every franchise row
' and every franchise collection (upstream's setAllFranchises and setAll).
function anyFranchiseOff() as Boolean
    for each f in m.top.franchises
        if not franchiseOn(f) then return true
    end for
    for each row in collectionRows("franchises")
        if not collectionOn(row) then return true
    end for
    return false
end function

' Upstream's SUBTITLES row (SettingsPlaybackView): one setting for both flags.
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
    renderRail()
    renderPane()
end sub

' The rail (SettingsRailView): SETTINGS, the pinned tab, a divider, the four
' others. A tab's bar is 4 wide, 6 on the selected tab and 8 on the focused one;
' the focused tab has a 22% tint and a 3 px border, and the selected one keeps a
' 6% white fill while focus is in the rows. No icons, glow or scanlines here.
sub renderRail()
    rail = m.top.FindNode("rail")
    rail.RemoveChildrenIndex(rail.GetChildCount(), 0)
    rail.AppendChild(newRect(0, 0, m.railW, 1080, "0x080814F2"))
    rail.AppendChild(newRect(m.railW, 0, 1, 1080, "0xFFFFFF1A"))
    rail.AppendChild(newLabel("SETTINGS", "VT323-Regular", 44, "0xFFFFFF99", 40, 70))
    y = 138
    for i = 0 to m.tabs.Count() - 1
        t = m.tabs[i]
        drawTab(rail, i, t, y)
        y = y + 80
        if t.pinned then
            rail.AppendChild(newRect(48, y + 14, m.railW - 96, 1, "0xFFFFFF1A"))
            y = y + 33
        end if
    end for
end sub

sub drawTab(rail as Object, i as Integer, t as Object, y as Float)
    selected = (i = m.tabIndex)
    focused = selected and m.where = "rail"
    w = m.railW - 40
    if focused then
        rail.AppendChild(newRect(20, y, w, 76, m.accent + "38"))
    else if selected then
        rail.AppendChild(newRect(20, y, w, 76, "0xFFFFFF0F"))
    end if
    barW = 4
    if selected then barW = 6
    if focused then barW = 8
    barColor = m.accent + "4D"
    if selected then barColor = m.accent + "FF"
    rail.AppendChild(newRect(20, y, barW, 76, barColor))
    if focused then
        rail.AppendChild(newRect(20, y, w, 3, m.accent + "FF"))
        rail.AppendChild(newRect(20, y + 73, w, 3, m.accent + "FF"))
        rail.AppendChild(newRect(20, y, 3, 76, m.accent + "FF"))
        rail.AppendChild(newRect(20 + w - 3, y, 3, 76, m.accent + "FF"))
    end if
    tc = "0xFFFFFFB3"
    if selected then tc = "0xFFFFFFFF"
    rail.AppendChild(newLabel(t.title, "DMMono-Medium", 24, tc, 20 + barW + 18, y + 22))
end sub

' The pane (SettingsContainerView's detailPane): the tab's 96 px icon, title
' and line pinned at the top, a divider, then only the rows scroll under it.
sub renderPane()
    page = m.top.FindNode("pane")
    page.RemoveChildrenIndex(page.GetChildCount(), 0)
    t = m.tabs[m.tabIndex]
    icon = CreateObject("roSGNode", "Poster")
    icon.uri = "pkg:/images/look/settings_hero_" + t.hero + ".png"
    icon.translation = [0, 60]
    icon.width = 96
    icon.height = 96
    page.AppendChild(icon)
    page.AppendChild(newLabel(t.title, "DMMono-Medium", 34, "0xFFFFFFFF", 124, 72))
    page.AppendChild(newLabel(t.line, "DMMono-Regular", 20, "0xFFFFFFB3", 124, 119))
    page.AppendChild(newRect(0, 176, m.rowW, 1, "0xFFFFFF0F"))

    ' Where each row sits in the whole list, then a scroll that keeps the
    ' focused row in view, with the headings just above it when they fit.
    tops = []
    y = 0
    for each row in m.rows
        tops.Push(y)
        y = y + rowHeight(row)
    end for
    if m.focus >= 0 then
        top = tops[m.focus]
        bottom = top + rowHeight(m.rows[m.focus])
        k = m.focus - 1
        while k >= 0 and not focusable(m.rows[k]) and bottom - tops[k] <= m.listH
            top = tops[k]
            k = k - 1
        end while
        ' At the last row focus can reach, the lines after it come into view
        ' too, as the end of upstream's scroll does.
        if nextFocusable(m.focus, 1) = m.focus then
            last = rowCount() - 1
            if tops[last] + rowHeight(m.rows[last]) - top <= m.listH then bottom = tops[last] + rowHeight(m.rows[last])
        end if
        if top < m.scroll then m.scroll = top
        if bottom > m.scroll + m.listH then m.scroll = bottom - m.listH
    end if

    for i = 0 to rowCount() - 1
        row = m.rows[i]
        rt = tops[i]
        if rt >= m.scroll and rt + rowHeight(row) <= m.scroll + m.listH then
            y = m.listTop + rt - m.scroll
            if row.kind = "header" then
                ' A thin divider between sections, as settingsDivider.
                if i > 0 then page.AppendChild(newRect(0, y + 8, m.rowW, 1, "0xFFFFFF0F"))
                page.AppendChild(newLabel(row.title, "DMMono-Medium", 28, "0xFFFFFFCC", 0, y + 28))
                if row.subtitle <> "" then page.AppendChild(newLabel(row.subtitle, "DMMono-Regular", 20, "0xFFFFFFB3", 0, y + 68))
            else if row.kind = "subheader" or row.kind = "info" then
                page.AppendChild(newLabel(row.text, "DMMono-Regular", 20, "0xFFFFFFB3", 0, y + 8))
            else if row.kind = "support" then
                ' A QR code to the site, drawn as the sign-in's (NxQrDraw):
                ' the one thing a remote can't open, a phone camera can.
                qr = CreateObject("roSGNode", "Group")
                qr.translation = [30, y + 8]
                NxQrDraw(qr, NxQrMatrix(m.supportUrl), 160)
                page.AppendChild(qr)
                page.AppendChild(newLabel("NOSTALGEX.APP", "DMMono-Medium", 24, "0xFFFFFFBF", 220, y + 58))
                page.AppendChild(newLabel("Scan with a phone camera to open it", "VT323-Regular", 24, "0xFFFFFF80", 220, y + 88))
                page.AppendChild(newRect(0, y, 4, 176, m.accent + "66"))
            else if row.kind = "missingCard" then
                drawMissingCard(page, i, row, y)
            else if row.kind = "missingNone" then
                ' Read-only but focusable, as the Apple TV's, so focus has
                ' somewhere to be on the page.
                if i = m.focus and m.where = "rows" then page.AppendChild(newRect(0, y, m.rowW, 54, "0xFFFFFF12"))
                page.AppendChild(newLabel("Every channel in your packages is on air.", "DMMono-Regular", 20, "0xFFFFFFB3", 20, y + 14))
            else
                drawRow(page, i, row, y)
            end if
        end if
    end for
end sub

function serversOnCount() as Integer
    n = 0
    for each x in m.serversOn
        if x then n = n + 1
    end for
    return n
end function

sub drawRow(page as Object, i as Integer, row as Object, y as Float)
    focused = (i = m.focus) and m.where = "rows"
    accent = m.accent
    extra = []
    indent = 0
    faded = false
    ' The amber count on a package short of content, or invalid.
    badge = invalid
    ' The state's width: 380, or 760 for a value that is a line of its own
    ' (ABOUT's version and address).
    stateW = 380
    if row.kind = "channelsLink" then
        ' SettingsLinkRow: the page's title, its value on the right in cyan
        ' when focused, and a chevron after it.
        label = row.title
        detail = ""
        if row.page = "missing" then
            state = NxMissingLinkValue(m.missingCount) + "  >"
        else
            state = NxChannelsLinkValue(row.page, linkCounts()) + "  >"
        end if
        stateColor = "0xFFFFFF99"
        if focused then stateColor = m.accent + "FF"
    else if row.kind = "bundle" then
        b = m.top.bundles[row.index]
        on = NxHasValue(m.enabled, b.id)
        label = b.name
        detail = b.channelIDs.Count().ToStr() + " CHANNELS"
        if b.id = NxFranchisesBundleID() then
            ' The Apple TV's switch line: the package's seven classics are not
            ' what it brings, the series in the library are.
            detail = "The classics and the series in your library"
        else if on and not m.building.DoesExist(b.id) then
            ' How many of its channels are on air, and the count of those that
            ' are not, as the Apple TV's "9/10 CH" and amber circle. Only for a
            ' package the guide held when Settings opened.
            badge = NxPackageBadge(on, false, row.built, row.avail)
            if row.built and row.avail.available > 0 then detail = row.avail.available.ToStr() + "/" + row.avail.total.ToStr() + " CHANNELS"
        end if
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
            stateColor = m.accent + "FF"
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
        stateColor = m.accent + "FF"
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
            stateColor = m.accent + "FF"
        end if
    else if row.kind = "collectionsToggle" then
        label = NxCollectionCategoryName(row.category)
        detail = NxCollectionCategoryDescription(row.category) + " · " + collectionsOnAir(row.category)
        if m.collectionsChanged then detail = "Changes air when you go back to the guide · " + collectionsOnAir(row.category)
        state = "SHOW"
        if m.collectionsOpen[row.category] = true then state = "HIDE"
        stateColor = m.accent + "FF"
    else if row.kind = "collection" or row.kind = "franchiseCollection" then
        indent = 40
        cr = row.collection
        label = cr.title
        detail = cr.detail
        ' Among the franchises, a collection says so, as the Apple TV's
        ' COLLECTION tag does.
        if row.kind = "franchiseCollection" then detail = detail + " · COLLECTION"
        if cr.channelNumber <> invalid then detail = detail + " · CH " + cr.channelNumber.ToStr()
        state = "OFF"
        stateColor = "0xFFFFFF59"
        if collectionOn(cr) then
            state = "ON"
            stateColor = m.accent + "FF"
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
            stateColor = m.accent + "FF"
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
        extra = []
        for i = 1 to lines.Count() - 1
            extra.Push(lines[i])
        end for
        state = ""
        stateColor = m.accent + "FF"
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
            stateColor = m.accent + "FF"
        end if
    else if row.kind = "retro" then
        label = "RETRO MODE"
        detail = "CRT scanlines, vignette, VHS glitch, 4:3 aspect ratio"
        state = "OFF"
        stateColor = "0xFFFFFF59"
        if NxRetroMode() then
            state = "ON"
            stateColor = m.accent + "FF"
        end if
    else if row.kind = "watershed" then
        label = "WATERSHED"
        detail = "18 and R-rated titles wait until 9 PM"
        state = "OFF"
        stateColor = "0xFFFFFF59"
        if NxWatershedOn() then
            state = "ON"
            stateColor = m.accent + "FF"
        end if
    else if row.kind = "guideText" then
        ' Roku only (I-060): the guide's text, built-in sizes.
        label = "GUIDE TEXT SIZE"
        detail = "Bigger program titles and channel names in the guide"
        state = "NORMAL"
        stateColor = "0xFFFFFF59"
        if NxGuideTextLarge() then
            state = "LARGE"
            stateColor = m.accent + "FF"
        end if
    else if row.kind = "quality" then
        label = "STREAM QUALITY"
        detail = "Lower this when your connection is slow or shared"
        state = NxSqLevel(NxSqCurrent()).name
        stateColor = m.accent + "FF"
    else if row.kind = "qualityChoice" then
        ' The Apple TV's sheet marks the level in use ACTIVE.
        indent = 40
        label = row.label
        detail = row.detail
        state = ""
        stateColor = m.accent + "FF"
        if NxSqCurrent() = row.code then state = "ACTIVE"
    else if row.kind = "subtitles" then
        label = "SUBTITLES"
        detail = subtitleModeExplanation()
        state = subtitleModeLabel()
        stateColor = "0xFFFFFF59"
        if state <> "OFF" then stateColor = m.accent + "FF"
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
        stateColor = m.accent + "FF"
    else if row.kind = "languageChoice" then
        indent = 40
        label = row.label
        detail = ""
        state = ""
        stateColor = m.accent + "FF"
        if NxSavedLanguage(row.key) = row.code then state = "SELECTED"
    else if row.kind = "version" then
        ' The Apple TV's VERSION row: focusable, select does nothing.
        label = "VERSION"
        detail = "The build number tells two submissions of one version apart"
        state = NxVersionValue()
        stateColor = "0xFFFFFFFF"
        stateW = 760
    else if row.kind = "github" then
        ' tvOS has no browser and nor has a Roku: an address to read, not a link.
        label = "GITHUB"
        detail = "Source code and issues. Open it on a phone or computer."
        state = "github.com/chadMueller/Nostalgex"
        stateColor = "0xFFFFFFFF"
        stateW = 760
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
    if focused then page.AppendChild(newRect(indent, y, m.rowW - indent, h, accent + "52"))
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
            lbl.width = m.rowW - 80
            page.AppendChild(lbl)
            ly = ly + 26
        end for
    end if
    stateWidth = 0
    if state <> "" then
        stateLabel = newLabel(state, "DMMono-Medium", 24, stateColor, m.rowW - 40 - stateW, y + 22)
        stateLabel.width = stateW
        stateLabel.horizAlign = "right"
        page.AppendChild(stateLabel)
        stateWidth = Len(state) * advanceOf("DMMono-Medium", 24)
    end if
    ' The amber count sits left of the state, as the Apple TV's sits left of
    ' the switch.
    if badge <> invalid then drawBadge(page, badge, y, m.rowW - 60 - stateWidth)
end sub

' Upstream's AlertCountBadge: an amber capsule, at least a 34 px circle, with
' the count in dark type (99+ past 99), its right edge at `edge`.
sub drawBadge(page as Object, count as Integer, y as Float, edge as Float)
    text = NxBadgeText(count)
    w = NxBadgeWidth(count, Len(text) * advanceOf("DMMono-Medium", 20))
    x = edge - w
    capsule = CreateObject("roSGNode", "Poster")
    capsule.uri = "pkg:/images/look/capsule.9.png"
    capsule.translation = [x, y + 20]
    capsule.width = w
    capsule.height = 34
    capsule.blendColor = "0xFFB020FF"
    page.AppendChild(capsule)
    number = newLabel(text, "DMMono-Medium", 20, "0x0A0A1AFF", x, y + 20)
    number.width = w
    number.height = 34
    number.horizAlign = "center"
    number.vertAlign = "center"
    page.AppendChild(number)
end sub

' The width of one character of a monospace font, measured once.
function advanceOf(font as String, size as Integer) as Float
    key = font + size.ToStr()
    if m.advance[key] = invalid then
        probe = newLabel("0000000000", font, size, "0xFFFFFFFF", 0, 0)
        m.advance[key] = probe.boundingRect().width / 10
    end if
    return m.advance[key]
end function

' Up and Down on the rail swap the tab, and with it the hero and the rows, with
' no press. An open list folds when its tab is left, and CHANNELS & BUNDLES goes
' back to its list; the MY COLLECTIONS accordion and a package still building
' stay as they were. Each tab opens scrolled to the top. Nothing is saved or rebuilt here.
sub selectTab(i as Integer)
    if i < 0 or i > m.tabs.Count() - 1 or i = m.tabIndex then return
    m.tabIndex = i
    m.signOutArmed = false
    ' Another tab puts CHANNELS & BUNDLES back on its list.
    m.channelsPage = ""
    ' Only the tab changes, so its rows are picked from the ones built, not
    ' built again: with a few hundred franchises or collections a rebuild on
    ' each press of the rail was a lot of work on a stick (#201 review). An
    ' open list is folded before focus reaches the rail (NxSettingsKeyAction),
    ' so this rebuild is only a guard.
    if m.languageOpen <> "" then
        m.languageOpen = ""
        buildRows()
    else
        pickTab()
    end if
    m.focus = NxSettingsFirstFocusable(m.rows)
    m.scroll = 0
    render()
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if m.signOutArmed and key <> "OK" then
        m.signOutArmed = false
        render()
    end if
    action = NxSettingsKeyAction(m.where, key, m.languageOpen <> "", shownPage() <> "")
    if action = "tabUp" then
        selectTab(m.tabIndex - 1)
    else if action = "tabDown" then
        selectTab(m.tabIndex + 1)
    else if action = "enter" then
        ' Into the tab's first row (each view's firstRowID), not the row last
        ' left. A tab with nothing to focus (SUPPORT NOSTALGEX) leaves focus on
        ' the rail.
        if m.focus >= 0 then
            m.where = "rows"
            m.focus = NxSettingsFirstFocusable(m.rows)
            m.scroll = 0
            render()
        end if
    else if action = "leave" then
        leave()
    else if action = "move" then
        d = 1
        if key = "up" then d = -1
        m.focus = nextFocusable(m.focus, d)
        ' Up from the first row shows the headings above it again.
        if key = "up" and nextFocusable(m.focus, -1) = m.focus then m.scroll = 0
        render()
    else if action = "press" then
        pressRow()
    else if action = "fold" then
        foldLanguage()
    else if action = "pageUp" then
        showPage(NxChannelsPageParent(m.channelsPage), m.channelsPage)
    else if action = "toRail" then
        m.where = "rail"
        render()
    end if
    return true
end function

' ChannelRequirementCard: a lighter panel, cyan-edged when focused; the
' channel's colour bar and name, the amber line with how many titles match,
' then its rules, one bullet each, as wrapped in pushMissing. Read-only: OK
' does nothing on it.
sub drawMissingCard(page as Object, i as Integer, row as Object, y as Float)
    focused = (i = m.focus) and m.where = "rows"
    h = rowHeight(row) - 6
    fill = "0xFFFFFF08"
    if focused then fill = "0xFFFFFF12"
    page.AppendChild(newRect(0, y, m.rowW, h, fill))
    if focused then
        edge = m.accent + "80"
        page.AppendChild(newRect(0, y, m.rowW, 2, edge))
        page.AppendChild(newRect(0, y + h - 2, m.rowW, 2, edge))
        page.AppendChild(newRect(0, y, 2, h, edge))
        page.AppendChild(newRect(m.rowW - 2, y, 2, h, edge))
    end if
    def = row.def
    color = NxToStr(def.colorHex)
    if Left(color, 1) = "#" and Len(color) = 7 then color = "0x" + Mid(color, 2) + "FF" else color = "0xFFFFFFFF"
    page.AppendChild(newRect(20, y + 18, 4, 22, color))
    page.AppendChild(newLabel(UCase(NxToStr(def.name)), "DMMono-Medium", 22, "0xFFFFFFFF", 34, y + 14))
    ly = y + 14 + 34
    count = NxMissingCountOf(m.top.matchCounts, def.id)
    for each line in NxWrapText(NxMissingNeedsLine(def.minItems, count), row.cols)
        page.AppendChild(newLabel(line, "DMMono-Regular", 20, "0xFFB020FF", 20, ly))
        ly = ly + 26
    end for
    ' The longest amber line was measured: a shorter one leaves its space.
    ly = y + 14 + 34 + 26 * row.needsLines
    for each line in row.bullets
        page.AppendChild(newLabel(line, "DMMono-Regular", 20, "0xFFFFFFA6", 20, ly))
        ly = ly + 26
    end for
end sub

' OK on the focused row.
sub pressRow()
    if m.focus < 0 then return
    row = m.rows[m.focus]
    if row.kind = "channelsLink" then
        showPage(row.page)
    else if row.kind = "bundle" then
        id = m.top.bundles[row.index].id
        kept = []
        found = false
        for each x in m.enabled
            if x = id then found = true else kept.Push(x)
        end for
        ' The last package on stays on, as upstream's toggleBundle keeps one.
        if found and kept.Count() = 0 then return
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
        ' setAllFranchises: one explicit choice for every row, and every
        ' franchise collection not already the way asked (setAll).
        turnOn = anyFranchiseOff()
        for each f in m.top.franchises
            NxFranchiseRecordChoice(m.choices, f.id, turnOn)
        end for
        if m.top.franchises.Count() > 0 then m.franchisesChanged = true
        for each cr in collectionRows("franchises")
            if collectionOn(cr) <> turnOn then
                if turnOn then m.collectionKeys[cr.id] = true else m.collectionKeys.Delete(cr.id)
                m.collectionsChanged = true
            end if
        end for
        render()
    else if row.kind = "franchise" then
        NxFranchiseRecordChoice(m.choices, row.franchise.id, not franchiseOn(row.franchise))
        m.franchisesChanged = true
        render()
    else if row.kind = "collection" or row.kind = "franchiseCollection" then
        ' toggleCollection: switch one on and it airs from CH 310 (a franchise) or 400.
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
    else if row.kind = "watershed" then
        ' The library task reads it on its next re-check, which closing
        ' Settings asks for at once.
        NxSaveWatershed(not NxWatershedOn())
        print "settings: watershed "; NxWatershedOn()
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
    else if row.kind = "signOut" then
        if m.signOutArmed then
            m.top.result = "signOut"
        else
            m.signOutArmed = true
            render()
        end if
    end if
    ' VERSION and GITHUB: nothing to press, as on the Apple TV.
end sub

' Back on the rail: the server, franchise and collection choices are saved once
' here and the guide rebuilt as needed, as they were when Settings was one page.
sub leave()
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
end sub
