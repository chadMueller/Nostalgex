' Which channels the guide shows, in what order, and what each one airs.
'
' Copyright (c) 2024 Chad Mueller / Muell Haus Inc. (Nostalgex), MIT License.
' Port copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Source: plex-tuner.html getTimeFilteredPool,
' staticChannelIDsForPoolBuild, applyBundleFilter, sortChannelsForGuide,
' buildChannelSchedule, and nostalgex-daily-manifest.js getManifestBlocks
' and pool fingerprint; its day helpers are in source/schedule/LocalTime.brs.
' Checked against tests/vectors/lineup.json. Pools stay in library order,
' unshuffled, as the Apple TV's loaders build them (web tuner 1.0.7).
'
' Upstream clears its per-day schedule cache on every library load, which on
' the web is every page load, so the cache only ever lives for a session.
' Here it lives in memory (NxManifestCache) for the same reason, and the
' library load clears it the same way.

' ── Pools ───────────────────────────────────────────────────────────────────

' JS ToInt32.
function NxToInt32(x as LongInteger) as LongInteger
    r = x mod 4294967296&
    if r < 0 then r = r + 4294967296&
    if r >= 2147483648& then r = r - 4294967296&
    return r
end function

' The local hour the WATERSHED gate holds its ratings until: 9 PM, the window
' VHS VAULT's own blockRatings uses (Channel.watershedHour).
function NxWatershedHour() as Integer
    return 21
end function

' The US labels WATERSHED holds (Channel.watershedRatings). GB-15 and GB-18
' read as R or TV-MA through NxUsContentRating, so they aren't listed.
function NxWatershedRatings() as Object
    return ["R", "NC-17", "TV-MA"]
end function

' Mirrors getTimeFilteredPool at a local hour (0-23). watershed is the
' Settings switch (WATERSHED): with it on, a channel without blockRatings of
' its own drops its R, NC-17 and TV-MA titles before 9 PM, after its own rules
' and with no fallback, so a channel may go empty (Channel.filteredPool).
function NxTimeFilteredPool(channel as Object, pool as Object, hour as Integer, watershed = false as Boolean) as Object
    out = pool
    tr = channel.timeRestrictions
    if type(tr) = "roAssociativeArray" then
        out = NxOwnTimeRules(tr, out, hour)
        if out = invalid then return []
    end if
    if watershed and not NxHasOwnBlockRatings(channel) and hour < NxWatershedHour() then
        held = NxWatershedRatings()
        kept = []
        for each it in out
            if not NxHasValue(held, NxUsContentRating(it.contentRating, it.type)) then kept.Push(it)
        end for
        out = kept
    end if
    return out
end function

' Whether the channel's pool is empty at this hour only because WATERSHED
' took every title, not because it has none (Channel.isWatershedHold).
function NxIsWatershedHold(channel as Object, pool as Object, hour as Integer, watershed as Boolean) as Boolean
    if not watershed or pool = invalid then return false
    if pool.Count() = 0 or NxHasOwnBlockRatings(channel) then return false
    if hour >= NxWatershedHour() then return false
    return NxTimeFilteredPool(channel, pool, hour, watershed).Count() = 0
end function

' VHS VAULT's shape: blockRatings of its own, which WATERSHED leaves alone.
function NxHasOwnBlockRatings(channel as Object) as Boolean
    tr = channel.timeRestrictions
    if type(tr) <> "roAssociativeArray" then return false
    return type(tr.blockRatings) = "roAssociativeArray"
end function

' A channel's own timeRestrictions at a local hour; invalid when
' onlyAfterHour takes the channel off the air.
function NxOwnTimeRules(tr as Object, pool as Object, hour as Integer) as Dynamic
    out = pool
    br = tr.blockRatings
    if type(br) = "roAssociativeArray" then
        blocked = false
        if br.blockBefore <> invalid then
            if hour < br.blockBefore then blocked = true
        end if
        if br.blockAfter <> invalid then
            if hour >= br.blockAfter then blocked = true
        end if
        if blocked then
            filtered = []
            for each it in out
                ' A rating from another country counts as its US label: GB-18 waits like R.
                if not NxHasValue(NxList(br.ratings), NxUsContentRating(it.contentRating, it.type)) then filtered.Push(it)
            end for
            if filtered.Count() >= 2 then out = filtered
        end if
    end if

    if tr.tvOnlyBefore <> invalid then
        if hour < tr.tvOnlyBefore then
            episodes = []
            for each it in out
                if it.type = "episode" then episodes.Push(it)
            end for
            if episodes.Count() >= 2 then out = episodes
        end if
    end if

    if tr.onlyAfterHour <> invalid then
        if hour < tr.onlyAfterHour then return invalid
    end if
    return out
