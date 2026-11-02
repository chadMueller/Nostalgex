' Daily 24h schedule builder, ported from Nostalgex.
'
' Copyright (c) 2024 Chad Mueller / Muell Haus Inc. (Nostalgex), MIT License.
' Port copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Source: upstream scripts/nostalgex-daily-manifest.js, which upstream holds
' bit-identical to the Apple TV's SchedulePoolOrdering.swift and
' DailyManifestScheduler.swift. A channel must air the same programme at the
' same second on Roku as on Apple TV and the web, so every function here is a
' line-for-line port, checked against tests/vectors/schedule.json. Don't
' improve the algorithm here; propose it upstream.
'
' 64-bit arithmetic. The RNG and premiere hash are unsigned 64-bit in Swift.
' BrightScript has only a signed LongInteger, so:
'   - multiply and add rely on two's-complement wraparound, which the vectors
'     confirm on device;
'   - shifts are built from multiply and divide (NxShl, NxShr), because the
'     << and >> operators are not trustworthy on LongInteger across runtimes;
'   - XOR, absent from the language, is (a or b) and not (a and b).
' Only the cache (upstream's localStorage layer) is left out. It lives with
' the caller, since storage on a Roku is a registry, not a key-value page.

' ── 64-bit helpers ──────────────────────────────────────────────────────────

function NxXor(a as LongInteger, b as LongInteger) as LongInteger
    return (a or b) and not (a and b)
end function

' Logical right shift by n, where p = 2^n (1 <= n <= 62).
function NxShr(x as LongInteger, p as LongInteger) as LongInteger
    if x >= 0 then return x \ p
    ' Unsigned x is 2^63 + (x and MAX); shift each part. 2^62 \ (p\2) = 2^(63-n).
    return ((x and &h7FFFFFFFFFFFFFFF&) \ p) + (&h4000000000000000& \ (p \ 2))
end function

' Left shift by n, where p = 2^n (1 <= n <= 62). Bits shifted past 63 are
' dropped explicitly, so no overflow is involved.
function NxShl(x as LongInteger, p as LongInteger) as LongInteger
    top = &h4000000000000000& \ (p \ 2)
    r = (x and (top - 1)) * p
    if (x and top) <> 0 then r = r or &h8000000000000000&
    return r
end function

' Unsigned x mod n, for n > 0. (Not "m": that name is BrightScript's this.)
function NxUMod(x as LongInteger, n as LongInteger) as LongInteger
    if x >= 0 then return x mod n
    return ((x and &h7FFFFFFFFFFFFFFF&) mod n + (&h7FFFFFFFFFFFFFFF& mod n) + 1) mod n
end function

' ── Seeded RNG: mirrors Swift SeededRNG (splitmix64-seeded xorshift64) ──────

function NxSplitmix64(x as LongInteger) as LongInteger
    z = x + &h9E3779B97F4A7C15&
    z = NxXor(z, NxShr(z, &h40000000&)) * &hBF58476D1CE4E5B9&
    z = NxXor(z, NxShr(z, &h8000000&)) * &h94D049BB133111EB&
    return NxXor(z, NxShr(z, &h80000000&))
end function

function NxSeededRng(seed as LongInteger) as Object
    state = NxSplitmix64(seed)
    if state = 0 then state = 1&
    return { state: state }
end function

function NxRngNext(rng as Object) as LongInteger
    s = rng.state
    s = NxXor(s, NxShl(s, &h2000&))
    s = NxXor(s, NxShr(s, &h80&))
    s = NxXor(s, NxShl(s, &h20000&))
    rng.state = s
    return s
end function

' Mirrors Swift stdlib RandomNumberGenerator.next(upperBound:), Lemire's
' nearly-divisionless draw. The high and low 64 bits of next() * u are built
' from 32-bit halves; u < 2^31 keeps every partial product below 2^63.
' The result is below upperBound, so it returns as an Integer: array indexes
' must be one.
function NxRngBounded(rng as Object, upperBound as LongInteger) as Integer
    u = upperBound
    x = NxRngNext(rng)
    pl = (x and &hFFFFFFFF&) * u
    ph = NxShr(x, &h100000000&) * u + pl \ &h100000000&
    low = NxShl(ph and &hFFFFFFFF&, &h100000000&) or (pl and &hFFFFFFFF&)
    if low >= 0 and low < u then
        t = NxUMod(-u, u)
        while low >= 0 and low < t
            x = NxRngNext(rng)
            pl = (x and &hFFFFFFFF&) * u
            ph = NxShr(x, &h100000000&) * u + pl \ &h100000000&
            low = NxShl(ph and &hFFFFFFFF&, &h100000000&) or (pl and &hFFFFFFFF&)
        end while
    end if
    return ph \ &h100000000&
