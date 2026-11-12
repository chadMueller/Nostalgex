' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' The bundle stripes' rules (source/guide/GuideStripes.brs, issue #276): the
' colour a name gets (the Apple TV's GuideStripes.Palette, FNV-1a, so the same
' on every launch and TV), the name's contrast on it, which bundle a channel is
' in, the runs that make a stripe, and stepping between bundles.
' Returns the failure count.

function NxRunGuideStripesTests(configPath as String) as Integer
    r = { pass: 0, fail: 0 }
    config = ParseJson(ReadAsciiFile(configPath))
    palette = NxStripePalette()

    ' Palette indexes the Apple TV's hash gives the shipped bundle names (worked out
    ' with the same FNV-1a over the upper-cased name, halves folded, modulo ten).
    want = { "NOSTALGEX": 9, "KIDZ ZONE": 1, "CASE FILES": 2, "PRIME TIME": 6, "MARQUEE": 1, "ARTHOUSE": 0, "ADVENTURELAND": 4, "OVERTIME": 9, "DECADES": 4, "FRANCHISES": 6, "NETWORKS": 6, "SCREAM": 0, "TIS THE SEASON": 5, "HIGH ROTATION": 7 }
    bad = []
    for each b in config.bundles
        if want.DoesExist(b.name) then
            if NxStripeIndex(b.name) <> want[b.name] then bad.Push(b.name + " " + NxToStr(NxStripeIndex(b.name)))
        else
            bad.Push(b.name + " is not in the list this test knows")
        end if
    end for
    NxCheck(r, "colour: every shipped bundle name gets the Apple TV's palette index", bad.Join(", "), "")
    NxCheck(r, "colour: a name is case-blind", NxStripeHex("kidz zone"), NxStripeHex("KIDZ ZONE"))
    NxCheck(r, "colour: the palette is ten colours", NxToStr(palette.Count()), "10")
    NxCheck(r, "colour: KIDZ ZONE is red", NxStripeHex("KIDZ ZONE"), "#E74C3C")

    ' No two neighbouring shipped bundles in guide order (by their lowest channel number) share a colour.
    numberOf = {}
    for each c in config.channels
        numberOf[NxToStr(c.id)] = c.number
    end for
    order = []
    for each b in config.bundles
        low = 1000000
        for each id in b.channelIDs
            n = numberOf[NxToStr(id)]
            if n <> invalid and n < low then low = n
        end for
        if low < 1000000 then order.Push({ name: b.name, low: low })
    end for
    for i = 1 to order.Count() - 1
        j = i
        while j > 0 and order[j - 1].low > order[j].low
            tmp = order[j]
            order[j] = order[j - 1]
            order[j - 1] = tmp
            j = j - 1
        end while
    end for
    same = []
    for i = 1 to order.Count() - 1
        if NxStripeIndex(order[i].name) = NxStripeIndex(order[i - 1].name) then same.Push(order[i - 1].name + "/" + order[i].name)
    end for
    NxCheck(r, "colour: neighbouring shipped bundles in guide order differ", same.Join(", "), "")

    ' The name reads at 4.5:1 or better on every colour, plain and focused.
    low = []
    for each hex in palette
        if NxStripeNameContrast(hex) < 4.5 then low.Push(hex)
        if NxStripeNameContrast(NxStripeFocusedHex(hex)) < 4.5 then low.Push("focused " + hex)
    end for
    NxCheck(r, "contrast: every palette colour and its focused lift reads at 4.5:1", low.Join(","), "")
    NxCheck(r, "contrast: black on yellow", NxToStr(NxStripeNameIsBlack("#F1C40F")), "true")
    NxCheck(r, "contrast: white on purple", NxToStr(NxStripeNameIsBlack("#8E44AD")), "false")
    NxCheck(r, "focus: a fifth of the way to white", NxStripeFocusedHex("#000000"), "#383838")
    NxCheck(r, "focus: white stays white", NxStripeFocusedHex("#FFFFFF"), "#FFFFFF")

    ' Membership: the first enabled bundle that lists a channel, then the jump lists.
    bundles = [
        { id: "a", name: "ALPHA", channelIDs: [1, 2, 3] },
        { id: "b", name: "BETA", channelIDs: [3, 4] },
        { id: "c", name: "GAMMA", channelIDs: [9], jumpIDs: [9, 10] },
        { id: "d", name: "OFF", channelIDs: [20] }
    ]
    mem = NxStripeMembership(bundles, ["a", "b", "c"], [{ name: "FOUND", ids: [11, 4] }])
    NxCheck(r, "membership: the first bundle wins a channel in two", mem["3"], "ALPHA")
    NxCheck(r, "membership: the second bundle's own channel", mem["4"], "BETA")
    NxCheck(r, "membership: a bundle's jump list is read", mem["10"], "GAMMA")
    NxCheck(r, "membership: a jump list adds channels no bundle lists", mem["11"], "FOUND")
    NxCheck(r, "membership: a bundle that is off lists none", NxToStr(mem.DoesExist("20")), "false")

    ' Runs: consecutive rows in the same bundle, a plain run for none, a bundle apart is a second run.
    ch = []
    for each id in [1, 2, 99, 3, 4, 5, 1, 2]
        ch.Push({ id: id })
    end for
    mem = NxStripeMembership([{ id: "a", name: "ALPHA", channelIDs: [1, 2, 3] }, { id: "b", name: "BETA", channelIDs: [4, 5] }], ["a", "b"], [])
    groups = NxStripeGroups(ch, mem)
    text = []
    for each g in groups
        text.Push(NxToStr(g.name) + ":" + NxToStr(g.firstRow) + "+" + NxToStr(g.rowCount))
    end for
    NxCheck(r, "runs: ALPHA, a plain run, ALPHA, BETA, ALPHA again", text.Join("|"), "ALPHA:0+2|:2+1|ALPHA:3+1|BETA:4+2|ALPHA:6+2")
    NxCheck(r, "runs: no channels", NxToStr(NxStripeGroups([], mem).Count()), "0")
    NxCheck(r, "runs: the run a row is in", NxToStr(NxStripeGroupIndex(groups, 5)), "3")
    NxCheck(r, "runs: a row past the end", NxToStr(NxStripeGroupIndex(groups, 8)), "-1")
    NxCheck(r, "runs: has bundles", NxToStr(NxStripeHasBundles(groups)), "true")
    NxCheck(r, "runs: none named has none", NxToStr(NxStripeHasBundles(NxStripeGroups([{ id: 99 }], {}))), "false")
    ' Stepping skips the plain run and does not wrap.
    NxCheck(r, "step: down from the first ALPHA skips the plain run", NxToStr(NxStripeNeighbour(groups, 0, 1)), "2")
    NxCheck(r, "step: up from BETA", NxToStr(NxStripeNeighbour(groups, 3, -1)), "2")
    NxCheck(r, "step: up from the first run has nowhere to go", NxToStr(NxStripeNeighbour(groups, 0, -1)), "-1")
    NxCheck(r, "step: down from the last run has nowhere to go", NxToStr(NxStripeNeighbour(groups, 4, 1)), "-1")
    NxCheck(r, "step: up from the run after the plain one skips it", NxToStr(NxStripeNeighbour(groups, 2, -1)), "0")

    print "guide stripes tests: "; r.pass; " passed, "; r.fail; " failed"
    return r.fail
end function
