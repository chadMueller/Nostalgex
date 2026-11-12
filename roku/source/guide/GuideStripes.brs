' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Bundle stripes in the guide (#276), the Apple TV's GuideStripes.swift (and the
' web tuner's stripeHex): a coloured stripe down the left edge of the guide, one
' run per bundle in guide order with the bundle's name written up it, a plain
' unnamed stripe for channels in no bundle. Pure, no stored data: it is all
' worked out from the lineup on screen.

' The ten colours a stripe can be, all channel colours the app already uses.
function NxStripePalette() as Object
    return ["#FF2DB4", "#E74C3C", "#E67E22", "#F1C40F", "#2ECC71", "#2DC7B0", "#00BFFF", "#7B68EE", "#8E44AD", "#B9770E"]
end function

' FNV-1a over the upper-cased name's UTF-8 bytes, its two 16-bit halves folded
' together, modulo the palette: written out so a name is the same colour on
' every launch and every TV (and on the Apple TV and the web tuner).
function NxStripeIndex(name as String) as Integer
    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(UCase(name))
    h& = &h811C9DC5&
    for each b in bytes
        h& = ((h& or b) and not (h& and b)) * &h01000193&
        h& = h& and &hFFFFFFFF&
    end for
    folded& = (h& \ 65536) and &hFFFF&
    low& = h& and &hFFFF&
    folded& = (folded& or low&) and not (folded& and low&)
    return folded& mod NxStripePalette().Count()
end function

function NxStripeHex(name as String) as String
    return NxStripePalette()[NxStripeIndex(name)]
end function

' WCAG relative luminance of "#RRGGBB".
function NxStripeLuminance(hex as String) as Float
    r = Val(Mid(hex, 2, 2), 16)
    g = Val(Mid(hex, 4, 2), 16)
    b = Val(Mid(hex, 6, 2), 16)
    out = 0.0
    k = 0
    for each v in [r, g, b]
        c = v / 255.0
        if c <= 0.03928 then c = c / 12.92 else c = ((c + 0.055) / 1.055) ^ 2.4
        if k = 0 then out = out + 0.2126 * c
        if k = 1 then out = out + 0.7152 * c
        if k = 2 then out = out + 0.0722 * c
        k = k + 1
    end for
    return out
end function

' Black or white, whichever reads better on the stripe: never below 4.5 to 1.
function NxStripeNameIsBlack(hex as String) as Boolean
    l = NxStripeLuminance(hex)
    return (l + 0.05) / 0.05 >= 1.05 / (l + 0.05)
end function

function NxStripeNameContrast(hex as String) as Float
    l = NxStripeLuminance(hex)
    black = (l + 0.05) / 0.05
    white = 1.05 / (l + 0.05)
    if black > white then return black
    return white
end function

' The colour a stripe is drawn in while it has focus: a fifth of the way to white
' (0.22), so it reads brighter than its neighbours. The name is chosen for this.
function NxStripeFocusedHex(hex as String) as String
    out = "#"
    digits = "0123456789ABCDEF"
    for i = 0 to 2
        c = Val(Mid(hex, 2 + i * 2, 2), 16)
        v = Int(c + (255 - c) * 0.22 + 0.5)
        out = out + Mid(digits, v \ 16 + 1, 1) + Mid(digits, v mod 16 + 1, 1)
    end for
    return out
end function

' Channel id (as a string) to the name of the bundle it is in: the first enabled
' bundle, in order, that lists it, then the jump lists the guide adds
' (NxGuideJumpTargets reads the same lists). `jumpIDs` is a bundle's list when it
' has one (FRANCHISES with the franchises found).
function NxStripeMembership(bundles as Dynamic, enabledBundles as Dynamic, jumps as Dynamic) as Object
    out = {}
    entries = []
    for each b in NxList(bundles)
        if NxHasValue(NxList(enabledBundles), b.id) then
            ids = b.channelIDs
            if b.jumpIDs <> invalid then ids = b.jumpIDs
            entries.Push({ name: NxToStr(b.name), ids: NxList(ids) })
        end if
    end for
    for each j in NxList(jumps)
        entries.Push({ name: NxToStr(j.name), ids: NxList(j.ids) })
    end for
    for each e in entries
        for each id in e.ids
            k = NxToStr(id)
            if not out.DoesExist(k) then out[k] = e.name
        end for
    end for
    return out
end function

' The runs of consecutive rows in the same bundle (or in none), in guide order:
' [{ name (invalid for none), firstRow, rowCount }]. A bundle the guide lists
' apart comes back as a second run, each its own stripe.
function NxStripeGroups(channels as Dynamic, membership as Object) as Object
    groups = []
    cur = invalid
    row = 0
    for each ch in NxList(channels)
        name = membership[NxToStr(ch.id)]
        if cur <> invalid and NxToStr(cur.name) = NxToStr(name) and (cur.name = invalid) = (name = invalid) then
            cur.rowCount = cur.rowCount + 1
        else
            if cur <> invalid then groups.Push(cur)
            cur = { name: name, firstRow: row, rowCount: 1 }
        end if
        row = row + 1
    end for
    if cur <> invalid then groups.Push(cur)
    return groups
end function

' The run the row is in, or -1.
function NxStripeGroupIndex(groups as Object, row as Integer) as Integer
    for i = 0 to groups.Count() - 1
        if groups[i].firstRow <= row and row < groups[i].firstRow + groups[i].rowCount then return i
    end for
    return -1
end function

' The previous (-1) or next (+1) run that is a bundle, from run `index`:
' unnamed runs are stepped over and there is no wrap (-1 past either end).
function NxStripeNeighbour(groups as Object, index as Integer, dir as Integer) as Integer
    i = index + dir
    while i >= 0 and i < groups.Count()
        if groups[i].name <> invalid then return i
        i = i + dir
    end while
    return -1
end function

' Whether there is any bundle to move between; with none Left goes to the
' bundle list as it always did.
function NxStripeHasBundles(groups as Object) as Boolean
    for each g in groups
        if g.name <> invalid then return true
    end for
    return false
end function