end function

' Mirrors Swift stdlib MutableCollection.shuffle(using:). In place.
sub NxSwiftShuffle(arr as Object, rng as Object)
    amount = arr.Count()
    currentIndex = 0
    while amount > 1
        random = NxRngBounded(rng, amount)
        amount = amount - 1
        j = currentIndex + random
        tmp = arr[currentIndex]
        arr[currentIndex] = arr[j]
        arr[j] = tmp
        currentIndex = currentIndex + 1
    end while
end sub

function NxDuration(item as Object) as Integer
    d = item.duration
    if d = invalid then return 0
    return d
end function

' ── Interleave: shows in shuffled groups, at most two episodes in a row ─────

function NxInterleaveByShow(items as Object, seed as Integer, dayNumber as Integer) as Object
    if items.Count() <= 1 then
        copy = []
        copy.Append(items)
        return copy
    end if

    ' Episodes group on title, which is the show title. Case matters, as in Swift.
    groups = {}
    groups.SetModeCaseSensitive()
    order = []
    for each item in items
        if item.type = "episode" then key = item.title else key = "movie_" + item.ratingKey
        if not groups.DoesExist(key) then
            groups[key] = []
            order.Push(key)
        end if
        groups[key].Push(item)
    end for

    ' Long before adding: Abs() returns a Float, and the sum can pass 2^31.
    s& = seed
    if s& < 0 then s& = -s&
    rng = NxSeededRng(s& + 1 + dayNumber)

    orderedGroups = []
    for each key in order
        NxSwiftShuffle(groups[key], rng)
        orderedGroups.Push(groups[key])
    end for
    NxSwiftShuffle(orderedGroups, rng)

    maxConsecutive = 2
    result = []
    positions = []
    for i = 0 to orderedGroups.Count() - 1
        positions.Push(0)
    end for
    groupCount = orderedGroups.Count()
    groupIndex = 0
    exhausted = 0

    while exhausted < groupCount
        attempts = 0
        while positions[groupIndex] >= orderedGroups[groupIndex].Count()
            groupIndex = (groupIndex + 1) mod groupCount
            attempts = attempts + 1
            if attempts > groupCount then exit while
        end while
        if attempts > groupCount then exit while

        group = orderedGroups[groupIndex]
        at = positions[groupIndex]
        take = group.Count() - at
        if take > maxConsecutive then take = maxConsecutive
        for i = 0 to take - 1
            result.Push(group[at + i])
        end for
        positions[groupIndex] = at + take
        if positions[groupIndex] >= group.Count() then exhausted = exhausted + 1
        groupIndex = (groupIndex + 1) mod groupCount
    end while

    return result
end function

' ── Premieres: this week's additions move to a prime-time slot ──────────────

' Slot in 19:00-24:00, 15-minute steps, per (channel, item): FNV-1a over the
' ratingKey's UTF-8 bytes, then the murmur3 finalizer.
function NxPremiereOffset(channelId as Integer, ratingKey as String) as Integer
    anchor = 19 * 3600
    slots = 20& ' 5h spread / 15min slots
    x& = channelId
    x = x& + &h9E3779B97F4A7C15&
    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(ratingKey)
    for each b in bytes
        x = NxXor(x, b) * &h00000100000001B3&
    end for
    x = NxXor(x, NxShr(x, &h200000000&))
    x = x * &hFF51AFD7ED558CCD&
    x = NxXor(x, NxShr(x, &h200000000&))
    return anchor + NxUMod(x, slots) * 900
end function

function NxPromoteRecentlyAdded(items as Object, dayStartUnix as Integer, channelId as Integer, windowSeconds = invalid as Dynamic) as Object
    if items.Count() <= 1 then return items
    window = 7 * 86400
    if windowSeconds <> invalid then window = windowSeconds
    cutoff = dayStartUnix - window

    recent = []
    rest = []
    for each item in items
        addedAt = item.addedAt
        if addedAt = invalid then addedAt = 0
        if addedAt > 0 and addedAt >= cutoff then recent.Push(item) else rest.Push(item)
    end for
    if recent.Count() = 0 or recent.Count() >= items.Count() then return items

    ' Ascending by target slot, ratingKey breaking ties. Insertion sort: lists
    ' are a handful of items, and it is stable like the JS sort.
    targets = []
    for each item in recent
        t = { item: item, offset: NxPremiereOffset(channelId, item.ratingKey) }
        i = targets.Count()
        targets.Push(t)
        while i > 0 and NxTargetBefore(t, targets[i - 1])
            targets[i] = targets[i - 1]
            i = i - 1
        end while
        targets[i] = t
    end for

    out = []
    out.Append(rest)
    for each target in targets
        insertAt = out.Count()
        cumulativeSeconds = 0
        for index = 0 to out.Count() - 1
            if cumulativeSeconds >= target.offset then
                insertAt = index
                exit for
            end if
            cumulativeSeconds = cumulativeSeconds + NxDuration(out[index]) * 60
        end for
        NxArrayInsert(out, insertAt, target.item)
    end for
    return out
