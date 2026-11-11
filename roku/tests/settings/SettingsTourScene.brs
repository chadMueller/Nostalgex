' The Settings tour's scene: SettingsView over made-up data (see
' SettingsTourMain.brs). The packages are the real ones from data/channels.json;
' which of their channels are "on air", the franchises and the collections are
' made up, so every state of the channel rows can be put on screen.

sub init()
end sub

sub onArgs()
    ' It saves package and collection choices to make its rows: never in the
    ' real app's saved data, which the store build shares.
    if NxDataSpace() = "" then
        label = m.top.FindNode("refused")
        label.text = "SETTINGS TOUR REFUSED. This build's saved data is the real app's. Install it with scripts/deploy.sh --settings-tour, which gives it its own."
        label.visible = true
        print "TOUR REFUSED: this is not the test data space"
        return
    end if
    a = m.top.args
    state = NxToStr(a.state)
    if state = "" then state = "on"

    config = ParseJson(ReadAsciiFile("pkg:/data/channels.json"))
    bundles = []
    for each b in config.bundles
        bundles.Push({ id: b.id, name: b.name, channelIDs: b.channelIDs, activeMonths: b.activeMonths, seasonStart: b.seasonStart })
    end for

    ' Four packages on, one short a channel (a 1), one short twelve (a 12), one
    ' with none on air (no count, the Apple TV's other message), and the
    ' FRANCHISES switch as the state says.
    enabled = ["nostalgex", "kids", "essentials", "arthouse"]
    if state <> "off" then enabled.Push("franchises")
    NxSaveEnabledBundles(enabled)
    onAir = []
    for each b in bundles
        if b.id <> "franchises" and NxHasValue(enabled, b.id) then
            keep = b.channelIDs.Count()
            if b.id = "kids" then keep = keep - 1
            if b.id = "essentials" then keep = keep - 12
            if b.id = "arthouse" then keep = 0
            for i = 0 to keep - 1
                onAir.Push(b.channelIDs[i])
            end for
        end if
    end for

    dot = " " + Chr(183) + " "
    franchises = []
    if state = "on" or state = "fills" or state = "folded" or state = "overcap" then
        franchises = [
            { id: "dict:DIE HARD", name: "DIE HARD", countLabel: "5 movies", stockChannelID: 101, channelNumber: 104, enabled: true },
            { id: "dict:JAMES BOND", name: "JAMES BOND", countLabel: "24 movies", stockChannelID: 102, channelNumber: 105, enabled: true },
            { id: "dict:STAR TREK", name: "STAR TREK", countLabel: "13 movies, 6 shows", stockChannelID: 104, channelNumber: 107, enabled: false },
            { id: "dict:STAR WARS", name: "STAR WARS", countLabel: "11 movies", stockChannelID: 100, channelNumber: 103, enabled: true },
            { id: "f:harry-potter", name: "HARRY POTTER", countLabel: "8 movies", stockChannelID: invalid, channelNumber: 310, enabled: true },
            { id: "f:john-wick", name: "JOHN WICK", countLabel: "4 movies", stockChannelID: invalid, channelNumber: invalid, enabled: false }
        ]
    end if
    rows = []
    keys = {}
    if state <> "empty" then
        rows.Push({ id: "c-batman", title: "Batman Collection", detail: "7 movies", warned: false, category: "franchises", enabled: true, channelNumber: 311 })
        rows.Push({ id: "c-oceans", title: "Ocean's Collection", detail: "80% already on CH 98 STAND-UP", warned: true, category: "franchises", enabled: false, channelNumber: invalid })
        keys["c-batman"] = true
        if state <> "folded" then
            rows.Push({ id: "c-cage", title: "Nicolas Cage", detail: "12 movies", warned: false, category: "custom", enabled: true, channelNumber: 400 })
            rows.Push({ id: "c-xmas", title: "Christmas Favorites", detail: "9 movies" + dot + "2 shows", warned: false, category: "custom", enabled: false, channelNumber: invalid })
            keys["c-cage"] = true
        end if
    end if
    NxSaveCollectionKeys(keys)
    overFound = 0
    overFranchises = 0
    if state = "overcap" then
        overFound = 4
        overFranchises = 3
    end if
    collections = { rows: rows, overCap: overFranchises, overCapFranchises: overFranchises, overCapCustom: 0, capacityFranchises: 90, capacityCustom: 100, scanned: rows.Count(), failed: 0 }

    m.settings = CreateObject("roSGNode", "SettingsView")
    m.settings.bundles = bundles
    m.settings.onAirIds = onAir
    m.settings.builtBundles = enabled
    ' Made-up counts for WHY ARE SOME CHANNELS MISSING? (#227): every channel
    ' a few titles short of its minimum, some at none.
    byId = {}
    for each def in config.channels
        n = NxNumberOr0(def.minItems)
        if n = 0 then n = 50
        byId[NxToStr(def.id)] = (def.id mod 4) * Int(n / 4)
    end for
    m.settings.matchCounts = { state: "counted", byId: byId }
    m.settings.franchises = franchises
    m.settings.franchiseOverCap = overFound
    m.settings.franchiseCapacity = 90
    m.settings.collections = collections
    m.settings.ObserveField("result", "onResult")
    m.top.AppendChild(m.settings)
    m.settings.callFunc("open", invalid)
    print "TOUR settings open: state "; state; ", "; bundles.Count(); " packages, "; franchises.Count(); " franchises, "; rows.Count(); " collections"
    ' fills: as "on", then after `after` seconds (default 30) every channel of
    ' the packages on, FRANCHISES included, is on air, handed over as GuideView's refreshSettings
    ' does after a guide build, so MISSING CHANNELS, left open, has none.
    if state = "fills" then
        m.fillIds = []
        for each b in bundles
            if NxHasValue(enabled, b.id) then m.fillIds.Append(b.channelIDs)
        end for
        m.fillBuilt = enabled
        after = Val(NxToStr(a.after))
        if after <= 0 then after = 30
        m.fillTimer = CreateObject("roSGNode", "Timer")
        m.fillTimer.duration = after
        m.fillTimer.ObserveField("fire", "onFill")
        m.fillTimer.control = "start"
    end if
end sub

sub onFill()
    m.settings.onAirIds = m.fillIds
    m.settings.builtBundles = m.fillBuilt
    m.settings.callFunc("refreshRows", invalid)
    print "TOUR every channel of the packages on is on air ("; m.fillIds.Count(); " channels)"
end sub

sub onResult()
    print "TOUR settings result: "; m.settings.result
end sub
