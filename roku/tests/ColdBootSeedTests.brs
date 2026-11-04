' Runs source/guide/ColdBootSeed.brs (#155): what the seed keeps of a
' channel within its budget, and what a launch can play from it. The Roku's
' own: the Apple TV has no seed to transcribe. Returns the failure count.

function NxRunColdBootSeedTests() as Integer
    r = { pass: 0, fail: 0 }
    ch = NxSeedTestChannel()

    ' Which channel: the one a launch tunes, channel one.
    NxCheck(r, "seed channel: the first", NxToStr(NxSeedChannel([ch, { id: 9 }]).id), "7")
    NxCheck(r, "seed channel: none without channels", (NxSeedChannel([]) = invalid).ToStr(), "true")
    NxCheck(r, "seed channel: none without a list", (NxSeedChannel(invalid) = invalid).ToStr(), "true")

    ' From the airing on now: the one that ended at 1000 is left out.
    text = NxSeedFrom(ch, 1500, "1.0+b", 100000)
    s = ParseJson(text)
    NxCheck(r, "from now: four airings left", s.blocks.Count().ToStr(), "4")
    NxCheck(r, "from now: the one on now first", s.blocks[0].ratingKey, "b")
    NxCheck(r, "from now: the channel's row fields", s.channel.name + " " + NxToStr(s.channel.number) + " " + s.channel.color, "MOVIES 3 #ff0000")
    NxCheck(r, "from now: the key", s.key, "1.0+b")
    NxCheck(r, "from now: the summary isn't kept", s.blocks[0].summary, "")
    NxCheck(r, "from now: the play path's fields are", s.blocks[0].partKey + " " + s.blocks[0].container, "/library/parts/1/file.mkv mkv")
    NxCheck(r, "from now: nothing left after the last", NxSeedFrom(ch, 5000, "k", 100000), "")
    NxCheck(r, "no channel, no seed", NxSeedFrom(invalid, 1500, "k", 100000), "")

    ' The budget: as many whole airings as fit, never part of one.
    full = NxUtf8Bytes(text)
    NxCheck(r, "budget: the whole text fits its own size", NxUtf8Bytes(NxSeedFrom(ch, 1500, "1.0+b", full)).ToStr(), full.ToStr())
    under = ParseJson(NxSeedFrom(ch, 1500, "1.0+b", full - 1))
    NxCheck(r, "budget: a byte short drops the last airing", under.blocks.Count().ToStr(), "3")
    NxCheck(r, "budget: within it", (NxUtf8Bytes(NxSeedFrom(ch, 1500, "1.0+b", full - 1)) <= full - 1).ToStr(), "true")
    NxCheck(r, "budget: not even the first airing fits", NxSeedFrom(ch, 1500, "1.0+b", 50), "")
    NxCheck(r, "budget: counts bytes, not characters", NxUtf8Bytes("é").ToStr(), "2")
    NxCheck(r, "budget: the default is 10 KB", NxSeedBudget().ToStr(), "10240")

    ' A launch from the seed: the one channel, its airings not yet over.
    g = NxSeedGuide(text, 1500, "1.0+b", ["nostalgex"])
    NxCheck(r, "launch: a guide", (g <> invalid).ToStr(), "true")
    if g <> invalid then
        NxCheck(r, "launch: marked seed", NxTruthy(g.seed).ToStr(), "true")
        NxCheck(r, "launch: one channel, by id", g.channels.Count().ToStr() + " " + NxToStr(g.channels[0].id), "1 7")
        NxCheck(r, "launch: its airings", g.channels[0].blocks.Count().ToStr(), "4")
        NxCheck(r, "launch: the packages on", FormatJson(g.enabledBundles), "[""nostalgex""]")
        NxCheck(r, "launch: no packages to list", g.bundles.Count().ToStr(), "0")
    end if
    later = NxSeedGuide(text, 2500, "1.0+b", [])
    NxCheck(r, "launch later: the ended airing is dropped", NxToStr(later.channels[0].blocks[0].ratingKey) + " " + later.channels[0].blocks.Count().ToStr(), "c 3")
    NxCheck(r, "launch on the last airing", NxSeedGuide(text, 4999, "1.0+b", []).channels[0].blocks.Count().ToStr(), "1")
    NxCheck(r, "launch after the last airing: none", (NxSeedGuide(text, 5000, "1.0+b", []) = invalid).ToStr(), "true")
    NxCheck(r, "launch before the first airing (clock set back): none", (NxSeedGuide(text, 900, "1.0+b", []) = invalid).ToStr(), "true")
    NxCheck(r, "launch on another build: none", (NxSeedGuide(text, 1500, "1.1+c", []) = invalid).ToStr(), "true")
    NxCheck(r, "launch without a seed: none", (NxSeedGuide("", 1500, "1.0+b", []) = invalid).ToStr(), "true")
    NxCheck(r, "launch from a broken seed: none", (NxSeedGuide("{""key"":""1.0+b""", 1500, "1.0+b", []) = invalid).ToStr(), "true")
    NxCheck(r, "launch with no packages read", FormatJson(NxSeedGuide(text, 1500, "1.0+b", invalid).enabledBundles), "[]")

    print "cold-boot seed cases (#155): "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' A channel as NxScheduleGuide gives it: five airings of 1000 s from 0.
function NxSeedTestChannel() as Object
    blocks = []
    keys = ["a", "b", "c", "d", "e"]
    for i = 0 to 4
        blocks.Push({
            startSec: i * 1000, endSec: (i + 1) * 1000, ratingKey: keys[i], line: "Film " + keys[i], title: "Film " + keys[i],
            episodeTitle: "", seasonNumber: invalid, episodeNumber: invalid, summary: "A long summary the info panel shows.",
            year: "1999", partKey: "/library/parts/" + i.ToStr() + "/file.mkv", container: "mkv", videoCodec: "h264", audioCodec: "aac",
            videoProfile: "high", audioChannels: 2, bitrate: 4000, audioTracks: invalid, forcedSubs: invalid, fullSubs: invalid,
            duration: 16, videoWidth: 1920, videoHeight: 1080, serverIndex: 0, contentRating: "R", rating: 7.5, type: "movie"
        })
    end for
    return { id: 7, number: 3, name: "MOVIES", color: "#ff0000", blocks: blocks }
end function
