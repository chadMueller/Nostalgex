' Runs upstream's scripts/schedule-parity-golden.json (copied unchanged to
' tests/vectors/), which NostalgexTests/ScheduleParityTests.swift made from
' the Apple TV's own scheduler, guide, conflict rule, tune and advance code,
' and npm run test:schedule-parity holds the web tuner to. The same walk as
' upstream's scripts/schedule-parity-dump.mjs, through the port's code:
'   items: each fixture item through the port's own loader (NxPlexMovieItem,
'          NxMbEpisodeItem, ...), so minutes are truncated as the Apple TV's;
'   days:  each channel's day from NxManifestBlocks, pools in library order;
'   at:    at each instant the guide's channels from NxScheduleGuide, the
'          24-hour window (NxChannelSchedule), one title on two channels
'          (NxGaveWay), what tuning in plays (startTune: what is on, from
'          where the clock is) and the next pick early, at the slot's end and
'          10 minutes after (NxAdvancePick).
' tests/vectors/schedule-parity-zones.json holds each zone's UTC offsets over
' those dates, from the tz database. Returns the failure count.

function NxRunScheduleParityGoldenTests(goldenPath as String, zonesPath as String) as Integer
    golden = ParseJson(ReadAsciiFile(goldenPath))
    tz = ParseJson(ReadAsciiFile(zonesPath))
    if golden = invalid or tz = invalid then
        print "FAIL cannot read "; goldenPath; " or "; zonesPath
        return 1
    end if
    r = { pass: 0, fail: 0 }
    g = GetGlobalAA()
    g.nxTzOffsetSec = invalid
    cover = { gaveWay: 0, tuneGaveWay: 0, skipped: 0, resyncSeek: 0, dropped: 0 }
    ' By index throughout: a nested `for each` over the same array shares its
    ' place on a TV.
    for ci = 0 to golden.cases.Count() - 1
        c = golden.cases[ci]
        fx = c.fixture
        want = c.expect
        g.nxTzOffsets = tz.zones[fx.zone]
        if g.nxTzOffsets = invalid then
            NxCheck(r, c.name + " has offsets", "no", "yes")
        else
            NxClearManifests()
            NxParityCase(r, c.name, fx, want, cover)
        end if
    end for
    g.nxTzOffsets = invalid

    ' The golden file covers what it claims, so a pass here means something.
    NxCheck(r, "a channel gives a title way to a lower one", (cover.gaveWay >= 6).ToStr(), "true")
    NxCheck(r, "tuning to a channel that gave way still plays that title", (cover.tuneGaveWay > 0).ToStr(), "true")
    NxCheck(r, "a next pick skips a title already on another channel", (cover.skipped > 0).ToStr(), "true")
    NxCheck(r, "a resync seeks into the programme", (cover.resyncSeek > 0).ToStr(), "true")
    NxCheck(r, "items the loaders drop", (cover.dropped >= 4).ToStr(), "true")
    print "schedule parity golden (Apple TV): "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

sub NxParityCase(r as Object, name as String, fx as Object, want as Object, cover as Object)
    musicGenre = CreateObject("roRegex", "music", "i")
    byKey = {}
    byKey.SetModeCaseSensitive()
    for i = 0 to fx.items.Count() - 1
        spec = fx.items[i]
        it = NxParityItem(spec, musicGenre)
        key = NxParitySpecKey(spec)
        if it <> invalid then byKey[key] = it
        got = invalid
        if it <> invalid then
            added& = 0
            if NxIsNumber(it.addedAt) then added& = it.addedAt
            if added& < 0 then added& = 0
            got = [it.duration, added&, NxToStr(it.title), NxToStr(it.type)]
        end if
        expected = want.items[key]
        if expected = invalid then cover.dropped = cover.dropped + 1
        NxCheck(r, name + " item " + key, NxParityJson(got), NxParityJson(expected))
    end for

    lineup = []
    for i = 0 to fx.channels.Count() - 1
        row = fx.channels[i]
        pool = []
        for each k in row.pool
            if byKey.DoesExist(NxToStr(k)) then pool.Push(byKey[NxToStr(k)])
        end for
        number = row.id
        if row.number <> invalid then number = row.number
        lineup.Push({ id: row.id, number: number, name: "CH " + row.id.ToStr(), colorHex: "#FFFFFF",
            isPremiereChannel: NxTruthy(row.premiere), pool: pool })
    end for

    for each t in fx.prime
        for each ch in lineup
            NxManifestBlocks(ch, ch.pool, t)
        end for
    end for

    for each t in fx.days
        wantDay = want.days[t.ToStr()]
        for each ch in lineup
            got = []
            for each b in NxManifestBlocks(ch, ch.pool, t)
                got.Push([NxToStr(b.item.ratingKey), b.startSec, b.endSec])
            end for
            NxCheck(r, name + " day " + t.ToStr() + " CH " + ch.id.ToStr(), NxParityJson(got), NxParityJson(wantDay[ch.id.ToStr()]))
        end for
    end for

    for ai = 0 to fx.at.Count() - 1
        t& = fx.at[ai]
        wantAt = invalid
        for each a in want.at
            if a.t = t& then wantAt = a
        end for
        channels = NxScheduleGuide(lineup, t&)
        gave = NxGaveWay(channels, t&)
        for i = 0 to channels.Count() - 1
            label = name + " at " + t&.ToStr() + " CH " + channels[i].id.ToStr()
            got = NxParityRow(channels, i, gave[i.ToStr()], t&)
            w = wantAt.ch[channels[i].id.ToStr()]
            NxCheck(r, label, NxParityJson(got), NxParityJson(w))
            if w <> invalid then
                if w.gaveWay <> invalid then
                    cover.gaveWay = cover.gaveWay + 1
                    if w.tune <> invalid and w.shown <> invalid then
                        if w.tune[0] = w.gaveWay and w.shown[0] <> w.gaveWay then cover.tuneGaveWay = cover.tuneGaveWay + 1
                    end if
                end if
                if w.early <> invalid and w.next <> invalid then
                    if w.early[0] <> w.next then cover.skipped = cover.skipped + 1
                end if
                if w.resync <> invalid then
                    if w.resync[1] > 0 then cover.resyncSeek = cover.resyncSeek + 1
                end if
            end if
        end for
    end for
end sub

' One channel at t in the golden file's shape, from the port's own answers.
function NxParityRow(channels as Object, i as Integer, gave as Dynamic, t as LongInteger) as Dynamic
    s = NxChannelSchedule(channels[i].blocks, t)
    if s = invalid then return invalid
    nowB = invalid
    if s.now >= 0 then nowB = s.entries[s.now]
    nextKey = invalid
    if s.next >= 0 then nextKey = s.entries[s.next].ratingKey
    first = s.entries[0]
    last = s.entries.Peek()
    row = {
        now: invalid, elapsed: s.elapsed, next: nextKey,
        span: [s.entries.Count(), first.startSec, last.endSec],
        shown: invalid, shownNext: nextKey, gaveWay: invalid, tune: invalid
    }
    if nowB <> invalid then
        row.now = [nowB.ratingKey, nowB.startSec, nowB.endSec]
        row.shown = [nowB.ratingKey, nowB.startSec]
        ' startTune: a press joins what airs now part way in.
        row.tune = [nowB.ratingKey, t - nowB.startSec]
    end if
    if gave <> invalid then
        row.gaveWay = gave.gaveWay.ratingKey
        row.shown = [gave.shown.ratingKey, gave.shown.startSec]
        ' What follows the one shown in its place; nothing when nothing did.
        row.shownNext = invalid
        if s.next >= 0 and s.next + 1 < s.entries.Count() then row.shownNext = s.entries[s.next + 1].ratingKey
    end if
    prev = invalid
    if row.tune <> invalid then prev = row.tune[0]
    endOfNow& = t
    if nowB <> invalid then endOfNow& = nowB.endSec
    row.early = NxParityPick(channels, i, prev, t, true)
    row["end"] = NxParityPick(channels, i, prev, endOfNow&, true)
    row.resync = NxParityPick(channels, i, prev, endOfNow& + 600, false)
    return row
end function

function NxParityPick(channels as Object, i as Integer, prev as Dynamic, t as LongInteger, natural as Boolean) as Dynamic
    p = NxAdvancePick(channels, i, prev, t, natural)
    if p = invalid then return invalid
    return [p.block.ratingKey, p.seek]
end function

' A fixture item through the loader its server uses.
function NxParityItem(spec as Object, musicGenre as Object) as Dynamic
    raw = spec.raw
    show = spec.show
    if show = invalid then show = {}
    if spec.backend = "plex" then
        if spec.kind = "episode" then return NxPlexEpisodeItem(raw, show, [], invalid, false)
        return NxPlexMovieItem(raw, { type: "movie" }, false, musicGenre)
    end if
    if spec.kind = "episode" then return NxMbEpisodeItem(raw, show, [], invalid, false)
    return NxMbMovieItem(raw, false, musicGenre)
end function

function NxParitySpecKey(spec as Object) as String
    if spec.backend = "plex" then return NxToStr(spec.raw.ratingKey)
    return NxToStr(spec.raw.Id)
end function

' JSON with each object's keys sorted, as upstream's canonical(), so the
' port's answer and the golden file's compare as text. Numbers as integers.
function NxParityJson(v as Dynamic) as String
    if v = invalid then return "null"
    t = type(v)
    if t = "roArray" then
        parts = []
        for each x in v
            parts.Push(NxParityJson(x))
        end for
        return "[" + parts.Join(",") + "]"
    end if
    if t = "roAssociativeArray" then
        keys = []
        for each k in v
            keys.Push(k)
        end for
        keys.Sort()
        parts = []
        for each k in keys
            parts.Push(FormatJson(LCase(k)) + ":" + NxParityJson(v[k]))
        end for
        return "{" + parts.Join(",") + "}"
    end if
    if NxIsString(v) then return FormatJson(v)
    if t = "Boolean" or t = "roBoolean" then return LCase(v.ToStr())
    if NxIsNumber(v) then
        n& = v
        return n&.ToStr()
    end if
    return "?" + t
end function