end function

function NxTargetBefore(a as Object, b as Object) as Boolean
    if a.offset <> b.offset then return a.offset < b.offset
    return a.item.ratingKey < b.item.ratingKey
end function

sub NxArrayInsert(arr as Object, index as Integer, value as Dynamic)
    arr.Push(value)
    i = arr.Count() - 1
    while i > index
        arr[i] = arr[i - 1]
        i = i - 1
    end while
    arr[index] = value
end sub

' ── Sequel parts: a multi-part story airs in order, back to back ────────────

function NxGroupSequelParts(items as Object) as Object
    if items.Count() <= 1 then return items

    ' Anchored to the end of the title, so mid-title words never match.
    marker = CreateObject("roRegex", "^(.*?)[\s:,-]+(?:part|pt\.?)\s*([0-9]{1,2})\s*$", "i")
    groups = {}
    groups.SetModeCaseSensitive()
    bases = []
    for index = 0 to items.Count() - 1
        it = items[index]
        if it.type = "movie" then
            title = it.title
            if title = invalid then title = ""
            match = marker.Match(title)
            if match.Count() = 3 then
                base = LCase(match[1]).Trim()
                if base <> "" then
                    if not groups.DoesExist(base) then
                        groups[base] = []
                        bases.Push(base)
                    end if
                    groups[base].Push({ index: index, ordinal: match[2].ToInt() })
                end if
            end if
        end if
    end for

    ' Only real multi-part stories move; a lone "Part 2" stays put.
    pulled = {}
    insertions = {}
    for each base in bases
        family = groups[base]
        if family.Count() > 1 then
            anchor = family[0].index
            ordered = []
            for each mark in family
                if mark.index < anchor then anchor = mark.index
                pulled[mark.index.ToStr()] = true
                ' Stable insertion by ordinal.
                i = ordered.Count()
                ordered.Push(mark)
                while i > 0 and ordered[i - 1].ordinal > mark.ordinal
                    ordered[i] = ordered[i - 1]
                    i = i - 1
                end while
                ordered[i] = mark
            end for
            members = []
            for each mark in ordered
                members.Push(items[mark.index])
            end for
            insertions[anchor.ToStr()] = members
        end if
    end for
    if insertions.Count() = 0 then return items

    result = []
    for index = 0 to items.Count() - 1
        key = index.ToStr()
        if insertions.DoesExist(key) then
            result.Append(insertions[key])
        else if not pulled.DoesExist(key) then
            result.Push(items[index])
        end if
    end for
    return result
end function

' ── Across channels: one title on one channel at a time ─────────────────────
' Mirrors DailyManifestScheduler's lineup packing and ScheduleOccupancy
' (nostalgex-daily-manifest.js makeOccupancy, sequelMark, waitsForEarlierPart,
' pickCandidate). A day is packed for the whole lineup at once
' (NxPackLineupDay, source/guide/Lineup.brs); the pieces are here.

' How far down its running order a channel looks for a programme no other
' channel has on in the same slot (DailyManifestScheduler.lookahead).
function NxLookahead() as Integer
    return 8
end function

' What the other channels have on, by title: ratingKey -> [{ ch, s, e }].
' Mirrors ScheduleOccupancy.
function NxOccupancy() as Object
    byKey = {}
    byKey.SetModeCaseSensitive()
    return { byKey: byKey }
end function

sub NxOccupancyAdd(occupancy as Object, channelId as Integer, ratingKey as String, startSec as Integer, endSec as Integer)
    if not (endSec > startSec) then return
    list = occupancy.byKey[ratingKey]
    if list = invalid then
        list = []
        occupancy.byKey[ratingKey] = list
    end if
    list.Push({ ch: channelId, s: startSec, e: endSec })
end sub

