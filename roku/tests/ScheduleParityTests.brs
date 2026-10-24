' Runs upstream's scripts/schedule-parity-golden.json (written by the Apple
' TV's own ScheduleParityTests.swift) through the port: the loaders' minutes
' and dates, each channel's day, the guide's 24-hour window, one title on two
' channels, what tuning in plays and the next pick, as
' scripts/schedule-parity-dump.mjs walks it for the web tuner. Each case's
' zone comes from tests/vectors/schedule-parity-zones.json. Returns the
' failure count.

function NxRunScheduleParityTests(goldenPath as String, zonesPath as String) as Integer
    r = { pass: 0, fail: 0 }
    golden = ParseJson(ReadAsciiFile(goldenPath))
    tz = ParseJson(ReadAsciiFile(zonesPath))
    if golden = invalid or tz = invalid then
        print "FAIL cannot read "; goldenPath; " or "; zonesPath
        return 1
    end if
    g = GetGlobalAA()
    for each c in golden.cases
        g.nxTzOffsets = tz.zones[c.fixture.zone]
        if g.nxTzOffsets = invalid then
            NxCheck(r, c.name + " has offsets", "no", "yes")
        else
            got = NxParityDump(c.fixture)
            for each part in ["items", "days", "at"]
                NxParityCompare(r, c.name + " " + part, got[part], c.expect[part])
            end for
        end if
    end for
    g.nxTzOffsets = invalid
    NxClearManifests()
    print "schedule parity cases (upstream schedule-parity-golden.json):"; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' Compares element by element, so a failure names the place.
sub NxParityCompare(r as Object, label as String, got as Dynamic, want as Dynamic)
    if type(want) = "roArray" and type(got) = "roArray" then
        if got.Count() <> want.Count() then
            NxCheck(r, label + " count", got.Count().ToStr(), want.Count().ToStr())
            return
        end if
        for i = 0 to want.Count() - 1
            NxParityCompare(r, label + "[" + i.ToStr() + "]", got[i], want[i])
        end for
        return
    end if
    NxCheck(r, label, NxParityCanon(got), NxParityCanon(want))
end sub

' Canonical JSON, keys sorted, numbers whole: canonical() in schedule-parity-dump.mjs.
function NxParityCanon(v as Dynamic) as String
    if v = invalid then return "null"
    t = type(v)
    if t = "roAssociativeArray" then
        ' Keys compared lowercased (a TV lowercases literal keys), but read
        ' with the key as stored: ParseJson's objects are case-sensitive.
        byLower = {}
        keys = []
        for each k in v
            keys.Push(LCase(k))
            byLower[LCase(k)] = NxParityCanon(v[k])
        end for
        keys.Sort()
        parts = []
        for each k in keys
            parts.Push(FormatJson(k) + ":" + byLower[k])
        end for
        return "{" + parts.Join(",") + "}"
    end if
    if t = "roArray" then
        parts = []
        for each x in v
            parts.Push(NxParityCanon(x))
        end for
        return "[" + parts.Join(",") + "]"
    end if
    if t = "roString" or t = "String" then return FormatJson(v)
    if t = "roBoolean" or t = "Boolean" then
        if v then return "true"
        return "false"
    end if
    if t = "roFloat" or t = "Float" or t = "roDouble" or t = "Double" then
        n& = v
        if n& = v then return n&.ToStr()
        return Str(v).Trim()
    end if
    n& = v
    return n&.ToStr()
end function

' An item as the Apple TV's loaders read it (makeItem in the dump), through
' the port's own minute and date readers. [ratingKey, item or invalid].
function NxParityItem(spec as Object) as Object
    if type(spec.compact) = "roArray" then
        k = NxToStr(spec.compact[0])
        return [k, { ratingKey: k, title: spec.compact[1], type: spec.compact[2], duration: spec.compact[3], addedAt: spec.compact[4] }]
    end if
    raw = spec.raw
    if spec.backend = "plex" then
        k = NxToStr(raw.ratingKey)
        minutes = NxPlexMinutes(raw.duration)
        if minutes <= 0 then return [k, invalid]
        title = raw.title
        if spec.kind = "episode" then
            title = ""
            if spec.show <> invalid and spec.show.title <> invalid then title = spec.show.title
        end if
        return [k, { ratingKey: k, title: title, type: spec.kind, duration: minutes, addedAt: NxOr(raw.addedAt, 0) }]
    end if
    k = NxToStr(raw.Id)
    minutes = NxMbMinutes(raw.RunTimeTicks)
    if minutes <= 0 then return [k, invalid]
    title = NxOr(raw.Name, "")
    if spec.kind = "episode" then
        title = ""
        if spec.show <> invalid and spec.show.Name <> invalid then
            title = spec.show.Name
        else if raw.SeriesName <> invalid then
            title = raw.SeriesName
        end if
    end if
    return [k, { ratingKey: k, title: title, type: spec.kind, duration: minutes, addedAt: NxMbUnixSeconds(raw.DateCreated) }]