end function

' ── Lineup ──────────────────────────────────────────────────────────────────

' Channel ids whose pools get built: those in switched-on bundles, in any
' month (staticChannelIDsForPoolBuild, as on any load after the first). A
' seasonal package's season decides only the invite and the guide's lead
' (SeasonalPrompt.brs); upstream 8160f04 stopped it gating the build, so one
' switched on outside its season kept its channels.
function NxPoolChannelIds(config as Object, enabledBundles as Object) as Object
    ids = {}
    for each b in NxList(config.bundles)
        if NxHasValue(enabledBundles, b.id) then
            for each id in NxList(b.channelIDs)
                ids[id.ToStr()] = true
            end for
        end if
    end for
    return ids
end function

' The guide's channels, in guide order: those in switched-on bundles
' (applyBundleFilter) and with enough items, seasonal packages that are on
' and in season first (seasonalLeadIDs), the rest by number
' (sortChannelsForGuide). `channels` are channels.json entries with an
' `enabled` flag set; `now` a local date for NxIsInSeason.
function NxGuideOrder(config as Object, channels as Object, enabledBundles as Object, now as Object) as Object
    inBundles = {}
    for each b in NxList(config.bundles)
        if NxHasValue(enabledBundles, b.id) then
            for each id in NxList(b.channelIDs)
                inBundles[id.ToStr()] = true
            end for
        end if
    end for
    lead = []
    for each id in NxSeasonalLeadIds(config.bundles, enabledBundles, now)
        if not NxHasValue(lead, id) then lead.Push(id)
    end for

    leading = []
    for each id in lead
        for each ch in channels
            if ch.id = id and inBundles.DoesExist(ch.id.ToStr()) and ch.enabled then leading.Push(ch)
        end for
    end for
    rest = []
    for each ch in channels
        if inBundles.DoesExist(ch.id.ToStr()) and ch.enabled and not NxHasValue(lead, ch.id) then
            ' Stable insertion by number (chNum: number, else id).
            i = rest.Count()
            rest.Push(ch)
            while i > 0 and NxChNum(rest[i - 1]) > NxChNum(ch)
                rest[i] = rest[i - 1]
                i = i - 1
            end while
            rest[i] = ch
        end if
    end for
    leading.Append(rest)
    return leading
end function

function NxChNum(ch as Object) as Integer
    if NxTruthy(ch.number) then return ch.number
    return ch.id
end function

' ── Schedule ────────────────────────────────────────────────────────────────

' Mirrors poolFingerprint: a 32-bit string hash of the sorted ratingKeys.
function NxPoolFingerprint(pool as Object) as String
    keys = []
    for each it in pool
        keys.Push(NxToStr(it.ratingKey))
    end for
    keys.Sort()
    ' Over the bytes, in one pass: Mid() on a long string is slow enough that a
    ' character loop made a 1,000-item channel take most of a minute. Bytes
    ' equal JS UTF-16 code units for the ASCII ratingKeys Plex uses.
    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(keys.Join(","))
    ' Kept unsigned mod 2^32 inside the loop and made signed once at the end,
    ' which gives what ToInt32 at every step would: a call per byte was most
    ' of the cost.
    h& = 0
    for each c in bytes
        h& = (h& * 31 + c) mod 4294967296&
    end for
    return NxToInt32(h&).ToStr()
end function

' The session's schedule cache: channelId_dayKey -> { fp, blocks }.
function NxManifestCache() as Object
    g = GetGlobalAA()
    if g.nxManifests = invalid then g.nxManifests = {}
    return g.nxManifests
end function

' A library load starts over: no stored days, and no lineup until the new
' one's pools are scheduled (NxSetLineup), so the last build's pools aren't
' held while the next is built.
sub NxClearManifests()
    g = GetGlobalAA()
    g.nxManifests = {}
    g.nxLineup = invalid
end sub

' What depends only on a pool: its playable items, their lookup and its
' fingerprint, { valid, lookup, fp (invalid for none) }. `memo`, when given, holds it
' from an earlier call with the same pool: the fingerprint alone took most of a
' 30 s re-check at 120 channels.
function NxPoolPrepare(pool as Object, memo = invalid as Dynamic) as Object
    if memo <> invalid and memo.fp <> invalid then return { valid: memo.valid, lookup: memo.lookup, fp: memo.fp }
    valid = []
    lookup = {}
    lookup.SetModeCaseSensitive()
    for each it in pool
        if it <> invalid and NxDuration(it) > 0 then
            valid.Push(it)
            lookup[NxToStr(it.ratingKey)] = it
        end if
    end for
    fp = invalid
    if valid.Count() > 0 then fp = NxPoolFingerprint(valid)
    if memo <> invalid then
        memo.valid = valid
        memo.lookup = lookup
        memo.fp = fp
    end if
    return { valid: valid, lookup: lookup, fp: fp }