' The seconds of [startSec, endSec) that some other channel already airs the
' title for.
function NxOccupancyOverlap(occupancy as Object, ratingKey as String, startSec as Integer, endSec as Integer, channelId as Integer) as Integer
    list = occupancy.byKey[ratingKey]
    if list = invalid then return 0
    sec = 0
    for each x in list
        if x.ch <> channelId then
            lo = startSec
            if x.s > lo then lo = x.s
            hi = endSec
            if x.e < hi then hi = x.e
            if hi > lo then sec = sec + (hi - lo)
        end if
    end for
    return sec
end function

' The story and part of a multi-part film ("... Part 2"), or invalid: the same
' test as NxGroupSequelParts, as sequelMark.
function NxSequelMark(item as Object) as Dynamic
    if item.type <> "movie" then return invalid
    g = GetGlobalAA()
    if g.nxSequelRegex = invalid then g.nxSequelRegex = CreateObject("roRegex", "^(.*?)[\s:,-]+(?:part|pt\.?)\s*([0-9]{1,2})\s*$", "i")
    title = item.title
    if title = invalid then title = ""
    match = g.nxSequelRegex.Match(title)
    if match.Count() <> 3 then return invalid
    base = LCase(match[1]).Trim()
    if base = "" then return invalid
    return { base: base, ordinal: match[2].ToInt() }
end function

' A later part may not jump ahead of an earlier part of the same story still
' waiting before it.
function NxWaitsForEarlierPart(queue as Object, i as Integer) as Boolean
    mark = NxSequelMark(queue[i])
    if mark = invalid then return false
    for k = 0 to i - 1
        other = NxSequelMark(queue[k])
        if other <> invalid then
            if other.base = mark.base and other.ordinal < mark.ordinal then return true
        end if
    end for
    return false
end function

' Which of the first NxLookahead() programmes in `queue` airs at t: the first
' one no other channel has on during its slot; failing that, -1 when mustFit
' (the caller has something else to try), else the one that overlaps least (the
' earliest of those). How long candidate i runs from t is its length, less
' firstOffsetSec for the first, and at most capSec when that is above 0 (the
' day's end). avoidKey (the title that just played here) is passed over while
' there is anything else, and a later part of a story never goes ahead of an
' earlier one waiting before it. With no occupancy, or nothing on elsewhere,
' this is always 0: the channel's own order. Mirrors
' DailyManifestScheduler.pickCandidate.
function NxPickCandidate(queue as Object, t as Integer, occupancy as Dynamic, channelId as Integer, avoidKey as Dynamic, mustFit as Boolean, firstOffsetSec = 0 as Integer, capSec = 0 as Integer) as Integer
    n = queue.Count()
    if n > NxLookahead() then n = NxLookahead()
    best = -1
    bestOverlap = 0
    for i = 0 to n - 1
        item = queue[i]
        skip = false
        if n > 1 and avoidKey <> invalid then
            if item.ratingKey = avoidKey then skip = true
        end if
        if not skip and i > 0 then
            if NxWaitsForEarlierPart(queue, i) then skip = true
        end if
        if not skip then
            ov = 0
            if occupancy <> invalid then
                play = NxDuration(item) * 60
                if i = 0 then play = play - firstOffsetSec
                if capSec > 0 and play > capSec then play = capSec
                ov = NxOccupancyOverlap(occupancy, item.ratingKey, t, t + play, channelId)
            end if
            if ov = 0 then return i
            if best < 0 or ov < bestOverlap then
                bestOverlap = ov
                best = i
            end if
        end if
    end for
    if mustFit then return -1
    if best >= 0 then return best
    return 0
end function

' ── One day's schedule ──────────────────────────────────────────────────────

