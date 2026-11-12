' Settings as a rail and a pane, held to the Apple TV's (N-028, 1.0.29): the
' five tabs in the rail's order, which tab each row belongs to, where focus
' lands when a tab or a CHANNELS & BUNDLES page is entered, and what a key does
' on the rail, in the rows and inside a page.
' The drawing is SettingsView's; these are the rules it follows.
'
' Source: upstream Nostalgex/Views/Settings/SettingsCategory.swift (the tabs,
' their titles and lines, the pinned one), SettingsContainerView.swift (the
' keys) and the firstRowID of each tab's view.
'
' Port copyright (c) 2026 nostalgex-roku contributors, MIT License.

' ── The tabs ────────────────────────────────────────────────────────────────

' The rail's tabs, in its order: SUPPORT NOSTALGEX pinned above a divider, then
' the four others. NOSTALGEX PRO is off on the Apple TV (SettingsFeatures), so
' it isn't here. `line` is the hero's one line under the title: the Apple TV's
' word for word, except SUPPORT NOSTALGEX, whose tab there is a star rating and
' tip tiles, where the Roku keeps its QR card and its own line. `hero` names
' the 96 px icon in images/look/settings_hero_<hero>.png.
function NxSettingsTabs() as Object
    return [
        { id: "support", title: "SUPPORT NOSTALGEX", line: "News, help and the Apple TV app are on its site", hero: "support", pinned: true },
        { id: "playback", title: "PLAYBACK & PICTURE", line: "Picture, quality, subtitles and audio", hero: "playback", pinned: false },
        { id: "channels", title: "CHANNELS & BUNDLES", line: "Packages, franchises, collections and the schedule", hero: "channels", pinned: false },
        { id: "servers", title: "SERVERS & ACCOUNTS", line: "Servers, libraries, rescans and sign out", hero: "servers", pinned: false },
        { id: "about", title: "ABOUT", line: "Version and links", hero: "about", pinned: false }
    ]
end function

' The tab a row of `kind` sits in. Text rows (header, subheader, info) belong
' to the section they head, so SettingsView gives them their tab itself; this
' returns "" for them and for a kind it doesn't know.
function NxSettingsTabOf(kind as String) as String
    playback = ["retro", "guideText", "quality", "qualityChoice", "subtitles", "language", "languageChoice", "lastChannel", "reportNowPlaying", "reportMarkWatched"]
    ' WATERSHED is #211's row (SettingsChannelsView on the Apple TV). It is
    ' listed here before that row exists, so neither pull request has to land
    ' first: a kind missing from these lists is in no tab and never shows.
    channels = ["channelsLink", "bundle", "franchiseAll", "franchise", "franchiseCollection", "collectionsToggle", "collection", "watershed", "missingCard", "missingNone"]
    servers = ["server", "includeHidden", "rescan", "signOut"]
    about = ["version", "aboutLink"]
    if kind = "support" then return "support"
    if NxHasValue(playback, kind) then return "playback"
    if NxHasValue(channels, kind) then return "channels"
    if NxHasValue(servers, kind) then return "servers"
    if NxHasValue(about, kind) then return "about"
    return ""
end function

' The rows of `all` in the tab `tabId`, in order. SettingsView builds every
' tab's rows once and picks one tab's from them on each rail press, so Up and
' Down on the rail don't rebuild the franchise and collection lists.
' `page` is the CHANNELS & BUNDLES page on show (a row's `inPage`): "" is the
' tab's list, which every other tab's rows are on too. A row with no `inPage`
' is on the list.
function NxSettingsRowsInTab(all as Dynamic, tabId as String, page = "" as String) as Object
    rows = []
    if type(all) <> "roArray" then return rows
    for each row in all
        if type(row) = "roAssociativeArray" and row.inTab = tabId and NxToStr(row.inPage) = page then rows.Push(row)
    end for
    return rows
end function

' The row on the list that opens `page` (its channelsLink), for Back from the
' page to land on (ChannelsPage.linkRowID); -1 when the list has none.
function NxSettingsLinkRowOf(rows as Dynamic, page as String) as Integer
    i = 0
    for each row in NxList(rows)
        if NxToStr(row.kind) = "channelsLink" and NxToStr(row.page) = page then return i
        i = i + 1
    end for
    return -1
end function

' ── Focus ───────────────────────────────────────────────────────────────────

' Whether a row of `kind` takes focus. Text rows never do, nor the QR card:
' scanning it is the action. VERSION and the ABOUT links do, as on the Apple TV, where
' the remote has somewhere to land and select does nothing.
function NxSettingsRowFocusable(kind as String) as Boolean
    return kind <> "header" and kind <> "subheader" and kind <> "info" and kind <> "support"
end function

' The row focus lands on when a tab is entered (each view's firstRowID): the
' first one that takes focus (a row marked `gated`, a franchise collection
' while FRANCHISES is off, never does), or -1 when none does (SUPPORT NOSTALGEX), when
' focus stays on the rail.
function NxSettingsFirstFocusable(rows as Dynamic) as Integer
    i = 0
    for each row in NxList(rows)
        if NxSettingsRowFocusable(NxToStr(row.kind)) and row.gated <> true then return i
        i = i + 1
    end for
    return -1
end function

' ── Keys ────────────────────────────────────────────────────────────────────

' What a key does, from where focus is: "rail" or "rows". `listOpen` is a
' language or quality list open in place, which folds before anything else, as
' it did when the list was one page. `inPage` is a CHANNELS & BUNDLES page on
' show, where Back steps up to the list before it reaches the rail
' (SettingsContainerView's onExitCommand). The actions:
'   on the rail: "tabUp" / "tabDown" swap the pane at once, with no press;
'   "enter" (Right or OK) goes into the tab's first row; "leave" (Back) closes
'   Settings. Left does nothing there.
'   in the rows: "move" (Up / Down), "press" (OK), "fold" (Left or Back with a
'   list open), "pageUp" (Back inside a page: to the list, on the row that
'   opened it), "toRail" (Left, or Back on the list). Left inside a page goes
'   to the rail too and leaves the page on show, as the Apple TV's does. Right
'   does nothing.
' "" is a key with nothing to do.
function NxSettingsKeyAction(where as String, key as String, listOpen as Boolean, inPage = false as Boolean) as String
    if where = "rail" then
        if key = "up" then return "tabUp"
        if key = "down" then return "tabDown"
        if key = "OK" or key = "right" then return "enter"
        if key = "back" then return "leave"
        return ""
    end if
    if key = "up" or key = "down" then return "move"
    if key = "OK" then return "press"
    if key = "left" or key = "back" then
        if listOpen then return "fold"
        if key = "back" and inPage then return "pageUp"
        return "toRail"
    end if
    return ""
end function