end function

' The day's blocks for a channel as [{ item, startSec, endSec }]. Mirrors
' getManifestBlocks: reuse the day's schedule while the pool is unchanged,
' otherwise pack the day for the whole lineup (NxSetLineup) at once, so one
' title is on one channel at a time, skipping what aired yesterday. A channel
' the lineup doesn't carry packs after it, against it.
' `memo`, when given, holds what depends only on the pool from an earlier call
' with the same pool (NxPoolPrepare).
function NxManifestBlocks(channel as Object, pool as Object, atSec as LongInteger, memo = invalid as Dynamic) as Object
    prepared = NxPoolPrepare(pool, memo)
    valid = prepared.valid
    lookup = prepared.lookup
    fp = prepared.fp
    if valid.Count() = 0 then return []

    day = NxLocalDay(atSec)
    cache = NxManifestCache()
    key = channel.id.ToStr() + "_" + day.dayKey
    cached = cache[key]
    if cached = invalid or cached.fp <> fp then
        ' Not stored. This channel takes its place in the lineup with the pool
        ' it was asked with; one the guide doesn't carry packs after the
        ' lineup, against it, so it never changes what the guide's channels air.
        own = { channel: channel, pool: valid, fp: fp }
        entries = []
        at = -1
        ' By index: the guide's `for each` over its channels is this very array,
        ' and a nested `for each` over the same array shares its place on a TV (the
        ' outer loop stopped after the first channel).
        ' A channel the lineup names twice counts once, at its first place, as
        ' the web and the Apple TV count it.
        seen = {}
        lineup = NxList(GetGlobalAA().nxLineup)
        for li = 0 to lineup.Count() - 1
            lc = lineup[li]
            lcKey = lc.id.ToStr()
            if not seen.DoesExist(lcKey) then
                seen[lcKey] = true
                if lc.id = channel.id then
                    at = entries.Count()
                    entries.Push(own)
                else
                    ws = NxWatershedSet()
                    lp = NxPoolPrepare(NxTimeFilteredPool(lc, lc.pool, day.hour, ws), NxPoolMemo(lc, day.hour, ws))
                    if lp.valid.Count() > 0 then entries.Push({ channel: lc, pool: lp.valid, fp: lp.fp })
                end if
            end if
        end for
        extra = invalid
        if at < 0 then extra = own
        packedBy = NxPackLineupDay(entries, extra, day)
        cache = NxManifestCache()
        cached = cache[key]
        if cached = invalid then cached = { fp: fp, blocks: NxList(packedBy[channel.id.ToStr()]) }
    end if

    out = []
    for each b in cached.blocks
        it = lookup[b.ratingKey]
        if it <> invalid then out.Push({ item: it, startSec: b.startSec, endSec: b.endSec })
    end for
    return out
end function

' The order channels claim programmes in: channels whose pool changes with the
' hour (timeRestrictions) last, so the others' days never depend on when a device
' first built them; then by channel id, so the lowest keeps a title, as
' resolveConflicts does. A stable insertion sort; a new list. Mirrors
' DailyManifestScheduler.lineupPriority.
function NxSortByLineupPriority(entries as Object) as Object
    out = []
    for each e in entries
        i = out.Count()
        out.Push(e)
        while i > 0 and NxLineupBefore(e, out[i - 1])
            out[i] = out[i - 1]
            i = i - 1
        end while
        out[i] = e
    end for
    return out
end function

function NxLineupBefore(a as Object, b as Object) as Boolean
    ra = 0
    rb = 0
    if NxIsGated(a.channel) then ra = 1
    if NxIsGated(b.channel) then rb = 1
    if ra <> rb then return ra < rb
    return a.channel.id < b.channel.id
end function

' A channel whose pool changes with the hour (timeRestrictions), which packs
' after the rest and gives way to them but never to another like it. Mirrors
' Channel.timeRestrictions != nil.
function NxIsGated(channel as Object) as Boolean
    return type(channel.timeRestrictions) = "roAssociativeArray"
end function

