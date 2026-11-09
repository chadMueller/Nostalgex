' Runs source/guide/SettingsRail.brs against the Apple TV's Settings rail
' (N-028, 1.0.29; Views/Settings/SettingsCategory.swift and
' SettingsContainerView.swift): the tabs and the pinned one, which tab each row
' kind sits in, where focus lands when a tab is entered, and what Left, Back
' and the other keys do from the rail, a row, an open list and a CHANNELS &
' BUNDLES page. Returns the failure count.

function NxRunSettingsRailTests() as Integer
    r = { pass: 0, fail: 0 }

    ' ── The tabs, in the rail's order ───────────────────────────────────────
    tabs = NxSettingsTabs()
    NxCheck(r, "tabs: five, in the Apple TV's order", NxRailIds(tabs), "support|playback|channels|servers|about")
    NxCheck(r, "tabs: SUPPORT NOSTALGEX is the one pinned above the divider", NxRailPinned(tabs), "support")
    NxCheck(r, "tabs: the titles", NxRailTitles(tabs), "SUPPORT NOSTALGEX|PLAYBACK & PICTURE|CHANNELS & BUNDLES|SERVERS & ACCOUNTS|ABOUT")
    NxCheck(r, "tabs: PLAYBACK & PICTURE's line, word for word", tabs[1].line, "Picture, quality, subtitles and audio")
    NxCheck(r, "tabs: CHANNELS & BUNDLES's line", tabs[2].line, "Packages, franchises, collections and the schedule")
    NxCheck(r, "tabs: SERVERS & ACCOUNTS's line", tabs[3].line, "Servers, libraries, rescans and sign out")
    NxCheck(r, "tabs: ABOUT's line", tabs[4].line, "Version and links")
    NxCheck(r, "tabs: SUPPORT NOSTALGEX keeps the Roku's own line", tabs[0].line, "News, help and the Apple TV app are on its site")
    NxCheck(r, "tabs: each has a hero icon", NxRailField(tabs, "hero"), "support|playback|channels|servers|about")

    ' ── Which tab a row kind sits in ────────────────────────────────────────
    NxCheck(r, "tab of: the QR card", NxSettingsTabOf("support"), "support")
    for each kind in ["retro", "guideText", "quality", "qualityChoice", "subtitles", "language", "languageChoice"]
        NxCheck(r, "tab of: " + kind, NxSettingsTabOf(kind), "playback")
    end for
    NxCheck(r, "tab of: SHOW NOW PLAYING moves from CONNECTION to PLAYBACK & PICTURE", NxSettingsTabOf("reportNowPlaying"), "playback")
    NxCheck(r, "tab of: MARK WATCHED too", NxSettingsTabOf("reportMarkWatched"), "playback")
    for each kind in ["channelsLink", "bundle", "franchiseAll", "franchise", "franchiseCollection", "collectionsToggle", "collection"]
        NxCheck(r, "tab of: " + kind, NxSettingsTabOf(kind), "channels")
    end for
    for each kind in ["server", "rescan", "signOut"]
        NxCheck(r, "tab of: " + kind, NxSettingsTabOf(kind), "servers")
    end for
    NxCheck(r, "tab of: the version line is an ABOUT row", NxSettingsTabOf("version"), "about")
    NxCheck(r, "tab of: GITHUB", NxSettingsTabOf("github"), "about")
    NxCheck(r, "tab of: WATERSHED (#211's row) is a CHANNELS row", NxSettingsTabOf("watershed"), "channels")
    NxCheck(r, "tab of: a text row has none of its own", NxSettingsTabOf("header"), "")
    NxCheck(r, "tab of: an unknown kind", NxSettingsTabOf("nothing"), "")

    ' ── Where focus lands when a tab is entered ─────────────────────────────
    NxCheck(r, "focusable: a header is not", NxSettingsRowFocusable("header").ToStr(), "false")
    NxCheck(r, "focusable: a subheader is not", NxSettingsRowFocusable("subheader").ToStr(), "false")
    NxCheck(r, "focusable: an info line is not", NxSettingsRowFocusable("info").ToStr(), "false")
    NxCheck(r, "focusable: the QR card is not", NxSettingsRowFocusable("support").ToStr(), "false")
    NxCheck(r, "focusable: VERSION is, so the remote has somewhere to land", NxSettingsRowFocusable("version").ToStr(), "true")
    NxCheck(r, "focusable: a package row", NxSettingsRowFocusable("bundle").ToStr(), "true")
    NxCheck(r, "focusable: a CHANNELS & BUNDLES link row", NxSettingsRowFocusable("channelsLink").ToStr(), "true")
    NxCheck(r, "first row: SUPPORT NOSTALGEX has none, focus stays on the rail", NxSettingsFirstFocusable([{ kind: "support" }]).ToStr(), "-1")
    NxCheck(r, "first row: PLAYBACK & PICTURE opens on RETRO MODE", NxSettingsFirstFocusable([{ kind: "retro" }, { kind: "guideText" }]).ToStr(), "0")
    NxCheck(r, "first row: a heading is skipped", NxSettingsFirstFocusable([{ kind: "header" }, { kind: "bundle" }]).ToStr(), "1")
    NxCheck(r, "first row: SERVERS & ACCOUNTS opens on the first server", NxSettingsFirstFocusable([{ kind: "subheader" }, { kind: "server" }, { kind: "rescan" }]).ToStr(), "1")
    NxCheck(r, "first row: with no server row, RESCAN LIBRARY", NxSettingsFirstFocusable([{ kind: "subheader" }, { kind: "rescan" }]).ToStr(), "1")
    NxCheck(r, "first row: text only", NxSettingsFirstFocusable([{ kind: "header" }, { kind: "info" }]).ToStr(), "-1")
    NxCheck(r, "first row: no rows", NxSettingsFirstFocusable([]).ToStr(), "-1")
    NxCheck(r, "first row: no list", NxSettingsFirstFocusable(invalid).ToStr(), "-1")

    ' ── What a key does ─────────────────────────────────────────────────────
    NxCheck(r, "rail: Up swaps the pane at once", NxSettingsKeyAction("rail", "up", false), "tabUp")
    NxCheck(r, "rail: Down too", NxSettingsKeyAction("rail", "down", false), "tabDown")
    NxCheck(r, "rail: OK goes into the tab's first row", NxSettingsKeyAction("rail", "OK", false), "enter")
    NxCheck(r, "rail: Right too", NxSettingsKeyAction("rail", "right", false), "enter")
    NxCheck(r, "rail: Back leaves Settings", NxSettingsKeyAction("rail", "back", false), "leave")
    NxCheck(r, "rail: Left does nothing", NxSettingsKeyAction("rail", "left", false), "")
    NxCheck(r, "rows: Up moves", NxSettingsKeyAction("rows", "up", false), "move")
    NxCheck(r, "rows: Down moves", NxSettingsKeyAction("rows", "down", false), "move")
    NxCheck(r, "rows: OK presses the row", NxSettingsKeyAction("rows", "OK", false), "press")
    NxCheck(r, "rows: Left goes straight to the rail", NxSettingsKeyAction("rows", "left", false), "toRail")
    NxCheck(r, "rows: Back goes to the rail", NxSettingsKeyAction("rows", "back", false), "toRail")
    NxCheck(r, "rows: Right does nothing", NxSettingsKeyAction("rows", "right", false), "")
    NxCheck(r, "open list: Left folds it first", NxSettingsKeyAction("rows", "left", true), "fold")
    NxCheck(r, "open list: Back folds it first", NxSettingsKeyAction("rows", "back", true), "fold")
    NxCheck(r, "open list: OK still presses", NxSettingsKeyAction("rows", "OK", true), "press")
    NxCheck(r, "open list: Up still moves", NxSettingsKeyAction("rows", "up", true), "move")
    NxCheck(r, "page: Back steps up to the list", NxSettingsKeyAction("rows", "back", false, true), "pageUp")
    NxCheck(r, "page: Left goes straight to the rail", NxSettingsKeyAction("rows", "left", false, true), "toRail")
    NxCheck(r, "page: OK presses", NxSettingsKeyAction("rows", "OK", false, true), "press")
    NxCheck(r, "page: Up moves", NxSettingsKeyAction("rows", "up", false, true), "move")
    NxCheck(r, "page: an open list still folds first", NxSettingsKeyAction("rows", "back", true, true), "fold")
    NxCheck(r, "page: on the rail, Back still leaves Settings", NxSettingsKeyAction("rail", "back", false, true), "leave")
    NxCheck(r, "page: on the rail, Right enters the page's rows", NxSettingsKeyAction("rail", "right", false, true), "enter")

    ' ── One tab's rows from every tab's ─────────────────────────────────────
    all = [{ kind: "support", inTab: "support" }, { kind: "retro", inTab: "playback" }, { kind: "header", inTab: "channels" }, { kind: "bundle", inTab: "channels", index: 0 }, { kind: "bundle", inTab: "channels", index: 1 }, { kind: "signOut", inTab: "servers" }]
    NxCheck(r, "rows in tab: CHANNELS's, in order", NxRailRowKinds(NxSettingsRowsInTab(all, "channels")), "header|bundle0|bundle1")
    NxCheck(r, "rows in tab: one row", NxRailRowKinds(NxSettingsRowsInTab(all, "servers")), "signOut")
    NxCheck(r, "rows in tab: a tab with none", NxSettingsRowsInTab(all, "about").Count().ToStr(), "0")
    NxCheck(r, "rows in tab: a row in no tab is in none", NxSettingsRowsInTab([{ kind: "nothing", inTab: "" }], "channels").Count().ToStr(), "0")
    picked = NxSettingsRowsInTab(all, "playback")
    picked[0].marked = "yes"
    NxCheck(r, "rows in tab: the rows themselves, not copies", NxToStr(all[1].marked), "yes")
    NxCheck(r, "rows in tab: no list", NxSettingsRowsInTab(invalid, "channels").Count().ToStr(), "0")

    ' ── CHANNELS & BUNDLES: its list and its pages ──────────────────────────
    ch = [
        { kind: "channelsLink", inTab: "channels", inPage: "", page: "packages" },
        { kind: "channelsLink", inTab: "channels", inPage: "", page: "franchises" },
        { kind: "channelsLink", inTab: "channels", inPage: "", page: "collections" },
        { kind: "header", inTab: "channels", inPage: "packages" },
        { kind: "bundle", inTab: "channels", inPage: "packages", index: 0 },
        { kind: "header", inTab: "channels", inPage: "franchises" },
        { kind: "bundle", inTab: "channels", inPage: "franchises", index: 9 },
        { kind: "franchiseAll", inTab: "channels", inPage: "franchises" },
        { kind: "header", inTab: "channels", inPage: "collections" },
        { kind: "info", inTab: "channels", inPage: "collections" },
        { kind: "watershed", inTab: "channels", inPage: "" },
        { kind: "rescan", inTab: "servers", inPage: "" }
    ]
    NxCheck(r, "pages: the list is the three links, then WATERSHED", NxRailRowKinds(NxSettingsRowsInTab(ch, "channels")), "channelsLink|channelsLink|channelsLink|watershed")
    NxCheck(r, "pages: CHANNEL PACKAGES holds its section", NxRailRowKinds(NxSettingsRowsInTab(ch, "channels", "packages")), "header|bundle0")
    NxCheck(r, "pages: FRANCHISES holds its switch and ADD ALL", NxRailRowKinds(NxSettingsRowsInTab(ch, "channels", "franchises")), "header|bundle9|franchiseAll")
    NxCheck(r, "pages: a page opens on its first row", NxSettingsFirstFocusable(NxSettingsRowsInTab(ch, "channels", "packages")).ToStr(), "1")
    NxCheck(r, "pages: the list opens on CHANNEL PACKAGES", NxSettingsFirstFocusable(NxSettingsRowsInTab(ch, "channels")).ToStr(), "0")
    NxCheck(r, "pages: MY COLLECTIONS with only text has no row to land on", NxSettingsFirstFocusable(NxSettingsRowsInTab(ch, "channels", "collections")).ToStr(), "-1")
    NxCheck(r, "pages: another tab's rows are on no page", NxRailRowKinds(NxSettingsRowsInTab(ch, "servers")), "rescan")
    NxCheck(r, "pages: nothing of another tab on a page", NxSettingsRowsInTab(ch, "servers", "packages").Count().ToStr(), "0")
    NxCheck(r, "pages: a row with no inPage is on the list", NxSettingsRowsInTab([{ kind: "retro", inTab: "playback" }], "playback").Count().ToStr(), "1")
    list = NxSettingsRowsInTab(ch, "channels")
    NxCheck(r, "back from a page: lands on the row that opened CHANNEL PACKAGES", NxSettingsLinkRowOf(list, "packages").ToStr(), "0")
    NxCheck(r, "back from a page: FRANCHISES", NxSettingsLinkRowOf(list, "franchises").ToStr(), "1")
    NxCheck(r, "back from a page: MY COLLECTIONS", NxSettingsLinkRowOf(list, "collections").ToStr(), "2")
    NxCheck(r, "back from a page: a page with no link", NxSettingsLinkRowOf(list, "missing").ToStr(), "-1")
    NxCheck(r, "back from a page: no list", NxSettingsLinkRowOf(invalid, "packages").ToStr(), "-1")

    print "settings rail cases:"; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

function NxRailField(tabs as Object, field as String) as String
    out = []
    for each t in tabs
        out.Push(NxToStr(t[field]))
    end for
    return out.Join("|")
end function

function NxRailIds(tabs as Object) as String
    return NxRailField(tabs, "id")
end function

function NxRailTitles(tabs as Object) as String
    return NxRailField(tabs, "title")
end function

function NxRailPinned(tabs as Object) as String
    out = []
    for each t in tabs
        if t.pinned then out.Push(t.id)
    end for
    return out.Join("|")
end function

' Kinds joined with "|", a bundle's index after it.
function NxRailRowKinds(rows as Object) as String
    out = []
    for each row in rows
        k = row.kind
        if row.index <> invalid then k = k + row.index.ToStr()
        out.Push(k)
    end for
    return out.Join("|")
end function