end function

function NxParityDump(fx as Object) as Object
    NxClearManifests()
    byKey = {}
    byKey.SetModeCaseSensitive()
    items = {}
    items.SetModeCaseSensitive()
    for each spec in NxList(fx.items)
        pair = NxParityItem(spec)
        if pair[1] <> invalid then byKey[pair[0]] = pair[1]
        if type(spec.compact) <> "roArray" then
            it = pair[1]
            if it = invalid then
                items[pair[0]] = invalid
            else
                added& = it.addedAt
                if added& < 0 then added& = 0
                items[pair[0]] = [it.duration, added&, it.title, it.type]
            end if
        end if
    end for
    lineup = []
    for each row in fx.channels
        pool = []
        for each k in NxList(row.pool)
            it = byKey[NxToStr(k)]
            if it <> invalid then pool.Push(it)
        end for
        lineup.Push({ channel: { id: row.id, isPremiereChannel: NxTruthy(row.premiere) }, pool: pool })
    end for

    for each t in NxList(fx.prime)
        for each ln in lineup
            NxManifestBlocks(ln.channel, ln.pool, t)
        end for
    end for

    days = {}
    for each t in NxList(fx.days)
        byChannel = {}
        for each ln in lineup
            rows = []
            for each b in NxManifestBlocks(ln.channel, ln.pool, t)
                rows.Push([NxBlockKey(b), b.startSec, b.endSec])
            end for
            byChannel[ln.channel.id.ToStr()] = rows
        end for
        days[NxParityKey(t)] = byChannel
    end for

    at = []
    for each t in NxList(fx.at)
        rawRows = NxParitySchedules(lineup, t)
        shownRows = NxResolveConflicts(rawRows)
        byChannel = {}
        for i = 0 to lineup.Count() - 1
            ln = lineup[i]
            u = rawRows[i].schedule
            s = shownRows[i].schedule
            if u = invalid or s = invalid then
                byChannel[ln.channel.id.ToStr()] = invalid
            else
                tune = NxTuneIn(ln.channel, ln.pool, s, t)
                prev = invalid
                if tune <> invalid then prev = NxBlockKey(tune.block)
                endOfNow& = t
                if u.nowPlaying <> invalid then endOfNow& = u.nowPlaying.endSec
                gave = invalid
                for each e in s.entries
                    if e.isConflict then
                        gave = e.key
                        exit for
                    end if
                end for
                rec = {}
                rec.now = invalid
                if u.nowPlaying <> invalid then rec.now = [u.nowPlaying.key, u.nowPlaying.startSec, u.nowPlaying.endSec]
                rec.elapsed = u.elapsedSeconds
                rec.next = invalid
                if u.upNext <> invalid then rec.next = u.upNext.key
                rec.span = [u.entries.Count(), u.entries[0].startSec, u.entries.Peek().endSec]
                rec.shown = invalid
                if s.nowPlaying <> invalid then rec.shown = [s.nowPlaying.key, s.nowPlaying.startSec]
                rec.shownNext = invalid
                if s.upNext <> invalid then rec.shownNext = s.upNext.key
                rec.gaveWay = gave
                rec.tune = invalid
                if tune <> invalid then rec.tune = [NxBlockKey(tune.block), tune.seekSeconds]
                rec.early = NxParityAdvance(ln, lineup, prev, t, true)
                rec.end = NxParityAdvance(ln, lineup, prev, endOfNow&, true)
                rec.resync = NxParityAdvance(ln, lineup, prev, endOfNow& + 600, false)
                byChannel[ln.channel.id.ToStr()] = rec
            end if
        end for
        at.Push({ t: t, ch: byChannel })
    end for
    return { items: items, days: days, at: at }
end function

function NxParitySchedules(lineup as Object, t as LongInteger) as Object
    rows = []
    for each ln in lineup
        rows.Push({ id: ln.channel.id, schedule: NxBuildSchedule(ln.channel, ln.pool, t) })
    end for
    return rows
end function

function NxParityAdvance(ln as Object, lineup as Object, prev as Dynamic, now as LongInteger, natural as Boolean) as Dynamic
    p = NxAdvancePickFrom(NxBuildSchedule(ln.channel, ln.pool, now), prev, now, ln.channel.id, NxParitySchedules(lineup, now), natural)
    if p = invalid then return invalid
    return [NxBlockKey(p.block), p.seekSeconds]
end function

function NxParityKey(t as Dynamic) as String
    n& = t
    return n&.ToStr()
end function
