' Copyright (c) 2026 nostalgex-roku contributors, MIT License.

sub init()
    m.top.functionName = "lookUp"
end sub

sub lookUp()
    items = NxList(m.top.items)
    cache = NxMusicLoadCache()
    net = NxMusicNet()
    halt = { task: m.top }
    halt.shouldStop = function() as Boolean
        return NxMusicShouldStop(m.task.control = "stop", NxEnabledBundles())
    end function
    saver = { items: items }
    saver.save = function(cache as Object)
        NxMusicSaveCache(NxMusicCapCache(cache, m.items))
    end function
    now& = CreateObject("roDateTime").AsSeconds()
    print "music: looking up "; items.Count(); " music videos (MusicBrainz about 1 a second, Deezer for the genres it lacks)"
    clock = CreateObject("roTimespan")
    n = NxMusicEnrich(net, items, cache, now&, halt, saver)
    if n > 0 then saver.save(cache)
    useful = 0
    for each k in cache
        if cache[k].useful = true then useful = useful + 1
    end for
    print "music: "; n; " rows written in "; clock.TotalSeconds(); " s; "; useful; " of "; cache.Count(); " with channel genres"
    m.top.written = n
end sub

' The lookups over HTTPS, paced and timed out as upstream's: MusicBrainz's
' JSON API with a User-Agent naming the app, as it asks, and Deezer's
' public API (the web tuner reaches it by JSONP; a TV reads it as JSON).
function NxMusicNet() as Object
    net = { mbLast: invalid, dzLast: invalid, agent: "Nostalgex/" + CreateObject("roAppInfo").GetVersion() + " (https://www.nostalgex.app; roku)" }
    net.get = function(url as String, kind as String) as Dynamic
        if kind = "mb" then
            m.mbLast = NxMusicPace(m.mbLast, NxMusicMbIntervalMs())
        else
            m.dzLast = NxMusicPace(m.dzLast, NxMusicDzIntervalMs())
        end if
        port = CreateObject("roMessagePort")
        xfer = CreateObject("roUrlTransfer")
        xfer.SetMessagePort(port)
        xfer.SetUrl(url)
        xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
        xfer.EnablePeerVerification(true)
        xfer.EnableHostVerification(true)
        xfer.SetHeaders({ "Accept": "application/json", "User-Agent": m.agent })
        if not xfer.AsyncGetToString() then return invalid
        msg = Wait(NxMusicTimeoutMs(), port)
        if type(msg) <> "roUrlEvent" then
            xfer.AsyncCancel()
            return invalid
        end if
        code = msg.GetResponseCode()
        if code < 200 or code > 299 then return invalid
        body = msg.GetString()
        if body = "" then return invalid
        return ParseJson(body)
    end function
    net.mbSearch = function(q as String) as Dynamic
        return m.get("https://musicbrainz.org/ws/2/recording?query=" + NxUrlEncode(q) + "&fmt=json&limit=10", "mb")
    end function
    net.mbRecording = function(id as String) as Dynamic
        return m.get("https://musicbrainz.org/ws/2/recording/" + NxUrlEncode(id) + "?inc=artist-credits+tags+releases&fmt=json", "mb")
    end function
    net.dzSearch = function(q as String) as Dynamic
        return m.get("https://api.deezer.com/search?q=" + NxUrlEncode(q) + "&limit=5", "dz")
    end function
    net.dzAlbum = function(id as String) as Dynamic
        return m.get("https://api.deezer.com/album/" + NxUrlEncode(id), "dz")
    end function
    return net
end function

' Waits out the rest of `intervalMs` since `last` (a roTimespan), then
' returns a fresh one for this request.
function NxMusicPace(last as Dynamic, intervalMs as Integer) as Object
    if last <> invalid then
        rest = intervalMs - last.TotalMilliseconds()
        if rest > 0 then Sleep(rest)
    end if
    return CreateObject("roTimespan")
end function