' The stored day's blocks ([] if none), whatever pool packed them.
function NxStoredBlocks(cache as Object, channelId as Integer, dayKey as String) as Object
    stored = cache[channelId.ToStr() + "_" + dayKey]
    if stored = invalid then return []
    return stored.blocks
end function

' Packs one local day for the lineup's channels whose day isn't stored yet,
' together, so no title is on two of them at once. Channels pack in priority
' order (NxSortByLineupPriority): each one's day is its own running order
' (NxPackDay) except where a programme is already on another channel in that
' slot. Days already stored, and the programmes that run over from the day
' before, are fixed: what airs now never moves because another channel's pool
' changed. Writes every day it packs into the session cache. Mirrors
' DailyManifestScheduler.packLineupDay.
' entries: [{ channel, pool (playable items), fp }], every pool non-empty.
' extra: one more { channel, pool, fp } that is not in the guide, packed after
' the lineup against it and seen by nothing, or invalid. day: NxLocalDay.
' Returns channel id (text) -> its day's blocks, stored or packed now.
function NxPackLineupDay(entries as Object, extra as Dynamic, day as Object) as Object
    dayEndSec = NxStartOfNextLocalDaySec(day.dayStartSec)
    yesterdayKey = NxPreviousLocalDayKey(day.dayStartSec)
    cache = NxManifestCache()
    occupancy = NxOccupancy()
    packedBy = {}
    all = NxSortByLineupPriority(entries)
    if extra <> invalid then all.Push(extra)
    yesterday = {}
    for each entry in all
        id = entry.channel.id
        prev = NxStoredBlocks(cache, id, yesterdayKey)
        yesterday[id.ToStr()] = prev
        ' What runs past midnight from yesterday is on air today too (the
        ' guide's channels' only: one off the guide is seen by nothing).
        if extra = invalid or id <> extra.channel.id then
            for each b in prev
                if b.endSec > day.dayStartSec then NxOccupancyAdd(occupancy, id, b.ratingKey, b.startSec, b.endSec, NxIsGated(entry.channel))
            end for
        end if
    end for
    toPack = []
    for each entry in all
        id = entry.channel.id
        cached = cache[id.ToStr() + "_" + day.dayKey]
        if cached <> invalid and cached.fp = entry.fp then
            if extra = invalid or id <> extra.channel.id then
                for each b in cached.blocks
                    NxOccupancyAdd(occupancy, id, b.ratingKey, b.startSec, b.endSec, NxIsGated(entry.channel))
                end for
            end if
            packedBy[id.ToStr()] = cached.blocks
        else
            toPack.Push(entry)
        end if
    end for
    for each entry in toPack
        channel = entry.channel
        prev = yesterday[channel.id.ToStr()]
        aired = {}
        aired.SetModeCaseSensitive()
        last = invalid
        for each b in prev
            aired[b.ratingKey] = true
        end for
        if prev.Count() > 0 then last = prev.Peek().ratingKey
        packed = NxPackDay(entry.pool, day.dayStartSec, dayEndSec, day.dayNumber, channel.id, aired, NxTruthy(channel.isPremiereChannel), last, occupancy, NxIsGated(channel))
        cache[channel.id.ToStr() + "_" + day.dayKey] = { fp: entry.fp, blocks: packed }
        packedBy[channel.id.ToStr()] = packed
        if extra = invalid or channel.id <> extra.channel.id then
            for each b in packed
                NxOccupancyAdd(occupancy, channel.id, b.ratingKey, b.startSec, b.endSec, NxIsGated(channel))
            end for
        end if
    end for
    return packedBy
end function

' The block on air at nowSec, as buildChannelSchedule finds it: the one
' spanning now, else the latest that has started. Its index, or -1.
function NxNowBlockIndex(blocks as Object, nowSec as LongInteger) as Integer
    for i = 0 to blocks.Count() - 1
        if nowSec >= blocks[i].startSec and nowSec < blocks[i].endSec then return i
    end for
    best = -1
    for i = 0 to blocks.Count() - 1
        if nowSec >= blocks[i].startSec then
            if best = -1 then
                best = i
            else if blocks[i].startSec > blocks[best].startSec then
                best = i
            end if
        end if
    end for
    return best
end function

' What the guide prints for an item (itemDisplayLine).
function NxGuideTitle(item as Object) as String
    if item.librarySource = "musicVideo" then
        if NxTruthy(item.artist) then return NxToStr(item.artist) + " — " + NxToStr(item.title)
        return NxToStr(item.title)
    end if
    if NxTruthy(item.episodeTitle) then return NxToStr(item.title) + ": " + NxToStr(item.episodeTitle)
    return NxToStr(item.title)
end function