' Returns [{ ratingKey, startSec, endSec }] covering dayStartSec to dayEndSec.
' dayEndSec is the next local midnight (NxStartOfNextLocalDaySec), not
' dayStartSec + 86,400: a 25-hour day packed for 24 left its last hour empty,
' and a 23-hour one ran an hour into the next day.
' yesterdayAired is an AA used as a set of ratingKeys; yesterdayLastRatingKey
' is a String or invalid. occupancy (NxOccupancy) is what the other channels
' of the lineup have on today, or invalid when this channel packs alone: then
' every pick is the first, as before. Mirrors DailyManifestScheduler.packDay.
function NxPackDay(pool as Object, dayStartSec as Integer, dayEndSec as Integer, dayNumber as Integer, channelId as Integer, yesterdayAired as Object, isPremiereChannel as Boolean, yesterdayLastRatingKey as Dynamic, occupancy = invalid as Dynamic) as Object
    totalPoolSec = 0&
    for each item in pool
        totalPoolSec = totalPoolSec + NxDuration(item) * 60
    end for
    if totalPoolSec <= 0 then return []

    unplayed = []
    for each item in pool
        if not yesterdayAired.DoesExist(item.ratingKey) then unplayed.Push(item)
    end for
    ' Interleave, then premieres to prime time, then reunite multi-part stories,
    ' in that order, so a just-added Part 1 drags its Part 2 with it.
    ordered = NxInterleaveByShow(unplayed, channelId, dayNumber)
    if isPremiereChannel then ordered = NxPromoteRecentlyAdded(ordered, dayStartSec, channelId)
    ordered = NxGroupSequelParts(ordered)

    ' Cross-day seam: don't open with the title that closed yesterday.
    if yesterdayLastRatingKey <> invalid and ordered.Count() > 1 then
        if ordered[0].ratingKey = yesterdayLastRatingKey then ordered.Push(ordered.Shift())
    end if

    blocks = []
    t = dayStartSec
    ' In the channel's order, except that a programme another channel has on
    ' in the same slot waits for a later one (NxPickCandidate). It stays in
    ' the queue, so it still airs today if the day has room, and counts as
    ' unplayed tomorrow if not. When nothing waiting fits, the day goes on
    ' with the filler loop below, which holds the whole pool.
    queue = []
    for each item in ordered
        if NxDuration(item) > 0 then queue.Push(item)
    end for
    while queue.Count() > 0 and t < dayEndSec
        j = NxPickCandidate(queue, t, occupancy, channelId, invalid, true)
        if j < 0 then exit while
        item = queue[j]
        queue.Delete(j)
        dur = NxDuration(item) * 60
        blocks.Push({ ratingKey: item.ratingKey, startSec: t, endSec: t + dur })
        t = t + dur
    end while

    if t < dayEndSec then
        ' Filler loop: sequels only, no premiere promotion, as on tvOS.
        orderedFull = NxGroupSequelParts(NxInterleaveByShow(pool, channelId, dayNumber + 1))
        ' Math.floor, exactly: Int() would round a pool past 2^24 seconds to float32.
        goldenShift = NxFloorDouble(totalPoolSec * 0.6180339887#)
        day& = dayNumber
        offsetSec = (day& * goldenShift) mod totalPoolSec

        elapsed = 0&
        cycleIndex = 0
        offsetInItem = offsetSec
        for i = 0 to orderedFull.Count() - 1
            d = NxDuration(orderedFull[i]) * 60
            if elapsed + d > offsetSec then
                cycleIndex = i
                offsetInItem = offsetSec - elapsed
                exit for
            end if
            elapsed = elapsed + d
        end for

        ' Wraparound seam: the cycle can land on the item that just played.
        if orderedFull.Count() > 1 then
            lastPlayed = yesterdayLastRatingKey
            if blocks.Count() > 0 then lastPlayed = blocks.Peek().ratingKey
            if lastPlayed <> invalid then
                if orderedFull[cycleIndex].ratingKey = lastPlayed then
                    cycleIndex = (cycleIndex + 1) mod orderedFull.Count()
                    offsetInItem = 0
                end if
            end if
        end if

        ' The loop as a queue from the cycle's start: what airs goes to the
        ' back, so with nothing on elsewhere this is the cycle in order. The
        ' first programme starts part way in (offsetInItem) only if it airs
        ' first; one picked ahead of it starts at 0.
        cycle = []
        for i = cycleIndex to orderedFull.Count() - 1
            if NxDuration(orderedFull[i]) > 0 then cycle.Push(orderedFull[i])
        end for
        for i = 0 to cycleIndex - 1
            if NxDuration(orderedFull[i]) > 0 then cycle.Push(orderedFull[i])
        end for
        first = true
        while t < dayEndSec and cycle.Count() > 0
            remainingDay% = dayEndSec - t
            offFirst% = 0
            if first then offFirst% = offsetInItem
            lastKey = yesterdayLastRatingKey
            if blocks.Count() > 0 then lastKey = blocks.Peek().ratingKey
            j = NxPickCandidate(cycle, t, occupancy, channelId, lastKey, false, offFirst%, remainingDay%)
            item = cycle[j]
            playSec = NxDuration(item) * 60
            if j = 0 and first then playSec = playSec - offFirst%
            if playSec > remainingDay% then playSec = remainingDay%
            cycle.Delete(j)
            cycle.Push(item)
            first = false
            blocks.Push({ ratingKey: item.ratingKey, startSec: t, endSec: t + playSec })
            t = t + playSec
        end while
    end if

    return blocks
end function
