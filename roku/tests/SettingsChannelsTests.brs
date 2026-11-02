' Runs source/guide/SettingsChannels.brs against the Apple TV's CHANNELS &
' BUNDLES (N-028, 1.0.29; Views/Settings/SettingsChannelsView.swift): the
' amber count on a package short of content, the FRANCHISES page's one A to Z
' list, and what MY COLLECTIONS says now that it holds only the viewer's own.
' The last cases read the real packages in data/channels.json.
' Returns the failure count.

function NxRunSettingsChannelsTests(configPath as String) as Integer
    r = { pass: 0, fail: 0 }

    ' ── bundleChannelAvailability ───────────────────────────────────────────
    onAir = NxOnAirSet([1, 2, 4, 5, 1000000])
    a = NxBundleAvailability([1, 2, 3], onAir)
    NxCheck(r, "availability: 2 of 3 on air", a.available.ToStr() + "/" + a.total.ToStr() + " missing " + a.missing.ToStr(), "2/3 missing 1")
    a = NxBundleAvailability([4, 5], onAir)
    NxCheck(r, "availability: all on air", a.available.ToStr() + "/" + a.total.ToStr() + " missing " + a.missing.ToStr(), "2/2 missing 0")
    a = NxBundleAvailability([7, 8, 9], onAir)
    NxCheck(r, "availability: none on air", a.available.ToStr() + "/" + a.total.ToStr() + " missing " + a.missing.ToStr(), "0/3 missing 3")
    a = NxBundleAvailability([], onAir)
    NxCheck(r, "availability: an empty package", a.available.ToStr() + "/" + a.total.ToStr() + " missing " + a.missing.ToStr(), "0/0 missing 0")
    a = NxBundleAvailability(["1", "2"], onAir)
    NxCheck(r, "availability: an id as text is the same id", a.available.ToStr(), "2")
    a = NxBundleAvailability([1000000, 3], onAir)
    NxCheck(r, "availability: a found franchise's id", a.available.ToStr(), "1")
    NxCheck(r, "availability: no guide on air", NxBundleAvailability([1, 2], NxOnAirSet(invalid)).missing.ToStr(), "2")

    ' ── packageRow's amber count ────────────────────────────────────────────
    short = { total: 10, available: 8, missing: 2 }
    NxCheck(r, "badge: on, built, 2 short", NxBadgeOf(NxPackageBadge(true, false, true, short)), "2")
    NxCheck(r, "badge: off is never a warning", NxBadgeOf(NxPackageBadge(false, false, true, short)), "none")
    NxCheck(r, "badge: not while it builds", NxBadgeOf(NxPackageBadge(true, true, true, short)), "none")
    NxCheck(r, "badge: not for a package the guide never held", NxBadgeOf(NxPackageBadge(true, false, false, short)), "none")
    NxCheck(r, "badge: none on air is another message, not a count", NxBadgeOf(NxPackageBadge(true, false, true, { total: 10, available: 0, missing: 10 })), "none")
    NxCheck(r, "badge: every channel on air", NxBadgeOf(NxPackageBadge(true, false, true, { total: 10, available: 10, missing: 0 })), "none")
    NxCheck(r, "badge: one short", NxBadgeOf(NxPackageBadge(true, false, true, { total: 4, available: 3, missing: 1 })), "1")

    ' ── AlertCountBadge ─────────────────────────────────────────────────────
    NxCheck(r, "badge text: 1", NxBadgeText(1), "1")
    NxCheck(r, "badge text: 99", NxBadgeText(99), "99")
    NxCheck(r, "badge text: 100", NxBadgeText(100), "99+")
    NxCheck(r, "badge text: 250", NxBadgeText(250), "99+")
    NxCheck(r, "badge width: one digit is a 34 px circle", NxBadgeWidth(5, 12).ToStr(), "34")
    NxCheck(r, "badge width: two digits get 9 px a side", NxBadgeWidth(10, 24).ToStr(), "42")
    NxCheck(r, "badge width: 99+", NxBadgeWidth(100, 36).ToStr(), "54")
    NxCheck(r, "badge width: wide type past 34 stays as it is", NxBadgeWidth(5, 40).ToStr(), "40")

    ' ── ChannelsFranchisesPage: one A to Z list ─────────────────────────────
    franchises = [
        { id: "dict:ALIEN", name: "ALIEN" },
        { id: "dict:STAR WARS", name: "STAR WARS" },
        { id: "f:fast", name: "Fast & Furious" }
    ]
    collections = [
        { id: "c1", title: "Batman Collection", category: "franchises" },
        { id: "c2", title: "alien Nation", category: "franchises" }
    ]
    NxCheck(r, "page: classics, found franchises and collections in one list", NxPageNames(NxFranchisePageEntries(franchises, collections, true)), "ALIEN|alien Nation|Batman Collection|Fast & Furious|STAR WARS")
    NxCheck(r, "page: the kinds follow", NxPageKinds(NxFranchisePageEntries(franchises, collections, true)), "franchise|collection|collection|franchise|franchise")
    NxCheck(r, "page: switch off, the collections stay listed", NxPageNames(NxFranchisePageEntries(franchises, collections, false)), "alien Nation|Batman Collection")
    NxCheck(r, "page: nothing at all", NxPageNames(NxFranchisePageEntries([], [], true)), "")
    NxCheck(r, "page: no lists yet", NxPageNames(NxFranchisePageEntries(invalid, invalid, true)), "")
    tie = NxFranchisePageEntries([{ id: "dict:DUNE", name: "DUNE" }], [{ id: "c9", title: "Dune", category: "franchises" }], true)
    NxCheck(r, "page: a tie keeps the franchise first", NxPageKinds(tie), "franchise|collection")
    digits = NxFranchisePageEntries([], [{ id: "a", title: "2 Fast", category: "franchises" }, { id: "b", title: "10 Things", category: "franchises" }], true)
    NxCheck(r, "page: digits compare as characters, as localizedCaseInsensitiveCompare", NxPageNames(digits), "10 Things|2 Fast")
    NxCheck(r, "page: case does not order", NxPageNames(NxFranchisePageEntries([], [{ id: "a", title: "b", category: "franchises" }, { id: "b", title: "A", category: "franchises" }, { id: "c", title: "C", category: "franchises" }], true)), "A|b|C")

    ' ── The shared block's one note ─────────────────────────────────────────
    NxCheck(r, "note: found franchises and collections past the block add up", NxFranchiseBlockNote(3, 2, 90), "Up to 90 franchise channels fit in the guide. 5 more are switched on but not shown.")
    NxCheck(r, "note: only collections past it", NxFranchiseBlockNote(0, 4, 90), "Up to 90 franchise channels fit in the guide. 4 more are switched on but not shown.")
    NxCheck(r, "note: a build before the split has no collection count", NxFranchiseBlockNote(1, invalid, 90), "Up to 90 franchise channels fit in the guide. 1 more are switched on but not shown.")
    NxCheck(r, "note: nothing past the block", NxFranchiseBlockNote(0, 0, 90), "")
    NxCheck(r, "note: no capacity yet", NxFranchiseBlockNote(3, 2, 0), "")

    ' ── MY COLLECTIONS ──────────────────────────────────────────────────────
    custom = { title: "Actors", category: "custom" }
    franchise = { title: "Batman", category: "franchises" }
    old = { title: "Before the split" }
    split = NxCollectionSplit([custom, franchise, franchise, old])
    NxCheck(r, "split: franchise collections go to FRANCHISES", split.franchises.ToStr(), "2")
    NxCheck(r, "split: a row from before the split is the viewer's own", split.custom.ToStr(), "2")
    NxCheck(r, "split: no list", NxCollectionSplit(invalid).custom.ToStr(), "0")
    NxCheck(r, "line: no collections block yet", NxCollectionsNote(invalid), "")
    NxCheck(r, "line: a read that failed", NxCollectionsNote({ rows: [], scanned: 0, failed: 2 }), "COULD NOT READ COLLECTIONS FROM YOUR SERVER")
    NxCheck(r, "line: none big enough", NxCollectionsNote({ rows: [], scanned: 5, failed: 0 }), "NO COLLECTIONS WITH 3 OR MORE MOVIES OR EPISODES")
    NxCheck(r, "line: not read yet", NxCollectionsNote({ rows: [], scanned: 0, failed: 0 }), "Your server's collections show here after the library is read")
    NxCheck(r, "line: only the viewer's own, nothing to say", NxCollectionsNote({ rows: [custom, custom], scanned: 2, failed: 0 }), "")
    NxCheck(r, "line: some under FRANCHISES", NxCollectionsNote({ rows: [custom, custom, custom, franchise, franchise], scanned: 5, failed: 0 }), "3 FOUND · 2 UNDER FRANCHISES")
    NxCheck(r, "line: all of them franchises", NxCollectionsNote({ rows: [franchise, franchise, franchise], scanned: 3, failed: 0 }), "All 3 of your collections are franchises, under FRANCHISES.")
    NxCheck(r, "line: the one is a franchise", NxCollectionsNote({ rows: [franchise], scanned: 1, failed: 0 }), "Your collection is a franchise, under FRANCHISES.")

    ' ── The real packages ───────────────────────────────────────────────────
    config = ParseJson(ReadAsciiFile(configPath))
    ids = []
    franchisesBundle = invalid
    for each b in config.bundles
        if b.id = "nostalgex" then ids = b.channelIDs
        if b.id = NxFranchisesBundleID() then franchisesBundle = b
    end for
    NxCheck(r, "real: NOSTALGEX has channels", FormatJson(ids.Count() > 1), "true")
    shortIds = []
    for i = 0 to ids.Count() - 2
        shortIds.Push(ids[i])
    end for
    real = NxBundleAvailability(ids, NxOnAirSet(shortIds))
    NxCheck(r, "real: NOSTALGEX one channel short", real.missing.ToStr() + " of " + real.total.ToStr(), "1 of " + ids.Count().ToStr())
    NxCheck(r, "real: and it shows a 1", NxBadgeOf(NxPackageBadge(true, false, true, real)), "1")
    NxCheck(r, "real: FRANCHISES is a package of its own", FormatJson(franchisesBundle <> invalid), "true")

    print "settings channels cases (upstream SettingsChannelsView): "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' A badge as text: its count, or "none" for no badge.
function NxBadgeOf(badge as Dynamic) as String
    if badge = invalid then return "none"
    return badge.ToStr()
end function

' The names on the page's entries, in order, as text.
function NxPageNames(entries as Object) as String
    out = ""
    for each e in entries
        name = ""
        if e.kind = "franchise" then name = e.franchise.name else name = e.collection.title
        if out <> "" then out = out + "|"
        out = out + name
    end for
    return out
end function

function NxPageKinds(entries as Object) as String
    out = ""
    for each e in entries
        if out <> "" then out = out + "|"
        out = out + e.kind
    end for
    return out
end function
