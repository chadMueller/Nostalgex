' What Settings' channel rows work out beyond a switch, held to the Apple TV's
' CHANNELS & BUNDLES (N-028, 1.0.29): the amber count on a package short of
' content, and the FRANCHISES page's one A to Z list.
'
' Source: upstream Nostalgex/Views/Settings/SettingsChannelsView.swift
' (ChannelsPackagesPage.packageRow, ChannelsFranchisesPage, ChannelsCollectionsPage)
' and Views/Settings/SettingsSharedComponents.swift (AlertCountBadge).
'
' Port copyright (c) 2026 nostalgex-roku contributors, MIT License.

' ── Packages short of content ───────────────────────────────────────────────

' The ids of the channels in the guide, as a set: the guide holds only channels
' with enough content. Built once per row list, not per package.
function NxOnAirSet(onAirIDs as Dynamic) as Object
    onAir = {}
    for each id in NxList(onAirIDs)
        onAir[NxToStr(id)] = true
    end for
    return onAir
end function

' bundleChannelAvailability: of a package's channels (ids, config order), how
' many are on air (`onAir`, NxOnAirSet). Returns { total, available, missing }.
function NxBundleAvailability(channelIDs as Object, onAir as Object) as Object
    total = 0
    available = 0
    for each id in NxList(channelIDs)
        total = total + 1
        if onAir.DoesExist(NxToStr(id)) then available = available + 1
    end for
    return { total: total, available: available, missing: total - available }
end function

' The amber count beside a package's channel count (packageRow's missingBadge):
' the channels still short of content, for a package that is on, not building
' and has some channels on air. An OFF package is an invitation, never a
' warning. `built` is whether the guide held the package when Settings opened:
' one switched on during the visit has no channels in it yet, which would read
' as "none have content". invalid when there is no badge.
function NxPackageBadge(on as Boolean, building as Boolean, built as Boolean, availability as Object) as Dynamic
    if on and built and not building and availability.available > 0 and availability.missing > 0 then return availability.missing
    return invalid
end function

' AlertCountBadge's text: 99+ past 99.
function NxBadgeText(count as Integer) as String
    if count > 99 then return "99+"
    return count.ToStr()
end function

' The width of the amber capsule for `textWidth` px of text: at least a 34 px
' circle, 9 px more each side past one digit (AlertCountBadge).
function NxBadgeWidth(count as Integer, textWidth as Float) as Float
    w = textWidth
    if count > 9 then w = w + 18
    if w < 34 then w = 34
    return w
end function

' ── The FRANCHISES page ─────────────────────────────────────────────────────

' ChannelsFranchisesPage's entries: the stock classics and the found franchises
' (`franchises`, NxFranchiseListRows) and the server's franchise collections
' (`collectionRows`, the collection rows of category "franchises"), one list, A to
' Z by name without regard to case (`localizedCaseInsensitiveCompare`; digits
' compare as characters here, unlike the franchise rows' own natural order).
' The franchise rows are listed only while the package is on (`showFranchises`);
' the collections always are. A tie keeps the franchise first.
' Entries: { kind: "franchise", franchise } or { kind: "collection", collection }.
function NxFranchisePageEntries(franchises as Dynamic, collectionRows as Dynamic, showFranchises as Boolean) as Object
    entries = []
    if showFranchises then
        for each f in NxList(franchises)
            entries.Push({ kind: "franchise", franchise: f, key: LCase(NxToStr(f.name)) })
        end for
    end if
    for each c in NxList(collectionRows)
        entries.Push({ kind: "collection", collection: c, key: LCase(NxToStr(c.title)) })
    end for
    ' A stable insertion sort: an entry moves up only past a larger name.
    sorted = []
    for each e in entries
        i = sorted.Count()
        sorted.Push(e)
        while i > 0 and e.key < sorted[i - 1].key
            sorted[i] = sorted[i - 1]
            i = i - 1
        end while
        sorted[i] = e
    end for
    return sorted
end function

' The one note under the franchise switch when the shared block (CH 310-399) is
' full: the found franchises and the franchise collections past it together.
function NxFranchiseBlockNote(overFound as Dynamic, overCollections as Dynamic, capacity as Dynamic) as String
    over = NxNumberOr0(overFound) + NxNumberOr0(overCollections)
    cap = NxNumberOr0(capacity)
    if over <= 0 or cap <= 0 then return ""
    return "Up to " + cap.ToStr() + " franchise channels fit in the guide. " + over.ToStr() + " more are switched on but not shown."
end function

' ── MY COLLECTIONS, custom collections only ─────────────────────────────────

' How many of the rows are franchise collections (listed under FRANCHISES) and
' how many are the viewer's own, MY COLLECTIONS'. A row from a build before the
' split has no category and is a custom one, as every row was.
function NxCollectionSplit(rows as Dynamic) as Object
    franchises = 0
    custom = 0
    for each r in NxList(rows)
        if NxToStr(r.category) = "franchises" then franchises = franchises + 1 else custom = custom + 1
    end for
    return { franchises: franchises, custom: custom }
end function

' The line under MY COLLECTIONS when there is something to say beyond the
' accordion's count: none found, a read that failed, every one a franchise, or
' how many sit under FRANCHISES (the Apple TV's scan line and allFoldedHint).
' `c` is the guide's collections ({ rows, scanned, failed }).
function NxCollectionsNote(c as Dynamic) as String
    if c = invalid then return ""
    rows = NxList(c.rows)
    if NxNumberOr0(c.failed) > 0 and rows.Count() = 0 then return "COULD NOT READ COLLECTIONS FROM YOUR SERVER"
    if rows.Count() = 0 then
        if NxNumberOr0(c.scanned) > 0 then return "NO COLLECTIONS WITH 3 OR MORE MOVIES OR EPISODES"
        return "Your server's collections show here after the library is read"
    end if
    split = NxCollectionSplit(rows)
    if split.franchises = 0 then return ""
    if split.custom = 0 then
        if split.franchises = 1 then return "Your collection is a franchise, under FRANCHISES."
        return "All " + split.franchises.ToStr() + " of your collections are franchises, under FRANCHISES."
    end if
    return split.custom.ToStr() + " FOUND · " + split.franchises.ToStr() + " UNDER FRANCHISES"
end function
