' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Runs source/guide/LastChannel.brs, OPEN ON LAST CHANNEL (#230), on a stand-in
' registry section (NxFakeRegistry, tests/LaunchGuardTests.brs): the cases the
' issue lists, then the web tuner's nostalgex-last-channel-smoke.mjs cases for
' the match (its lineup, and every stock channel finding itself), then the
' cold-boot seed's channel following it (NxSeedChannel). The Apple TV's
' LaunchChannelMemoryTests.swift holds the same rule; its demo mode cases
' have no Roku counterpart. Returns the failure count.

function NxRunLastChannelTests(channelsPath as String) as Integer
    r = { pass: 0, fail: 0 }
    one = { id: 1, number: 1, name: "NOSTALGEX" }
    toons = { id: 12, number: 12, name: "SAT MORNING CARTOONS" }
    vault = { id: 30, number: 30, name: "VHS VAULT" }
    guide = [one, toons, vault]

    ' The switch: never chosen starts on, a stored off stays off.
    reg = NxFakeRegistry()
    NxCheck(r, "never chosen starts on", NxLastChannelOn(reg).ToStr(), "true")
    NxCheck(r, "the default is on", NxLastChannelOnByDefault().ToStr(), "true")
    NxSaveLastChannelOn(reg, false)
    NxCheck(r, "a stored off stays off", NxLastChannelOn(reg).ToStr(), "false")
    NxSaveLastChannelOn(reg, true)
    NxCheck(r, "a stored on is on", NxLastChannelOn(reg).ToStr(), "true")
    reg.Write("openLastChannel", "yes")
    NxCheck(r, "anything else stored is off", NxLastChannelOn(reg).ToStr(), "false")
    NxCheck(r, "no registry: the default", NxLastChannelOn(invalid).ToStr(), "true")

    ' Nothing remembered opens the first channel (-1: the caller's channel one).
    reg = NxFakeRegistry()
    NxCheck(r, "nothing remembered opens the first channel", NxChannelToOpen(reg, guide).ToStr(), "-1")
    NxCheck(r, "nothing remembered: nothing saved", (NxLastChannelSaved(reg) = invalid).ToStr(), "true")

    ' Saved and restored.
    NxCheck(r, "a tuned channel is saved", NxRememberChannel(reg, toons).ToStr(), "true")
    NxCheck(r, "saved: the id and the name", FormatJson(NxLastChannelSaved(reg)), FormatJson({ id: "12", name: "SAT MORNING CARTOONS" }))
    NxCheck(r, "saved and restored", NxChannelToOpen(reg, guide).ToStr(), "1")
    NxCheck(r, "the same channel again writes nothing", NxRememberChannel(reg, toons).ToStr(), "false")
    NxCheck(r, "restored where it now sits in the guide", NxChannelToOpen(reg, [vault, one, toons]).ToStr(), "2")
    ' An id that came back from JSON as a number or as text is the same id.
    NxCheck(r, "an id as text matches", NxChannelToOpen(reg, [one, { id: "12", name: "SAT MORNING CARTOONS" }]).ToStr(), "1")

    ' Renamed, renumbered, gone: the first channel.
    NxCheck(r, "renamed opens the first channel", NxChannelToOpen(reg, [one, { id: 12, number: 12, name: "SATURDAY CARTOONS" }, vault]).ToStr(), "-1")
    ' Renumbered: the id is another channel's now and the name sits at another id.
    NxCheck(r, "renumbered opens the first channel", NxChannelToOpen(reg, [one, { id: 12, number: 12, name: "VHS VAULT" }, { id: 13, number: 13, name: "SAT MORNING CARTOONS" }]).ToStr(), "-1")
    NxCheck(r, "gone opens the first channel", NxChannelToOpen(reg, [one, vault]).ToStr(), "-1")
    NxCheck(r, "no channels opens nothing", NxChannelToOpen(reg, []).ToStr(), "-1")
    NxCheck(r, "no guide opens nothing", NxChannelToOpen(reg, invalid).ToStr(), "-1")

    ' Switch off opens the first channel, and the channel is saved all the same.
    NxSaveLastChannelOn(reg, false)
    NxCheck(r, "switch off opens the first channel", NxChannelToOpen(reg, guide).ToStr(), "-1")
    NxCheck(r, "switch off: a tune is still saved", NxRememberChannel(reg, vault).ToStr(), "true")
    NxSaveLastChannelOn(reg, true)
    NxCheck(r, "switched on later opens what was last tuned", NxChannelToOpen(reg, guide).ToStr(), "2")

    ' Only a viewer's tune is remembered: nothing here saves but
    ' NxRememberChannel, and asking which channel to open (a launch, the
    ' fallback to channel one) leaves the saved one alone.
    before = reg.Read("lastChannel")
    NxChannelToOpen(reg, [one])
    NxChannelToOpen(reg, guide)
    NxLastChannelSaved(reg)
    NxCheck(r, "a launch's fallback forgets nothing", reg.Read("lastChannel"), before)
    NxCheck(r, "the channel comes back when its package does", NxChannelToOpen(reg, guide).ToStr(), "2")

    ' Sign-out clears the channel and leaves the switch alone.
    NxSaveLastChannelOn(reg, false)
    NxForgetLastChannel(reg)
    NxCheck(r, "sign-out clears it", reg.Read("lastChannel"), "")
    NxCheck(r, "sign-out leaves the switch off", NxLastChannelOn(reg).ToStr(), "false")
    NxSaveLastChannelOn(reg, true)
    NxCheck(r, "after sign-out a launch opens the first channel", NxChannelToOpen(reg, guide).ToStr(), "-1")
    NxForgetLastChannel(invalid)

    ' A damaged value opens the first channel.
    for each bad in ["", "12", "not json", "[12]", "{}", "{""id"":12}", "{""name"":""SAT MORNING CARTOONS""}", "{""id"":12,""name"":""""}", "{""id"":12,""name"":7}", "{""id"":"""",""name"":""SAT MORNING CARTOONS""}", "{""id"":12,""name"":""SAT MORNING"]
        reg = NxFakeRegistry()
        reg.Write("lastChannel", bad)
        NxCheck(r, "damaged value " + FormatJson(bad) + " opens the first channel", NxChannelToOpen(reg, guide).ToStr(), "-1")
    end for
    NxCheck(r, "a value that isn't text is no channel", (NxLastChannelParse(invalid) = invalid).ToStr(), "true")

    for each bad in ["null", "[]", "[1,2]", "7", """x"""]
        NxCheck(r, "parse refuses " + bad, (NxLastChannelParse(bad) = invalid).ToStr(), "true")
    end for

    ' The web smoke's lineup: two channels share a name, and the id picks one.
    lineup = [{ id: 1, name: "VHS VAULT" }, { id: 2, name: "DVD SHELF" }, { id: 12, name: "MTV 80S" }, { id: 40, name: "VHS VAULT" }]
    NxCheck(r, "the same id and name is opened", NxLastChannelIndex({ id: "12", name: "MTV 80S" }, lineup).ToStr(), "2")
    NxCheck(r, "two channels with one name: the second", NxLastChannelIndex({ id: "40", name: "VHS VAULT" }, lineup).ToStr(), "3")
    NxCheck(r, "two channels with one name: the first", NxLastChannelIndex({ id: "1", name: "VHS VAULT" }, lineup).ToStr(), "0")
    NxCheck(r, "a text id in the guide matches", NxLastChannelIndex({ id: "7", name: "X" }, [{ id: "7", name: "X" }]).ToStr(), "0")
    NxCheck(r, "renamed: same id, other name", NxLastChannelIndex({ id: "12", name: "MTV 90S" }, lineup).ToStr(), "-1")
    NxCheck(r, "renumbered: the name sits on another id", NxLastChannelIndex({ id: "13", name: "MTV 80S" }, lineup).ToStr(), "-1")
    NxCheck(r, "the name is matched exactly, not by case", NxLastChannelIndex({ id: "12", name: "mtv 80s" }, lineup).ToStr(), "-1")
    NxCheck(r, "the name is matched exactly, not by spacing", NxLastChannelIndex({ id: "12", name: "MTV 80S " }, lineup).ToStr(), "-1")
    NxCheck(r, "not in the list opens nothing", NxLastChannelIndex({ id: "99", name: "GONE" }, lineup).ToStr(), "-1")
    NxCheck(r, "nothing kept opens nothing", NxLastChannelIndex(invalid, lineup).ToStr(), "-1")
    NxCheck(r, "a list with holes still finds the channel", NxLastChannelIndex({ id: "1", name: "VHS VAULT" }, [invalid, lineup[0]]).ToStr(), "1")

    ' The real lineup: every channel in channels.json finds itself and no other.
    stock = ParseJson(ReadAsciiFile(channelsPath))
    if stock = invalid or type(stock.channels) <> "roArray" or stock.channels.Count() = 0 then
        NxCheck(r, "channels.json is read", "no", "yes")
    else
        wrong = 0
        for i = 0 to stock.channels.Count() - 1
            if NxLastChannelIndex(NxLastChannelParse(NxLastChannelText(stock.channels[i])), stock.channels) <> i then wrong = wrong + 1
        end for
        NxCheck(r, "every stock channel is found by its own id and name, and by nothing else", wrong.ToStr(), "0")
    end if

    ' A channel with no id or no name is not saved: nothing to match later.
    reg = NxFakeRegistry()
    NxCheck(r, "no name is not saved", NxRememberChannel(reg, { id: 5 }).ToStr(), "false")
    NxCheck(r, "an empty name is not saved", NxRememberChannel(reg, { id: 5, name: "" }).ToStr(), "false")
    NxCheck(r, "no id is not saved", NxRememberChannel(reg, { name: "FLICKS" }).ToStr(), "false")
    NxCheck(r, "no channel is not saved", NxRememberChannel(reg, invalid).ToStr(), "false")
    NxCheck(r, "no registry saves nothing", NxRememberChannel(invalid, toons).ToStr(), "false")
    NxCheck(r, "nothing was written", reg.Read("lastChannel"), "")

    ' The cold-boot seed (#155) holds the channel a launch opens on.
    reg = NxFakeRegistry()
    NxCheck(r, "seed: channel one with nothing remembered", NxToStr(NxSeedChannel(guide, NxChannelToOpen(reg, guide)).id), "1")
    NxRememberChannel(reg, toons)
    NxCheck(r, "seed: the remembered channel", NxToStr(NxSeedChannel(guide, NxChannelToOpen(reg, guide)).id), "12")
    NxCheck(r, "seed: channel one when the remembered one isn't in the guide", NxToStr(NxSeedChannel([one, vault], NxChannelToOpen(reg, [one, vault])).id), "1")
    NxSaveLastChannelOn(reg, false)
    NxCheck(r, "seed: channel one with the switch off", NxToStr(NxSeedChannel(guide, NxChannelToOpen(reg, guide)).id), "1")
    NxCheck(r, "seed: an index past the guide is channel one", NxToStr(NxSeedChannel(guide, 9).id), "1")
    NxCheck(r, "seed: none without channels", (NxSeedChannel([], 0) = invalid).ToStr(), "true")

    ' The Settings row is in PLAYBACK & PICTURE, or it would never show.
    NxCheck(r, "the row's tab", NxSettingsTabOf("lastChannel"), "playback")

    print "last channel cases (#230):"; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function
