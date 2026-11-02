' Runs the pieces of the lineup packing (source/schedule/DailyManifest.brs and
' source/guide/Lineup.brs): the occupancy, the multi-part mark, pickCandidate and
' the channel order, then a small lineup through NxManifestBlocks. The whole
' walk is held to scripts/schedule-parity-golden.json in
' ScheduleParityGoldenTests.brs; these are the cases it can't name one by one.
' Mirrors nostalgex-daily-manifest.js makeOccupancy, sequelMark,
' waitsForEarlierPart, pickCandidate and sortByLineupPriority.
' Returns the failure count.

function NxRunCrossChannelTests() as Integer
    r = { pass: 0, fail: 0 }

    ' ── Occupancy ───────────────────────────────────────────────────────────
    occ = NxOccupancy()
    NxOccupancyAdd(occ, 1, "a", 100, 200)
    NxOccupancyAdd(occ, 3, "a", 120, 180)
    NxOccupancyAdd(occ, 1, "b", 500, 500)
    NxCheck(r, "overlap: another channel's slot", NxOccupancyOverlap(occ, "a", 150, 250, 2).ToStr(), "80")
    NxCheck(r, "overlap: a channel's own slot is not another's", NxOccupancyOverlap(occ, "a", 150, 250, 1).ToStr(), "30")
    NxCheck(r, "overlap: after it", NxOccupancyOverlap(occ, "a", 200, 300, 2).ToStr(), "0")
    NxCheck(r, "overlap: another title", NxOccupancyOverlap(occ, "c", 100, 200, 2).ToStr(), "0")
    NxCheck(r, "overlap: an empty slot is never added", NxOccupancyOverlap(occ, "b", 0, 1000, 2).ToStr(), "0")
    NxCheck(r, "overlap: the key is case sensitive", NxOccupancyOverlap(occ, "A", 100, 200, 2).ToStr(), "0")
    gatedOcc = NxOccupancy()
    NxOccupancyAdd(gatedOcc, 4, "g", 0, 100, true)
    NxOccupancyAdd(gatedOcc, 5, "g", 50, 100, false)
    NxCheck(r, "overlap: a time-gated channel is seen by the rest", NxOccupancyOverlap(gatedOcc, "g", 0, 100, 2).ToStr(), "150")
    NxCheck(r, "overlap: a time-gated channel asking skips the gated ones", NxOccupancyOverlap(gatedOcc, "g", 0, 100, 2, true).ToStr(), "50")
    NxCheck(r, "overlap: skipping gated ones leaves the rest as they were", NxOccupancyOverlap(occ, "a", 150, 250, 2, true).ToStr(), "80")

    ' ── The mark of a multi-part film ───────────────────────────────────────
    NxCheck(r, "mark: Part 2", NxMarkText(NxSequelMark({ type: "movie", title: "The Long Night Part 2" })), "the long night 2")
    NxCheck(r, "mark: Pt. 3 after a colon", NxMarkText(NxSequelMark({ type: "movie", title: "Rocky: Pt. 3" })), "rocky 3")
    NxCheck(r, "mark: no part", NxMarkText(NxSequelMark({ type: "movie", title: "Alien" })), "none")
    NxCheck(r, "mark: an episode never has one", NxMarkText(NxSequelMark({ type: "episode", title: "Show Part 2" })), "none")
    NxCheck(r, "mark: nothing before the part", NxMarkText(NxSequelMark({ type: "movie", title: "Part 1" })), "none")
    NxCheck(r, "mark: three digits are not a part", NxMarkText(NxSequelMark({ type: "movie", title: "Saga Part 123" })), "none")
    p1 = { ratingKey: "1", type: "movie", title: "Saga Part 1", duration: 60 }
    p2 = { ratingKey: "2", type: "movie", title: "Saga Part 2", duration: 60 }
    o = { ratingKey: "3", type: "movie", title: "Other", duration: 60 }
    NxCheck(r, "waits: a later part behind an earlier one", NxWaitsForEarlierPart([p1, p2], 1).ToStr(), "true")
    NxCheck(r, "waits: the earlier part first", NxWaitsForEarlierPart([p2, p1], 1).ToStr(), "false")
    NxCheck(r, "waits: another film in front", NxWaitsForEarlierPart([o, p2], 1).ToStr(), "false")

    ' ── pickCandidate ───────────────────────────────────────────────────────
    a = NxCrossItem("a", 60)
    b = NxCrossItem("b", 60)
    c = NxCrossItem("c", 60)
    busy = NxOccupancy()
    NxOccupancyAdd(busy, 9, "a", 0, 3600)
    NxCheck(r, "pick: no occupancy is the first", NxPickCandidate([a, b, c], 0, invalid, 1, invalid, true).ToStr(), "0")
    NxCheck(r, "pick: the first one on elsewhere waits", NxPickCandidate([a, b, c], 0, busy, 1, invalid, true).ToStr(), "1")
    NxCheck(r, "pick: its own slot elsewhere is its own", NxPickCandidate([a, b, c], 0, busy, 9, invalid, true).ToStr(), "0")
    NxCheck(r, "pick: free after the other's slot", NxPickCandidate([a, b, c], 3600, busy, 1, invalid, true).ToStr(), "0")
    NxCheck(r, "pick: the title that just played is passed over", NxPickCandidate([a, b, c], 0, invalid, 1, "a", false).ToStr(), "1")
    NxCheck(r, "pick: nothing else, it plays again", NxPickCandidate([a], 0, invalid, 1, "a", false).ToStr(), "0")
    allBusy = NxOccupancy()
    NxOccupancyAdd(allBusy, 9, "a", 0, 3600)
    NxOccupancyAdd(allBusy, 9, "b", 0, 1800)
    NxOccupancyAdd(allBusy, 9, "c", 0, 3000)
    NxCheck(r, "pick: all busy and it must fit", NxPickCandidate([a, b, c], 0, allBusy, 1, invalid, true).ToStr(), "-1")
    NxCheck(r, "pick: all busy, the one that overlaps least", NxPickCandidate([a, b, c], 0, allBusy, 1, invalid, false).ToStr(), "1")
    NxCheck(r, "pick: a tie takes the earlier", NxPickCandidate([a, a], 0, allBusy, 1, invalid, false).ToStr(), "0")
    NxCheck(r, "pick: the first part's slot on elsewhere, the second does not jump ahead", NxPickCandidate([p1, p2, o], 0, NxBusyOn("1"), 1, invalid, true).ToStr(), "2")
    NxCheck(r, "pick: how long it runs from t decides (a 30 min day end)", NxPickCandidate([a, b], 0, NxBusyAt("a", 2000, 3000), 1, invalid, true, 0, 1800).ToStr(), "0")
    NxCheck(r, "pick: the first starts part way in", NxPickCandidate([a, b], 0, NxBusyAt("a", 3000, 3600), 1, invalid, true, 1800, 0).ToStr(), "0")
    longQueue = []
    for i = 0 to 9
        longQueue.Push(NxCrossItem("x" + i.ToStr(), 60))
    end for
    longBusy = NxOccupancy()
    for i = 0 to 8
        NxOccupancyAdd(longBusy, 9, "x" + i.ToStr(), 0, 3600)
    end for
    gatedBusy = NxOccupancy()
    NxOccupancyAdd(gatedBusy, 9, "a", 0, 3600, true)
    NxCheck(r, "pick: a gated channel gives way to an ungated one", NxPickCandidate([a, b, c], 0, NxBusyUngated("a"), 1, invalid, true, 0, 0, true).ToStr(), "1")
    NxCheck(r, "pick: a gated channel never gives way to another gated one", NxPickCandidate([a, b, c], 0, gatedBusy, 1, invalid, true, 0, 0, true).ToStr(), "0")
    NxCheck(r, "pick: an ungated channel gives way to a gated one", NxPickCandidate([a, b, c], 0, gatedBusy, 1, invalid, true, 0, 0, false).ToStr(), "1")
    NxCheck(r, "pick: looks at the first 8 only", NxPickCandidate(longQueue, 0, longBusy, 1, invalid, true).ToStr(), "-1")

    ' ── The channel order ───────────────────────────────────────────────────
    entries = [NxCrossEntry(5, false), NxCrossEntry(3, true), NxCrossEntry(4, false), NxCrossEntry(1, true), NxCrossEntry(2, false)]
    ids = []
    for each e in NxSortByLineupPriority(entries)
        ids.Push(e.channel.id.ToStr())
    end for
    NxCheck(r, "order: time-gated channels last, then by id", ids.Join(" "), "2 4 5 1 3")

    ' ── A lineup through NxManifestBlocks ───────────────────────────────────
    g = GetGlobalAA()
    g.nxTzOffsetSec = 0
    at& = 1792094400&
    pool = []
    for i = 0 to 29
        pool.Push({ ratingKey: "t" + i.ToStr(), type: "movie", title: "Film " + i.ToStr(), duration: 60, addedAt: 0 })
    end for
    ch1 = { id: 1, pool: pool }
    ch2 = { id: 2, pool: pool }
    ch3 = { id: 3, pool: pool }
    NxClearManifests()
    NxSetLineup([ch1, ch2, ch3])
    sets = []
    for each ch in [ch1, ch2, ch3]
        sets.Push(NxManifestBlocks(ch, ch.pool, at&))
    end for
    NxCheck(r, "lineup: three channels on one pool, no title on two at once", NxCrossDoubled(sets).ToStr(), "0")
    NxCheck(r, "lineup: each channel still has a whole day", NxCrossSpan(sets[2]).ToStr(), "86400")
    again = NxManifestBlocks(ch1, ch1.pool, at& + 600)
    NxCheck(r, "lineup: the stored day stands", FormatJson(NxCrossKeys(again)), FormatJson(NxCrossKeys(sets[0])))
    ' A channel the lineup doesn't carry packs after it, against it, and adds nothing to it.
    NxClearManifests()
    NxSetLineup([ch1, ch2])
    off = { id: 9, pool: pool }
    offBlocks = NxManifestBlocks(off, off.pool, at&)
    first = NxManifestBlocks(ch1, ch1.pool, at&)
    second = NxManifestBlocks(ch2, ch2.pool, at&)
    NxCheck(r, "lineup: the lineup's days are the same with a channel off the guide asked first", NxCrossDoubled([first, second]).ToStr(), "0")
    NxCheck(r, "lineup: the channel off the guide has a whole day", NxCrossSpan(offBlocks).ToStr(), "86400")
    NxClearManifests()
    NxSetLineup([ch1, ch2])
    first2 = NxManifestBlocks(ch1, ch1.pool, at&)
    NxManifestBlocks(off, off.pool, at&)
    NxCheck(r, "lineup: a channel off the guide changes no lineup channel's day", FormatJson(NxCrossKeys(first2)), FormatJson(NxCrossKeys(first)))
    ' A channel the lineup names twice counts once, at its first place: a second
    ' entry for it, over the same films in the other order, changes nobody's day.
    NxClearManifests()
    NxSetLineup([ch1, ch2])
    plain = NxManifestBlocks(ch2, ch2.pool, at&)
    plainOne = NxManifestBlocks(ch1, ch1.pool, at&)
    twicePool = []
    for i = 29 to 0 step -1
        twicePool.Push(pool[i])
    end for
    NxClearManifests()
    NxSetLineup([ch1, ch2, { id: 1, pool: twicePool }])
    twice = NxManifestBlocks(ch2, ch2.pool, at&)
    twiceOne = NxManifestBlocks(ch1, ch1.pool, at&)
    NxCheck(r, "lineup: a channel named twice leaves the others' days alone", FormatJson(NxCrossKeys(twice)), FormatJson(NxCrossKeys(plain)))
    NxCheck(r, "lineup: a channel named twice keeps its first entry's day", FormatJson(NxCrossKeys(twiceOne)), FormatJson(NxCrossKeys(plainOne)))
    ' The lineup's pack hands back every channel's day, stored or packed now.
    NxClearManifests()
    NxSetLineup([ch1, ch2])
    NxManifestBlocks(ch1, ch1.pool, at&)
    storedDays = NxPackLineupDay([{ channel: ch1, pool: pool, fp: NxPoolFingerprint(pool) }, { channel: ch2, pool: pool, fp: NxPoolFingerprint(pool) }], invalid, NxLocalDay(at&))
    NxCheck(r, "lineup: the pack returns the stored days too", (storedDays["1"].Count() > 0).ToStr() + " " + (storedDays["2"].Count() > 0).ToStr(), "true true")
    NxCheck(r, "gated: a channel with timeRestrictions", NxIsGated({ id: 1, timeRestrictions: { tvOnlyBefore: 0 } }).ToStr() + " " + NxIsGated({ id: 1 }).ToStr() + " " + NxIsGated({ id: 1, timeRestrictions: invalid }).ToStr(), "true false false")
    ' The guide schedules the very array that is the lineup, as LibraryTask does: a
    ' nested `for each` over one array stopped the outer loop on a TV.
    NxClearManifests()
    ordered = [ch1, ch2, ch3]
    NxSetLineup(ordered)
    guide = NxScheduleGuide(ordered, at&)
    NxCheck(r, "guide: every channel of the lineup it is given", guide.Count().ToStr(), "3")
    NxCheck(r, "guide: the last channel has its blocks", (guide[2].blocks.Count() > 24).ToStr(), "true")
    NxClearManifests()
    NxCheck(r, "lineup: a library load clears the lineup", (GetGlobalAA().nxLineup = invalid).ToStr(), "true")

    print "cross-channel cases (upstream pickCandidate, packLineupDay): "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

