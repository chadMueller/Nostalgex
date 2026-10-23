' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Talking to a Jellyfin or Emby server, after the Apple TV app's
' JellyfinAPIService.swift and EmbyAPIService.swift and the web tuner. Both
' servers answer the same calls here, and every request carries the same
' header:
'
'   Authorization: MediaBrowser Client="Nostalgex", Device="Roku",
'                  DeviceId="<id>", Version="0.1", Token="<token>"
'
' with Token left off before sign-in. The DeviceId is the per-install client
' id the Plex sign-in already keeps (NxPlexClientId), and it must stay the
' same: Jellyfin cancels a device's earlier token when that device signs in
' again (docs/JELLYFIN-EMBY.md).
'
' Requests go through NxServerRequest: HTTPS, or plain HTTP to a private
' address only, as for Plex.

function NxMbAuthHeader(token as String) as String
    h = "MediaBrowser Client=""Nostalgex"", Device=""Roku"", DeviceId=""" + NxPlexClientId() + """, Version=""0.1"""
    if token <> "" then h = h + ", Token=""" + token + """"
    return h
end function

function NxMbHeaders(token as String) as Object
    return { "Accept": "application/json", "Authorization": NxMbAuthHeader(token) }
end function

function NxMbPostHeaders(token as String) as Object
    h = NxMbHeaders(token)
    h["Content-Type"] = "application/json"
    return h
end function

' The addresses to try for what someone typed, in order, as upstream's
' ServerURLNormalizer: spaces trimmed, a trailing slash and a /web/... page
' dropped, a reverse-proxy path such as /jellyfin kept. With no scheme it is
' http; a plain http address with no port is tried at :8096 first, then as
' typed. Empty when it isn't an address.
function NxMbAddressCandidates(typed as String) as Object
    t = typed.Trim()
    if t = "" then return []
    if not CreateObject("roRegex", "^https?://", "i").IsMatch(t) then t = "http://" + t
    t = CreateObject("roRegex", "/web(/.*)?$", "i").Replace(t, "")
    t = CreateObject("roRegex", "/+$", "").Replace(t, "")
    hit = CreateObject("roRegex", "^(https?)://([^/:]+)(:\d+)?(/.*)?$", "i").Match(t)
    if hit.Count() = 0 then return []
    scheme = LCase(hit[1])
    host = hit[2]
    portPart = ""
    if hit.Count() > 3 then portPart = hit[3]
    path = ""
    if hit.Count() > 4 then path = hit[4]
    asTyped = scheme + "://" + host + portPart + path
    if scheme = "http" and portPart = "" then return [scheme + "://" + host + ":8096" + path, asTyped]
    return [asTyped]
end function

' What /System/Info/Public says about a server: { name, id, kind, version },
' kind "jellyfin" or "emby", or invalid when nothing answered as one. Jellyfin
' names itself in ProductName; Emby has no ProductName but lists
' LocalAddresses (scripts/nostalgex-jellyfin-urls.js).
function NxMbPublicInfo(base as String) as Dynamic
    res = NxServerRequest("GET", base + "/System/Info/Public", { "Accept": "application/json" }, "", 8000)
    return NxMbReadPublicInfo(res)
end function

function NxMbReadPublicInfo(res as Object) as Dynamic
    if res.code < 200 or res.code > 299 or type(res.json) <> "roAssociativeArray" then return invalid
    j = res.json
    kind = ""
    if NxIsString(j.ProductName) and CreateObject("roRegex", "jellyfin", "i").IsMatch(j.ProductName) then
        kind = "jellyfin"
    else if type(j.LocalAddresses) = "roArray" and NxIsString(j.Version) and NxIsString(j.Id) then
        kind = "emby"
    end if
    if kind = "" then return invalid
    name = NxToStr(j.ServerName)
    if name = "" then
        name = "Jellyfin Server"
        if kind = "emby" then name = "Emby Server"
    end if
    return { name: name, id: NxToStr(j.Id), kind: kind, version: NxToStr(j.Version) }
end function

' Sign in with a username and password: { token, userId, serverId } on
' success, "" when the server refused them, invalid when it couldn't be
' reached or didn't answer as one.
function NxMbSignIn(base as String, username as String, password as String) as Dynamic
    body = FormatJson({ Username: username, Pw: password })
    return NxMbReadAuth(NxServerRequest("POST", base + "/Users/AuthenticateByName", NxMbPostHeaders(""), body, 15000))
end function

function NxMbReadAuth(res as Object) as Dynamic
    if res.code = 401 or res.code = 403 then return ""
    if res.code < 200 or res.code > 299 or type(res.json) <> "roAssociativeArray" then return invalid
    j = res.json
    userId = ""
    if type(j.User) = "roAssociativeArray" then userId = NxToStr(j.User.Id)
    if not NxIsString(j.AccessToken) or j.AccessToken = "" or userId = "" then return ""
    return { token: j.AccessToken, userId: userId, serverId: NxToStr(j.ServerId) }
end function

' Quick Connect (Jellyfin only): { code, secret } to show and poll, "off" when
' the server has it switched off (401), "notJellyfin" when the address answers
' 404 or a web page, invalid when it couldn't be reached.
' Jellyfin 10.9 and later start a code with a POST and answer a GET with 405
' (12.2, checked 2026-10-18; upstream's clients still send the GET); older
' servers take the GET.
function NxMbQuickConnectStart(base as String) as Dynamic
    res = NxServerRequest("POST", base + "/QuickConnect/Initiate", NxMbHeaders(""), "", 8000)
    if res.code = 405 or res.code = 404 then res = NxServerRequest("GET", base + "/QuickConnect/Initiate", NxMbHeaders(""), "", 8000)
    if res.code = 401 or res.code = 403 then return "off"
    if res.code = 404 then return "notJellyfin"
    if res.code >= 200 and res.code <= 299 and type(res.json) <> "roAssociativeArray" then return "notJellyfin"
    if res.code < 200 or res.code > 299 or type(res.json) <> "roAssociativeArray" then return invalid
    if not NxIsString(res.json.Code) or not NxIsString(res.json.Secret) then return invalid
    return { code: res.json.Code, secret: res.json.Secret }
end function

' Whether the code has been approved: true, false, or invalid when the
' request failed (the code may have expired).
function NxMbQuickConnectApproved(base as String, secret as String) as Dynamic
    res = NxServerRequest("GET", base + "/QuickConnect/Connect?Secret=" + NxUrlEncode(secret), NxMbHeaders(""), "", 8000)
    if res.code < 200 or res.code > 299 or type(res.json) <> "roAssociativeArray" then return invalid
    return res.json.Authenticated = true
end function

' The sign-in an approved code gives, as NxMbSignIn's.
function NxMbQuickConnectFinish(base as String, secret as String) as Dynamic
    body = FormatJson({ Secret: secret })
    return NxMbReadAuth(NxServerRequest("POST", base + "/Users/AuthenticateWithQuickConnect", NxMbPostHeaders(""), body, 15000))
end function

' Whether a saved sign-in still works: "ok", "rejected" when the server
' refuses the token (signed out elsewhere, or a reinstalled server), or
' "unreachable".
function NxMbCheckSignIn(server as Object) as String
    res = NxServerRequest("GET", NxToStr(server.uri) + "/Users/" + NxUrlEncode(NxToStr(server.userId)), NxMbHeaders(NxToStr(server.accessToken)), "", 8000)
    if res.code = 401 or res.code = 403 then return "rejected"
    if res.code >= 200 and res.code <= 299 then return "ok"
    return "unreachable"
end function

' What NxMbScanServer reads a server through: getJSON(path) gives the parsed
' answer or invalid, with up to three tries, and getMany(paths) five at a
' time, each failure retried on its own. `auth` is set once the server
' rejects the token. server is a saved server: { uri, accessToken }.
function NxMbFetcher(server as Object) as Object
    return {
        base: NxToStr(server.uri),
        headers: NxMbHeaders(NxToStr(server.accessToken)),
        auth: false,
        getJSON: function(path as String) as Dynamic
            for attempt = 1 to 3
                res = NxServerRequest("GET", m.base + path, m.headers, "", 30000)
                ' A scan told to stop waiting keeps an answer that came,
                ' and tries nothing again.
                if NxLoadStopped() and (res.code < 200 or res.code > 299) then return invalid
                if res.code = 401 or res.code = 403 then
                    m.auth = true
                    return invalid
                end if
                if res.code >= 200 and res.code <= 299 then return res.json
                print "mediabrowser: a library request failed ("; res.code; "), try "; attempt; " of 3"
            end for
            return invalid
        end function,
        getMany: function(paths as Object) as Object
            urls = []
            for each path in paths
                urls.Push(m.base + path)
            end for
            answers = NxServerGetMany(urls, m.headers, 5, 30000)
            out = []
            for i = 0 to paths.Count() - 1
                res = answers[i]
                if res.code = 401 or res.code = 403 then
                    m.auth = true
                    out.Push(invalid)
                else if res.code >= 200 and res.code <= 299 then
                    out.Push(res.json)
                else if NxLoadStopped() then
                    out.Push(invalid)
                else
                    out.Push(m.getJSON(paths[i]))
                end if
            end for
            return out
        end function
    }
end function

' One UDP reply as { name, address, id }, or invalid. Address and Id must be
' there; Name falls back to the address (LANServerDiscovery.parseReply).
function NxMbDiscoveryReply(text as String) as Dynamic
    j = NxParseJsonBody(text)
    if type(j) <> "roAssociativeArray" then return invalid
    if not NxIsString(j.Address) or not NxIsString(j.Id) then return invalid
    address = j.Address.Trim()
    id = j.Id.Trim()
    if address = "" or id = "" then return invalid
    name = ""
    if NxIsString(j.Name) then name = j.Name.Trim()
    if name = "" then name = address
    return { name: name, address: address, id: id }
end function

' Servers of a kind on this network: [{ name, address, id }] in the order
' they answered, from a UDP broadcast to port 7359 that Jellyfin answers to
' "who is JellyfinServer?" and Emby to "who is EmbyServer?"
' (LANServerDiscovery.swift). Waits waitMs for answers, 3 s as upstream's
' listen window; empty when none came or the socket couldn't be made. One
' server heard twice is merged by NxSignInOutcome (SignInFlow.brs).
function NxMbDiscover(kind as String, waitMs = 3000 as Integer) as Object
    found = []
    probe = "who is JellyfinServer?"
    if kind = "emby" then probe = "who is EmbyServer?"
    sock = CreateObject("roDatagramSocket")
    if sock = invalid then return found
    port = CreateObject("roMessagePort")
    sock.SetMessagePort(port)
    sock.SetBroadcast(true)
    dest = CreateObject("roSocketAddress")
    dest.SetAddress("255.255.255.255:7359")
    sock.SetSendToAddress(dest)
    sock.NotifyReadable(true)
    sock.SendStr(probe)
    clock = CreateObject("roTimespan")
    while clock.TotalMilliseconds() < waitMs
        msg = Wait(waitMs - clock.TotalMilliseconds(), port)
        if type(msg) = "roSocketEvent" and sock.IsReadable() then
            reply = NxMbDiscoveryReply(sock.ReceiveStr(4096))
            if reply <> invalid then found.Push(reply)
        else if msg = invalid then
            exit while
        end if
    end while
    sock.Close()
    return found
end function
