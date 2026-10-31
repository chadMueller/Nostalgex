' Vertical moves in the guide grid, after upstream's ChannelGuideView.swift
' (66033f6, "Up out of channel one belongs to SETTINGS, so only the downward
' wrap gets a sentinel"): Down from the last channel wraps to channel one, Up
' from channel one does not wrap. On the Roku, SETTINGS is the sidebar's first
' row, one Left press away. With fewer than two channels there is nothing to
' wrap to. Returns the new focus index, or -1 when the press isn't handled.
function NxGuideStep(focus as Integer, count as Integer, key as String) as Integer
    if key = "down" then
        if focus < count - 1 then return focus + 1
        if count > 1 then return 0
    else if key = "up" then
        if focus > 0 then return focus - 1
    end if
    return -1
end function

' Back on the guide grid. Away from the live channel it returns there, as
' Menu does on Apple TV (GuideExitAction). On the live channel it leaves the
' app, but a stream the server is encoding is stopped first: Roku doesn't
' pass Home to the app, so this is the one exit that can end the encode
' (#81). Returns "live", "stop" (send the stop, then leave) or "leave"
' (let Roku close the app).
function NxGuideBack(focus as Integer, tuned as Integer, slotOffset as Integer, encoding as Boolean) as String
    if focus <> tuned or slotOffset <> 0 then return "live"
    if encoding then return "stop"
    return "leave"
end function

' The packages sidebar (Left on the live slot), as the Apple TV app's
' bundleJumpTargets: one entry per package with a channel on screen, jumping
' to its first channel, in guide order. Guide order, not the package list's:
' the list is channels.json's order (CASE FILES third though it airs from
' CH 120), and a seasonal package leading the guide leads the list too.
' bundles: the guide's packages ({ name, channelIDs, jumpIDs when the jump
' covers more, as FRANCHISES does }), enabledBundles their switched-on ids,
' jumps entries no switch owns ({ name, ids }: the collections), channels
' the guide's, in guide order. Returns [{ name, channel (its index), color }].
function NxGuideJumpTargets(bundles as Dynamic, enabledBundles as Dynamic, jumps as Dynamic, channels as Object) as Object
    at = {}
    for i = 0 to channels.Count() - 1
        k = NxToStr(channels[i].id)
        if not at.DoesExist(k) then at[k] = i
    end for
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
    out = []
    for each e in entries
        first = -1
        for each id in e.ids
            k = NxToStr(id)
            if at.DoesExist(k) then
                if first < 0 or at[k] < first then first = at[k]
            end if
        end for
        if first >= 0 then
            ' Insert in guide order (a stable insertion; the list is short).
            t = { name: e.name, channel: first, color: channels[first].color }
            p = out.Count()
            while p > 0 and out[p - 1].channel > first
                p = p - 1
            end while
            if p = out.Count() then
                out.Push(t)
            else
                shifted = []
                for q = 0 to out.Count() - 1
                    if q = p then shifted.Push(t)
                    shifted.Push(out[q])
                end for
                out = shifted
            end if
        end if
    end for
    return out
end function