function NxCrossItem(key as String, minutes as Integer) as Object
    return { ratingKey: key, type: "movie", title: "Title " + key, duration: minutes, addedAt: 0 }
end function

function NxCrossEntry(id as Integer, gated as Boolean) as Object
    ch = { id: id }
    if gated then ch.timeRestrictions = { tvOnlyBefore: 0 }
    return { channel: ch, pool: [], fp: "" }
end function

' A title on air on an ungated channel, over the first hour.
function NxBusyUngated(key as String) as Object
    occ = NxOccupancy()
    NxOccupancyAdd(occ, 9, key, 0, 3600, false)
    return occ
end function

' A title's whole slot taken by another channel, over [startAt, endAt).
function NxBusyAt(key as String, startAt as Integer, endAt as Integer) as Object
    occ = NxOccupancy()
    NxOccupancyAdd(occ, 9, key, startAt, endAt)
    return occ
end function

function NxBusyOn(key as String) as Object
    return NxBusyAt(key, 0, 7200)
end function

function NxMarkText(mark as Dynamic) as String
    if mark = invalid then return "none"
    return mark.base + " " + mark.ordinal.ToStr()
end function

' The share of seconds with a title on two or more of these channels' days.
function NxCrossDoubled(sets as Object) as Integer
    byKey = {}
    byKey.SetModeCaseSensitive()
    doubled = 0
    for each blocks in sets
        for each b in blocks
            key = NxToStr(b.item.ratingKey)
            list = byKey[key]
            if list = invalid then
                list = []
                byKey[key] = list
            end if
            for each iv in list
                lo = b.startSec
                if iv[0] > lo then lo = iv[0]
                hi = b.endSec
                if iv[1] < hi then hi = iv[1]
                if hi > lo then doubled = doubled + (hi - lo)
            end for
            list.Push([b.startSec, b.endSec])
        end for
    end for
    return doubled
end function

function NxCrossSpan(blocks as Object) as Integer
    return blocks.Peek().endSec - blocks[0].startSec
end function

function NxCrossKeys(blocks as Object) as Object
    out = []
    for each b in blocks
        out.Push(NxToStr(b.item.ratingKey) + "@" + b.startSec.ToStr())
    end for
    return out
end function
